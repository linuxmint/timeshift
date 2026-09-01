package sysexec

import "context"

// Simple adapts an Exec to the narrow shape most packages want: an argv, some
// stdin, and back an exit code with the two output streams.
//
// The narrow interface is deliberate. block, distro and the engines only ever
// need "run this and give me the output", and declaring that is what lets them
// be tested with a three-line fake instead of a process.
type Simple struct{ E *Exec }

// NewSimple wraps e.
func NewSimple(e *Exec) Simple { return Simple{E: e} }

// Run executes argv and returns its exit code and output. A non-zero exit is
// reported in the code, not as an error; err is non-nil only when the process
// could not be run at all.
func (s Simple) Run(ctx context.Context, argv []string, stdin string) (int, string, string, error) {
	res, err := s.E.Run(ctx, Cmd{Argv: argv, Stdin: stdin})
	return res.ExitCode, res.Stdout, res.Stderr, err
}

// Stream executes argv, handing each line of output to onLine with "stdout" or
// "stderr" as the stream name.
func (s Simple) Stream(ctx context.Context, argv []string, onLine func(stream, line string)) (int, error) {
	p, err := s.E.Start(ctx, Cmd{Argv: argv}, Handler{
		Stdout: func(l string) { onLine("stdout", l) },
		Stderr: func(l string) { onLine("stderr", l) },
	})
	if err != nil {
		return -1, err
	}
	res, err := p.Wait()
	return res.ExitCode, err
}

/* RunEnv is Run with the child's environment replaced.
 *
 * It exists for exactly one caller: handing ssh a password through SSH_ASKPASS.
 * The password goes in the CHILD's environment and nowhere else -- not in argv,
 * where /proc/<pid>/cmdline exposes it to anything on the machine, and not in a
 * file. Putting it in the daemon's own environment instead, as the Vala build
 * did, would leave it readable in /proc/self/environ for as long as the daemon
 * runs rather than for the life of one ssh-copy-id.
 *
 * A nil env means DefaultEnv(), the same as Run.
 */
func (s Simple) RunEnv(ctx context.Context, argv []string, stdin string, env []string) (int, string, string, error) {
	res, err := s.E.Run(ctx, Cmd{Argv: argv, Stdin: stdin, Env: env})
	return res.ExitCode, res.Stdout, res.Stderr, err
}
