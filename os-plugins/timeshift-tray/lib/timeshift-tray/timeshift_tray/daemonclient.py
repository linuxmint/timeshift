# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The connection to timeshiftd.

Three connections, deliberately.

`_req` does request/response and `_evt` issues one jobs.subscribe and then only
reads -- the split src/Core/DaemonClient.vala already uses, because a single
connection carrying both means every synchronous call has to read past events
that arrived first, and a bug in that interleaving looks exactly like one call
returning another call's answer.

The third is per repo.status call and is closed on reply. The daemon answers a
connection's calls in order, and repo.status opens the repository -- for an SSH
location that is a network round trip that can hang for as long as ssh takes to
give up. On a shared connection everything queued behind it would hang too.
"""

import os
import traceback

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import ipc  # noqa: E402
from .constants import (  # noqa: E402
    BACKOFF_LADDER,
    BACKOFF_SLOW,
    METHOD_JOBS_SUBSCRIBE,
    METHOD_SYSTEM_INFO,
    PROTOCOL_VERSION,
    REPO_STATUS_DEADLINE_SECONDS,
    RUN_DIR,
    SOCKET_PATH,
)
from .model import ConnState  # noqa: E402

# snapshots.list on a full repository is a large single line.
_READ_BUFFER = 256 * 1024


def classify_connect_error(err, path=None):
    """Which kind of "cannot talk to the daemon" this is.

    The distinction is the whole point: the socket is 0660 root:timeshift, so a
    non-member is refused by connect(2) itself, and reporting that as "not
    running" sends someone off to start a service that is already up.

    A refusal is checked against the file before it is believed: if access(2)
    says the account may open it, the refusal was transient. The caller adds
    the second half of that defence (see DaemonClient._on_req_connected),
    because at the instant of the refusal the file usually agrees with it.
    """
    if err is None:
        return ConnState.DISCONNECTED
    quark = Gio.io_error_quark()
    if err.matches(quark, Gio.IOErrorEnum.PERMISSION_DENIED):
        if path and os.access(path, os.R_OK | os.W_OK):
            return ConnState.DISCONNECTED
        return ConnState.NO_ACCESS
    if err.matches(quark, Gio.IOErrorEnum.NOT_FOUND):
        return ConnState.NO_DAEMON
    if err.matches(quark, Gio.IOErrorEnum.CONNECTION_REFUSED):
        # A socket file left behind with nothing listening.
        return ConnState.NO_DAEMON
    return ConnState.DISCONNECTED


class _Conn:
    """One socket: a write queue, a read loop, and pending calls by id."""

    def __init__(self, conn, on_frame, on_closed, first_id=1, log=None):
        self._conn = conn
        self._on_frame = on_frame
        self._on_closed = on_closed
        self._log = log or (lambda *_a, **_k: None)
        self._closed = False
        self._next_id = first_id
        self.pending = {}

        self._out = conn.get_output_stream()
        self._in = Gio.DataInputStream.new(conn.get_input_stream())
        self._in.set_newline_type(Gio.DataStreamNewlineType.LF)
        self._in.set_buffer_size(_READ_BUFFER)
        self._writing = False
        self._queue = []
        self._read_next()

    # -- writing ---------------------------------------------------------------

    def send(self, method, params, callback):
        """Queue one request; callback(result, error) when it is answered."""
        req_id = self._next_id
        self._next_id += 1
        if callback is not None:
            self.pending[req_id] = callback
        self._queue.append(ipc.encode_request(req_id, method, params))
        self._pump()
        return req_id

    def _pump(self):
        if self._writing or self._closed or not self._queue:
            return
        self._writing = True
        line = self._queue.pop(0)
        self._out.write_all_async(line.encode("utf-8"), GLib.PRIORITY_DEFAULT,
                                  None, self._on_written)

    def _on_written(self, stream, res):
        self._writing = False
        try:
            stream.write_all_finish(res)
        except GLib.Error as err:
            return self.close(err)
        self._pump()

    # -- reading ---------------------------------------------------------------

    def _read_next(self):
        if self._closed:
            return
        self._in.read_line_async(GLib.PRIORITY_DEFAULT, None, self._on_line)

    def _on_line(self, stream, res):
        try:
            line, _length = stream.read_line_finish_utf8(res)
        except GLib.Error as err:
            return self.close(err)
        if line is None:
            # EOF: the daemon went away, or was restarted under us.
            return self.close(None)
        self._dispatch(line)
        # Re-armed unconditionally, and that is the point of _dispatch's
        # barrier: a handler that raises must not be able to stop this loop.
        # It would stop with the socket still open, so there is no EOF, no
        # close, no retry -- the applet keeps a healthy icon and a menu frozen
        # at whatever it last knew, for the rest of the session.
        self._read_next()

    def _dispatch(self, line):
        frame = ipc.decode_line(line)
        try:
            if isinstance(frame, ipc.Response):
                callback = self.pending.pop(frame.id, None)
                if callback is not None:
                    callback(frame.result, frame.error)
            elif isinstance(frame, ipc.Event):
                self._on_frame(frame)
            else:
                self._log("ignoring unparseable line: %s", frame.reason)
        except Exception:  # noqa: BLE001 - see the comment above
            self._log("handler raised on %r:\n%s", frame,
                      traceback.format_exc().rstrip())

    # -- teardown --------------------------------------------------------------

    def close(self, err):
        if self._closed:
            return
        self._closed = True
        pending, self.pending = self.pending, {}
        try:
            self._conn.close(None)
        except GLib.Error:
            pass
        for callback in pending.values():
            callback(None, ipc.Error("unavailable", "connection closed"))
        if self._on_closed is not None:
            self._on_closed(err)

    @property
    def closed(self):
        return self._closed


class DaemonClient:
    """Connect, stay connected, and report what the daemon says.

    on_state(ConnState) and on_event(ipc.Event) are called on the main loop.
    connect_fn and clock exist so tests can drive both without a real socket.
    """

    def __init__(self, on_state, on_event, socket_path=SOCKET_PATH,
                 connect_fn=None, log=None):
        self._on_state = on_state
        self._on_event = on_event
        self._socket_path = socket_path
        self._connect_fn = connect_fn or self._default_connect
        self._log = log or (lambda *_a, **_k: None)

        self.state = ConnState.STARTING
        self.system = None
        self.daemon_protocol = 0

        self._req = None
        self._evt = None
        self._isolated = []
        # In-flight isolated calls, so stop() can cancel their deadlines
        # rather than leave them to fire into a torn-down client.
        self._isolated_calls = []
        self._attempt = 0
        self._denied = 0
        self._retry_source = None
        self._monitor = None
        self._stopped = False
        self._connecting = False

    # -- lifecycle -------------------------------------------------------------

    def start(self):
        self._watch_run_dir()
        self._connect()

    def stop(self):
        self._stopped = True
        self._cancel_retry()
        for state in list(self._isolated_calls):
            state["done"] = True
            self._retire_isolated(state)
        if self._monitor is not None:
            self._monitor.cancel()
            self._monitor = None
        for conn in [self._req, self._evt] + list(self._isolated):
            if conn is not None:
                conn.close(None)
        self._req = self._evt = None
        self._isolated = []

    def _watch_run_dir(self):
        """Notice the socket appearing instead of waiting out a backoff.

        The unit is socket-activated, so a tight retry loop would keep starting
        the daemon; this is what lets the retry ladder stay slow without the
        tray looking dead for half a minute after the service comes up.
        """
        try:
            directory = Gio.File.new_for_path(RUN_DIR)
            self._monitor = directory.monitor_directory(
                Gio.FileMonitorFlags.NONE, None)
            self._monitor.connect("changed", self._on_run_dir_changed)
        except GLib.Error as err:
            self._log("no monitor on %s: %s", RUN_DIR, err.message)
            self._monitor = None

    def _on_run_dir_changed(self, _monitor, gfile, _other, event):
        if event not in (Gio.FileMonitorEvent.CREATED,
                         Gio.FileMonitorEvent.CHANGES_DONE_HINT):
            return
        if gfile.get_path() != self._socket_path:
            return
        if self.state in (ConnState.NO_DAEMON, ConnState.DISCONNECTED):
            self._cancel_retry()
            self._connect()

    # -- connecting ------------------------------------------------------------

    def _default_connect(self, callback):
        client = Gio.SocketClient.new()
        address = Gio.UnixSocketAddress.new(self._socket_path)

        def done(source, res):
            try:
                callback(source.connect_finish(res), None)
            except GLib.Error as err:
                callback(None, err)

        client.connect_async(address, None, done)

    def _connect(self):
        if self._stopped or self._connecting:
            return
        self._connecting = True
        self._connect_fn(self._on_req_connected)

    def _on_req_connected(self, conn, err):
        self._connecting = False
        if self._stopped:
            if conn is not None:
                conn.close(None)
            return
        if conn is None:
            return self._fail(self._classify(err))
        self._denied = 0
        if self._req is not None and not self._req.closed:
            # Refuse to orphan a live connection. An orphan is worse than a
            # leaked fd: it keeps re-arming its own read loop, so it is never
            # collected, and when its socket eventually closes its _on_closed
            # tears down the connection that REPLACED it.
            self._log("already connected; dropping a redundant connection")
            conn.close(None)
            return
        self._req = _Conn(conn, self._ignore_event, self._on_req_closed,
                          log=self._log)
        self._req.send(METHOD_SYSTEM_INFO, None, self._on_system_info)

    def _classify(self, err):
        """classify_connect_error, with NO_ACCESS believed only the second time.

        systemd binds the socket and chowns it afterwards, so a member who
        connects in that gap is refused by a socket that is root:root for a
        few milliseconds -- and at that instant access(2) agrees with the
        refusal. NO_ACCESS is then retried every five minutes, on the
        reasoning that group membership cannot change without a login. Seen
        for real: one restart of timeshiftd.socket left the applet saying
        "not permitted" for the next five minutes over a perfectly readable
        socket. So the first refusal is treated as a disconnect and retried on
        the ladder; only a refusal that survives the retry is a verdict.
        """
        state = classify_connect_error(err, self._socket_path)
        if state is not ConnState.NO_ACCESS:
            self._denied = 0
            return state
        self._denied += 1
        if self._denied < 2:
            self._log("refused; checking again before concluding no access")
            return ConnState.DISCONNECTED
        return state

    def _on_system_info(self, result, error):
        if error is not None:
            # An ERROR REPLY, not a transport failure: the socket is still open
            # and healthy, so it has to be dropped explicitly or the retry
            # orphans it.
            self._log("system.info failed: %s", error)
            self._drop_connections()
            return self._fail(ConnState.DISCONNECTED)
        info = result or {}
        protocol = info.get("protocol_version")
        protocol = int(protocol) if isinstance(protocol, (int, float)) else 0
        if protocol != PROTOCOL_VERSION:
            # Strict, like the Go CLI: JSON ignores what it does not know, so a
            # daemon speaking a different protocol answers confidently about
            # something other than what was asked.
            self.daemon_protocol = protocol
            self._drop_connections()
            return self._fail(ConnState.PROTOCOL_MISMATCH)
        self.system = info
        self._attempt = 0
        self._denied = 0
        self._open_event_connection()

    def _open_event_connection(self):
        def connected(conn, err):
            if self._stopped:
                if conn is not None:
                    conn.close(None)
                return
            if conn is None:
                # The request connection succeeded and answered; only the
                # second connect failed. Drop the first, or the retry orphans
                # it.
                self._log("event connection failed: %s",
                          err.message if err else "?")
                self._drop_connections()
                return self._fail(classify_connect_error(err))
            self._evt = _Conn(conn, self._on_event, self._on_evt_closed,
                              log=self._log)
            # The reply to this is an EMPTY snapshot for the follow-everything
            # case (cmd/timeshiftd/daemon.go), so it is deliberately discarded:
            # a job already in flight is found with jobs.list instead.
            self._evt.send(METHOD_JOBS_SUBSCRIBE,
                           {"job": "", "with_log": False}, None)
            self._enter(ConnState.READY)

        self._connect_fn(connected)

    def _ignore_event(self, _frame):
        """Events never arrive on the request connection; drop them quietly."""

    def _on_req_closed(self, _err):
        if self._stopped or self.state is ConnState.PROTOCOL_MISMATCH:
            return
        self._req = None
        self._drop_connections()
        self._fail(ConnState.DISCONNECTED)

    def _on_evt_closed(self, _err):
        if self._stopped or self.state is ConnState.PROTOCOL_MISMATCH:
            return
        self._evt = None
        self._drop_connections()
        self._fail(ConnState.DISCONNECTED)

    def _drop_connections(self):
        for conn in (self._req, self._evt):
            if conn is not None:
                conn._on_closed = None
                conn.close(None)
        self._req = self._evt = None

    # -- state and retry -------------------------------------------------------

    def _enter(self, state):
        if state != self.state:
            self.state = state
            self._on_state(state)

    def _fail(self, state):
        self._enter(state)
        self._schedule_retry(state)

    def _cancel_retry(self):
        if self._retry_source is not None:
            GLib.source_remove(self._retry_source)
            self._retry_source = None

    def retry_delay(self, state, attempt):
        """Seconds before the next attempt.

        Group membership is fixed at login and a protocol version changes only
        when the service is replaced, so retrying either quickly cannot
        succeed; the ladder is for the cases that genuinely resolve themselves.
        """
        if state in (ConnState.NO_ACCESS, ConnState.PROTOCOL_MISMATCH):
            return BACKOFF_SLOW
        index = min(attempt, len(BACKOFF_LADDER) - 1)
        return BACKOFF_LADDER[index]

    def _schedule_retry(self, state):
        if self._stopped:
            return
        self._cancel_retry()
        delay = self.retry_delay(state, self._attempt)
        self._attempt += 1

        def fire():
            self._retry_source = None
            self._connect()
            return GLib.SOURCE_REMOVE

        self._retry_source = GLib.timeout_add_seconds(delay, fire)

    def retry_now(self):
        """Try again immediately -- used after the grant helper succeeds.

        A no-op when already connected. Reconnecting from READY would open a
        second event connection, and then every job event would be delivered
        twice.
        """
        if self.state is ConnState.READY:
            return
        self._cancel_retry()
        self._attempt = 0
        self._denied = 0
        self._connect()

    # -- calls -----------------------------------------------------------------

    def call(self, method, params, callback):
        """A read-only call on the shared request connection."""
        if self._req is None or self._req.closed:
            callback(None, ipc.Error("unavailable", "not connected"))
            return
        self._req.send(method, params, callback)

    def call_isolated(self, method, params, callback,
                      deadline=REPO_STATUS_DEADLINE_SECONDS):
        """A call on a connection of its own, abandoned after `deadline`.

        For repo.status, which can block on an unreachable SSH host: the daemon
        answers one connection's calls in order, so a hung location check would
        otherwise stall every cheap call queued behind it. The tray must be able
        to stop waiting without killing anything.
        """
        state = {"done": False, "timer": 0, "channel": None}

        def deliver(result, error):
            """Answer the caller exactly once, and always close the channel.

            The close comes first and inside a finally, because `callback` is
            the caller's code: a handler that raises must not be able to leave
            the connection open. That is not hypothetical -- it is how one
            formatting bug in the repo-unavailable notification leaked an fd
            per call for the life of the session.
            """
            if state["done"]:
                return
            state["done"] = True
            try:
                self._retire_isolated(state)
            finally:
                callback(result, error)

        def connected(conn, err):
            if conn is None:
                return deliver(None, ipc.Error(
                    "unavailable", err.message if err else "not connected"))
            # stop() empties self._isolated; a connect still in flight must not
            # re-populate it or call back into a torn-down client.
            if state["done"] or self._stopped:
                conn.close(None)
                return

            def closed(_err):
                channel = state["channel"]
                if channel in self._isolated:
                    self._isolated.remove(channel)

            channel = _Conn(conn, self._ignore_event, closed, log=self._log)
            state["channel"] = channel
            self._isolated.append(channel)
            self._isolated_calls.append(state)

            channel.send(method, params, deliver)

            def expire():
                state["timer"] = 0
                deliver(None, ipc.Error("unavailable",
                                        "%s timed out" % method))
                return GLib.SOURCE_REMOVE

            state["timer"] = GLib.timeout_add_seconds(deadline, expire)

        self._connect_fn(connected)

    def _retire_isolated(self, state):
        """Cancel the deadline and close the channel, idempotently."""
        if state["timer"]:
            GLib.source_remove(state["timer"])
            state["timer"] = 0
        channel = state["channel"]
        if channel is not None:
            # Detach the closed callback first: closing is what we are doing,
            # not news to react to.
            channel._on_closed = None
            channel.close(None)
            if channel in self._isolated:
                self._isolated.remove(channel)
            state["channel"] = None
        if state in self._isolated_calls:
            self._isolated_calls.remove(state)
