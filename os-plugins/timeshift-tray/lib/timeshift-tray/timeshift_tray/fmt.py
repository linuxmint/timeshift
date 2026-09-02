# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Every human-readable string the tray produces.

Pure: no D-Bus, no sockets, no clock of its own -- `now` is always passed in, so
an age string can be tested without waiting for time to pass.
"""

import datetime

# The tag letters the daemon stores, in the order Timeshift lists them.
TAG_NAMES = {
    "ondemand": "On demand",
    "boot": "Boot",
    "hourly": "Hourly",
    "daily": "Daily",
    "weekly": "Weekly",
    "monthly": "Monthly",
    # The control file writes letters; both spellings are accepted.
    "O": "On demand",
    "B": "Boot",
    "H": "Hourly",
    "D": "Daily",
    "W": "Weekly",
    "M": "Monthly",
}

_TAG_ORDER = ("On demand", "Boot", "Hourly", "Daily", "Weekly", "Monthly")


def escape_label(text):
    """Double every underscore.

    The GNOME host runs `label.replace(/_([^_])/, '$1')` to strip mnemonics, so
    a device path like /dev/mapper/vg_root-lv_home loses characters on the way
    to the panel unless they are doubled here.
    """
    return (text or "").replace("_", "__")


def group_digits(text):
    """Thousands separators, reproducing fsutil's group()."""
    neg = text.startswith("-")
    if neg:
        text = text[1:]
    whole, dot, frac = text.partition(".")
    out = []
    for i, ch in enumerate(reversed(whole)):
        if i and i % 3 == 0:
            out.append(",")
        out.append(ch)
    grouped = "".join(reversed(out))
    return ("-" if neg else "") + grouped + dot + frac


def format_size(size, show_units=True, decimals=1, group=True):
    """Decimal units, one decimal, grouped -- fsutil.DefaultSizeOpts().

    The `>` comparisons are deliberate rather than `>=`: FormatSize uses them,
    so exactly 1e9 bytes renders as "1,000.0 MB" and not "1.0 GB". Anything
    that reproduces the daemon's numbers has to reproduce its boundaries too.
    """
    if size is None or size < 0:
        return ""
    unit_k = 1000
    unit_m = unit_k * unit_k
    unit_g = unit_m * unit_k
    unit_t = unit_g * unit_k

    def scaled(div, letter):
        txt = "%.*f" % (decimals, float(size) / float(div))
        if group:
            txt = group_digits(txt)
        return txt + (" " + letter + "B" if show_units else "")

    if size > unit_t:
        return scaled(unit_t, "T")
    if size > unit_g:
        return scaled(unit_g, "G")
    if size > unit_m:
        return scaled(unit_m, "M")
    if size > unit_k:
        return scaled(unit_k, "K")
    txt = str(int(size))
    if group:
        txt = group_digits(txt)
    return txt + (" B" if show_units else "")


def format_count(n):
    """A file count, grouped: 212,880."""
    if n is None or n < 0:
        return ""
    return group_digits(str(int(n)))


