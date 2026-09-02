# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The orderings.

Every test here is a sequence that actually happens on a real machine and that
the applet used to get wrong. None of them needs a bus, a display, or a second
of waiting.
"""

import json
import os
import unittest

import fakes
from timeshift_tray import actions, controller, icons, menutree
from timeshift_tray.constants import (
    METHOD_JOBS_GET,
    METHOD_JOBS_LIST,
    METHOD_REPO_STATUS,
    METHOD_SCHEDULE_STATUS,
    METHOD_SNAPSHOTS_LIST,
    CREATE_LATCH_SECONDS,
    REPO_POLL_SECONDS,
    RECONCILE_SECONDS,
)
from timeshift_tray.model import ConnState, Health

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def corpus(name):
    with open(os.path.join(DATA, name), "r") as handle:
        return json.load(handle)


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.client = fakes.FakeClient()
        self.menu = fakes.FakeMenu()
        self.item = fakes.FakeItem()
        self.notifier = fakes.FakeNotifier()
        self.spawner = fakes.FakeSpawner()
        self.timers = fakes.FakeTimers()
        self.clock = fakes.FakeClock()
        self.quits = []
        self.ctl = controller.Controller(
            client=self.client, menu=self.menu, item=self.item,
            notifier=self.notifier, spawner=self.spawner, timers=self.timers,
            clock=self.clock, on_quit=lambda: self.quits.append(True))
        self.ctl.start()

    def connect(self, snapshots=True):
        """Reach READY and answer the opening round of calls."""
        self.ctl.on_conn_state(ConnState.READY)
        self.client.answer(METHOD_JOBS_LIST, [])
        self.client.answer(METHOD_SCHEDULE_STATUS, corpus("schedule_status.json"))
        self.client.answer(METHOD_SNAPSHOTS_LIST,
                           corpus("snapshots_list.json") if snapshots else [])
        self.client.answer(METHOD_REPO_STATUS, corpus("repo_status.json"),
                           isolated=True)
        self.draw()

    def draw(self):
        """Let the coalesced redraw happen."""
        self.timers.fire_oneshots()

    def state(self):
        return self.ctl.state


class StartupTest(ControllerTest):
    def test_reaching_ready_asks_for_everything(self):
        self.ctl.on_conn_state(ConnState.READY)
        self.assertIn(METHOD_JOBS_LIST, self.client.methods())
        self.assertIn(METHOD_SCHEDULE_STATUS, self.client.methods())
        self.assertIn(METHOD_SNAPSHOTS_LIST, self.client.methods())
        self.assertTrue(self.client.pending(METHOD_REPO_STATUS, isolated=True))

    def test_the_repository_is_polled(self):
        """REPO_POLL_SECONDS was defined, imported and never used, so in a
        session where nobody opened the menu the location was never re-checked
        and the icon was graded from hours-old data."""
        self.assertIn(REPO_POLL_SECONDS, self.timers.intervals())

    def test_jobs_are_reconciled_periodically(self):
        self.assertIn(RECONCILE_SECONDS, self.timers.intervals())

    def test_a_healthy_connection_draws_the_ok_icon(self):
        self.connect()
        self.assertEqual(self.item.icon, icons.icon_for(Health.OK))
        self.assertFalse(self.item.attention)


class JobIdentityTest(ControllerTest):
    def start_job(self, job_id="j-1", kind="create"):
        self.ctl.on_event(fakes.event("job.started", job_id, kind=kind,
                                      state="running"))
        self.draw()

    def test_the_kind_comes_from_the_event(self):
        """The daemon now repeats it on every event, so no round trip."""
        self.connect()
        self.start_job()
        self.assertEqual(self.state().job.kind, "create")
        self.assertEqual(self.client.pending(METHOD_JOBS_GET), [])
        self.assertIn("Creating snapshot", self.menu.find("job.head").label)

    def test_an_older_daemon_is_asked(self):
        """Without a kind on the wire, jobs.get is the only place that says."""
        self.connect()
        self.ctl.on_event(fakes.event("job.started", "j-1", state="running"))
        self.assertTrue(self.client.pending(METHOD_JOBS_GET))
        self.client.answer(METHOD_JOBS_GET,
                           {"id": "j-1", "kind": "create", "state": "running"})
        self.draw()
        self.assertEqual(self.state().job.kind, "create")

    def test_a_job_finishing_before_jobs_get_answers_is_still_announced(self):
        """The race that silently swallowed a whole snapshot: no toast and no
        refresh, because both were gated on a kind that had not arrived."""
        self.connect()
        self.ctl.on_event(fakes.event("job.started", "j-1", state="running"))
        self.ctl.on_event(fakes.event("job.finished", "j-1", state="finished",
                                      outcome="ok"))
        self.assertEqual(self.notifier.summaries(), [])
        # The reply lands afterwards, and the outcome was kept for it.
        self.client.answer(METHOD_JOBS_GET, {"id": "j-1", "kind": "create"})
        self.assertEqual(self.notifier.summaries(), ["Snapshot created"])

    def test_an_unknown_kind_still_refreshes_the_snapshot_list(self):
        """Guessing wrong costs one read; guessing the other way leaves the
        list stale after the operation that changed it."""
        self.connect()
        self.ctl.on_event(fakes.event("job.started", "j-1", state="running"))
        self.client.answer_all(METHOD_SNAPSHOTS_LIST, [])
        self.ctl.on_event(fakes.event("job.finished", "j-1", outcome="ok"))
        self.timers.fire_oneshots(within=5)
        self.assertTrue(self.client.pending(METHOD_SNAPSHOTS_LIST))

    def test_a_foreign_job_finishing_leaves_the_running_one_alone(self):
        """A sibling's completion used to clear the running job: the progress
        rows vanished mid-backup, create became clickable, and the toast named
        the wrong operation."""
        self.connect()
        self.start_job("j-5", "create")
        self.ctl.on_event(fakes.event("job.finished", "j-4", kind="estimate",
                                      outcome="ok"))
        self.draw()
        self.assertIsNotNone(self.state().job)
        self.assertEqual(self.state().job.id, "j-5")
        self.assertFalse(self.menu.find("action.create").enabled)
        self.assertEqual(self.notifier.summaries(), [])

    def test_a_late_jobs_list_does_not_erase_a_live_job(self):
        """Events flow before the jobs.list reply, which the daemon snapshotted
        before the job existed."""
        self.ctl.on_conn_state(ConnState.READY)
        self.start_job("j-7", "create")
        self.client.answer(METHOD_JOBS_LIST, [])       # taken before j-7
        self.draw()
        self.assertIsNotNone(self.state().job)
        self.assertEqual(self.state().job.kind, "create")

    def test_a_concurrent_estimate_does_not_displace_the_snapshot(self):
        """An estimate takes no write lock, so it really can run alongside."""
        self.connect()
        self.start_job("j-5", "create")
        self.ctl.on_event(fakes.event("job.progress", "j-6", kind="estimate",
                                      state="running",
                                      progress={"percent": 0.1}))
        self.draw()
        self.assertEqual(self.state().job.id, "j-5")

    def test_a_job_the_daemon_no_longer_knows_about_is_forgotten(self):
        """A dropped subscription used to leave the tray permanently busy,
        with create disabled and the repository never re-read."""
        self.connect()
        self.start_job("j-1", "create")
        self.assertTrue(self.state().job.active)
        self.clock.advance(5 * 60)                   # older than the grace
        self.timers.fire_repeating(RECONCILE_SECONDS)
        self.client.answer(METHOD_JOBS_LIST, [])      # reconciliation
        self.draw()
        self.assertIsNone(self.state().job)
        self.assertTrue(self.menu.find("action.create").enabled)


class AppearanceTest(ControllerTest):
    def test_the_panel_icon_follows_the_style(self):
        self.connect()
        self.draw()
        self.assertEqual(self.item.icon, "timeshift-tray-ok-symbolic")
        self.ctl.icon_style = "colour"
        self.ctl.rebuild_menu()
        self.draw()
        self.assertEqual(self.item.icon, "timeshift-tray-ok")

    def test_the_panel_icon_fills_its_ring_as_the_snapshot_progresses(self):
        """Progress without opening the menu, which GNOME gives no tooltip for."""
        self.connect()
        self.ctl.on_event(fakes.event("job.started", "j-1", kind="create",
                                      state="running"))
        self.draw()
        self.assertEqual(self.item.icon, "timeshift-tray-busy-symbolic")
        self.ctl.on_event(fakes.event("job.progress", "j-1", kind="create",
                                      progress={"percent": 0.55, "count": 5,
                                                "total": 10}))
        self.draw()
        self.assertEqual(self.item.icon, "timeshift-tray-busy-4-symbolic")
        self.assertIn("Creating snapshot", self.item.tooltip[1])
        self.assertEqual(self.item.tooltip_icon, "timeshift-tray-busy-4")

    def test_the_tooltip_is_verdict_then_schedule_with_the_colour_shield(self):
        self.connect()
        self.draw()
        title, body = self.item.tooltip
        self.assertEqual(title, "Timeshift")
        first, second = body.split("\n")
        self.assertTrue(first.startswith("Protected"), first)
        self.assertTrue(second.startswith("Next check") or "Scheduled" in second,
                        second)
        self.assertEqual(self.item.tooltip_icon, "timeshift-tray-ok")


class NotificationTest(ControllerTest):
    def test_success_failure_and_warnings_read_differently(self):
        self.connect()
        for job_id, outcome, expected in (
                ("j-1", "ok", "Snapshot created"),
                ("j-2", "warnings", "Snapshot finished with warnings"),
                ("j-3", "failed", "Snapshot failed")):
            self.ctl.on_event(fakes.event("job.finished", job_id, kind="create",
                                          outcome=outcome, error="",
                                          messages=["a note"]))
        self.assertEqual(self.notifier.summaries(),
                         ["Snapshot created",
                          "Snapshot finished with warnings",
                          "Snapshot failed"])

    def test_toasts_carry_the_brand_shield_for_their_outcome(self):
        self.connect()
        for job_id, outcome in (("j-1", "ok"), ("j-2", "warnings"),
                                ("j-3", "failed")):
            self.ctl.on_event(fakes.event("job.finished", job_id, kind="create",
                                          outcome=outcome))
        self.assertEqual(self.notifier.icons,
                         ["timeshift-tray-ok", "timeshift-tray-warning",
                          "timeshift-tray-error"])

    def test_a_finished_snapshot_reports_its_file_count(self):
        self.connect()
        self.ctl.on_event(fakes.event("job.started", "j-1", kind="create",
                                      state="running"))
        self.ctl.on_event(fakes.event("job.progress", "j-1", kind="create",
                                      progress={"percent": 1.0, "count": 12309,
                                                "total": 12309}))
        self.ctl.on_event(fakes.event("job.finished", "j-1", kind="create",
                                      outcome="ok"))
        self.assertEqual(self.notifier.bodies(), ["12,309 files"])

    def test_history_is_not_news(self):
        """Everything already terminal when we attach: announcing it would say
        "snapshot created" at login about last night's snapshot."""
        self.ctl.on_conn_state(ConnState.READY)
        self.client.answer(METHOD_JOBS_LIST, corpus("jobs_list.json"))
        self.assertEqual(self.notifier.summaries(), [])

    def test_a_failure_we_missed_while_disconnected_is_announced(self):
        """The disconnect that hid it is usually the same event that broke it."""
        self.connect()
        self.ctl.on_conn_state(ConnState.DISCONNECTED)
        self.ctl.on_conn_state(ConnState.READY)
        finished = self.clock().isoformat().replace("+00:00", "Z")
        self.client.answer(METHOD_JOBS_LIST, [
            {"id": "j-9", "kind": "create", "state": "failed",
             "outcome": "failed", "error": "no space left",
             "finished": finished}])
        self.assertEqual(self.notifier.summaries(), ["Snapshot failed"])

    def test_an_old_failure_is_not_announced_on_every_reconnect(self):
        self.connect()
        self.ctl.on_conn_state(ConnState.DISCONNECTED)
        self.ctl.on_conn_state(ConnState.READY)
        self.clock.advance(controller.LATE_NEWS_SECONDS + 60)
        finished = (self.clock.now - __import__("datetime").timedelta(
            seconds=controller.LATE_NEWS_SECONDS + 30))
        self.client.answer(METHOD_JOBS_LIST, [
            {"id": "j-9", "kind": "create", "state": "failed",
             "outcome": "failed",
             "finished": finished.isoformat().replace("+00:00", "Z")}])
        self.assertEqual(self.notifier.summaries(), [])

    def test_a_job_that_ended_during_the_gap_is_announced_once(self):
        self.connect()
        self.ctl.on_conn_state(ConnState.DISCONNECTED)
        self.ctl.on_conn_state(ConnState.READY)
        finished = self.clock().isoformat().replace("+00:00", "Z")
        entry = [{"id": "j-9", "kind": "create", "state": "failed",
                  "outcome": "failed", "finished": finished}]
        self.client.answer(METHOD_JOBS_LIST, entry)
        self.client.answer_all(METHOD_SCHEDULE_STATUS,
                               corpus("schedule_status.json"))
        self.client.answer_all(METHOD_SNAPSHOTS_LIST, [])
        self.client.answer_all(METHOD_REPO_STATUS, corpus("repo_status.json"),
                               isolated=True)
        self.timers.fire_repeating(RECONCILE_SECONDS)
        self.client.answer(METHOD_JOBS_LIST, entry)
        self.assertEqual(self.notifier.summaries(), ["Snapshot failed"])


