package ipc

import "syscall"

func dup2(from, to int) error { return syscall.Dup3(from, to, 0) }
