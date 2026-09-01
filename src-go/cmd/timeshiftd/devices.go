package main

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* devices.unlock.
 *
 * This is what finally retires the `Gtk.Window? parent_window` threaded through
 * restore_snapshot(), mount_target_devices() and all five SnapshotRepo
 * constructors -- a parameter that existed purely so the core could raise a
 * LUKS passphrase dialog. The core no longer asks anybody anything: a client
 * that can reach a person collects the passphrase and sends it.
 *
 * The passphrase reaches cryptsetup on stdin, never in argv, and is never
 * logged. Nothing here puts the params into a log line either, because
 * "%v" on the params struct would print it.
 */
func (d *daemon) devicesUnlock(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.DeviceUnlockParams](params)
	if err != nil {
		return nil, err
	}

	if in.Device == "" {
		return nil, ipc.Errf(ipc.CodeBadRequest, "devices.unlock needs a device")
	}

	scanner := &block.Scanner{Runner: d.runner}
	devices, err := scanner.Scan(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}

	target := block.FindByPath(devices, in.Device)
	if target == nil {
		return nil, ipc.Errf(ipc.CodeNotFound, "no such device: %s", in.Device)
	}

	unlocker := &block.Unlocker{Runner: d.runner}
	mapper, alreadyOpen, err := unlocker.Unlock(ctx, devices, target, in.Name, in.Passphrase)
	switch {
	case errors.Is(err, block.ErrNotEncrypted):
		return nil, ipc.Errf(ipc.CodeBadRequest, "%s is not an encrypted device", target.Path)
	case errors.Is(err, block.ErrNoPassphrase):
		/* Named distinctly so a client can tell "ask the person again" from
		 * "this will never work". A daemon has no terminal to prompt on. */
		return nil, ipc.Errf(ipc.CodeBadRequest, "a passphrase is required to unlock %s", target.Path)
	case errors.Is(err, block.ErrWrongPassphrase):
		return nil, ipc.Errf(ipc.CodeDenied, "wrong passphrase for %s", target.Path)
	case err != nil:
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}

	/* Rescan: the mapper device did not exist a moment ago, and the caller
	 * wants the device rather than its name. */
	after, err := scanner.Scan(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	unlocked := block.FindByPath(after, mapper)

	d.log.Info("luks container unlocked",
		"device", target.Path, "mapper", mapper, "already_open", alreadyOpen)

	res := ipc.DeviceUnlockResult{
		Device:      target.Path,
		MappedName:  mapper,
		AlreadyOpen: alreadyOpen,
	}
	if unlocked != nil {
		res.Path = unlocked.Path
		res.UUID = unlocked.UUID
		res.FSType = unlocked.FSType
	}
	return res, nil
}

// devicesLock closes a container this daemon or anyone else opened.
func (d *daemon) devicesLock(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.DeviceLockParams](params)
	if err != nil {
		return nil, err
	}

	if in.Name == "" {
		return nil, ipc.Errf(ipc.CodeBadRequest, "devices.lock needs a mapper name")
	}

	unlocker := &block.Unlocker{Runner: d.runner}
	if err := unlocker.Lock(ctx, in.Name); err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	d.log.Info("luks container locked", "mapper", in.Name)
	return ipc.DeviceLockResult{Name: in.Name}, nil
}
