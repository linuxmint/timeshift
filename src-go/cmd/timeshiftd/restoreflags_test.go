package main

import (
	"encoding/json"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* The two post-transfer steps the wizard offers as checkboxes.
 *
 * They were hard-coded true in the daemon, which made "Update initramfs" and
 * "Update GRUB menu" decorative: the page offered them and then did both
 * whatever was chosen. They are pointers on the wire because a plain bool
 * cannot tell "the caller said no" from "an older caller could not say", and
 * those need opposite answers -- the second must default to true or a restored
 * system boots with an initramfs naming devices that no longer exist.
 */
func TestOptionalRestoreFlagsDistinguishUnsetFromFalse(t *testing.T) {
	cases := []struct {
		name       string
		body       string
		wantInitrd bool
		wantMenu   bool
	}{
		{"an older client sends neither", `{"snapshot":"s"}`, true, true},
		{"explicitly off", `{"snapshot":"s","update_initramfs":false,"update_grub_menu":false}`, false, false},
		{"explicitly on", `{"snapshot":"s","update_initramfs":true,"update_grub_menu":true}`, true, true},
		{"one of each", `{"snapshot":"s","update_initramfs":false,"update_grub_menu":true}`, false, true},
	}

	for _, c := range cases {
		var in ipc.RestoreParams
		if err := json.Unmarshal([]byte(c.body), &in); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := boolOr(in.UpdateInitramfs, true); got != c.wantInitrd {
			t.Errorf("%s: initramfs = %v, want %v", c.name, got, c.wantInitrd)
		}
		if got := boolOr(in.UpdateGrubMenu, true); got != c.wantMenu {
			t.Errorf("%s: grub menu = %v, want %v", c.name, got, c.wantMenu)
		}
	}
}

/* An omitted flag must stay omitted on the wire, so a daemon reading it can
 * still tell it was never set. omitempty on a pointer drops nil and keeps a
 * pointer to false, which is the behaviour the distinction depends on. */
func TestAnUnsetFlagIsNotSentAsFalse(t *testing.T) {
	off := false

	unset, err := json.Marshal(ipc.RestoreParams{Snapshot: "s"})
	if err != nil {
		t.Fatal(err)
	}
	if string(unset) != `{"snapshot":"s"}` {
		t.Errorf("an unset flag appeared on the wire: %s", unset)
	}

	explicit, err := json.Marshal(ipc.RestoreParams{Snapshot: "s", UpdateInitramfs: &off})
	if err != nil {
		t.Fatal(err)
	}
	if string(explicit) != `{"snapshot":"s","update_initramfs":false}` {
		t.Errorf("an explicit false was dropped: %s", explicit)
	}
}
