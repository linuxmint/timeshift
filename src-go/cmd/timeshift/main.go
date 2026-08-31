// Command timeshift is the Timeshift command-line client.
//
// It will replace the Vala AppConsole, keeping every flag it accepts, and will
// reach the core by connecting to timeshiftd's unix socket rather than doing
// the work in-process. That is what lets a snapshot started by
// apt-snapshot-guard be watched from the GUI at the same time.
//
// The IPC client lands with the socket, in a later phase. This binary is not
// installed yet -- the Vala `timeshift` is still the one on PATH.
//
// NOTE for whoever wires this into the man pages: docs/man/meson.build runs
// help2man against the installed binary, so --help must keep its shape (a
// version line, then Usage:, then Options:) or the package build breaks.
package main

import (
	"fmt"
	"os"

	"github.com/makeafide/timeshift/src-go/internal/config"
)

// version is stamped by the build; see src-go/go-build.sh.
var version = "dev"

func main() {
	args := os.Args[1:]

	for _, a := range args {
		switch a {
		case "--help", "-h":
			fmt.Print(help())
			return
		case "--version":
			fmt.Printf("timeshift %s\n", version)
			return
		}
	}

	if len(args) == 0 {
		fmt.Print(help())
		return
	}

	fmt.Fprintf(os.Stderr,
		"timeshift: the Go client is not wired up yet; use the installed timeshift.\n")
	os.Exit(2)
}

func help() string {
	return fmt.Sprintf(`
Timeshift %s

Syntax: timeshift [options]

Options:

  --help, -h        Show all options
  --version         Print version number
  --config PATH     Path to timeshift.json (default %s)
`, version, config.SystemPath)
}
