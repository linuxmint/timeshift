package main

import (
	"context"

	"github.com/makeafide/timeshift/src-go/internal/jobs"
	"github.com/makeafide/timeshift/src-go/internal/replock"
)

/* The repository write lock, as the job queue wants it.
 *
 * This exists because the queue's single worker is only half of the guarantee.
 * It serialises this daemon's jobs; it knows nothing about the Vala core, which
 * keeps its own create, delete and restore implementations for as long as both
 * are installed. During that overlap a scheduled backup and a GUI-driven one
 * would otherwise run into the same repository at the same time, each with
 * --delete and each running its own retention pass. */

type writeLock struct {
	path string
	log  logger
}

// logger is the sliver of the daemon's logger this needs, so the adapter can be
// constructed in a test without one.
type logger interface {
	Info(msg string, args ...any)
}

func (w writeLock) Acquire(ctx context.Context, what string, waiting func(string)) (func(), error) {
	announced := false

	l, err := replock.Acquire(ctx, w.path, what, func(h replock.Holder) {
		announced = true
		if w.log != nil {
			w.log.Info("waiting for another Timeshift operation to finish",
				"holder", h.String(), "wanted", what)
		}
		if waiting != nil {
			waiting(h.String())
		}
	})
	if err != nil {
		return nil, err
	}

	if announced && w.log != nil {
		w.log.Info("took the repository write lock", "what", what)
	}

	return func() {
		if err := l.Release(); err != nil && w.log != nil {
			w.log.Info("could not release the repository write lock", "err", err)
		}
	}, nil
}

var _ jobs.WriteLock = writeLock{}
