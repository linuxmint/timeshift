# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Health to icon name.

Two sets are installed under /usr/share/icons/hicolor, both generated from the
same geometry by tools/make-icons.py -- Timeshift's own shield, with the state
cut out of it:

    timeshift-tray-<state>-symbolic   one colour; the panel recolours it
    timeshift-tray-<state>            the brand colours, drawn as-is

Timeshift's own timeshift-shield-*.svg cannot be used directly: they live in
/usr/share/timeshift/images, which has no index.theme and no size/context
layout, so it is not an icon theme and neither IconName nor IconThemePath can
resolve a name out of it.

The default policy is that colour on the panel means something: a healthy or
busy tray is monochrome and sits with the desktop's own indicators, and the
amber or red brand shield appears only when the person's eyes are needed. A
symbolic icon carries its state in the silhouette as well, so the two sets
agree for someone who cannot see the colour.

No dots in these names. The GNOME host strips what it takes to be a file
extension by joining the remaining pieces with an empty string, which mangles
any other dotted name into something that resolves to nothing.
"""

from .model import Health

STYLE_AUTO = "auto"          # colour for warning and error, symbolic otherwise
STYLE_SYMBOLIC = "symbolic"  # never colour
STYLE_COLOUR = "colour"      # always colour
STYLES = (STYLE_AUTO, STYLE_SYMBOLIC, STYLE_COLOUR)

_STATE = {
    Health.OK: "ok",
    Health.BUSY: "busy",
    Health.WARNING: "warning",
    Health.ERROR: "error",
    Health.NOACCESS: "inactive",
}

_COLOUR_IN_AUTO = frozenset((Health.WARNING, Health.ERROR))

# The running state is drawn with its ring filled in eighths, so the panel
# shows how far a snapshot has got without the menu being opened. Eight is
# what 16 pixels can show; more steps would be more NewIcon signals for no
# visible difference.
PROGRESS_STEPS = 8


def symbolic_name(state):
    return "timeshift-tray-%s-symbolic" % state


def colour_name(state):
    return "timeshift-tray-%s" % state


# What NeedsAttention shows. Always the colour one: attention is the one state
# where being seen matters more than fitting in.
ATTENTION_ICON = colour_name("error")

# Every name this module can return, for check-deb.sh to verify against the
# files the package actually installs.
_ALL_STATES = tuple(_STATE.values()) + tuple(
    "busy-%d" % n for n in range(PROGRESS_STEPS))
ALL_ICONS = tuple(sorted(
    {symbolic_name(s) for s in _ALL_STATES}
    | {colour_name(s) for s in _ALL_STATES}))


def progress_step(fraction):
    """0..1 -> 0..PROGRESS_STEPS-1, or None when there is no fraction.

    Never the full ring before the job has finished: the last step means "one
    eighth to go", and a job at 100% is about to stop being busy at all.
    """
    if fraction is None:
        return None
    fraction = min(1.0, max(0.0, float(fraction)))
    return min(PROGRESS_STEPS - 1, int(fraction * PROGRESS_STEPS))


def parse_style(text, default=STYLE_AUTO):
    """An environment value to a style, tolerating the other spelling."""
    value = (text or "").strip().lower()
    if value == "color":
        value = STYLE_COLOUR
    return value if value in STYLES else default


def icon_for(health, style=STYLE_AUTO, progress=None):
    """The panel icon. `progress` is a 0..1 fraction, only read for BUSY."""
    state = _STATE.get(health, "ok")
    if health is Health.BUSY:
        step = progress_step(progress)
        if step is not None:
            state = "busy-%d" % step
    if style == STYLE_COLOUR:
        return colour_name(state)
    if style == STYLE_AUTO and health in _COLOUR_IN_AUTO:
        return colour_name(state)
    return symbolic_name(state)


def notification_icon(outcome):
    """The toast icon for a job or condition outcome: ok, warning or error.

    Always colour: a notification is not part of the panel and the brand
    shield is what the Timeshift window itself shows for the same states.
    """
    state = outcome if outcome in ("ok", "warning", "error", "busy") else "ok"
    return colour_name(state)


def wants_attention(health):
    """Whether the item should ask the panel to highlight it.

    Only a real fault does. A running backup is not a problem, and a tray that
    demands attention for ordinary work teaches people to ignore it.
    """
    return health is Health.ERROR
