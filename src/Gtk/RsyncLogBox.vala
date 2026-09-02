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

/* Row object for the status filter drop-down: GTK4 list widgets bind to
 * GObjects rather than tree-model columns. */
public class RsyncLogFilter : GLib.Object {

	public string key { get; set; }
	public string text { get; set; }

	public RsyncLogFilter(string _key, string _text){
		key = _key;
		text = _text;
	}
}

/* Row object for the rsync log list. GTK4 list widgets bind to GObjects rather
 * than tree-model columns; the status text and icon name are precomputed here
 * exactly as the tree model used to store them. */
public class RsyncLogRow : GLib.Object {

	public FileItem item { get; set; }
	public string relpath { get; set; }
	public string status { get; set; }
	public string status_icon { get; set; }

	public RsyncLogRow(FileItem _item, string _relpath, string _status, string _status_icon){
		item = _item;
		relpath = _relpath;
		status = _status;
		status_icon = _status_icon;
	}
}

public class RsyncLogBox : Gtk.Box {

	private Gtk.Box vbox_progress;
	private Gtk.Box vbox_list;

	private Gtk.ColumnView treeview;
	private Gtk.FilterListModel treefilter;
	private GLib.ListStore log_model;
	private Gtk.CustomFilter log_filter;
	private Gtk.DropDown cmb_filter;
	private Gtk.Box hbox_filter;
	private Gtk.SearchEntry txt_pattern;

	private Gtk.ColumnViewColumn col_name;
	private Gtk.ColumnViewColumn col_status;
	
	private string name_filter = "";
	private string status_filter = "";

	public Gtk.Label lbl_header;
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

	/* Set when the log belongs to a SNAPSHOT, which the daemon can read
	 * wherever it lives -- including a remote repository, where the old path
	 * downloaded the whole file first just to parse it locally.
	 *
	 * Empty for the restore wizard, whose log is written by the restore
	 * running in this process and does not live under /var/log/timeshift, so
	 * log.parse would refuse it by path. That caller moves with the restore
	 * itself. */
	private string snapshot_name = "";
	private string snapshot_log_name = "";

	private Gtk.Window window;
	private bool ui_built = false;

	/* Emitted once the log has been parsed and the list is populated. The
	 * restore wizard keeps its navigation disabled until then: parse_log_file()
	 * pumps the main loop, so a second open_log() from there would start a
	 * second parser thread over the same App.task and loglist. */
	public signal void log_ready();

	public RsyncLogBox(Gtk.Window _window) {
		
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		
		log_debug("RsyncLogBox: RsyncLogBox()");

		window	= _window;
	}

	/* Open a SNAPSHOT's log through the daemon.
	 *
	 * nominal_path is never opened. It is the log's path in the repository,
	 * used only to derive the column title and to rebuild each entry's display
	 * path, so it is fine for it to name a file on the far side of an ssh
	 * connection. */
	public void open_snapshot_log(string snapshot, string log_name,
		string nominal_path){

		snapshot_name = snapshot;
		snapshot_log_name = log_name;
		open_log(nominal_path);
	}

