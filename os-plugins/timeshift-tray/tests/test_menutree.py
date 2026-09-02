# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The menu each state produces, and the stability the diff depends on."""

import datetime
import json
import os
import unittest

from timeshift_tray import menutree, model

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
NOW = datetime.datetime(2026, 9, 1, 12, 0, tzinfo=datetime.timezone.utc)


def corpus(name):
    with open(os.path.join(DATA, name), "r") as handle:
        return json.load(handle)


def ready_state():
    state = model.TrayState()
    state.conn = model.ConnState.READY
    state.system = model.SystemInfo.from_wire(corpus("system_info.json"))
    state.schedule = model.ScheduleStatus.from_wire(corpus("schedule_status.json"))
    state.repo = model.RepoStatus.from_wire(corpus("repo_status.json"))
    state.snapshots = [model.Snapshot.from_wire(o)
                       for o in corpus("snapshots_list.json")]
    return state


def build(state, ids=None):
    return menutree.build_menu(state, NOW, ids or menutree.IdAllocator())


def labels(root):
    return [node.label for node in root.children if node.visible]


def find(root, key):
    for node in root.walk():
        if node.key == key:
            return node
    return None


class ShapeTest(unittest.TestCase):
    def test_healthy_menu(self):
        root = build(ready_state())
        keys = [n.key for n in root.children]
        self.assertEqual(keys, [
            "status.snapshot", "status.schedule", "status.location",
            "job.head", "job.detail", "sep.1",
            "action.create", "action.revoke", "action.open", "recent",
            "sep.2", "action.quit",
        ])
        self.assertTrue(find(root, "action.create").enabled)

    def test_status_rows_cannot_be_clicked(self):
        root = build(ready_state())
        for key in ("status.snapshot", "status.schedule", "status.location"):
            node = find(root, key)
            self.assertFalse(node.enabled, key)
            self.assertIsNone(node.action, key)

    def test_location_is_the_daemons_own_words(self):
        state = ready_state()
        root = build(state)
        # A bare "OK" is dropped when there are details: the row's icon says
        # it, and the fact is the number.
        self.assertEqual(find(root, "status.location").label,
                         "26 snapshots, 29.9 TB free")
        self.assertEqual(find(root, "status.location").dot, menutree.DOT_OK)

    def test_no_access_offers_the_way_out(self):
        state = model.TrayState()
        state.conn = model.ConnState.NO_ACCESS
        root = build(state)
        self.assertIsNotNone(find(root, "action.grant"))
        self.assertIsNone(find(root, "action.create"))
        self.assertIn("timeshift", labels(root)[1])

    def test_no_daemon_says_so_rather_than_blaming_permissions(self):
        state = model.TrayState()
        state.conn = model.ConnState.NO_DAEMON
        root = build(state)
        self.assertIn("not running", labels(root)[0])
        self.assertIsNone(find(root, "action.grant"))

    def test_protocol_mismatch_names_both_versions(self):
        state = model.TrayState()
        state.conn = model.ConnState.PROTOCOL_MISMATCH
        state.daemon_protocol = 3
        root = build(state)
        detail = find(root, "status.detail").label
        self.assertIn("3", detail)
        self.assertIn("2", detail)

    def test_a_live_session_disables_create_with_a_reason(self):
        state = ready_state()
        state.system.live = True
        node = find(build(state), "action.create")
        self.assertFalse(node.enabled)
        self.assertIn("live session", node.label)

    def test_quit_is_always_there(self):
        for conn in model.ConnState:
            state = model.TrayState()
            state.conn = conn
            self.assertIsNotNone(find(build(state), "action.quit"), conn)


