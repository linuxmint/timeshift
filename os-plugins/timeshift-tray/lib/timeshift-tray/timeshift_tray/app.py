# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Wiring: build the real collaborators, hand them to the controller, run.

Every decision lives in controller.py. What is left here is the parts that can
only be done against a real session bus and a real main loop -- and the startup
and shutdown order, which is the one thing a test cannot check.
"""

import os
import signal
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import icons, menutree, notify  # noqa: E402
from .actions import Spawner  # noqa: E402
from .constants import (  # noqa: E402
    APP_BUS_NAME,
    DBUSMENU_OBJECT_PATH,
    DOTS_DIR,
    NO_HOST_WARN_SECONDS,
    PROTOCOL_VERSION,
    SOCKET_PATH,
    VERSION,
)
from .controller import Controller, ITEM_TITLE  # noqa: E402
from .daemonclient import DaemonClient  # noqa: E402
from .dbusmenu import DBusMenu  # noqa: E402
from .model import ConnState, Health  # noqa: E402
from .sni import StatusNotifierItem  # noqa: E402

ITEM_ID = "timeshift-tray"

USAGE = """\
Usage: timeshift-tray [OPTION...]

  Shows Timeshift's status in the desktop's system tray: when the last
  snapshot was taken, whether scheduled snapshots are running, whether the
  snapshot location is reachable, and live progress for any snapshot the
  machine is taking. Runs as your own user and never as root.

Options:
  --debug      log what it is doing to stderr
  --version    print the version and exit
  --help       print this and exit

Environment:
  TIMESHIFT_TRAY_DEBUG=1           the same as --debug
  TIMESHIFT_TRAY_ICONS=auto|symbolic|colour
               panel icon style; "auto" (the default) is monochrome until
               something needs attention, then the coloured shield

  Reading Timeshift's status requires membership of the "timeshift" group;
  the applet's menu offers to arrange it.
