# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The menu as data.

Pure: this module builds a tree of Nodes from a TrayState and nothing else. It
holds no D-Bus types, so the whole menu -- every state, every label -- can be
asserted in a test with no bus and no display.

Ids are allocated per KEY and never reused, which is what makes a rebuild after
a progress tick a property update rather than a new layout. The host tears down
and re-reads the whole menu on LayoutUpdated; if the ids moved, an open menu
would visibly rebuild itself once a second.
"""

from . import fmt
from .constants import GROUP, PROTOCOL_VERSION
from .model import ConnState, KIND_CREATE, KIND_DELETE, KIND_RESTORE

# Action keys. The tree names an action; app.py owns what it does, so this
# module can be imported without gi.
ACTION_CREATE = "create"
ACTION_OPEN = "open"
ACTION_GRANT = "grant"
ACTION_REVOKE = "revoke"
ACTION_QUIT = "quit"

SEPARATOR = "separator"
STANDARD = "standard"

# Properties the host understands, and the variant type each must carry. A
# property sent with the wrong type is dropped silently by the host, so this
# table is the contract rather than documentation.
PROP_TYPES = {
    "label": "s",
    "enabled": "b",
    "visible": "b",
    "type": "s",
    "children-display": "s",
    "icon-name": "s",
    "icon-data": "ay",
}

# What the spec says an absent property means. Sending these wastes bytes and,
# worse, makes a diff look like a change.
PROP_DEFAULTS = {
    "label": "",
    "enabled": True,
    "visible": True,
    "type": STANDARD,
}


class IdAllocator:
    """Stable int ids for string keys, for the life of the process."""

    def __init__(self, first=1):
        self._next = first
        self._ids = {}

    def id_for(self, key):
        ident = self._ids.get(key)
        if ident is None:
            ident = self._next
            self._next += 1
            self._ids[key] = ident
        return ident


class Node:
    __slots__ = ("id", "key", "label", "enabled", "visible", "kind",
                 "icon_name", "dot", "action", "children")

    def __init__(self, id, key, label="", enabled=True, visible=True,
                 kind=STANDARD, icon_name="", dot="", action=None,
                 children=None):
        self.id = id
        self.key = key
        self.label = label
        self.enabled = enabled
        self.visible = visible
        self.kind = kind
        self.icon_name = icon_name
        # A DOTS key. Emitted as icon-data, which the transport layer turns
        # into PNG bytes; this module stays free of files and of gi. The host
        # draws icon-data only when icon-name is absent, so a row has one or
        # the other.
        self.dot = dot
        self.action = action
        self.children = children if children is not None else []

    def props(self):
        """The dbusmenu property dict for this node, defaults omitted."""
        out = {}
        if self.kind == SEPARATOR:
            out["type"] = SEPARATOR
        else:
            out["label"] = fmt.escape_label(self.label)
            if self.icon_name:
                out["icon-name"] = self.icon_name
            elif self.dot:
                out["icon-data"] = self.dot
        if not self.enabled:
            out["enabled"] = False
        if not self.visible:
            out["visible"] = False
        if self.children:
            out["children-display"] = "submenu"
        return {k: v for k, v in out.items() if PROP_DEFAULTS.get(k, object()) != v}

    def walk(self):
        yield self
        for child in self.children:
            for node in child.walk():
                yield node

    def __repr__(self):
        return "Node(%d, %r)" % (self.id, self.key)


def index_of(root):
    return {node.id: node for node in root.walk()}


def same_structure(a, b):
    """Same ids in the same order and the same nesting.

    When this holds, a change is ItemsPropertiesUpdated; when it does not, the
    layout revision has to move.
    """
    if a.id != b.id or len(a.children) != len(b.children):
        return False
    for left, right in zip(a.children, b.children):
        if not same_structure(left, right):
            return False
    return True


def diff_props(old, new):
    """(updated, removed) in the shapes ItemsPropertiesUpdated wants."""
    old_index = {n.id: n.props() for n in old.walk()}
    updated = []
    removed = []
    for node in new.walk():
        before = old_index.get(node.id, {})
        after = node.props()
        changed = {k: v for k, v in after.items() if before.get(k) != v}
        gone = [k for k in before if k not in after]
        if changed:
            updated.append((node.id, changed))
        if gone:
            removed.append((node.id, gone))
    return updated, removed


# --- building -----------------------------------------------------------------

# Status rows carry a coloured disc (a DOTS key, shipped as PNG and sent as
# icon-data) so the colour says what the row says: green is fine, yellow
# wants a look, red is a fault, blue is information, grey is nothing to
# report, brand is work in progress. The keys are the files in
# share/timeshift-tray/dots; check-deb.sh verifies every one named here.
DOT_OK = "green"
DOT_WARN = "yellow"
DOT_FAULT = "red"
DOT_INFO = "blue"
DOT_NEUTRAL = "grey"
DOT_BUSY = "brand"
ALL_DOTS = (DOT_OK, DOT_WARN, DOT_FAULT, DOT_INFO, DOT_NEUTRAL, DOT_BUSY)

# Action rows carry themed symbolic icons, all from the common Adwaita/Breeze
# set except the tray's own, so every host resolves them; a name the theme
# lacks simply draws no icon, it does not break the row.
ICON_CREATE = "document-save-symbolic"
ICON_OPEN = "timeshift"
ICON_RECENT = "document-open-recent-symbolic"
ICON_GRANT = "changes-allow-symbolic"
ICON_REVOKE = "changes-prevent-symbolic"
ICON_QUIT = "application-exit-symbolic"

# The one separator the labels use: the middle dot joins facts of equal weight
# on one row, as in "Shadow · Morph · Focus".
DOT = " · "


def _status_row(ids, key, text, dot=""):
    return Node(ids.id_for(key), key, label=text, enabled=False, dot=dot)


def _separator(ids, key):
    return Node(ids.id_for(key), key, kind=SEPARATOR)


def _job_verb(kind):
    return {
        KIND_CREATE: "Creating snapshot",
        KIND_DELETE: "Deleting snapshots",
        KIND_RESTORE: "Restoring",
    }.get(kind, "Working")


def job_lines(job):
    """Two rows: what is happening with a meter, and how far along it is."""
    head = _job_verb(job.kind)
    percent = fmt.format_percent(job.progress.percent)
    if not job.progress.indeterminate and percent:
        head = "%s  %s %s" % (head, fmt.format_meter(job.progress.percent),
                              percent)
    else:
        head = head + "…"

    detail = ""
    if job.progress.total > 0:
        # rsync's item total is an estimate and the real count routinely
        # exceeds it -- the recorded corpus has 286,907 of 286,021. Clamp
        # rather than print arithmetic nonsense.
        counted = min(job.progress.count, job.progress.total)
        detail = "%s of %s files" % (fmt.format_count(counted),
                                     fmt.format_count(job.progress.total))
        eta = fmt.format_eta(job.progress.eta_seconds)
        if eta:
            detail = detail + DOT + eta
    elif job.phase:
        detail = job.phase
    elif job.progress.status_line:
        detail = job.progress.status_line
    return head, detail


def _create_label(state):
    """What the create item says, and whether it can be clicked.

    The daemon would attach a second click to the running job rather than take
    two snapshots, so this is not a correctness guard -- it is the difference
    between a menu that reports what is happening and one that invites a
    pointless password prompt.
    """
    if state.live:
        return "Snapshots are disabled in a live session", False
    if state.job is not None and state.job.active:
        # Named after the job, not after this item: what the person needs to
        # know is why they cannot click, and the progress is on its own row
        # just above.
        return {
            KIND_CREATE: "A snapshot is already being taken",
            KIND_DELETE: "Snapshots are being deleted",
            KIND_RESTORE: "A restore is running",
        }.get(state.job.kind, "Timeshift is busy"), False
    if state.create_pending:
        return "Waiting for authorisation…", False
    if state.conn is not ConnState.READY:
        return "Create snapshot now", False
    return "Create snapshot now", True


def build_menu(state, now, ids):
    """The whole menu for a state. Returns the root Node (id 0)."""
    root = Node(0, "root")
    rows = root.children

    if state.conn is ConnState.NO_ACCESS:
        rows.append(_status_row(ids, "status.headline",
                                "Timeshift status is not available to you",
                                DOT_WARN))
        rows.append(_status_row(ids, "status.detail",
                                "This account is not in the \"%s\" group"
                                % GROUP))
    elif state.conn is ConnState.NO_DAEMON:
        rows.append(_status_row(ids, "status.headline",
                                "The Timeshift service is not running",
                                DOT_FAULT))
        rows.append(_status_row(ids, "status.detail",
                                "Start it with: sudo systemctl start timeshiftd"))
    elif state.conn is ConnState.PROTOCOL_MISMATCH:
        rows.append(_status_row(ids, "status.headline",
                                "The Timeshift service speaks a different protocol",
                                DOT_WARN))
        rows.append(_status_row(
            ids, "status.detail",
            "Service %d, applet %d%srestart it after upgrading"
            % (state.daemon_protocol, PROTOCOL_VERSION, DOT)))
    elif state.conn in (ConnState.STARTING, ConnState.DISCONNECTED):
        rows.append(_status_row(ids, "status.headline",
                                "Connecting to the Timeshift service…",
                                DOT_NEUTRAL))
    else:
        for key, (text, dot) in zip(
                ("status.snapshot", "status.schedule", "status.location"),
                status_rows(state, now)):
            rows.append(_status_row(ids, key, text, dot))

    # The job rows exist in every READY menu and are merely hidden when idle,
    # so a snapshot starting is a property change and not a new layout.
    if state.conn is ConnState.READY:
        head, detail = job_lines(state.job) if state.job is not None else ("", "")
        running = state.job is not None and state.job.active
        rows.append(Node(ids.id_for("job.head"), "job.head", label=head,
                         enabled=False, visible=running,
                         dot=DOT_BUSY if running else ""))
        rows.append(Node(ids.id_for("job.detail"), "job.detail", label=detail,
                         enabled=False, visible=running and bool(detail)))

    rows.append(_separator(ids, "sep.1"))

    if state.conn is ConnState.NO_ACCESS:
        rows.append(Node(ids.id_for("action.grant"), "action.grant",
                         label="Enable status access…",
                         icon_name=ICON_GRANT, action=ACTION_GRANT))
    else:
        label, enabled = _create_label(state)
        rows.append(Node(ids.id_for("action.create"), "action.create",
                         label=label, enabled=enabled, icon_name=ICON_CREATE,
                         action=ACTION_CREATE))
        rows.append(Node(ids.id_for("action.revoke"), "action.revoke",
                         label="Remove status access…",
                         icon_name=ICON_REVOKE, action=ACTION_REVOKE,
                         visible=state.conn is ConnState.READY))

    rows.append(Node(ids.id_for("action.open"), "action.open",
                     label="Open Timeshift…", icon_name=ICON_OPEN,
                     action=ACTION_OPEN))

    recent = _recent_submenu(state, ids, now)
    if recent is not None:
        rows.append(recent)

    rows.append(_separator(ids, "sep.2"))
    rows.append(Node(ids.id_for("action.quit"), "action.quit", label="Quit",
                     icon_name=ICON_QUIT, action=ACTION_QUIT))
    return root


def status_rows(state, now):
    """The three status rows as (text, dot): verdict, schedule, location."""
    return (_snapshot_line(state, now),
            _schedule_line(state, now),
            _location_line(state))


def summary_lines(state, now):
    """The three status texts, also the tooltip on hosts that show one."""
    return tuple(text for text, _dot in status_rows(state, now))


def _recent_submenu(state, ids, now):
    if not state.snapshots:
        return None
    kids = []
    for snap in state.snapshots[:5]:
        key = "snap.%s" % snap.name
        label = fmt.format_stamp_relative(snap.created, now) or snap.name
        tags = fmt.format_tags(snap.tags)
        if tags:
            label = label + DOT + tags
        if not snap.valid:
            label = label + DOT + "incomplete"
        elif snap.live:
            label = label + DOT + "pre-restore"
        kids.append(Node(ids.id_for(key), key, label=label, enabled=False))
    return Node(ids.id_for("recent"), "recent", label="Recent snapshots",
                icon_name=ICON_RECENT, children=kids)


def _snapshot_line(state, now):
    """The headline: the verdict, then the fact it rests on.

    It answers "am I protected?", which is why an incomplete or pre-restore
    snapshot, or a location that cannot be reached, has to change the VERDICT
    and not merely add a suffix: "Protected" over a snapshot nothing could be
    restored from is reassuring in exactly the state where reassurance is
    wrong.
    """
    repo = state.repo
    if repo is not None and not repo.available and not state.repo_stale:
        return ("Not protected" + DOT + "snapshot location unavailable",
                DOT_FAULT)
    snap = state.latest
    if snap is None:
        return "Not protected" + DOT + "no snapshots yet", DOT_FAULT
    age = fmt.format_age(snap.created, now)
    if not snap.valid:
        return ("Not protected" + DOT + "last snapshot is incomplete",
                DOT_FAULT)
    if snap.live:
        return ("Restored" + DOT + "previous system kept %s" % age,
                DOT_INFO)
    text = "Protected" + DOT + "last snapshot %s" % age
    tags = fmt.format_tags(snap.tags)
    if tags:
        text = text + DOT + tags
    return text, DOT_OK


def _schedule_line(state, now):
    sched = state.schedule
    if sched is None:
        return "Schedule unknown", DOT_NEUTRAL
    if state.live:
        return "Not scheduled in a live session", DOT_NEUTRAL
    if not sched.enabled:
        return "Scheduled snapshots off", DOT_NEUTRAL
    if not sched.running:
        return "Scheduler not running", DOT_WARN
    if sched.last_error:
        return "Last check failed" + DOT + sched.last_error, DOT_WARN
    if sched.next_run is not None and sched.next_run < now:
        late = fmt.format_duration((now - sched.next_run).total_seconds())
        return "Check overdue by %s" % late, DOT_WARN
    when = fmt.format_clock(sched.next_run)
    if when:
        return "Next check %s" % when, DOT_INFO
    return "Scheduled snapshots on", DOT_INFO


def _location_line(state):
    """The daemon's own words.

    message and details are what `timeshift --list` prints, and reproducing
    them rather than recomputing means there is one renderer for a location --
    which matters most for a remote repository, where there is no device to
    measure and no free-space number to be had. The one liberty taken is to
    drop a bare "OK" when there are details to show instead: the row's icon
    already says it, and "26 snapshots, 29.9 TB free" is the fact.
    """
    repo = state.repo
    if repo is None:
        return (("Checking location…" if state.repo_checking
                 else "Location unknown"), DOT_NEUTRAL)
    if repo.available and repo.details and repo.message.strip().upper() == "OK":
        text = repo.details
    elif repo.details:
        text = repo.message + DOT + repo.details
    else:
        text = repo.message
    if state.repo_stale:
        # The last check could not be completed. Showing the previous answer is
        # right; showing it as current is not.
        return "%s (last known)" % text, DOT_WARN
    return text, DOT_OK if repo.available else DOT_FAULT
