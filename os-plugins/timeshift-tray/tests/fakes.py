# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Recorders standing in for the controller's collaborators.

Every one of them is deliberately dumb: they record what they were asked to do
and let the test decide when a reply arrives. That is what makes an ordering --
"this reply lands after that event" -- something a test can state directly
instead of hoping for.
"""

import datetime

from timeshift_tray import ipc
from timeshift_tray.model import ConnState


class FakeClock:
    def __init__(self, start=None):
        self.now = start or datetime.datetime(2026, 9, 1, 12, 0,
                                              tzinfo=datetime.timezone.utc)

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += datetime.timedelta(seconds=seconds)


class FakeTimers:
    """Timers that only fire when a test says so."""

    def __init__(self):
        self._next = 1
        self.repeating = {}     # handle -> (seconds, callback)
        self.oneshots = {}      # handle -> (seconds, callback)

    def _add(self, table, seconds, callback):
        handle = self._next
        self._next += 1
        table[handle] = (seconds, callback)
        return handle

    def every(self, seconds, callback):
        return self._add(self.repeating, seconds, callback)

    def once(self, seconds, callback):
        return self._add(self.oneshots, seconds, callback)

    def once_ms(self, milliseconds, callback):
        return self._add(self.oneshots, milliseconds / 1000.0, callback)

    def cancel(self, handle):
        self.repeating.pop(handle, None)
        self.oneshots.pop(handle, None)

    # -- driving ---------------------------------------------------------------

    def intervals(self):
        return sorted(seconds for seconds, _cb in self.repeating.values())

    def fire_repeating(self, seconds):
        """Fire every repeating timer registered at this interval."""
        for _handle, (every, callback) in list(self.repeating.items()):
            if every == seconds:
                callback()

    def fire_oneshots(self, within=1.0):
        """Fire the one-shots due within `within` seconds, and anything they
        schedule that is also due.

        Bounded by the delay, not fired wholesale: a 0.5s menu redraw and a
        60s latch expiry are different events, and a fake that fires both at
        once cannot tell a test that the latch was ever observable.
        """
        for _round in range(10):
            pending = [(h, d, cb) for h, (d, cb) in self.oneshots.items()
                       if d <= within]
            if not pending:
                return
            for handle, _delay, callback in pending:
                if handle in self.oneshots:
                    del self.oneshots[handle]
                    callback()


class FakeClient:
    """Records calls; the test supplies the replies."""

    def __init__(self):
        self.calls = []          # (method, params, callback)
        self.isolated = []       # (method, params, callback)
        self.started = False
        self.stopped = False
        self.retried = 0
        self.state = ConnState.STARTING
        self.system = {"protocol_version": 2, "version": "test"}
        self.daemon_protocol = 2

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def retry_now(self):
        self.retried += 1

    def call(self, method, params, callback):
        self.calls.append((method, params, callback))

    def call_isolated(self, method, params, callback, **_kwargs):
        self.isolated.append((method, params, callback))

    # -- driving ---------------------------------------------------------------

    def methods(self):
        return [m for m, _p, _cb in self.calls]

    def pending(self, method, isolated=False):
        table = self.isolated if isolated else self.calls
        return [entry for entry in table if entry[0] == method]

    def answer(self, method, result, error=None, isolated=False):
        """Answer the OLDEST outstanding call to `method`."""
        table = self.isolated if isolated else self.calls
        for index, (name, _params, callback) in enumerate(table):
            if name == method:
                del table[index]
                callback(result, error)
                return True
        raise AssertionError("no outstanding call to %s (have %s)"
                             % (method, [e[0] for e in table]))

    def answer_all(self, method, result, error=None, isolated=False):
        count = 0
        while True:
            try:
                self.answer(method, result, error, isolated=isolated)
            except AssertionError:
                return count
            count += 1


class FakeMenu:
    def __init__(self):
        self.trees = []

    def set_tree(self, root):
        self.trees.append(root)

    @property
    def last(self):
        return self.trees[-1] if self.trees else None

    def labels(self):
        return [n.label for n in self.last.walk() if n.id and n.visible]

    def find(self, key):
        for node in self.last.walk():
            if node.key == key:
                return node
        return None


class FakeItem:
    def __init__(self):
        self.icon = None
        self.attention = False
        self.tooltip = ("", "")
        self.activation_token = ""
        self.registered = False

    def set_icon(self, name, attention=False):
        self.icon = name
        self.attention = attention

    def set_tooltip(self, title, body, icon=""):
        self.tooltip = (title, body)
        self.tooltip_icon = icon


class FakeNotifier:
    def __init__(self):
        self.sent = []           # (summary, body, urgency, key)
        self.icons = []          # the icon of each, in the same order

    def send(self, summary, body, urgency=1, icon="timeshift", key=None,
             actions=True):
        self.sent.append((summary, body, urgency, key))
        self.icons.append(icon)

    def summaries(self):
        return [summary for summary, _b, _u, _k in self.sent]

    def bodies(self):
        return [body for _s, body, _u, _k in self.sent]


class FakeSpawner:
    def __init__(self, succeed=True):
        self.runs = []           # (argv, callback)
        self.activation_token = ""
        self.succeed = succeed

    def run(self, argv, on_exit=None):
        self.runs.append((list(argv), on_exit))
        if on_exit is not None and self.succeed:
            on_exit(True, "")

    def fail_last(self, message="boom"):
        _argv, on_exit = self.runs[-1]
        if on_exit is not None:
            on_exit(False, message)

    def argvs(self):
        return [argv for argv, _cb in self.runs]


def event(name, job="", **payload):
    """One wire event, in the shape ipc.decode_line produces."""
    obj = {"event": name}
    if job:
        obj["job"] = job
    obj.update(payload)
    return ipc.Event(name, job, obj)