class RepositoryTest(ControllerTest):
    def test_a_transport_failure_is_not_a_verdict(self):
        """A daemon restart, or an SSH host slower than the deadline, used to
        manufacture "location unavailable" and turn the icon red."""
        self.connect()
        good = self.state().repo
        self.client.pending(METHOD_REPO_STATUS, isolated=True)
        self.ctl._fetch_repo(force=True)
        self.client.answer(METHOD_REPO_STATUS, None,
                           error=fakes.ipc.Error("unavailable", "connection closed"),
                           isolated=True)
        self.draw()
        self.assertIs(self.state().repo, good)
        self.assertTrue(self.state().repo_stale)
        self.assertEqual(self.notifier.summaries(), [])
        self.assertIn("last known", self.menu.find("status.location").label)

    def test_the_daemon_saying_unavailable_is_a_verdict(self):
        self.connect()
        self.ctl._fetch_repo(force=True)
        self.client.answer(METHOD_REPO_STATUS,
                           {"available": False, "message": "Snapshot device not available",
                            "details": "no such device"}, isolated=True)
        self.draw()
        self.assertEqual(self.notifier.summaries(),
                         ["Snapshot location unavailable"])
        self.assertIs(self.state().health(self.clock()), Health.ERROR)

    def test_the_unavailable_notification_does_not_crash(self):
        """It used to: `"%s %s" % (a, b).strip()` applies strip to the TUPLE."""
        self.connect()
        self.ctl._fetch_repo(force=True)
        self.client.answer(METHOD_REPO_STATUS,
                           {"available": False, "message": "gone",
                            "details": "really gone"}, isolated=True)
        _summary, body, _urgency, _key = self.notifier.sent[-1]
        self.assertEqual(body, "gone really gone")

    def test_a_refresh_during_a_job_is_deferred_not_dropped(self):
        self.connect()
        self.ctl.on_event(fakes.event("job.started", "j-1", kind="create",
                                      state="running"))
        self.client.answer_all(METHOD_SNAPSHOTS_LIST, [])
        self.ctl.on_event(fakes.event("snapshots.changed"))
        self.assertEqual(self.client.pending(METHOD_SNAPSHOTS_LIST), [])
        self.ctl.on_event(fakes.event("job.finished", "j-1", kind="create",
                                      outcome="ok"))
        self.timers.fire_oneshots(within=5)
        self.assertTrue(self.client.pending(METHOD_SNAPSHOTS_LIST))


