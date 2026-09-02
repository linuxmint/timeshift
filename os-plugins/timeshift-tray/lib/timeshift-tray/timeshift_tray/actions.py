# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Everything this applet runs, and the only place an argv is written.

Both privileged actions go through pkexec to a fixed-argument wrapper rather
than to the Timeshift CLI directly. A polkit exec action authorises the
PROGRAM, not the arguments, so pointing an auth_admin_keep action at
/usr/libexec/timeshift/timeshift would grant five unauthenticated minutes of a
binary that also implements --delete, --delete-all and --restore. The wrappers
take no arguments at all, so the grant is exactly what it says.

Keeping the argv lists here, as data, is also what lets a test assert them:
this is a security invariant, not a style preference.
"""

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from .constants import (  # noqa: E402
    CREATE_SNAPSHOT_HELPER,
    GRANT_ACCESS_HELPER,
    LAUNCHER,
    REVOKE_ACCESS_HELPER,
)

PKEXEC = "pkexec"

CREATE_SNAPSHOT_ARGV = [PKEXEC, CREATE_SNAPSHOT_HELPER]
GRANT_ACCESS_ARGV = [PKEXEC, GRANT_ACCESS_HELPER]
REVOKE_ACCESS_ARGV = [PKEXEC, REVOKE_ACCESS_HELPER]
OPEN_TIMESHIFT_ARGV = [LAUNCHER]


class Spawner:
    """Runs a command and forgets about it, except for its exit status."""

    def __init__(self, log=None, spawn_fn=None):
        self._log = log or (lambda *_a, **_k: None)
        self._spawn_fn = spawn_fn or self._default_spawn
        self.activation_token = ""

    def run(self, argv, on_exit=None):
        """Start argv detached. on_exit(ok, message) when it finishes."""
        self._log("spawn: %s", " ".join(argv))
        try:
            self._spawn_fn(list(argv), self.activation_token, on_exit)
        except GLib.Error as err:
            self._log("spawn failed: %s", err.message)
            if on_exit is not None:
                on_exit(False, err.message)

    def _default_spawn(self, argv, token, on_exit):
        # stderr is PIPED, not silenced: every diagnostic the wrappers write
        # went to /dev/null, so "the timeshift group does not exist" and "the
        # helper is not installed" both presented as the menu item doing
        # nothing at all.
        launcher = Gio.SubprocessLauncher.new(
            Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_PIPE)
        if token:
            launcher.setenv("XDG_ACTIVATION_TOKEN", token, True)
            launcher.setenv("DESKTOP_STARTUP_ID", token, True)
        process = launcher.spawnv(argv)

        def reaped(source, res):
            try:
                _ok, _out, errtext = source.communicate_utf8_finish(res)
            except GLib.Error as err:
                if on_exit is not None:
                    on_exit(False, err.message)
                return
            status = source.get_exit_status()
            if on_exit is not None:
                on_exit(status == 0, _last_line(errtext))

        # Always waited on, even with no callback: an unreaped child is a
        # zombie for the life of the session.
        process.communicate_utf8_async(None, None, reaped)


def _last_line(text):
    """The most specific thing the helper said before giving up."""
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return lines[-1] if lines else ""
