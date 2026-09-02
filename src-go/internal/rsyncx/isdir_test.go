package rsyncx

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

/* rsync's itemise type column, the second character, says what the thing IS.
 *
 * It was matched by every one of these regexes and then dropped on the floor,
 * so a client could not tell a directory from a file. That matters in exactly
 * one place and it is not cosmetic: the log view hides directories on a dry
 * run, because a restore lists every parent directory of every changed file,
 * and on a real system they outnumber the changes several times over.
 */
func TestTheItemiseTypeColumnIsReported(t *testing.T) {
	const p = "2026/08/31 12:00:00 [1234] "
	cases := []struct {
		line  string
		isDir bool
		what  string
	}{
		{p + "cd+++++++++ etc/skel/", true, "a created directory"},
		{p + ">f+++++++++ etc/hosts", false, "a created file"},
		{p + ".d          var/log/", true, "an unchanged directory"},
		{p + ".f          etc/passwd", false, "an unchanged file"},
		{p + ".d...p..... var/spool/", true, "a directory with changed permissions"},
		{p + ">f..t...... etc/fstab", false, "a file with a changed timestamp"},
		{p + "cL+++++++++ usr/bin/link", false, "a symlink is not a directory"},
	}

	for _, c := range cases {
		got, ok := ParseLogLine(c.line)
		if !ok {
			t.Errorf("%s did not parse: %q", c.what, c.line)
			continue
		}
		if got.IsDir != c.isDir {
			t.Errorf("%s: IsDir = %v, want %v (%q)", c.what, got.IsDir, c.isDir, c.line)
		}
	}
}

/* A deleted path has no type column at all -- rsync's "*deleting" line carries
 * only the name -- so it can only report false. That is not a regression: the
 * Vala parser stat'ed the path to find out, and a deleted file is already gone.
 */
func TestADeletedPathReportsNoType(t *testing.T) {
	got, ok := ParseLogLine("2026/08/31 12:00:00 [1234] *deleting   var/tmp/old")
	if !ok {
		t.Fatal("the deleting line did not parse")
	}
	if got.IsDir {
		t.Error("a deleted path cannot be known to be a directory")
	}
}

/* Against the captured corpus rather than hand-written lines: these are real
 * rsync passes, and they contain directory entries in all three itemising
 * forms. If the type column stops being read, this stops finding any. */
func TestTheCapturedCorpusYieldsDirectories(t *testing.T) {
	const prefix = "2026/08/31 12:00:00 [1234] "

	matches, err := filepath.Glob("../../testdata/rsync/*.itemise")
	if err != nil || len(matches) == 0 {
		t.Skipf("corpus not found: %v", err)
	}

	dirs, files := 0, 0
	for _, name := range matches {
		f, err := os.Open(name)
		if err != nil {
			t.Fatal(err)
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimRight(sc.Text(), "\r")
			if line == "" {
				continue
			}
			// The corpus is console itemise output; the log form adds a prefix.
			c, ok := ParseLogLine(prefix + line)
			if !ok {
				continue
			}
			if c.IsDir {
				dirs++
			} else {
				files++
			}
		}
		f.Close()
	}

	if dirs == 0 {
		t.Error("no directories found in the corpus -- the type column is being dropped")
	}
	if files == 0 {
		t.Error("no files found in the corpus -- the parse is not working at all")
	}
	t.Logf("corpus: %d directories, %d files", dirs, files)
}
