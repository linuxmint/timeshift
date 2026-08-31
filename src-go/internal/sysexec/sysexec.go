// Package sysexec runs the external commands Timeshift is built out of:
// rsync, btrfs, lsblk, df, mount, cryptsetup, ssh.
//
// It exists to replace TeeJee.ProcessHelper, and it fixes that layer's central
// defect. exec_script_sync() wrote a bash script whose wrapper appended
//
//	exitCode=$?; echo ${exitCode} > status
//
// so the last command in every script was a successful echo and the function
// *always returned 0*. Callers that needed the real status had to read a
// sibling file (AsyncTask.read_exit_code) or append an explicit `exit $?`
// (RepoBackend.run_script_checked). Here the exit status is simply the exit
// status.
//
// Commands are argv slices, never assembled strings, so nothing needs quoting
// and TeeJee's escape_single_quote() has no equivalent. The one place that
// still genuinely needs generated shell is the restore script, which runs under
// chroot and must survive a reboot; that lives in internal/restore.
package sysexec

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
)

// ErrNotFound reports that the executable is not on PATH. Callers that probe
// for optional tools (btrfs, tailscale, dpkg-repack) test for this rather than
// inspecting an exit code.
var ErrNotFound = errors.New("sysexec: executable not found")

// maxLine bounds a single line of child output. rsync paths are long but
// nowhere near this; the cap keeps a runaway child from exhausting memory.
const maxLine = 1 << 20

// Cmd describes one process to run.
type Cmd struct {
	Argv []string
	Dir  string

	// Env replaces the environment entirely. Leave nil to get DefaultEnv(),
	// which forces the C locale -- every parser in this tree reads command
	// output positionally and a translated `df` or `lsblk` breaks all of them.
	Env []string

	// Stdin is written to the child and the pipe then closed. This is how a
	// LUKS passphrase reaches cryptsetup: as an argument it would sit in
	// /proc/<pid>/cmdline, readable by anything, for the life of the process.
	Stdin string

	// Nice raises the child's niceness (positive values only; 0 leaves it
	// alone). Backup and delete run at Nice 5, matching the Vala default.
	Nice int

	// IOIdle puts the child in the idle I/O scheduling class. A snapshot must
	// not make the desktop unusable, which is what src/vapi/ioprio.vapi was
	// added for.
	IOIdle bool
}

// Result is the outcome of a finished process.
type Result struct {
	ExitCode int
	Stdout   string
	Stderr   string
}

// Failed reports a non-zero exit. rsync is the notable caller that must NOT use
// this: it treats 24 (files vanished) as success and 23 as a warning.
func (r Result) Failed() bool { return r.ExitCode != 0 }

// Output returns stdout, falling back to stderr when stdout is empty -- and
// prefers stderr on failure, because a command that printed to stdout and then
// failed would otherwise report the wrong half.
func (r Result) Output() string {
	if r.Failed() {
		if strings.TrimSpace(r.Stderr) != "" {
			return r.Stderr
		}
		return r.Stdout
	}
	if strings.TrimSpace(r.Stdout) != "" {
		return r.Stdout
	}
	return r.Stderr
}

// Handler receives child output a line at a time, with the trailing newline
// removed. Either field may be nil. Handlers run on the reader goroutines, so
// an implementation that touches shared state must do its own locking; the job
// layer satisfies this by forwarding to a channel.
type Handler struct {
	Stdout func(line string)
	Stderr func(line string)
}

// Runner is the seam tests replace. Nothing outside this package builds an
// *exec.Cmd.
type Runner interface {
	Run(ctx context.Context, c Cmd) (Result, error)
	Start(ctx context.Context, c Cmd, h Handler) (*Process, error)
}

// Exec is the real Runner.
type Exec struct {
	Log *slog.Logger
}

// New returns a Runner logging to log. A nil logger is allowed and discards.
func New(log *slog.Logger) *Exec {
	if log == nil {
		// Not slog.DiscardHandler: that is go1.24, and the Build-Depends floor
		// is golang-go 1.22 so older LTS toolchains can still build this.
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Exec{Log: log}
}

// DefaultEnv is the process environment with the C locale forced, matching what
// TeeJee's save_bash_script_temp() exported into every generated script.
func DefaultEnv() []string {
	env := make([]string, 0, len(os.Environ())+2)
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "LANG=") || strings.HasPrefix(kv, "LC_ALL=") {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "LANG=C", "LC_ALL=C.UTF-8")
}

// Run executes c to completion and returns its output.
//
// A non-zero exit is NOT an error: it comes back in Result.ExitCode, because
// several callers treat particular codes as success. An error means the process
// could not be run or was cancelled.
func (e *Exec) Run(ctx context.Context, c Cmd) (Result, error) {
	var out, errb strings.Builder
	h := Handler{
		Stdout: func(l string) { out.WriteString(l); out.WriteByte('\n') },
		Stderr: func(l string) { errb.WriteString(l); errb.WriteByte('\n') },
	}

	p, err := e.Start(ctx, c, h)
	if err != nil {
		return Result{ExitCode: -1}, err
	}

	res, err := p.Wait()
	res.Stdout = out.String()
	res.Stderr = errb.String()
	return res, err
}

