# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Every decision this applet makes.

Separated from app.py, which is now only wiring, because this is where the
orderings live -- which job an event belongs to, whether a completion is news
or history, when the repository is worth re-reading -- and none of that was
testable while it was tangled with a D-Bus connection and a GLib main loop.

Collaborators arrive as constructor arguments and are used through small
duck-typed interfaces (`client`, `menu`, `item`, `notifier`, `spawner`,
`timers`, `clock`). A test substitutes recorders for all seven and drives any
ordering it likes with no bus, no display and no waiting.
"""

import datetime

from . import actions, fmt, icons, menutree, notify
from .constants import (
    ABOUT_TO_SHOW_FLOOR_SECONDS,
    CREATE_LATCH_SECONDS,
    EVENT_CONFIG_CHANGED,
    EVENT_FINISHED,
    EVENT_PHASE,
    EVENT_PROGRESS,
    EVENT_STARTED,
    EVENT_SNAPSHOTS_CHANGED,
    GROUP,
    METHOD_JOBS_GET,
    METHOD_JOBS_LIST,
    METHOD_REPO_STATUS,
    METHOD_SCHEDULE_STATUS,
    METHOD_SNAPSHOTS_LIST,
    METHOD_SYSTEM_INFO,
    RECONCILE_GRACE_SECONDS,
    RECONCILE_SECONDS,
    REPO_POLL_SECONDS,
    SCHEDULE_POLL_SECONDS,
    SYSTEM_INFO_POLL_SECONDS,
    TICK_SECONDS,
)
from .model import (
    ConnState,
    Job,
    MUTATING_KINDS,
    OUTCOME_FAILED,
    OUTCOME_WARNINGS,
    Progress,
    RepoStatus,
    ScheduleStatus,
    Snapshot,
    SystemInfo,
    TERMINAL_STATES,
    TrayState,
)

ITEM_TITLE = "Timeshift"

# How long after a reconnect a job that ended while we were away still counts
# as news. Beyond this it is history and announcing it would be a lie about
# when it happened.
LATE_NEWS_SECONDS = 15 * 60

# Menu redraws are coalesced this long. Progress events arrive far faster than
# anyone can read.
REBUILD_COALESCE_MS = 500


def _utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


class Controller:
    def __init__(self, client, menu, item, notifier, spawner, timers,
                 clock=_utcnow, log=None, on_quit=None,
                 icon_style=icons.STYLE_AUTO):
        self.client = client
        self.menu = menu
        self.item = item
        self.notifier = notifier
        self.spawner = spawner
        self.timers = timers
        self.clock = clock
        self.icon_style = icon_style
        self.log = log or (lambda *_a, **_k: None)
        self.on_quit = on_quit

        self.state = TrayState()
        self._ids = menutree.IdAllocator()

        # Jobs by id. Not one slot: an estimate does not take the repository
        # write lock, so it can run alongside a create, and a single slot would
        # flip-flop between them.
        self._jobs = {}
        # When each job was first seen, so reconciliation can tell "the daemon
        # has forgotten this" from "this started after the listing was taken".
        self._first_seen = {}
        self._kind_asked = set()
        self._announced = set()

        self._repo_last_fetch = None
        self._refresh_pending = False
        self._repo_available_before = None
        self._scheduler_warned = False
        self._create_latch = None
        # Outcomes waiting on a jobs.get that has not answered yet, so a job
        # that finished before we learned its kind is still announced.
        self._pending_finish = {}
        self._rebuild_handle = None
        self._timers = []
        self._no_host_warned = False

    # -- lifecycle -------------------------------------------------------------

    def start(self):
        self.rebuild_menu()
        self.client.start()
        self._timers = [
            self.timers.every(SCHEDULE_POLL_SECONDS, self._poll_schedule),
            self.timers.every(REPO_POLL_SECONDS, self._poll_repo),
            self.timers.every(RECONCILE_SECONDS, self._reconcile_jobs),
            self.timers.every(SYSTEM_INFO_POLL_SECONDS, self._poll_system_info),
            # Ages are rendered from data already held, so the menu stays
            # truthful between fetches without a single call to the daemon.
            self.timers.every(TICK_SECONDS, self.rebuild_menu),
        ]

    def stop(self):
        for handle in self._timers:
            self.timers.cancel(handle)
        self._timers = []
        self._cancel_create_latch()
        if self._rebuild_handle is not None:
            self.timers.cancel(self._rebuild_handle)
            self._rebuild_handle = None
        self.client.stop()

    def quit(self):
        if self.on_quit is not None:
            self.on_quit()

    # -- connection ------------------------------------------------------------

    def on_conn_state(self, state):
        previous = self.state.conn
        self.state.conn = state
        self.state.daemon_protocol = getattr(self.client, "daemon_protocol", 0)

        if state is ConnState.READY:
            self.state.system = SystemInfo.from_wire(
                getattr(self.client, "system", None))
            self.state.disconnected_since = None
            self._fetch_all()
        else:
            if previous is ConnState.READY or self.state.disconnected_since is None:
                self.state.disconnected_since = self.clock()
            # A job we were watching is now of UNKNOWN state, not finished.
            # Forgetting it is right; announcing an outcome we did not see
            # would not be.
            self._jobs.clear()
            self._first_seen.clear()
            self.state.job = None
            if state is not ConnState.DISCONNECTED:
                self.state.repo = None
                self.state.schedule = None
                self.state.repo_stale = False
        self.rebuild_menu()

    def _fetch_all(self):
        self.client.call(METHOD_JOBS_LIST, None, self._on_jobs_list)
        self._poll_schedule()
        self._fetch_repo(force=True)

    # -- polling ---------------------------------------------------------------

    def _ready(self):
        return self.state.conn is ConnState.READY

    def _poll_schedule(self):
        if not self._ready():
            return
        self.client.call(METHOD_SCHEDULE_STATUS, None, self._on_schedule)

    def _poll_system_info(self):
        if not self._ready():
            return

        def answered(result, error):
            if error is None:
                self.state.system = SystemInfo.from_wire(result)

        self.client.call(METHOD_SYSTEM_INFO, None, answered)

    def _poll_repo(self):
        self._fetch_repo(force=True)

    def _reconcile_jobs(self):
        """Ask the daemon what is actually running.

        The event stream is not a guarantee: a subscriber that falls behind is
        DROPPED rather than waited for, which is correct for the daemon and
        means a missed job.finished would otherwise leave this applet showing a
        backup that ended hours ago, with the create item disabled and the
        repository never re-read. This is the repair.
        """
        if not self._ready():
            return
        self.client.call(METHOD_JOBS_LIST, None, self._on_jobs_list)

    def _fetch_repo(self, force=False):
        """snapshots.list and repo.status, which both open the repository.

        Deferred rather than dropped while a job runs: for an SSH location each
        is a network round trip, and during a backup the far end is busy doing
        the backup. Dropping them was the bug -- a snapshots.changed arriving
        mid-job was simply lost.
        """
        if not self._ready():
            return
        if self._busy():
            self._refresh_pending = True
            return
        now = self.clock()
        if not force and self._repo_last_fetch is not None:
            age = (now - self._repo_last_fetch).total_seconds()
            if age < ABOUT_TO_SHOW_FLOOR_SECONDS:
                return
        self._repo_last_fetch = now
        self._refresh_pending = False
        self.client.call(METHOD_SNAPSHOTS_LIST, None, self._on_snapshots)
        self.state.repo_checking = True
        self.client.call_isolated(METHOD_REPO_STATUS, None, self._on_repo)

    def _drain_pending_refresh(self):
        if self._refresh_pending and not self._busy():
            self._fetch_repo(force=True)

    # -- replies ---------------------------------------------------------------

    def _on_jobs_list(self, result, error):
        if error is not None:
            self.log("jobs.list: %s", error)
            return
        live = {}
        for entry in result or []:
            job = Job.from_wire(entry)
            if not job.id:
                continue
            if job.state in TERMINAL_STATES:
                self._announce_late(job)
            else:
                live[job.id] = job
        # MERGE, do not replace. A job.started can arrive before this reply,
        # which was snapshotted by the daemon before that job existed; replacing
        # would erase a job we are already following and leave it running as an
        # unidentified "Working…" for the rest of its life.
        for job_id, job in live.items():
            known = self._jobs.get(job_id)
            if known is None:
                self._jobs[job_id] = job
                self._first_seen.setdefault(job_id, self.clock())
            else:
                known.kind = known.kind or job.kind
                known.state = job.state
                if not known.phase:
                    known.phase = job.phase
        # Anything we think is running that the daemon does not know about has
        # ended without us hearing; drop it rather than stay busy forever.
        #
        # But only once it is old enough to have appeared in this listing. A
        # job.started can arrive while a jobs.list is in flight, and sweeping
        # on the reply would erase the very job the merge above exists to
        # protect -- the two rules pull in opposite directions and this is the
        # line between them.
        now = self.clock()
        for job_id in [j for j in self._jobs if j not in live]:
            first_seen = self._first_seen.get(job_id)
            if first_seen is not None and \
                    (now - first_seen).total_seconds() < RECONCILE_GRACE_SECONDS:
                continue
            self.log("job %s vanished; reconciling", job_id)
            self._forget_job(job_id)
        self._refresh_displayed_job()
        self.rebuild_menu()

    def _announce_late(self, job):
        """A job that ended while we were not looking.

        Anything already terminal when we attach is history -- announcing it
        would say "snapshot created" at login about last night's snapshot. A
        FAILURE within the last few minutes is different: it is the thing the
        applet exists to tell someone, and the disconnect that hid it is
        usually the same event that broke the job.
        """
        if job.id in self._announced:
            return
        self._announced.add(job.id)
        # Failures only. A completion or a warning that we missed is not worth
        # resurrecting; a failure is the whole reason to have a tray icon, and
        # the disconnect that hid it is usually what broke the job.
        if job.outcome != OUTCOME_FAILED and not job.error:
            return
        if job.finished is None:
            return
        age = (self.clock() - job.finished).total_seconds()
        if age < 0 or age > LATE_NEWS_SECONDS:
            return
        self._notify_finished(job.kind, job.outcome, job.error, job.messages,
                              job.progress.count)

    def _on_schedule(self, result, error):
        if error is not None:
            self.log("schedule.status: %s", error)
            return
        self.state.schedule = ScheduleStatus.from_wire(result)
        self._maybe_warn_scheduler()
        self.rebuild_menu()

    def _on_snapshots(self, result, error):
        if error is not None:
            self.log("snapshots.list: %s", error)
            return
        snapshots = [Snapshot.from_wire(obj) for obj in (result or [])]
        # (created is not None, created) never compares None with a datetime:
        # the boolean discriminates first and equal tuples short-circuit.
        snapshots.sort(key=lambda s: (s.created is not None, s.created),
                       reverse=True)
        self.state.snapshots = snapshots
        self.rebuild_menu()

    def _on_repo(self, result, error):
        self.state.repo_checking = False
        if error is not None:
            # A transport failure is not a verdict about the repository. The
            # daemon restarting, or an SSH host taking longer than the deadline,
            # would otherwise manufacture "location unavailable", fire a
            # notification and turn the icon red -- for a location that is
            # perfectly fine.
            self.log("repo.status: %s", error)
            self.state.repo_stale = True
        else:
            self.state.repo = RepoStatus.from_wire(result)
            self.state.repo_stale = False
            self._maybe_warn_repo()
        self.rebuild_menu()

    # -- events ----------------------------------------------------------------

    def on_event(self, event):
        name = event.name
        if name in (EVENT_STARTED, EVENT_PHASE, EVENT_PROGRESS):
            self._apply_job_event(event)
        elif name == EVENT_FINISHED:
            self._on_job_finished(event)
        elif name == EVENT_SNAPSHOTS_CHANGED:
            self._fetch_repo(force=True)
        elif name == EVENT_CONFIG_CHANGED:
            self._poll_schedule()
        else:
            self.log("unhandled event %s", name)
            return
        self.rebuild_menu()

    def _apply_job_event(self, event):
        job_id = event.job
        if not job_id:
            return
        payload = event.payload
        job = self._jobs.get(job_id)
        if job is None:
            job = Job(id=job_id)
            self._jobs[job_id] = job
            self._first_seen[job_id] = self.clock()

        # The daemon repeats the kind on every event. Older daemons do not, and
        # then jobs.get is the only place that says -- a round trip this races
        # against a short job, which is exactly why the field was added.
        kind = payload.get("kind")
        if isinstance(kind, str) and kind:
            job.kind = kind
        elif not job.kind:
            self._ask_kind(job_id)

        state = payload.get("state")
        if isinstance(state, str) and state:
            job.state = state
        elif not job.state:
            job.state = "running"
        phase = payload.get("phase")
        if isinstance(phase, str) and phase:
            job.phase = phase
        if isinstance(payload.get("progress"), dict):
            job.progress = Progress.from_wire(payload["progress"])
        if event.name == EVENT_STARTED and job.kind in MUTATING_KINDS:
            self._cancel_create_latch()
        self._refresh_displayed_job()

    def _ask_kind(self, job_id):
        if job_id in self._kind_asked:
            return
        self._kind_asked.add(job_id)

        def answered(result, error):
            if error is not None:
                self.log("jobs.get %s: %s", job_id, error)
                return
            fetched = Job.from_wire(result)
            job = self._jobs.get(job_id)
            if job is None:
                # It finished while we were asking. Record the kind anyway: the
                # completion handler may still be waiting to decide whether this
                # was worth announcing.
                self._late_kind(job_id, fetched)
                return
            job.kind = job.kind or fetched.kind
            if not job.phase:
                job.phase = fetched.phase
            self._refresh_displayed_job()
            self.rebuild_menu()

        self.client.call(METHOD_JOBS_GET, {"job": job_id}, answered)

    def _late_kind(self, job_id, fetched):
        """A jobs.get that landed after its job finished."""
        pending = self._pending_finish.pop(job_id, None)
        if pending is None:
            return
        outcome, error, messages, count = pending
        self._notify_finished(fetched.kind, outcome, error, messages, count)
        if fetched.kind in MUTATING_KINDS:
            self._schedule_refetch()

    def _on_job_finished(self, event):
        payload = event.payload
        job_id = event.job
        job = self._jobs.get(job_id)

        kind = payload.get("kind")
        if not isinstance(kind, str) or not kind:
            kind = job.kind if job is not None else ""
        outcome = payload.get("outcome") or ""
        error = payload.get("error") or ""
        messages = [m for m in (payload.get("messages") or [])
                    if isinstance(m, str)]
        count = job.progress.count if job is not None else 0

        # Only the job that finished. Without this guard a sibling job's
        # completion cleared the running one: the progress rows vanished
        # mid-backup, "Create snapshot now" became clickable, and the toast
        # named the wrong operation.
        self._forget_job(job_id)

        if job_id and job_id not in self._announced:
            self._announced.add(job_id)
            if kind:
                self._notify_finished(kind, outcome, error, messages, count)
            else:
                # Kind still unknown: park the outcome for the jobs.get reply
                # rather than dropping it silently.
                self._pending_finish[job_id] = (outcome, error, messages, count)

        # An unknown kind is treated as mutating. Guessing wrong here costs one
        # extra read; guessing the other way leaves the snapshot list stale
        # after the very operation that changed it, because snapshots.changed
        # is not published for a create or a delete.
        if not kind or kind in MUTATING_KINDS:
            self._schedule_refetch()
        else:
            self._drain_pending_refresh()

    def _schedule_refetch(self):
        self._refresh_pending = True
        self.timers.once(2, self._drain_pending_refresh)

    def _forget_job(self, job_id):
        self._jobs.pop(job_id, None)
        self._first_seen.pop(job_id, None)
        self._kind_asked.discard(job_id)
        self._refresh_displayed_job()
        if not self._busy():
            self._cancel_create_latch()

    def _busy(self):
        return any(job.active for job in self._jobs.values())

    def _refresh_displayed_job(self):
        """One job is shown. Prefer the one that changes the repository."""
        active = [j for j in self._jobs.values() if j.active]
        mutating = [j for j in active if j.kind in MUTATING_KINDS]
        unknown = [j for j in active if not j.kind]
        self.state.job = (mutating or unknown or active or [None])[0]

    # -- notifications ---------------------------------------------------------

    def _notify_finished(self, kind, outcome, error, messages, count=0):
        verb = {"create": "Snapshot", "delete": "Snapshot deletion",
                "restore": "Restore"}.get(kind)
        if verb is None:
            return
        if outcome == OUTCOME_FAILED or error:
            body = error or "\n".join(messages)
            self.notifier.send("%s failed" % verb, body,
                               urgency=notify.URGENCY_CRITICAL, key=kind,
                               icon=icons.notification_icon("error"))
        elif outcome == OUTCOME_WARNINGS:
            # Not a failure: rsync answers 23 for files it could not read on a
            # running system, and the daemon records that as an outcome rather
            # than an error.
            self.notifier.send("%s finished with warnings" % verb,
                               messages[-1] if messages else "",
                               urgency=notify.URGENCY_NORMAL, key=kind,
                               icon=icons.notification_icon("warning"))
        else:
            done = {"create": "Snapshot created",
                    "delete": "Snapshots deleted",
                    "restore": "Restore finished"}[kind]
            # The one number a person wants to see at the end of a create.
            body = ""
            if kind == "create" and count > 0:
                body = "%s files" % fmt.format_count(count)
            self.notifier.send(done, body, urgency=notify.URGENCY_LOW,
                               key=kind, icon=icons.notification_icon("ok"))

    def _maybe_warn_repo(self):
        repo = self.state.repo
        available = repo.available if repo is not None else None
        if self._repo_available_before is True and available is False:
            body = " ".join(part for part in (repo.message, repo.details)
                            if part).strip()
            self.notifier.send("Snapshot location unavailable", body,
                               urgency=notify.URGENCY_NORMAL, key="repo",
                               icon=icons.notification_icon("error"))
        self._repo_available_before = available

    def _maybe_warn_scheduler(self):
        stalled = self.state.scheduler_stalled
        if stalled and not self._scheduler_warned:
            self._scheduler_warned = True
            self.notifier.send(
                "Scheduled snapshots are not running",
                "No automatic snapshots are being taken.",
                urgency=notify.URGENCY_NORMAL, key="scheduler",
                icon=icons.notification_icon("warning"))
        elif not stalled:
            self._scheduler_warned = False

    def warn_no_host(self):
        """Say so when nothing on the bus can draw a tray icon.

        Unconditional, not debug-only: "the icon never appeared" is the most
        likely support question, and on stock GNOME the cause is an extension
        that is installed but not enabled. Said once; the applet keeps running,
        because sni.py is watching and a host that arrives later still gets its
        icon without a re-login.
        """
        if self._no_host_warned:
            return
        self._no_host_warned = True
        return (
            "no StatusNotifierItem host on the session bus; the tray icon "
            "cannot be shown. On GNOME Shell, enable an appindicator "
            "extension:\n"
            "    gnome-extensions enable ubuntu-appindicators@ubuntu.com\n"
            "Still running: the icon will appear if a host arrives.")

    # -- menu ------------------------------------------------------------------

    def rebuild_menu(self):
        if self._rebuild_handle is not None:
            return
        self._rebuild_handle = self.timers.once_ms(
            REBUILD_COALESCE_MS, self._do_rebuild)

    def _do_rebuild(self):
        self._rebuild_handle = None
        now = self.clock()
        self.menu.set_tree(menutree.build_menu(self.state, now, self._ids))
        health = self.state.health(now)
        self.item.set_icon(icons.icon_for(health, self.icon_style),
                           attention=icons.wants_attention(health))
        self.item.set_tooltip(ITEM_TITLE, self._tooltip_body(now),
                              icons.icon_for(health, icons.STYLE_COLOUR))

    def _tooltip_body(self, now):
        """The verdict and the schedule, for hosts that show a tooltip."""
        if not self._ready():
            return ""
        headline, schedule, _location = menutree.summary_lines(self.state, now)
        return "%s\n%s" % (headline, schedule)

    def on_about_to_show(self, item_id):
        if item_id == 0:
            self._fetch_repo()

    # -- actions ---------------------------------------------------------------

    def on_action(self, action):
        self.spawner.activation_token = getattr(self.item, "activation_token", "")
        if action == menutree.ACTION_CREATE:
            self.create_snapshot()
        elif action == menutree.ACTION_OPEN:
            self.open_gui()
        elif action == menutree.ACTION_GRANT:
            self.grant_access()
        elif action == menutree.ACTION_REVOKE:
            self.revoke_access()
        elif action == menutree.ACTION_QUIT:
            self.quit()

    def create_snapshot(self):
        self._arm_create_latch()
        self.rebuild_menu()
        self.spawner.run(actions.CREATE_SNAPSHOT_ARGV, self._on_create_exit)

    def _on_create_exit(self, ok, message):
        if not ok:
            self._cancel_create_latch()
            self.log("create helper: %s", message)
            self.notifier.send("Could not start the snapshot",
                               message or "The helper did not run.",
                               urgency=notify.URGENCY_CRITICAL, key="create",
                               icon=icons.notification_icon("error"))
        self.rebuild_menu()

    def _arm_create_latch(self):
        """Disable the item while the polkit prompt is on screen.

        Cleared by the job actually starting; this is the timeout for a prompt
        nobody answered, so a cancelled password dialog does not leave the item
        disabled for the rest of the session.
        """
        self._cancel_create_latch()
        # Set AFTER cancelling: the previous version set the flag first and
        # then cleared it here, so the state was never observable.
        self.state.create_pending = True

        def expire():
            self._create_latch = None
            self.state.create_pending = False
            self.rebuild_menu()

        self._create_latch = self.timers.once(CREATE_LATCH_SECONDS, expire)

    def _cancel_create_latch(self):
        if self._create_latch is not None:
            self.timers.cancel(self._create_latch)
            self._create_latch = None
        self.state.create_pending = False

    def open_gui(self):
        self.spawner.run(actions.OPEN_TIMESHIFT_ARGV, self._on_helper_exit)

    def grant_access(self):
        self.spawner.run(actions.GRANT_ACCESS_ARGV, self._on_grant_exit)

    def revoke_access(self):
        self.spawner.run(actions.REVOKE_ACCESS_ARGV, self._on_revoke_exit)

    def _on_helper_exit(self, ok, message):
        if not ok:
            self.log("helper: %s", message)
            self.notifier.send("Could not open Timeshift",
                               message or "The launcher did not run.",
                               urgency=notify.URGENCY_NORMAL, key="open",
                               icon=icons.notification_icon("error"))

    def _on_grant_exit(self, ok, message):
        if not ok:
            self.log("grant helper: %s", message)
            self.notifier.send("Could not enable status access",
                               message or "The helper did not run.",
                               urgency=notify.URGENCY_NORMAL, key="grant",
                               icon=icons.notification_icon("error"))
            return
        self.notifier.send(
            "Timeshift status access enabled",
            "This account was added to the \"%s\" group. Log out and back in "
            "for it to take effect." % GROUP,
            urgency=notify.URGENCY_NORMAL, key="grant")
        # The credential this process holds was fixed at login, so this cannot
        # succeed yet; it is a no-op unless the account was already a member.
        self.client.retry_now()

    def _on_revoke_exit(self, ok, message):
        if not ok:
            self.log("revoke helper: %s", message)
            self.notifier.send("Could not remove status access",
                               message or "The helper did not run.",
                               urgency=notify.URGENCY_NORMAL, key="revoke",
                               icon=icons.notification_icon("error"))
            return
        self.notifier.send(
            "Timeshift status access removed",
            "This account was removed from the \"%s\" group. Log out and back "
            "in for it to take effect." % GROUP,
            urgency=notify.URGENCY_NORMAL, key="revoke")
