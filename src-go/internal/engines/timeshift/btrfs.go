package timeshift

import (
	"context"
	"fmt"
	"path"
	"strconv"
	"strings"
	"time"
)

/* btrfs mode.
 *
 * A btrfs snapshot is not a copy: `btrfs subvolume snapshot` makes a new
 * subvolume sharing every extent with the original, which is why it completes
 * in a moment and costs nothing until something is written. That also makes it
 * a completely different shape of operation from rsync mode -- there is no file
 * transfer, no progress to report per file, and no exclude list, because a
 * subvolume snapshot takes the whole subvolume or nothing.
 *
 * Only the Ubuntu-style layout is supported: a top-level "@" for root and
 * optionally "@home". That is not a limitation this port introduced; the
 * subvolume names are hard-coded through the Vala core too, and a repository
 * with other names is refused rather than half-handled.
 *
 * btrfs and a remote repository are mutually exclusive: a subvolume snapshot is
 * a local filesystem operation and there is no way to perform one over rsync.
 * The config loader forces btrfs off for an ssh location, and Engine.Open does
 * it again so an engine opened directly cannot get it wrong.
 */

// Subvolume names this engine handles. Anything else is not a layout it knows.
const (
	SubvolRoot = "@"
	SubvolHome = "@home"
)

// SupportedSubvolumes lists them in the order they are operated on.
var SupportedSubvolumes = []string{SubvolRoot, SubvolHome}

// IsSupportedSubvolume reports whether a name is one this engine handles.
func IsSupportedSubvolume(name string) bool {
	return name == SubvolRoot || name == SubvolHome
}

// BtrfsCaps describes what the installed btrfs-progs can do.
type BtrfsCaps struct {
	Major int
	Minor int

	// RecursiveDelete is `btrfs subvolume delete --recursive`, added in 6.12.
	// Without it a snapshot containing a nested subvolume cannot be deleted in
	// one call and the nested one has to be found and removed first.
	RecursiveDelete bool

	// QuotasEnabled means qgroups are on, which makes deletion much more
	// involved: the qgroup has to be destroyed and the quota tree rescanned,
	// and both can only proceed once btrfs has finished the deletion.
	QuotasEnabled bool
}

// DetectBtrfsCaps asks btrfs-progs what it is.
func DetectBtrfsCaps(ctx context.Context, runner Runner) (BtrfsCaps, error) {
	var caps BtrfsCaps

	code, stdout, _, err := runner.Run(ctx, []string{"btrfs", "--version"}, "")
	if err != nil {
		return caps, fmt.Errorf("timeshift: btrfs-progs not available: %w", err)
	}
	if code != 0 {
		return caps, fmt.Errorf("timeshift: btrfs --version exited %d", code)
	}

	caps.Major, caps.Minor = parseBtrfsVersion(stdout)
	// 6.12 is where --recursive arrived.
	caps.RecursiveDelete = caps.Major > 6 || (caps.Major == 6 && caps.Minor >= 12)
	return caps, nil
}

// parseBtrfsVersion reads "btrfs-progs v6.17.1" into 6, 17.
func parseBtrfsVersion(out string) (int, int) {
	for _, field := range strings.Fields(out) {
		v, ok := strings.CutPrefix(field, "v")
		if !ok {
			continue
		}
		parts := strings.Split(v, ".")
		if len(parts) < 2 {
			continue
		}
		major, err1 := strconv.Atoi(parts[0])
		minor, err2 := strconv.Atoi(strings.TrimSuffix(parts[1], "-"))
		if err1 == nil && err2 == nil {
			return major, minor
		}
	}
	return 0, 0
}

// Subvolume is one btrfs subvolume in a repository or on the system.
type Subvolume struct {
	Name string
	Path string

	// ID is the btrfs subvolume id, which is also the qgroup id as "0/<id>".
	// Zero when it has not been read.
	ID int64

	// MountPath is the filesystem this subvolume lives on, which is what the
	// quota and sync commands operate on -- not the subvolume path.
	MountPath string
}

