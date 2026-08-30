/*
 * RestoreProgressBox.vala
 *
 * Copyright 2012-2018 Tony George <teejeetech@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301, USA.
 *
 *
 */

using Gtk;
using Gee;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

/* What a restore looks like while it runs.
 *
 * Everything a restore can say about itself in one view: which step is running,
 * how far along the file sync is, which file is being written right now, what
 * has changed so far, and - behind a disclosure - the raw script output that
 * used to be the whole screen.
 *
 * The same class serves both restore paths. In `hero` form it fills the
 * full-screen window that takes over when the running system is being
 * overwritten; in compact form it is the wizard's progress page. It is a view
 * only: RestoreBox owns the thread and the polling loop and writes into it. */

public class RestoreProgressBox : TaskProgressBox {

	public Banner banner;
	public PhaseList phases;
	public LogPane log_pane;

	private bool hero_mode;

	private StatusCard? card = null;
	private StatTile? tile_created = null;
	private StatTile? tile_modified = null;
	private StatTile? tile_deleted = null;

	private string active_phase = "";

	public RestoreProgressBox(string header, bool hero){

		// the ten-row counts grid belongs to the compact page; the
		// full-screen view says the same thing in three tiles
		base(header, !hero);

		hero_mode = hero;

		// warning strip ------------------------------------------------

		banner = new Banner();
		prepend(banner);

		phases = new PhaseList();
		log_pane = new LogPane();

		if (hero_mode){

			lbl_header.visible = false; // the card carries the title

			card = new StatusCard();
			card.set_shield(IconManager.SHIELD_HIGH);
			card.set_title(header);
			append(card);
			reorder_child_after(card, banner);

			append(phases);
			phases.margin_top = Ui.Spacing.SM;

			var tiles = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.MD);
			tiles.homogeneous = true;
			tiles.margin_top = Ui.Spacing.SM;
			append(tiles);

			tile_created = new StatTile(_("Created"));
			tiles.append(tile_created);

			tile_modified = new StatTile(_("Changed"));
			tiles.append(tile_modified);

			tile_deleted = new StatTile(_("Deleted"));
			tiles.append(tile_deleted);

			append(log_pane);
			log_pane.margin_top = Ui.Spacing.SM;

			/* The checklist reads as a continuation of the progress bar, so
			 * it goes directly under the current-file line. */
			reorder_child_after(phases, lbl_status);
		}
		else {
			/* The full-screen window scrolls the whole page itself, but the
			 * wizard's notebook does not: without a scroller here the
			 * checklist and the counts push the Restore window past 900 px
			 * tall and off a short screen. */
			var inner = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.SM);

			var scroller = new Gtk.ScrolledWindow();
			scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
			scroller.has_frame = false;
			scroller.hexpand = true;
			scroller.vexpand = true;
			scroller.min_content_height = 160;
			scroller.margin_top = Ui.Spacing.SM;
			scroller.set_child(inner);
			append(scroller);

			// the counts card comes from the base class; it moves in too
			remove(counts_box);
			counts_box.margin_top = 0;

			inner.append(phases);
			inner.append(counts_box);
			inner.append(log_pane);
		}
	}

	// content ----------------------------------------------------------

	public void set_banner(string text, Gtk.MessageType type){
		banner.set_message(text, type);
	}

	public void set_subtitle(string text){

		if (card != null){
			card.set_subtitle(text);
		}
	}

	/* Rebuilds the checklist. Called once per run, before the work starts,
	 * with the steps that will actually be taken. */
	public void set_phases(Gee.ArrayList<RestorePhase> list){

		phases.clear();
		active_phase = "";

		foreach(var phase in list){
			phases.add_phase(phase.key, phase.title);
		}
	}

	/* Advances the checklist, and mirrors the step's name into the hero
	 * subtitle. Cheap to call every tick: unchanged keys do nothing. */
	public void set_phase(string key){

		if ((key.length == 0) || (key == active_phase)){ return; }
		if (!phases.has_phase(key)){ return; }

		active_phase = key;
		phases.set_active(key);
	}

	public void complete_phases(){
		phases.complete_all();
	}

	public void append_log(string[] lines){
		log_pane.append_lines(lines);
	}

	public void clear_log(){
		log_pane.clear();
	}

	/* One place that turns an RsyncTask's counters into labels, so the
	 * compact grid and the hero tiles can never disagree. */
	public void update_counts(RsyncTask task){

		lbl_unchanged.label = count_text(task.count_unchanged);
		lbl_created.label = count_text(task.count_created);
		lbl_deleted.label = count_text(task.count_deleted);
		lbl_modified.label = count_text(task.count_modified);
		lbl_checksum.label = count_text(task.count_checksum);
		lbl_size.label = count_text(task.count_size);
		lbl_timestamp.label = count_text(task.count_timestamp);
		lbl_permissions.label = count_text(task.count_permissions);
		lbl_owner.label = count_text(task.count_owner);
		lbl_group.label = count_text(task.count_group);

		if (tile_created != null){
			tile_created.set_value(count_text(task.count_created));
			tile_modified.set_value(count_text(task.count_modified));
			tile_deleted.set_value(count_text(task.count_deleted));
		}
	}

	/* Grouped digits, without the varargs mismatch that "%'d" on an int64
	 * gives everywhere else in the app: on the 64-bit targets this ships to,
	 * long is the width of gint64. */
	private static string count_text(int64 value){
		return "%'ld".printf((long) value);
	}
}