"""


class GLibTimers:
    """The controller's clock, in terms GLib understands.

    A port rather than a direct call so a test can drive every timeout without
    waiting for one.
    """

    def __init__(self, log=None):
        self._log = log or (lambda *_a, **_k: None)

    def every(self, seconds, callback):
        def fire():
            # A repeating source whose callback raises is removed by GLib, so
            # without this the applet silently stops ticking: ages freeze at
            # "2 hours ago" and the scheduler warning never fires again.
            try:
                callback()
            except Exception:  # noqa: BLE001
                import traceback
                self._log("timer raised:\n%s", traceback.format_exc().rstrip())
            return GLib.SOURCE_CONTINUE

        return GLib.timeout_add_seconds(seconds, fire)

    def once(self, seconds, callback):
        return GLib.timeout_add_seconds(seconds, self._oneshot(callback))

    def once_ms(self, milliseconds, callback):
        return GLib.timeout_add(milliseconds, self._oneshot(callback))

    def _oneshot(self, callback):
        def fire():
            try:
                callback()
            except Exception:  # noqa: BLE001
                import traceback
                self._log("timer raised:\n%s", traceback.format_exc().rstrip())
            return GLib.SOURCE_REMOVE

        return fire

    def cancel(self, handle):
        if handle:
            GLib.source_remove(handle)


def load_dots(folder, log):
    """The menu's status discs, read once. A missing file costs that row its
    dot and nothing else; the transport drops an icon-data it has no bytes
    for."""
    out = {}
    for key in menutree.ALL_DOTS:
        path = os.path.join(folder, key + ".png")
        try:
            with open(path, "rb") as handle:
                out[key] = handle.read()
        except OSError as err:
            log("dot %s: %s", key, err)
    return out


class TrayApp:
    def __init__(self, bus, socket_path=SOCKET_PATH, debug=False,
                 spawn_fn=None, icon_style=icons.STYLE_AUTO):
        self._debug = debug
        self._loop = GLib.MainLoop()
        self._name_id = 0
        self._name_owned = False
        self._signal_ids = []
        self._no_host_handle = None

        timers = GLibTimers(log=self.log)
        menu = DBusMenu(bus, DBUSMENU_OBJECT_PATH, self._on_action,
                        on_about_to_show=self._on_about_to_show, log=self.log,
                        icon_data=load_dots(DOTS_DIR, self.log))
        item = StatusNotifierItem(
            bus, DBUSMENU_OBJECT_PATH, ITEM_ID, ITEM_TITLE,
            icons.icon_for(Health.OK), icons.ATTENTION_ICON,
            on_secondary_activate=self._on_secondary_activate, log=self.log)
        client = DaemonClient(self._on_conn_state, self._on_event,
                              socket_path=socket_path, log=self.log)

        self.item = item
        self.controller = Controller(
            client=client, menu=menu, item=item,
            notifier=notify.Notifier(bus, on_default_action=self._open_gui,
                                     log=self.log),
            spawner=Spawner(log=self.log, spawn_fn=spawn_fn),
            timers=timers, log=self.log, on_quit=self.quit,
            icon_style=icon_style)
        self._timers = timers

    # -- logging ---------------------------------------------------------------

    def log(self, message, *args):
        if self._debug:
            self.say(message % args if args else message)

    def say(self, message):
        """Unconditional, for the handful of things a user must be able to see.

        Everything else is --debug. These are the states where the icon is
        absent or useless, so the journal is the only place left to explain
        why.
        """
        sys.stderr.write("timeshift-tray: %s\n" % message)
        sys.stderr.flush()

    # -- lifecycle -------------------------------------------------------------

    def run(self):
        """Run the loop. Nothing is exported until the bus name is acquired."""
        for sig in (signal.SIGTERM, signal.SIGINT):
            self._signal_ids.append(GLib.unix_signal_add(
                GLib.PRIORITY_DEFAULT, sig, self._on_signal))
        try:
            self._loop.run()
        except KeyboardInterrupt:
            # Ctrl-C is a request, not a crash; exiting non-zero would be
            # journalled as one.
            self.quit()
        return 0

    def start_serving(self):
        """Called once this process knows it is the only instance."""
        self.item.export()
        self.controller.start()
        self._no_host_handle = self._timers.once(
            NO_HOST_WARN_SECONDS, self._check_for_host)

    def _on_signal(self):
        self.quit()
        return GLib.SOURCE_REMOVE

    def quit(self):
        if self._no_host_handle is not None:
            self._timers.cancel(self._no_host_handle)
            self._no_host_handle = None
        self.controller.stop()
        self.item.stop()
        self.controller.menu.unexport()
        self.controller.notifier.stop()
        # Only a name we actually hold. Releasing one we never acquired --
        # which is exactly the case for the instance that lost the race -- is
        # answered with NOT_OWNER and a GLib warning on the way out.
        if self._name_id and self._name_owned:
            Gio.bus_unown_name(self._name_id)
        self._name_id = 0
        self._loop.quit()

    def own_name(self, name_id):
        """Remember the bus name so quit() can give it back."""
        self._name_id = name_id

    def name_acquired(self):
        self._name_owned = True

    def _check_for_host(self):
        self._no_host_handle = None
        if self.item.registered:
            return
        message = self.controller.warn_no_host()
        if message:
            self.say(message)

    # -- callbacks into the controller ----------------------------------------

    def _on_conn_state(self, state):
        self.controller.on_conn_state(state)
        self._explain(state)

    def _explain(self, state):
        """Say the terminal states out loud, whatever --debug says."""
        if state is ConnState.NO_ACCESS:
            self.say("not permitted to read %s; this account is not in the "
                     "\"timeshift\" group. Use the tray menu's \"Enable status "
                     "access\", or: sudo gpasswd -a $USER timeshift"
                     % SOCKET_PATH)
        elif state is ConnState.PROTOCOL_MISMATCH:
            # Name the side that is behind. The advice was always "restart the
            # service", which is wrong exactly when the applet is the older
            # one -- the common case, because the two ship in separate
            # packages and this one is upgraded second.
            daemon = self.controller.client.daemon_protocol
            fix = ("restart this applet after upgrading"
                   if daemon > PROTOCOL_VERSION
                   else "restart the Timeshift service after upgrading")
            self.say("the Timeshift service speaks protocol %d and this applet "
                     "speaks %d; %s" % (daemon, PROTOCOL_VERSION, fix))

    def _on_event(self, event):
        self.controller.on_event(event)

    def _on_action(self, action):
        self.controller.on_action(action)

    def _on_about_to_show(self, item_id):
        self.controller.on_about_to_show(item_id)

    def _on_secondary_activate(self):
        self._open_gui()

    def _open_gui(self):
        self.controller.open_gui()


def main(argv):
    if "--help" in argv or "-h" in argv:
        sys.stdout.write(USAGE)
        return 0
    if "--version" in argv:
        sys.stdout.write("timeshift-tray %s\n" % VERSION)
        return 0

    debug = "--debug" in argv or os.environ.get("TIMESHIFT_TRAY_DEBUG") == "1"
    # symbolic | colour | auto. The default paints the panel only for trouble.
    icon_style = icons.parse_style(os.environ.get("TIMESHIFT_TRAY_ICONS"))
    unknown = [a for a in argv if a not in ("--debug",)]
    if unknown:
        sys.stderr.write("timeshift-tray: unrecognised argument: %s\n"
                         % unknown[0])
        sys.stderr.write(USAGE)
        return 2

    if os.geteuid() == 0:
        sys.stderr.write(
            "timeshift-tray: this is a desktop applet and must not run as "
            "root; it talks to timeshiftd as an unprivileged client.\n")
        return 0

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as err:
        # No session bus is an ordinary state for an autostart entry -- in a
        # console login there is nothing to draw on and nothing to draw. Not a
        # failure, so not a non-zero exit that gets journalled as a crash.
        sys.stderr.write("timeshift-tray: no session bus (%s); not starting\n"
                         % err.message)
        return 0

    # An env var rather than a flag: this is a test hook, the same shape
    # apt-snapshot-guard's TS_SOCKET has, and it does not belong in --help.
    app = TrayApp(bus, socket_path=os.environ.get("TIMESHIFT_TRAY_SOCKET",
                                                  SOCKET_PATH),
                  debug=debug, icon_style=icon_style)

    def acquired(_conn, _name):
        app.name_acquired()
        app.start_serving()

    def lost(_conn, _name):
        # Decided HERE rather than sampled by a timeout: a second instance used
        # to draw an icon, connect to the daemon and only then check a flag,
        # and if RequestName took longer than the timeout -- which login is
        # exactly when it might -- both instances ran forever.
        sys.stderr.write("timeshift-tray: already running\n")
        app.quit()

    name_id = Gio.bus_own_name_on_connection(
        bus, APP_BUS_NAME, Gio.BusNameOwnerFlags.DO_NOT_QUEUE, acquired, lost)
    app.own_name(name_id)

    # Nothing is exported and no connection is made until `acquired` fires, so
    # a second instance never draws an icon, never registers with the watcher
    # and never touches the daemon -- it just exits.
    return app.run()
