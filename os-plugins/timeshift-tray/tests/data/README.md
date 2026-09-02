# Corpus

Real replies from a running `timeshiftd`, captured on 2026-09-01 from a machine
whose repository is a **remote (SSH)** location, by connecting to
`/run/timeshift/daemon.sock` as root and calling each method once:

| file | method |
|---|---|
| `system_info.json` | `system.info` |
| `schedule_status.json` | `schedule.status` |
| `repo_status.json` | `repo.status` |
| `snapshots_list.json` | `snapshots.list` (26 snapshots) |
| `jobs_list.json` | `jobs.list` (two finished create jobs) |

Captured rather than invented because the two things most likely to be wrong
about them cannot be guessed from the Go source at a glance:

* `snapshots.list` marshals **Go field names** (`Name`, `Created`, `SizeBytes`)
  because `engines.Snapshot` carries no json tags, while everything else on the
  same socket is snake_case.
* free space exists only as prose inside `repo.status`'s `details`
  ("26 snapshots, 29.9 TB free"); there is no number to read anywhere on that
  reply, and on this remote repository there is not even a device to measure.

They also pin the timestamp format: nine fractional digits and a numeric
offset, e.g. `2026-09-01T09:03:20.377161285-04:00`.

Two cases could not be captured here and are hand-written in the tests that
need them:

* a Go **zero time** (`0001-01-01T00:00:00Z`), which is what an unset
  `last_run`/`next_run`/`finished` looks like -- `omitempty` does nothing for a
  `time.Time`. Covered in `test_fmt.py`.
* a job in flight. Every job in the capture had already finished. Progress
  events are synthesised in `test_menutree.py` from the shape `jobs_list.json`
  shows.
