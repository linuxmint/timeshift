# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Formatting, including the two Go-shaped surprises in its timestamps."""

import datetime
import unittest

from timeshift_tray import fmt

UTC = datetime.timezone.utc


class SizeTest(unittest.TestCase):
    def test_matches_fsutil_boundaries(self):
        """FormatSize compares with > and not >=, and this must too.

        Exactly 1e9 bytes therefore renders in megabytes. Reproducing the
        daemon's numbers means reproducing where it changes unit.
        """
        self.assertEqual(fmt.format_size(1000000000), "1,000.0 MB")
        self.assertEqual(fmt.format_size(1000000001), "1.0 GB")

    def test_grouping_and_units(self):
        self.assertEqual(fmt.format_size(210400000000), "210.4 GB")
        self.assertEqual(fmt.format_size(999), "999 B")

    def test_unknown_size(self):
        """-1 is the daemon's "not computed", not a negative size."""
        self.assertEqual(fmt.format_size(-1), "")


class AgeTest(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 9, 1, 12, 0, tzinfo=UTC)

    def age(self, **delta):
        return fmt.format_age(self.now - datetime.timedelta(**delta), self.now)

    def test_scale(self):
        self.assertEqual(self.age(seconds=5), "just now")
        self.assertEqual(self.age(minutes=1, seconds=45), "1 minute ago")
        self.assertEqual(self.age(minutes=30), "30 minutes ago")
        self.assertEqual(self.age(hours=2), "2 hours ago")
        self.assertEqual(self.age(days=3), "3 days ago")
        self.assertEqual(self.age(days=30), "4 weeks ago")

    def test_never(self):
        self.assertEqual(fmt.format_age(None, self.now), "never")

    def test_a_future_timestamp_is_a_clock_problem_not_a_negative_age(self):
        future = self.now + datetime.timedelta(hours=3)
        self.assertEqual(fmt.format_age(future, self.now), "just now")


class TimestampTest(unittest.TestCase):
    def test_go_zero_time_means_never(self):
        """omitempty does nothing for a time.Time, so unset arrives as year 1."""
        self.assertIsNone(fmt.parse_rfc3339("0001-01-01T00:00:00Z"))

    def test_nine_fractional_digits(self):
        """Go emits up to nine; fromisoformat accepts three or six."""
        parsed = fmt.parse_rfc3339("2026-08-31T03:00:01.123456789Z")
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.year, 2026)
        self.assertEqual(parsed.microsecond, 123456)

    def test_offset_and_no_fraction(self):
        self.assertIsNotNone(fmt.parse_rfc3339("2026-08-31T03:00:01+02:00"))
        self.assertIsNotNone(fmt.parse_rfc3339("2026-08-31T03:00:01Z"))

    def test_rubbish(self):
        for text in ("", None, "yesterday", 7):
            self.assertIsNone(fmt.parse_rfc3339(text))


class LabelTest(unittest.TestCase):
    def test_underscores_are_doubled(self):
        """The panel strips a single underscore as a mnemonic marker."""
        self.assertEqual(fmt.escape_label("/dev/mapper/vg_root-lv_home"),
                         "/dev/mapper/vg__root-lv__home")

    def test_tags_are_named_and_ordered(self):
        self.assertEqual(fmt.format_tags(["daily", "boot"]), "Boot, Daily")
        self.assertEqual(fmt.format_tags(["D", "O"]), "On demand, Daily")
        self.assertEqual(fmt.format_tags([]), "")

    def test_eta_minus_one_is_not_a_time(self):
        self.assertEqual(fmt.format_eta(-1), "")
        self.assertEqual(fmt.format_eta(90), "1 minute left")

    def test_percent(self):
        self.assertEqual(fmt.format_percent(0.435), "44%")
        self.assertEqual(fmt.format_percent(None), "")


class MeterTest(unittest.TestCase):
    def test_rounds_to_cells(self):
        self.assertEqual(fmt.format_meter(0), "▱▱▱▱▱▱▱▱▱▱")
        self.assertEqual(fmt.format_meter(0.43), "▰▰▰▰▱▱▱▱▱▱")
        self.assertEqual(fmt.format_meter(0.5), "▰▰▰▰▰▱▱▱▱▱")
        self.assertEqual(fmt.format_meter(1), "▰▰▰▰▰▰▰▰▰▰")

    def test_never_full_before_done(self):
        """A bar that fills at 96% says finished four percent early."""
        self.assertEqual(fmt.format_meter(0.96), "▰▰▰▰▰▰▰▰▰▱")
        self.assertEqual(fmt.format_meter(0.999), "▰▰▰▰▰▰▰▰▰▱")

    def test_clamps_and_tolerates_none(self):
        self.assertEqual(fmt.format_meter(1.7), "▰▰▰▰▰▰▰▰▰▰")
        self.assertEqual(fmt.format_meter(-3), "▱▱▱▱▱▱▱▱▱▱")
        self.assertEqual(fmt.format_meter(None), "")


class RelativeStampTest(unittest.TestCase):
    def setUp(self):
        # Local time matters here, so build `now` in the local zone.
        self.now = datetime.datetime(2026, 9, 1, 12, 0).astimezone()

    def test_today_yesterday_and_older(self):
        today = self.now.replace(hour=9, minute=5)
        self.assertEqual(fmt.format_stamp_relative(today, self.now),
                         "Today 09:05")
        yesterday = today - datetime.timedelta(days=1)
        self.assertEqual(fmt.format_stamp_relative(yesterday, self.now),
                         "Yesterday 09:05")
        older = today - datetime.timedelta(days=9)
        self.assertEqual(fmt.format_stamp_relative(older, self.now),
                         older.strftime("%Y-%m-%d %H:%M"))

    def test_none(self):
        self.assertEqual(fmt.format_stamp_relative(None, self.now), "")


class DurationTest(unittest.TestCase):
    def test_words(self):
        self.assertEqual(fmt.format_duration(30), "1 minute")
        self.assertEqual(fmt.format_duration(25 * 60), "25 minutes")
        self.assertEqual(fmt.format_duration(3 * 3600), "3 hours")
        self.assertEqual(fmt.format_duration(3 * 86400), "3 days")
        self.assertEqual(fmt.format_duration(-1), "")


if __name__ == "__main__":
    unittest.main()