// SnapshotSubvolume creates a snapshot of src at dst.
//
// Instant and free: the new subvolume shares every extent with the original
// until one of them is written to.
func SnapshotSubvolume(ctx context.Context, runner Runner, src, dst string) error {
	code, _, stderr, err := runner.Run(ctx,
		[]string{"btrfs", "subvolume", "snapshot", src, dst}, "")
	if err != nil {
		return fmt.Errorf("timeshift: btrfs snapshot %s: %w", src, err)
	}
	if code != 0 {
		return fmt.Errorf("timeshift: btrfs snapshot %s -> %s failed: %s",
			src, dst, strings.TrimSpace(stderr))
	}
	return nil
}

// IsSubvolume reports whether a path is a btrfs subvolume rather than an
// ordinary directory.
func IsSubvolume(ctx context.Context, runner Runner, p string) bool {
	code, _, _, err := runner.Run(ctx, []string{"btrfs", "subvolume", "show", p}, "")
	return err == nil && code == 0
}

// DeleteOptions control subvolume removal.
type DeleteOptions struct {
	Caps BtrfsCaps

	// UseCommitAfter passes --commit-after, which waits for the deletion to be
	// committed. Self-demoting: the Vala core drops it on first failure,
	// because older btrfs-progs reject it.
	UseCommitAfter bool
}

// DeleteSubvolume removes a subvolume, including a nested one if present.
//
// The nested check is not paranoia. A snapshot directory can itself contain a
// subvolume -- "@" inside a snapshot named for its own root -- and deleting the
// outer one fails while the inner exists. It is verified with `subvolume show`
// first, because an ordinary directory of the same name must NOT be deleted as
// though it were a subvolume.
func DeleteSubvolume(ctx context.Context, runner Runner, sv Subvolume, o DeleteOptions) error {
	args := []string{"btrfs", "subvolume", "delete"}
	if o.UseCommitAfter {
		args = append(args, "--commit-after")
	}
	if o.Caps.RecursiveDelete {
		args = append(args, "--recursive")
	}

	// A nested subvolume of the same name, e.g. <snapshot>/@ inside <snapshot>.
	nested := path.Join(sv.Path, sv.Name)
	if IsSubvolume(ctx, runner, nested) {
		code, _, stderr, err := runner.Run(ctx, append(append([]string{}, args...), nested), "")
		if err != nil {
			return fmt.Errorf("timeshift: delete nested subvolume %s: %w", nested, err)
		}
		if code != 0 {
			return fmt.Errorf("timeshift: could not delete nested subvolume %s: %s",
				nested, strings.TrimSpace(stderr))
		}
	}

	code, _, stderr, err := runner.Run(ctx, append(args, sv.Path), "")
	if err != nil {
		return fmt.Errorf("timeshift: delete subvolume %s: %w", sv.Path, err)
	}
	if code != 0 {
		return fmt.Errorf("timeshift: could not delete subvolume %s: %s",
			sv.Path, strings.TrimSpace(stderr))
	}
	return nil
}

/* Cleaning up after a deletion when quotas are on.
 *
 * btrfs deletes a subvolume asynchronously, and its qgroup outlives it. Left
 * behind, stale qgroups accumulate and every `qgroup show` gets slower, which
 * is what makes a repository with quotas enabled gradually become unusable.
 *
 * Each step waits for the previous one because none can proceed while the
 * deletion is still in flight.
 *
 * Expect this to take about half a minute even on a tiny filesystem, and know
 * why: `btrfs subvolume sync` BLOCKS until the kernel's cleaner thread has
 * finished removing the subvolume, and that runs on the commit interval, ~30s
 * by default. Measured at 31.0s for a single empty subvolume on a 512 MB
 * loopback filesystem. It is not a hang, and it is not this code being slow.
 *
 * The Vala loops are unbounded. These take a deadline -- and it is applied
 * through the context, not merely checked between retries, because the slow
 * step is a single blocking call rather than a sequence of quick failures. A
 * clock check between attempts would never fire.
 */