class RunningJobTest(unittest.TestCase):
    def running(self):
        state = ready_state()
        state.job = model.Job.from_wire({
            "id": "j-9", "kind": "create", "state": "running",
            "phase": "sync_files",
            "progress": {"percent": 0.43, "count": 12309, "total": 28400,
                         "eta_seconds": 95, "status_line": "usr/lib/x"},
        })
        return state

    def test_progress_is_shown_in_the_menu(self):
        """The GNOME host does not implement ToolTip, so this is the only place
        a percentage can appear at all."""
        root = build(self.running())
        head = find(root, "job.head")
        self.assertTrue(head.visible)
        self.assertEqual(head.label, "Creating snapshot  ▰▰▰▰▱▱▱▱▱▱ 43%")
        self.assertEqual(head.dot, menutree.DOT_BUSY)
        self.assertEqual(head.props()["icon-data"], menutree.DOT_BUSY)
        self.assertEqual(find(root, "job.detail").label,
                         "12,309 of 28,400 files · 1 minute left")

    def test_create_is_disabled_while_one_runs(self):
        node = find(build(self.running()), "action.create")
        self.assertFalse(node.enabled)
        self.assertEqual(node.label, "A snapshot is already being taken")

    def test_a_job_of_unknown_kind_still_explains_itself(self):
        """jobs.Event carries no kind, so there is a window where a running job
        is known but not yet identified."""
        state = ready_state()
        state.job = model.Job.from_wire({"id": "j-9", "state": "running"})
        node = find(build(state), "action.create")
        self.assertFalse(node.enabled)
        self.assertEqual(node.label, "Timeshift is busy")

    def test_starting_a_job_is_a_property_change_not_a_new_layout(self):
        """The rows exist when idle and are merely hidden.

        If they were added and removed the host would re-read the whole menu,
        which is visible as a rebuild when the menu happens to be open.
        """
        ids = menutree.IdAllocator()
        idle = build(ready_state(), ids)
        busy = build(self.running(), ids)
        self.assertTrue(menutree.same_structure(idle, busy))
        updated, _removed = menutree.diff_props(idle, busy)
        changed_ids = {item_id for item_id, _ in updated}
        self.assertIn(find(busy, "job.head").id, changed_ids)

    def test_indeterminate_progress_does_not_claim_zero_percent(self):
        state = ready_state()
        state.job = model.Job.from_wire({
            "id": "j-9", "kind": "create", "state": "running",
            "phase": "prepare",
            "progress": {"percent": 0, "count": 0, "total": 0,
                         "eta_seconds": -1}})
        root = build(state)
        self.assertEqual(find(root, "job.head").label, "Creating snapshot…")
        self.assertEqual(find(root, "job.detail").label, "prepare")


class IdentityTest(unittest.TestCase):
    def test_ids_are_stable_across_rebuilds(self):
        ids = menutree.IdAllocator()
        first = build(ready_state(), ids)
        second = build(ready_state(), ids)
        self.assertEqual([n.id for n in first.walk()],
                         [n.id for n in second.walk()])

    def test_a_new_snapshot_changes_the_layout(self):
        """A row appearing genuinely IS a layout change, and must say so."""
        ids = menutree.IdAllocator()
        before_state = ready_state()
        before_state.snapshots = before_state.snapshots[:2]
        before = build(before_state, ids)
        after_state = ready_state()
        after_state.snapshots = after_state.snapshots[:3]
        after = build(after_state, ids)
        self.assertFalse(menutree.same_structure(before, after))

    def test_only_the_age_changing_is_not_a_layout_change(self):
        ids = menutree.IdAllocator()
        before = menutree.build_menu(ready_state(), NOW, ids)
        later = menutree.build_menu(
            ready_state(), NOW + datetime.timedelta(hours=5), ids)
        self.assertTrue(menutree.same_structure(before, later))
        updated, removed = menutree.diff_props(before, later)
        self.assertTrue(updated)
        self.assertFalse(removed)


class LabelTest(unittest.TestCase):
    def test_every_label_is_mnemonic_safe(self):
        """A single underscore is eaten by the panel as a mnemonic marker."""
        state = ready_state()
        state.repo = model.RepoStatus.from_wire(
            {"available": True, "has_snapshots": True, "message": "OK",
             "details": "on /dev/mapper/vg_root-lv_home"})
        node = find(build(state), "status.location")
        self.assertIn("vg__root", node.props()["label"])


class HeadlineTest(unittest.TestCase):
    """The first row is a verdict, and the verdict changes -- not a suffix."""

    def headline(self, state):
        return find(build(state), "status.snapshot")

    def test_protected_names_the_age_and_the_level(self):
        node = self.headline(ready_state())
        self.assertTrue(node.label.startswith("Protected · last snapshot "))
        self.assertEqual(node.label.count(" · "), 2, node.label)
        self.assertEqual(node.dot, menutree.DOT_OK)

    def test_no_snapshots_is_not_protected(self):
        state = ready_state()
        state.snapshots = []
        node = self.headline(state)
        self.assertEqual(node.label, "Not protected · no snapshots yet")
        self.assertEqual(node.dot, menutree.DOT_FAULT)

    def test_an_incomplete_latest_is_not_protected(self):
        state = ready_state()
        for snap in state.snapshots:
            snap.valid = False
        node = self.headline(state)
        self.assertEqual(node.label,
                         "Not protected · last snapshot is incomplete")
        self.assertEqual(node.dot, menutree.DOT_FAULT)

    def test_a_pre_restore_snapshot_says_restored(self):
        state = ready_state()
        for snap in state.snapshots:
            snap.live = True
        node = self.headline(state)
        self.assertTrue(node.label.startswith("Restored · previous system kept "))
        self.assertEqual(node.dot, menutree.DOT_INFO)

    def test_an_unreachable_location_is_not_protected(self):
        """A snapshot that cannot be reached protects nothing, however recent."""
        state = ready_state()
        state.repo = model.RepoStatus.from_wire(
            {"available": False, "message": "Snapshot device not available"})
        node = self.headline(state)
        self.assertEqual(node.label,
                         "Not protected · snapshot location unavailable")
        loc = find(build(state), "status.location")
        self.assertEqual(loc.label, "Snapshot device not available")
        self.assertEqual(loc.dot, menutree.DOT_FAULT)

    def test_a_stale_location_keeps_the_last_verdict(self):
        """A transport failure is not a verdict about the repository."""
        state = ready_state()
        state.repo_stale = True
        self.assertTrue(self.headline(state).label.startswith("Protected"))
        loc = find(build(state), "status.location")
        self.assertTrue(loc.label.endswith("(last known)"))
        self.assertEqual(loc.dot, menutree.DOT_WARN)