// Start launches c and returns a handle. The caller must call Wait.
func (e *Exec) Start(ctx context.Context, c Cmd, h Handler) (*Process, error) {
	if len(c.Argv) == 0 {
		return nil, errors.New("sysexec: empty argv")
	}

	path, err := exec.LookPath(c.Argv[0])
	if err != nil {
		return nil, fmt.Errorf("%w: %s", ErrNotFound, c.Argv[0])
	}

	cmd := exec.Command(path, c.Argv[1:]...)
	cmd.Dir = c.Dir
	cmd.Env = c.Env
	if cmd.Env == nil {
		cmd.Env = DefaultEnv()
	}

	// Its own process group, so Stop/Pause reach every descendant. rsync over
	// ssh forks a child; signalling only the parent leaves that child running.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	var stdin io.WriteCloser
	if c.Stdin != "" {
		if stdin, err = cmd.StdinPipe(); err != nil {
			return nil, err
		}
	}

	e.Log.Debug("exec", "argv", c.Argv, "dir", c.Dir)

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("sysexec: start %s: %w", c.Argv[0], err)
	}

	p := &Process{cmd: cmd, log: e.Log, argv: c.Argv}

	/* Priority is applied from the parent after the fork rather than in a
	 * pre-exec hook, which Go has no way to install without cgo. The child
	 * therefore runs at normal priority for the few milliseconds until this
	 * lands -- harmless for work measured in minutes. */
	if c.Nice > 0 {
		if err := syscall.Setpriority(syscall.PRIO_PROCESS, cmd.Process.Pid, c.Nice); err != nil {
			e.Log.Debug("could not set nice", "pid", cmd.Process.Pid, "err", err)
		}
	}
	if c.IOIdle {
		if err := setIOIdle(cmd.Process.Pid); err != nil {
			e.Log.Debug("could not set io priority", "pid", cmd.Process.Pid, "err", err)
		}
	}

	if stdin != nil {
		go func() {
			io.WriteString(stdin, c.Stdin)
			stdin.Close()
		}()
	}

	p.readers.Add(2)
	go p.scan(stdout, h.Stdout)
	go p.scan(stderr, h.Stderr)

	// Cancellation kills the group, not just the leader.
	if ctx.Done() != nil {
		p.watch = make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				p.signal(syscall.SIGKILL)
			case <-p.watch:
			}
		}()
	}

	return p, nil
}

// Process is a running child.
type Process struct {
	cmd   *exec.Cmd
	log   *slog.Logger
	argv  []string
	watch chan struct{}

	readers sync.WaitGroup

	mu     sync.Mutex
	paused bool
	done   bool
}

// Pid is the child's process id, which is also its process-group id.
func (p *Process) Pid() int { return p.cmd.Process.Pid }

func (p *Process) scan(r io.Reader, fn func(string)) {
	defer p.readers.Done()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), maxLine)
	for sc.Scan() {
		if fn != nil {
			fn(sc.Text())
		}
	}
}

// Wait blocks until the child exits and every line of its output has been
// handed to the Handler.
func (p *Process) Wait() (Result, error) {
	p.readers.Wait()

	err := p.cmd.Wait()

	p.mu.Lock()
	p.done = true
	p.mu.Unlock()
	if p.watch != nil {
		close(p.watch)
	}

	var ee *exec.ExitError
	switch {
	case err == nil:
		return Result{ExitCode: 0}, nil
	case errors.As(err, &ee):
		// A real exit status, including one produced by a signal.
		return Result{ExitCode: ee.ExitCode()}, nil
	default:
		return Result{ExitCode: -1}, fmt.Errorf("sysexec: wait %s: %w", p.argv[0], err)
	}
}

// signal sends sig to the whole process group. A negative pid is the group.
func (p *Process) signal(sig syscall.Signal) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.done || p.cmd.Process == nil {
		return nil
	}
	return syscall.Kill(-p.cmd.Process.Pid, sig)
}

// Pause suspends the child and its descendants.
func (p *Process) Pause() error {
	if err := p.signal(syscall.SIGSTOP); err != nil {
		return err
	}
	p.mu.Lock()
	p.paused = true
	p.mu.Unlock()
	return nil
}

// Resume continues a paused child.
func (p *Process) Resume() error {
	if err := p.signal(syscall.SIGCONT); err != nil {
		return err
	}
	p.mu.Lock()
	p.paused = false
	p.mu.Unlock()
	return nil
}

// Paused reports whether Pause is in effect.
func (p *Process) Paused() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.paused
}

// Stop asks the child to terminate.
//
// SIGCONT goes first: SIGTERM delivered to a stopped process is queued and does
// nothing until it runs again, so cancelling a paused backup would otherwise
// hang forever.
func (p *Process) Stop() error {
	p.signal(syscall.SIGCONT)
	return p.signal(syscall.SIGTERM)
}

// Kill terminates the child immediately.
func (p *Process) Kill() error {
	p.signal(syscall.SIGCONT)
	return p.signal(syscall.SIGKILL)
}
