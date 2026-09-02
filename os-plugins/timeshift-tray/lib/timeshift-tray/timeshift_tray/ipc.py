# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The daemon's line protocol, with no I/O in it.

One JSON object per line, both directions. A response carries the request's
"id"; an event carries "event" and no id. That is the whole classification
rule, and keeping it in a module that cannot open a socket is what lets it be
tested against a recorded stream.
"""

import json


class Frame:
    """Base class for what one line turned out to be."""


class Response(Frame):
    """A reply to a request we sent."""

    __slots__ = ("id", "result", "error")

    def __init__(self, id, result=None, error=None):
        self.id = id
        self.result = result
        self.error = error

    @property
    def ok(self):
        return self.error is None

    def __repr__(self):
        return "Response(id=%r, ok=%r)" % (self.id, self.ok)


class Event(Frame):
    """Something the daemon decided to tell us."""

    __slots__ = ("name", "job", "payload")

    def __init__(self, name, job, payload):
        self.name = name
        self.job = job
        self.payload = payload

    def __repr__(self):
        return "Event(%r, job=%r)" % (self.name, self.job)


class Junk(Frame):
    """A line we could not make sense of.

    Not an exception: one unparseable line must not tear down a connection that
    is otherwise fine, and a daemon that grows a new event type should be
    ignorable by an older client rather than fatal to it.
    """

    __slots__ = ("line", "reason")

    def __init__(self, line, reason):
        self.line = line
        self.reason = reason

    def __repr__(self):
        return "Junk(%r)" % (self.reason,)


class Error:
    """The {"code", "message"} object a failed call returns."""

    __slots__ = ("code", "message")

    def __init__(self, code, message):
        self.code = code
        self.message = message

    def __str__(self):
        return self.message or self.code or "unknown error"

    def __repr__(self):
        return "Error(%r, %r)" % (self.code, self.message)


def encode_request(req_id, method, params=None):
    """One request, newline-terminated, ready to write."""
    obj = {"id": req_id, "method": method}
    if params is not None:
        obj["params"] = params
    # separators without spaces: the daemon does not care, and it keeps the
    # test corpus comparable.
    return json.dumps(obj, separators=(",", ":")) + "\n"


def decode_line(line):
    """Classify one line. Never raises."""
    text = line.strip()
    if not text:
        return Junk(line, "blank line")
    try:
        obj = json.loads(text)
    except ValueError as exc:
        return Junk(line, "not JSON: %s" % exc)
    if not isinstance(obj, dict):
        return Junk(line, "not a JSON object")

    if "event" in obj:
        return Event(obj.get("event") or "", obj.get("job") or "", obj)

    if "id" in obj:
        err = obj.get("error")
        if isinstance(err, dict):
            return Response(obj["id"], None,
                            Error(err.get("code", ""), err.get("message", "")))
        return Response(obj["id"], obj.get("result"), None)

    return Junk(line, "neither a response nor an event")
