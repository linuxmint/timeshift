# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""org.kde.StatusNotifierItem, exported by hand.

Four things here are decisions rather than transcription, each checked against
the host this desktop actually runs:

  * `Activate` is deliberately NOT exported. GNOME's indicator support probes
    for it, and when it is present every left-click waits out the
    double-click interval before opening the menu. Without it the menu opens at
    once, which is what a status menu should do.

  * `Status` must never be "Passive": the host reads that as "hide the icon",
    and its proxy pre-seeds the value, so the first GetAll has to answer
    correctly. Even with no access the icon stays, because a tray icon that
    vanishes when something is wrong cannot be used to find out what.

  * `Id` and `Menu` are required. The host will not consider the item ready
    without both, and an item that is never ready is never drawn.

  * Changes are announced BOTH as the legacy New* signals and as
    PropertiesChanged. GDBus does not emit the latter for a hand-registered
    object, so it is emitted explicitly; between them, every host in use
    notices.
"""

import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import gcompat  # noqa: E402
from .constants import (  # noqa: E402
    SNI_BUS_NAME_PREFIX,
    SNI_IFACE,
    SNI_OBJECT_PATH,
    WATCHER_IFACE,
    WATCHER_NAMES,
    WATCHER_PATH,
)

SNI_XML = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconThemePath" type="s" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <method name="ContextMenu">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
    </method>
    <method name="SecondaryActivate">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
    </method>
    <method name="Scroll">
      <arg type="i" name="delta" direction="in"/>
      <arg type="s" name="orientation" direction="in"/>
    </method>
    <method name="ProvideXdgActivationToken">
      <arg type="s" name="token" direction="in"/>
    </method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewOverlayIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus">
      <arg type="s" name="status"/>
    </signal>
    <signal name="NewIconThemePath">
      <arg type="s" name="icon_theme_path"/>
    </signal>
  </interface>
</node>
"""

STATUS_ACTIVE = "Active"
STATUS_ATTENTION = "NeedsAttention"


