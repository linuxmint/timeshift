/*
 * ExcludeBox.vala
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

/* Row object for the exclude list. GTK4 list widgets bind to GObjects rather
 * than tree-model columns; include/exclude is still derived from the "+ "
 * prefix, exactly as the tree model did. */
public class ExcludePatternRow : GLib.Object {

	public string pattern { get; set; }

	public ExcludePatternRow(string _pattern){
		pattern = _pattern;
	}

	public bool is_include(){
		return pattern.has_prefix("+ ");
	}

	public string display_text(){
		return pattern.has_prefix("+ ") ? pattern[2:pattern.length] : pattern;
	}
}

class ExcludeBox : Gtk.Box{
	
	private Gtk.ColumnView treeview;
	private GLib.ListStore exclude_model;
	private Gtk.MultiSelection exclude_selection;
	private Gtk.Window parent_window;
	private UsersBox users_box;
	private Gtk.Label lbl_message;
	
	public ExcludeBox (Gtk.Window _parent_window) {

		log_debug("ExcludeBox: ExcludeBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		Ui.add_title(this, _("Include / Exclude Patterns"));

		lbl_message = Ui.add_dim_label(this, _("Click a pattern to edit it"));

		init_treeview();

		init_actions();
		
		refresh_treeview();

		log_debug("ExcludeBox: ExcludeBox(): exit");
    }

    public void set_users_box(UsersBox _users_box){
		
		users_box = _users_box;
	}

    private void init_treeview(){

		/* GTK4 deprecates Gtk.TreeView. This is a Gtk.ColumnView over a
		 * GLib.ListStore of ExcludePatternRow: two radio columns for the
		 * include/exclude choice and an editable pattern column. */

		exclude_model = new GLib.ListStore(typeof(ExcludePatternRow));
		exclude_selection = new Gtk.MultiSelection(exclude_model);

		treeview = new Gtk.ColumnView(exclude_selection);
		treeview.show_column_separators = false;
		treeview.set_tooltip_text(_("Click to edit."));

		// scrolled
		Ui.add_boxed_list(this, treeview);

		treeview.append_column(make_toggle_column(_("Include"), true));
		treeview.append_column(make_toggle_column(_("Exclude"), false));
		treeview.append_column(make_pattern_column());
	}

	private Gtk.ColumnViewColumn make_toggle_column(string title, bool for_include){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var chk = new Gtk.CheckButton();
			chk.halign = Gtk.Align.CENTER;

			chk.toggled.connect(() => {
				if (!chk.active){ return; }

				var row = chk.get_data<ExcludePatternRow>("row");
				if (row == null){ return; }

				if (for_include){
					if (!row.pattern.has_prefix("+ ")){
						row.pattern = "+ %s".printf(row.pattern);
					}
				}
				else{
					if (row.pattern.has_prefix("+ ")){
						row.pattern = row.pattern[2:row.pattern.length];
					}
				}

				save_changes();
			});

			list_item.set_child(chk);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var chk = (Gtk.CheckButton) list_item.get_child();
			var row = (ExcludePatternRow) list_item.get_item();

			chk.steal_data<ExcludePatternRow>("row");
			chk.active = for_include ? row.is_include() : !row.is_include();
			chk.set_data<ExcludePatternRow>("row", row);
		});