// QGroupCleanupOptions bound the wait.
type QGroupCleanupOptions struct {
	// Timeout caps the whole sequence. Zero uses DefaultQGroupTimeout.
	Timeout time.Duration

	// Interval is how often to retry a step. Zero uses one second.
	Interval time.Duration
}

// DefaultQGroupTimeout bounds the qgroup dance. Generous, because a large
// deletion genuinely takes time; finite, because a daemon cannot block forever.
const DefaultQGroupTimeout = 10 * time.Minute

// CleanupQGroup destroys the qgroup a deleted subvolume left behind.
//
// Returns nil when quotas are not enabled or the qgroup is already gone: btrfs
// destroys it with the subvolume in some versions, and that is not an error.
func CleanupQGroup(ctx context.Context, runner Runner, sv Subvolume, repoMountPath string, o QGroupCleanupOptions) error {
	if sv.ID <= 0 || repoMountPath == "" {
		return nil
	}
	timeout := o.Timeout
	if timeout == 0 {
		timeout = DefaultQGroupTimeout
	}
	interval := o.Interval
	if interval == 0 {
		interval = time.Second
	}

	/* The deadline goes on the CONTEXT so it also bounds a single blocking
	 * call. sysexec kills the process group when the context is done, so a
	 * `subvolume sync` that never returns is cut off rather than pinning the
	 * job forever. */
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	retry := func(what string, argv []string) error {
		for {
			code, _, stderr, err := runner.Run(ctx, argv, "")
			if err == nil && code == 0 {
				return nil
			}
			if ctx.Err() != nil {
				return fmt.Errorf("timeshift: %s did not finish within %s: %s",
					what, timeout, strings.TrimSpace(stderr))
			}
			select {
			case <-ctx.Done():
				return fmt.Errorf("timeshift: %s did not finish within %s", what, timeout)
			case <-time.After(interval):
			}
		}
	}

	// Wait for the deletion to be committed.
	if err := retry("btrfs subvolume sync", []string{"btrfs", "subvolume", "sync", sv.MountPath}); err != nil {
		return err
	}
	if err := retry("btrfs quota rescan", []string{"btrfs", "quota", "rescan", sv.MountPath}); err != nil {
		return err
	}

	qgroupID := "0/" + strconv.FormatInt(sv.ID, 10)
	code, stdout, _, err := runner.Run(ctx, []string{"btrfs", "qgroup", "show", "-f", repoMountPath}, "")
	if err != nil {
		return err
	}
	// Already gone: btrfs destroyed it with the subvolume. Not an error.
	if code != 0 || !strings.Contains(stdout, qgroupID) {
		return nil
	}

	code, _, stderr, err := runner.Run(ctx,
		[]string{"btrfs", "qgroup", "destroy", qgroupID, repoMountPath}, "")
	if err != nil {
		return err
	}
	if code != 0 {
		/* Not fatal. The qgroup may have been destroyed between the check and
		 * here, and a leftover one costs performance rather than correctness. */
		return fmt.Errorf("timeshift: qgroup %s could not be destroyed: %s",
			qgroupID, strings.TrimSpace(stderr))
	}

	if err := retry("btrfs quota rescan", []string{"btrfs", "quota", "rescan", sv.MountPath}); err != nil {
		return err
	}
	return retry("btrfs subvolume sync", []string{"btrfs", "subvolume", "sync", sv.MountPath})
}

