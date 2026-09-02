# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Framing: what one line off the socket turns out to be."""

import json
import unittest

from timeshift_tray import ipc


class EncodeTest(unittest.TestCase):
    def test_request_is_one_line(self):
        line = ipc.encode_request(7, "snapshots.list", None)
        self.assertTrue(line.endswith("\n"))
        self.assertEqual(line.count("\n"), 1)
        self.assertEqual(json.loads(line), {"id": 7, "method": "snapshots.list"})

    def test_params_are_included_when_given(self):
        line = ipc.encode_request(1, "jobs.subscribe", {"job": "", "with_log": False})
        self.assertEqual(json.loads(line)["params"], {"job": "", "with_log": False})


class DecodeTest(unittest.TestCase):
    def test_result(self):
        frame = ipc.decode_line('{"id":3,"result":{"a":1}}')
        self.assertIsInstance(frame, ipc.Response)
        self.assertEqual(frame.id, 3)
        self.assertTrue(frame.ok)
        self.assertEqual(frame.result, {"a": 1})

    def test_error(self):
        frame = ipc.decode_line(
            '{"id":4,"error":{"code":"denied","message":"requires root"}}')
        self.assertIsInstance(frame, ipc.Response)
        self.assertFalse(frame.ok)
        self.assertEqual(frame.error.code, "denied")
        self.assertEqual(str(frame.error), "requires root")

    def test_event_has_no_id(self):
        frame = ipc.decode_line('{"event":"job.progress","job":"j-7"}')
        self.assertIsInstance(frame, ipc.Event)
        self.assertEqual(frame.name, "job.progress")
        self.assertEqual(frame.job, "j-7")

    def test_event_without_a_job(self):
        """config.changed and snapshots.changed carry no job."""
        frame = ipc.decode_line('{"event":"config.changed"}')
        self.assertIsInstance(frame, ipc.Event)
        self.assertEqual(frame.job, "")

    def test_unknown_event_is_still_an_event(self):
        """A daemon that grows an event must not break an older client."""
        frame = ipc.decode_line('{"event":"job.something-new","job":"j-1"}')
        self.assertIsInstance(frame, ipc.Event)

    def test_garbage_is_junk_not_an_exception(self):
        """One bad line must not tear down a working connection."""
        for text in ("not json at all", "", "   ", "[1,2,3]", "{}"):
            self.assertIsInstance(ipc.decode_line(text), ipc.Junk, text)

    def test_a_very_long_line(self):
        """snapshots.list on a full repository is one large line."""
        payload = [{"Name": "2026-01-%02d_00-00-00" % (i % 28 + 1),
                    "Path": "/mnt/backup/timeshift/snapshots/%d" % i}
                   for i in range(4000)]
        line = json.dumps({"id": 1, "result": payload})
        self.assertGreater(len(line), 200000)
        frame = ipc.decode_line(line)
        self.assertIsInstance(frame, ipc.Response)
        self.assertEqual(len(frame.result), 4000)


if __name__ == "__main__":
    unittest.main()
