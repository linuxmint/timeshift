// Package config reads and writes /etc/timeshift/timeshift.json.
//
// Two properties of that file are contracts, not implementation details:
//
//   - Every value is a JSON *string*, including booleans and numbers:
//     "btrfs_mode" : "false", "count_daily" : "5". The Vala side wrote them
//     with set_string_member() throughout and reads them back through
//     json_get_bool/int/uint64, which parse the string. A Go writer that emits
//     a real bool or number produces a file the GUI silently misreads.
//
//   - The layout is json-glib's pretty printer, which is not encoding/json's:
//     the separator is `" : "`, array elements indent by 4 while their closing
//     bracket indents by 2, an empty array is `[]` on one line, and there is no
//     trailing newline. Reproducing it exactly keeps `git diff` and any
//     side-by-side comparison with the Vala build meaningful.
//
// Key order is the order save_app_config() writes them (src/Core/Main.vala:4595)
// and is reproduced by the field order of Config plus the two conditional
// blocks in Marshal.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// SystemPath is where the daemon reads and writes its configuration.
const SystemPath = "/etc/timeshift/timeshift.json"

// LegacyPath is the pre-2018 location, migrated on first read.
const LegacyPath = "/etc/timeshift.json"

// DefaultDateFormat matches Main.date_format's initialiser.
const DefaultDateFormat = "%Y-%m-%d %H:%M:%S"

// Config is the on-disk configuration.
//
// The zero value is not useful; start from Defaults(). Fields are ordered as
// they are serialised.
type Config struct {
	BackupDeviceUUID string
	ParentDeviceUUID string

	BackupLocationType string // "local" | "ssh"
	BackupSSHURL       string
	BackupSSHKey       string
	BackupSSHPort      int
	BackupSSHFakeSuper bool

	DoFirstRun bool // always written false; only meaningful on read

	BtrfsMode                  bool
	IncludeBtrfsHomeForBackup  bool
	IncludeBtrfsHomeForRestore bool
	StopCronEmails             bool

	ScheduleMonthly bool
	ScheduleWeekly  bool
	ScheduleDaily   bool
	ScheduleHourly  bool
	ScheduleBoot    bool

	// StartupDelayIntervalMins holds the first scheduled check back after the
	// machine boots. The original declared this field and never used it: the
	// delay was hard-coded into the cron line as "sleep 10m". Now that the
	// daemon owns the timer the field does the job it was named for.
	StartupDelayIntervalMins int

	CountMonthly int
	CountWeekly  int
	CountDaily   int
	CountHourly  int
	CountBoot    int

	// The estimated size and file count of the first snapshot. Written only
	// once the repository actually has snapshots, and doubling as the progress
	// denominator everywhere else.
	SnapshotSize  uint64
	SnapshotCount int64

	DateFormat  string
	ThemeMode   string // system | light | dark
	ThemeAccent string // system | a preset key

	Exclude     []string
	ExcludeApps []string

	// PauseSnapshots is either unix seconds ("1756400000") or a boot id, and is
	// absent from the file when snapshots are not paused. Kept as the raw
	// string so a boot id survives a round trip untouched.
	PauseSnapshots string

	// Engine names the storage engine that owns this location. Absent in every
	// file written before engines existed, which is why it defaults to
	// "timeshift" rather than erroring.
	Engine string

	// present records which optional keys the file we read actually had, so
	// Marshal can put back exactly what it found.
	present map[string]bool
}

// EngineDefault is the engine every pre-existing installation is using.
const EngineDefault = "timeshift"

// Defaults returns the configuration of a fresh install, matching the
// initialisers in Main.vala and files/timeshift.json.
func Defaults() Config {
	return Config{
		BackupLocationType:       "local",
		DoFirstRun:               true,
		StopCronEmails:           true,
		StartupDelayIntervalMins: 10,

		CountMonthly: 2,
		CountWeekly:  3,
		CountDaily:   5,
		CountHourly:  6,
		CountBoot:    5,
		DateFormat:   DefaultDateFormat,
		ThemeMode:    "system",
		ThemeAccent:  "system",
		Exclude:      []string{},
		ExcludeApps:  []string{},
		Engine:       EngineDefault,
		present:      map[string]bool{},
	}
}

