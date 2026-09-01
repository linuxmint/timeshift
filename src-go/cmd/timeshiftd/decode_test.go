package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* Malformed parameters must be REFUSED, not silently zero-valued.
 *
 * Discarding the unmarshal error does not make a request fail -- it makes it
 * succeed, about something other than what was asked. These two are the cases
 * where that had consequences.
 */
func TestMalformedParamsAreRefused(t *testing.T) {
	d := testDaemon(t)
	ctx := context.Background()

	// `dry_run` is a bool; a string is the kind of thing a hand-written client
	// or a version-skewed one sends.
	bad := json.RawMessage(`{"device_uuid":"x","dry_run":"yes-please"}`)

	cases := []struct {
		name string
		call func() (any, error)
		why  string
	}{
		{
			name: "repo.select",
			call: func() (any, error) { return d.repoSelect(ctx, nil, bad) },
			why:  "a malformed body left DryRun false, so a rehearsal WROTE the config",
		},
		{
			name: "snapshot.create",
			call: func() (any, error) {
				return d.snapshotCreate(ctx, nil,
					json.RawMessage(`{"attach_existing":"true"}`))
			},
			why: "a malformed body left AttachExisting false, so racing apt frontends took two snapshots",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := c.call()
			if err == nil {
				t.Fatalf("malformed parameters were accepted: %s", c.why)
			}
			var e *ipc.Error
			if !errors.As(err, &e) || e.Code != ipc.CodeBadRequest {
				t.Fatalf("want %s, got %v", ipc.CodeBadRequest, err)
			}
			if !strings.Contains(err.Error(), "malformed") {
				t.Errorf("the error should say what is wrong; got %q", err)
			}
		})
	}
}

// Handlers that take no parameters must still accept an empty body.
func TestEmptyParamsAreNotAnError(t *testing.T) {
	d := testDaemon(t)
	ctx := context.Background()

	if _, err := d.jobsList(ctx, nil, nil); err != nil {
		t.Fatalf("nil params must be fine for a no-parameter method: %v", err)
	}
	if _, err := d.jobsList(ctx, nil, json.RawMessage("")); err != nil {
		t.Fatalf("empty params must be fine: %v", err)
	}
}