class ScheduleRowTest(unittest.TestCase):
    def row(self, **fields):
        state = ready_state()
        for name, value in fields.items():
            setattr(state.schedule, name, value)
        return find(build(state), "status.schedule")

    def test_next_check_is_a_clock_time(self):
        node = self.row(next_run=NOW + datetime.timedelta(minutes=7))
        self.assertTrue(node.label.startswith("Next check "))
        self.assertEqual(node.dot, menutree.DOT_INFO)

    def test_faults_get_the_warning_icon(self):
        self.assertEqual(self.row(running=False).label, "Scheduler not running")
        self.assertEqual(self.row(running=False).dot, menutree.DOT_WARN)
        self.assertEqual(self.row(last_error="boom").label,
                         "Last check failed · boom")
        late = self.row(next_run=NOW - datetime.timedelta(minutes=25))
        self.assertEqual(late.label, "Check overdue by 25 minutes")
        self.assertEqual(late.dot, menutree.DOT_WARN)

    def test_off_and_live_are_not_faults(self):
        self.assertEqual(self.row(enabled=False).label,
                         "Scheduled snapshots off")
        state = ready_state()
        state.system.live = True
        node = find(build(state), "status.schedule")
        self.assertEqual(node.label, "Not scheduled in a live session")
        self.assertEqual(node.dot, menutree.DOT_NEUTRAL)


class RowIconTest(unittest.TestCase):
    def test_every_action_has_an_icon(self):
        root = build(ready_state())
        for key in ("action.create", "action.revoke", "action.open",
                    "recent", "action.quit"):
            self.assertTrue(find(root, key).icon_name, key)
        self.assertEqual(find(root, "action.open").icon_name, "timeshift")

    def test_icons_travel_as_properties(self):
        node = find(build(ready_state()), "action.create")
        self.assertEqual(node.props()["icon-name"], menutree.ICON_CREATE)

    def test_connection_headlines_have_dots(self):
        for conn, dot in ((model.ConnState.NO_DAEMON, menutree.DOT_FAULT),
                          (model.ConnState.NO_ACCESS, menutree.DOT_WARN),
                          (model.ConnState.STARTING, menutree.DOT_NEUTRAL)):
            state = model.TrayState()
            state.conn = conn
            self.assertEqual(find(build(state), "status.headline").dot, dot, conn)

    def test_the_idle_job_row_carries_no_dot(self):
        """Hidden rows must not accumulate properties the host would draw the
        instant they become visible with stale text."""
        node = find(build(ready_state()), "job.head")
        self.assertEqual(node.dot, "")
        self.assertNotIn("icon-data", node.props())

    def test_a_row_has_a_name_or_a_dot_never_both(self):
        """The host draws icon-data only when icon-name is absent."""
        for node in build(ready_state()).walk():
            self.assertFalse(node.icon_name and node.dot, node.key)

    def test_every_dot_used_is_declared(self):
        used = set()
        for conn in model.ConnState:
            state = ready_state()
            state.conn = conn
            used |= {n.dot for n in build(state).walk() if n.dot}
        self.assertTrue(used <= set(menutree.ALL_DOTS), used)


class RecentTest(unittest.TestCase):
    def test_entries_are_relative_and_dotted(self):
        state = ready_state()
        state.snapshots[0].created = NOW - datetime.timedelta(hours=2)
        state.snapshots[0].tags = ["O"]
        state.snapshots[1].created = NOW - datetime.timedelta(days=1)
        state.snapshots[1].valid = False
        recent = find(build(state), "recent")
        first, second = recent.children[0].label, recent.children[1].label
        self.assertTrue(first.startswith("Today "), first)
        self.assertTrue(first.endswith(" · On demand"), first)
        self.assertTrue(second.startswith("Yesterday "), second)
        self.assertTrue(second.endswith(" · incomplete"), second)


if __name__ == "__main__":
    unittest.main()