	public void open_log(string _rsync_log_file){

		if (thread_is_running){
			log_debug("open_log(): parser already running, ignoring");
			return;
		}

		rsync_log_file = _rsync_log_file;

		/* A second open (the restore wizard's Back, then another dry run)
		 * reuses the widgets: treeview_refresh() clears the model itself. */
		if (ui_built){
			// the filter entries and the column title depend on which log this
			// is, so rebuild them rather than reusing the previous log's
			refresh_filter_options();
			col_name.title = is_restore_log ? _("File (system)") : _("File (snapshot)");
			lbl_header.label = App.dry_run ? _("Confirm Actions") : _("Rsync Log");

			vbox_progress.visible = true;
			hbox_filter.visible = false;
			vbox_list.visible = false;
			tmr_init = Timeout.add(100, init_delayed);
			return;
		}
		ui_built = true;

		// header
		lbl_header = Ui.add_title(this, App.dry_run ? _("Confirm Actions") : _("Rsync Log"));

		create_progressbar();

		create_filters();
		
		create_treeview();

		cmb_filter.notify["selected"].connect(() => {

			var selected = cmb_filter.get_selected_item() as RsyncLogFilter;
			status_filter = (selected == null) ? "" : selected.key;
			log_debug("combo_changed(): filter=%s".printf(status_filter));

			Timeout.add(100, ()=>{

				hbox_filter.sensitive = false;
				treeview.sensitive = false;
				
				log_debug("refilter(): start");
				log_filter.changed(Gtk.FilterChange.DIFFERENT);
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

		this.visible = true;

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

		parse_log_file();

		log_ready();

		log_debug("init_delayed(): finish");
		
		return false;
	}

	private void parse_log_file(){

		/* A snapshot's log goes through the daemon. The local parser below is
		 * still reached by the restore wizard, whose log this process is
		 * writing as it runs. */
		if (snapshot_name.length > 0){

			bool ok = parse_log_via_daemon();

			/* No local fallback for a snapshot's log, deliberately.
			 *
			 * The path names a file in the REPOSITORY, which for a remote one
			 * does not exist on this machine at all -- so falling through to
			 * the local parser would replace a clear failure with an empty
			 * list and no explanation. */
			if (!ok){
				loglist = new Gee.ArrayList<FileItem>();
				lbl_msg.label = _("The log could not be read.");
				progressbar.fraction = 0;
			}

			if (ok){
				lbl_msg.label = _("Populating list...");
				gtk_do_events();
				treeview_refresh();
			}

			vbox_progress.visible = ok ? false : true;
			gtk_do_events();
			vbox_list.visible = ok;
			hbox_filter.visible = ok;
			return;
		}

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

		vbox_progress.visible = false;
		gtk_do_events();
		vbox_list.visible = true;
		hbox_filter.visible = true;
	}
	
	private void parse_log_file_thread(){
		
		App.task = new RsyncTask();
		loglist = App.task.parse_log(rsync_log_file);
		thread_is_running = false;
	}

	/* Parse a snapshot's log in the daemon and page the result back.
	 *
	 * Returns false if the daemon cannot do it, so the caller falls back to
	 * the local parser -- which is still the only way to read the restore
	 * wizard's own log.
	 *
	 * The entries come back flat and relative. They are turned into FileItems
	 * carrying the same absolute paths the local parser produced, so
	 * treeview_refresh() -- which strips that prefix back off, and decides the
	 * status text and icon -- needs no change at all.
	 */
	private bool parse_log_via_daemon(){

		var api = DaemonApi.get_shared();
		if ((api == null) || (snapshot_name.length == 0)){ return false; }

		string job_id, resolved;
		if (!api.log_parse(snapshot_name, snapshot_log_name, "",
			out job_id, out resolved)){
			log_debug("log.parse refused: %s".printf(api.last_error));
			return false;
		}

		/* The parse is a JOB, and the daemon runs one job at a time -- so this
		 * waits behind a backup if one is running. Say so rather than sitting
		 * on a still progress bar, which reads as a hang. */
		lbl_msg.label = _("Waiting for the Timeshift service...");
		progressbar.pulse();
		gtk_do_events();

		while (true){

			var job = api.jobs_get(job_id);
			if (job == null){
				log_debug("jobs.get failed: %s".printf(api.last_error));
				return false;
			}

			string state = DaemonClient.wire_string(job, "state", "");
			if ((state == "finished") || (state == "failed")
				|| (state == "cancelled")){
				if (state != "finished"){
					log_debug("log.parse ended as %s".printf(state));
					return false;
				}
				break;
			}

			if (state == "running"){
				lbl_msg.label = _("Parsing log file...");
				if (job.has_member("progress") &&
					(job.get_member("progress").get_node_type() == Json.NodeType.OBJECT)){
					var pr = job.get_object_member("progress");
					int64 count = DaemonClient.wire_int(pr, "count", 0);
					int64 total = DaemonClient.wire_int(pr, "total", 0);
					if (total > 0){
						progressbar.fraction = (double) count / (double) total;
					}
					else {
						progressbar.pulse();
					}
					string line = DaemonClient.wire_string(pr, "status_line", "");
					if (line.length > 0){ lbl_msg.label = _("Read") + " " + line; }
				}
			}

			sleep(200);
			gtk_do_events();
		}

		return load_entries(api, resolved);
	}

	/* Page the parsed entries back.
	 *
	 * Paged rather than fetched whole because a restore log here is 22 MB and
	 * 222,521 changes: asking for it in one response is a download, not a
	 * reply. The page size is a compromise between round trips and the size of
	 * a single JSON object the client has to hold. */
	private bool load_entries(DaemonApi api, string path){

		const int PAGE = 20000;

		loglist = new Gee.ArrayList<FileItem>();
		string basepath = "%s/localhost".printf(file_parent(rsync_log_file));

		int offset = 0;
		while (true){

			var page = api.log_entries_page(path, offset, PAGE);
			if (page == null){
				log_debug("log.entries failed: %s".printf(api.last_error));
				return false;
			}

			foreach (var entry in page.entries){
				var item = new FileItem.from_path_and_type(
					path_combine(basepath, entry.path),
					entry.is_dir ? FileType.DIRECTORY : FileType.REGULAR);
				item.file_status = entry.kind;
				loglist.add(item);
			}

			lbl_msg.label = _("Read %'d of %'d entries...").printf(
				loglist.size, page.total);
			if (page.total > 0){
				progressbar.fraction = (double) loglist.size / (double) page.total;
			}
			gtk_do_events();

			if (!page.more){ break; }
			offset += page.entries.size;

			// A page that advances nothing would loop forever.
			if (page.entries.size == 0){ break; }
		}

		return true;
	}

	public bool is_running{
		get {
			return thread_is_running;
		}
	}
	
	// create ui -----------------------------------------

	private void create_progressbar(){
		
		var progress = new TaskProgressBox(_("Parsing log file..."), false);
		this.append(progress);
		vbox_progress = progress;

		spinner = progress.spinner;
		lbl_msg = progress.lbl_msg;
		progressbar = progress.progressbar;
		progress.lbl_status.visible = false;
	}

	// create filters -------------------------------------------

	private void create_filters(){
		
		log_debug("create_filters()");
		
		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		hbox.visible = false; // until the log is parsed
        this.append(hbox);
		hbox_filter = hbox;
		

		add_search_entry(hbox);

		add_combo(hbox);
	}

	private void add_search_entry(Gtk.Box hbox){

		var txt = new Gtk.SearchEntry();
		txt.hexpand = true;
		hbox.append(txt);
		
		txt.placeholder_text = _("Filter by name or path");

		txt_pattern = txt;

		txt.activate.connect(()=>{
			execute_action();
		});

		var focus = new Gtk.EventControllerFocus();
		focus.leave.connect(() => {
			txt.activate();
		});
		txt.add_controller(focus);

		// suppress the right-click menu -- claim the press before the entry sees it
		var click = new Gtk.GestureClick();
		click.button = Gdk.BUTTON_SECONDARY;
		click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
		click.pressed.connect(() => {
			click.set_state(Gtk.EventSequenceState.CLAIMED);
		});
		txt.add_controller(click);

		var keys = new Gtk.EventControllerKey();
		keys.key_pressed.connect((keyval, keycode, state) => {
			add_action_delayed();
			return false;
		});
		txt.add_controller(keys);
		
		//txt.set_no_show_all(true);
	}

	private void add_combo(Gtk.Box hbox){
		
		// combo
		/* GTK4 deprecates Gtk.ComboBox; a Gtk.DropDown over a GLib.ListStore
		 * of RsyncLogFilter carries the key/label pair the old two-column
		 * tree model held. */

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = new Gtk.Label("");
			lbl.xalign = (float) 0.0;
			list_item.set_child(lbl);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = (Gtk.Label) list_item.get_child();
			var option = (RsyncLogFilter) list_item.get_item();
			lbl.label = option.text;
		});

		var combo = new Gtk.DropDown(null, null);
		combo.factory = factory;
		hbox.append(combo);
		cmb_filter = combo;

		refresh_filter_options();
	}

	/* The entries depend on which log is open (dry run vs restore vs create),
	 * so they are rebuilt whenever a log is loaded into an existing box. */
	private void refresh_filter_options(){

		var model = new GLib.ListStore(typeof(RsyncLogFilter));

		model.append(new RsyncLogFilter("", _("All Files")));
		model.append(new RsyncLogFilter("created", "%s".printf(App.dry_run ? _("Create") : _("Created"))));

		if (is_restore_log){
			model.append(new RsyncLogFilter("deleted", "%s".printf(App.dry_run ? _("Delete") : _("Deleted"))));
		}

		string txt = App.dry_run ? _("Restore") : _("Changed");

		model.append(new RsyncLogFilter("changed", "%s".printf(txt)));

		if (!App.dry_run){
			model.append(new RsyncLogFilter("checksum",    " └ %s".printf(_("Checksum"))));
			model.append(new RsyncLogFilter("size",        " └ %s".printf(_("Size"))));
			model.append(new RsyncLogFilter("timestamp",   " └ %s".printf(_("Timestamp"))));
			model.append(new RsyncLogFilter("permissions", " └ %s".printf(_("Permissions"))));
			model.append(new RsyncLogFilter("owner",       " └ %s".printf(_("Owner"))));
			model.append(new RsyncLogFilter("group",       " └ %s".printf(_("Group"))));
		}

		cmb_filter.model = model;
		cmb_filter.selected = 0;
		status_filter = "";
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

		name_filter = txt_pattern.text.down();
		
		log_filter.changed(Gtk.FilterChange.DIFFERENT);
		
		return false;
	}

	// treeview --------------------------------------------------------

	private void create_treeview() {

		vbox_list = new Gtk.Box(Orientation.VERTICAL, Ui.Spacing.XS);
		vbox_list.visible = false; // until the log is parsed
		this.append(vbox_list);

		/* GTK4 deprecates Gtk.TreeView/Gtk.TreeModelFilter. The rows live in a
		 * GLib.ListStore behind a Gtk.FilterListModel driven by a
		 * Gtk.CustomFilter wrapping the same predicate as before. */

		log_model = new GLib.ListStore(typeof(RsyncLogRow));

		log_filter = new Gtk.CustomFilter((item) => {
			return filter_packages_func((RsyncLogRow) item);
		});

		treefilter = new Gtk.FilterListModel(log_model, log_filter);

		treeview = new Gtk.ColumnView(new Gtk.MultiSelection(treefilter));

		// scrolled
		Ui.add_boxed_list(vbox_list, treeview);

		add_column_status();

		add_column_name();
	}

	private Gtk.ColumnViewColumn make_icon_text_column(string title, bool is_status){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);

			var img = new Gtk.Image();
			img.pixel_size = 16;
			hbox.append(img);

			var lbl = new Gtk.Label("");
			lbl.xalign = (float) 0.0;
			lbl.ellipsize = Pango.EllipsizeMode.END;
			hbox.append(lbl);

			list_item.set_child(hbox);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var hbox = (Gtk.Box) list_item.get_child();
			var img = (Gtk.Image) hbox.get_first_child();
			var lbl = (Gtk.Label) img.get_next_sibling();
			var row = (RsyncLogRow) list_item.get_item();

			if (is_status){
				/* A coloured dot: one symbolic icon, tinted per status by the
				 * stylesheet so it follows the palette. */
				img.remove_css_class("ts-status-changed");
				img.remove_css_class("ts-status-created");
				img.remove_css_class("ts-status-deleted");
				if (row.status_icon.length > 0){
					img.set_from_icon_name("media-record-symbolic");
					img.add_css_class(row.status_icon);
				}
				else {
					img.clear();
				}
				lbl.label = row.status;
			}
			else{
				/* The item already carries a GLib.Icon, so hand that straight to
				 * the image rather than rendering it into a (deprecated) texture
				 * via a pixbuf. */
				if (row.item.icon != null){
					img.set_from_gicon(row.item.icon);
				}
				else {
					IconManager.set_image_icon(img,
						(row.item.file_type == FileType.DIRECTORY)
							? IconManager.GENERIC_ICON_DIRECTORY
							: IconManager.GENERIC_ICON_FILE, 16);
				}
				lbl.label = row.relpath;
			}
		});

