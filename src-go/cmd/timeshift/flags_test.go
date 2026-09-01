package main

import (
	"strings"
	"testing"
)

/* The help and the parser must not drift.
 *
 * They already had: eight accepted aliases were undocumented and --verbose was
 * documented while doing nothing. Nothing failed when that happened, which is
 * why it happened. Generating the help from the table makes the two agree by
 * construction; this asserts it, so a future hand-written help does not
 * quietly reintroduce the problem.
 */
func TestEveryDocumentedFlagIsAccepted(t *testing.T) {
	h := help()
	for _, f := range flagTable {
		if f.help == "" {
			continue // an alias, deliberately not listed
		}
		if !strings.Contains(h, f.names[0]) {
			t.Errorf("%s is in the table but not in --help", f.names[0])
		}
		if _, ok := lookup(f.names[0]); !ok {
			t.Errorf("%s is documented but the parser does not accept it", f.names[0])
		}
	}
}

// Every alias must reach the same spec as its canonical name.
func TestAliasesResolveToTheSameFlag(t *testing.T) {
	for _, f := range flagTable {
		for _, alias := range f.names[1:] {
			got, ok := lookup(alias)
			if !ok {
				t.Errorf("alias %s is not accepted", alias)
				continue
			}
			if got.names[0] != f.names[0] {
				t.Errorf("alias %s resolves to %s, want %s", alias, got.names[0], f.names[0])
			}
			if got.arg != f.arg {
				t.Errorf("alias %s takes %q, canonical takes %q", alias, got.arg, f.arg)
			}
		}
	}
}

// No flag may be declared twice; the first would silently win.
func TestNoDuplicateFlagNames(t *testing.T) {
	seen := map[string]string{}
	for _, f := range flagTable {
		for _, n := range f.names {
			if prev, dup := seen[n]; dup {
				t.Errorf("%s is declared by both %s and %s", n, prev, f.names[0])
			}
			seen[n] = f.names[0]
		}
	}
}

/* Two modes on one command line must be refused.
 *
 * `timeshift --list --delete --snapshot x` used to DELETE: mode was a plain
 * string and the last flag to set it won, silently.
 */
func TestTwoModesAreRefused(t *testing.T) {
	_, err := parseArgs([]string{"--list", "--delete", "--snapshot", "x"})
	if err == nil {
		t.Fatal("--list --delete was accepted; one of them was silently ignored")
	}
	if !strings.Contains(err.Error(), "--list") || !strings.Contains(err.Error(), "--delete") {
		t.Errorf("the error should name both modes; got %q", err)
	}
}

// The same mode twice is not a conflict -- it is a person repeating themselves.
func TestTheSameModeTwiceIsFine(t *testing.T) {
	if _, err := parseArgs([]string{"--list", "--list"}); err != nil {
		t.Errorf("--list --list should be accepted: %v", err)
	}
}

// Aliases of one mode are the same mode, not two.
func TestModeAliasesDoNotConflict(t *testing.T) {
	if _, err := parseArgs([]string{"--list", "--list-snapshots"}); err != nil {
		t.Errorf("--list and its own alias must not conflict: %v", err)
	}
}

// A value flag at the end of the line has nothing to take, and must say so
// using the name from the table rather than a hand-written string.
func TestMissingValueNamesTheFlagAndTheValue(t *testing.T) {
	_, err := parseArgs([]string{"--target"})
	if err == nil {
		t.Fatal("--target with no value was accepted")
	}
	if !strings.Contains(err.Error(), "--target") || !strings.Contains(err.Error(), "DEVICE") {
		t.Errorf("want the flag and the value named; got %q", err)
	}
}
