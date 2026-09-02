package schedule

import (
	"context"
	"strings"
	"testing"
)

/* Sweeping root's own crontab.
 *
 * This deletes lines from a file the administrator also owns, so the tests are
 * mostly about what it must NOT remove. The drop-in sweep beside it can afford
 * to be blunter: those files have our name on them.
 */

type fakeCron struct {
	list     string
	listCode int
	listErr  error
	written  string
	removed  bool
	calls    [][]string
}

func (f *fakeCron) Run(_ context.Context, argv []string, stdin string) (int, string, string, error) {
	f.calls = append(f.calls, argv)
	switch {
	case len(argv) > 1 && argv[1] == "-l":
		return f.listCode, f.list, "", f.listErr
	case len(argv) > 1 && argv[1] == "-r":
		f.removed = true
		return 0, "", "", nil
	default:
		f.written = stdin
		return 0, "", "", nil
	}
}

func TestOurLinesGoAndEverythingElseStays(t *testing.T) {
	f := &fakeCron{list: strings.Join([]string{
		"# m h dom mon dow command",
		"0 * * * * /usr/bin/timeshift --backup",
		"@reboot /usr/bin/timeshift-btrfs --backup",
		"30 3 * * * /usr/local/bin/mybackup.sh",
		"0 5 * * * /usr/bin/timeshift --check",
		"",
	}, "\n")}

	n, err := RemoveLegacyCrontabEntries(f)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("removed = %d, want 2", n)
	}
	if strings.Contains(f.written, "--backup") {
		t.Errorf("a legacy line survived:\n%s", f.written)
	}
	for _, keep := range []string{"mybackup.sh", "timeshift --check", "# m h dom"} {
		if !strings.Contains(f.written, keep) {
			t.Errorf("%q was removed and should not have been:\n%s", keep, f.written)
		}
	}
	if f.removed {
		t.Error("crontab -r was used while other lines survived")
	}
}

/* A commented-out line is not a schedule. Removing it would edit something the
 * administrator deliberately left as a note. */
func TestACommentedLineIsLeftAlone(t *testing.T) {
	f := &fakeCron{list: "# 0 * * * * /usr/bin/timeshift --backup\n"}

	n, err := RemoveLegacyCrontabEntries(f)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("removed = %d, want 0", n)
	}
}

/* Both halves are required. "timeshift" alone matches somebody's wrapper;
 * "--backup" alone matches another program's flag. */
func TestOnlyLinesThatAreBothTimeshiftAndBackupMatch(t *testing.T) {
	f := &fakeCron{list: strings.Join([]string{
		"0 1 * * * /usr/bin/timeshift --list",
		"0 2 * * * /opt/other/tool --backup",
		"",
	}, "\n")}

	n, err := RemoveLegacyCrontabEntries(f)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("removed = %d, want 0 -- one of these is not ours", n)
	}
}

/* When nothing of anyone else's is left, the crontab goes entirely: writing an
 * empty one through `crontab -` is rejected by some implementations. */
func TestAnEmptyRemainderRemovesTheCrontab(t *testing.T) {
	f := &fakeCron{list: "0 * * * * /usr/bin/timeshift --backup\n"}

	if _, err := RemoveLegacyCrontabEntries(f); err != nil {
		t.Fatal(err)
	}
	if !f.removed {
		t.Error("an empty remainder should remove the crontab")
	}
	if f.written != "" {
		t.Errorf("an empty crontab was written instead: %q", f.written)
	}
}

/* No cron installed, and "no crontab for root", are both success with nothing
 * to do. A machine without cron is the normal case now. */
func TestNoCronIsNotAnError(t *testing.T) {
	for _, f := range []*fakeCron{
		{listErr: context.Canceled},
		{listCode: 1, list: "no crontab for root"},
	} {
		n, err := RemoveLegacyCrontabEntries(f)
		if err != nil {
			t.Errorf("unexpected error: %v", err)
		}
		if n != 0 {
			t.Errorf("removed = %d, want 0", n)
		}
		if f.written != "" || f.removed {
			t.Error("a crontab was modified when there was none to read")
		}
	}
}