		return new Gtk.ColumnViewColumn(title, factory);
	}

	private void add_column_status(){

		var col = make_icon_text_column(is_restore_log ? _("Action") : _("Status"), true);
		treeview.append_column(col);
		col_status = col;
	}

	private void add_column_name(){

		var col = make_icon_text_column(_("Name"), false);
		col.expand = true;
		col.resizable = true;
		treeview.append_column(col);
		col_name = col;
	}

	private void treeview_refresh() {
		
		log_debug("treeview_refresh(): 0");

		var tmr = timer_start();

		hbox_filter.sensitive = false;
		
		gtk_set_busy(true, window);

		/* Build the rows detached, then splice them in as ONE operation.
		 *
		 * log_model has a FilterListModel and the ColumnView attached, so every
		 * append() emits items_changed and cascades through both. Appending row
		 * by row is fine for a few hundred; a restore log carries a couple of
		 * hundred THOUSAND, and the cascade turns into effectively quadratic
		 * work -- the UI freezes at 100% CPU showing the last painted frame,
		 * which looks exactly like a hang partway through parsing.
		 *
		 * splice() emits once, whatever the row count. */
		var rows = new GenericArray<Object>();

		var spath = "%s/localhost".printf(file_parent(rsync_log_file));
		
		foreach(var item in loglist) {

			if (App.dry_run){
				if (item.file_type == FileType.DIRECTORY){ continue; }
			}

			string status = "";
			string status_icon = "";
			
			if (is_restore_log){

				switch(item.file_status){
				case "checksum":
				case "size":
				case "timestamp":
				case "permissions":
				case "owner":
				case "group":
					status = App.dry_run ? _("Restore") : _("Changed");
					status_icon = "ts-status-changed";
					break;
				case "created":
					status =  App.dry_run ? _("Create") : _("Created");
					status_icon = "ts-status-created";
					break;
				case "deleted":
					status =  App.dry_run ? _("Delete") : _("Deleted");
					status_icon = "ts-status-deleted";
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
					status_icon = "ts-status-changed";
					break;
				case "created":
					status = _("Created");
					status_icon = "ts-status-created";
					break;
				case "deleted":
					status = _("Deleted");
					status_icon = "ts-status-deleted";
					break;
				}
			}

			var relpath = item.file_path[spath.length:item.file_path.length];

			if (!is_restore_log){
				relpath = relpath[1:relpath.length]; // show relative path; remove / prefix
			}
			
			// add row
			rows.add(new RsyncLogRow(item, relpath, status, status_icon));
		}

		log_model.splice(0, log_model.get_n_items(), rows.data);

		log_filter.changed(Gtk.FilterChange.DIFFERENT);

		log_debug("treeview_refresh(): %s".printf(timer_elapsed_string(tmr)));

		hbox_filter.sensitive = true;
		gtk_set_busy(false, window);
	}

	private bool filter_packages_func (RsyncLogRow row) {

		var item = row.item;

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
}
