# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The variants GetLayout and friends put on the wire.

Needs gi, but no bus and no display: the point is the shape of the data, which
is where a hand-built variant goes wrong -- a mis-nested `av` type-checks at
construction and is rejected by the host at read time, with nothing said.
"""

import datetime
import json
import os
import unittest

import gi

gi.require_version("Gio", "2.0")
from gi.repository import GLib  # noqa: E402

from timeshift_tray import dbusmenu, menutree, model  # noqa: E402

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
NOW = datetime.datetime(2026, 9, 1, 12, 0, tzinfo=datetime.timezone.utc)


def corpus(name):
    with open(os.path.join(DATA, name), "r") as handle:
        return json.load(handle)


def ready_menu():
    state = model.TrayState()
    state.conn = model.ConnState.READY
    state.schedule = model.ScheduleStatus.from_wire(corpus("schedule_status.json"))
    state.repo = model.RepoStatus.from_wire(corpus("repo_status.json"))
    state.snapshots = [model.Snapshot.from_wire(o)
                       for o in corpus("snapshots_list.json")]
    return menutree.build_menu(state, NOW, menutree.IdAllocator())


class LayoutTest(unittest.TestCase):
    def test_signature(self):
        variant = dbusmenu.layout_variant(2, ready_menu(), -1, [])
        self.assertEqual(variant.get_type_string(), "(u(ia{sv}av))")

    def test_round_trip(self):
        root = ready_menu()
        variant = dbusmenu.layout_variant(7, root, -1, [])
        revision, layout = variant.unpack()
        self.assertEqual(revision, 7)
        item_id, props, children = layout
        self.assertEqual(item_id, 0)
        self.assertEqual(props["children-display"], "submenu")
        self.assertEqual(len(children),
                         len([c for c in root.children if c.visible]))

    def test_separators_and_disabled_rows_survive(self):
        _revision, layout = dbusmenu.layout_variant(
            1, ready_menu(), -1, []).unpack()
        _id, _props, children = layout
        kinds = [row[1].get("type") for row in children]
        self.assertIn("separator", kinds)
        self.assertIn(False, [row[1].get("enabled") for row in children])

    def test_nesting(self):
        """The Recent submenu has to arrive as children, not as a flat list."""
        _revision, layout = dbusmenu.layout_variant(
            1, ready_menu(), -1, []).unpack()
        _id, _props, children = layout
        submenus = [row for row in children
                    if row[1].get("children-display") == "submenu"]
        self.assertEqual(len(submenus), 1)
        self.assertTrue(submenus[0][2])

    def test_depth_zero_returns_no_children(self):
        _revision, layout = dbusmenu.layout_variant(
            1, ready_menu(), 0, []).unpack()
        self.assertEqual(layout[2], [])

    def test_requested_property_subset_is_honoured(self):
        """The host asks for ['type','children-display'] before it asks for all."""
        _revision, layout = dbusmenu.layout_variant(
            1, ready_menu(), -1, ["type", "children-display"]).unpack()
        for row in layout[2]:
            self.assertNotIn("label", row[1])

    def test_defaults_are_omitted(self):
        """enabled=true and visible=true are what an absent property means."""
        root = ready_menu()
        node = next(n for n in root.walk() if n.key == "action.open")
        self.assertEqual(set(node.props()), {"label", "icon-name"})
        status = next(n for n in root.walk() if n.key == "status.snapshot")
        self.assertEqual(set(status.props()), {"label", "enabled", "icon-data"})


class IconDataTest(unittest.TestCase):
    """A dot is a key in the tree and PNG bytes on the wire."""

    def node(self):
        root = ready_menu()
        return next(n for n in root.walk() if n.key == "status.snapshot")

    def test_bytes_pack_as_ay(self):
        node = self.node()
        props = dbusmenu.props_variant(node, None, {node.dot: b"\x89PNG.."})
        self.assertEqual(props["icon-data"].get_type_string(), "ay")
        self.assertEqual(bytes(props["icon-data"]), b"\x89PNG..")

    def test_a_key_with_no_bytes_is_dropped_not_raised(self):
        node = self.node()
        props = dbusmenu.props_variant(node, None, {})
        self.assertNotIn("icon-data", props)
        self.assertIn("label", props)
        props = dbusmenu.props_variant(node, None, None)
        self.assertNotIn("icon-data", props)

    def test_the_layout_carries_the_bytes(self):
        root = ready_menu()
        node = self.node()
        _rev, layout = dbusmenu.layout_variant(
            1, root, -1, None, {node.dot: b"png"}).unpack()
        rows = {row[0]: row[1] for row in layout[2]}
        self.assertEqual(bytes(rows[node.id]["icon-data"]), b"png")


class DiffTest(unittest.TestCase):
    def test_updates_pack_as_the_signal_expects(self):
        ids = menutree.IdAllocator()
        state = model.TrayState()
        state.conn = model.ConnState.READY
        before = menutree.build_menu(state, NOW, ids)
        state.job = model.Job.from_wire(
            {"id": "j-1", "kind": "create", "state": "running",
             "progress": {"percent": 0.5, "count": 5, "total": 10,
                          "eta_seconds": 30}})
        after = menutree.build_menu(state, NOW, ids)
        updated, removed = menutree.diff_props(before, after)
        rows = [(item_id, {key: GLib.Variant(menutree.PROP_TYPES[key], value)
                           for key, value in changed.items()})
                for item_id, changed in updated]
        variant = GLib.Variant("(a(ia{sv})a(ias))", (rows, removed))
        self.assertEqual(variant.get_type_string(), "(a(ia{sv})a(ias))")
        self.assertTrue(variant.unpack()[0])


class PropertyTypeTest(unittest.TestCase):
    def test_every_property_has_a_declared_type(self):
        """A property sent with the wrong type is dropped without a word."""
        state = model.TrayState()
        state.conn = model.ConnState.READY
        root = menutree.build_menu(state, NOW, menutree.IdAllocator())
        for node in root.walk():
            for key in node.props():
                self.assertIn(key, menutree.PROP_TYPES, key)


if __name__ == "__main__":
    unittest.main()
