# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""com.canonical.dbusmenu, exported by hand.

The menu is drawn by the desktop shell from this data, which is why the applet
needs no widget toolkit at all. Two rules hold the whole thing together:

  * A method handler answers immediately and never does I/O. `Event` returns
    before it acts, because the shell's call is asynchronous only from its own
    side -- if this blocked on a polkit prompt, the panel would block with it.

  * GetLayout and GetGroupProperties read the cached tree and nothing else.
    Fetching a snapshot list to answer a menu redraw would put an SSH round
    trip in the middle of a click.
"""

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import gcompat, menutree  # noqa: E402
from .constants import DBUSMENU_IFACE  # noqa: E402

# Signatures taken from a live indicator's introspection rather than the spec
# document, so that what is exported is what hosts on this desktop expect.
# Note IconThemePath is `as` here and `s` on org.kde.StatusNotifierItem.
DBUSMENU_XML = """
<node>
  <interface name="com.canonical.dbusmenu">
    <method name="GetLayout">
      <arg type="i" name="parentId" direction="in"/>
      <arg type="i" name="recursionDepth" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="u" name="revision" direction="out"/>
      <arg type="(ia{sv}av)" name="layout" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="a(ia{sv})" name="properties" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="name" direction="in"/>
      <arg type="v" name="value" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="eventId" direction="in"/>
      <arg type="v" name="data" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg type="a(isvu)" name="events" direction="in"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg type="i" name="id" direction="in"/>
      <arg type="b" name="needUpdate" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="ai" name="updatesNeeded" direction="out"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})" name="updatedProps"/>
      <arg type="a(ias)" name="removedProps"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg type="u" name="revision"/>
      <arg type="i" name="parent"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg type="i" name="id"/>
      <arg type="u" name="timestamp"/>
    </signal>
  </interface>
