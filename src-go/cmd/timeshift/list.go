package main

import (
	"context"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/fsutil"
	"github.com/makeafide/timeshift/src-go/internal/textui"
)

/* `timeshift --list`.
 *
 * Reproduces AppConsole's "list-snapshots" case: the repository status block,
 * then the snapshot table, then a blank line. An empty repository prints "No
 * snapshots found" and the process exits 1 -- scripts rely on that, so it is
 * behaviour rather than an accident. */

// listSnapshots writes the status block and table, and reports whether any
// snapshot was found.
func listSnapshots(ctx context.Context, w io.Writer, repo *tsengine.Repo, deviceName, deviceUUID string) (bool, error) {
	var header strings.Builder
	if err := repo.PrintStatus(ctx, &header, deviceName, deviceUUID); err != nil {
		return false, err
	}
	io.WriteString(w, header.String())

	snapshots, err := repo.List(ctx)
	if err != nil {
		return false, err
	}
	if len(snapshots) == 0 {
		fmt.Fprintln(w, "No snapshots found")
		return false, nil
	}

	rows := [][]string{{"Num", "", "Name", "Tags", "Size", "Unique", "Description"}}
	for i, s := range snapshots {
		rows = append(rows, []string{
			strconv.Itoa(i),
			">",
			s.Name,
			tsengine.TagListShort(s.Tags),
			snapshotSize(s.SizeBytes),
			snapshotSize(s.UnsharedBytes),
			s.Description,
		})
	}

	textui.Grid{
		Rows:       rows,
		RightAlign: []bool{false, false, false, false, true, true, false},
		HasHeader:  true,
	}.Render(w)

	fmt.Fprintln(w)
	return true, nil
}

// snapshotSize renders a Size or Unique cell.
//
// -1 means the size has not been computed yet, which is different from a
// snapshot measured at zero bytes; both render empty, exactly as
// size_formatted does for an uncomputed value.
func snapshotSize(n int64) string {
	if n < 0 {
		return ""
	}
	return fsutil.FormatSize(uint64(n), fsutil.DefaultSizeOpts())
}

// locationFromConfig defers to the engine, which owns these config keys.
func locationFromConfig(c config.Config, devices []*block.Device) (engines.Location, string, string, error) {
	return tsengine.LocationFromConfig(c, devices)
}
