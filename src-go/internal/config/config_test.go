package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This is the point of the package: a file the Vala build actually wrote must
// come back out of Marshal unchanged. Anything else means the GUI and the
// daemon disagree about the file they share.
//
// Only live-ssh.json qualifies. default.json is the hand-maintained seed from
// files/timeshift.json and deliberately does NOT round-trip: it carries
// do_first_run "true" (save_app_config always writes "false", because reaching
// a save means the first run is over) and the pre-split include_btrfs_home key.
// Its contract is that it parses, which TestDefaultsMatchSeedFile covers.
func TestGoldenRoundTrip(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "config", "live-ssh.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}

	extra, err := UnknownKeys(raw)
	if err != nil {
		t.Fatalf("scan keys: %v", err)
	}
	if len(extra) > 0 {
		t.Fatalf("golden carries keys Marshal would drop: %v", extra)
	}

	c, err := Unmarshal(raw)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	got := Marshal(c)
	if string(got) != string(raw) {
		t.Errorf("round trip changed the file\n%s", firstDiff(string(raw), string(got)))
	}
}

// The seed file's shape is not round-trippable, but every key in it must still
// be one Marshal knows, or a fresh install would lose settings on first save.
func TestSeedFileHasNoUnknownKeys(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "config", "default.json"))
	if err != nil {
		t.Fatal(err)
	}
	extra, err := UnknownKeys(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(extra) > 0 {
		t.Errorf("files/timeshift.json carries keys Marshal would drop: %v", extra)
	}
}

// default.json is the seed for a fresh install, so Unmarshal of it must equal
// Defaults() apart from the keys that file genuinely sets.
func TestDefaultsMatchSeedFile(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "config", "default.json"))
	if err != nil {
		t.Fatal(err)
	}
	c, err := Unmarshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	d := Defaults()

	if c.CountMonthly != d.CountMonthly || c.CountWeekly != d.CountWeekly ||
		c.CountDaily != d.CountDaily || c.CountHourly != d.CountHourly ||
		c.CountBoot != d.CountBoot {
		t.Errorf("retention defaults drifted from files/timeshift.json: got %d/%d/%d/%d/%d",
			c.CountMonthly, c.CountWeekly, c.CountDaily, c.CountHourly, c.CountBoot)
	}
	if c.BackupLocationType != "local" {
		t.Errorf("seed location type = %q, want local", c.BackupLocationType)
	}
	if !c.DoFirstRun {
		t.Error("seed file must set do_first_run true")
	}
	if !c.StopCronEmails {
		t.Error("seed file must set stop_cron_emails true")
	}
	if c.Engine != EngineDefault {
		t.Errorf("engine = %q, want %q for a file with no engine key", c.Engine, EngineDefault)
	}
}

