package main

import (
	"context"
	"encoding/json"

	"strings"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* repo.ssh.* and repo.drop_master.
 *
 * The GUI's Location page needs all of these, and none of them existed. They
 * are kept separate from config.set on purpose: choosing a remote location is
 * one setting, but making it WORK is a sequence -- scan the host key, show its
 * fingerprint, generate a key, install it, prove it authenticates -- and each
 * step can fail in a way a person has to see.
 */

/* repo.ssh.scan_host fetches the remote's host key so its fingerprint can be
 * shown BEFORE any password is sent.
 *
 * Without this the first connection is trust-on-first-use with a password
 * already in flight, which is the moment a man in the middle is worth the most.
 */
func (d *daemon) repoSSHScanHost(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.SSHScanHostParams](params)
	if err != nil {
		return nil, err
	}
	if in.Host == "" {
		return nil, ipc.Errf(ipc.CodeBadRequest, "repo.ssh.scan_host needs a host")
	}

	hk, err := tsengine.ScanHostKey(ctx, d.runner, in.Host, in.Port)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	return ipc.SSHScanHostResult{Host: in.Host, Line: hk.Line, Fingerprint: hk.Fingerprint}, nil
}

/* repo.ssh.setup_key is the whole sequence, because the steps are only safe in
 * order and only meaningful together.
 *
 * Trusting the host key is a separate, explicit input: a client that has not
 * shown the fingerprint to anybody passes trust_host_key=false and gets a
 * refusal rather than silently accepting whatever answered.
 */
func (d *daemon) repoSSHSetupKey(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.SSHSetupKeyParams](params)
	if err != nil {
		return nil, err
	}

	cfg := d.config()
	backend, err := d.sshBackendFor(in.URL, in.KeyFile, in.Port, cfg)
	if err != nil {
		return nil, err
	}

	var res ipc.SSHSetupKeyResult

	if in.HostKeyLine != "" {
		if err := tsengine.TrustHostKey(tsengine.HostKey{Line: in.HostKeyLine}, ""); err != nil {
			return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
		}
		res.HostKeyTrusted = true
	}

	created, err := tsengine.EnsureKey(ctx, d.runner, backend.KeyFile)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	res.KeyCreated = created
	res.KeyFile = backend.KeyFile

	/* An already-working key needs no password and no install. Asking for one
	 * anyway is how a person concludes the feature is broken when it is
	 * already done. */
	if err := tsengine.VerifyKeyAuth(ctx, d.runner, backend); err == nil {
		res.AlreadyWorking = true
		res.Verified = true
		/* Tidy here too. The Vala flow had no already-working shortcut, so it
		 * reached the tidy on every press of the button; without this, a
		 * machine whose key already works can never clear the keys it left
		 * behind on an earlier install. */
		res.StaleKeysRemoved = d.tidyStaleKeys(ctx, backend)
		return res, nil
	}

	if err := tsengine.InstallPublicKey(ctx, d.runner, backend, in.Password); err != nil {
		return nil, ipc.Errf(ipc.CodeDenied, "%v", err)
	}
	res.Installed = true

	/* Required, not belt-and-braces: ssh-copy-id exits 0 even when the
	 * password was wrong and nothing was installed. */
	if err := tsengine.VerifyKeyAuth(ctx, d.runner, backend); err != nil {
		return nil, ipc.Errf(ipc.CodeDenied, "%v", err)
	}
	res.Verified = true

	res.StaleKeysRemoved = d.tidyStaleKeys(ctx, backend)

	d.log.Info("ssh key set up for the remote repository",
		"host", backend.Host, "key", backend.KeyFile, "created", created,
		"stale_keys_removed", res.StaleKeysRemoved)
	return res, nil
}

/* tidyStaleKeys removes this machine's superseded keys from the remote.
 *
 * Called only once the key in hand is proven to authenticate: removing the old
 * ones first would lock the account out if the new one turned out not to work.
 *
 * A failure is logged and swallowed. The setup itself succeeded, and reporting
 * it as failed would send someone chasing a key that is already installed and
 * working -- the tidy-up is hygiene, not part of the result. */
func (d *daemon) tidyStaleKeys(ctx context.Context, backend *tsengine.SSHBackend) int {
	removed, err := tsengine.RemoveStaleKeys(ctx, backend)
	if err != nil {
		d.log.Warn("could not tidy old keys on the remote host",
			"host", backend.Host, "error", err)
		return 0
	}
	if removed > 0 {
		d.log.Info("removed superseded keys from the remote host",
			"host", backend.Host, "count", removed)
	}
	return removed
}

// repo.ssh.test reports whether the configured location is reachable.
func (d *daemon) repoSSHTest(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.SSHTestParams](params)
	if err != nil {
		return nil, err
	}

	cfg := d.config()
	backend, err := d.sshBackendFor(in.URL, in.KeyFile, in.Port, cfg)
	if err != nil {
		return nil, err
	}

	if err := tsengine.VerifyKeyAuth(ctx, d.runner, backend); err != nil {
		return ipc.SSHTestResult{Host: backend.Host, OK: false, Message: err.Error()}, nil
	}
	return ipc.SSHTestResult{Host: backend.Host, OK: true, Message: "key-based login works"}, nil
}

/* repo.drop_master tears down the ssh ControlMaster.
 *
 * The restore script does this itself on a transport failure, because a client
 * attaching to a WEDGED master never calls connect(2) and so ConnectTimeout
 * never applies -- it waits forever on a connection that is already dead. This
 * exposes the same escape hatch to a person watching the GUI.
 */
