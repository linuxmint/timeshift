# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Names, paths and protocol constants.

Everything here is a fact about something outside this program: the daemon's
socket and protocol, the D-Bus interfaces the desktop implements, and the paths
this package installs to. Nothing here makes a decision.
"""

VERSION = "1.0.0"

# --- the daemon ---------------------------------------------------------------

# Matches ipc.SocketPath (src-go/internal/ipc/protocol.go).
SOCKET_PATH = "/run/timeshift/daemon.sock"

# The directory the socket appears in. Watched so that "the daemon started" is
# noticed immediately instead of at the end of a backoff.
RUN_DIR = "/run/timeshift"

# Matches ipc.ProtocolVersion. Checked with STRICT equality, the way the Go CLI
# does (cmd/timeshift/jobs.go): a daemon speaking anything else is refused
# rather than half-understood, because JSON ignores fields it does not know and
# a partial understanding is indistinguishable from a working one.
PROTOCOL_VERSION = 3

# The group whose members may call the read-only methods.
GROUP = "timeshift"

METHOD_SYSTEM_INFO = "system.info"
METHOD_REPO_STATUS = "repo.status"
METHOD_SNAPSHOTS_LIST = "snapshots.list"
METHOD_SCHEDULE_STATUS = "schedule.status"
METHOD_JOBS_LIST = "jobs.list"
METHOD_JOBS_GET = "jobs.get"
METHOD_JOBS_SUBSCRIBE = "jobs.subscribe"

EVENT_STARTED = "job.started"
EVENT_PHASE = "job.phase"
EVENT_PROGRESS = "job.progress"
EVENT_FINISHED = "job.finished"
EVENT_CONFIG_CHANGED = "config.changed"
EVENT_SNAPSHOTS_CHANGED = "snapshots.changed"

# --- D-Bus --------------------------------------------------------------------

SNI_IFACE = "org.kde.StatusNotifierItem"
SNI_OBJECT_PATH = "/StatusNotifierItem"
SNI_BUS_NAME_PREFIX = "org.kde.StatusNotifierItem"

# Both spellings exist in the wild; whichever appears first is used.
WATCHER_NAMES = (
    "org.kde.StatusNotifierWatcher",
    "org.ayatana.StatusNotifierWatcher",
)
WATCHER_PATH = "/StatusNotifierWatcher"
WATCHER_IFACE = "org.kde.StatusNotifierWatcher"

DBUSMENU_IFACE = "com.canonical.dbusmenu"
DBUSMENU_OBJECT_PATH = "/MenuBar"

NOTIFICATIONS_NAME = "org.freedesktop.Notifications"
NOTIFICATIONS_PATH = "/org/freedesktop/Notifications"
NOTIFICATIONS_IFACE = "org.freedesktop.Notifications"

# Owned with DO_NOT_QUEUE so a second instance exits instead of waiting for a
# turn that never comes: autostart plus a manual launch must not draw two icons.
APP_BUS_NAME = "io.github.makeafide.timeshift_tray"

# The .desktop the notification server should credit. Deliberately the GUI's
# entry and not our own, which is NoDisplay: the toast should carry Timeshift's
# name and icon.
NOTIFY_APP_NAME = "Timeshift"
NOTIFY_DESKTOP_ENTRY = "timeshift-gtk"

# --- installed paths ----------------------------------------------------------

# Fixed-argument wrappers, which are what the polkit actions authorise. See
# actions.py for why they exist rather than pkexec'ing the CLI directly.
CREATE_SNAPSHOT_HELPER = "/usr/libexec/timeshift-tray/create-snapshot"
GRANT_ACCESS_HELPER = "/usr/libexec/timeshift-tray/grant-access"
REVOKE_ACCESS_HELPER = "/usr/libexec/timeshift-tray/revoke-access"

# What the create wrapper runs. /usr/bin/timeshift is the Go CLI since the
# consumer cutover, and every mutating command it has goes through timeshiftd.
TIMESHIFT_CLI = "/usr/bin/timeshift"

LAUNCHER = "timeshift-launcher"

# The 16px discs the menu's status rows carry as dbusmenu icon-data. PNG bytes
# rather than themed names because the host draws icon-data as it is, colour
# and all, where a themed symbolic name is recoloured to the menu text.
DOTS_DIR = "/usr/share/timeshift-tray/dots"

# --- tuning -------------------------------------------------------------------

SCHEDULE_POLL_SECONDS = 60
REPO_POLL_SECONDS = 15 * 60
SYSTEM_INFO_POLL_SECONDS = 60 * 60

# Redraw from data already held, so ages stay honest without any IPC.
TICK_SECONDS = 60

# Ask the daemon what is really running. The event stream is not a guarantee:
# a subscriber that falls behind is dropped, and a missed job.finished would
# otherwise leave the tray showing a backup that ended hours ago.
RECONCILE_SECONDS = 120

# A job younger than this is not swept by reconciliation even if the daemon's
# listing does not mention it: the listing may simply predate it.
RECONCILE_GRACE_SECONDS = 30

# How long a connection may be down before the icon stops claiming everything
# is fine. Long enough not to blink during an ordinary daemon restart.
DISCONNECTED_GRACE_SECONDS = 120

# How long to wait for a tray host before saying, in the journal, that there
# is not one. Long enough for a shell still starting up at login.
NO_HOST_WARN_SECONDS = 30

# A menu opened twice in quick succession should not mean two round trips to an
# SSH repository.
ABOUT_TO_SHOW_FLOOR_SECONDS = 30

# repo.status can block on an unreachable host for as long as SSH takes to give
# up. It runs on its own connection, and this is when we stop waiting for it.
REPO_STATUS_DEADLINE_SECONDS = 30

# How long "Create snapshot now" stays disabled after being clicked, if no
# job.started arrives -- the length of an unanswered polkit prompt.
CREATE_LATCH_SECONDS = 60

# Retry ladders, in seconds.
BACKOFF_LADDER = (1, 2, 4, 8, 16, 30)
# Neither group membership nor the daemon's protocol version can change without
# a login or a service restart, so retrying either quickly is pure noise.
BACKOFF_SLOW = 300