</node>
"""


def prop_variant(key, value, icon_data=None):
    """One property as a variant, or None for one that cannot be sent.

    icon-data is the only indirection: the tree names a dot and the bytes
    live here, so the tree stays free of files. A key with no bytes behind it
    is dropped -- the row then has no icon, which beats a row that raises.
    """
    if key == "icon-data":
        data = (icon_data or {}).get(value)
        if not data:
            return None
        return GLib.Variant("ay", data)
    return GLib.Variant(menutree.PROP_TYPES[key], value)


def props_variant(node, names=None, icon_data=None):
    """One item's properties as a{sv}, honouring the requested subset.

    An empty `names` means "everything", which is what the GNOME host asks for.
    """
    wanted = set(names or ())
    out = {}
    for key, value in node.props().items():
        if wanted and key not in wanted:
            continue
        variant = prop_variant(key, value, icon_data)
        if variant is not None:
            out[key] = variant
    return out


def layout_tuple(node, depth, names=None, icon_data=None):
    """The (ia{sv}av) triple. depth < 0 means unlimited."""
    if depth == 0:
        children = []
    else:
        children = [
            GLib.Variant("(ia{sv}av)",
                         layout_tuple(child, depth - 1, names, icon_data))
            for child in node.children if child.visible
        ]
    return (node.id, props_variant(node, names, icon_data), children)


def layout_variant(revision, node, depth, names=None, icon_data=None):
    return GLib.Variant("(u(ia{sv}av))",
                        (revision, layout_tuple(node, depth, names, icon_data)))


class DBusMenu:
    """Exports one menu tree and keeps hosts told about changes."""

    def __init__(self, bus, path, on_action, on_about_to_show=None,
                 on_visibility=None, log=None, icon_data=None):
        self._bus = bus
        self._path = path
        self._on_action = on_action
        self._on_about_to_show = on_about_to_show
        self._on_visibility = on_visibility
        self._log = log or (lambda *_a, **_k: None)
        self._icon_data = dict(icon_data or {})   # dot key -> PNG bytes

        self._root = menutree.Node(0, "root")
        self._index = {0: self._root}
        self._revision = 1
        self._needs_update = False

        info = Gio.DBusNodeInfo.new_for_xml(DBUSMENU_XML).interfaces[0]
        self._registration = gcompat.register_object(
            bus, path, info, self._call, self._get)

    def unexport(self):
        gcompat.unregister_object(self._bus, self._registration)
        self._registration = 0

    # -- the tree --------------------------------------------------------------

    @property
    def revision(self):
        return self._revision

    def set_tree(self, root):
        """Install a new tree, telling the host in the cheapest correct way.

        Same shape means the properties changed, which the host applies in
        place. A different shape means the layout revision has to move, and the
        host then re-reads everything -- visible as a rebuild if the menu is
        open, which is why ids are stable and the job rows merely hide.
        """
        old = self._root
        structural = not menutree.same_structure(old, root)
        self._root = root
        self._index = menutree.index_of(root)
        if structural:
            self._revision += 1
            self._needs_update = False
            self._emit("LayoutUpdated", GLib.Variant("(ui)",
                                                     (self._revision, 0)))
            return
        updated, removed = menutree.diff_props(old, root)
        if updated or removed:
            rows = []
            for item_id, changed in updated:
                variants = {}
                for key, value in changed.items():
                    variant = prop_variant(key, value, self._icon_data)
                    if variant is not None:
                        variants[key] = variant
                if variants:
                    rows.append((item_id, variants))
            self._emit("ItemsPropertiesUpdated",
                       GLib.Variant("(a(ia{sv})a(ias))", (rows, removed)))

    def _emit(self, name, params):
        try:
            self._bus.emit_signal(None, self._path, DBUSMENU_IFACE, name,
                                  params)
        except GLib.Error as err:
            self._log("dbusmenu %s: %s", name, err.message)

    # -- interface -------------------------------------------------------------

    def _get(self, _conn, _sender, _path, _iface, prop):
        return {
            "Version": GLib.Variant("u", 3),
            # No GTK here, so no get_default_direction; ltr until this program
            # has a translation catalogue to ask.
            "TextDirection": GLib.Variant("s", "ltr"),
            "Status": GLib.Variant("s", "normal"),
            "IconThemePath": GLib.Variant("as", []),
        }.get(prop)

    def _call(self, _conn, _sender, _path, _iface, method, params, invocation):
        try:
            self._dispatch(method, params, invocation)
        except Exception as exc:  # noqa: BLE001 - a raise here hangs the panel
            self._log("dbusmenu %s: %r", method, exc)
            invocation.return_error_literal(
                Gio.dbus_error_quark(), Gio.DBusError.FAILED, str(exc))

    def _dispatch(self, method, params, invocation):
        if method == "GetLayout":
            parent_id, depth, names = params.unpack()
            node = self._index.get(parent_id)
            if node is None:
                invocation.return_error_literal(
                    Gio.dbus_error_quark(), Gio.DBusError.INVALID_ARGS,
                    "no such menu item: %d" % parent_id)
                return
            invocation.return_value(
                layout_variant(self._revision, node, depth, names,
                               self._icon_data))

        elif method == "GetGroupProperties":
            ids, names = params.unpack()
            rows = [(i, props_variant(self._index[i], names, self._icon_data))
                    for i in ids if i in self._index]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (rows,)))

        elif method == "GetProperty":
            item_id, name = params.unpack()
            node = self._index.get(item_id)
            value = (props_variant(node, [name], self._icon_data).get(name)
                     if node else None)
            if value is None:
                default = menutree.PROP_DEFAULTS.get(name)
                value = (GLib.Variant(menutree.PROP_TYPES[name], default)
                         if default is not None and name in menutree.PROP_TYPES
                         else GLib.Variant("s", ""))
            invocation.return_value(GLib.Variant("(v)", (value,)))

        elif method == "Event":
            item_id, event_id, _data, timestamp = params.unpack()
            invocation.return_value(None)
            self._queue_event(item_id, event_id, timestamp)

        elif method == "EventGroup":
            (events,) = params.unpack()
            errors = []
            for item_id, event_id, _data, timestamp in events:
                if item_id in self._index or item_id == 0:
                    self._queue_event(item_id, event_id, timestamp)
                else:
                    errors.append(item_id)
            invocation.return_value(GLib.Variant("(ai)", (errors,)))

        elif method == "AboutToShow":
            (item_id,) = params.unpack()
            self._queue_about_to_show(item_id)
            invocation.return_value(GLib.Variant("(b)", (self._needs_update,)))

        elif method == "AboutToShowGroup":
            (ids,) = params.unpack()
            needed = []
            errors = []
            for item_id in ids:
                if item_id in self._index:
                    self._queue_about_to_show(item_id)
                    if self._needs_update:
                        needed.append(item_id)
                else:
                    errors.append(item_id)
            invocation.return_value(GLib.Variant("(aiai)", (needed, errors)))

        else:
            invocation.return_error_literal(
                Gio.dbus_error_quark(), Gio.DBusError.UNKNOWN_METHOD, method)

    def _queue_event(self, item_id, event_id, timestamp):
        # Answered already; act on the idle so nothing the action does can
        # delay the reply the shell is waiting on.
        GLib.idle_add(self._deliver_event, item_id, event_id, timestamp)

    def _deliver_event(self, item_id, event_id, timestamp):
        if event_id in ("opened", "closed") and self._on_visibility is not None:
            self._on_visibility(event_id == "opened")
            return GLib.SOURCE_REMOVE
        if event_id != "clicked":
            return GLib.SOURCE_REMOVE
        node = self._index.get(item_id)
        # A click that raced a rebuild is a no-op, not an error: the id may
        # simply belong to a menu that no longer exists.
        if node is not None and node.action and node.enabled:
            self._on_action(node.action)
        return GLib.SOURCE_REMOVE

    def _queue_about_to_show(self, item_id):
        if self._on_about_to_show is not None:
            GLib.idle_add(self._deliver_about_to_show, item_id)

    def _deliver_about_to_show(self, item_id):
        self._on_about_to_show(item_id)
        return GLib.SOURCE_REMOVE
