package main

import (
	"context"
	"encoding/json"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* snapshots.browse and snapshots.browse_release.
 *
 * The daemon mounts; the client opens. Opening a file manager needs the desktop
 * user's session -- their display, their bus, their own file manager -- and the
 * daemon may have none of that, so it hands back a path and stops there.
 *
 * A local repository needs no mount at all: the snapshot is already a directory
 * on a mounted filesystem. Only a remote one is sshfs-mounted, and the reason
 * the daemon has to do it is credentials -- the key that opens the repository
 * lives in /etc/timeshift/ssh and only root can read it, so the person at the
 * keyboard frequently cannot reach the host on their own.
 */

func (d *daemon) snapshotsBrowse(ctx context.Context, c *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.BrowseParams](params)
	if err != nil {
		return nil, err
	}
	if in.Snapshot == "" {
		return nil, ipc.Errf(ipc.CodeBadRequest, "browse needs a snapshot name")
	}

	repo, _, _, err := d.openRepo(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	defer repo.Close()

	snap, err := findSnapshot(ctx, repo, in.Snapshot)
	if err != nil {
		return nil, err
	}

	/* Who the mount is for.
	 *
	 * The caller may say, because the GUI runs as root under pkexec while the
	 * file manager it will spawn runs as the desktop user -- so root's own uid
	 * is exactly the wrong answer there. When it does not say, fall back to the
	 * peer's real uid, which is right for anyone talking to us directly. */
	uid, gid := in.UID, in.GID
	if uid == 0 && c != nil && c.Peer.UID != 0 {
		uid, gid = c.Peer.UID, c.Peer.GID
	}

	mount, err := repo.Browse(ctx, snap.Path, uid, gid)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}

	d.log.Info("snapshot opened for browsing",
		"snapshot", snap.Name, "path", mount.Path, "mounted", mount.Mounted, "uid", uid)

	return ipc.BrowseResult{
		Path:     mount.Path,
		Mounted:  mount.Mounted,
		Snapshot: snap.Name,
	}, nil
}

func (d *daemon) snapshotsBrowseRelease(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.BrowseReleaseParams](params)
	if err != nil {
		return nil, err
	}

	clean, ok := browseReleasePath(d.mountRoot, in.Path)
	if !ok {
		return nil, ipc.Errf(ipc.CodeBadRequest,
			"%s is not a browse mount this daemon made", in.Path)
	}

	/* Released without opening the repository.
	 *
	 * Unmounting needs a runner and a path; it does not need a connection, a
	 * backend, or the repository device mounted. Opening one here meant that
	 * unplugging the disk a snapshot was being browsed from made the release
	 * fail -- so the mount could never be cleaned up, in precisely the case
	 * that produces it. The path is already confined to <run>/browse/ by
	 * browseReleasePath above, which is what makes this safe to do directly.
	 */
	if err := tsengine.ReleaseBrowseMount(ctx, d.runner, clean); err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	d.log.Info("browse mount released", "path", clean)
	return ipc.BrowseResult{Path: clean}, nil
}

// findSnapshot resolves a name to the snapshot the repository holds.
func findSnapshot(ctx context.Context, repo engines.Repository, name string) (*engines.Snapshot, error) {
	list, err := repo.List(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	for i := range list {
		if list[i].Name == name {
			return &list[i], nil
		}
	}
	return nil, ipc.Errf(ipc.CodeNotFound, "no such snapshot: %s", name)
}

/* browseReleasePath accepts only a path this daemon could have mounted.
 *
 * Without it, browse_release is an unmount-anything method: hand it "/" and it
 * would try. Browse mounts live under <run>/browse/<digest> and nowhere else,
 * so requiring that prefix is both sufficient and exact.
 *
 * Symlinks are resolved first, so a link that merely LIVES in the browse
 * directory cannot stand in for a path inside it -- the check has to be about
 * where the target is, not where the name is. A path that does not resolve is
 * checked as written, which is correct for a mount point that has already gone.
 */
func browseReleasePath(mountRoot, requested string) (string, bool) {
	if requested == "" {
		return "", false
	}
	root := path.Clean(path.Join(mountRoot, "browse"))

	clean := path.Clean(requested)
	if resolved, err := filepath.EvalSymlinks(clean); err == nil {
		clean = resolved
	}

	// The browse directory itself is not a mount, so only paths BENEATH it
	// qualify. Accepting the root would mean accepting a request to unmount a
	// directory nothing ever mounted.
	if !strings.HasPrefix(clean, root+string(os.PathSeparator)) {
		return "", false
	}
	return clean, true
}
