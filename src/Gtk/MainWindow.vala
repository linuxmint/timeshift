/*
 * MainWindow.vala
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

public delegate void MenuActionFunc();

class MainWindow : AppWindow{

	private Gtk.Box vbox_main;
	private Gtk.HeaderBar header;

	// header actions
	private Gtk.Button btn_backup;
	private Gtk.Button btn_restore;
	private Gtk.Button btn_delete_snapshot;
	private Gtk.Button btn_browse_snapshot;
	private GLib.SimpleAction action_unpause;
	private GLib.SimpleAction action_settings;
	private GLib.SimpleAction action_wizard;

	// content: the list, or an empty-state page
	private Gtk.Stack content_stack;
	private SnapshotListBox snapshot_list_box;
	private StatusPage status_page;
	private Gtk.Button btn_status_action;
	private Gtk.Button btn_status_retry;
	private bool status_action_opens_wizard = false;

	// status area
	private Banner daemon_banner;
	private JobMonitorWindow? monitor_window = null;
	private uint tmr_daemon = 0;

	private Gtk.Box status_area;
	private StatusCard status_card;
	private StatTile tile_snapshots;
	private StatTile tile_free;

	//timers
	private uint tmr_init;
	private int def_width = 900;
	private int def_height = 640;

	public MainWindow () {

		log_debug("MainWindow: MainWindow()");
		
		this.title = "Timeshift";
        this.set_default_size (def_width, def_height);
		this.close_request.connect(on_delete_event);

	    //vbox_main
        vbox_main = new Gtk.Box(Orientation.VERTICAL, 0);
        set_child(vbox_main);

        init_ui_header();

        init_ui_daemon_banner();

        init_ui_snapshot_list();

		init_ui_statusbar();

        if (App.live_system()){
			btn_backup.sensitive = false;
			action_settings.set_enabled(false);
		}

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("MainWindow: MainWindow(): exit");
    }

    private bool init_delayed(){
		
		if (tmr_init > 0){
			Source.remove(tmr_init);
			tmr_init = 0;
		}

		log_debug("MainWindow(): init_delayed()");

		// Don't fall back to a local device when a remote location is
		// configured - an unreachable remote would otherwise be silently
		// replaced by whatever backup_parent_uuid still points at.
		if ((App.backup_location_type != "ssh")
			&& ((App.repo == null) || !App.repo.available())){
			if (App.backup_parent_uuid.length > 0){
				log_debug("repo: creating from parent uuid");
				App.repo = new SnapshotRepo.from_uuid(App.backup_parent_uuid, this, App.btrfs_mode);
			}
		}

		refresh_all();

		/* Ask the service whether something is already under way.
		 *
		 * This is the case the whole daemon exists for: apt-snapshot-guard has
		 * blocked dpkg while it takes a snapshot, and until now opening this
		 * window during that was either refused outright or showed a stale
		 * list with no hint that anything was happening. */
		check_daemon_job();
		tmr_daemon = Timeout.add_seconds(5, () => {
			check_daemon_job();
			return true;
		});

		if (App.first_run){
			btn_wizard_clicked();
		}

		log_debug("MainWindow(): init_delayed(): exit");
		
		return false;
	}

	/* The banner that says something else is working.
	 *
	 * Hidden until there is a job. GTK4 widgets are visible by default, so it
	 * has to be switched off explicitly rather than merely left alone. */
	private void init_ui_daemon_banner(){

		daemon_banner = new Banner();
		daemon_banner.visible = false;
		vbox_main.append(daemon_banner);

		/* Banner is a Gtk.Box whose label hexpands, so an appended button
		 * lands at the end of the strip. */
		var btn = new Gtk.Button.with_label(_("Show Progress"));
		btn.valign = Gtk.Align.CENTER;
		btn.clicked.connect(show_daemon_job);
		daemon_banner.append(btn);
	}

	/* Poll the daemon for a running job.
	 *
	 * Polling, not a subscription, and on purpose: this only needs to know
	 * whether to show a one-line banner, and a five-second poll of a local
	 * socket costs nothing. The live stream is opened by JobMonitorWindow,
	 * which is the thing that actually needs every event.
	 */
	private void check_daemon_job(){

		var client = App.daemon;
		if (client == null){
			hide_daemon_banner();
			return;
		}

		string job_id, kind;
		if (!client.running_job(out job_id, out kind)){
			log_debug("MainWindow: the Timeshift service has no job running");

			// A job that has just gone away means new snapshots to list.
			if (daemon_banner.visible){
				hide_daemon_banner();
				refresh_all();
			}
			return;
		}

		if (monitor_window != null){
			return; // already being watched; the window has the detail
		}

		log_debug("MainWindow: the Timeshift service is running %s (%s)".printf(job_id, kind));

		daemon_banner.set_message(daemon_banner_text(kind), Gtk.MessageType.INFO);
	}

	private string daemon_banner_text(string kind){
		switch (kind){
		case "create":
			return _("A snapshot is being created by the Timeshift service.");
		case "delete":
			return _("Snapshots are being deleted by the Timeshift service.");
		case "estimate":
			return _("The Timeshift service is estimating the system size.");
		default:
			return _("The Timeshift service is busy.");
		}
	}

	private void hide_daemon_banner(){
		daemon_banner.visible = false;
		daemon_banner.clear();
	}

	private void show_daemon_job(){

		var client = App.daemon;
		if (client == null){ return; }

		string job_id, kind;
		if (!client.running_job(out job_id, out kind)){ return; }

		if (monitor_window != null){
			monitor_window.present();
			return;
		}

		monitor_window = new JobMonitorWindow(client, job_id, kind);
		monitor_window.closed.connect(() => {
			monitor_window = null;
		});
		monitor_window.job_done.connect(() => {
			// The snapshot list is stale the moment a job finishes.
			hide_daemon_banner();
			refresh_all();
		});
		monitor_window.present();
	}

	private void init_ui_header(){

		/* Create is the primary verb and keeps its label; Restore, Delete and
		 * Browse are a linked icon group with tooltips. Settings and the
		 * wizard are in the menu -- rare actions, and six labelled buttons do
		 * not fit beside a title. */

		header = new Gtk.HeaderBar();
		set_titlebar(header);

		var box_create = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		btn_backup = Ui.add_icon_button(box_create, "document-save-symbolic", _("Create"),
			_("Create snapshot of current system"));
		btn_backup.add_css_class("suggested-action");
		btn_backup.clicked.connect (create_snapshot);
		header.pack_start(box_create);

		var group = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		group.add_css_class("linked");
		header.pack_start(group);

		btn_restore = Ui.add_icon_only_button(group, "document-open-recent-symbolic",
			_("Restore selected snapshot"));
		btn_restore.clicked.connect (btn_restore_clicked);

		btn_delete_snapshot = Ui.add_icon_only_button(group, "edit-delete-symbolic",
			_("Delete selected snapshot"));
		/* No .destructive-action here: as a permanent toolbar icon it renders
		 * as a solid red block. The destructive styling lives on the Yes of
		 * the confirmation, which is the point of no return. */
		btn_delete_snapshot.clicked.connect (delete_selected);

		btn_browse_snapshot = Ui.add_icon_only_button(group, "folder-symbolic",
			_("Browse selected snapshot"));
		btn_browse_snapshot.clicked.connect (browse_selected);

		init_ui_menu();
	}

	private void init_ui_snapshot_list(){

		content_stack = new Gtk.Stack();
		content_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
		content_stack.vexpand = true;
		vbox_main.append(content_stack);

		snapshot_list_box = new SnapshotListBox(this);
		snapshot_list_box.vexpand = true;
		Ui.as_page(snapshot_list_box);
		content_stack.add_named(snapshot_list_box, "list");

		snapshot_list_box.delete_selected.connect(delete_selected);
		
		snapshot_list_box.mark_selected.connect(mark_selected);

		snapshot_list_box.browse_selected.connect(browse_selected);

		snapshot_list_box.view_snapshot_log.connect(view_snapshot_log);

		// empty state: no location, or a location with nothing on it
		status_page = new StatusPage("drive-harddisk-symbolic", "", "");
		content_stack.add_named(status_page, "empty");

		btn_status_action = new Gtk.Button.with_label("");
		btn_status_action.add_css_class("suggested-action");
		btn_status_action.clicked.connect(() => {
			if (status_action_opens_wizard){
				btn_wizard_clicked();
			}
			else {
				create_snapshot();
			}
		});

		/* A dropped network used to leave "Select Snapshot Location" as the
		 * only way forward -- i.e. walk the whole setup wizard again, at the
		 * exact moment someone is trying to rescue a machine. Retry asks the
		 * same location again. */
		btn_status_retry = new Gtk.Button.with_label(_("Retry"));
		btn_status_retry.visible = false;
		btn_status_retry.clicked.connect(retry_location);

		var action_row = new Gtk.Box(Orientation.HORIZONTAL, Ui.Spacing.SM);
		action_row.halign = Align.CENTER;
		action_row.append(btn_status_retry);
		action_row.append(btn_status_action);

		status_page.set_action(action_row);
    }

	private void init_ui_statusbar(){

		/* One row: the protection status card taking the horizontal slack,
		 * two stat tiles trailing. Nothing here may set vexpand -- the
		 * content stack above absorbs the window's leftover height. */

		status_area = new Gtk.Box(Orientation.HORIZONTAL, Ui.Spacing.MD);
		set_margin_all(status_area, Ui.Spacing.LG);
		status_area.margin_top = 0; // the page above carries the gap
		vbox_main.append(status_area);

		status_card = new StatusCard();
		status_card.set_shield(IconManager.SHIELD_HIGH);
		status_area.append(status_card);

		tile_snapshots = new StatTile(_("Snapshots"));
		status_area.append(tile_snapshots);

		tile_free = new StatTile(_("Available"));
		status_area.append(tile_free);

		// TODO: medium: add a refresh button for device when device is offline

		// TODO: low: refresh device list automatically when a device is plugged in
	}

    private void init_ui_menu(){

		/* GTK4 removes Gtk.Menu/Gtk.MenuItem. The hamburger is a Gtk.MenuButton
		 * driven by a GMenu model, with the entries backed by GActions. */

		var actions = new GLib.SimpleActionGroup();
		var menu_model = new GLib.Menu();

		var menu_setup = new GLib.Menu();
		action_settings = add_menu_action(actions, "settings", btn_settings_clicked);
		menu_setup.append(_("Settings"), "win.settings");
		action_wizard = add_menu_action(actions, "wizard", btn_wizard_clicked);
		menu_setup.append(_("Setup Wizard"), "win.wizard");
		menu_model.append_section(null, menu_setup);

		if (!App.live_system()){

			add_menu_action(actions, "view-logs", btn_view_app_logs_clicked);
			menu_model.append(_("View TimeShift Logs"), "win.view-logs");

			action_unpause = add_menu_action(actions, "unpause", () => App.unpause_snapshots());
			add_menu_action(actions, "pause-boot", () => App.pause_snapshots_for_this_boot());
			add_menu_action(actions, "pause-30m", () => App.pause_snapshots_for(1800));
			add_menu_action(actions, "pause-4h",  () => App.pause_snapshots_for(3600*4));
			add_menu_action(actions, "pause-8h",  () => App.pause_snapshots_for(3600*8));
			add_menu_action(actions, "pause-12h", () => App.pause_snapshots_for(3600*12));

			var menu_pause = new GLib.Menu();
			menu_pause.append(_("Unpause"), "win.unpause");
			menu_pause.append(_("Pause until shutdown"), "win.pause-boot");
			menu_pause.append(_("Pause for 30min"), "win.pause-30m");
			menu_pause.append(_("Pause for 4h"), "win.pause-4h");
			menu_pause.append(_("Pause for 8h"), "win.pause-8h");
			menu_pause.append(_("Pause for 12h"), "win.pause-12h");

			menu_model.append_submenu(_("Pause Snapshots"), menu_pause);
		}

		add_menu_action(actions, "about", btn_about_clicked);
		menu_model.append(_("About"), "win.about");

		this.insert_action_group("win", actions);

		var btn_menu = new Gtk.MenuButton();
		btn_menu.icon_name = "open-menu-symbolic";
		btn_menu.set_tooltip_text(_("Open Menu"));
		btn_menu.set_menu_model(menu_model);
		btn_menu.primary = true;
		header.pack_end(btn_menu);

		// "Unpause" is only meaningful while snapshots are actually paused
		btn_menu.notify["active"].connect(() => {
			if (action_unpause != null){
				action_unpause.set_enabled(App.snapshots_paused);
			}
		});
	}

	private GLib.SimpleAction add_menu_action(GLib.SimpleActionGroup actions, string name, owned MenuActionFunc callback){

		var action = new GLib.SimpleAction(name, null);
		action.activate.connect(() => { callback(); });
		actions.add_action(action);
		return action;
	}

	/* Ask the configured location again, without reconfiguring it.
	 *
	 * Drops the shared ssh connection first: after a link failure the master
	 * process can still be resident holding a dead session, and every new
	 * client attaches to it over a unix socket where ConnectTimeout does not
	 * apply -- so without this, Retry would block instead of dialling. The
	 * capability cache is cleared too, since it latches its verdict for the
	 * process lifetime and a drop mid-probe would otherwise pin a wrong
	 * reason ("read-only", "no hard-links") no matter how healthy the link. */
	private void retry_location(){

		btn_status_retry.sensitive = false;
		status_page.set_description(_("Contacting the snapshot location..."));
		gtk_do_events();

		App.repo.backend.drop_master();
		App.repo.invalidate_capability_cache();
		App.repo.check_status();

		if (App.repo.available()){
			App.repo.load_snapshots();
		}

		btn_status_retry.sensitive = true;

		refresh_all();
	}

	private bool refresh_all(){

		/* updates statusbar messages and snapshot list after backup device is changed */

		ui_sensitive(false);

		snapshot_list_box.refresh();
		update_statusbar();
		update_content_page();
		
		ui_sensitive(true);

		return false;
	}

	/* The list, or an empty-state page that says what to do next. */
	private void update_content_page(){

		if (!App.repo.available()){
			status_page.set_icon("drive-harddisk-symbolic");
			status_page.set_title(App.repo.status_message);
			status_page.set_description(App.repo.status_details);
			btn_status_action.label = _("Select Snapshot Location");
			// restoring needs a location too, so this stays available on a
			// live system -- it is the only way forward there
			btn_status_action.visible = true;
			status_action_opens_wizard = true;
			// only a remote location can come back on its own
			btn_status_retry.visible = App.repo.backend.is_remote;
			content_stack.visible_child_name = "empty";
		}
		else if (!App.repo.has_snapshots()){
			status_page.set_icon("camera-photo-symbolic");
			status_page.set_title(_("No snapshots available"));
			status_page.set_description(_("Create snapshots manually or enable scheduled snapshots to protect your system"));
			btn_status_action.label = _("Create Snapshot");
			btn_status_action.visible = !App.live_system(); // cannot create on a live system
			btn_status_retry.visible = false;
			status_action_opens_wizard = false;
			content_stack.visible_child_name = "empty";
		}
		else {
			content_stack.visible_child_name = "list";
		}

		/* The empty state already repeats status_message/status_details, so the
		 * card would say it twice -- except in live mode, where the card
		 * carries the "Live USB Mode (Restore Only)" notice instead. */
		status_area.visible = (content_stack.visible_child_name == "list") || App.live_system();
	}

	private bool on_delete_event(){

		// a browse mount should not outlive the window that opened it
		browse_unmount_all();

		/* Stop polling the daemon and drop the monitor.
		 *
		 * Note what is NOT done here: the daemon's job is left running. A job
		 * belongs to the service, not to whoever happens to be looking at it,
		 * and closing this window while apt waits on a snapshot must not
		 * abandon the snapshot apt is waiting for. */
		if (tmr_daemon > 0){
			Source.remove(tmr_daemon);
			tmr_daemon = 0;
		}
		if (monitor_window != null){
			monitor_window.close_self();
			monitor_window = null;
		}

		this.close_request.disconnect(on_delete_event); //disconnect this handler

		if (App.task.status == AppStatus.RUNNING){
			log_error (_("Main window closed by user"));
			App.task.stop();
		}

		// stop deletion task if running
		if (App.thread_delete_running){
			// clear queue
			App.delete_list.clear();
			// kill current task
			if (App.delete_file_task != null){
				App.delete_file_task.stop(AppStatus.CANCELLED);
			}
		}

		// check backup device -------------------------------

		if (!App.live_system()){
			
			if (!App.repo.available() || !App.repo.has_space()){

				var title = App.repo.status_message;
				
				var msg = _("Select another device?");
				
				var type = Gtk.MessageType.ERROR;
				var dlg = new CustomMessageDialog(title, msg, type, this, Gtk.ButtonsType.YES_NO);
				var response = dlg.run();
				dlg.destroy();
				
				if (response == Gtk.ResponseType.YES){
					this.close_request.connect(on_delete_event); // reconnect this handler
					btn_wizard_clicked(); // open wizard
					return true; // keep window open
				}
				else{
					notify_closed();
					return false; // close window
				}
			}
		}
		
		App.exit_app(0);

		notify_closed();

		return false;
	}

	// context menu
	
	public void create_snapshot(){

		if (check_if_deletion_running()){
			return;
		}
		
		ui_sensitive(false);
		
		// check root device --------------

		if (App.btrfs_mode && (App.check_btrfs_layout_system(this) == false)){
			ui_sensitive(true);
			return;
		}

		// check snapshot device -----------

		if (!App.repo.available()){
			gtk_messagebox(App.repo.status_message, App.repo.status_details, this, true);
			// allow user to continue after showing message
		}

		// run wizard window ------------------

		var win = new BackupWindow();
		win.set_transient_for(this);
		win.closed.connect(()=>{
			refresh_all();
			ui_sensitive(true);
		});
	}

	public void delete_selected(){

		log_debug("main window: delete_selected()");
		
		// check snapshot device -----------

		if (!App.repo.available()){
			gtk_messagebox(
				App.repo.status_message,
				_("Select another device to delete snapshots"),
				this, false);
			return;
		}
		else if (!App.repo.has_snapshots()){
			gtk_messagebox(
				_("No snapshots on device"),
				_("Select another device to delete snapshots"),
				this, false);
			return;
		}

		// check if selected snapshot is live ------------------

		foreach(var bak in snapshot_list_box.selected_snapshots()){
			if (bak.live){
				string title = _("Cannot Delete Live Snapshot");
				string msg = _("Snapshot '%s' is being used by the system and cannot be deleted. Restart the system to activate the restored snapshot.").printf(bak.date_formatted);
				gtk_messagebox(title,msg,this,false);
				return;
			}
		}

		// confirm deletion ------------------

        var confirm_dialog = new CustomMessageDialog(
            _("Confirm Delete"),
            _("Are you sure you want to delete this snapshot?"),
            Gtk.MessageType.QUESTION,
            this,
            Gtk.ButtonsType.YES_NO
            );
        confirm_dialog.set_destructive();

        var confirm_response = confirm_dialog.run();

        if (confirm_response != Gtk.ResponseType.YES) {
            return;
        }

		// get selected snapshots

		if (!App.thread_delete_running){
			// check and add by name since snapshot_list would have changed
			foreach (var item in snapshot_list_box.selected_snapshots()){
				bool already_in_list = false;
				foreach(var bak in App.delete_list){
					if (bak.name == item.name){
						already_in_list = true;
						break;
					}
				}
				if (!already_in_list){
					App.delete_list.add(item);
				}
			}
		}

		log_debug("main window: delete_selected(): count=%d".printf(
			App.delete_list.size));

		// run wizard window ------------------

		ui_sensitive(false);
		
		var win = new DeleteWindow();
		win.set_transient_for(this);
		win.closed.connect(()=>{
			refresh_all();
			ui_sensitive(true);
		});
	}

	public void mark_selected(){

		bool is_success = true;

		// check selected count ----------------

		var selected = snapshot_list_box.selected_snapshots();

		if (selected.size == 0){
			
			gtk_messagebox(
				_("No Snapshots Selected"),
				_("Select the snapshots to mark for deletion"),
				this, false);
				
			return;
		}

		// get selected snapshots --------------------

		bool marked = false;

		foreach(var bak in selected){

			if (!is_success){ break; }

			// mark for deletion
			bak.mark_for_deletion();
			// have any snapshots been marked?
			marked = marked || bak.marked_for_deletion;
		}

		App.repo.load_snapshots();

		/* Whole sentences: a runtime-concatenated string never reaches the
		 * translation catalogue. */
		string title = marked ? _("Marked for deletion") : _("Unmarked for deletion");

		string message = marked
			? _("Snapshots will be removed during the next scheduled run")
			: _("Snapshots will not be removed during the next scheduled run");

		gtk_messagebox(title, message, this, false);

		snapshot_list_box.refresh();
	}

	// ---------------------------------------------------------------
	// snapshot browsing
	// ---------------------------------------------------------------

	// mount state, so a second browse reuses the first mount and exit can
	// unmount everything we made
	private Gee.ArrayList<string> browse_mounts = new Gee.ArrayList<string>();

	private bool thr_mount_running = false;
	private bool thr_mount_ok = false;
	private string thr_mount_cmd = "";
	private string thr_mount_err = "";

	/* Opens a path inside the snapshot repository in the user's file manager.
	 *
	 * Local repositories open the path directly.
	 *
	 * Remote ones prefer sftp:// when the desktop user already has a working
	 * GVFS mount for that host - that costs us nothing and uses their own
	 * session. Otherwise we mount the path ourselves with Timeshift's key,
	 * because the desktop user frequently has no credentials for the remote at
	 * all: the key lives in /etc/timeshift/ssh and only root can read it.
	 *
	 * Note the openers cannot confirm success - exec_user_async() returns as
	 * soon as the spawn works, not when a window appears - so we report
	 * failures to launch but never claim it opened. */
	private void browse_repo_path(string repo_path){

		if ((App.repo == null) || (App.repo.backend == null)){ return; }

		if (!App.repo.backend.is_remote){
			if (!exo_open_folder(repo_path, false)){
				gtk_messagebox(_("Could not open the file manager"),
					_("No file manager could be launched for") + ":\n%s".printf(repo_path),
					this, true);
			}
			return;
		}

		var backend = App.repo.backend as SshRepoBackend;
		if (backend == null){ return; }

		// 1. the user's own GVFS mount, if they have one
		if (user_has_gvfs_mount(backend)){
			string uri = App.repo.backend.browse_uri(repo_path);
			log_debug("browse via gvfs: %s".printf(uri));
			if (!xdg_open(uri)){
				gtk_messagebox(_("Could not open the file manager"),
					_("xdg-open is not available."), this, true);
			}
			return;
		}

		// 2. mount it ourselves using Timeshift's key
		if (!cmd_exists("sshfs")){
			offer_sshfs_install();
			return;
		}

		string mount_point = browse_mount_remote(backend, repo_path);

		if (mount_point.length == 0){ return; }

		if (!exo_open_folder(mount_point, false)){
			gtk_messagebox(_("Could not open the file manager"),
				_("The snapshot is mounted at") + ":\n%s".printf(mount_point),
				this, true);
		}
	}

	/* True when the desktop user already has this host mounted through GVFS,
	 * in which case sftp:// works with their own credentials.
	 *
	 * Deliberately not `cmd_exists("gio")`: gio ships with glib2 on every
	 * desktop whether or not the sftp backend is installed or usable, so that
	 * test always passed and the mount path below was never reached. */
	private bool user_has_gvfs_mount(SshRepoBackend backend){

		int uid = get_user_id();
		if (uid <= 0){ return false; }

		string gvfs_dir = "/run/user/%d/gvfs".printf(uid);
		if (!dir_exists(gvfs_dir)){ return false; }

		string needle = "host=%s".printf(backend.host);

		try{
			var dir = File.new_for_path(gvfs_dir);
			var iter = dir.enumerate_children(FileAttribute.STANDARD_NAME, 0);
			FileInfo info;
			while ((info = iter.next_file()) != null){
				string name = info.get_name();
				if (name.has_prefix("sftp:") && name.contains(needle)){
					log_debug("found gvfs mount: %s".printf(name));
					return true;
				}
			}
		}
		catch(Error e){
			log_debug(e.message);
		}

		return false;
	}

	private void offer_sshfs_install(){

		string package = "sshfs";
		string install_cmd = "";

		// Only offer to run an install for a package manager we recognise;
		// otherwise just name the package and let the user do it.
		switch ((App.current_distro == null) ? "" : App.current_distro.dist_type){
		case "debian":
			install_cmd = "apt-get install -y sshfs";
			break;
		case "redhat":
			package = "fuse-sshfs";
			install_cmd = "dnf install -y fuse-sshfs";
			break;
		case "arch":
			install_cmd = "pacman -S --noconfirm sshfs";
			break;
		}

		string msg = _("Browsing a remote snapshot needs the %s package, which is not installed.").printf(package);

		if (install_cmd.length == 0){
			msg += "\n\n" + _("Install it with your package manager and try again.");
			gtk_messagebox(_("sshfs is not installed"), msg, this, true);
			return;
		}

		msg += "\n\n" + _("Install it with") + ":\n    sudo %s".printf(install_cmd);
		msg += "\n\n" + _("Install it now?");

		var dlg = new CustomMessageDialog(_("sshfs is not installed"), msg,
			Gtk.MessageType.QUESTION, this, Gtk.ButtonsType.YES_NO);

		var resp = dlg.run();
		dlg.destroy();
		gtk_do_events();

		if (resp != Gtk.ResponseType.YES){ return; }

		string std_out, std_err;
		gtk_set_busy(true, this);
		int ret_val = exec_script_sync(install_cmd + "\nexit $?\n", out std_out, out std_err, true);
		gtk_set_busy(false, this);

		if ((ret_val != 0) || !cmd_exists("sshfs")){
			gtk_messagebox(_("Could not install %s").printf(package),
				(std_err == null) ? "" : std_err.strip(), this, true);
		}
	}

	/* Mounts a repository path read-only with Timeshift's key and returns the
	 * mount point, or "" with the reason already shown. */
	private string browse_mount_remote(SshRepoBackend backend, string repo_path){

		// one mount per path, so browsing a second snapshot does not collide
		// with the first
		string mount_point = path_combine(
			path_combine(App.mount_point_app, "browse"),
			Checksum.compute_for_string(ChecksumType.SHA1, repo_path).substring(0, 12));

		if (path_is_mounted(mount_point)){
			log_debug("reusing existing browse mount: %s".printf(mount_point));
			return mount_point;
		}

		dir_create(mount_point);

		int uid = get_user_id();
		int gid = uid;
		unowned Posix.Passwd? pw = Posix.getpwuid(uid);
		if (pw != null){ gid = (int) pw.pw_gid; }

		string cmd = backend.sshfs_command(repo_path, mount_point, uid, gid);

		if (cmd.length == 0){
			gtk_messagebox(_("Could not mount the remote snapshot"),
				backend.last_error, this, true);
			return "";
		}

		// on a worker thread: sshfs can block for ConnectTimeout, and this
		// runs from a button handler on the GTK main thread
		thr_mount_cmd = cmd;
		thr_mount_err = "";
		thr_mount_ok = false;
		thr_mount_running = true;

		try {
			new Thread<bool>.try("browse-mount", () => {
				string o, e;
				int r = exec_script_sync(thr_mount_cmd + "\nexit $?\n", out o, out e, true);
				thr_mount_ok = (r == 0);
				thr_mount_err = (e == null) ? "" : e.strip();
				thr_mount_running = false;
				return true;
			});
		}
		catch (Error e){
			thr_mount_running = false;
			log_error(e.message);
		}

		gtk_set_busy(true, this);
		while (thr_mount_running){
			gtk_do_events();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 100);
		}
		gtk_set_busy(false, this);

		// Trust /proc/mounts over the exit code: opening an empty directory as
		// if it were the snapshot would be worse than saying the mount failed.
		if (!thr_mount_ok || !path_is_mounted(mount_point)){
			gtk_messagebox(_("Could not mount the remote snapshot"),
				thr_mount_err, this, true);
			remove_mount_dir(mount_point);
			return "";
		}

		if (!browse_mounts.contains(mount_point)){
			browse_mounts.add(mount_point);
		}

		// With --fake-super the real ownership and mode live in xattrs, so what
		// the file manager shows is the remote account's, not the original's.
		// Say so once rather than quietly misrepresenting the snapshot.
		if (backend.fake_super && !browse_fake_super_warned){
			browse_fake_super_warned = true;
			gtk_messagebox(_("File ownership is not shown correctly"),
				_("This location stores ownership in extended attributes, so files here appear to belong to the remote account. The original ownership is preserved and restored correctly."),
				this, false);
		}

		return mount_point;
	}

	private bool browse_fake_super_warned = false;

	private bool path_is_mounted(string path){

		string? text = file_read("/proc/mounts");
		if (text == null){ return false; }

		foreach(string line in text.split("\n")){
			string[] parts = line.split(" ");
			// /proc/mounts escapes spaces and tabs as octal
			if ((parts.length > 1) && (parts[1].compress() == path)){ return true; }
		}

		return false;
	}

	/* Removes an empty browse mount point. Deliberately rmdir and not
	 * dir_delete: while the path is still mounted it resolves to the snapshot
	 * on the backup device, and a recursive delete would walk into the backup
	 * itself. rmdir refuses a non-empty directory, so it cannot do that. */
	private void remove_mount_dir(string mount_point){

		if (path_is_mounted(mount_point)){
			log_error(_("Still mounted, leaving in place") + ": %s".printf(mount_point));
			return;
		}

		exec_script_sync("rmdir '%s' 2>/dev/null\nexit 0\n".printf(
			escape_single_quote(mount_point)), null, null, true);
	}

	/* Unmounts everything browsing mounted. Called when the window closes, so
	 * a mount does not outlive the reason for it. */
	public void browse_unmount_all(){

		foreach(string mp in browse_mounts){
			if (!path_is_mounted(mp)){ continue; }
			string o, e;
			exec_script_sync("fusermount3 -u '%s' 2>/dev/null || fusermount -u '%s' 2>/dev/null || umount '%s'".printf(
				escape_single_quote(mp), escape_single_quote(mp), escape_single_quote(mp)),
				out o, out e, true);
			remove_mount_dir(mp);
		}

		browse_mounts.clear();
	}

	public void browse_selected(){

		var selected = snapshot_list_box.selected_snapshots();

		if (selected.size == 0){
			
			// For a remote repo, skip the existence probe: it is a full SSH
			// round trip on the GTK main thread and would stall the click for
			// up to ConnectTimeout. The snapshots dir is the right target
			// anyway, and a wrong one fails visibly at the mount.
			if (App.repo.backend.is_remote){
				browse_repo_path(App.repo.snapshots_path);
			}
			else if (dir_exists(App.repo.snapshots_path)){
				browse_repo_path(App.repo.snapshots_path);
			}
			else{
				browse_repo_path(App.repo.mount_path);
			}
			return;
		}

		var bak = selected[0];

		if (App.btrfs_mode){
			browse_repo_path(bak.path);
		}
		else{
			browse_repo_path(bak.path + "/localhost");
		}
	}

	public void view_snapshot_log(bool view_restore_log){
		
		var selected = snapshot_list_box.selected_snapshots();

		if (selected.size == 0){
			gtk_messagebox(
				_("Select Snapshot"),
				_("Please select a snapshot to view the log!"),
				this, false);
			return;
		}

		{
			{
				var bak = selected[0];

				string log_file_name = bak.rsync_log_file;
				if (view_restore_log){
					log_file_name = bak.rsync_restore_log_file;;
				}

				// A remote log has to be fetched before it can be parsed:
				// rsync's log parser reads it, and derives every item path
				// from the log's own parent directory, so both sides must
				// agree on the local copy.
				if (App.repo.backend.is_remote){

					string local_log = path_combine(TEMP_DIR,
						"%s-%s".printf(bak.name, view_restore_log ? "rsync-log-restore" : "rsync-log"));

					gtk_set_busy(true, this);
					bool fetched = App.repo.backend.download_file(log_file_name, local_log);
					gtk_set_busy(false, this);

					if (!fetched || !file_exists(local_log)){
						gtk_messagebox(
							_("Log not available"),
							_("Could not fetch the log from the remote location."),
							this, false);
						return;
					}

					log_file_name = local_log;
				}

				if (file_exists(log_file_name) || file_exists(log_file_name + "-changes")){

					this.visible = false;
					
					var win = new RsyncLogWindow(log_file_name);
					win.set_transient_for(this);
					win.closed.connect(()=>{
						this.visible = true;
					});
				}

				return;
			}
		}
	}

	private void btn_restore_clicked(){

		if (check_if_deletion_running()){
			return;
		}
		
		App.mirror_system = false;
		restore();
	}

	private bool check_if_deletion_running(){

		if (App.thread_delete_running){

			ui_sensitive(true);
			
			gtk_messagebox(
				_("Snapshot deletion in progress..."),
				_("Please wait for snapshots to be deleted."), this, true);
			
			ui_sensitive(false);
		
			var win = new DeleteWindow();
			win.set_transient_for(this);
			win.closed.connect(()=>{
				refresh_all();
				ui_sensitive(true);
			});
			
			return true;
		}

		return false;
	}


	private void restore(){

		if (!App.mirror_system){

			//check if single snapshot is selected -------------

			var selected = snapshot_list_box.selected_snapshots();

			if (selected.size == 0){
				gtk_messagebox(
					_("No snapshots selected"),
					_("Select the snapshot to restore"),
					this, false);
				return;
			}
			else if (selected.size > 1){
				gtk_messagebox(
					_("Multiple snapshots selected"),
					_("Select a single snapshot to restore"),
					this, false);
				return;
			}
			
			//get selected snapshot ------------------

			Snapshot snapshot_to_restore = selected[0];

			if ((snapshot_to_restore != null) && (snapshot_to_restore.marked_for_deletion)){
				
				gtk_messagebox(
					_("Invalid snapshot"),
					_("Selected snapshot is marked for deletion and cannot be restored"),
					this, false);
				return;
			}

			App.snapshot_to_restore = snapshot_to_restore;
		}
		else{
			App.snapshot_to_restore = null;
		}

		App.init_mount_list();
		
		//show restore window -----------------

		var window = new RestoreWindow();
		window.set_transient_for (this);
		//window.show_all();

		window.closed.connect(()=>{
			App.dry_run = false;
			App.repo.load_snapshots();
			refresh_all();
		});
	}

	private void btn_settings_clicked(){

		log_debug("MainWindow: btn_settings_clicked()");
		
		action_settings.set_enabled(false);
		action_wizard.set_enabled(false);

		this.visible = false;

		bool btrfs_mode_prev = App.btrfs_mode;
		
		var win = new SettingsWindow();
		win.set_transient_for(this);
		win.closed.connect(()=>{
			action_settings.set_enabled(!App.live_system());
			action_wizard.set_enabled(true);
			settings_changed(btrfs_mode_prev);
		});
	}

	private void btn_wizard_clicked(){

		log_debug("MainWindow: btn_wizard_clicked()");
		
		action_settings.set_enabled(false);
		action_wizard.set_enabled(false);

		this.visible = false;
		
		bool btrfs_mode_prev = App.btrfs_mode;
		
		var win = new SetupWizardWindow();
		win.set_transient_for(this);
		win.closed.connect(()=>{
			action_settings.set_enabled(!App.live_system());
			action_wizard.set_enabled(true);
			settings_changed(btrfs_mode_prev);
		});
	}

	private void settings_changed(bool btrfs_mode_prev){

		// A remote repo has no Device, so the branches below would fall through
		// to the btrfs/null case and silently discard a location the user just
		// configured, while backup_location_type stayed "ssh".
		if ((App.backup_location_type == "ssh")
			|| ((App.repo != null) && App.repo.backend.is_remote)){

			App.save_app_config();
			App.repo.load_snapshots();
			refresh_all();
			this.present();
			return;
		}

		if (btrfs_mode_prev != App.btrfs_mode){
			if ((App.repo != null) && (App.repo.device != null) && (App.repo.device.uuid.length > 0)){
				App.repo = new SnapshotRepo.from_uuid(App.repo.device.uuid, this, App.btrfs_mode);
			}
			else{
				if ((App.sys_root != null) && (App.sys_root.fstype == "btrfs")){
					App.repo = new SnapshotRepo.from_uuid(App.sys_root.uuid, this, App.btrfs_mode);
				}
				else{
					App.repo = new SnapshotRepo.from_null();
				}
			}
		}

		App.save_app_config();
		App.repo.load_snapshots();
		refresh_all();
		this.present();
	}

	private void btn_view_app_logs_clicked(){
		
		exo_open_folder(App.log_dir);
	}

	private void btn_about_clicked (){
		var dialog = new Gtk.AboutDialog();
		dialog.set_transient_for(this);
		dialog.set_program_name("Timeshift");
		dialog.set_comments(_("System Restore Utility"));
		dialog.set_copyright("Copyright © 2012-21 Tony George (%s)".printf(AppAuthorEmail));
		dialog.set_version(AppVersion);
		dialog.set_logo_icon_name("timeshift");
		dialog.set_license_type(Gtk.License.GPL_2_0);
		dialog.set_website_label("https://github.com/linuxmint/timeshift");
		dialog.set_website("https://github.com/linuxmint/timeshift");

		// this overwrites the default behaviour of About Dialog
		dialog.activate_link.connect(TeeJee.System.xdg_open);

		/* GTK4 removes Gtk.Dialog.run(); the about window closes itself. */
		dialog.set_modal(true);
		dialog.present();
	}

	private void ui_sensitive(bool enable){
		
		header.sensitive = enable;
		snapshot_list_box.treeview.sensitive = enable;
		gtk_set_busy(!enable, this);
	}

	private void update_statusbar(){
		
		App.repo.check_status();
		string message = App.repo.status_message;
		string details = App.repo.status_details;
		int status_code = App.repo.status_code;
		
		DateTime? last_snapshot_date = null;
		DateTime? oldest_snapshot_date = null;

		if (App.repo.has_snapshots()){
			string sys_uuid = (App.sys_root == null) ? "" : App.sys_root.uuid;
			var last_snapshot = App.repo.get_latest_snapshot("", sys_uuid);
			last_snapshot_date = (last_snapshot == null) ? null : last_snapshot.date;
			var oldest_snapshot = App.repo.get_oldest_snapshot("", sys_uuid);
			oldest_snapshot_date = (oldest_snapshot == null) ? null : oldest_snapshot.date;
		}

		if (App.live_system()){
			// nothing to count in restore-only mode
			tile_snapshots.visible = false;
			tile_free.visible = false;

			status_card.set_shield(IconManager.SHIELD_LIVE);
			status_card.set_title(_("Live USB Mode (Restore Only)"));
			status_card.set_subtitle("");

			switch (status_code){
			case SnapshotLocationStatus.NOT_SELECTED:
			case SnapshotLocationStatus.NOT_AVAILABLE:
			case SnapshotLocationStatus.NO_BTRFS_SYSTEM:
				status_card.set_subtitle(details);
				break;
			
			case SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE:
			case SnapshotLocationStatus.HAS_SNAPSHOTS_HAS_SPACE:
				status_card.set_subtitle(_("Snapshots available for restore"));
				break;

			case SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE:
			case SnapshotLocationStatus.NO_SNAPSHOTS_HAS_SPACE:
				status_card.set_subtitle(_("No snapshots found"));
				break;
			}
		}
		else{
			switch (status_code){
			case SnapshotLocationStatus.READ_ONLY_FS:
			case SnapshotLocationStatus.HARDLINKS_NOT_SUPPORTED:
			case SnapshotLocationStatus.NOT_SELECTED:
			case SnapshotLocationStatus.NOT_AVAILABLE:
			case SnapshotLocationStatus.NO_BTRFS_SYSTEM:
			case SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE:
			case SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE:
				status_card.set_shield(IconManager.SHIELD_LOW);
				status_card.set_title(message);
				status_card.set_subtitle(details);
				break;

			case SnapshotLocationStatus.NO_SNAPSHOTS_HAS_SPACE:
			case SnapshotLocationStatus.HAS_SNAPSHOTS_HAS_SPACE:
				// has space
				if (App.scheduled){
					// is scheduled
					if (App.repo.has_snapshots()){
						// has snaps
						status_card.set_shield(IconManager.SHIELD_HIGH);
						//status_card.set_title(_("System is protected"));
						status_card.set_title(_("Timeshift is active"));
						status_card.set_subtitle("%s: %s\n%s: %s".printf(
							_("Latest snapshot"),
							(last_snapshot_date == null) ? _("None") : last_snapshot_date.format(App.date_format),
							_("Oldest snapshot"),
							(oldest_snapshot_date == null) ? _("None") : oldest_snapshot_date.format(App.date_format)
							));
					}
					else{
						// no snaps
						status_card.set_shield(IconManager.SHIELD_HIGH);
						status_card.set_title(_("Timeshift is active"));
						status_card.set_subtitle(_("Snapshots will be created at selected intervals"));
					}
				}
				else {
					// not scheduled
					if (App.repo.has_snapshots()){
						// has snaps
						status_card.set_shield(IconManager.SHIELD_MED);
						status_card.set_title(_("Scheduled snapshots are disabled"));
						status_card.set_subtitle(_("Enable scheduled snapshots to protect your system"));
					}
					else{
						// no snaps
						status_card.set_shield(IconManager.SHIELD_LOW);
						status_card.set_title(_("No snapshots available"));
						status_card.set_subtitle(_("Create snapshots manually or enable scheduled snapshots to protect your system"));
					}
				}
				
				break;
			}

			tile_snapshots.visible = false;
			tile_free.visible = false;
			
			switch (status_code){
			case SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE:
			case SnapshotLocationStatus.NO_SNAPSHOTS_HAS_SPACE:
			case SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE:
			case SnapshotLocationStatus.HAS_SNAPSHOTS_HAS_SPACE:
				tile_snapshots.visible = true;
				tile_snapshots.set_value("%0d".printf(App.repo.snapshots.size));
				tile_snapshots.set_subnote(App.btrfs_mode ? "btrfs" : "rsync");

				tile_free.visible = true;
				tile_free.set_value(format_file_size(App.repo.free_bytes));

				string devname = _("unknown"); // was "(??)": ??) is a C trigraph for ]
				if (App.repo.backend.is_remote){
					devname = App.repo.backend.display_name;
				}
				else if ((App.repo != null) && (App.repo.device != null)){
					devname = "%s".printf(App.repo.device.device);
				}
				tile_free.set_subnote(devname);
				break;
			}
		}
	}

}
