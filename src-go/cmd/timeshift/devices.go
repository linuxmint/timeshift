package main

import (
	"context"
	"fmt"
	"io"
	"strconv"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/fsutil"
	"github.com/makeafide/timeshift/src-go/internal/textui"
)

/* `timeshift --list-devices`.
 *
 * Reproduces AppConsole.list_all_devices(): every device lsblk reports that has
 * a Linux filesystem, in lsblk's own order, with the size rendered by
 * format_file_size() and a literal "?? GB" when lsblk reported no size. The
 * columns are Num, a ">" marker, Device, Size, Type, Label, with Size and Type
 * right-aligned.
 *
 * The `include_esp` variant is used by the restore flow, not by the CLI flag,
 * so it is not here yet. */

func listDevices(ctx context.Context, w io.Writer, scanner *block.Scanner) error {
	devices, err := scanner.Scan(ctx)
	if err != nil {
		return err
	}

	var shown []*block.Device
	for _, d := range devices {
		if d.HasLinuxFilesystem() {
			shown = append(shown, d)
		}
	}

	rows := [][]string{{"Num", "", "Device", "Size", "Type", "Label"}}
	for i, d := range shown {
		rows = append(rows, []string{
			strconv.Itoa(i),
			">",
			d.NameWithParent(),
			deviceSize(d),
			d.FSType,
			d.Label,
		})
	}

	textui.Grid{
		Rows:       rows,
		RightAlign: []bool{false, false, false, true, true, false},
		HasHeader:  true,
	}.Render(w)

	return nil
}

// deviceSize renders the Size column. The "?? GB" for an unknown size is what
// the Vala CLI prints -- literally, units and all, whatever the actual scale
// would have been.
func deviceSize(d *block.Device) string {
	if d.SizeBytes <= 0 {
		return "?? GB"
	}
	return fsutil.FormatSize(uint64(d.SizeBytes), fsutil.DefaultSizeOpts())
}

// errNotRoot is returned rather than exiting, so the caller decides the code.
func requireRoot(uid int) error {
	if uid != 0 {
		return fmt.Errorf("timeshift needs superuser (root) privileges to run this application")
	}
	return nil
}