// Scheduled reports whether any schedule level is enabled. Mirrors the
// `scheduled` property at Main.vala:1281.
func (c *Config) Scheduled() bool {
	return c.ScheduleMonthly || c.ScheduleWeekly || c.ScheduleDaily ||
		c.ScheduleHourly || c.ScheduleBoot
}

// Remote reports whether the configured location is reached over SSH.
func (c *Config) Remote() bool { return c.BackupLocationType == "ssh" }

// Load reads path. A missing file is not an error: it returns Defaults() with
// found == false, which is how first-run is detected.
func Load(path string) (Config, bool, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Defaults(), false, nil
	}
	if err != nil {
		return Defaults(), false, fmt.Errorf("config: read %s: %w", path, err)
	}
	c, err := Unmarshal(raw)
	if err != nil {
		return Defaults(), false, fmt.Errorf("config: parse %s: %w", path, err)
	}
	return c, true, nil
}

// Save writes c to path atomically: a crash mid-write must not leave a
// half-written config, because the next run would treat it as a first run and
// silently forget the snapshot location.
func Save(path string, c Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return fmt.Errorf("config: mkdir: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".timeshift.json.*")
	if err != nil {
		return fmt.Errorf("config: temp file: %w", err)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(Marshal(c)); err != nil {
		tmp.Close()
		return fmt.Errorf("config: write: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("config: sync: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("config: close: %w", err)
	}
	if err := os.Chmod(tmp.Name(), 0644); err != nil {
		return fmt.Errorf("config: chmod: %w", err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("config: rename: %w", err)
	}
	return nil
}

// Unmarshal parses the string-typed JSON object.
func Unmarshal(raw []byte) (Config, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return Config{}, err
	}

	c := Defaults()
	c.present = make(map[string]bool, len(obj))
	for k := range obj {
		c.present[k] = true
	}

	str := func(key string, dst *string) {
		if v, ok := obj[key]; ok {
			var s string
			if json.Unmarshal(v, &s) == nil {
				*dst = s
			}
		}
	}
	/* Values are strings on disk, so a bool is the text "true". Anything else
	 * -- including a real JSON true, which no Timeshift ever wrote -- leaves
	 * the default in place rather than guessing. */
	bl := func(key string, dst *bool) {
		if v, ok := obj[key]; ok {
			var s string
			if json.Unmarshal(v, &s) == nil {
				*dst = s == "true"
			}
		}
	}
	num := func(key string, set func(string)) {
		if v, ok := obj[key]; ok {
			var s string
			if json.Unmarshal(v, &s) == nil {
				set(s)
			}
		}
	}
	in := func(key string, dst *int) {
		num(key, func(s string) {
			if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
				*dst = n
			}
		})
	}
	arr := func(key string, dst *[]string) {
		if v, ok := obj[key]; ok {
			var a []string
			if json.Unmarshal(v, &a) == nil {
				*dst = a
			}
		}
	}

	str("backup_device_uuid", &c.BackupDeviceUUID)
	str("parent_device_uuid", &c.ParentDeviceUUID)
	str("backup_location_type", &c.BackupLocationType)
	str("backup_ssh_url", &c.BackupSSHURL)
	str("backup_ssh_key", &c.BackupSSHKey)
	in("backup_ssh_port", &c.BackupSSHPort)
	bl("backup_ssh_fake_super", &c.BackupSSHFakeSuper)

	bl("do_first_run", &c.DoFirstRun)
	bl("btrfs_mode", &c.BtrfsMode)

	// include_btrfs_home is the pre-split legacy name; the specific keys win.
	bl("include_btrfs_home", &c.IncludeBtrfsHomeForBackup)
	bl("include_btrfs_home_for_backup", &c.IncludeBtrfsHomeForBackup)
	bl("include_btrfs_home_for_restore", &c.IncludeBtrfsHomeForRestore)
	bl("stop_cron_emails", &c.StopCronEmails)

	bl("schedule_monthly", &c.ScheduleMonthly)
	bl("schedule_weekly", &c.ScheduleWeekly)
	bl("schedule_daily", &c.ScheduleDaily)
	bl("schedule_hourly", &c.ScheduleHourly)
	bl("schedule_boot", &c.ScheduleBoot)

	in("startup_delay_interval_mins", &c.StartupDelayIntervalMins)

	in("count_monthly", &c.CountMonthly)
	in("count_weekly", &c.CountWeekly)
	in("count_daily", &c.CountDaily)
	in("count_hourly", &c.CountHourly)
	in("count_boot", &c.CountBoot)

	num("snapshot_size", func(s string) {
		if n, err := strconv.ParseUint(strings.TrimSpace(s), 10, 64); err == nil {
			c.SnapshotSize = n
		}
	})
	num("snapshot_count", func(s string) {
		if n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64); err == nil {
			c.SnapshotCount = n
		}
	})

	str("date_format", &c.DateFormat)
	str("theme_mode", &c.ThemeMode)
	str("theme_accent", &c.ThemeAccent)

	arr("exclude", &c.Exclude)
	arr("exclude-apps", &c.ExcludeApps)

	str("pause_snapshots", &c.PauseSnapshots)
	str("engine", &c.Engine)
	if strings.TrimSpace(c.Engine) == "" {
		c.Engine = EngineDefault
	}

	/* Two invariants applied on load, exactly where Vala applies them
	 * (Main.vala:4753). btrfs snapshots are subvolume operations on a local
	 * filesystem; they cannot happen over rsync-to-a-remote-host. */
	if c.Remote() {
		c.BtrfsMode = false
	}

	return c, nil
}

// Marshal renders c in json-glib's pretty format, byte for byte.
func Marshal(c Config) []byte {
	var b strings.Builder
	b.WriteString("{\n")

	first := true
	kv := func(key, val string) {
		if !first {
			b.WriteString(",\n")
		}
		first = false
		fmt.Fprintf(&b, "  %s : %s", quote(key), quote(val))
	}
	list := func(key string, vals []string) {
		if !first {
			b.WriteString(",\n")
		}
		first = false
		if len(vals) == 0 {
			// json-glib collapses an empty array onto one line.
			fmt.Fprintf(&b, "  %s : []", quote(key))
			return
		}
		fmt.Fprintf(&b, "  %s : [\n", quote(key))
		for i, v := range vals {
			b.WriteString("    ")
			b.WriteString(quote(v))
			if i < len(vals)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString("  ]")
	}

	kv("backup_device_uuid", c.BackupDeviceUUID)
	kv("parent_device_uuid", c.ParentDeviceUUID)
	kv("backup_location_type", c.BackupLocationType)
	kv("backup_ssh_url", c.BackupSSHURL)
	kv("backup_ssh_key", c.BackupSSHKey)
	kv("backup_ssh_port", strconv.Itoa(c.BackupSSHPort))
	kv("backup_ssh_fake_super", boolStr(c.BackupSSHFakeSuper))

	// Always written false: reaching the point of saving means the first run is
	// over. Matches `config.set_string_member("do_first_run", false.to_string())`.
	kv("do_first_run", "false")

	kv("btrfs_mode", boolStr(c.BtrfsMode))
	kv("include_btrfs_home_for_backup", boolStr(c.IncludeBtrfsHomeForBackup))
	kv("include_btrfs_home_for_restore", boolStr(c.IncludeBtrfsHomeForRestore))
	kv("stop_cron_emails", boolStr(c.StopCronEmails))

	kv("schedule_monthly", boolStr(c.ScheduleMonthly))
	kv("schedule_weekly", boolStr(c.ScheduleWeekly))
	kv("schedule_daily", boolStr(c.ScheduleDaily))
	kv("schedule_hourly", boolStr(c.ScheduleHourly))
	kv("schedule_boot", boolStr(c.ScheduleBoot))

	/* startup_delay_interval_mins is written only if it was already there.
	 *
	 * Emitting it unconditionally would make it appear and vanish depending on
	 * which program last saved: while the Vala GUI is still installed there
	 * are two writers of this file and the Vala one drops every key it does not
	 * know, so the key would churn in a file people put in configuration
	 * management.
	 *
	 * Never emitting it is worse in the other direction, and that was the bug
	 * here: someone who sets it by hand would have it silently deleted the
	 * first time any setting was changed. Preserving what the file had keeps a
	 * Vala-written config byte-identical -- it never contains this key -- while
	 * a hand-edited one keeps its value. */
	if c.present["startup_delay_interval_mins"] {
		kv("startup_delay_interval_mins", strconv.Itoa(c.StartupDelayIntervalMins))
	}

	kv("count_monthly", strconv.Itoa(c.CountMonthly))
	kv("count_weekly", strconv.Itoa(c.CountWeekly))
	kv("count_daily", strconv.Itoa(c.CountDaily))
	kv("count_hourly", strconv.Itoa(c.CountHourly))
	kv("count_boot", strconv.Itoa(c.CountBoot))

	/* Conditional in Vala on `repo.available() && repo.has_snapshots()`. The
	 * daemon has no repository handle here, so the rule is restated in terms of
	 * the data: write the estimate back if we have one, or if the file we read
	 * already carried it. The in-memory values are never cleared -- zeroing
	 * them threw away the numbers driving the first backup's progress bar. */
	if c.SnapshotSize > 0 || c.SnapshotCount > 0 || c.present["snapshot_size"] {
		kv("snapshot_size", strconv.FormatUint(c.SnapshotSize, 10))
		kv("snapshot_count", strconv.FormatInt(c.SnapshotCount, 10))
	}

	kv("date_format", c.DateFormat)
	kv("theme_mode", c.ThemeMode)
	kv("theme_accent", c.ThemeAccent)

	list("exclude", c.Exclude)
	list("exclude-apps", c.ExcludeApps)

	if c.PauseSnapshots != "" {
		kv("pause_snapshots", c.PauseSnapshots)
	}

	/* Only written once it is not the default, so upgrading Timeshift does not
	 * rewrite every existing config with a key its own GUI would ignore. */
	if c.Engine != "" && c.Engine != EngineDefault {
		kv("engine", c.Engine)
	}

	b.WriteString("\n}")
	return []byte(b.String())
}

// boolStr renders a bool the way Vala's bool.to_string() does.
func boolStr(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

/* json-glib escapes the same characters encoding/json does for these values --
 * exclude patterns and device paths are plain ASCII in practice -- but it does
 * NOT escape < > & the way encoding/json does by default. Marshalling through
 * a json.Encoder with SetEscapeHTML(false) gets both halves right. */
func quote(s string) string {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return strconv.Quote(s)
	}
	return strings.TrimRight(b.String(), "\n")
}

// Keys lists every key Marshal can emit, in order. Used by the round-trip test
// to report which key diverged rather than dumping two whole files.
func Keys() []string {
	return []string{
		"backup_device_uuid", "parent_device_uuid", "backup_location_type",
		"backup_ssh_url", "backup_ssh_key", "backup_ssh_port",
		"backup_ssh_fake_super", "do_first_run", "btrfs_mode",
		"include_btrfs_home_for_backup", "include_btrfs_home_for_restore",
		"stop_cron_emails", "schedule_monthly", "schedule_weekly",
		"schedule_daily", "schedule_hourly", "schedule_boot",
		"count_monthly", "count_weekly", "count_daily", "count_hourly",
		"count_boot", "snapshot_size", "snapshot_count", "date_format",
		"theme_mode", "theme_accent", "exclude", "exclude-apps",
		"pause_snapshots", "engine",
	}
}

// UnknownKeys reports keys present in raw that Marshal would drop. A non-empty
// result means a round trip would lose data.
func UnknownKeys(raw []byte) ([]string, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, err
	}
	known := map[string]bool{"include_btrfs_home": true}
	for _, k := range Keys() {
		known[k] = true
	}
	var out []string
	for k := range obj {
		if !known[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out, nil
}

/* Applying a partial update.
 *
 * The GUI changes one setting at a time, so an update names only the keys it
 * touches. Sending a whole Config instead would mean a client that is a version
 * behind silently reverting every key it does not know about -- which is the
 * exact failure the Vala GUI already has against this file, and the reason
 * startup_delay_interval_mins cannot be written while that GUI still ships.
 *
 * The merge goes through Marshal and Unmarshal rather than a second key table.
 * That is not laziness: a separate table would be a second place to add a
 * setting, and the one that got forgotten would fail silently -- the value
 * would be accepted and dropped.
 */
func Apply(c Config, values map[string]json.RawMessage) (Config, error) {

	/* The reference object lists every settable key, including the optional
	 * ones this config does not currently carry. Validating against Marshal(c)
	 * alone would report a real setting as unknown purely because the file
	 * being edited had never mentioned it. */
	reference := c
	reference.present = allOptionalKeysPresent(c.present)

	var obj map[string]json.RawMessage
	if err := json.Unmarshal(Marshal(reference), &obj); err != nil {
		return c, fmt.Errorf("config: re-read own output: %w", err)
	}

	// Keys the file did not have and the update does not set stay absent.
	for key := range obj {
		if optionalKeys[key] && !c.present[key] {
			if _, setting := values[key]; !setting {
				delete(obj, key)
			}
		}
	}

	for key, value := range values {
		if _, known := obj[key]; !known {
			/* Refused, not ignored. A typo that is quietly accepted looks
			 * exactly like a setting that does not work, and the report comes
			 * back as "Timeshift ignores my schedule". */
			return c, fmt.Errorf("config: unknown setting %q", key)
		}
		if err := checkShape(key, obj[key], value); err != nil {
			return c, err
		}
		obj[key] = value
	}

	merged, err := json.Marshal(obj)
	if err != nil {
		return c, fmt.Errorf("config: merge: %w", err)
	}

	updated, err := Unmarshal(merged)
	if err != nil {
		return c, fmt.Errorf("config: apply: %w", err)
	}
	return updated, nil
}

/* Keys Marshal emits only when the file already had them.
 *
 * They are omitted from a config that never carried them so that a file the
 * Vala GUI also writes does not churn, and preserved once someone has set one
 * by hand. See the note in Marshal.
 */
var optionalKeys = map[string]bool{
	"startup_delay_interval_mins": true,
}

func allOptionalKeysPresent(current map[string]bool) map[string]bool {
	out := make(map[string]bool, len(current)+len(optionalKeys))
	for k, v := range current {
		out[k] = v
	}
	for k := range optionalKeys {
		out[k] = true
	}
	return out
}

/* checkShape rejects a value of the wrong JSON kind.
 *
 * Every scalar in this file is a STRING ("true", "5"), and the two exclude
 * lists are arrays. Unmarshal would silently keep the old value for a mistyped
 * one -- a client sending a real boolean true instead of "true" would see its
 * change accepted and discarded.
 */
func checkShape(key string, current, incoming json.RawMessage) error {

	kind := func(raw json.RawMessage) string {
		for _, b := range raw {
			switch b {
			case ' ', '\t', '\n', '\r':
				continue
			case '[':
				return "array"
			case '"':
				return "string"
			default:
				return "scalar"
			}
		}
		return "empty"
	}

	want := kind(current)
	got := kind(incoming)
	if want == got {
		return nil
	}

	if want == "string" {
		return fmt.Errorf(
			"config: %q must be a JSON string (every value in timeshift.json is a string, so send \"true\" and \"5\", not true and 5)", key)
	}
	return fmt.Errorf("config: %q must be a JSON %s, got %s", key, want, got)
}
