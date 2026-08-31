package distro

import (
	"os"
	"path/filepath"
	"testing"
)

// stage lays the captured corpus out as a root filesystem would have it.
func stage(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0755); err != nil {
		t.Fatal(err)
	}
	for name, src := range files {
		data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "distro", src))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "etc", name), data, 0644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestDetectFromRealCorpus(t *testing.T) {
	root := stage(t, map[string]string{
		"os-release":  "ubuntu-resolute.os-release",
		"lsb-release": "ubuntu-resolute.lsb-release",
	})

	got := Detect(root)
	if got.ID != "Ubuntu" && got.ID != "ubuntu" {
		t.Errorf("ID = %q", got.ID)
	}
	if got.Codename != "resolute" {
		t.Errorf("codename = %q", got.Codename)
	}
	if got.Description == "" {
		t.Error("description is empty")
	}
	if got.Type() != "debian" {
		t.Errorf("type = %q, want debian", got.Type())
	}
	// The string recorded in a snapshot's control file.
	if want := got.Description + " (resolute)"; got.FullName() != want {
		t.Errorf("FullName = %q, want %q", got.FullName(), want)
	}
}

// os-release alone must be enough: many distributions ship no lsb-release.
func TestDetectFromOSReleaseOnly(t *testing.T) {
	root := stage(t, map[string]string{"os-release": "ubuntu-resolute.os-release"})
	got := Detect(root)
	if got.ID == "" || got.Description == "" {
		t.Errorf("os-release alone was not enough: %+v", got)
	}
}

func TestDetectMissing(t *testing.T) {
	got := Detect(t.TempDir())
	if got != (Info{}) {
		t.Errorf("a root with no release files should yield nothing, got %+v", got)
	}
	if got.FullName() != "" {
		t.Errorf("FullName = %q", got.FullName())
	}
}

// Taking a root path is the point: the same code names the distribution inside
// a snapshot, which is how the listing shows where each came from.
func TestDetectUnderSnapshotRoot(t *testing.T) {
	root := t.TempDir()
	payload := filepath.Join(root, "snapshot", "localhost")
	os.MkdirAll(filepath.Join(payload, "etc"), 0755)
	os.WriteFile(filepath.Join(payload, "etc", "os-release"),
		[]byte("ID=debian\nVERSION_ID=\"13\"\nPRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nVERSION_CODENAME=trixie\n"), 0644)

	got := Detect(payload)
	if got.ID != "debian" || got.Codename != "trixie" {
		t.Errorf("got %+v", got)
	}
	if got.Type() != "debian" {
		t.Errorf("type = %q", got.Type())
	}
}

func TestTypeBuckets(t *testing.T) {
	cases := map[string]string{
		"ubuntu": "debian", "debian": "debian", "linuxmint": "debian",
		"fedora": "redhat", "rocky": "redhat", "centos": "redhat",
		"arch": "arch", "manjaro": "arch",
		"gentoo": "", "": "",
	}
	for id, want := range cases {
		if got := (Info{ID: id}).Type(); got != want {
			t.Errorf("Type(%q) = %q, want %q", id, got, want)
		}
	}
}

func TestQuoteStripping(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "etc"), 0755)
	os.WriteFile(filepath.Join(root, "etc", "os-release"),
		[]byte("# a comment\nID='single'\nPRETTY_NAME=\"Double Quoted\"\nVERSION_ID=bare\n\n"), 0644)

	got := Detect(root)
	if got.ID != "single" {
		t.Errorf("single quotes not stripped: %q", got.ID)
	}
	if got.Description != "Double Quoted" {
		t.Errorf("double quotes not stripped: %q", got.Description)
	}
	if got.Release != "bare" {
		t.Errorf("unquoted value = %q", got.Release)
	}
}
