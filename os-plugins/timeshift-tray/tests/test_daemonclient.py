# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The connection, against a real socket that can misbehave on cue.

Each test runs a GLib main loop with a watchdog, so a hang fails the run
instead of stopping it.
"""

import json
import os
import unittest

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from fake_daemon import FakeDaemon  # noqa: E402
from timeshift_tray import daemonclient  # noqa: E402
from timeshift_tray.model import ConnState  # noqa: E402


class LoopHarness(unittest.TestCase):
    def setUp(self):
        self.loop = GLib.MainLoop()
        self.states = []
        self.events = []
        self.daemon = None
        self.client = None
        self._watchdog = None

    def tearDown(self):
        if self.client is not None:
            self.client.stop()
        if self.daemon is not None:
            self.daemon.stop()
        if self._watchdog is not None:
            GLib.source_remove(self._watchdog)

    def start(self, daemon, **kwargs):
        self.daemon = daemon
        self.client = daemonclient.DaemonClient(
            self._on_state, self._on_event, socket_path=daemon.path, **kwargs)
        self.client.start()

    def _on_state(self, state):
        self.states.append(state)

    def _on_event(self, event):
        self.events.append(event)

    def run_until(self, predicate, timeout_ms=5000):
        done = {"polled": False, "expired": False}

        def check():
            if predicate():
                done["polled"] = True
                self.loop.quit()
                return GLib.SOURCE_REMOVE
            return GLib.SOURCE_CONTINUE

        def expire():
            done["expired"] = True
            self.loop.quit()
            return GLib.SOURCE_REMOVE

        poll = GLib.timeout_add(20, check)
        self._watchdog = GLib.timeout_add(timeout_ms, expire)
        self.loop.run()
        if not done["polled"]:
            GLib.source_remove(poll)
        if not done["expired"]:
            GLib.source_remove(self._watchdog)
        self._watchdog = None
        if done["expired"]:
            self.fail("timed out waiting; states=%s"
                      % [s.value for s in self.states])


class HandshakeTest(LoopHarness):
    def test_reaches_ready(self):
        self.start(FakeDaemon())
        self.run_until(lambda: ConnState.READY in self.states)
        methods = [m for m, _p in self.daemon.requests]
        self.assertEqual(methods[0], "system.info")
        self.assertIn("jobs.subscribe", methods)

    def test_a_different_protocol_is_refused_by_name(self):
        """Strict inequality, like the CLI's own check.

        JSON ignores fields it does not understand, so a daemon speaking
        another protocol does not fail -- it answers confidently about
        something else.
        """
        self.start(FakeDaemon(protocol_version=3))
        self.run_until(lambda: ConnState.PROTOCOL_MISMATCH in self.states)
        self.assertEqual(self.client.daemon_protocol, 3)
        self.assertNotIn(ConnState.READY, self.states)

    def test_subscribing_to_everything_answers_with_nothing(self):
        """Which is why jobs.list exists on connect, and this pins it."""
        daemon = FakeDaemon()
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)
        answers = []
        self.client.call("jobs.subscribe", {"job": "", "with_log": False},
                         lambda result, error: answers.append(result))
        self.run_until(lambda: answers)
        self.assertEqual(answers[0], {})


class CallTest(LoopHarness):
    def test_results_go_to_the_right_caller(self):
        daemon = FakeDaemon(responses={
            "schedule.status": {"enabled": True, "running": True},
            "snapshots.list": [{"Name": "2026-09-01_09-00-00"}],
        })
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)

        got = {}
        self.client.call("schedule.status", None,
                         lambda r, e: got.__setitem__("schedule", r))
        self.client.call("snapshots.list", None,
                         lambda r, e: got.__setitem__("snapshots", r))
        self.run_until(lambda: len(got) == 2)
        self.assertEqual(got["schedule"]["enabled"], True)
        self.assertEqual(got["snapshots"][0]["Name"], "2026-09-01_09-00-00")

    def test_an_event_arriving_mid_call_does_not_confuse_it(self):
        daemon = FakeDaemon(responses={"schedule.status": {"enabled": True}})
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)
        daemon.push_event({"event": "job.started", "job": "j-4",
                           "kind": "create", "state": "running"})
        got = []
        self.client.call("schedule.status", None,
                         lambda r, e: got.append((r, e)))
        self.run_until(lambda: got and self.events)
        self.assertIsNone(got[0][1])
        self.assertEqual(got[0][0], {"enabled": True})
        self.assertEqual(self.events[0].name, "job.started")

    def test_an_error_reply_is_reported_not_raised(self):
        self.start(FakeDaemon())
        self.run_until(lambda: ConnState.READY in self.states)
        got = []
        self.client.call("snapshot.create", None,
                         lambda r, e: got.append((r, e)))
        self.run_until(lambda: got)
        self.assertIsNotNone(got[0][1])
        self.assertEqual(got[0][1].code, "unknown_method")


class IsolationTest(LoopHarness):
    def test_repo_status_gets_its_own_connection(self):
        """So a location check blocked on ssh cannot stall anything else."""
        daemon = FakeDaemon(responses={"repo.status": {"available": True},
                                       "schedule.status": {"enabled": True}})
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)
        got = []
        self.client.call_isolated("repo.status", None,
                                  lambda r, e: got.append((r, e)))
        self.run_until(lambda: got)
        self.assertEqual(got[0][0], {"available": True})

    def test_a_hung_call_is_abandoned_rather_than_waited_on(self):
        daemon = FakeDaemon(responses={"schedule.status": {"enabled": True}},
                            hang_methods=["repo.status"])
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)

        got = []
        self.client.call_isolated("repo.status", None,
                                  lambda r, e: got.append((r, e)), deadline=1)
        # The cheap call behind it must still be answered while repo.status
        # hangs; that is the entire reason for the separate connection.
        quick = []
        self.client.call("schedule.status", None,
                         lambda r, e: quick.append(r))
        self.run_until(lambda: quick)
        self.assertEqual(quick[0], {"enabled": True})

        self.run_until(lambda: got, timeout_ms=4000)
        self.assertIsNone(got[0][0])
        self.assertIn("timed out", str(got[0][1]))


class ReconnectTest(LoopHarness):
    def test_a_restart_is_noticed_and_recovered_from(self):
        daemon = FakeDaemon()
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)
        daemon.drop_connections()
        self.run_until(lambda: ConnState.DISCONNECTED in self.states)
        self.run_until(
            lambda: self.states.count(ConnState.READY) >= 2, timeout_ms=8000)


class ClassifyTest(unittest.TestCase):
    """The three failures a client must tell apart.

    Reporting a permission problem as "the service is not running" sends
    somebody off to start something that is already up.
    """

    def error(self, code):
        return GLib.Error.new_literal(Gio.io_error_quark(), "test", int(code))

    def test_permission_denied_is_not_a_missing_daemon(self):
        self.assertIs(
            daemonclient.classify_connect_error(
                self.error(Gio.IOErrorEnum.PERMISSION_DENIED)),
            ConnState.NO_ACCESS)

    def test_not_found_is_a_missing_daemon(self):
        self.assertIs(
            daemonclient.classify_connect_error(
                self.error(Gio.IOErrorEnum.NOT_FOUND)),
            ConnState.NO_DAEMON)

    def test_a_stale_socket_file_is_also_a_missing_daemon(self):
        self.assertIs(
            daemonclient.classify_connect_error(
                self.error(Gio.IOErrorEnum.CONNECTION_REFUSED)),
            ConnState.NO_DAEMON)

    def test_a_refusal_the_file_contradicts_is_transient(self):
        """systemd binds, then chowns: a member connecting in between is refused
        by a socket that is root:root for milliseconds. If access(2) says we
        may open it, that is what happened, and it gets the ladder rather than
        the five-minute NO_ACCESS retry."""
        daemon = FakeDaemon()
        try:
            denied = self.error(Gio.IOErrorEnum.PERMISSION_DENIED)
            self.assertIs(
                daemonclient.classify_connect_error(denied, daemon.path),
                ConnState.DISCONNECTED)
            os.chmod(daemon.path, 0o000)
            if os.geteuid() != 0:
                self.assertIs(
                    daemonclient.classify_connect_error(denied, daemon.path),
                    ConnState.NO_ACCESS)
        finally:
            os.chmod(daemon.path, 0o755)
            daemon.stop()
        # No path to check against: the error is believed as it stands.
        self.assertIs(daemonclient.classify_connect_error(denied),
                      ConnState.NO_ACCESS)
        self.assertIs(daemonclient.classify_connect_error(denied, "/nonexistent"),
                      ConnState.NO_ACCESS)

    def test_anything_else_is_merely_disconnected(self):
        self.assertIs(
            daemonclient.classify_connect_error(
                self.error(Gio.IOErrorEnum.TIMED_OUT)),
            ConnState.DISCONNECTED)


class SecondOpinionTest(unittest.TestCase):
    """A refusal is believed the second time, not the first."""

    def denied(self):
        return GLib.Error.new_literal(Gio.io_error_quark(), "denied",
                                      int(Gio.IOErrorEnum.PERMISSION_DENIED))

    def test_the_first_refusal_is_a_disconnect(self):
        states = []
        client = daemonclient.DaemonClient(states.append, lambda _e: None,
                                           socket_path="/nonexistent",
                                           connect_fn=lambda cb: None)
        try:
            client._on_req_connected(None, self.denied())
            self.assertEqual(states, [ConnState.DISCONNECTED])
            client._on_req_connected(None, self.denied())
            self.assertEqual(states, [ConnState.DISCONNECTED, ConnState.NO_ACCESS])
        finally:
            client.stop()

    def test_anything_in_between_resets_the_count(self):
        states = []
        client = daemonclient.DaemonClient(states.append, lambda _e: None,
                                           socket_path="/nonexistent",
                                           connect_fn=lambda cb: None)
        try:
            client._on_req_connected(None, self.denied())
            refused = GLib.Error.new_literal(
                Gio.io_error_quark(), "refused",
                int(Gio.IOErrorEnum.CONNECTION_REFUSED))
            client._on_req_connected(None, refused)
            client._on_req_connected(None, self.denied())
            self.assertNotIn(ConnState.NO_ACCESS, states)
        finally:
            client.stop()


class BackoffTest(unittest.TestCase):
    def test_the_ladder_climbs_and_stops(self):
        client = daemonclient.DaemonClient(lambda _s: None, lambda _e: None,
                                           connect_fn=lambda cb: None)
        delays = [client.retry_delay(ConnState.DISCONNECTED, n)
                  for n in range(8)]
        self.assertEqual(delays[:3], [1, 2, 4])
        self.assertEqual(delays[-1], 30)

    def test_what_cannot_change_quickly_is_not_retried_quickly(self):
        """Group membership is fixed at login; a protocol version at install."""
        client = daemonclient.DaemonClient(lambda _s: None, lambda _e: None,
                                           connect_fn=lambda cb: None)
        for state in (ConnState.NO_ACCESS, ConnState.PROTOCOL_MISMATCH):
            self.assertEqual(client.retry_delay(state, 0), 300, state)


class RealSocketPermissionTest(unittest.TestCase):
    def test_a_socket_we_may_not_open_reports_no_access(self):
        """Not a synthesised error: a real 0000-mode socket, refused by connect."""
        daemon = FakeDaemon()
        try:
            os.chmod(daemon.path, 0o000)
            if os.geteuid() == 0:
                self.skipTest("root can open anything")
            client = Gio.SocketClient.new()
            with self.assertRaises(GLib.Error) as caught:
                client.connect(Gio.UnixSocketAddress.new(daemon.path), None)
            self.assertIs(daemonclient.classify_connect_error(caught.exception),
                          ConnState.NO_ACCESS)
        finally:
            os.chmod(daemon.path, 0o755)
            daemon.stop()


class ResilienceTest(LoopHarness):
    """The three ways a connection used to break and never recover."""

    def test_a_raising_handler_does_not_stop_the_read_loop(self):
        """Without a barrier the loop stops with the socket still OPEN, so
        there is no EOF, no close, no retry -- the applet keeps a healthy icon
        and a frozen menu for the rest of the session."""
        daemon = FakeDaemon(responses={"schedule.status": {"enabled": True}})
        boom = {"raised": False}

        def exploding(_event):
            boom["raised"] = True
            raise ValueError("handler bug")

        self.daemon = daemon
        self.client = daemonclient.DaemonClient(
            self._on_state, exploding, socket_path=daemon.path)
        self.client.start()
        self.run_until(lambda: ConnState.READY in self.states)

        daemon.push_event({"event": "job.started", "job": "j-1"})
        self.run_until(lambda: boom["raised"])

        # The loop survived: a later call still gets its answer.
        got = []
        self.client.call("schedule.status", None, lambda r, e: got.append(r))
        self.run_until(lambda: got)
        self.assertEqual(got[0], {"enabled": True})

    def test_an_error_reply_to_the_handshake_does_not_orphan_the_socket(self):
        """An error REPLY is not a transport failure: the socket is still open
        and healthy, and the retry used to build a second one beside it."""
        self.start(FakeDaemon(error_methods=["system.info"]))
        self.run_until(lambda: ConnState.DISCONNECTED in self.states)
        self.assertIsNone(self.client._req)

    def test_retry_now_while_connected_is_a_no_op(self):
        """Reconnecting from READY opened a SECOND event connection, and then
        every job event was delivered twice."""
        daemon = FakeDaemon()
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)
        before = daemon.requests.count(("jobs.subscribe", {"job": "", "with_log": False}))
        self.client.retry_now()
        self.run_until(lambda: True)
        after = daemon.requests.count(("jobs.subscribe", {"job": "", "with_log": False}))
        self.assertEqual(before, after)

    def test_an_isolated_call_leaves_nothing_behind(self):
        daemon = FakeDaemon(responses={"repo.status": {"available": True}})
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)
        got = []
        self.client.call_isolated("repo.status", None,
                                  lambda r, e: got.append(r))
        self.run_until(lambda: got)
        self.assertEqual(self.client._isolated, [])
        self.assertEqual(self.client._isolated_calls, [])

    def test_an_isolated_call_whose_handler_raises_still_closes(self):
        """It did not, and that leaked one fd per call for the life of the
        session -- reached by a formatting bug in the very notification that
        fires when the backup location goes away."""
        daemon = FakeDaemon(responses={"repo.status": {"available": True}})
        self.start(daemon)
        self.run_until(lambda: ConnState.READY in self.states)
        raised = {"yes": False}

        def exploding(_result, _error):
            raised["yes"] = True
            raise ValueError("handler bug")

        self.client.call_isolated("repo.status", None, exploding)
        try:
            self.run_until(lambda: raised["yes"])
        except Exception:
            pass
        self.assertEqual(self.client._isolated, [])


if __name__ == "__main__":
    unittest.main()
