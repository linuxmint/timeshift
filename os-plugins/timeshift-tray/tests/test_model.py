# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Parsing the daemon's replies, against real captured ones."""

import json
import os
import unittest

from timeshift_tray import model

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def corpus(name):
    with open(os.path.join(DATA, name), "r") as handle:
        return json.load(handle)


class SystemInfoTest(unittest.TestCase):
    def test_real_reply(self):
        info = model.SystemInfo.from_wire(corpus("system_info.json"))
        self.assertEqual(info.protocol_version, 2)
        self.assertEqual(info.engine, "timeshift")
        self.assertFalse(info.live)


class ScheduleTest(unittest.TestCase):
    def test_real_reply(self):
        status = model.ScheduleStatus.from_wire(corpus("schedule_status.json"))
        self.assertTrue(status.enabled)
        self.assertTrue(status.running)
        self.assertIsNotNone(status.next_run)
        self.assertEqual(status.interval_seconds, 600)

    def test_unset_times_are_never_not_the_year_one(self):
        status = model.ScheduleStatus.from_wire(
            {"enabled": True, "running": True,
             "last_run": "0001-01-01T00:00:00Z",
             "next_run": "0001-01-01T00:00:00Z"})
        self.assertIsNone(status.last_run)
        self.assertIsNone(status.next_run)


class RepoTest(unittest.TestCase):
    def test_real_reply(self):
        repo = model.RepoStatus.from_wire(corpus("repo_status.json"))
        self.assertTrue(repo.available)
        self.assertTrue(repo.has_snapshots)
        self.assertEqual(repo.message, "OK")
        # Free space lives here and nowhere else, which is why it is shown
        # verbatim instead of recomputed.
        self.assertIn("free", repo.details)


class SnapshotTest(unittest.TestCase):
    def test_go_field_names(self):
        """engines.Snapshot has no json tags, so the wire is PascalCase.

        Reading snake_case here is not a cosmetic mistake: every field comes
        back empty and a full repository reports itself as having no snapshots.
        """
        snapshots = [model.Snapshot.from_wire(o)
                     for o in corpus("snapshots_list.json")]
        self.assertEqual(len(snapshots), 26)
        newest = snapshots[0]
        self.assertEqual(newest.name, "2026-08-30_21-45-59")
        self.assertIsNotNone(newest.created)
        self.assertIn("ondemand", newest.tags)
        self.assertGreater(newest.size_bytes, 0)
        self.assertTrue(newest.valid)

    def test_snake_case_is_accepted_too(self):
        snap = model.Snapshot.from_wire(
            {"name": "2026-08-30_21-45-59", "tags": ["daily"], "valid": True})
        self.assertEqual(snap.name, "2026-08-30_21-45-59")
        self.assertEqual(snap.tags, ["daily"])

    def test_an_unparseable_created_falls_back_to_the_directory_name(self):
        """The name IS the timestamp.

        A snapshot dated to the epoch reads as older than everything, which is
        how retention comes to delete the wrong one.
        """
        snap = model.Snapshot.from_wire(
            {"Name": "2026-08-30_21-45-59", "Created": "not a date"})
        self.assertIsNotNone(snap.created)
        self.assertEqual(snap.created.year, 2026)
        self.assertEqual(snap.created.hour, 21)


class JobTest(unittest.TestCase):
    def test_real_reply(self):
        jobs = [model.Job.from_wire(o) for o in corpus("jobs_list.json")]
        self.assertTrue(jobs)
        job = jobs[0]
        self.assertEqual(job.kind, "create")
        self.assertIn(job.state, model.TERMINAL_STATES)
        self.assertFalse(job.active)
        self.assertEqual(job.outcome, "ok")
        self.assertEqual(job.progress.total, 286021)

    def test_zero_total_is_indeterminate(self):
        job = model.Job.from_wire(
            {"id": "j-9", "state": "running", "kind": "create",
             "progress": {"percent": 0, "count": 0, "total": 0,
                          "eta_seconds": -1}})
        self.assertTrue(job.active)
        self.assertTrue(job.progress.indeterminate)


class HealthTest(unittest.TestCase):
    def ready(self):
        state = model.TrayState()
        state.conn = model.ConnState.READY
        state.system = model.SystemInfo.from_wire(corpus("system_info.json"))
        state.schedule = model.ScheduleStatus.from_wire(
            corpus("schedule_status.json"))
        state.repo = model.RepoStatus.from_wire(corpus("repo_status.json"))
        state.snapshots = [model.Snapshot.from_wire(o)
                           for o in corpus("snapshots_list.json")]
        return state

    def test_healthy(self):
        self.assertIs(self.ready().health(), model.Health.OK)

    def test_no_access(self):
        state = model.TrayState()
        state.conn = model.ConnState.NO_ACCESS
        self.assertIs(state.health(), model.Health.NOACCESS)

    def test_no_daemon_and_protocol_mismatch_are_errors(self):
        for conn in (model.ConnState.NO_DAEMON,
                     model.ConnState.PROTOCOL_MISMATCH):
            state = model.TrayState()
            state.conn = conn
            self.assertIs(state.health(), model.Health.ERROR, conn)

    def test_running_job_is_busy_not_a_problem(self):
        state = self.ready()
        state.job = model.Job(id="j-3", kind="create", state="running")
        self.assertIs(state.health(), model.Health.BUSY)

    def test_stalled_scheduler_warns(self):
        state = self.ready()
        state.schedule.running = False
        self.assertTrue(state.scheduler_stalled)
        self.assertIs(state.health(), model.Health.WARNING)

    def test_a_live_session_is_not_a_stalled_scheduler(self):
        """Live.Status exists precisely so a client does not cry wolf here."""
        state = self.ready()
        state.schedule.running = False
        state.schedule.live = True
        self.assertFalse(state.scheduler_stalled)
        self.assertIs(state.health(), model.Health.OK)

    def test_unreachable_repository_is_an_error(self):
        state = self.ready()
        state.repo = model.RepoStatus.from_wire(
            {"available": False, "message": "Remote location not available",
             "details": "ssh: connect to host 10.2.45.108 port 22: No route"})
        self.assertIs(state.health(), model.Health.ERROR)

    def test_latest_ignores_the_pre_restore_snapshot(self):
        state = self.ready()
        live = model.Snapshot.from_wire(
            {"Name": "2026-09-01_10-00-00", "Live": True, "Valid": True})
        state.snapshots.insert(0, live)
        self.assertNotEqual(state.latest.name, live.name)


if __name__ == "__main__":
    unittest.main()
