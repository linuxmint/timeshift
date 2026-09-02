# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""What the applet runs.

These are security assertions, not style ones. The privileged commands are
authorised by a polkit action that matches on the PROGRAM, so what matters is
that the program named is the fixed-argument wrapper and that nothing the
applet was told by anyone reaches the argv.
"""

import unittest

from timeshift_tray import actions


class ArgvTest(unittest.TestCase):
    def test_create_runs_the_wrapper_and_not_the_cli(self):
        """Pointing an auth_admin_keep action at /usr/bin/timeshift would
        authorise deleting every snapshot just as readily as taking one."""
        self.assertEqual(actions.CREATE_SNAPSHOT_ARGV,
                         ["pkexec", "/usr/libexec/timeshift-tray/create-snapshot"])

    def test_grant_runs_the_wrapper_and_names_nobody(self):
        """The wrapper resolves the user from PKEXEC_UID, so an unprivileged
        caller cannot add somebody else to the group."""
        self.assertEqual(actions.GRANT_ACCESS_ARGV,
                         ["pkexec", "/usr/libexec/timeshift-tray/grant-access"])

    def test_no_argv_is_a_shell_string(self):
        for argv in (actions.CREATE_SNAPSHOT_ARGV, actions.GRANT_ACCESS_ARGV,
                     actions.OPEN_TIMESHIFT_ARGV):
            self.assertIsInstance(argv, list)
            for word in argv:
                self.assertNotIn(" ", word)
                self.assertNotIn(";", word)
                self.assertNotIn("|", word)

    def test_open_uses_the_launcher(self):
        self.assertEqual(actions.OPEN_TIMESHIFT_ARGV, ["timeshift-launcher"])


class SpawnTest(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def record(argv, token, on_exit):
            self.calls.append((argv, token))
            if on_exit is not None:
                on_exit(True, "")

        self.spawner = actions.Spawner(spawn_fn=record)

    def test_argv_reaches_the_spawn_unchanged(self):
        self.spawner.run(actions.CREATE_SNAPSHOT_ARGV)
        self.assertEqual(self.calls[0][0], actions.CREATE_SNAPSHOT_ARGV)

    def test_the_activation_token_is_passed_on(self):
        """Without it the window we launch arrives as a "ready to run" toast
        instead of taking focus."""
        self.spawner.activation_token = "tok-1"
        self.spawner.run(actions.OPEN_TIMESHIFT_ARGV)
        self.assertEqual(self.calls[0][1], "tok-1")

    def test_the_caller_hears_about_the_exit(self):
        seen = []
        self.spawner.run(actions.OPEN_TIMESHIFT_ARGV,
                         lambda ok, message: seen.append(ok))
        self.assertEqual(seen, [True])


if __name__ == "__main__":
    unittest.main()