// Every value on disk is a string. A real JSON bool or number is not something
// any Timeshift wrote, and must not silently become the value.
func TestValuesAreStringsNotNatives(t *testing.T) {
	c, err := Unmarshal([]byte(`{"btrfs_mode": true, "count_daily": 9}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.BtrfsMode {
		t.Error("a native JSON true was accepted for btrfs_mode; only the string \"true\" counts")
	}
	if c.CountDaily != Defaults().CountDaily {
		t.Errorf("a native JSON number was accepted for count_daily: got %d", c.CountDaily)
	}
}

func TestMarshalIsJSONGlibShaped(t *testing.T) {
	out := string(Marshal(Defaults()))

	if strings.Contains(out, `":`) {
		t.Error(`separator is "key": -- json-glib writes "key" : `)
	}
	if !strings.Contains(out, `"backup_device_uuid" : ""`) {
		t.Error("missing json-glib key/value spacing")
	}
	if !strings.Contains(out, `"exclude" : []`) {
		t.Error("an empty array must collapse to [] on one line")
	}
	if strings.HasSuffix(out, "\n") {
		t.Error("json-glib writes no trailing newline")
	}
	if !strings.HasSuffix(out, "\n}") {
		t.Error("file must end with a newline then the closing brace")
	}
}

func TestArrayIndentation(t *testing.T) {
	c := Defaults()
	c.Exclude = []string{"+ /home/u/**", "/root/**"}
	out := string(Marshal(c))
	want := "  \"exclude\" : [\n    \"+ /home/u/**\",\n    \"/root/**\"\n  ],"
	if !strings.Contains(out, want) {
		t.Errorf("array layout wrong.\ngot:\n%s\nwant to contain:\n%s", out, want)
	}
}

// btrfs is a local-filesystem operation; it cannot run against a remote
// repository. Vala forces this on load at Main.vala:4753 and again at :4908.
func TestRemoteForcesBtrfsOff(t *testing.T) {
	c, err := Unmarshal([]byte(
		`{"backup_location_type":"ssh","btrfs_mode":"true","backup_ssh_url":"u@h:/p"}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.BtrfsMode {
		t.Error("btrfs_mode must be forced off for an ssh location")
	}
}

// The pre-split key still has to be honoured, or upgrading loses the setting.
func TestLegacyIncludeBtrfsHomeKey(t *testing.T) {
	c, err := Unmarshal([]byte(`{"include_btrfs_home":"true"}`))
	if err != nil {
		t.Fatal(err)
	}
	if !c.IncludeBtrfsHomeForBackup {
		t.Error("legacy include_btrfs_home must map to the backup flag")
	}
}

// pause_snapshots holds either unix seconds or a boot id, and is absent when
// nothing is paused. Both forms must survive untouched.
func TestPauseSnapshotsRoundTrip(t *testing.T) {
	for _, v := range []string{"1756400000", "b3f1c2d4-5e6f-7081-92a3-b4c5d6e7f809"} {
		c := Defaults()
		c.PauseSnapshots = v
		out := Marshal(c)
		back, err := Unmarshal(out)
		if err != nil {
			t.Fatal(err)
		}
		if back.PauseSnapshots != v {
			t.Errorf("pause_snapshots %q became %q", v, back.PauseSnapshots)
		}
	}
	if strings.Contains(string(Marshal(Defaults())), "pause_snapshots") {
		t.Error("pause_snapshots must be absent when not paused")
	}
}

// A config that has never named an engine must keep working, and must not gain
// the key on the next save.
func TestEngineDefaultsAndStaysAbsent(t *testing.T) {
	c := Defaults()
	if strings.Contains(string(Marshal(c)), "engine") {
		t.Error("the default engine must not be written out")
	}
	c.Engine = "borg"
	if !strings.Contains(string(Marshal(c)), `"engine" : "borg"`) {
		t.Error("a non-default engine must be written")
	}
}

func TestSaveIsAtomicAndReadable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "timeshift.json")

	c := Defaults()
	c.BackupSSHURL = "user@host:/srv/snap"
	c.BackupLocationType = "ssh"
	if err := Save(path, c); err != nil {
		t.Fatal(err)
	}

	back, found, err := Load(path)
	if err != nil || !found {
		t.Fatalf("reload: found=%v err=%v", found, err)
	}
	if back.BackupSSHURL != c.BackupSSHURL {
		t.Errorf("url = %q, want %q", back.BackupSSHURL, c.BackupSSHURL)
	}

	// No temp files left behind.
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("Save left %d files in the directory, want 1", len(entries))
	}
}

func TestLoadMissingFileIsFirstRun(t *testing.T) {
	c, found, err := Load(filepath.Join(t.TempDir(), "absent.json"))
	if err != nil {
		t.Fatalf("a missing config must not be an error: %v", err)
	}
	if found {
		t.Error("found must be false for a missing file")
	}
	if c.CountDaily != Defaults().CountDaily {
		t.Error("a missing config must yield Defaults()")
	}
}

// firstDiff points at the first differing line rather than dumping both files.
func firstDiff(want, got string) string {
	w := strings.Split(want, "\n")
	g := strings.Split(got, "\n")
	for i := 0; i < len(w) || i < len(g); i++ {
		var wl, gl string
		if i < len(w) {
			wl = w[i]
		}
		if i < len(g) {
			gl = g[i]
		}
		if wl != gl {
			return "line " + itoa(i+1) + ":\n  want: " + wl + "\n  got:  " + gl
		}
	}
	return "(files differ only in trailing bytes)"
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
