package main

import (
	"context"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* applyOverride is the translation half: an override becomes a config that was
 * never written down. The transmission half is tested in cmd/timeshift.
 *
 * Both halves were correct in isolation for the whole of protocol version 2.
 * What was missing was the wire between them, which is why these tests are
 * paired with the ones in the client and neither is sufficient alone.
 */

func configured() config.Config {
	return config.Config{
		BackupLocationType: "ssh",
		BackupSSHURL:       "backup@nas:/srv/snapshots",
		BackupSSHKey:       "/etc/timeshift/ssh/id_ed25519",
		BtrfsMode:          true,
	}
}

func TestNoOverrideChangesNothing(t *testing.T) {
	got, changed, err := applyOverride(context.Background(), nil, configured(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Error("an absent override reported a change")
	}
	want := configured()
	if got.BackupLocationType != want.BackupLocationType ||
		got.BackupSSHURL != want.BackupSSHURL ||
		got.BackupDeviceUUID != want.BackupDeviceUUID ||
		got.BtrfsMode != want.BtrfsMode {
		t.Errorf("the configuration was modified: %+v", got)
	}
}

/* A device override switches the location TYPE as well as the uuid. Setting
 * only the uuid would leave a remote configuration in place and the request
 * would go to the network. */
func TestADeviceOverrideSwitchesToThatLocalDevice(t *testing.T) {
	got, changed, err := applyOverride(context.Background(), nil, configured(),
		&ipc.LocationOverride{DeviceUUID: "1111-2222"})
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("a device override reported no change")
	}
	if got.BackupLocationType != "local" {
		t.Errorf("location type = %q, want local -- the request would still go to the remote", got.BackupLocationType)
	}
	if got.BackupDeviceUUID != "1111-2222" {
		t.Errorf("device uuid = %q", got.BackupDeviceUUID)
	}
}

/* btrfs snapshots cannot cross a filesystem, so a remote repository forces the
 * mode off. Someone who names a remote for one command has been explicit
 * enough that reporting a conflict would only be in the way. */
func TestAURLOverrideForcesBtrfsOff(t *testing.T) {
	got, _, err := applyOverride(context.Background(), nil, configured(),
		&ipc.LocationOverride{URL: "backup@other:/srv/other"})
	if err != nil {
		t.Fatal(err)
	}
	if got.BackupLocationType != "ssh" || got.BackupSSHURL != "backup@other:/srv/other" {
		t.Errorf("the url override did not take: %+v", got)
	}
	if got.BtrfsMode {
		t.Error("btrfs stayed on for a remote repository")
	}
}

/* --rsync has to be expressible. A plain bool cannot say it, because false is
 * also what "the caller said nothing" looks like -- which is why the field is
 * a pointer. */
func TestModeOverrideDistinguishesUnsetFromForcedOff(t *testing.T) {
	off := false
	got, changed, err := applyOverride(context.Background(), nil, configured(),
		&ipc.LocationOverride{BtrfsMode: &off})
	if err != nil {
		t.Fatal(err)
	}
	if !changed || got.BtrfsMode {
		t.Error("--rsync did not force btrfs off")
	}

	got, changed, err = applyOverride(context.Background(), nil, configured(),
		&ipc.LocationOverride{KeyFile: "/tmp/k"})
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("a key-file override reported no change")
	}
	if !got.BtrfsMode {
		t.Error("an override that said nothing about the mode turned it off anyway")
	}
}
