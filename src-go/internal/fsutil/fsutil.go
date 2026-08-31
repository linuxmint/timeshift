// Package fsutil holds the file and formatting helpers that TeeJee.FileSystem
// provided: existence tests, atomic writes, line counting, gzip, size
// formatting and the one bit of shell quoting this tree still needs.
package fsutil

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// FileExists reports whether path exists and is not a directory, matching
// TeeJee's file_exists() -- which deliberately answers false for a directory.
func FileExists(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && !fi.IsDir()
}

// DirExists reports whether path exists and is a directory.
func DirExists(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

// IsSymlink reports whether path is a symbolic link, without following it.
func IsSymlink(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.Mode()&os.ModeSymlink != 0
}

// EnsureDir creates path and any missing parents.
func EnsureDir(path string, perm os.FileMode) error {
	if err := os.MkdirAll(path, perm); err != nil {
		return fmt.Errorf("fsutil: mkdir %s: %w", path, err)
	}
	return nil
}

// ReadString reads a whole file. A missing file yields "" and no error, because
// almost every caller in this tree treats absence as "not configured yet".
// Callers that must distinguish use os.ReadFile directly.
func ReadString(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

// WriteAtomic writes data to path via a temporary file in the same directory
// and renames it into place, so a crash cannot leave a half-written file.
func WriteAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("fsutil: mkdir %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("fsutil: temp file in %s: %w", dir, err)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("fsutil: write %s: %w", tmp.Name(), err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("fsutil: sync %s: %w", tmp.Name(), err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("fsutil: close %s: %w", tmp.Name(), err)
	}
	if err := os.Chmod(tmp.Name(), perm); err != nil {
		return fmt.Errorf("fsutil: chmod %s: %w", tmp.Name(), err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("fsutil: rename to %s: %w", path, err)
	}
	return nil
}

// LineCount counts newlines in a file.
//
// This is the snapshot's file_count: create_snapshot_with_rsync() sets it from
// file_line_count() of the rsync log, and that number becomes the progress
// denominator for the next delete. A byte scan, not a Scanner, so a pathological
// line cannot blow up.
func LineCount(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, fmt.Errorf("fsutil: open %s: %w", path, err)
	}
	defer f.Close()

	var count int64
	buf := make([]byte, 1<<20)
	for {
		n, err := f.Read(buf)
		count += int64(bytes.Count(buf[:n], []byte{'\n'}))
		if err == io.EOF {
			return count, nil
		}
		if err != nil {
			return count, fmt.Errorf("fsutil: read %s: %w", path, err)
		}
	}
}

// Gzip compresses src to src+".gz" and removes the original on success.
//
// TeeJee shelled out to gzip(1); compress/gzip is in the standard library, so
// this is one fewer process and one fewer thing to be missing from a recovery
// environment.
func Gzip(src string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("fsutil: open %s: %w", src, err)
	}
	defer in.Close()

	fi, err := in.Stat()
	if err != nil {
		return fmt.Errorf("fsutil: stat %s: %w", src, err)
	}

	dst := src + ".gz"
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, fi.Mode())
	if err != nil {
		return fmt.Errorf("fsutil: create %s: %w", dst, err)
	}

	zw := gzip.NewWriter(out)
	if _, err := io.Copy(zw, in); err != nil {
		zw.Close()
		out.Close()
		os.Remove(dst)
		return fmt.Errorf("fsutil: compress %s: %w", src, err)
	}
	if err := zw.Close(); err != nil {
		out.Close()
		os.Remove(dst)
		return fmt.Errorf("fsutil: finish %s: %w", dst, err)
	}
	if err := out.Close(); err != nil {
		os.Remove(dst)
		return fmt.Errorf("fsutil: close %s: %w", dst, err)
	}
	return os.Remove(src)
}

// ReadLines returns the lines of a file with newlines stripped. A missing file
// yields nil and no error.
func ReadLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("fsutil: open %s: %w", path, err)
	}
	defer f.Close()

	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	if err := sc.Err(); err != nil {
		return out, fmt.Errorf("fsutil: read %s: %w", path, err)
	}
	return out, nil
}

