/*
 * ExcludeAppsBox.vala
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

class ExcludeAppsBox : Gtk.Box{
	private Gtk.TreeView treeview;
	private Gtk.Window parent_window;

	public ExcludeAppsBox (Gtk.Window _parent_window) {

		log_debug("ExcludeAppsBox: ExcludeAppsBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;

		var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		add(box);
		
		add_label_header(box, _("Exclude Application Settings"), true);

		//add_label(this, _("Selected items will be excluded"));

		var buffer = add_label(box, "");
		buffer.hexpand = true;

		init_exclude_summary_link(box);

		init_treeview();

		refresh_treeview();

		log_debug("ExcludeAppsBox: ExcludeAppsBox(): exit");
    }

	private void init_treeview(){

		// treeview
		treeview = new TreeView();
		treeview.get_selection().mode = SelectionMode.MULTIPLE;
		treeview.headers_visible = false;
		treeview.reorderable = true;
		treeview.set_tooltip_column(2);
		//treeview.row_activated.connect(treeview_row_activated);

		// scrolled
		var scrolled = new ScrolledWindow(null, null);
		scrolled.set_shadow_type (ShadowType.ETCHED_IN);
		scrolled.add (treeview);
		scrolled.expand = true;
		add(scrolled);

        // column
		var col = new TreeViewColumn();
		col.expand = true;
		treeview.append_column(col);
		
		// margin
		var cell_text = new CellRendererText();
		cell_text.text = "";
		col.pack_start (cell_text, false);

		// toggle
		var cell_toggle = new CellRendererToggle();
		cell_toggle.radio = false;
		cell_toggle.activatable = true;
		col.pack_start(cell_toggle, false);

		col.set_cell_data_func(cell_toggle, (cell_layout, cell, model, iter)=>{
			AppExcludeEntry entry;
			model.get (iter, 0, out entry, -1);
			((Gtk.CellRendererToggle)cell).active = entry.enabled;
		});

		cell_toggle.toggled.connect ((cell_toggle, path) => {
			var tree_path = new Gtk.TreePath.from_string (path);
			Gtk.TreeIter iter;
			var store = (Gtk.ListStore) treeview.model;
			store.get_iter(out iter, tree_path);
			
			AppExcludeEntry entry;
			store.get(iter, 0, out entry);
			entry.enabled = !cell_toggle.active;
			
			store.set(iter, 1, !cell_toggle.active);
		});

		// pattern
		cell_text = new CellRendererText ();
		col.pack_start (cell_text, false);
		
		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			
			AppExcludeEntry entry;
			model.get (iter, 0, out entry, -1);
			((Gtk.CellRendererText)cell).text = entry.name;
		});
	}

	private void init_exclude_summary_link(Gtk.Box box){
		
		var size_group = new Gtk.SizeGroup(SizeGroupMode.HORIZONTAL);
		var button = add_button(box, _("Summary"), "", size_group, null);
        button.clicked.connect(()=>{
			new ExcludeListSummaryWindow(true);
		});
	}
	
	// helpers

	public void refresh(){
		
		refresh_treeview();
	}
	
	public void refresh_treeview(){
		
		var model = new Gtk.ListStore(3, typeof(AppExcludeEntry), typeof(bool), typeof(string));
		treeview.model = model;

		foreach(var entry in App.exclude_list_apps){
			TreeIter iter;
			model.append(out iter);
			model.set (iter, 0, entry, -1);
			model.set (iter, 1, entry.enabled, -1);
			model.set (iter, 2, entry.tooltip_text(), -1);
		}
	}
}
