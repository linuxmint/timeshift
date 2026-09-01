package config

import (
	"encoding/json"
	"strings"
	"testing"
)

func raw(v string) json.RawMessage { return json.RawMessage(v) }

func TestApplyChangesOnlyTheKeysGiven(t *testing.T) {
	c := Defaults()
	c.BackupDeviceUUID = "keep-me"
	c.CountHourly = 6

	got, err := Apply(c, map[string]json.RawMessage{
		"schedule_hourly": raw(`"true"`),
		"count_hourly":    raw(`"9"`),
	})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}

	if !got.ScheduleHourly {
		t.Error("schedule_hourly was not applied")
	}
	if got.CountHourly != 9 {
		t.Errorf("count_hourly = %d, want 9", got.CountHourly)
	}
	if got.BackupDeviceUUID != "keep-me" {
		t.Errorf("an untouched key was lost: backup_device_uuid = %q", got.BackupDeviceUUID)
	}
	if got.CountDaily != c.CountDaily {
		t.Errorf("an untouched key changed: count_daily = %d, want %d", got.CountDaily, c.CountDaily)
	}
}

func TestApplyRoundTripsThroughTheFileFormat(t *testing.T) {
	c := Defaults()

	got, err := Apply(c, map[string]json.RawMessage{"count_weekly": raw(`"4"`)})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}

	// The result must still marshal to the json-glib format the Vala GUI reads.
	out := string(Marshal(got))
	if !strings.Contains(out, `"count_weekly" : "4"`) {
		t.Fatalf("output is not in the on-disk format:\n%s", out)
	}
}

// A typo must be refused. Accepting it quietly looks exactly like a setting
// that does not work.
func TestApplyRefusesAnUnknownKey(t *testing.T) {
	_, err := Apply(Defaults(), map[string]json.RawMessage{"schedule_hourley": raw(`"true"`)})
	if err == nil {
		t.Fatal("an unknown setting was accepted")
	}
	if !strings.Contains(err.Error(), "unknown setting") {
		t.Fatalf("unhelpful error: %v", err)
	}
}

/* The trap this file exists to catch.
 *
 * Every value in timeshift.json is a JSON string. A client sending a real
 * boolean would otherwise have its change accepted and silently dropped, since
 * Unmarshal keeps the old value for a member of the wrong type.
 */
func TestApplyRefusesAWronglyTypedValue(t *testing.T) {
	_, err := Apply(Defaults(), map[string]json.RawMessage{"schedule_hourly": raw(`true`)})
	if err == nil {
		t.Fatal("a real JSON boolean was accepted for a string-typed setting")
	}
	if !strings.Contains(err.Error(), "must be a JSON string") {
		t.Fatalf("the error does not explain the format: %v", err)
	}

	if _, err := Apply(Defaults(), map[string]json.RawMessage{"count_hourly": raw(`5`)}); err == nil {
		t.Fatal("a real JSON number was accepted for a string-typed setting")
	}
}

func TestApplyHandlesTheExcludeArrays(t *testing.T) {
	got, err := Apply(Defaults(), map[string]json.RawMessage{
		"exclude": raw(`["/home/user/.cache/**","/var/log/**"]`),
	})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if len(got.Exclude) != 2 || got.Exclude[0] != "/home/user/.cache/**" {
		t.Fatalf("exclude = %v", got.Exclude)
	}

	if _, err := Apply(Defaults(), map[string]json.RawMessage{"exclude": raw(`"/tmp"`)}); err == nil {
		t.Fatal("a string was accepted for an array-typed setting")
	}
}

// An empty update is a no-op, not an error: a client that computed no changes
// should not have to special-case sending nothing.
func TestApplyWithNoValuesChangesNothing(t *testing.T) {
	c := Defaults()
	c.BackupSSHURL = "backup@host:/srv/timeshift"

	got, err := Apply(c, nil)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if string(Marshal(got)) != string(Marshal(c)) {
		t.Fatal("an empty update changed the configuration")
	}
}

/* A key the daemon reads but does not normally write must survive an edit.
 *
 * startup_delay_interval_mins is omitted from a config that never had it, so a
 * Vala-written file stays byte-identical. But once someone has set it by hand,
 * changing an unrelated setting must not silently delete it.
 */
func TestApplyPreservesAHandSetStartupDelay(t *testing.T) {
	original := []byte(`{
  "backup_device_uuid" : "u",
  "startup_delay_interval_mins" : "25",
  "schedule_hourly" : "false"
}`)

	c, err := Unmarshal(original)
	if err != nil {
		t.Fatal(err)
	}
	if c.StartupDelayIntervalMins != 25 {
		t.Fatalf("read %d, want 25", c.StartupDelayIntervalMins)
	}

	got, err := Apply(c, map[string]json.RawMessage{"schedule_hourly": raw(`"true"`)})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if got.StartupDelayIntervalMins != 25 {
		t.Fatalf("the hand-set value was lost: %d", got.StartupDelayIntervalMins)
	}
	if !strings.Contains(string(Marshal(got)), `"startup_delay_interval_mins" : "25"`) {
		t.Fatalf("the key was dropped on write:\n%s", Marshal(got))
	}
}

// And a config that never had the key must not gain it, or every save would
// churn a file the Vala GUI also writes.
func TestApplyDoesNotIntroduceTheStartupDelayKey(t *testing.T) {
	c, err := Unmarshal([]byte(`{ "backup_device_uuid" : "u", "schedule_hourly" : "false" }`))
	if err != nil {
		t.Fatal(err)
	}

	got, err := Apply(c, map[string]json.RawMessage{"schedule_hourly": raw(`"true"`)})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if strings.Contains(string(Marshal(got)), "startup_delay_interval_mins") {
		t.Fatalf("a key the file never had was introduced:\n%s", Marshal(got))
	}
}

// Setting an optional key on a file that never had it must work, and must add
// it. Reporting a real setting as unknown because the file had not mentioned it
// would be the worst of both behaviours.
func TestApplyCanIntroduceAnOptionalKeyWhenAsked(t *testing.T) {
	c, err := Unmarshal([]byte(`{ "backup_device_uuid" : "u" }`))
	if err != nil {
		t.Fatal(err)
	}

	got, err := Apply(c, map[string]json.RawMessage{
		"startup_delay_interval_mins": raw(`"3"`),
	})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if got.StartupDelayIntervalMins != 3 {
		t.Fatalf("value = %d, want 3", got.StartupDelayIntervalMins)
	}
	if !strings.Contains(string(Marshal(got)), `"startup_delay_interval_mins" : "3"`) {
		t.Fatalf("the key was not written:\n%s", Marshal(got))
	}
}
