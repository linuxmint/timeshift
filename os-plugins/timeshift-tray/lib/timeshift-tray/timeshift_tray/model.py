# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""What the daemon told us, and what that means.

Two things live here and nothing else: parsers that turn wire objects into
plain values, and TrayState, which is the single place that decides what the
tray currently believes. Presentation reads TrayState; transport writes it.

Note the wire is not one dialect. jobs.* and schedule.status carry Go struct
tags and arrive snake_case; engines.Snapshot has no tags at all, so
snapshots.list arrives with Go FIELD NAMES -- Name, Created, SizeBytes. Reading
one convention for both is how a full repository reports itself empty.
"""

import datetime
import enum

from . import fmt
from .constants import DISCONNECTED_GRACE_SECONDS

# --- job vocabulary, from internal/jobs -----------------------------------------

STATE_QUEUED = "queued"
STATE_RUNNING = "running"
STATE_PAUSED = "paused"
STATE_FINISHED = "finished"
STATE_CANCELLED = "cancelled"
STATE_FAILED = "failed"

ACTIVE_STATES = frozenset((STATE_QUEUED, STATE_RUNNING, STATE_PAUSED))
TERMINAL_STATES = frozenset((STATE_FINISHED, STATE_CANCELLED, STATE_FAILED))

KIND_CREATE = "create"
KIND_DELETE = "delete"
KIND_RESTORE = "restore"
# The kinds that change the repository, and so the ones whose completion means
# the snapshot list we are holding is stale.
MUTATING_KINDS = frozenset((KIND_CREATE, KIND_DELETE, KIND_RESTORE))

OUTCOME_OK = "ok"
OUTCOME_WARNINGS = "warnings"
OUTCOME_FAILED = "failed"


class ConnState(enum.Enum):
    """Why we can or cannot see the daemon.

    These are kept apart because each needs different words in the menu.
    Telling someone the service is not running when in fact they are simply not
    in the group sends them off to start something that is already up, which is
    the one instruction guaranteed to stop them finding the real answer.
    """

    STARTING = "starting"
    NO_DAEMON = "no-daemon"
    NO_ACCESS = "no-access"
    PROTOCOL_MISMATCH = "protocol-mismatch"
    DISCONNECTED = "disconnected"
    READY = "ready"


class Health(enum.Enum):
    OK = "ok"
    BUSY = "busy"
    WARNING = "warning"
    ERROR = "error"
    NOACCESS = "inactive"


def _s(obj, *names, default=""):
    """First present string among several spellings of the same field."""
    for name in names:
        value = obj.get(name)
        if isinstance(value, str):
            return value
    return default


def _b(obj, *names, default=False):
    for name in names:
        value = obj.get(name)
        if isinstance(value, bool):
            return value
    return default


def _i(obj, *names, default=0):
    for name in names:
        value = obj.get(name)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            return int(value)
    return default


class SystemInfo:
    __slots__ = ("version", "protocol_version", "engine", "read_only",
                 "active_job", "live")

    def __init__(self, version="", protocol_version=0, engine="",
                 read_only=False, active_job="", live=False):
        self.version = version
        self.protocol_version = protocol_version
        self.engine = engine
        self.read_only = read_only
        self.active_job = active_job
        self.live = live

    @classmethod
    def from_wire(cls, obj):
        obj = obj or {}
        return cls(
            version=_s(obj, "version"),
            protocol_version=_i(obj, "protocol_version"),
            engine=_s(obj, "engine"),
            read_only=_b(obj, "read_only"),
            active_job=_s(obj, "active_job"),
            live=_b(obj, "live"),
        )


class ScheduleStatus:
    __slots__ = ("enabled", "running", "live", "last_run", "last_error",
                 "last_result", "next_run", "interval_seconds")

    def __init__(self, enabled=False, running=False, live=False, last_run=None,
                 last_error="", last_result="", next_run=None,
                 interval_seconds=0):
        self.enabled = enabled
        self.running = running
        self.live = live
        self.last_run = last_run
        self.last_error = last_error
        self.last_result = last_result
        self.next_run = next_run
        self.interval_seconds = interval_seconds

    @classmethod
    def from_wire(cls, obj):
        obj = obj or {}
        return cls(
            enabled=_b(obj, "enabled"),
            running=_b(obj, "running"),
            live=_b(obj, "live"),
            last_run=fmt.parse_rfc3339(_s(obj, "last_run")),
            last_error=_s(obj, "last_error"),
            last_result=_s(obj, "last_result"),
            next_run=fmt.parse_rfc3339(_s(obj, "next_run")),
            interval_seconds=_i(obj, "interval_seconds"),
        )


class RepoStatus:
    """The location header, as the daemon renders it.

    message and details are carried verbatim rather than re-derived: free space
    exists nowhere on this object as a number, only inside details, and details
    is also the only formulation that says anything sensible about a remote
    repository, where there is no device to measure.
    """

    __slots__ = ("code", "message", "details", "available", "has_snapshots")

    def __init__(self, code=0, message="", details="", available=False,
                 has_snapshots=False):
        self.code = code
        self.message = message
        self.details = details
        self.available = available
        self.has_snapshots = has_snapshots

    @classmethod
    def from_wire(cls, obj):
        obj = obj or {}
        return cls(
            code=_i(obj, "code"),
            message=_s(obj, "message"),
            details=_s(obj, "details"),
            available=_b(obj, "available"),
            has_snapshots=_b(obj, "has_snapshots"),
        )


class Snapshot:
    """One stored snapshot.

    Wire keys are Go FIELD NAMES, because engines.Snapshot carries no json
    tags. The snake_case spellings are accepted too, so that a daemon which
    later grows tags does not silently blank this out.
    """

    __slots__ = ("name", "path", "created", "tags", "description",
                 "size_bytes", "valid", "live")

    def __init__(self, name="", path="", created=None, tags=(), description="",
                 size_bytes=-1, valid=True, live=False):
        self.name = name
        self.path = path
        self.created = created
        self.tags = list(tags)
        self.description = description
        self.size_bytes = size_bytes
        self.valid = valid
        self.live = live

    @classmethod
    def from_wire(cls, obj):
        obj = obj or {}
        tags = obj.get("Tags")
        if not isinstance(tags, list):
            tags = obj.get("tags")
        if not isinstance(tags, list):
            tags = []
        created = fmt.parse_rfc3339(_s(obj, "Created", "created"))
        name = _s(obj, "Name", "name")
        if created is None and name:
            # The directory name IS the timestamp, so a control file whose
            # `created` will not parse still dates the snapshot correctly
            # rather than to the epoch -- which is how the daemon's own reader
            # ends up deleting a good snapshot for being older than everything.
            created = _parse_snapshot_name(name)
        return cls(
            name=name,
            path=_s(obj, "Path", "path"),
            created=created,
            tags=[t for t in tags if isinstance(t, str)],
            description=_s(obj, "Description", "description"),
            size_bytes=_i(obj, "SizeBytes", "size_bytes", default=-1),
            valid=_b(obj, "Valid", "valid", default=True),
            live=_b(obj, "Live", "live"),
        )


def _parse_snapshot_name(name):
    """"2026-08-31_03-00-01" -> a local datetime, or None."""
    import datetime
    try:
        naive = datetime.datetime.strptime(name, "%Y-%m-%d_%H-%M-%S")
    except ValueError:
        return None
    return naive.astimezone()


class Progress:
    __slots__ = ("percent", "count", "total", "eta_seconds", "status_line")

    def __init__(self, percent=0.0, count=0, total=0, eta_seconds=-1,
                 status_line=""):
        self.percent = percent
        self.count = count
        self.total = total
        self.eta_seconds = eta_seconds
        self.status_line = status_line

    @property
    def indeterminate(self):
        """Zero of zero is "no idea yet", not "nothing done"."""
        return self.total <= 0

    @classmethod
    def from_wire(cls, obj):
        obj = obj or {}
        percent = obj.get("percent")
        return cls(
            percent=float(percent) if isinstance(percent, (int, float)) else 0.0,
            count=_i(obj, "count"),
            total=_i(obj, "total"),
            eta_seconds=_i(obj, "eta_seconds", default=-1),
            status_line=_s(obj, "status_line"),
        )


class Job:
    __slots__ = ("id", "kind", "state", "phase", "progress", "outcome",
                 "error", "messages", "finished")

    def __init__(self, id="", kind="", state="", phase="", progress=None,
                 outcome="", error="", messages=(), finished=None):
        self.id = id
        self.kind = kind
        self.state = state
        self.phase = phase
        self.progress = progress or Progress()
        self.outcome = outcome
        self.error = error
        self.messages = list(messages)
        # When it ended, where the daemon said. Kept because a job that
        # finished while we were disconnected is only worth announcing if it
        # finished RECENTLY -- otherwise it is history.
        self.finished = finished

    @property
    def active(self):
        return self.state in ACTIVE_STATES

    @classmethod
    def from_wire(cls, obj):
        obj = obj or {}
        messages = obj.get("messages")
        return cls(
            id=_s(obj, "id"),
            kind=_s(obj, "kind"),
            state=_s(obj, "state"),
            phase=_s(obj, "phase"),
            progress=Progress.from_wire(obj.get("progress")),
            outcome=_s(obj, "outcome"),
            error=_s(obj, "error"),
            messages=[m for m in (messages or []) if isinstance(m, str)],
            finished=fmt.parse_rfc3339(_s(obj, "finished")),
        )


class TrayState:
    """Everything the tray believes, and the one rule that grades it."""

    def __init__(self):
        self.conn = ConnState.STARTING
        self.daemon_protocol = 0        # what a mismatched daemon claimed
        self.system = None              # SystemInfo
        self.schedule = None            # ScheduleStatus
        self.repo = None                # RepoStatus
        self.repo_checking = False
        # The last repo.status could not be completed -- a transport failure,
        # not a verdict about the repository. What is displayed is the previous
        # answer, and it is labelled as such.
        self.repo_stale = False
        self.disconnected_since = None
        self.snapshots = []             # newest first
        self.job = None                 # Job, when one is running
        self.create_pending = False     # a polkit prompt is on screen

    @property
    def live(self):
        if self.system is not None and self.system.live:
            return True
        return bool(self.schedule is not None and self.schedule.live)

    @property
    def latest(self):
        for snap in self.snapshots:
            if snap.valid and not snap.live:
                return snap
        return self.snapshots[0] if self.snapshots else None

    @property
    def scheduler_stalled(self):
        """Enabled, but the loop that would act on it is not running.

        Live media are excluded deliberately: there is nothing here to
        snapshot, so "not running" is the correct state and not a fault.
        """
        sched = self.schedule
        if sched is None or self.live:
            return False
        return bool(sched.enabled and not sched.running)

    def disconnected_for(self, now=None):
        """Seconds since the connection was last good, 0 while it is good."""
        if self.disconnected_since is None:
            return 0.0
        now = now or datetime.datetime.now(datetime.timezone.utc)
        return max(0.0, (now - self.disconnected_since).total_seconds())

    def health(self, now=None):
        if self.conn is ConnState.NO_ACCESS:
            return Health.NOACCESS
        if self.conn in (ConnState.NO_DAEMON, ConnState.PROTOCOL_MISMATCH):
            return Health.ERROR
        if self.job is not None and self.job.active:
            return Health.BUSY
        if self.conn is not ConnState.READY:
            # Starting, or briefly disconnected: not yet a verdict. But only
            # briefly -- a crash-looping daemon would otherwise leave the tray
            # showing the healthy icon indefinitely, which is the one thing it
            # must never do.
            if self.disconnected_for(now) > DISCONNECTED_GRACE_SECONDS:
                return Health.WARNING
            return Health.OK
        if self.repo is not None and not self.repo.available:
            return Health.ERROR
        if self.scheduler_stalled:
            return Health.WARNING
        if self.schedule is not None and self.schedule.last_error:
            return Health.WARNING
        if self.repo is not None and not self.repo.has_snapshots:
            return Health.WARNING
        return Health.OK