def format_age(when, now):
    """How long ago, in the words a person would use.

    Deliberately coarse above an hour: a tray line that says "2 hours ago" and
    is redrawn once a minute never looks stale, where "2 hours 14 minutes ago"
    invites the reader to check whether it is still true.
    """
    if when is None:
        return "never"
    delta = now - when
    seconds = int(delta.total_seconds())
    if seconds < 0:
        # A snapshot dated in the future is a clock problem, not an age.
        return "just now"
    if seconds < 90:
        return "just now"
    minutes = seconds // 60
    if minutes < 60:
        return "%d minute%s ago" % (minutes, "" if minutes == 1 else "s")
    hours = minutes // 60
    if hours < 48:
        return "%d hour%s ago" % (hours, "" if hours == 1 else "s")
    days = hours // 24
    if days < 14:
        return "%d days ago" % days
    weeks = days // 7
    if weeks < 9:
        return "%d weeks ago" % weeks
    months = days // 30
    if months < 24:
        return "%d months ago" % months
    return "%d years ago" % (days // 365)


def format_clock(when):
    """A wall-clock time for something in the near future: 14:30."""
    if when is None:
        return ""
    return when.astimezone().strftime("%H:%M")


def format_stamp(when):
    """A snapshot's own timestamp, as the snapshot list shows it."""
    if when is None:
        return ""
    return when.astimezone().strftime("%Y-%m-%d %H:%M")


def format_stamp_relative(when, now):
    """Today 17:40 / Yesterday 14:32 / 2026-08-25 09:00.

    Days are compared in LOCAL time, since that is the calendar the person
    reading the menu is on.
    """
    if when is None:
        return ""
    local = when.astimezone()
    today = now.astimezone().date()
    days = (today - local.date()).days
    clock = local.strftime("%H:%M")
    if days == 0:
        return "Today %s" % clock
    if days == 1:
        return "Yesterday %s" % clock
    return local.strftime("%Y-%m-%d %H:%M")


def format_duration(seconds):
    """A length of time in the coarse words format_age uses, with no "ago"."""
    if seconds is None or seconds < 0:
        return ""
    seconds = int(seconds)
    minutes = max(1, seconds // 60)
    if minutes < 60:
        return "%d minute%s" % (minutes, "" if minutes == 1 else "s")
    hours = minutes // 60
    if hours < 48:
        return "%d hour%s" % (hours, "" if hours == 1 else "s")
    days = hours // 24
    return "%d days" % days


METER_FULL = "\u25b0"     # ▰ BLACK PARALLELOGRAM
METER_EMPTY = "\u25b1"    # ▱ WHITE PARALLELOGRAM


def format_meter(fraction, width=10):
    """A progress bar in text: ▰▰▰▰▱▱▱▱▱▱ for 0.43.

    The parallelograms are in DejaVu, Cantarell and Noto, which between them
    cover every desktop this runs on, and unlike the block elements they keep a
    uniform advance in proportional fonts so the bar does not wobble as it
    fills. Rounded to the nearest cell, but never full before 1.0: a bar that
    fills at 96% says "done" four percent early.
    """
    if fraction is None:
        return ""
    fraction = min(1.0, max(0.0, float(fraction)))
    filled = int(round(fraction * width))
    if filled == width and fraction < 1.0:
        filled = width - 1
    return METER_FULL * filled + METER_EMPTY * (width - filled)


def format_tags(tags):
    """"Daily, Boot" -- named, deduplicated, in Timeshift's own order."""
    if not tags:
        return ""
    names = []
    for tag in tags:
        name = TAG_NAMES.get(tag, tag)
        if name not in names:
            names.append(name)
    names.sort(key=lambda n: _TAG_ORDER.index(n) if n in _TAG_ORDER else 99)
    return ", ".join(names)


def format_eta(seconds):
    """The daemon uses -1 for "cannot say yet", which must not print as -1s."""
    if seconds is None or seconds < 0:
        return ""
    if seconds < 60:
        return "%d seconds left" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%d minute%s left" % (minutes, "" if minutes == 1 else "s")
    hours = minutes // 60
    return "%d hour%s left" % (hours, "" if hours == 1 else "s")


def format_percent(fraction):
    """0..1 -> "43%". Progress with no total is indeterminate, not 0%."""
    if fraction is None:
        return ""
    return "%d%%" % int(round(fraction * 100))


def parse_rfc3339(text):
    """The daemon's timestamps, with both of Go's surprises handled.

    Go writes up to nine fractional digits, which datetime.fromisoformat
    rejects, and `omitempty` does nothing for a time.Time, so an unset time
    arrives as "0001-01-01T00:00:00Z" rather than being absent. Year 1 means
    never, and callers get None for it.
    """
    if not text or not isinstance(text, str):
        return None
    value = text.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    # Trim the fraction to six digits, wherever it sits relative to the offset.
    dot = value.find(".")
    if dot != -1:
        end = dot + 1
        while end < len(value) and value[end].isdigit():
            end += 1
        frac = value[dot + 1:end][:6]
        value = value[:dot] + ("." + frac if frac else "") + value[end:]
    try:
        parsed = datetime.datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.year <= 1:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed
