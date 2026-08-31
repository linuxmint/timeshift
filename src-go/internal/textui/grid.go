// Package textui renders the console tables `timeshift --list` and
// `--list-devices` print.
//
// The layout is not a design choice, it is a compatibility requirement: scripts
// parse this output, and the differential test that proves the Go CLI is a
// drop-in replacement compares it byte for byte against the Vala one. So this
// reproduces AppConsole.print_grid() exactly, including the parts that look
// like mistakes.
package textui

import (
	"io"
	"strings"
)

// Separator is the rule printed under a header row.
//
// It is a fixed 78 characters -- `string.nfill(78, '-')` -- and does NOT track
// the width of the table, so a wide table overhangs it and a narrow one falls
// short. That is what the Vala CLI prints today.
const Separator = 78

// Grid is a table of cells, the first row being the header.
type Grid struct {
	// Rows is the cell text. Every row must have the same length.
	Rows [][]string

	// RightAlign marks columns that are right-aligned, one entry per column.
	RightAlign []bool

	// HasHeader prints the separator rule under the first row.
	HasHeader bool
}

// Render writes the grid.
//
// Column width is the widest cell in that column, header included, and every
// cell is followed by two spaces -- including the last one on a line, which is
// why the Vala output has trailing whitespace on every row. Reproduced
// deliberately: stripping it would make a byte-for-byte diff against the
// existing CLI fail on every single line.
func (g Grid) Render(w io.Writer) {
	if len(g.Rows) == 0 {
		return
	}
	cols := len(g.Rows[0])

	widths := make([]int, cols)
	for _, row := range g.Rows {
		for c := 0; c < cols && c < len(row); c++ {
			if n := len(row[c]); n > widths[c] {
				widths[c] = n
			}
		}
	}

	var b strings.Builder
	for i, row := range g.Rows {
		for c := 0; c < cols; c++ {
			cell := ""
			if c < len(row) {
				cell = row[c]
			}
			right := c < len(g.RightAlign) && g.RightAlign[c]
			b.WriteString(pad(cell, widths[c], right))
			b.WriteString("  ")
		}
		b.WriteString("\n")

		if g.HasHeader && i == 0 {
			b.WriteString(strings.Repeat("-", Separator))
			b.WriteString("\n")
		}
	}
	io.WriteString(w, b.String())
}

// pad implements printf's "%-Ns" and "%Ns".
//
// Vala asks for "%+Ns" when right-aligning. The + flag is only defined for
// numeric conversions and glibc ignores it for %s, so it behaves as "%Ns" --
// right-aligned. A cell wider than the column is never truncated.
func pad(s string, width int, right bool) string {
	if len(s) >= width {
		return s
	}
	fill := strings.Repeat(" ", width-len(s))
	if right {
		return fill + s
	}
	return s + fill
}
