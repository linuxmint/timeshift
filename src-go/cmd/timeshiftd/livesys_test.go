package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/schedule"
)

/* A live session must refuse to write a snapshot.
 *
 * The failure this guards is not an error message anybody would see. It is a
 * snapshot of the recovery environment's ramdisk arriving in the user's real
 * repository -- and the retention pass that follows counting it towards a
 * level's limit, which can untag and so delete a real snapshot to make room
 * for it. The recovery environment boots boot=casper, enables timeshiftd, and
 * carries a copy of the user's timeshift.json, so every ingredient is present.
 */
func TestLiveSessionRefusesToCreate(t *testing.T) {
	d := testDaemon(t)
	d.live = true

	_, err := d.snapshotCreate(context.Background(), nil, json.RawMessage(`{}`))
	if err == nil {
		t.Fatal("snapshot.create must be refused on live media")
	}
	if !strings.Contains(err.Error(), "live session") {
		t.Fatalf("the refusal must say why; got %q", err)
	}
	var e *ipc.Error
	if !errors.As(err, &e) || e.Code != ipc.CodeUnavailable {
		t.Fatalf("want a %s error, got %v", ipc.CodeUnavailable, err)
	}
}

func TestLiveSessionRefusesScheduledCheck(t *testing.T) {
	d := testDaemon(t)
	d.live = true

	if _, err := d.scheduleCheck(context.Background(), nil, nil); err == nil {
		t.Fatal("schedule.check must be refused on live media")
	}
}

/* An installed system must be unaffected.
 *
 * Worth its own test rather than trusting the flag: a guard that refuses
 * everywhere is indistinguishable from a broken daemon, and this is the case
 * that actually runs on every user's machine.
 */
func TestInstalledSystemStillCreates(t *testing.T) {
	d := testDaemon(t)
	d.live = false

	// The repository is not reachable in a unit test, so this fails later --
	// but it must get PAST the live guard, which is what is being asserted.
	_, err := d.snapshotCreate(context.Background(), nil, json.RawMessage(`{}`))
	if err != nil && strings.Contains(err.Error(), "live session") {
		t.Fatalf("an installed system must not be refused as live: %v", err)
	}
}

/* Enabled still reports the config, and Live explains the silence.
 *
 * A client seeing Enabled true with Running false has to warn that the machine
 * is taking no snapshots -- that is the failure losing cron introduced. On live
 * media the same two values are correct and unalarming, so something has to
 * tell the two apart.
 */
func TestScheduleStatusDistinguishesLiveFromDeadScheduler(t *testing.T) {
	d := testDaemon(t)
	d.live = true
	d.ticker = nil

	set, err := setConfig(t, d, map[string]string{"schedule_daily": `"true"`})
	if err != nil {
		t.Fatal(err)
	}
	if !set.ScheduleDaily {
		t.Fatal("precondition: daily schedule should be on")
	}

	got, err := d.scheduleStatus(context.Background(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	st, ok := got.(schedule.Status)
	if !ok {
		t.Fatalf("want a schedule.Status, got %T", got)
	}
	if !st.Enabled {
		t.Error("Enabled must still report the user's configuration")
	}
	if st.Running {
		t.Error("Running must be false: no ticker is started on live media")
	}
	if !st.Live {
		t.Error("Live must say why the scheduler is not running")
	}
}

func TestSystemInfoReportsLive(t *testing.T) {
	d := testDaemon(t)
	d.live = true

	got, err := d.systemInfo(context.Background(), &ipc.Conn{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	info, ok := got.(ipc.SystemInfo)
	if !ok {
		t.Fatalf("want an ipc.SystemInfo, got %T", got)
	}
	if !info.Live {
		t.Error("system.info must report a live session so a client can explain itself")
	}
}
