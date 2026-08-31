//go:build linux

package ipc

import "syscall"

// syscallUmask sets the process umask and returns the previous value.
//
// Wrapped so the call site reads clearly, and isolated in a build-tagged file
// because umask is not portable. It is process-wide, so it is set immediately
// before net.Listen and restored immediately after -- the window in which
// another goroutine could create a file with the wrong mode is that one call.
func syscallUmask(mask int) int { return syscall.Umask(mask) }
