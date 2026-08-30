/*
 * TaskProgressBox.vala
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
 */

using TeeJee.GtkHelper;

/* The progress page shared by backup, restore, delete, estimate and log
 * parsing: a header, a spinner with the current message and time remaining,
 * a progress bar, a status line, and (optionally) the rsync counts panel.
 *
 * The polling loops that drive it live in the pages that own the task; they
 * write straight to the public labels. */

public class TaskProgressBox : Gtk.Box {

	public Gtk.Label lbl_header;
	public Gtk.Spinner spinner;
	public Gtk.Label lbl_msg;
	public Gtk.Label lbl_remaining;
	public Gtk.ProgressBar progressbar;
	public Gtk.Label lbl_status;

	// counts panel
	private Gtk.Box counts_box;
	public Gtk.Label lbl_unchanged;
	public Gtk.Label lbl_created;
	public Gtk.Label lbl_deleted;
	public Gtk.Label lbl_modified;
	public Gtk.Label lbl_checksum;
	public Gtk.Label lbl_size;
	public Gtk.Label lbl_timestamp;
	public Gtk.Label lbl_permissions;
	public Gtk.Label lbl_owner;
	public Gtk.Label lbl_group;

	public TaskProgressBox(string header, bool show_counts){

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM);

		lbl_header = Ui.add_title(this, header);

		// message row ---------------------------------------------------

		var hbox_status = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		append(hbox_status);

		spinner = new Gtk.Spinner();
		spinner.spinning = true;
		hbox_status.append(spinner);

		lbl_msg = Ui.add_body(hbox_status, _("Preparing..."), false);
		lbl_msg.hexpand = true;
		lbl_msg.ellipsize = Pango.EllipsizeMode.END;

		lbl_remaining = Ui.add_dim_label(hbox_status, "");
		lbl_remaining.wrap = false;

		progressbar = new Gtk.ProgressBar();
		append(progressbar);

		lbl_status = Ui.add_caption(this, "");
		lbl_status.wrap = false;
		lbl_status.ellipsize = Pango.EllipsizeMode.MIDDLE;

		// counts ------------------------------------------------------------

		counts_box = Ui.add_card(this);
		counts_box.margin_top = Ui.Spacing.SM;
		counts_box.visible = show_counts;

		if (show_counts){
			build_counts(counts_box);
		}
	}

	private void build_counts(Gtk.Box box){

		var grid = new Gtk.Grid();
		grid.column_spacing = Ui.Spacing.LG;
		grid.row_spacing = Ui.Spacing.XS / 2;
		box.append(grid);

		int row = 0;

		var heading = new Gtk.Label(_("File and directory counts:"));
		heading.add_css_class("ts-heading");
		heading.xalign = (float) 0.0;
		grid.attach(heading, 0, row++, 2, 1);

		lbl_unchanged = add_count_row(grid, row++, _("No Change"));
		lbl_created = add_count_row(grid, row++, _("Created"));
		lbl_deleted = add_count_row(grid, row++, _("Deleted"));
		lbl_modified = add_count_row(grid, row++, _("Changed"));

		heading = new Gtk.Label(_("Changed items:"));
		heading.add_css_class("ts-heading");
		heading.xalign = (float) 0.0;
		heading.margin_top = Ui.Spacing.SM;
		grid.attach(heading, 0, row++, 2, 1);

		lbl_checksum = add_count_row(grid, row++, _("Checksum"));
		lbl_size = add_count_row(grid, row++, _("Size"));
		lbl_timestamp = add_count_row(grid, row++, _("Timestamp"));
		lbl_permissions = add_count_row(grid, row++, _("Permissions"));
		lbl_owner = add_count_row(grid, row++, _("Owner"));
		lbl_group = add_count_row(grid, row++, _("Group"));
	}

	private Gtk.Label add_count_row(Gtk.Grid grid, int row, string caption){

		var lbl_caption = new Gtk.Label(caption);
		lbl_caption.add_css_class("ts-dim");
		lbl_caption.xalign = (float) 0.0;
		grid.attach(lbl_caption, 0, row, 1, 1);

		var lbl_value = new Gtk.Label("");
		lbl_value.xalign = (float) 1.0;
		lbl_value.add_css_class("numeric");
		grid.attach(lbl_value, 1, row, 1, 1);

		// a value made insensitive dims its caption too
		lbl_value.notify["sensitive"].connect(() => {
			lbl_caption.sensitive = lbl_value.sensitive;
		});

		return lbl_value;
	}

	public void set_header(string text){
		lbl_header.label = text;
	}

	public void set_paused(bool paused){

		spinner.spinning = !paused;
		lbl_msg.label = paused ? _("Paused") : "";
	}

	public void set_counts_visible(bool visible){
		counts_box.visible = visible;
	}
}