		var col = new Gtk.ColumnViewColumn(title, factory);
		return col;
	}

	private Gtk.ColumnViewColumn make_pattern_column(){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);

			var img = new Gtk.Image();
			img.pixel_size = 16;
			hbox.append(img);

			var editable = new Gtk.EditableLabel("");
			editable.hexpand = true;
			hbox.append(editable);

			/* commit when editing ends, mirroring CellRendererText::edited */
			editable.notify["editing"].connect(() => {

				if (editable.editing){ return; }

				var row = editable.get_data<ExcludePatternRow>("row");
				if (row == null){ return; }

				string pattern = editable.text;

				if (row.is_include()){
					if (!pattern.has_prefix("+ ")){
						pattern = "+ %s".printf(pattern);
					}
				}
				else if (pattern.has_prefix("+ ")){
					pattern = pattern[2:pattern.length];
				}

				if (row.pattern != pattern){
					row.pattern = pattern;
					save_changes();
				}
			});

			list_item.set_child(hbox);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var hbox = (Gtk.Box) list_item.get_child();
			var img = (Gtk.Image) hbox.get_first_child();
			var editable = (Gtk.EditableLabel) img.get_next_sibling();
			var row = (ExcludePatternRow) list_item.get_item();

			editable.steal_data<ExcludePatternRow>("row");
			img.set_from_icon_name(row.is_include() ? "list-add-symbolic" : "list-remove-symbolic");
			editable.text = row.display_text();
			editable.set_data<ExcludePatternRow>("row", row);
		});

		var col = new Gtk.ColumnViewColumn(_("Pattern"), factory);
		col.expand = true;
		return col;
	}

	private void init_actions(){


		var hbox = Ui.add_button_row(this, Gtk.Align.START);

		var size_group = new Gtk.SizeGroup(SizeGroupMode.HORIZONTAL);
		var button = add_button(hbox, _("Add"), _("Add custom pattern"), size_group, null);
		
        button.clicked.connect(()=>{

			string pattern = gtk_inputbox(
						_("Exclude Pattern"),
						_("Enter the pattern to exclude (Ex: *.mp3, *.bak)"),
						parent_window, false);

			if ((pattern != null) && (pattern.strip().length > 0)){
				treeview_add_item(treeview, pattern); // don't strip
				Main.first_snapshot_size = 0; //re-calculate
			}
			
			save_changes();
		});
		
		button = add_button(hbox, _("Add Files"), _("Add files"), size_group, null);
		
        button.clicked.connect(()=>{
			add_files_clicked();
		});

		button = add_button(hbox, _("Add Folders"), _("Add directories"), size_group, null);
		
        button.clicked.connect(()=>{
			add_folder_clicked();
		});

		// for exclude only - Including contents without including directory is not logical
		/*size_group = null;
		button = add_button(hbox, _("Add Contents"),
			_("Add directory contents"), ref size_group, null);
		button.clicked.connect(()=>{
			add_folder_contents_clicked();
		});*/

		button = add_button(hbox, _("Remove"), "", size_group, null);
        button.clicked.connect(()=>{
			remove_clicked();
		});

		button = add_button(hbox, _("Summary"), "", size_group, null);
        button.clicked.connect(()=>{
			save_changes();
			new ExcludeListSummaryWindow(false);
		});
	}
	
	// actions
	
    private void remove_clicked(){
		
		var selected = new Gee.ArrayList<string>();

		for (uint i = 0; i < exclude_model.get_n_items(); i++) {
			if (exclude_selection.is_selected(i)){
				var row = (ExcludePatternRow) exclude_model.get_item(i);
				selected.add(row.pattern);
			}
		}

		if (selected.size == 0){
			string title = _("Items Not Selected");
			string message = _("Select the items to be removed from the list");
			gtk_messagebox(title, message, parent_window, true);
			return;
		}

		foreach(var pattern in selected){
			App.exclude_list_user.remove(pattern);
			log_debug("removed item: %s".printf(pattern));
			Main.first_snapshot_size = 0; //re-calculate
		}
		
		refresh_treeview();

		save_changes();
	}

	private void add_files_clicked(){

		var list = browse_files();

		if (list.length() > 0){
			foreach(string item in list){

				string pattern = item;

				if (!App.exclude_list_user.contains(pattern)){
					App.exclude_list_user.add(pattern);
					treeview_add_item(treeview, pattern);
					log_debug("file: %s".printf(pattern));
					Main.first_snapshot_size = 0; //re-calculate
				}
				else{
					log_debug("exclude_list_user contains: %s".printf(pattern));
				}
			}
		}

		save_changes();
	}

	private void add_folder_clicked(){

		var list = browse_folder();

		if (list.length() > 0){
			foreach(string item in list){

				string pattern = item;

				if (!pattern.has_suffix("/***")){
					pattern = "%s/***".printf(pattern);
				}
				
				/*
				NOTE:
				
				+ <dir>/*** will include the directory along with the contents
				+ <dir>/ will include only the directory without the contents
				
				<dir>/*** will exclude the directory along with the contents
				<dir>/ is same as exclude <dir>/***
				*/
				
				if (!App.exclude_list_user.contains(pattern)){
					App.exclude_list_user.add(pattern);
					treeview_add_item(treeview, pattern);
					log_debug("folder: %s".printf(pattern));
					Main.first_snapshot_size = 0; //re-calculate
				}
				else{
					log_debug("exclude_list_user contains: %s".printf(pattern));
				}
			}
		}

		save_changes();
	}

	private SList<string> browse_files(){

		var list = new SList<string>();
		
		/* GTK4 replaces Gtk.FileChooserDialog with the async Gtk.FileDialog.
		 * Callers here are synchronous, so block on a nested main loop. */

		var dialog = new Gtk.FileDialog();
		dialog.set_title(_("Select file(s)"));
		dialog.set_modal(true);

		var loop = new GLib.MainLoop();

		dialog.open_multiple.begin(parent_window, null, (obj, res) => {
			try {
				var files = dialog.open_multiple.end(res);
				if (files != null){
					for (uint i = 0; i < files.get_n_items(); i++){
						var file = (GLib.File) files.get_item(i);
						if (file.get_path() != null){
							list.append(file.get_path());
						}
					}
				}
			}
			catch (Error e){
				log_debug(e.message);
			}
			loop.quit();
		});

		loop.run();

	 	return (owned) list;
	}

	private SList<string> browse_folder(){

		var list = new SList<string>();
		
		var dialog = new Gtk.FileDialog();
		dialog.set_title(_("Select directory"));
		dialog.set_modal(true);

		var loop = new GLib.MainLoop();

		dialog.select_folder.begin(parent_window, null, (obj, res) => {
			try {
				var file = dialog.select_folder.end(res);
				if ((file != null) && (file.get_path() != null)){
					list.append(file.get_path());
				}
			}
			catch (Error e){
				log_debug(e.message);
			}
			loop.quit();
		});

		loop.run();

	 	return (owned) list;
	}

	// helpers

	public void refresh_treeview(){

		exclude_model.remove_all();

		foreach(string pattern in App.exclude_list_user){
			treeview_add_item(treeview, pattern);
		}
	}

	private void treeview_add_item(Gtk.ColumnView treeview, string pattern){

		log_debug("treeview_add_item(): %s".printf(pattern));

		exclude_model.append(new ExcludePatternRow(pattern));
	}

	public void save_changes(){

		App.exclude_list_user.clear();

		// add include patterns from the list
		for (uint i = 0; i < exclude_model.get_n_items(); i++) {

			var row = (ExcludePatternRow) exclude_model.get_item(i);
			string pattern = row.pattern;

			if (!App.exclude_list_user.contains(pattern)
				&& !App.exclude_list_default.contains(pattern)
				&& !App.exclude_list_home.contains(pattern)){

				App.exclude_list_user.add(pattern);
			}
		}

		log_debug("save_changes(): exclude_list_user:");
		foreach(var item in App.exclude_list_user){
			log_debug(item);
		}
		log_debug("");

		users_box.refresh();
	}
}
