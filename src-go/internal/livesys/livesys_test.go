package livesys

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIsLive(t *testing.T) {
	// The real command lines this project emits, from
	// src-recovery/lib/timeshift-recovery/common.sh, plus a real installed one.
	cases := []struct {
		name    string
		cmdline string
		want    bool
	}{
		{
			name:    "recovery partition target",
			cmdline: "BOOT_IMAGE=/casper/vmlinuz boot=casper live-media=/dev/disk/by-uuid/1234 live-media-path=casper quiet splash",
			want:    true,
		},
		{
			name:    "recovery root target, iso-scan plus toram",
			cmdline: "BOOT_IMAGE=/casper/vmlinuz boot=casper iso-scan/filename=/timeshift-recovery/recovery.img toram quiet splash",
			want:    true,
		},
		{
			name:    "debian live-boot",
			cmdline: "BOOT_IMAGE=/live/vmlinuz boot=live components quiet splash",
			want:    true,
		},
		{
			name:    "an ordinary installed system",
			cmdline: "BOOT_IMAGE=/vmlinuz-6.14.0-33-generic root=UUID=deadbeef ro quiet splash vt.handoff=7",
			want:    false,
		},
		{
			name: "a root filesystem that merely mentions casper",
			// The point: "casper" alone is not the marker, "boot=casper" is.
			// An installed system with a partition label or a path containing
			// the word must not be mistaken for a live one.
			cmdline: "BOOT_IMAGE=/vmlinuz root=UUID=beef ro rootflags=subvol=@casper-backup quiet",
			want:    false,
		},
		{
			name:    "empty",
			cmdline: "",
			want:    false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := IsLive(c.cmdline); got != c.want {
				t.Errorf("IsLive(%q) = %v, want %v", c.cmdline, got, c.want)
			}
		})
	}
}

func TestDetectorReadsTheFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cmdline")
	if err := os.WriteFile(path, []byte("boot=casper quiet splash\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !(Detector{Path: path}).Live() {
		t.Fatal("a cmdline naming boot=casper must read as live")
	}

	if err := os.WriteFile(path, []byte("root=UUID=x ro quiet\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if (Detector{Path: path}).Live() {
		t.Fatal("an ordinary cmdline must not read as live")
	}
}

/* An unreadable command line must read as NOT live.
 *
 * This is the fail-open direction and it is deliberate: refusing every
 * scheduled snapshot on a healthy machine because a file could not be read is
 * a worse failure than the one being guarded against.
 */
func TestUnreadableCmdlineIsNotLive(t *testing.T) {
	if (Detector{Path: filepath.Join(t.TempDir(), "absent")}).Live() {
		t.Fatal("an unreadable cmdline must not be reported as live")
	}
}
