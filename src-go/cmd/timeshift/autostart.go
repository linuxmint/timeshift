/*
 * autostart.go
 *
 * Copyright 2025 Timeshift contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* Bringing the daemon up when it is not there.
 *
 * Every mutating command goes through the daemon and has no in-process path --
 * only --list falls back to opening the repository itself. So "timeshiftd is
 * not running" is a total failure for --create, and --create is what
 * apt-snapshot-guard runs from a fail-closed hook that blocks dpkg.
 *
 * Until the cutover that was survivable, because the guard's fallback ran the
 * VALA binary, which needed no daemon at all. Once /usr/bin/timeshift is this
 * program, the fallback and the primary path are the same binary and the hook's
 * documented promise -- "it must never depend on the daemon being up" -- is only
 * true if this file makes it true.
 *
 * Socket activation covers the ordinary case: the socket unit is enabled with
 * the service, so connecting starts the daemon. It does not cover a masked
 * unit, a machine where the units were never enabled, or a container with no
 * systemd. Those are exactly the situations a recovery environment is.
 */

var (
	/* daemonBinary is where the daemon is installed.
	 *
	 * A var, not a const, so a test can point it at a stub -- and so a build
	 * running from the source tree can find its own daemon rather than the
	 * installed one. */
	daemonBinary = "/usr/libexec/timeshift/timeshiftd"

	// systemdMarker exists exactly when systemd is the running init.
	systemdMarker = "/run/systemd/system"

	/* socketWait bounds how long we wait for the socket to appear.
	 *
	 * The service is Type=notify, so `systemctl start` has already returned by
	 * the time we look; this budget is for the direct-spawn path, where there
	 * is nothing to synchronise against but the socket itself. */
	socketWait = 10 * time.Second
)

// errNoAutostart means we did not try, and the caller should report the daemon
// as absent in the ordinary way.
var errNoAutostart = errors.New("autostart not attempted")

/* autostartDaemon tries to make socket exist.
 *
 * It returns nil only when the socket is actually there afterwards -- starting
 * a unit is not the same as being able to talk to it, and reporting success on
 * the strength of an exit code would turn "the daemon is masked" into a
 * connection error further down.
 */
func autostartDaemon(socket string) error {
	/* Only root. A non-root caller cannot start a system daemon, and trying
	 * produces a confusing permission error in place of the message that
	 * actually tells them what to do. */
	if os.Geteuid() != 0 {
		return errNoAutostart
	}

	/* Only the compiled-in path.
	 *
	 * --socket names a daemon the caller is running themselves, usually a test
	 * one against a throwaway config. Starting the SYSTEM daemon because a
	 * private socket was missing would point the command at the real
	 * repository -- the same class of mistake as honouring an override on one
	 * path and not the other. */
	if socket != "" && socket != ipc.SocketPath {
		return errNoAutostart
	}

	if startViaSystemd() && waitForSocket(ipc.SocketPath) {
		return nil
	}
	if err := spawnDaemon(); err != nil {
		return err
	}
	if !waitForSocket(ipc.SocketPath) {
		return fmt.Errorf("started %s but %s never appeared", daemonBinary, ipc.SocketPath)
	}
	return nil
}

/* startViaSystemd asks systemd to bring the daemon up, preferring the socket.
 *
 * The socket unit first because that is the mechanism the units are built
 * around: it holds the listening fd, and the service starts on the first
 * connection. Starting the service directly also works and is the answer when
 * the socket unit is masked, so both are tried.
 *
 * Reports only whether a command succeeded. Whether that achieved anything is
 * decided by looking at the socket.
 */
func startViaSystemd() bool {
	if _, err := os.Stat(systemdMarker); err != nil {
		return false
	}
	systemctl, err := exec.LookPath("systemctl")
	if err != nil {
		return false
	}
	for _, unit := range []string{"timeshiftd.socket", "timeshiftd.service"} {
		cmd := exec.Command(systemctl, "start", unit)
		cmd.Stdout, cmd.Stderr = nil, nil
		if cmd.Run() == nil {
			return true
		}
	}
	return false
}

/* spawnDaemon runs the daemon directly, detached.
 *
 * The last resort, for a machine with no systemd or with the units masked. It
 * must outlive this process: the snapshot the caller is about to ask for
 * belongs to the daemon, and a daemon killed when the CLI exits would abandon
 * it. Setsid puts it in its own session so it survives, and so a Ctrl-C aimed
 * at the CLI does not reach it.
 */
func spawnDaemon() error {
	bin := daemonPath()
	if bin == "" {
		return fmt.Errorf("timeshiftd is not installed (looked for %s)", daemonBinary)
	}

	devnull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer devnull.Close()

	cmd := exec.Command(bin)
	// It writes to /var/log/timeshift; nothing should land on our stdout, which
	// may be a script reading --list output.
	cmd.Stdin, cmd.Stdout, cmd.Stderr = devnull, devnull, devnull
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("could not start %s: %w", bin, err)
	}
	/* Release it. Not waiting leaves a zombie only until we exit, which is
	 * moments away, and waiting would block for the daemon's whole lifetime. */
	go func() { _ = cmd.Wait() }()
	return nil
}

/* daemonPath finds the daemon, preferring one beside this executable.
 *
 * Same rule as the config override in Main.vala: a build running from the
 * source tree should use its own daemon, not the installed one, or testing a
 * change means installing it first.
 */
func daemonPath() string {
	if self, err := os.Executable(); err == nil {
		beside := filepath.Join(filepath.Dir(self), "timeshiftd")
		if isExecutable(beside) {
			return beside
		}
	}
	if isExecutable(daemonBinary) {
		return daemonBinary
	}
	return ""
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Mode().Perm()&0o111 != 0
}

// waitForSocket polls until the socket can be connected to, or the budget runs
// out. Connecting rather than stat-ing: a socket file left behind by a daemon
// that died is still a file.
func waitForSocket(path string) bool {
	deadline := time.Now().Add(socketWait)
	for {
		if c, err := ipc.Dial(path); err == nil {
			c.Close()
			return true
		} else if errors.Is(err, ipc.ErrNotPermitted) {
			// It is up; we are simply not allowed. Nothing to wait for.
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(50 * time.Millisecond)
	}
}
