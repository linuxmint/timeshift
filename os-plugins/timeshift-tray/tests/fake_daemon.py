# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""A scriptable stand-in for timeshiftd, over a real AF_UNIX socket.

Real socket rather than a mocked stream on purpose: the framing, the partial
reads and the EOF-on-restart behaviour are exactly what there is to get wrong,
and none of them exist in a fake that hands over whole objects.
"""

import json
import os
import socket
import tempfile
import threading

from timeshift_tray.constants import PROTOCOL_VERSION


class FakeDaemon:
    """Answers methods from a table and can be told to misbehave.

    responses: method name -> result object, or a callable(params) -> result.
    Anything not in the table gets an unknown_method error.
    """

    def __init__(self, responses=None, protocol_version=None, hang_methods=(),
                 close_after=None, error_methods=()):
        self.responses = dict(responses or {})
        self.error_methods = set(error_methods)
        # The applet's own version by default. A literal here means every
        # test in the suite fails on the next protocol bump for a reason
        # that has nothing to do with what it is testing.
        self.protocol_version = (PROTOCOL_VERSION if protocol_version is None
                                 else protocol_version)
        self.hang_methods = set(hang_methods)
        self.close_after = close_after      # close the connection after N lines
        self.requests = []                  # (method, params), in order

        self._dir = tempfile.mkdtemp(prefix="timeshift-tray-test-")
        self.path = os.path.join(self._dir, "daemon.sock")
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.path)
        self._server.listen(8)
        self._stop = False
        self._conns = []
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    # -- driving ---------------------------------------------------------------

    def push_event(self, obj):
        """Send one event to every connected client."""
        line = (json.dumps(obj) + "\n").encode("utf-8")
        with self._lock:
            for conn in list(self._conns):
                try:
                    conn.sendall(line)
                except OSError:
                    pass

    def drop_connections(self):
        """What a daemon restart looks like from the client's side."""
        with self._lock:
            conns, self._conns = self._conns, []
        for conn in conns:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()

    def stop(self):
        self._stop = True
        self.drop_connections()
        try:
            self._server.close()
        except OSError:
            pass
        try:
            os.unlink(self.path)
        except OSError:
            pass
        try:
            os.rmdir(self._dir)
        except OSError:
            pass

    # -- serving ---------------------------------------------------------------

    def _accept_loop(self):
        while not self._stop:
            try:
                conn, _addr = self._server.accept()
            except OSError:
                return
            with self._lock:
                self._conns.append(conn)
            threading.Thread(target=self._serve, args=(conn,),
                             daemon=True).start()

    def _serve(self, conn):
        buffered = b""
        served = 0
        while not self._stop:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffered += chunk
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    request = json.loads(line)
                except ValueError:
                    continue
                self.requests.append((request.get("method"),
                                      request.get("params")))
                served += 1
                if self.close_after is not None and served > self.close_after:
                    conn.close()
                    return
                self._answer(conn, request)

    def _answer(self, conn, request):
        method = request.get("method")
        if method in self.hang_methods:
            return                       # answered by nobody, deliberately
        if method in self.error_methods:
            self._write(conn, {"id": request.get("id"),
                               "error": {"code": "denied",
                                         "message": "refused by the fake"}})
            return
        if method == "system.info":
            result = {"version": "test", "protocol_version": self.protocol_version,
                      "engine": "timeshift", "read_only": True}
        elif method in self.responses:
            handler = self.responses[method]
            result = handler(request.get("params")) if callable(handler) else handler
        elif method == "jobs.subscribe":
            # The daemon answers the follow-everything case with an EMPTY
            # snapshot, which is the whole reason jobs.list exists on connect.
            # (Pinned to cmd/timeshiftd/daemon.go: getting this wrong in the
            # fake would hide the bug it exists to expose.)
            result = {}
        else:
            self._write(conn, {"id": request.get("id"),
                               "error": {"code": "unknown_method",
                                         "message": method or ""}})
            return
        self._write(conn, {"id": request.get("id"), "result": result})

    def _write(self, conn, obj):
        try:
            conn.sendall((json.dumps(obj) + "\n").encode("utf-8"))
        except OSError:
            pass