// ShellQuote wraps s in single quotes for embedding in generated shell.
//
// The ONLY place this belongs is the restore script, which must be real shell
// because it runs under chroot across a reboot. Everything else runs through
// sysexec with an argv slice and needs no quoting at all -- which is the whole
// reason TeeJee's escape_single_quote() had 100-odd call sites and this has a
// handful.
func ShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// SizeOpts controls FormatSize. The zero value is decimal units, one decimal
// place, no unit suffix and no digit grouping.
type SizeOpts struct {
	// Binary selects 1024-based units and the Ki/Mi/Gi/Ti suffixes.
	Binary bool
	// Unit pins the unit to one of "k", "m", "g", "t"; empty picks the largest
	// that leaves a value above 1.
	Unit string
	// ShowUnits appends " GB" and friends.
	ShowUnits bool
	// Decimals is the fraction width for everything above bytes.
	Decimals int
	// Group inserts thousands separators.
	//
	// Vala used printf's `'` flag, whose behaviour depends on LC_NUMERIC, and
	// both entry points call setlocale(ALL, "") -- so the Vala output is
	// grouped or not according to the user's desktop locale. Nothing here reads
	// these strings back, so the daemon fixes the choice rather than inheriting
	// that ambiguity; the CLI sets it to match what it is replacing.
	Group bool
}

// DefaultSizeOpts renders sizes the way `timeshift --list` does: decimal units,
// one decimal, a unit suffix, and thousands grouping.
//
// Grouping is not a guess. The CLI prints its minimum-free-space message as
// "Not enough disk space (< 1,000 MB)" -- MIN_FREE_SPACE is 1e9, which is NOT
// greater than unit_g, so it falls to the MB branch and comes out as 1000 with
// a separator. That comma is the Vala printf "%\'" flag under the user's
// locale, and reproducing it is what makes the output match.
func DefaultSizeOpts() SizeOpts {
	return SizeOpts{ShowUnits: true, Decimals: 1, Group: true}
}

// FormatSize renders a byte count, reproducing TeeJee's format_file_size().
//
// The comparisons are strictly greater-than, exactly as the original: 1000
// bytes formats as "1000 B", and only 1001 becomes "1.0 KB". That looks like an
// off-by-one and is not one -- it is the behaviour every existing snapshot
// listing already has.
func FormatSize(size uint64, o SizeOpts) string {
	unitK := uint64(1000)
	if o.Binary {
		unitK = 1024
	}
	unitM := unitK * unitK
	unitG := unitM * unitK
	unitT := unitG * unitK

	infix := ""
	if o.Binary {
		infix = "i"
	}

	scaled := func(div uint64, letter string) string {
		txt := strconv.FormatFloat(float64(size)/float64(div), 'f', o.Decimals, 64)
		if o.Group {
			txt = group(txt)
		}
		if o.ShowUnits {
			txt += " " + letter + infix + "B"
		}
		return txt
	}

	switch {
	case size > unitT && (o.Unit == "" || o.Unit == "t"):
		return scaled(unitT, "T")
	case size > unitG && (o.Unit == "" || o.Unit == "g"):
		return scaled(unitG, "G")
	case size > unitM && (o.Unit == "" || o.Unit == "m"):
		return scaled(unitM, "M")
	case size > unitK && (o.Unit == "" || o.Unit == "k"):
		return scaled(unitK, "K")
	default:
		txt := strconv.FormatUint(size, 10)
		if o.Group {
			txt = group(txt)
		}
		if o.ShowUnits {
			txt += " B"
		}
		return txt
	}
}

// GroupDigits renders an integer with thousands separators.
//
// Distinct from FormatSize: that scales into KB/MB/GB, which is wrong for a
// count of files. Using FormatSize with Unit "k" to get grouping divides the
// value by a thousand, which is how a progress display once reported 223,000
// entries as "223".
func GroupDigits(n int64) string {
	return group(strconv.FormatInt(n, 10))
}

// group inserts commas every three digits of the integer part.
func group(s string) string {
	intPart, frac := s, ""
	if i := strings.IndexByte(s, '.'); i >= 0 {
		intPart, frac = s[:i], s[i:]
	}
	neg := strings.HasPrefix(intPart, "-")
	if neg {
		intPart = intPart[1:]
	}
	var b strings.Builder
	for i, c := range intPart {
		if i > 0 && (len(intPart)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	out := b.String() + frac
	if neg {
		return "-" + out
	}
	return out
}
