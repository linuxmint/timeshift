# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Desktop notifications, straight over D-Bus.

No libnotify and no notify-send: the tray already holds a session bus
connection, and OSDNotify.vala only shells out because it runs as root and has
to drop back to the desktop user first.
"""

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from .constants import (  # noqa: E402
    NOTIFICATIONS_IFACE,
    NOTIFICATIONS_NAME,
    NOTIFICATIONS_PATH,
    NOTIFY_APP_NAME,
    NOTIFY_DESKTOP_ENTRY,
)

URGENCY_LOW = 0
URGENCY_NORMAL = 1
URGENCY_CRITICAL = 2


class Notifier:
    def __init__(self, bus, on_default_action=None, log=None):
        self._bus = bus
        self._on_default_action = on_default_action
        self._log = log or (lambda *_a, **_k: None)
        self._supports_actions = False
        self._ids = {}          # key -> the server's notification id
        self._ours = set()
        self._signal_id = self._bus.signal_subscribe(
            NOTIFICATIONS_NAME, NOTIFICATIONS_IFACE, "ActionInvoked",
            NOTIFICATIONS_PATH, None, Gio.DBusSignalFlags.NONE,
            self._on_action_invoked)
        self._query_capabilities()

    def stop(self):
        if self._signal_id:
            self._bus.signal_unsubscribe(self._signal_id)
            self._signal_id = 0

    def _query_capabilities(self):
        def done(source, res):
            try:
                (caps,) = source.call_finish(res).unpack()
            except GLib.Error as err:
                self._log("GetCapabilities: %s", err.message)
                return
            self._supports_actions = "actions" in caps

        self._bus.call(NOTIFICATIONS_NAME, NOTIFICATIONS_PATH,
                       NOTIFICATIONS_IFACE, "GetCapabilities", None,
                       GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE, 5000,
                       None, done)

    def _on_action_invoked(self, _conn, _sender, _path, _iface, _signal,
                           params):
        notification_id, action = params.unpack()
        if notification_id in self._ours and action == "default":
            if self._on_default_action is not None:
                self._on_default_action()

    def send(self, summary, body, urgency=URGENCY_NORMAL, icon="timeshift",
             key=None, actions=True):
        """Show one notification.

        `key` replaces an earlier notification with the same key rather than
        stacking a second one -- a job that fails after a progress toast should
        update it, not queue behind it.
        """
        action_list = []
        if actions and self._supports_actions:
            action_list = ["default", "Open Timeshift"]
        hints = {
            "desktop-entry": GLib.Variant("s", NOTIFY_DESKTOP_ENTRY),
            "urgency": GLib.Variant("y", urgency),
        }
        replaces = self._ids.get(key, 0) if key else 0

        def done(source, res):
            try:
                (notification_id,) = source.call_finish(res).unpack()
            except GLib.Error as err:
                self._log("Notify: %s", err.message)
                return
            self._ours.add(notification_id)
            if key:
                self._ids[key] = notification_id

        self._bus.call(
            NOTIFICATIONS_NAME, NOTIFICATIONS_PATH, NOTIFICATIONS_IFACE,
            "Notify",
            GLib.Variant("(susssasa{sv}i)",
                         (NOTIFY_APP_NAME, replaces, icon, summary, body,
                          action_list, hints, -1)),
            GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 5000, None, done)