func (d *daemon) repoDropMaster(ctx context.Context, _ *ipc.Conn, _ json.RawMessage) (any, error) {
	repo, _, _, err := d.openRepoFor(ctx, nil)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	defer repo.Close()

	dropped, err := repo.DropMaster(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	if dropped {
		d.log.Info("dropped the ssh control master")
	}
	return ipc.DropMasterResult{Dropped: dropped}, nil
}

/* sshBackendFor builds a backend from an explicit URL, or from the configured
 * location when none is given.
 *
 * An explicit URL is how the Location page tests credentials for a repository
 * that has not been saved yet -- refusing to answer until the setting is
 * committed would mean saving a broken location to find out it is broken.
 */
func (d *daemon) sshBackendFor(url, keyFile string, port int, cfg config.Config) (*tsengine.SSHBackend, error) {
	if url == "" {
		url = cfg.BackupSSHURL
		if keyFile == "" {
			keyFile = cfg.BackupSSHKey
		}
		if port == 0 {
			port = cfg.BackupSSHPort
		}
	}
	if url == "" {
		return nil, ipc.Errf(ipc.CodeBadRequest, "no remote location is configured, and none was given")
	}

	user, host, urlPort, remotePath, err := tsengine.ParseURL(url)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
	}
	if port == 0 {
		port = urlPort
	}
	if keyFile == "" {
		keyFile = tsengine.DefaultKeyFile()
	}

	return &tsengine.SSHBackend{
		Runner:  d.runner,
		User:    user,
		Host:    host,
		Port:    port,
		Path:    remotePath,
		KeyFile: keyFile,
	}, nil
}

/* repo.select chooses where snapshots are stored, and refuses a place that
 * cannot hold them.
 *
 * Kept separate from config.set even though it writes the same keys, because
 * the validation is the point. config.set will happily record a device that is
 * a whole disk, or has partitions on it, or has no Linux filesystem -- and the
 * first anyone hears of it is a backup that fails. Checking first turns that
 * into an answer at the moment the choice is made.
 *
 * A dry run reports the verdict without writing anything, which is what a
 * Location page wants as the person clicks around a device list.
 */
func (d *daemon) repoSelect(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.RepoSelectParams](params)
	if err != nil {
		return nil, err
	}

	cfg := d.config()
	res := ipc.RepoSelectResult{}

	switch {
	case in.URL != "":
		if _, _, _, _, err := tsengine.ParseURL(in.URL); err != nil {
			return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
		}
		/* btrfs mode and a remote repository are mutually exclusive, and the
		 * Vala config loader turned btrfs off SILENTLY on load -- so somebody
		 * who chose both got rsync snapshots and was never told. Report it. */
		if cfg.BtrfsMode {
			return nil, ipc.Errf(ipc.CodeBadRequest, "%v", tsengine.ErrBtrfsRemote)
		}
		res.Type = "ssh"
		res.URL = in.URL
		res.Usable = true

	case in.DeviceUUID != "" || in.Device != "":
		scanner := &block.Scanner{Runner: d.runner}
		devices, err := scanner.Scan(ctx)
		if err != nil {
			return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
		}

		var dev *block.Device
		if in.DeviceUUID != "" {
			dev = block.FindByUUID(devices, in.DeviceUUID)
		} else {
			dev = block.FindByPath(devices, in.Device)
		}
		if dev == nil {
			return nil, ipc.Errf(ipc.CodeNotFound, "no such device")
		}

		res.Type = "local"
		res.Device = dev.Path
		res.DeviceUUID = dev.UUID

		if why := unusableAsRepository(dev, cfg.BtrfsMode); why != "" {
			res.Usable = false
			res.Reason = why
			return res, nil
		}
		res.Usable = true

	default:
		return nil, ipc.Errf(ipc.CodeBadRequest, "repo.select needs a device or a URL")
	}

	if in.DryRun {
		return res, nil
	}

	values := map[string]json.RawMessage{}
	set := func(k, v string) {
		raw, _ := json.Marshal(v)
		values[k] = raw
	}

	if res.Type == "ssh" {
		set("backup_location_type", "ssh")
		set("backup_ssh_url", res.URL)
	} else {
		set("backup_location_type", "local")
		set("backup_device_uuid", res.DeviceUUID)
	}

	raw, _ := json.Marshal(ipc.ConfigSetParams{Values: values})
	if _, err := d.configSet(ctx, nil, raw); err != nil {
		return nil, err
	}
	res.Saved = true

	d.log.Info("backup location selected",
		"type", res.Type, "device", res.Device, "url", res.URL)
	return res, nil
}

/* unusableAsRepository names why a device cannot hold snapshots, or "" if it
 * can. Reproduces Main.check_device_for_backup(), whose answer was a boolean --
 * which is why the GUI could only say "no" without saying why.
 */
func unusableAsRepository(d *block.Device, btrfsMode bool) string {
	if d.Type == "disk" {
		return "this is a whole disk; choose a partition on it"
	}
	if len(d.Children) > 0 {
		return "this device holds partitions or volumes; choose one of them"
	}
	if btrfsMode {
		if d.FSType != "btrfs" && !strings.Contains(d.FSType, "luks") {
			return "btrfs mode needs a btrfs filesystem"
		}
		return ""
	}
	if !d.HasLinuxFilesystem() {
		return "no Linux filesystem here; snapshots need one that can store ownership and permissions"
	}
	return ""
}
