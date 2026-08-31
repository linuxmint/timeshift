// Package restore carries the pieces of a restore that are NOT storage: the
// marker protocol the generated scripts speak, the layout-safety checks that
// decide where files may be written, and the post-transfer system repair.
//
// The split follows the one the Vala code already has. create_restore_scripts()
// emits two scripts: sh_sync transfers the files, sh_finish fixes the system --
// chroot, GRUB, initramfs, hooks, reboot. The first belongs to whichever engine
// stored the snapshot; the second does not care which engine produced the files
// and lives here.
//
// Both scripts are real shell rather than a sequence of exec calls, and that is
// deliberate: they run under chroot and must survive the reboot boundary. It is
// the one place in the port where generated shell is still the right answer.
package restore

import (
	"strconv"
	"strings"
)

/* The marker protocol.
 *
 * The scripts announce their progress by echoing these onto stdout, where the
 * reader parses them back out of the rsync stream. Keys are untranslated ASCII
 * precisely so the match is locale-independent: the titles beside them are
 * translated, the keys never are.
 */
const (
	// PhaseMarker announces the step now running.
	PhaseMarker = "@@TS_PHASE:"

	// ReconnectMarker is transient: the link dropped and the script is waiting.
	// NOT a phase -- the checklist would gain a step that comes and goes.
	// Carries "<attempt>:<rsync exit code>".
	ReconnectMarker = "@@TS_RECONNECT:"

	// FailedMarker is terminal: rsync failed and the script is aborting BEFORE
	// the finish steps. Needed because the console path runs through a wrapper
	// that always reports success.
	FailedMarker = "@@TS_RESTORE_FAILED:"

	// WarningsMarker means rsync could not transfer everything but the rest
	// went through, and the finish steps still ran.
	WarningsMarker = "@@TS_RESTORE_WARNINGS"

	// StepFailedMarker is a step AFTER the transfer failing. Carries
	// "<phase>:<rc>". Worth distinguishing from FailedMarker: the files are
	// restored and only that step needs redoing, which is a different remedy.
	StepFailedMarker = "@@TS_STEP_FAILED:"

	// SourceOKMarker is echoed by the source-readability probe.
	SourceOKMarker = "@@TS_SOURCE_OK"
)

// Event is one thing a script announced.
type Event struct {
	Kind string

	// Phase is set for KindPhase.
	Phase string

	// Attempt and Code are set for KindReconnect.
	Attempt int
	Code    int

	// Step and StepCode are set for KindStepFailed.
	Step     string
	StepCode int
}

// Event kinds.
const (
	KindPhase      = "phase"
	KindReconnect  = "reconnect"
	KindFailed     = "failed"
	KindWarnings   = "warnings"
	KindStepFailed = "step_failed"
	KindSourceOK   = "source_ok"
)

// ParseMarker reads one line of script output.
//
// Returns ok=false for anything that is not a marker, which is the overwhelming
// majority: the same stream carries every line of rsync's itemised output.
func ParseMarker(line string) (Event, bool) {
	switch {
	case strings.HasPrefix(line, PhaseMarker):
		return Event{Kind: KindPhase, Phase: strings.TrimSpace(strings.TrimPrefix(line, PhaseMarker))}, true

	case strings.HasPrefix(line, ReconnectMarker):
		rest := strings.TrimSpace(strings.TrimPrefix(line, ReconnectMarker))
		attempt, code := splitPair(rest)
		n, _ := strconv.Atoi(attempt)
		c, _ := strconv.Atoi(code)
		return Event{Kind: KindReconnect, Attempt: n, Code: c}, true

	case strings.HasPrefix(line, FailedMarker):
		c, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, FailedMarker)))
		return Event{Kind: KindFailed, Code: c}, true

	case strings.HasPrefix(line, StepFailedMarker):
		rest := strings.TrimSpace(strings.TrimPrefix(line, StepFailedMarker))
		step, code := splitPair(rest)
		c, _ := strconv.Atoi(code)
		return Event{Kind: KindStepFailed, Step: step, StepCode: c}, true

	/* After the prefixed markers, because WarningsMarker is a prefix of
	 * nothing but is itself matched by a bare HasPrefix that would also catch
	 * a hypothetical longer marker starting with it. */
	case strings.HasPrefix(line, WarningsMarker):
		return Event{Kind: KindWarnings}, true

	case strings.HasPrefix(line, SourceOKMarker):
		return Event{Kind: KindSourceOK}, true
	}
	return Event{}, false
}

func splitPair(s string) (string, string) {
	if i := strings.LastIndex(s, ":"); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}

// Phase is one step of a restore, for the checklist.
type Phase struct {
	Key   string
	Title string
}

// Outcome is how a restore turned out.
type Outcome string

const (
	OutcomeOK       Outcome = "ok"
	OutcomeWarnings Outcome = "warnings"
	OutcomeFailed   Outcome = "failed"
)

// Tracker follows a restore by watching the marker stream.
//
// It exists so the decision "did this restore succeed" is made in one place
// from the script's own announcements, rather than from an exit code the
// console path cannot observe.
type Tracker struct {
	Phases  []Phase
	Current string
	Outcome Outcome

	// FailureCode is rsync's exit code when the transfer aborted.
	FailureCode int

	// FailedStep and FailedStepCode name a finish step that failed. The files
	// are restored in that case; only that step needs redoing.
	FailedStep     string
	FailedStepCode int

	// Reconnecting is set while the link is down, cleared when the phase is
	// re-announced.
	Reconnecting   bool
	ReconnectCount int
	ReconnectCode  int

	// SourceOK records the readability probe having passed.
	SourceOK bool
}

// NewTracker starts with the checklist the script will announce.
func NewTracker(phases []Phase) *Tracker {
	return &Tracker{Phases: phases, Outcome: OutcomeOK}
}

// Line feeds one line of script output. Returns true if it was a marker.
func (t *Tracker) Line(line string) bool {
	e, ok := ParseMarker(line)
	if !ok {
		return false
	}
	switch e.Kind {
	case KindPhase:
		t.Current = e.Phase
		// The script re-announces the phase after a successful reconnect,
		// which is what clears the banner.
		t.Reconnecting = false
	case KindReconnect:
		t.Reconnecting = true
		t.ReconnectCount = e.Attempt
		t.ReconnectCode = e.Code
	case KindWarnings:
		if t.Outcome == OutcomeOK {
			t.Outcome = OutcomeWarnings
		}
	case KindFailed:
		t.Outcome = OutcomeFailed
		t.FailureCode = e.Code
	case KindStepFailed:
		/* A failed finish step is a warning, not a failure: the transfer
		 * completed and the system is restored. Saying "failed" would send
		 * someone to re-run a restore they do not need. */
		if t.Outcome == OutcomeOK {
			t.Outcome = OutcomeWarnings
		}
		t.FailedStep = e.Step
		t.FailedStepCode = e.StepCode
	case KindSourceOK:
		t.SourceOK = true
	}
	return true
}

// Title returns a phase's human title.
func (t *Tracker) Title(key string) string {
	for _, p := range t.Phases {
		if p.Key == key {
			return p.Title
		}
	}
	return key
}
