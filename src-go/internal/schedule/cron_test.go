package schedule

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeCron(t *testing.T, root, rel, body string) string {
	t.Helper()
	full := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return full
}

func TestRemoveLegacyCron(t *testing.T) {
	root := t.TempDir()

	hourly := writeCron(t, root, "etc/cron.d/timeshift-hourly",
		"0 * * * * root timeshift --check --scripted\n")
	boot := writeCron(t, root, "etc/cron.d/timeshift-boot",
		"@reboot root sleep 10m && timeshift --create --scripted --tags B\n")

	removed, err := RemoveLegacyCron(root)
	if err != nil {
		t.Fatalf("RemoveLegacyCron: %v", err)
	}
	if len(removed) != 2 {
		t.Fatalf("removed %v, want both drop-ins", removed)
	}
	for _, p := range []string{hourly, boot} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s still exists", p)
		}
	}
}

func TestRemoveLegacyCronIsIdempotent(t *testing.T) {
	root := t.TempDir()
	if removed, err := RemoveLegacyCron(root); err != nil || len(removed) != 0 {
		t.Fatalf("on a clean system: removed %v, err %v", removed, err)
	}
}

// A file of the same name that is not ours is reported, not deleted. Removing
// somebody else's cron job because it shares a name would be very hard to trace
// back to this code.
func TestRemoveLegacyCronRefusesAForeignFile(t *testing.T) {
	root := t.TempDir()
	foreign := writeCron(t, root, "etc/cron.d/timeshift-hourly",
		"0 * * * * root /usr/local/bin/my-own-backup.sh\n")

	_, err := RemoveLegacyCron(root)
	if err == nil {
		t.Fatal("removed a file that timeshift did not write")
	}
	if !strings.Contains(err.Error(), "not written by timeshift") {
		t.Fatalf("unhelpful error: %v", err)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Fatalf("the foreign file was deleted anyway: %v", err)
	}
}

func TestRemoveLegacyCronRecognisesOlderFormats(t *testing.T) {
	root := t.TempDir()
	writeCron(t, root, "etc/cron.hourly/timeshift-hourly",
		"#!/bin/sh\ntimeshift --backup\n")

	removed, err := RemoveLegacyCron(root)
	if err != nil {
		t.Fatalf("RemoveLegacyCron: %v", err)
	}
	if len(removed) != 1 {
		t.Fatalf("removed %v, want the cron.hourly script", removed)
	}
}
