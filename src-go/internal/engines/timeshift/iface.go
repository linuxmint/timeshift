package timeshift

import (
	"context"
	"encoding/json"
	"path"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

/* The engine seam.
 *
 * Everything the host asks of a repository goes through engines.Repository.
 * That interface used to carry four read methods, and every write -- create,
 * delete, estimate, tag -- was reached by asserting past it:
 *
 *   repo, ok := repository.(*tsengine.Repo)
 *   if !ok { return fmt.Errorf("engine %q is not the timeshift engine", ...) }
 *
 * which made the interface decoration. There is no second engine planned, so
 * this is not about enabling one; it is so that new work is written against the
 * interface rather than accreting onto the concrete type, where it would have
 * to be untangled later by someone with less context.
 *
 * The methods here are the adapters that make the concrete Repo fit: the
 * operations themselves live beside their own code.
 */

// Repo implements the full repository interface.
//
// The compile-time assertion is the point: adding a method to the interface
// must break this build rather than break a caller at runtime.
var _ engines.Repository = (*Repo)(nil)

// ConsoleStatus renders the engine's header fields as opaque JSON.
//
// Opaque because a location's description is engine-shaped -- a device and a
// UUID and "Mode: RSYNC" here, something else entirely for another engine --
// and the host has no business knowing which. Whoever renders it decodes it
// with this package's StatusView, so there is one definition of the shape.
func (r *Repo) ConsoleStatus(ctx context.Context, deviceName, deviceUUID string) (json.RawMessage, error) {
	view, err := r.StatusView(ctx, deviceName, deviceUUID)
	if err != nil {
		return nil, err
	}
	return json.Marshal(view)
}

// ReadSnapshotFile reads one file from inside a snapshot.
//
// Through the backend rather than os.ReadFile, so it works for a remote
// repository -- the restore path reads the snapshot's own fstab this way.
func (r *Repo) ReadSnapshotFile(ctx context.Context, snapshotPath, name string) ([]byte, error) {
	return r.Backend.ReadFile(ctx, path.Join(snapshotPath, name))
}

// TransferSource describes how to read a snapshot's payload.
//
// The three values travel together because they are only correct together: a
// remote source needs its host prefix AND its transport AND, when the far side
// cannot preserve ownership as itself, its --rsync-path. Handing them out
// separately is how a caller ends up with a host-prefixed --link-dest, which
// rsync resolves on the receiving side and silently gets wrong.
func (r *Repo) TransferSource(payloadPath string) engines.TransferSource {
	return engines.TransferSource{
		Path:            r.RsyncSource(payloadPath),
		RSH:             r.RsyncRSH(),
		RemoteShellPath: r.RsyncPath(),
	}
}

// SetFirstSnapshotSize supplies the estimate used to judge free space on a
// repository that holds no snapshots yet.
func (r *Repo) SetFirstSnapshotSize(n uint64) { r.FirstSnapshotSize = n }

// DropMaster tears down the ssh ControlMaster, if there is one.
//
// A local repository has no transport to drop, and reports false rather than
// pretending it did something.
func (r *Repo) DropMaster(ctx context.Context) (bool, error) {
	ssh, ok := r.Backend.(*SSHBackend)
	if !ok || ssh.ControlPath == "" {
		return false, nil
	}
	argv := append([]string{"ssh"}, ssh.SSHOptions(false, false)...)
	argv = append(argv, "-O", "exit", ssh.HostSpec())

	/* A master that is already gone makes ssh exit non-zero, and that is not a
	 * failure: the caller wanted no master and there is none. Only an
	 * inability to run ssh at all is worth reporting. */
	if _, _, _, err := r.Deps.Runner.Run(ctx, argv, ""); err != nil {
		return false, err
	}
	return true, nil
}
