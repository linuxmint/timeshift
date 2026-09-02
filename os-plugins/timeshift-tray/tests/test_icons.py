# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Which icon each health gets, under each style."""

import unittest

from timeshift_tray import icons
from timeshift_tray.model import Health


class PolicyTest(unittest.TestCase):
    def test_auto_paints_only_trouble(self):
        """Colour on the panel has to mean something."""
        for health in (Health.OK, Health.BUSY, Health.NOACCESS):
            self.assertTrue(icons.icon_for(health).endswith("-symbolic"), health)
        self.assertEqual(icons.icon_for(Health.WARNING), "timeshift-tray-warning")
        self.assertEqual(icons.icon_for(Health.ERROR), "timeshift-tray-error")

    def test_symbolic_never_paints(self):
        for health in Health:
            name = icons.icon_for(health, icons.STYLE_SYMBOLIC)
            self.assertTrue(name.endswith("-symbolic"), health)

    def test_colour_always_paints(self):
        for health in Health:
            name = icons.icon_for(health, icons.STYLE_COLOUR)
            self.assertFalse(name.endswith("-symbolic"), health)

    def test_every_state_has_a_different_silhouette_name(self):
        names = {icons.icon_for(h, icons.STYLE_SYMBOLIC) for h in Health}
        self.assertEqual(len(names), len(Health))

    def test_all_icons_lists_everything_any_style_can_return(self):
        seen = set()
        for style in icons.STYLES:
            for health in Health:
                seen.add(icons.icon_for(health, style))
        seen.add(icons.ATTENTION_ICON)
        for outcome in ("ok", "warning", "error", "busy", "rubbish"):
            seen.add(icons.notification_icon(outcome))
        self.assertTrue(seen <= set(icons.ALL_ICONS), seen - set(icons.ALL_ICONS))

    def test_attention_is_the_colour_error(self):
        self.assertEqual(icons.ATTENTION_ICON, "timeshift-tray-error")
        self.assertTrue(icons.wants_attention(Health.ERROR))
        self.assertFalse(icons.wants_attention(Health.BUSY))

    def test_style_parsing_accepts_both_spellings(self):
        self.assertEqual(icons.parse_style("color"), icons.STYLE_COLOUR)
        self.assertEqual(icons.parse_style(" Symbolic "), icons.STYLE_SYMBOLIC)
        self.assertEqual(icons.parse_style(None), icons.STYLE_AUTO)
        self.assertEqual(icons.parse_style("neon"), icons.STYLE_AUTO)

    def test_no_dots_in_any_name(self):
        """The GNOME host mangles a dotted name into nothing."""
        for name in icons.ALL_ICONS:
            self.assertNotIn(".", name)


if __name__ == "__main__":
    unittest.main()
