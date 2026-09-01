// Package rundir clears up after Timeshift runs that were killed.
//
// Every run owns a directory named for its pid, /run/timeshift/<pid>, and
// mounts things underneath it -- a repository device, a snapshot being browsed,
// a restore target and its nested /home, /boot and /boot/efi. A run that exits
// normally unmounts them. A run that is killed does not, and nothing else ever
// did: the mounts stay, the filesystems stay busy, and the directories
// accumulate for the life of the boot.
//
// The daemon makes this both worse and easier. Worse, because it is long-lived:
// it crashes mid-restore, systemd restarts it under a NEW pid, and the old
// pid's target stays mounted forever with nobody who believes they own it.
// Easier, because there is now one process that starts early and can sweep
// before it does anything else.
//
// # The rule that matters
//
// Only subdirectories whose name is entirely numeric are ever touched, and
// never our own. The daemon's socket lives at /run/timeshift/daemon.sock, in
// the very directory being swept, so a reaper that walked everything would
// delete the socket it is about to listen on. The Vala reaper encodes the same
// rule through int64.try_parse (Main.vala); this one does it with
// strconv.Atoi and a test that names the socket explicitly.
//
// Removal is rmdir only, never rm -rf. A directory that still holds something
// is a directory whose mounts did not come apart, and deleting through it would
// mean deleting through a mount point into a real filesystem.
package rundir

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Root is the directory every run allocates its own subdirectory under.
const Root = "/run/timeshift"

// Runner is the subset of the command runner this package needs.
type Runner interface {
	Run(ctx context.Context, argv []string, dir string) (code int, stdout, stderr string, err error)
}

// Reaper sweeps the leftovers of dead runs.
type Reaper struct {
	// Runner performs the unmounts.
	Runner Runner

	// Root defaults to the package Root. Overridden in tests.
	Root string

	// Self is the pid whose directory must be left alone. Zero means
	// os.Getpid, which is what every caller outside a test wants.
	Self int

	// MountsFile defaults to /proc/mounts. Overridden in tests.
	MountsFile string

	// Alive reports whether a pid is still running. Defaults to a /proc check.
	Alive func(pid int) bool
}

// Report is what a sweep did, for a log line worth reading afterwards.
type Report struct {
	// Unmounted are the mount points released, deepest first.
	Unmounted []string

	// Removed are the run directories that came away cleanly.
	Removed []string

	// Kept are directories left alone because something is still in them --
	// almost always a mount that would not release.
	Kept []string

	// Problems are non-fatal failures, already described.
	Problems []string
}

// Empty reports whether the sweep found nothing to do, so a caller can stay
// quiet on the overwhelmingly common path.
func (r Report) Empty() bool {
	return len(r.Unmounted) == 0 && len(r.Removed) == 0 && len(r.Kept) == 0 && len(r.Problems) == 0
}

func (r *Reaper) root() string {
	if r.Root != "" {
		return r.Root
	}
	return Root
}

func (r *Reaper) self() int {
	if r.Self != 0 {
		return r.Self
	}
	return os.Getpid()
}

func (r *Reaper) mountsFile() string {
	if r.MountsFile != "" {
		return r.MountsFile
	}
	return "/proc/mounts"
}

func (r *Reaper) alive(pid int) bool {
	if r.Alive != nil {
		return r.Alive(pid)
	}
	_, err := os.Stat("/proc/" + strconv.Itoa(pid))
	return err == nil
}

// Reap unmounts and removes what dead runs left behind.
//
// It never returns an error for an individual failure: a leftover that will not
// come apart is worth reporting, but it is not a reason to refuse to start the
// daemon. The whole point is that this runs before anything else.
func (r *Reaper) Reap(ctx context.Context) Report {
	var rep Report

	root := r.root()
	if _, err := os.Stat(root); err != nil {
		return rep
	}

	dead := r.deadDirs(&rep)
	if len(dead) == 0 {
		return rep
	}

	// Unmount everything under the dead directories, deepest first, so a
	// nested /boot/efi is released before the root it sits inside.
	for _, mp := range r.mountsUnder(dead, &rep) {
		if code, _, stderr, err := r.Runner.Run(ctx, []string{"umount", mp}, ""); err != nil || code != 0 {
			/* Lazy is a deliberate second attempt and not a first resort. The
			 * holder here is a process that no longer exists; what keeps the
			 * mount busy is usually a nested bind the kernel has not finished
			 * with. A detach leaves it to come apart on its own rather than
			 * leaving it mounted forever. */
			if code2, _, stderr2, err2 := r.Runner.Run(ctx, []string{"umount", "-l", mp}, ""); err2 != nil || code2 != 0 {
				rep.Problems = append(rep.Problems,
					fmt.Sprintf("could not unmount %s: %s", mp, firstLine(stderr, stderr2)))
				continue
			}
		}
		rep.Unmounted = append(rep.Unmounted, mp)
	}

	for _, dir := range dead {
		r.removeDir(dir, &rep)
	}

	return rep
}

