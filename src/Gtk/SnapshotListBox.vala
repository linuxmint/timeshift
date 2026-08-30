/*
 * SnapshotListBox.vala
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

public enum SnapshotField {
	DATE,
	SYSTEM,
	TAGS,
	SIZE,
	UNSHARED
}

class SnapshotListBox : Gtk.Box{
	
	public Gtk.ColumnView treeview;
	private GLib.ListStore snapshot_model;
	private Gtk.MultiSelection snapshot_selection;
    private Gtk.ColumnViewColumn col_date;
    private Gtk.ColumnViewColumn col_tags;
    private Gtk.ColumnViewColumn col_size;
    private Gtk.ColumnViewColumn col_unshared;
    private Gtk.ColumnViewColumn col_system;
    private Gtk.ColumnViewColumn col_desc;
	private int treeview_sort_column_index = 0;
	private bool treeview_sort_column_desc = true;

	private Gtk.PopoverMenu menu_snapshots;
	private GLib.SimpleAction mi_browse;
	private GLib.SimpleAction mi_remove;
	private GLib.SimpleAction mi_mark;
	private GLib.SimpleAction mi_view_log_create;
	private GLib.SimpleAction mi_view_log_restore;
	
	private Gtk.Window parent_window;
	private bool context_menu_enabled = true;

	public signal void delete_selected();
	public signal void mark_selected();
	public signal void browse_selected();
	public signal void view_snapshot_log(bool show_restore_log);

	public SnapshotListBox (Gtk.Window _parent_window) {

		log_debug("SnapshotListBox: SnapshotListBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		init_treeview();
		
		init_list_view_context_menu();

		log_debug("SnapshotListBox: SnapshotListBox(): exit");
    }

    private void init_treeview(){

		/* GTK4 deprecates Gtk.TreeView. Snapshot is already a GObject, so it
		 * goes straight into a GLib.ListStore; sorting is now done natively by
		 * the Gtk.ColumnView via per-column sorters rather than by re-sorting
		 * and rebuilding the model on every header click. */

		snapshot_model = new GLib.ListStore(typeof(Snapshot));

		treeview = new Gtk.ColumnView(null);
		treeview.show_column_separators = false;

		Ui.add_boxed_list(this, treeview);

		col_date = make_snapshot_column(_("Snapshot"), SnapshotField.DATE);
		col_date.set_sorter(new Gtk.CustomSorter((a, b) => {
			return ((Snapshot) a).date.compare(((Snapshot) b).date);
		}));
		treeview.append_column(col_date);

		col_system = make_snapshot_column(_("System"), SnapshotField.SYSTEM);
		col_system.set_sorter(new Gtk.CustomSorter((a, b) => {
			return strcmp(((Snapshot) a).sys_distro, ((Snapshot) b).sys_distro);
		}));
		treeview.append_column(col_system);

		col_tags = make_snapshot_column(_("Tags"), SnapshotField.TAGS);
		col_tags.set_sorter(new Gtk.CustomSorter((a, b) => {
			return strcmp(((Snapshot) a).taglist, ((Snapshot) b).taglist);
		}));
		treeview.append_column(col_tags);

		col_size = make_snapshot_column(_("Size"), SnapshotField.SIZE);
		col_size.set_sorter(new Gtk.CustomSorter((a, b) => {
			int64 d = ((Snapshot) a).size_bytes - ((Snapshot) b).size_bytes;
			return (d < 0) ? -1 : ((d > 0) ? 1 : 0);
		}));
		treeview.append_column(col_size);

		col_unshared = make_snapshot_column(_("Unshared"), SnapshotField.UNSHARED);
		col_unshared.set_sorter(new Gtk.CustomSorter((a, b) => {
			int64 d = ((Snapshot) a).size_unshared_bytes - ((Snapshot) b).size_unshared_bytes;
			return (d < 0) ? -1 : ((d > 0) ? 1 : 0);
		}));
		treeview.append_column(col_unshared);

		col_desc = make_description_column();
		treeview.append_column(col_desc);

		/* sorting is applied to the model, so it must be built from the
		 * column view's own sorter */
		var sort_model = new Gtk.SortListModel(snapshot_model, treeview.sorter);
		snapshot_selection = new Gtk.MultiSelection(sort_model);
		treeview.model = snapshot_selection;

		// default: newest first, as before
		treeview.sort_by_column(col_date, Gtk.SortType.DESCENDING);
	}

	private string snapshot_field_text(Snapshot bak, SnapshotField field){

		switch (field){
		case SnapshotField.DATE:
			// Note: Avoid AM/PM as it may be hidden due to locale settings
			return bak.date_formatted;
		case SnapshotField.SYSTEM:
			var txt = bak.sys_distro;
			if ("LinuxMint" in txt) {
				txt = txt.replace("LinuxMint", "Linux Mint");
			}
			return txt;
		case SnapshotField.TAGS:
			return bak.taglist_short;
		case SnapshotField.SIZE:
			return bak.size_formatted;
		case SnapshotField.UNSHARED:
			return bak.size_unshared_formatted;
		}

		return "";
	}

	private string snapshot_tooltip(Snapshot bak, SnapshotField field){

		switch (field){

		case SnapshotField.DATE:
		case SnapshotField.SYSTEM:

			string txt = "";

			if (App.btrfs_mode){

				txt += "%s: %d\n".printf(_("Subvolumes"), bak.subvolumes.values.size);

				foreach(var subvol in bak.subvolumes_sorted){
					if (txt.length > 0) { txt += "\n"; }
					txt += "%s".printf(subvol.path);
				}
			}
			else if (App.repo.backend.is_remote){
				txt = "%s:%s".printf(App.repo.backend.display_name, bak.path);
			}
			else{
				txt = bak.path;
			}

			return txt;

		case SnapshotField.TAGS:

			return "%s\n\nO \t%s\nB \t%s\nH \t%s\nD \t%s\nW \t%s\nM \t%s".printf(
				_("Snapshot Levels"),
				_("On demand (manual)"),
				_("Boot"),
				_("Hourly"),
				_("Daily"),
				_("Weekly"),
				_("Monthly"));
		}

		return "";
	}

	private Gtk.ColumnViewColumn make_snapshot_column(string title, SnapshotField field){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);

			if (field == SnapshotField.DATE){
				var img = new Gtk.Image();
				img.pixel_size = 16;
				img.set_from_icon_name("x-office-calendar-symbolic");
				img.add_css_class("ts-dim");
				hbox.append(img);
			}

			var lbl = new Gtk.Label("");

			/* Ellipsizing makes a label report a minimum width near zero, so a
			 * column with no fixed_width measures only as wide as its header.
			 * Only the distro string is long enough to want it. */
			if (field == SnapshotField.SYSTEM){
				lbl.ellipsize = Pango.EllipsizeMode.END;
			}

			lbl.xalign = ((field == SnapshotField.SIZE) || (field == SnapshotField.UNSHARED))
				? (float) 1.0 : (float) 0.0;
			lbl.hexpand = true;
			hbox.append(lbl);

			list_item.set_child(hbox);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var hbox = (Gtk.Box) list_item.get_child();
			var bak = (Snapshot) list_item.get_item();

			Gtk.Widget? child = hbox.get_first_child();
			Gtk.Label? lbl = child as Gtk.Label;
			if (lbl == null){ lbl = (Gtk.Label) child.get_next_sibling(); }

			string txt = snapshot_field_text(bak, field);

			lbl.label = txt;
			Ui.set_text_style(lbl, bak.live ? "ts-heading" : "ts-body");
			lbl.sensitive = !bak.marked_for_deletion;

			string tip = snapshot_tooltip(bak, field);
			if (tip.length > 0){
				hbox.set_tooltip_text(tip);
			}
		});

		var col = new Gtk.ColumnViewColumn(title, factory);
		col.resizable = true;

		if (field == SnapshotField.DATE){ col.fixed_width = 200; }
		else if (field == SnapshotField.SYSTEM){ col.fixed_width = 200; }

		return col;
	}

	private Gtk.ColumnViewColumn make_description_column(){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var editable = new Gtk.EditableLabel("");
			editable.hexpand = true;
			editable.set_tooltip_text(
				_("Comments (double-click to edit)") + "\n"
				+ _("Snapshots with comments are not auto-deleted"));

			/* commit when editing ends, mirroring CellRendererText::edited */
			editable.notify["editing"].connect(() => {

				if (editable.editing){ return; }

				var bak = editable.get_data<Snapshot>("snapshot");
				if (bak == null){ return; }

				if (bak.description != editable.text){
					bak.description = editable.text;
					bak.update_control_file();
				}
			});

			list_item.set_child(editable);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var editable = (Gtk.EditableLabel) list_item.get_child();
			var bak = (Snapshot) list_item.get_item();

			editable.steal_data<Snapshot>("snapshot");
			editable.text = bak.live
				? "[" + _("LIVE") + "] " + bak.description : bak.description;
			editable.sensitive = !bak.marked_for_deletion;
			editable.set_data<Snapshot>("snapshot", bak);
		});

		var col = new Gtk.ColumnViewColumn(_("Comments"), factory);
		col.expand = true;
		col.resizable = true;
		return col;
	}

	private void init_list_view_context_menu(){

		/* GTK4 removes Gtk.Menu/Gtk.ImageMenuItem. The context menu is a
		 * Gtk.PopoverMenu over a GMenu model, with entries backed by GActions.
		 * Menu-item icons are not part of the GMenu model and are dropped. */

		var actions = new GLib.SimpleActionGroup();
		var model = new GLib.Menu();

		mi_browse = add_snapshot_action(actions, "browse", () => { browse_selected(); });
		model.append(_("Browse Files"), "snap.browse");

		mi_view_log_create = add_snapshot_action(actions, "view-log-create", () => { view_snapshot_log(false); });
		model.append(_("View Rsync Log for Create"), "snap.view-log-create");

		mi_view_log_restore = add_snapshot_action(actions, "view-log-restore", () => { view_snapshot_log(true); });
		model.append(_("View Rsync Log for Restore"), "snap.view-log-restore");

		mi_remove = add_snapshot_action(actions, "remove", () => { delete_selected(); });
		model.append(_("Delete"), "snap.remove");

		mi_mark = add_snapshot_action(actions, "mark", () => { mark_selected(); });
		model.append(_("Mark/Unmark for Deletion"), "snap.mark");

		this.insert_action_group("snap", actions);

		menu_snapshots = new Gtk.PopoverMenu.from_model(model);

		/* Parent the popover to this box rather than the treeview: a
		 * Gtk.TreeView owns internal CSS nodes and set_parent() on it trips
		 * gtk_css_node_insert_after(). */
		menu_snapshots.set_parent(this);
		menu_snapshots.set_has_arrow(false);

		// right-click
		var gesture = new Gtk.GestureClick();
		gesture.button = Gdk.BUTTON_SECONDARY;
		gesture.pressed.connect((n_press, x, y) => {
			if (!context_menu_enabled){ return; }
			/* GTK 4.12 deprecates translate_coordinates in favour of compute_point */
			Graphene.Point dest;
			var src = Graphene.Point(){ x = (float) x, y = (float) y };
			if (!treeview.compute_point(this, src, out dest)){
				dest = src;
			}
			menu_snapshots_popup((int) dest.x, (int) dest.y);
		});
		treeview.add_controller(gesture);

		// keyboard: Menu key and Shift+F10
		var keys = new Gtk.EventControllerKey();
		keys.key_pressed.connect((keyval, keycode, state) => {
			if (!context_menu_enabled){ return false; }
			if ((keyval == Gdk.Key.Menu)
				|| ((keyval == Gdk.Key.F10) && ((state & Gdk.ModifierType.SHIFT_MASK) != 0))){
				menu_snapshots_popup(0, 0);
				return true;
			}
			return false;
		});
		treeview.add_controller(keys);
	}

	private GLib.SimpleAction add_snapshot_action(GLib.SimpleActionGroup actions, string name, owned MenuActionFunc callback){

		var action = new GLib.SimpleAction(name, null);
		action.activate.connect(() => { callback(); });
		actions.add_action(action);
		return action;
	}

	// signals
	
	// renderers
	
	private void menu_snapshots_popup (int x, int y) {

		var selected = selected_snapshots();

		mi_remove.set_enabled(selected.size > 0);
		mi_mark.set_enabled(selected.size > 0);
		mi_view_log_create.set_enabled(!App.btrfs_mode);
		mi_view_log_restore.set_enabled(!App.btrfs_mode);

		if (!App.btrfs_mode){

			if (selected.size > 0){

				// Browsing a snapshot queued for deletion is misleading - it
				// may vanish under the file manager.
				mi_browse.set_enabled(!selected[0].marked_for_deletion);

				// a remote log cannot be probed with a local stat; assume it
				// exists and let the fetch report a real failure
				if (App.repo.backend.is_remote){
					mi_view_log_restore.set_enabled(true);
				}
				else {
					mi_view_log_restore.set_enabled(file_exists(selected[0].rsync_restore_log_file)
						|| file_exists(selected[0].rsync_restore_changes_log_file));
				}
			}
		}

		Gdk.Rectangle rect = { x, y, 1, 1 };
		menu_snapshots.set_pointing_to(rect);
		menu_snapshots.popup();
	}

	// actions
	
	public void refresh(){

		snapshot_model.remove_all();

		if ((App.repo == null) || !App.repo.available()){
			return;
		}

		App.repo.load_snapshots();

		foreach(Snapshot bak in App.repo.snapshots) {
			snapshot_model.append(bak);
		}

		col_size.visible = !App.btrfs_mode || App.btrfs_qgroups_enabled;
		col_unshared.visible = !App.btrfs_mode || App.btrfs_qgroups_enabled;
	}

	/* Disables the right-click / Menu-key menu. GTK4 event controllers are
	 * owned by the widget, so the handlers stay connected and check the flag. */
	public void hide_context_menu(){

		context_menu_enabled = false;

		if (menu_snapshots != null){
			menu_snapshots.popdown();
		}
	}

	public Gee.ArrayList<Snapshot> selected_snapshots(){

		var list = new Gee.ArrayList<Snapshot>();

		if (snapshot_selection == null){ return list; }

		for (uint i = 0; i < snapshot_selection.get_n_items(); i++) {
			if (snapshot_selection.is_selected(i)){
				list.add((Snapshot) snapshot_selection.get_item(i));
			}
		}

		return list;
	}
}
