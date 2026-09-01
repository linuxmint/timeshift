package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

func testDaemon(t *testing.T) *daemon {
	t.Helper()

	dir := t.TempDir()
	path := filepath.Join(dir, "timeshift.json")

	cfg := config.Defaults()
	cfg.BackupDeviceUUID = "test-uuid"
	if err := config.Save(path, cfg); err != nil {
		t.Fatal(err)
	}

	loaded, _, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}

	d := newDaemon(slog.New(slog.NewTextHandler(io.Discard, nil)), path, loaded)
	t.Cleanup(d.queue.Close)
	return d
}

func setConfig(t *testing.T, d *daemon, values map[string]string) (config.Config, error) {
	t.Helper()

	raw := map[string]json.RawMessage{}
	for k, v := range values {
		raw[k] = json.RawMessage(v)
	}
	params, err := json.Marshal(ipc.ConfigSetParams{Values: raw})
	if err != nil {
		t.Fatal(err)
	}

	result, err := d.configSet(context.Background(), nil, params)
	if err != nil {
		return config.Config{}, err
	}
	return result.(config.Config), nil
}

func TestConfigSetPersistsAndReloads(t *testing.T) {
	d := testDaemon(t)

	got, err := setConfig(t, d, map[string]string{
		"schedule_hourly": `"true"`,
		"count_hourly":    `"9"`,
	})
	if err != nil {
		t.Fatalf("config.set: %v", err)
	}
	if !got.ScheduleHourly || got.CountHourly != 9 {
		t.Fatalf("returned config did not take the change: %+v", got)
	}

	// The daemon's own view must have moved too, or the next scheduled check
	// would run against the settings the user just changed away from.
	if !d.config().ScheduleHourly {
		t.Fatal("the daemon is still using the old configuration")
	}

	// And it must be on disk.
	onDisk, _, err := config.Load(d.configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !onDisk.ScheduleHourly || onDisk.CountHourly != 9 {
		t.Fatalf("the change did not reach the file: %+v", onDisk)
	}
}

// The file has to stay readable by the Vala GUI, which is still installed.
func TestConfigSetKeepsTheOnDiskFormat(t *testing.T) {
	d := testDaemon(t)

	if _, err := setConfig(t, d, map[string]string{"count_daily": `"7"`}); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(d.configPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)

	if !strings.Contains(text, `"count_daily" : "7"`) {
		t.Fatalf("not in json-glib format:\n%s", text)
	}
	if strings.HasSuffix(text, "\n") {
		t.Fatal("the file gained a trailing newline; json-glib writes none")
	}
}

// A partial update must not revert the keys it does not mention. This is the
// failure the Vala GUI has against this file, and reproducing it here would
// undo the reason for having one writer.
func TestConfigSetDoesNotRevertUnmentionedKeys(t *testing.T) {
	d := testDaemon(t)

	if _, err := setConfig(t, d, map[string]string{"backup_ssh_url": `"backup@host:/srv/ts"`}); err != nil {
		t.Fatal(err)
	}
	got, err := setConfig(t, d, map[string]string{"schedule_daily": `"true"`})
	if err != nil {
		t.Fatal(err)
	}

	if got.BackupSSHURL != "backup@host:/srv/ts" {
		t.Fatalf("the second update reverted the first: ssh url = %q", got.BackupSSHURL)
	}
	if got.BackupDeviceUUID != "test-uuid" {
		t.Fatalf("an untouched key was lost: %q", got.BackupDeviceUUID)
	}
}

func TestConfigSetRejectsBadInput(t *testing.T) {
	d := testDaemon(t)

	if _, err := setConfig(t, d, map[string]string{"schedule_hourley": `"true"`}); err == nil {
		t.Error("a misspelled setting was accepted")
	}
	if _, err := setConfig(t, d, map[string]string{"schedule_hourly": `true`}); err == nil {
		t.Error("a real JSON boolean was accepted for a string-typed setting")
	}

	// A rejected update must leave the file alone.
	onDisk, _, err := config.Load(d.configPath)
	if err != nil {
		t.Fatal(err)
	}
	if onDisk.ScheduleHourly {
		t.Fatal("a rejected update was partly applied")
	}
}

// Other clients have to learn that a setting changed, or a second window keeps
// showing what is no longer true.
func TestConfigSetAnnouncesTheChange(t *testing.T) {
	d := testDaemon(t)

	sub := d.queue.Hub().Subscribe(jobs.SubscribeOptions{})
	defer sub.Close()

	if _, err := setConfig(t, d, map[string]string{"schedule_weekly": `"true"`}); err != nil {
		t.Fatal(err)
	}

	select {
	case e := <-sub.C:
		if e.Type != jobs.EventConfigChanged {
			t.Fatalf("event = %q, want %q", e.Type, jobs.EventConfigChanged)
		}
	default:
		t.Fatal("no config.changed event was published")
	}
}

func TestRepoReloadRereadsTheFile(t *testing.T) {
	d := testDaemon(t)

	// Simulate the other writer: the Vala GUI saving directly.
	cfg, _, err := config.Load(d.configPath)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ScheduleMonthly = true
	if err := config.Save(d.configPath, cfg); err != nil {
		t.Fatal(err)
	}

	if d.config().ScheduleMonthly {
		t.Fatal("the daemon saw the change without being told; this test proves nothing")
	}

	if _, err := d.repoReload(context.Background(), nil, nil); err != nil {
		t.Fatalf("repo.reload: %v", err)
	}
	if !d.config().ScheduleMonthly {
		t.Fatal("repo.reload did not pick up the change made by the other writer")
	}
}

/* config.get must return what config.set accepts.
 *
 * It used to return the Go struct, which marshals to Go field names
 * ("BackupSSHPort") and native types (22, not "22"), while config.set takes
 * the on-disk names and the on-disk shapes. The two could not round-trip -- a
 * client could not read a value, change it and write it back, which is the
 * only thing a settings page ever does. Nothing caught it because nothing had
 * ever read config.get and fed it back.
 */
func TestConfigGetReturnsWhatConfigSetAccepts(t *testing.T) {
	cfg := config.Defaults()
	cfg.BackupSSHPort = 2222
	cfg.BackupLocationType = "ssh"

	raw := config.Marshal(cfg)

	var got map[string]json.RawMessage
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("config.get output is not an object: %v", err)
	}

	// On-disk names, not Go field names.
	for _, key := range []string{
		"backup_device_uuid", "backup_location_type", "backup_ssh_port",
		"btrfs_mode", "schedule_daily", "count_daily",
	} {
		if _, ok := got[key]; !ok {
			t.Errorf("config.get is missing the on-disk key %q", key)
		}
	}
	for _, goName := range []string{"BackupSSHPort", "BtrfsMode", "ScheduleDaily"} {
		if _, ok := got[goName]; ok {
			t.Errorf("config.get leaked the Go field name %q", goName)
		}
	}

	/* Every scalar is a JSON string. A real number here is the failure that
	 * matters: Unmarshal keeps the old value for a wrongly-typed field, so the
	 * change is accepted and silently dropped. */
	for key, v := range got {
		s := string(v)
		if strings.HasPrefix(s, "[") {
			continue // the two exclude lists are arrays
		}
		if !strings.HasPrefix(s, `"`) {
			t.Errorf("%s = %s, want a JSON string", key, s)
		}
	}

	// And what came out must go back in unchanged.
	if _, err := config.Apply(cfg, got); err != nil {
		t.Fatalf("config.set refused what config.get returned: %v", err)
	}
}
