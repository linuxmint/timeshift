package main

import (
	"context"
	"encoding/json"
	"os"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

/* recovery.*
 *
 * A thin wrapper over /usr/sbin/timeshift-recovery, and deliberately thin. The
 * recovery environment is its own package with its own release cycle, and the
 * Vala GUI shells out to the same tool. Reimplementing any of its logic here
 * would mean two things that must agree about what "installed" means, and the
 * one that drifted would be discovered by someone who needed to boot it.
 *
 * The tool being ABSENT is an ordinary state, not an error: timeshift-recovery
 * is a separate package that many installations will not have.
 */

// RecoveryTool is the provisioner, owned by the timeshift-recovery package.
const RecoveryTool = "/usr/sbin/timeshift-recovery"

func (d *daemon) recoveryStatus(ctx context.Context, _ *ipc.Conn, _ json.RawMessage) (any, error) {
	if _, err := os.Stat(RecoveryTool); err != nil {
		return ipc.RecoveryStatus{Available: false}, nil
	}

	/* --machine is the tool's own KEY=VALUE form. Parsing the human output
	 * would make its layout a protocol, which is exactly the coupling the
	 * machine-readable mode exists to avoid. */
	code, stdout, stderr, err := d.runner.Run(ctx, []string{RecoveryTool, "status", "--machine"}, "")
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	if code != 0 {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%s", firstLineOrDefault(stderr, "timeshift-recovery status failed"))
	}

	st := ipc.RecoveryStatus{Available: true, Fields: map[string]string{}}
	for _, line := range strings.Split(stdout, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok || k == "" {
			continue
		}
		st.Fields[k] = v
	}

	st.Installed = st.Fields["INSTALLED"] == "1"
	st.Disabled = st.Fields["DISABLED"] == "1"
	st.Stale = st.Fields["STALE"] == "1"
	st.HostVersion = st.Fields["HOST_VERSION"]
	st.EnvVersion = st.Fields["ENV_VERSION"]
	st.Target = st.Fields["TARGET_DEV"]
	return st, nil
}

// recoveryEnable and recoveryDisable are instant: they only add or remove the
// GRUB entry, leaving the payload in place.
func (d *daemon) recoveryEnable(ctx context.Context, c *ipc.Conn, params json.RawMessage) (any, error) {
	return d.recoveryVerb(ctx, "enable")
}

func (d *daemon) recoveryDisable(ctx context.Context, c *ipc.Conn, params json.RawMessage) (any, error) {
	return d.recoveryVerb(ctx, "disable")
}

func (d *daemon) recoveryVerb(ctx context.Context, verb string) (any, error) {
	if _, err := os.Stat(RecoveryTool); err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "the timeshift-recovery package is not installed")
	}
	code, stdout, stderr, err := d.runner.Run(ctx, []string{RecoveryTool, verb}, "")
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	if code != 0 {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%s",
			firstLineOrDefault(stderr, "timeshift-recovery "+verb+" failed"))
	}
	d.log.Info("recovery environment "+verb+"d", "output", firstLineOrDefault(stdout, ""))
	return ipc.RecoveryVerbResult{Verb: verb, OK: true}, nil
}

/* recovery.install is a JOB, unlike enable and disable.
 *
 * It runs mmdebstrap to build a whole root filesystem and can take many
 * minutes. A synchronous method would hold a connection open for the duration
 * and give the caller nothing to watch -- which is the shape of problem this
 * daemon exists to remove, not to reproduce.
 *
 * It is NOT a mutating job in the repository sense and does not take the write
 * lock: it writes /var/lib/timeshift-recovery and GRUB, not snapshots. Nothing
 * about a backup conflicts with it.
 */
func (d *daemon) recoveryInstall(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	if _, err := os.Stat(RecoveryTool); err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "the timeshift-recovery package is not installed")
	}

	in, err := decode[ipc.RecoveryInstallParams](params)
	if err != nil {
		return nil, err
	}

	argv := []string{RecoveryTool, "install"}
	if in.Target != "" {
		if strings.HasPrefix(in.Target, "-") {
			return nil, ipc.Errf(ipc.CodeBadRequest, "%q is not a target", in.Target)
		}
		argv = append(argv, "--target", in.Target)
	}
	if in.Size != "" {
		if strings.HasPrefix(in.Size, "-") {
			return nil, ipc.Errf(ipc.CodeBadRequest, "%q is not a size", in.Size)
		}
		argv = append(argv, "--size", in.Size)
	}

	job, err := d.queue.Submit(jobs.KindRecovery, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		r.SetPhases([]jobs.Phase{{Key: "recovery_install", Title: "Building the recovery environment"}})
		r.Phase("recovery_install")

		code, err := d.runner.Stream(ctx, argv, func(_, line string) {
			r.Log(line)
			r.Progress(jobs.Progress{StatusLine: line})
		})
		if err != nil {
			return jobs.OutcomeFailed, err
		}
		if code != 0 {
			return jobs.OutcomeFailed, ipc.Errf(ipc.CodeUnavailable,
				"timeshift-recovery install exited %d", code)
		}
		return jobs.OutcomeOK, nil
	})
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBusy, "%v", err)
	}
	return ipc.JobRef{Job: job.ID}, nil
}

func firstLineOrDefault(s, fallback string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return fallback
	}
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
