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
		BackupLocationType: "local",
		DoFirstRun:         true,
		StopCronEmails:     true,
		CountMonthly:       2,
		CountWeekly:        3,
		CountDaily:         5,
		CountHourly:        6,
		CountBoot:          5,
		DateFormat:         DefaultDateFormat,
		ThemeMode:          "system",
		ThemeAccent:        "system",
		Exclude:            []string{},
		ExcludeApps:        []string{},
		Engine:             EngineDefault,
		present:            map[string]bool{},
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