class ActionTest(ControllerTest):
    def test_create_runs_the_wrapper(self):
        self.connect()
        self.ctl.on_action(menutree.ACTION_CREATE)
        self.assertIn(actions.CREATE_SNAPSHOT_ARGV, self.spawner.argvs())

    def test_the_latch_is_observable(self):
        """It was dead code: the flag was set and immediately cleared, so the
        item stayed enabled through the whole polkit prompt and a second click
        stacked a second password dialog."""
        self.connect()
        self.ctl.create_snapshot()
        self.assertTrue(self.state().create_pending)
        self.draw()
        self.assertFalse(self.menu.find("action.create").enabled)

    def test_the_latch_expires_if_nobody_answers_the_prompt(self):
        self.connect()
        self.ctl.create_snapshot()
        self.timers.fire_oneshots(within=CREATE_LATCH_SECONDS)
        self.assertFalse(self.state().create_pending)

    def test_the_job_starting_clears_the_latch(self):
        self.connect()
        self.ctl.create_snapshot()
        self.ctl.on_event(fakes.event("job.started", "j-1", kind="create",
                                      state="running"))
        self.assertFalse(self.state().create_pending)

    def test_a_helper_that_will_not_run_says_so(self):
        """Clicking the item used to do nothing at all: no toast, no log."""
        self.spawner.succeed = False
        self.connect()
        self.ctl.create_snapshot()
        self.spawner.fail_last("No such file or directory")
        self.assertEqual(self.notifier.summaries(),
                         ["Could not start the snapshot"])

    def test_granting_access_explains_the_logout(self):
        self.ctl.on_conn_state(ConnState.NO_ACCESS)
        self.ctl.on_action(menutree.ACTION_GRANT)
        self.assertIn(actions.GRANT_ACCESS_ARGV, self.spawner.argvs())
        self.assertEqual(self.notifier.summaries(),
                         ["Timeshift status access enabled"])

    def test_revoking_is_offered_and_works(self):
        self.connect()
        self.assertIsNotNone(self.menu.find("action.revoke"))
        self.ctl.on_action(menutree.ACTION_REVOKE)
        self.assertIn(actions.REVOKE_ACCESS_ARGV, self.spawner.argvs())

    def test_quit_quits(self):
        self.ctl.on_action(menutree.ACTION_QUIT)
        self.assertEqual(self.quits, [True])


class DegradedTest(ControllerTest):
    def test_no_access_offers_the_way_out(self):
        self.ctl.on_conn_state(ConnState.NO_ACCESS)
        self.draw()
        self.assertIsNotNone(self.menu.find("action.grant"))
        self.assertIs(self.state().health(self.clock()), Health.NOACCESS)

    def test_a_brief_disconnect_is_not_alarming(self):
        self.connect()
        self.ctl.on_conn_state(ConnState.DISCONNECTED)
        self.draw()
        self.assertIs(self.state().health(self.clock()), Health.OK)

    def test_a_long_disconnect_is(self):
        """A crash-looping daemon used to leave the healthy icon up forever."""
        self.connect()
        self.ctl.on_conn_state(ConnState.DISCONNECTED)
        self.clock.advance(10 * 60)
        self.assertIs(self.state().health(self.clock()), Health.WARNING)

    def test_the_no_host_warning_is_said_once(self):
        first = self.ctl.warn_no_host()
        self.assertIn("gnome-extensions enable", first)
        self.assertIsNone(self.ctl.warn_no_host())


if __name__ == "__main__":
    unittest.main()
