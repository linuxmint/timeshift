/*
 * RsyncLogBox.vala
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

public class RsyncLogBox : Gtk.Box {

	private Gtk.Box vbox_progress;
	private Gtk.Box vbox_list;

	private Gtk.TreeView treeview;
	private Gtk.TreeModelFilter treefilter;
	private Gtk.ComboBox cmb_filter;
	private Gtk.Box hbox_filter;
	private Gtk.Entry txt_pattern;

	private Gtk.TreeViewColumn col_name;
	private Gtk.TreeViewColumn col_status;
	
	private string name_filter = "";
	private string status_filter = "";

	public Gtk.Label lbl_header;
	public Gtk.Label lbl_header_progress;
	private Gtk.Spinner spinner;
	public Gtk.Label lbl_msg;
	public Gtk.Label lbl_status;
	public Gtk.Label lbl_remaining;
	public Gtk.ProgressBar progressbar;
	
	//private uint tmr_task = 0;
	private uint tmr_init = 0;
	private bool thread_is_running = false;

	private string rsync_log_file;
	private Gee.ArrayList<FileItem> loglist;

	private Gtk.Window window;

	public RsyncLogBox(Gtk.Window _window) {
		
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around

		this.margin = 6;
		
		log_debug("RsyncLogBox: RsyncLogBox()");

		window	= _window;
	}

	public void open_log(string _rsync_log_file){

		rsync_log_file = _rsync_log_file;

		// header
		if (App.dry_run){
			lbl_header = add_label_header(this, _("Confirm Actions"), true);
			lbl_header.set_no_show_all(true);
		}

		create_progressbar();

		create_filters();
		
		create_treeview();

		cmb_filter.changed.connect(() => {
			
			status_filter = gtk_combobox_get_value(cmb_filter, 0, "");
			log_debug("combo_changed(): filter=%s".printf(status_filter));

			Timeout.add(100, ()=>{

				hbox_filter.sensitive = false;
				treeview.sensitive = false;
				
				log_debug("refilter(): start");
				treefilter.refilter();
				log_debug("refilter(): end");

				hbox_filter.sensitive = true;
				treeview.sensitive = true;

				return false;
			});
		});

		if (is_restore_log){
			col_name.title = _("File (system)");
		}
		else{
			col_name.title = _("File (snapshot)");
		}

		show_all();

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("RsyncLogWindow: RsyncLogWindow(): exit");
	}

	private bool is_restore_log {
		get {
			return file_basename(rsync_log_file).contains("restore");
		}
	}

	public bool init_delayed(){

		log_debug("init_delayed()");
		
		if (tmr_init > 0){
			Source.remove(tmr_init);
			tmr_init = 0;
		}

		//gtk_set_busy(true, window);

		parse_log_file();

		if (App.dry_run){
			lbl_header.set_no_show_all(false);
			lbl_header.show();
		}

		//gtk_set_busy(false, window);

		log_debug("init_delayed(): finish");
		
		return false;
	}

	private void parse_log_file(){

		try {
			thread_is_running = true;
			new Thread<void>.try ("log-file-parser", () => {parse_log_file_thread();});
		}
		catch (Error e) {
			log_error (e.message);
		}

		while (thread_is_running){
			
			double fraction = (App.task.prg_count * 1.0) / App.task.prg_count_total;
			
			if (fraction < 0.99){
				progressbar.fraction = fraction;
			}
			
			lbl_msg.label = _("Read %'d of %'d lines...").printf(
				App.task.prg_count, App.task.prg_count_total);
				
			sleep(500);
			gtk_do_events();
		}
		
		lbl_msg.label = _("Populating list...");
		gtk_do_events();
		treeview_refresh();

		vbox_progress.hide();
		gtk_do_events();

		vbox_list.no_show_all = false;
		vbox_list.show_all();

		hbox_filter.no_show_all = false;
		hbox_filter.show_all();
	}
	
	private void parse_log_file_thread(){
		
		App.task = new RsyncTask();
		loglist = App.task.parse_log(rsync_log_file);
		thread_is_running = false;
	}

	public bool is_running{
		get {
			return thread_is_running;
		}
	}
	
	// create ui -----------------------------------------

	private void create_progressbar(){
		
		vbox_progress = new Gtk.Box(Orientation.VERTICAL, 6);
		this.add(vbox_progress);
		
		lbl_header_progress = add_label_header(vbox_progress, _("Parsing log file..."), true);
		
		var hbox_status = new Gtk.Box(Orientation.HORIZONTAL, 6);
		vbox_progress.add(hbox_status);
		
		spinner = new Gtk.Spinner();
		spinner.active = true;
		hbox_status.add(spinner);
		
		//lbl_msg
		lbl_msg = add_label(hbox_status, _("Preparing..."));
		lbl_msg.hexpand = true;
		lbl_msg.ellipsize = Pango.EllipsizeMode.END;
		lbl_msg.max_width_chars = 50;

		//lbl_remaining = add_label(hbox_status, "");

		//progressbar
		progressbar = new Gtk.ProgressBar();
		vbox_progress.add (progressbar);
	}

	// create filters -------------------------------------------

	private void create_filters(){
		
		log_debug("create_filters()");
		
		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		hbox.no_show_all = true;
        this.add(hbox);
		hbox_filter = hbox;
		
		//add_label(hbox, _("Filter:"));

		add_search_entry(hbox);

		add_combo(hbox);

		if (!App.dry_run){

			var label = add_label(hbox, "");
			label.hexpand = true;
			
			var button = new Gtk.Button.with_label(_("Close"));
			hbox.add(button);
			
			button.clicked.connect(()=>{
				window.destroy();
			});
		}

		/*var btn_exclude = add_button(hbox,
			_("Exclude Selected"),
			_("Exclude selected items from future snapshots (careful!)"),
			ref size_group, null);
			
        btn_exclude.clicked.connect(()=>{
			if (flat_view){
				gtk_messagebox(_("Cannot exclude files in flat view"),
					_("View has been changed to tree view. Select the parent item you want to exclude and click the 'Exclude' button."),this, true);

				flat_view = false;
			}
			else{
				exclude_selected_items();
			}
			
			treeview_refresh();
		});*/
	}

	private void add_search_entry(Gtk.Box hbox){

		var txt = new Gtk.Entry();
		txt.xalign = 0.0f;
		txt.hexpand = true;
		txt.margin = 0;
		hbox.add(txt);
		
		txt.placeholder_text = _("Filter by name or path");

		txt_pattern = txt;

		txt.activate.connect(()=>{
			execute_action();
		});

		txt.focus_out_event.connect((event) => {
			txt.activate();
			return false;
		});

		// connect signal for shift+F10
        txt.popup_menu.connect(() => {
			return true; // suppress right-click menu
		});

        // connect signal for right-click
		txt.button_press_event.connect((w, event) => {
			if (event.button == 3) { return true; } // suppress right-click menu
			return false;
		});

		txt.key_press_event.connect((event) => {
			//string key_name = Gdk.keyval_name(event.keyval);
			//if (key_name.down() == "escape"){
			//	close_panel(true);
			//	return false;
			//}
			add_action_delayed();
			return false;
		});
		
		//txt.set_no_show_all(true);
	}

	private void add_combo(Gtk.Box hbox){
		
		// combo
		var combo = new Gtk.ComboBox ();
		hbox.add(combo);
		cmb_filter = combo;
		
		var cell_text = new CellRendererText ();
		cell_text.text = "";
		combo.pack_start (cell_text, false);

		combo.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			string val;
			model.get (iter, 1, out val, -1);
			((Gtk.CellRendererText)cell).text = val;
		});

		//populate combo
		var model = new Gtk.ListStore(2, typeof(string), typeof(string));
		cmb_filter.model = model;

		TreeIter iter;
		
		model.append(out iter);
		model.set (iter, 0, "", 1, _("All Files"));
		
		model.append(out iter);
		model.set (iter, 0, "created", 1, "%s".printf(App.dry_run ? _("Create") : _("Created")));

		if (is_restore_log){
			model.append(out iter);
			model.set (iter, 0, "deleted", 1, "%s".printf(App.dry_run ? _("Delete") : _("Deleted")));
		}
		
		model.append(out iter);

		string txt = "";
		if (App.dry_run){
			txt = _("Restore");
		}
		else if (is_restore_log){
			txt = _("Changed");
		}
		else{
			txt = _("Changed");
		}
		
		model.set (iter, 0, "changed", 1, "%s".printf(txt));

		if (!App.dry_run){
			model.append(out iter);
			model.set (iter, 0, "checksum", 1, " └ %s".printf(_("Checksum")));
			model.append(out iter);
			model.set (iter, 0, "size", 1, " └ %s".printf(_("Size")));
			model.append(out iter);
			model.set (iter, 0, "timestamp", 1, " └ %s".printf(_("Timestamp")));
			model.append(out iter);
			model.set (iter, 0, "permissions", 1, " └ %s".printf(_("Permissions")));
			model.append(out iter);
			model.set (iter, 0, "owner", 1, " └ %s".printf(_("Owner")));
			model.append(out iter);
			model.set (iter, 0, "group", 1, " └ %s".printf(_("Group")));
		}
		
		cmb_filter.active = 0;
	}

	private uint tmr_action = 0;
	
	private void add_action_delayed(){
		
		clear_action_delayed();
		tmr_action = Timeout.add(200, execute_action);
	}

	private void clear_action_delayed(){
		
		if (tmr_action > 0){
			Source.remove(tmr_action);
			tmr_action = 0;
		}
	}

	private bool execute_action(){

		clear_action_delayed();

		name_filter = txt_pattern.text;
		
		treefilter.refilter();
		
		return false;
	}

	// treeview --------------------------------------------------------

	private void create_treeview() {

		vbox_list = new Gtk.Box(Orientation.VERTICAL, 6);
		vbox_list.no_show_all = true;
		this.add(vbox_list);

		//add_label(vbox_list,
		//	_("Following files have changed since previous snapshot:"));

		// treeview
		treeview = new Gtk.TreeView();
		treeview.get_selection().mode = SelectionMode.MULTIPLE;
		treeview.headers_clickable = true;
		treeview.rubber_banding = true;
		treeview.has_tooltip = true;
		treeview.show_expanders = false;

		// scrolled
		var scrolled = new Gtk.ScrolledWindow(null, null);
		scrolled.set_shadow_type(ShadowType.ETCHED_IN);
		scrolled.add (treeview);
		scrolled.hscrollbar_policy = PolicyType.AUTOMATIC;
		scrolled.vscrollbar_policy = PolicyType.AUTOMATIC;
		scrolled.vexpand = true;
		vbox_list.add(scrolled);

		add_column_status();

		add_column_name();

		add_column_buffer();
	}

	private void add_column_status(){

		var col = new Gtk.TreeViewColumn();
		col.title = is_restore_log ? _("Action") : _("Status");
		treeview.append_column(col);
		col_status = col;

		// cell icon
		var cell_pix = new Gtk.CellRendererPixbuf();
		cell_pix.stock_size = Gtk.IconSize.MENU;
		col.pack_start(cell_pix, false);
		col.set_attributes(cell_pix, "pixbuf", 3);
		
		// cell text
		var cell_text = new Gtk.CellRendererText ();
		col.pack_start (cell_text, false);
		col.set_attributes(cell_text, "text", 4);
	}

	private void add_column_name(){

		// column
		var col = new Gtk.TreeViewColumn();
		col.title = _("Name");
		col.clickable = true;
		col.resizable = true;
		col.expand = true;
		treeview.append_column(col);
		col_name = col;
		
		// cell icon
		var cell_pix = new Gtk.CellRendererPixbuf();
		cell_pix.stock_size = Gtk.IconSize.MENU;
		col.pack_start(cell_pix, false);
		col.set_attributes(cell_pix, "pixbuf", 1);
		
		// cell text
		var cell_text = new Gtk.CellRendererText ();
		cell_text.ellipsize = Pango.EllipsizeMode.END;
		col.pack_start (cell_text, false);
		col.set_attributes(cell_text, "text", 2);
	}

	private void add_column_buffer(){

		var col = new Gtk.TreeViewColumn();
		col.title = "";
		col.clickable = false;
		col.resizable = false;
		col.min_width = 20;
		treeview.append_column(col);
		//var col_spacer = col;
		
		// cell text
		var cell_text = new Gtk.CellRendererText ();
		col.pack_start (cell_text, false);
	}
	
	private void treeview_refresh() {
		
		log_debug("treeview_refresh(): 0");

		var tmr = timer_start();

		hbox_filter.sensitive = false;
		
		gtk_set_busy(true, window);

		var model = new Gtk.ListStore(5,
			typeof(FileItem), 	// item
			typeof(Gdk.Pixbuf), // file icon
			typeof(string), 	// path
			typeof(Gdk.Pixbuf), // status icon
			typeof(string) 		// status
		);

		TreeIter iter0;

		var spath = "%s/localhost".printf(file_parent(rsync_log_file));
		
		foreach(var item in loglist) {

			if (App.dry_run){
				if (item.file_type == FileType.DIRECTORY){ continue; }
			}

			string status = "";
			Gdk.Pixbuf status_icon = null;
			
			if (is_restore_log){

				switch(item.file_status){
				case "checksum":
				case "size":
				case "timestamp":
				case "permissions":
				case "owner":
				case "group":
					status = App.dry_run ? _("Restore") : _("Changed");
					status_icon = IconManager.lookup("item-yellow",16);
					break;
				case "created":
					status =  App.dry_run ? _("Create") : _("Created");
					status_icon = IconManager.lookup("item-green",16);
					break;
				case "deleted":
					status =  App.dry_run ? _("Delete") : _("Deleted");
					status_icon = IconManager.lookup("item-red",16);
					break;
				}
			}
			else{
				switch(item.file_status){
				case "checksum":
				case "size":
				case "timestamp":
				case "permissions":
				case "owner":
				case "group":
					status = _("Changed");
					status_icon = IconManager.lookup("item-yellow",16);
					break;
				case "created":
					status = _("Created");
					status_icon = IconManager.lookup("item-green",16);
					break;
				case "deleted":
					status = _("Deleted");
					status_icon = IconManager.lookup("item-red",16);
					break;
				}
			}

			var relpath = item.file_path[spath.length:item.file_path.length];

			if (!is_restore_log){
				relpath = relpath[1:relpath.length]; // show relative path; remove / prefix
			}
			
			// add row
			model.append(out iter0);
			model.set(iter0, 0, item);
			model.set(iter0, 1, item.get_icon(16, false, false));
			model.set(iter0, 2, relpath);
			model.set(iter0, 3, status_icon);
			model.set(iter0, 4, status);
		}
		
		treefilter = new Gtk.TreeModelFilter(model, null);
		treefilter.set_visible_func(filter_packages_func);
		treeview.set_model(treefilter);
		
		//treeview.set_model(model);
		//treeview.columns_autosize();

		log_debug("treeview_refresh(): %s".printf(timer_elapsed_string(tmr)));

		hbox_filter.sensitive = true;
		gtk_set_busy(false, window);
	}

	private bool filter_packages_func (Gtk.TreeModel model, Gtk.TreeIter iter) {
		
		FileItem item;
		model.get (iter, 0, out item, -1);

		//return true;
		//if (item.file_type == FileType.DIRECTORY){
		//	return false;
		//}

		if (name_filter.length > 0){

			var spath = "%s/localhost".printf(file_parent(rsync_log_file));
			var relpath = item.file_path[spath.length:item.file_path.length];
			
			if (!relpath.down().contains(name_filter)){
				
				return false;
			}
		}

		if (status_filter.length == 0){
			return true;
		}
		else if (status_filter == "changed"){
			switch(item.file_status){
			case "checksum":
			case "size":
			case "timestamp":
			case "permissions":
			case "owner":
			case "group":
				return true;
			default:
				return false;
			}
		}
		else{
			return (item.file_status == status_filter);
		}
	}

	private void exclude_selected_items(){
		var list = new Gee.ArrayList<string>();
		foreach(var pattern in App.exclude_list_user){
			list.add(pattern);
		}
		App.exclude_list_user.clear();

		// TODO: medium: exclude selected items: not working
		
		// add include list
		TreeIter iter;
		var store = (Gtk.ListStore) treeview.model;
		bool iterExists = store.get_iter_first (out iter);
		while (iterExists) {
			FileItem item;
			store.get (iter, 0, out item);

			string pattern = item.file_path;

			if (item.file_type == FileType.DIRECTORY){
				pattern = "%s/***".printf(pattern);
			}
			else{
				//pattern = "%s/***".printf(pattern);
			}
			
			if (!App.exclude_list_user.contains(pattern)
				&& !App.exclude_list_default.contains(pattern)
				&& !App.exclude_list_home.contains(pattern)){
				
				list.add(pattern);
			}
			
			iterExists = store.iter_next (ref iter);
		}

		App.exclude_list_user = list;

		log_debug("exclude_selected_items()");
		foreach(var item in App.exclude_list_user){
			log_debug(item);
		}
	}
}