class StatusNotifierItem:
    """One tray item, and its registration with whatever watcher shows up."""

    def __init__(self, bus, menu_path, item_id, title, icon_name,
                 attention_icon_name, on_secondary_activate=None, log=None):
        self._bus = bus
        self._menu_path = menu_path
        self._id = item_id
        self._title = title
        self._icon_name = icon_name
        self._attention_icon_name = attention_icon_name
        self._status = STATUS_ACTIVE
        self._tooltip_title = title
        self._tooltip_body = ""
        self._tooltip_icon = ""
        self._on_secondary_activate = on_secondary_activate
        self._log = log or (lambda *_a, **_k: None)

        self.activation_token = ""
        # Whether a watcher has accepted us. The applet reports "no tray host"
        # from this rather than from whether a watcher NAME exists, because a
        # watcher that refuses the registration looks the same to the user.
        self.registered = False
        self._bus_name = "%s-%d-1" % (SNI_BUS_NAME_PREFIX, os.getpid())
        self._name_id = 0
        self._watch_ids = []
        self._registration = 0
        self._watcher_owner = None
        self._host_signal_id = 0

    # -- lifecycle -------------------------------------------------------------

    def export(self):
        """Export the object, then own the name.

        Order matters: the watcher resolves the name to its owner and starts
        reading properties the moment it is told about us, so the object has to
        be answering before the name exists.
        """
        info = Gio.DBusNodeInfo.new_for_xml(SNI_XML).interfaces[0]
        self._registration = gcompat.register_object(
            self._bus, SNI_OBJECT_PATH, info, self._call, self._get)
        self._name_id = Gio.bus_own_name_on_connection(
            self._bus, self._bus_name, Gio.BusNameOwnerFlags.NONE,
            self._on_name_acquired, None)
        for name in WATCHER_NAMES:
            self._watch_ids.append(Gio.bus_watch_name_on_connection(
                self._bus, name, Gio.BusNameWatcherFlags.NONE,
                self._on_watcher_appeared, self._on_watcher_vanished))

    def stop(self):
        for watch_id in self._watch_ids:
            Gio.bus_unwatch_name(watch_id)
        self._watch_ids = []
        if self._host_signal_id:
            self._bus.signal_unsubscribe(self._host_signal_id)
            self._host_signal_id = 0
        if self._name_id:
            Gio.bus_unown_name(self._name_id)
            self._name_id = 0
        gcompat.unregister_object(self._bus, self._registration)
        self._registration = 0

    def _on_name_acquired(self, _conn, _name):
        self._register_with_watcher()

    def _on_watcher_appeared(self, _conn, name, _owner):
        self._watcher_owner = name
        # Re-register when a host joins: a shell that restarted has forgotten
        # about us, and it is the host, not us, that knows when that happened.
        if not self._host_signal_id:
            self._host_signal_id = self._bus.signal_subscribe(
                None, WATCHER_IFACE, "StatusNotifierHostRegistered", None,
                None, Gio.DBusSignalFlags.NONE, self._on_host_registered)
        self._register_with_watcher()

    def _on_watcher_vanished(self, _conn, name):
        # Only if it is the one we are actually registered with. Both watcher
        # spellings are watched, and clearing on the wrong one stranded
        # registration while a live watcher remained.
        if self._watcher_owner == name:
            self._watcher_owner = None
            self.registered = False

    def _on_host_registered(self, *_args):
        self._register_with_watcher()

    def _register_with_watcher(self):
        """Hand the watcher our BUS NAME.

        Both a bus name and an object path are accepted by the GNOME host, but
        KDE, xfce4-panel and waybar accept only the name, so the name is what
        is sent.
        """
        if self._watcher_owner is None or not self._name_id:
            return

        def done(source, res):
            try:
                source.call_finish(res)
                self.registered = True
            except GLib.Error as err:
                self._log("RegisterStatusNotifierItem: %s", err.message)

        self._bus.call(
            self._watcher_owner, WATCHER_PATH, WATCHER_IFACE,
            "RegisterStatusNotifierItem",
            GLib.Variant("(s)", (self._bus_name,)), None,
            Gio.DBusCallFlags.NONE, 5000, None, done)

    # -- state -----------------------------------------------------------------

    def set_icon(self, icon_name, attention=False):
        status = STATUS_ATTENTION if attention else STATUS_ACTIVE
        changed = {}
        if icon_name != self._icon_name:
            self._icon_name = icon_name
            changed["IconName"] = GLib.Variant("s", icon_name)
        if status != self._status:
            self._status = status
            changed["Status"] = GLib.Variant("s", status)
        if not changed:
            return
        self._properties_changed(changed)
        if "IconName" in changed:
            self._emit("NewIcon", None)
        if "Status" in changed:
            self._emit("NewStatus", GLib.Variant("(s)", (status,)))

    def set_tooltip(self, title, body, icon=""):
        """Kept current for hosts that show it; GNOME's does not read ToolTip.

        `icon` is the tooltip's own icon; empty means the item's current one.
        """
        if (title, body, icon) == (self._tooltip_title, self._tooltip_body,
                                   self._tooltip_icon):
            return
        self._tooltip_title = title
        self._tooltip_body = body
        self._tooltip_icon = icon
        self._properties_changed({"ToolTip": self._tooltip_variant()})
        self._emit("NewToolTip", None)

    def _tooltip_variant(self):
        return GLib.Variant("(sa(iiay)ss)",
                            (self._tooltip_icon or self._icon_name, [],
                             self._tooltip_title, self._tooltip_body))

    def _properties_changed(self, changed):
        try:
            self._bus.emit_signal(
                None, SNI_OBJECT_PATH, "org.freedesktop.DBus.Properties",
                "PropertiesChanged",
                GLib.Variant("(sa{sv}as)", (SNI_IFACE, changed, [])))
        except GLib.Error as err:
            self._log("PropertiesChanged: %s", err.message)

    def _emit(self, name, params):
        try:
            self._bus.emit_signal(None, SNI_OBJECT_PATH, SNI_IFACE, name,
                                  params)
        except GLib.Error as err:
            self._log("%s: %s", name, err.message)

    # -- interface -------------------------------------------------------------

    def _get(self, _conn, _sender, _path, _iface, prop):
        """Every property must answer.

        Wrapped like dbusmenu's handler: a failed GetAll makes the host discard
        every cached property it holds for this item -- i.e. the icon
        disappears -- so "not applicable" is an empty value here, never an
        error and never None.
        """
        try:
            return self._properties(prop)
        except Exception as exc:  # noqa: BLE001
            self._log("property %s: %r", prop, exc)
            return GLib.Variant("s", "") if prop != "Menu" else None

    def _properties(self, prop):
        return {
            "Category": GLib.Variant("s", "SystemServices"),
            "Id": GLib.Variant("s", self._id),
            "Title": GLib.Variant("s", self._title),
            "Status": GLib.Variant("s", self._status),
            "WindowId": GLib.Variant("i", 0),
            "IconThemePath": GLib.Variant("s", ""),
            "Menu": GLib.Variant("o", self._menu_path),
            "ItemIsMenu": GLib.Variant("b", True),
            "IconName": GLib.Variant("s", self._icon_name),
            "IconPixmap": GLib.Variant("a(iiay)", []),
            "OverlayIconName": GLib.Variant("s", ""),
            "OverlayIconPixmap": GLib.Variant("a(iiay)", []),
            "AttentionIconName": GLib.Variant("s", self._attention_icon_name),
            "AttentionIconPixmap": GLib.Variant("a(iiay)", []),
            "AttentionMovieName": GLib.Variant("s", ""),
            "ToolTip": self._tooltip_variant(),
        }.get(prop)

    def _call(self, _conn, _sender, _path, _iface, method, params, invocation):
        try:
            self._dispatch(method, params, invocation)
        except Exception as exc:  # noqa: BLE001 - a raise here hangs the panel
            self._log("%s: %r", method, exc)
            invocation.return_error_literal(
                Gio.dbus_error_quark(), Gio.DBusError.FAILED, str(exc))

    def _dispatch(self, method, params, invocation):
        if method == "ProvideXdgActivationToken":
            (token,) = params.unpack()
            # Kept for the next spawn: without it the window we launch arrives
            # as a "ready to run" notification instead of taking focus.
            self.activation_token = token
            invocation.return_value(None)
        elif method == "SecondaryActivate":
            invocation.return_value(None)
            if self._on_secondary_activate is not None:
                GLib.idle_add(self._deliver_secondary)
        elif method in ("ContextMenu", "Scroll"):
            # Answered rather than refused: the host logs a critical for an
            # unknown method, once per scroll over the icon.
            invocation.return_value(None)
        else:
            invocation.return_error_literal(
                Gio.dbus_error_quark(), Gio.DBusError.UNKNOWN_METHOD, method)

    def _deliver_secondary(self):
        self._on_secondary_activate()
        return GLib.SOURCE_REMOVE
