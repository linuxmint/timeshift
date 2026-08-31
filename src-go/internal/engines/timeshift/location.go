package timeshift

import (
	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
)

// LocationFromConfig translates timeshift.json into an engine Location.
//
// This lives in the engine because those keys -- backup_location_type,
// backup_ssh_url, backup_device_uuid -- are this engine's own settings. A
// future engine brings its own, and the host does not have to learn them.
//
// Returns the location plus the device name and UUID for display, which are
// empty for a remote repository or a device that is not attached.
func LocationFromConfig(c config.Config, devices []*block.Device) (engines.Location, string, string, error) {
	loc := engines.Location{
		Name:      "default",
		Type:      c.BackupLocationType,
		BtrfsMode: c.BtrfsMode,
	}

	if c.Remote() {
		user, host, port, p, err := ParseURL(c.BackupSSHURL)
		if err != nil {
			return loc, "", "", err
		}
		if c.BackupSSHPort > 0 {
			// An explicit port in the config overrides one in the URL.
			port = c.BackupSSHPort
		}
		loc.SSH = engines.SSHLocation{
			User: user, Host: host, Port: port, Path: p,
			KeyFile:   c.BackupSSHKey,
			FakeSuper: c.BackupSSHFakeSuper,
		}
		loc.MountPath = p
		return loc, "", "", nil
	}

	loc.Type = "local"
	loc.DeviceUUID = c.BackupDeviceUUID

	dev := block.FindByUUID(devices, c.BackupDeviceUUID)
	if dev == nil {
		// Configured but not attached. The engine still opens and Status()
		// reports why it is unusable, rather than the caller guessing.
		return loc, "", "", nil
	}
	if len(dev.MountPoints) > 0 {
		loc.MountPath = dev.MountPoints[0].Path
	}
	return loc, dev.NameWithParent(), dev.UUID, nil
}
