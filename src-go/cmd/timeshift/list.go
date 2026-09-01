package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/fsutil"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/textui"
)

/* `timeshift --list`.
 *
 * Reproduces AppConsole's "list-snapshots" case: the repository status block,
 * then the snapshot table, then a blank line. An empty repository prints "No
 * snapshots found" and the process exits 1 -- scripts rely on that, so it is
 * behaviour rather than an accident. */

// listSnapshots writes the status block and table, and reports whether any
// snapshot was found.
func listSnapshots(ctx context.Context, w io.Writer, repo engines.Repository, deviceName, deviceUUID string) (bool, error) {
	raw, err := repo.ConsoleStatus(ctx, deviceName, deviceUUID)
	if err != nil {
		return false, err
	}
	var view tsengine.StatusView
	if err := json.Unmarshal(raw, &view); err != nil {
		return false, err
	}

	var header strings.Builder
	tsengine.RenderStatus(&header, view)
	io.WriteString(w, header.String())

	snapshots, err := repo.List(ctx)
	if err != nil {
		return false, err
	}
	return renderSnapshotTable(w, snapshots), nil
}

// snapshotSize renders a Size or Unique cell.
//
// -1 means the size has not been computed yet, which is different from a
// snapshot measured at zero bytes; both render empty, exactly as
// size_formatted does for an uncomputed value.
func snapshotSize(n int64) string {
	if n < 0 {
		return ""
	}
	return fsutil.FormatSize(uint64(n), fsutil.DefaultSizeOpts())
}

// locationFromConfig defers to the engine, which owns these config keys.
func locationFromConfig(c config.Config, devices []*block.Device) (engines.Location, string, string, error) {
	return tsengine.LocationFromConfig(c, devices)
}

/* Listing through the daemon.
 *
 * Opening the repository in-process means MOUNTING it, at
 * /run/timeshift/<pid>, while the daemon very likely has it mounted too. A
 * second mount of the same filesystem is not itself corruption, but it makes
 * `--list` one more thing that leaves debris behind when killed, one more
 * ControlMaster against a remote host, and one more process that has to be
 * reasoned about when asking who is touching the repository.
 *
 * So ask the daemon when there is one. The in-process path stays as the
 * fallback, and is not a lesser path: a recovery environment, a masked unit, or
 * the moment during an upgrade before the daemon has started all have to keep
 * working. That is the same fail-open rule apt-snapshot-guard uses.
 *
 * Both paths render through RenderStatus and the same table builder, so the
 * output cannot drift between them -- which matters because this command's
 * output is byte-for-byte identical to the Vala binary's and is verified by
 * diffing the two.
 */
func listSnapshotsViaDaemon(socket string, w io.Writer, ov *ipc.LocationOverride) (found, served bool, err error) {
	c, derr := ipc.Dial(socket)
	if derr != nil {
		// No daemon. Not an error; the caller opens the repository itself.
		return false, false, nil
	}
	defer c.Close()

	/* A daemon speaking a different protocol is not used at all. Falling back
	 * to opening the repository here is correct and safe; talking to it anyway
	 * would mean an override it does not understand being silently ignored. */
	info, herr := c.Handshake()
	if herr != nil || info.ProtocolVersion != ipc.ProtocolVersion {
		return false, false, nil
	}

	var st ipc.RepoStatus
	if err := c.Call(ipc.MethodRepoStatus, ipc.RepoStatusParams{Location: ov}, &st); err != nil {
		return false, true, err
	}

	/* A daemon too old to send the header fields cannot serve this listing.
	 *
	 * Rendering what it did send would print "Device : Not Selected" over a
	 * perfectly good repository, which is worse than not using the daemon at
	 * all. Fall back to opening the repository ourselves -- the same fail-open
	 * rule as a daemon that is not running. Normally unreachable, since the
	 * unit is restarted on upgrade, but a daemon left running across one is
	 * exactly the case nobody tests. */
	if len(st.View) == 0 {
		return false, false, nil
	}

	var view tsengine.StatusView
	if err := json.Unmarshal(st.View, &view); err != nil {
		return false, true, err
	}

	var header strings.Builder
	tsengine.RenderStatus(&header, view)
	io.WriteString(w, header.String())

	var snapshots []engines.Snapshot
	if err := c.Call(ipc.MethodSnapshotsList, ipc.SnapshotsListParams{Location: ov}, &snapshots); err != nil {
		return false, true, err
	}

	return renderSnapshotTable(w, snapshots), true, nil
}

// renderSnapshotTable writes the snapshot table, and reports whether there was
// anything to write.
func renderSnapshotTable(w io.Writer, snapshots []engines.Snapshot) bool {
	if len(snapshots) == 0 {
		fmt.Fprintln(w, "No snapshots found")
		return false
	}

	rows := [][]string{{"Num", "", "Name", "Tags", "Size", "Unique", "Description"}}
	for i, s := range snapshots {
		rows = append(rows, []string{
			strconv.Itoa(i),
			">",
			s.Name,
			tsengine.TagListShort(s.Tags),
			snapshotSize(s.SizeBytes),
			snapshotSize(s.UnsharedBytes),
			s.Description,
		})
	}

	textui.Grid{
		Rows:       rows,
		RightAlign: []bool{false, false, false, false, true, true, false},
		HasHeader:  true,
	}.Render(w)

	fmt.Fprintln(w)
	return true
}

/* applyOverrideLocally mirrors the daemon's applyOverride for the fallback
 * path.
 *
 * Deliberately narrower: it does not resolve a device PATH to a UUID, because
 * doing that needs a scan and this path already has one available only later.
 * A path override on the fallback path is reported rather than silently
 * ignored -- see run() -- which is the difference between "not supported here"
 * and "supported and quietly wrong".
 */
func applyOverrideLocally(cfg config.Config, ov *ipc.LocationOverride) config.Config {
	if ov == nil {
		return cfg
	}
	switch {
	case ov.URL != "":
		cfg.BackupLocationType = "ssh"
		cfg.BackupSSHURL = ov.URL
		cfg.BtrfsMode = false
	case ov.DeviceUUID != "":
		cfg.BackupLocationType = "local"
		cfg.BackupDeviceUUID = ov.DeviceUUID
	}
	if ov.KeyFile != "" {
		cfg.BackupSSHKey = ov.KeyFile
	}
	if ov.Port != 0 {
		cfg.BackupSSHPort = ov.Port
	}
	if ov.BtrfsMode != nil {
		cfg.BtrfsMode = *ov.BtrfsMode
	}
	return cfg
}