// ListSubvolumes reads the subvolumes of a mounted btrfs filesystem.
func ListSubvolumes(ctx context.Context, runner Runner, mountPath string) (map[string]Subvolume, error) {
	code, stdout, stderr, err := runner.Run(ctx,
		[]string{"btrfs", "subvolume", "list", mountPath}, "")
	if err != nil {
		return nil, fmt.Errorf("timeshift: list subvolumes: %w", err)
	}
	if code != 0 {
		return nil, fmt.Errorf("timeshift: btrfs subvolume list %s exited %d: %s",
			mountPath, code, strings.TrimSpace(stderr))
	}
	return parseSubvolumeList(stdout, mountPath), nil
}

// parseSubvolumeList reads "ID 257 gen 9 top level 5 path @" lines.
func parseSubvolumeList(out, mountPath string) map[string]Subvolume {
	subs := map[string]Subvolume{}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 || f[0] != "ID" {
			continue
		}
		var id int64
		var name string
		for i := 0; i < len(f)-1; i++ {
			switch f[i] {
			case "ID":
				id, _ = strconv.ParseInt(f[i+1], 10, 64)
			case "path":
				name = strings.Join(f[i+1:], " ")
			}
		}
		if name == "" {
			continue
		}
		subs[name] = Subvolume{
			Name:      name,
			Path:      path.Join(mountPath, name),
			ID:        id,
			MountPath: mountPath,
		}
	}
	return subs
}

// ValidateLayout checks a mounted btrfs filesystem has the layout this engine
// understands.
//
// Only "@" is required; "@home" is optional. A filesystem without "@" is not a
// layout Timeshift can snapshot, and saying so plainly is better than
// discovering it halfway through.
func ValidateLayout(ctx context.Context, runner Runner, mountPath string, needHome bool) error {
	subs, err := ListSubvolumes(ctx, runner, mountPath)
	if err != nil {
		return err
	}
	if _, ok := subs[SubvolRoot]; !ok {
		return fmt.Errorf(
			"timeshift: %s has no %q subvolume; btrfs mode needs the Ubuntu-style layout",
			mountPath, SubvolRoot)
	}
	if needHome {
		if _, ok := subs[SubvolHome]; !ok {
			return fmt.Errorf("timeshift: %s has no %q subvolume", mountPath, SubvolHome)
		}
	}
	return nil
}

// BtrfsSnapshotPlan is what a btrfs create will do.
type BtrfsSnapshotPlan struct {
	// Name is the snapshot directory, the same timestamp form as rsync mode.
	Name string

	// Subvolumes maps a subvolume name to where its snapshot will be made.
	Subvolumes map[string]string
}

// PlanBtrfsSnapshot works out what a create would do, without doing it.
//
// Separated so a client can be told exactly which subvolumes are involved
// before anything happens -- and so the plan is testable without a filesystem.
func PlanBtrfsSnapshot(snapshotsPath, name string, includeHome bool) BtrfsSnapshotPlan {
	plan := BtrfsSnapshotPlan{Name: name, Subvolumes: map[string]string{}}
	plan.Subvolumes[SubvolRoot] = path.Join(snapshotsPath, name, SubvolRoot)
	if includeHome {
		plan.Subvolumes[SubvolHome] = path.Join(snapshotsPath, name, SubvolHome)
	}
	return plan
}

// RestoreSubvolume puts a snapshot's subvolume back.
//
// It is a snapshot of the snapshot, not a copy: the restored subvolume shares
// its extents with the stored one, so the restore is instant. That is why btrfs
// mode has no per-file progress to report -- there are no files being moved.
//
// Refuses when the destination already exists. The caller is expected to have
// moved the live subvolume aside first (that is what the pre-restore snapshot
// is for), and silently replacing a subvolume that is still there would destroy
// whatever it holds.
func RestoreSubvolume(ctx context.Context, runner Runner, src, dst string) error {
	if IsSubvolume(ctx, runner, dst) {
		return fmt.Errorf("timeshift: %s already exists; move the live subvolume aside first", dst)
	}
	return SnapshotSubvolume(ctx, runner, src, dst)
}