// deadDirs lists the run directories whose process is gone.
func (r *Reaper) deadDirs(rep *Report) []string {
	entries, err := os.ReadDir(r.root())
	if err != nil {
		rep.Problems = append(rep.Problems, "could not read "+r.root()+": "+err.Error())
		return nil
	}

	self := r.self()
	var dead []string

	for _, e := range entries {
		if !e.IsDir() {
			// daemon.sock lands here, and so does repo.lock.
			continue
		}

		/* The load-bearing check. A non-numeric name is not a run directory,
		 * and the socket this daemon is about to listen on lives in this very
		 * directory. */
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 0 {
			continue
		}
		if pid == self {
			continue
		}
		if r.alive(pid) {
			continue
		}

		dead = append(dead, filepath.Join(r.root(), e.Name()))
	}

	sort.Strings(dead)
	return dead
}

// mountsUnder returns the mount points beneath any of dirs, deepest first.
func (r *Reaper) mountsUnder(dirs []string, rep *Report) []string {
	data, err := os.ReadFile(r.mountsFile())
	if err != nil {
		rep.Problems = append(rep.Problems, "could not read "+r.mountsFile()+": "+err.Error())
		return nil
	}

	var found []string
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		// /proc/mounts octal-escapes spaces and friends.
		mp := unescapeMount(fields[1])

		for _, d := range dirs {
			if mp == d || strings.HasPrefix(mp, d+string(os.PathSeparator)) {
				found = append(found, mp)
				break
			}
		}
	}

	// Deepest first: a child mount must be released before its parent.
	sort.Slice(found, func(i, j int) bool {
		di, dj := strings.Count(found[i], "/"), strings.Count(found[j], "/")
		if di != dj {
			return di > dj
		}
		return found[i] > found[j]
	})
	return found
}

// removeDir clears a dead run's directory, as far as it safely can.
func (r *Reaper) removeDir(dir string, rep *Report) {
	/* The ssh control sockets first.
	 *
	 * rmdir cannot remove a socket, so a ControlMaster that was killed rather
	 * than shut down leaves one behind -- and with it a directory that could
	 * never be reaped. Worse, if the kernel later recycles that pid onto a new
	 * Timeshift, the new run's ControlPath points straight at the old socket.
	 *
	 * Deliberately narrow: named ssh-* and directly inside a dead run's
	 * directory. Everything else is left for rmdir to refuse. */
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			if !e.IsDir() && strings.HasPrefix(e.Name(), "ssh-") {
				_ = os.Remove(filepath.Join(dir, e.Name()))
			}
		}
		// Then the now-empty mount points, innermost first.
		var subdirs []string
		for _, e := range entries {
			if e.IsDir() {
				subdirs = append(subdirs, filepath.Join(dir, e.Name()))
			}
		}
		removeEmptyTree(subdirs)
	}

	if err := os.Remove(dir); err != nil {
		/* rmdir only. A directory that still holds something holds a mount
		 * that did not release, and deleting through it would mean deleting
		 * through a mount point into a real filesystem. */
		rep.Kept = append(rep.Kept, dir)
		return
	}
	rep.Removed = append(rep.Removed, dir)
}

// removeEmptyTree rmdirs the given directories and their empty descendants,
// deepest first. Anything that is not empty is left exactly as it is.
func removeEmptyTree(dirs []string) {
	for _, d := range dirs {
		if entries, err := os.ReadDir(d); err == nil {
			var kids []string
			for _, e := range entries {
				if e.IsDir() {
					kids = append(kids, filepath.Join(d, e.Name()))
				}
			}
			removeEmptyTree(kids)
		}
		_ = os.Remove(d)
	}
}

// unescapeMount decodes the octal escapes /proc/mounts uses for space, tab,
// newline and backslash in a mount point.
func unescapeMount(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if v, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(v))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func firstLine(candidates ...string) string {
	for _, c := range candidates {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		if i := strings.IndexByte(c, '\n'); i >= 0 {
			return c[:i]
		}
		return c
	}
	return "unknown error"
}
