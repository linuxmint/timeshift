package timeshift

import (
	"context"
	"fmt"
	"path"
	"sort"
)

/* Tag and description edits.
 *
 * Retention works by removing tags, and taking a scheduled level can be as
 * cheap as adding one. Both are a read-modify-write of the control file, which
 * is the only place a snapshot's tags live.
 *
 * The read matters. Writing a control file built from a listing would discard
 * every field the listing does not carry -- the size figures, the btrfs
 * subvolume table -- and a control file is what makes a directory a snapshot at
 * all. So the file on the repository is always the starting point, even though
 * the caller has just listed it.
 */

// SetTags replaces a snapshot's tag list.
func (r *Repo) SetTags(ctx context.Context, name string, tags []string) error {
	return r.editControl(ctx, name, func(c *ControlFile) {
		c.Tags = normaliseTags(tags)
	})
}

// AddTag adds one tag, and is a no-op if it is already there.
func (r *Repo) AddTag(ctx context.Context, name, tag string) error {
	return r.editControl(ctx, name, func(c *ControlFile) {
		for _, t := range c.Tags {
			if t == tag {
				return
			}
		}
		c.Tags = normaliseTags(append(c.Tags, tag))
	})
}

// SetDescription replaces the comment.
func (r *Repo) SetDescription(ctx context.Context, name, description string) error {
	return r.editControl(ctx, name, func(c *ControlFile) { c.Description = description })
}

// SetMarkedForDeletion writes the delete marker file, or removes it.
//
// This is a sidecar file rather than a control-file field because the original
// used one, and a client that marks a snapshot on a repository an older
// Timeshift also reads has to be understood by it.
func (r *Repo) SetMarkedForDeletion(ctx context.Context, name string, marked bool) error {
	marker := path.Join(r.SnapshotsPath(), name, "delete")
	if marked {
		return r.writeFile(ctx, marker, nil)
	}
	// Absent is the normal case, so removing a marker that is not there is not
	// a failure.
	if !r.Backend.FileExists(ctx, marker) {
		return nil
	}
	return r.Backend.Remove(ctx, marker)
}

func (r *Repo) editControl(ctx context.Context, name string, edit func(*ControlFile)) error {
	p := path.Join(r.SnapshotsPath(), name, "info.json")

	raw, err := r.Backend.ReadFile(ctx, p)
	if err != nil {
		return fmt.Errorf("read control file for %s: %w", name, err)
	}
	c, err := ParseControlFile(raw)
	if err != nil {
		return fmt.Errorf("parse control file for %s: %w", name, err)
	}

	edit(c)

	if err := r.writeFile(ctx, p, c.Marshal()); err != nil {
		return fmt.Errorf("write control file for %s: %w", name, err)
	}
	return nil
}

/* Tag order.
 *
 * The tag list is rendered into the control file and into the CLI's one-letter
 * column, and the original emits them in retention order rather than in
 * whatever order they were added. Sorting here keeps a snapshot's tags stable
 * across an edit, so a file does not change just because the same tags were
 * written in a different sequence.
 */
var tagOrder = map[string]int{
	"ondemand": 0,
	"boot":     1,
	"hourly":   2,
	"daily":    3,
	"weekly":   4,
	"monthly":  5,
}

func normaliseTags(tags []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, t := range tags {
		if t == "" || seen[t] {
			continue
		}
		seen[t] = true
		out = append(out, t)
	}
	sort.SliceStable(out, func(i, j int) bool {
		oi, iok := tagOrder[out[i]]
		oj, jok := tagOrder[out[j]]
		if iok && jok {
			return oi < oj
		}
		// An unknown tag keeps its place after the known ones rather than
		// being dropped: it is somebody's data, not a parse error.
		if iok != jok {
			return iok
		}
		return out[i] < out[j]
	})
	return out
}
