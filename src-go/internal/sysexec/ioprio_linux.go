//go:build linux

package sysexec

import "syscall"

/* The Vala tree bound ioprio_set() by hand in src/vapi/ioprio.vapi because
 * glibc exposes no wrapper for it. Same situation here: neither syscall nor
 * os/exec offers I/O priority, and this tree takes no third-party dependencies,
 * so the raw syscall it is.
 *
 * From include/uapi/linux/ioprio.h. Stable ABI; these numbers have not moved
 * since 2.6.13. */
const (
	ioprioWhoProcess = 1
	ioprioClassIdle  = 3
	ioprioClassShift = 13
)

// setIOIdle puts pid in the idle I/O scheduling class, so it only gets disk
// time nothing else wants. A backup that makes the desktop stutter is a backup
// people turn off.
func setIOIdle(pid int) error {
	prio := ioprioClassIdle << ioprioClassShift
	_, _, errno := syscall.Syscall(
		syscall.SYS_IOPRIO_SET, uintptr(ioprioWhoProcess), uintptr(pid), uintptr(prio))
	if errno != 0 {
		return errno
	}
	return nil
}
