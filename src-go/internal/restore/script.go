package restore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

/* Running a generated script.
 *
 * The scripts are written to a file and run with bash rather than fed on
 * stdin. Two reasons, and the second is the one that matters:
 *
 *   - A script on stdin cannot read stdin itself, and the finish script's
 *     run-parts hooks are third-party code that may want to.
 *   - A file can be read afterwards. When a restore goes wrong, the exact
 *     script that ran is the first thing anyone needs, and reconstructing it
 *     from the options is not the same as having it.
 *
 * Staged on /run, never in $TMPDIR. init_tmp() in the Vala core prefers
 * $TMPDIR then /var/tmp -- which, when restoring the RUNNING system, is on the
 * filesystem being overwritten. A script that deletes itself mid-run is not a
 * failure mode worth keeping.
 */

// ShellRunner runs generated scripts with bash.
type ShellRunner struct {
	// Runner streams the process output.
	Runner interface {
		Stream(ctx context.Context, argv []string, onLine func(stream, line string)) (int, error)
	}

	// Dir is where scripts are staged. Must not be on a filesystem the restore
	// is writing to.
	Dir string

	// Keep leaves the script files behind for inspection. On by default for a
	// restore: they are small, and they are the record of what ran.
	Keep bool

	seq int
}

// RunScript writes the script and runs it, streaming every line to onLine.
func (s *ShellRunner) RunScript(ctx context.Context, script string, onLine func(string)) (int, error) {

	dir := s.Dir
	if dir == "" {
		dir = "/run/timeshift"
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return -1, fmt.Errorf("restore: mkdir %s: %w", dir, err)
	}

	s.seq++
	path := filepath.Join(dir, fmt.Sprintf("restore-%d.sh", s.seq))

	/* 0700: the script names every path involved and runs as root. It is not
	 * secret, but it is not something an unprivileged process should be able to
	 * rewrite between the write and the exec. */
	if err := os.WriteFile(path, []byte("#!/bin/bash\n"+script), 0700); err != nil {
		return -1, fmt.Errorf("restore: write %s: %w", path, err)
	}
	if !s.Keep {
		defer os.Remove(path)
	}

	return s.Runner.Stream(ctx, []string{"bash", path}, func(_, line string) {
		onLine(line)
	})
}
