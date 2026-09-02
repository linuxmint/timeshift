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
	private DaemonBridge? daemon_bridge = null;
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

		/* Mirror the job into the fields every page here polls.
		 *
		 * This is the shim that lets the GUI stop being a second
		 * implementation. BackupBox, RestoreBox and DeleteBox do not observe
		 * anything -- they read App.task and App.progress_text from a loop --
		 * so filling those from the daemon's event stream makes them show work
		 * this process is not doing, without touching a line of their code.
		 *
		 * Only when nothing local is running. A backup started in this process
		 * owns App.task, and replacing it underneath would blank the counters
		 * of the operation the person is actually watching. */
		if ((daemon_bridge == null) && !local_work_running()){
			daemon_bridge = new DaemonBridge();
			if (!daemon_bridge.watch(job_id, kind)){
				daemon_bridge = null;
			}
			else {
				daemon_bridge.finished.connect(() => {
					daemon_bridge = null;
					hide_daemon_banner();
					refresh_all();
				});
			}
		}

		log_debug("MainWindow: the Timeshift service is running %s (%s)".printf(job_id, kind));

		daemon_banner.set_message(daemon_banner_text(kind), Gtk.MessageType.INFO);
	}

	/* True when this process is running an operation of its own.
	 *
	 * The daemon bridge must not take App.task away from it. */
	private bool local_work_running(){
		if (App.thread_delete_running){ return true; }
		if (App.task == null){ return false; }
		return (App.task.status == AppStatus.RUNNING) && (daemon_bridge == null);
	}

	private string daemon_banner_text(string kind){

		string what;

		switch (kind){
		case "create":
			what = _("A snapshot is being created by the Timeshift service.");
			break;
		case "delete":
			what = _("Snapshots are being deleted by the Timeshift service.");
			break;
		case "estimate":
			what = _("The Timeshift service is estimating the system size.");
			break;
		default:
			what = _("The Timeshift service is busy.");
			break;
		}

		/* Whole sentences reach the catalogue; a percentage appended to one
		 * does not need to be translated and must not be concatenated INTO
		 * it. Kept as a separate trailing fragment for that reason. */
		if ((daemon_bridge != null) && (App.task != null) && (App.task.progress > 0)){
			what += "  %.0f%%".printf(App.task.progress * 100.0);
		}

		return what;
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

	/* Refuse to start work the daemon is already doing, and offer to watch it
	 * instead.
	 *
	 * This is advisory. RepoLock is what actually prevents two Timeshifts
	 * writing one repository, and it would make this operation wait rather
	 * than corrupt anything. But waiting behind a job with no explanation
	 * looks like a hang, and the person almost always wanted to see the
	 * running snapshot rather than queue a second one. */
	private bool daemon_is_busy(string action){

		var client = App.daemon;
		if (client == null){ return false; }

		string job_id, kind;
		if (!client.running_job(out job_id, out kind)){ return false; }

		var title = _("Timeshift is already working");
		var msg = _("The Timeshift service is running an operation.") + "\n\n";
		msg += _("Show its progress instead of starting %s?").printf(action);

		var dlg = new CustomMessageDialog(
			title, msg, Gtk.MessageType.INFO, this, Gtk.ButtonsType.YES_NO);
		var response = dlg.run();
		dlg.destroy();

		if (response == Gtk.ResponseType.YES){
			show_daemon_job();
		}

		return true;
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

		/* A job belonging to the DAEMON is not stopped here.
		 *
		 * That is the whole point of the port: apt waits on a snapshot, and
		 * closing the window that happens to be watching it must not abandon
		 * it. Detach and leave it running -- the daemon outlives us. Only work
		 * running in THIS process is cancelled. */
		if (DaemonBridge.has_active_job()){
			if (daemon_bridge != null){
				daemon_bridge.detach();
				daemon_bridge = null;
			}
		}
		else {
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

		if (daemon_is_busy(_("a new snapshot"))){
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

		if (daemon_is_busy(_("a deletion"))){
			return;
		}
		
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


	/* Releases everything browsing mounted. Called when the window closes, so
	 * a mount does not outlive the reason for it.
	 *
	 * The daemon owns the mount, so it does the unmounting: browse_release
	 * refuses any path that is not under its own browse root, resolving
	 * symlinks first, which is what stops this from being an unmount-anything
	 * call over the socket. Only paths the daemon reported as mounted are in
	 * the list -- a local snapshot was never mounted and must not be released.
	 */
	public void browse_unmount_all(){

		var api = DaemonApi.get_shared();

		foreach(string mp in browse_mounts){
			if (api == null){
				log_debug("no daemon; leaving browse mount in place: %s".printf(mp));
				continue;
			}
			if (!api.snapshots_browse_release(mp)){
				log_debug("browse_release failed for %s: %s".printf(mp, api.last_error));
			}
		}

		browse_mounts.clear();
	}

	public void browse_selected(){

		var selected = snapshot_list_box.selected_snapshots();

		if (selected.size == 0){
			browse_repository_root();
			return;
		}

		browse_snapshot(selected[0]);
	}

	/* Opens one snapshot in the file manager.
	 *
	 * The daemon mounts, this side opens. That split is not arbitrary: the ssh
	 * key lives in /etc/timeshift/ssh and only root can read it, so the person
	 * at the keyboard usually cannot reach the host at all -- while opening a
	 * file manager needs their session, which the daemon does not have.
	 *
	 * A LOCAL snapshot is not mounted at all. It is already a directory on a
	 * mounted filesystem, and the daemon says so by returning mounted=false,
	 * which is also what stops a release from unmounting the repository.
	 */
	private void browse_snapshot(Snapshot bak){

		var api = DaemonApi.get_shared();
		if (api == null){
			gtk_messagebox(_("Browse Files"),
				_("The Timeshift service is not available."), this, true);
			return;
		}

		/* The uid the mount must be readable by is the DESKTOP user's, not
		 * ours: this process is root under pkexec, and the file manager it
		 * spawns is not. */
		int uid = get_user_id();
		int gid = get_group_id_from_uid(uid);

		gtk_set_busy(true, this);
		string path;
		bool mounted;
		bool ok = api.snapshots_browse(bak.name, uid, gid, out path, out mounted);
		gtk_set_busy(false, this);

		if (!ok || (path.length == 0)){
			gtk_messagebox(_("Could not open the snapshot"), api.last_error, this, true);
			return;
		}

		if (mounted && !browse_mounts.contains(path)){
			browse_mounts.add(path);
		}

		// btrfs keeps the subvolumes at the top; rsync puts the payload under
		// localhost.
		string target = App.btrfs_mode ? path : path_combine(path, "localhost");

		if (!exo_open_folder(target, false)){
			gtk_messagebox(_("Could not open the file manager"),
				_("The snapshot is available at") + ":\n%s".printf(target),
				this, true);
		}
	}

	/* The Browse button with nothing selected.
	 *
	 * Only a local repository, because there is no "browse the repository"
	 * method and inventing one to list a directory of snapshot names is a poor
	 * trade: the useful operation is browsing a snapshot, which is one click
	 * away. A remote repository says so rather than opening something wrong.
	 */
	private void browse_repository_root(){

		if ((App.repo == null) || (App.repo.backend == null)){ return; }

		if (App.repo.backend.is_remote){
			gtk_messagebox(_("Browse Files"),
				_("Select a snapshot to browse its files."), this, false);
			return;
		}

		string path = dir_exists(App.repo.snapshots_path)
			? App.repo.snapshots_path : App.repo.mount_path;

		if (!exo_open_folder(path, false)){
			gtk_messagebox(_("Could not open the file manager"),
				_("No file manager could be launched for") + ":\n%s".printf(path),
				this, true);
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

		var bak = selected[0];

		/* The daemon reads the log wherever it lives.
		 *
		 * This used to DOWNLOAD a remote log in full before parsing it locally
		 * -- a 22 MB file pulled over ssh so that a parser on this side could
		 * stat paths that do not exist on this side. log.parse takes the
		 * snapshot's name and reads it in place, so there is nothing to fetch
		 * and nothing to check for existence here: the daemon is the only
		 * party that can answer whether the log is there. */
		string log_name = view_restore_log ? "rsync-log-restore" : "rsync-log";
		string nominal = view_restore_log
			? bak.rsync_restore_log_file : bak.rsync_log_file;

		this.visible = false;

		var win = new RsyncLogWindow.for_snapshot(bak.name, log_name, nominal);
		win.set_transient_for(this);
		win.closed.connect(()=>{
			this.visible = true;
		});
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

		if (daemon_is_busy(_("a restore"))){
			return;
		}

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
