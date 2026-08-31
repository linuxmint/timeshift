/*
 * RestoreWindow.vala
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

class RestoreWindow : WizardWindow {

	// tabs
	private RestoreDeviceBox restore_device_box;
	private RestoreSummaryBox summary_box;
	private RestoreBox check_box;
	private RsyncLogBox log_box;
	private RestoreBox restore_box;
	private UsersBox users_box;
	private SummaryBox finish_box;

	private uint tmr_init;
	private bool success = false;

	public bool check_before_restore = true;

	public RestoreWindow() {

		/* Taller than the other wizards: the restore page now carries a step
		 * checklist above the counts, and 560 px put the counts below the fold. */
		base(App.mirror_system ? _("Clone System") : _("Restore Snapshot"), 700, 680);

		log_debug("RestoreWindow: RestoreWindow()");

		restore_device_box = new RestoreDeviceBox(this);
		add_page(restore_device_box);

		check_box = new RestoreBox(this);
		add_page(check_box);

		log_box = new RsyncLogBox(this);
		add_page(log_box, false);

		var exclude_box = new ExcludeBox(this); // dummy - not used
		users_box = new UsersBox(this, exclude_box, true);
		add_page(users_box, false);

		summary_box = new RestoreSummaryBox(this);
		add_page(summary_box);

		restore_box = new RestoreBox(this);
		add_page(restore_box);

		finish_box = new SummaryBox(_("Completed"));
		add_page(finish_box);

		log_box.log_ready.connect(() => {
			if (aborted){ return; }
			if (notebook.page == Tabs.SHOW_LOG){
				set_actions(can_go_back(), true, false, true);
			}
		});

		btn_finish.label = _("Close");
		finish_is_primary = false;

		present();

		gtk_do_events();

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("RestoreWindow: RestoreWindow(): exit");
	}

	private bool init_delayed(){

		if (tmr_init > 0){
			Source.remove(tmr_init);
			tmr_init = 0;
		}

		go_first();

		return false;
	}

	// WizardWindow contract -------------------------------------------

	protected override bool handle_close(){
		save_changes();
		notify_closed();
		return false;
	}

	/* One Cancel. On a page that is doing work it asks first, because
	 * abandoning a restore leaves the target inconsistent; elsewhere it just
	 * closes. */
	protected override void on_cancel(){

		bool working = (notebook.page == Tabs.CHECK) || (notebook.page == Tabs.RESTORE);

		if (working && !App.dry_run){

			var title = _("Cancel restore?");

			var msg = _("Cancelling the restore process will leave the target system in an inconsistent state. The system may fail to boot or you may run into various issues. After cancelling, you need to restore another snapshot, to bring the system to a consistent state. Click Yes to confirm.");

			var dlg = new CustomMessageDialog(title, msg, Gtk.MessageType.ERROR, this, Gtk.ButtonsType.YES_NO);
			dlg.set_destructive();
			var response = dlg.run();
			dlg.destroy();

			if (response != Gtk.ResponseType.YES){
				return;
			}
		}

		if (working && (App.task != null)){
			App.task.stop(AppStatus.CANCELLED);
		}

		save_changes();
		close_wizard();
	}

	protected override void on_finish(){
		save_changes();
		close_wizard();
	}

	private Tabs[] route(){

		Tabs[] r = {};

		if (App.btrfs_mode){
			if ((App.snapshot_to_restore != null) && App.snapshot_to_restore.subvolumes.has_key("@home")){
				r += Tabs.USERS;
			}
		}
		else {
			r += Tabs.TARGET_DEVICE;
			if (check_before_restore){
				r += Tabs.CHECK;
				r += Tabs.SHOW_LOG;
			}
		}

		r += Tabs.SUMMARY;
		r += Tabs.RESTORE;
		r += Tabs.FINISH;

		return r;
	}

	private string tab_title(Tabs tab){

		switch (tab){
		case Tabs.TARGET_DEVICE: return _("Target Device");
		case Tabs.CHECK:         return _("Dry Run");
		case Tabs.SHOW_LOG:      return _("Confirm Actions");
		case Tabs.USERS:         return _("Users");
		case Tabs.SUMMARY:       return _("Summary");
		case Tabs.RESTORE:       return App.mirror_system ? _("Clone") : _("Restore");
		default:                 return _("Finished");
		}
	}

	protected override string[] step_titles(){

		string[] titles = {};
		foreach (var tab in route()){ titles += tab_title(tab); }
		return titles;
	}

	protected override int current_step(){

		var r = route();
		for (int i = 0; i < r.length; i++){
			if (r[i] == notebook.page){ return i; }
		}
		return -1;
	}

	private void save_changes(){

		App.cron_job_update();
	}

	// navigation ----------------------------------------------------

	private void go_first(){

		if (App.btrfs_mode){

			if (App.snapshot_to_restore.subvolumes.has_key("@home")){
				notebook.page = Tabs.USERS;
			}
			else {
				notebook.page = Tabs.SUMMARY;
			}
		}
		else{
			notebook.page = Tabs.TARGET_DEVICE;
		}

		initialize_tab();
	}

	/* Back is offered on the pages a user can reasonably reconsider from.
	 * Going back past the dry run means the check is re-run on Next. */
	protected override void go_prev(){

		switch(notebook.page){
		case Tabs.SHOW_LOG:
			notebook.page = Tabs.TARGET_DEVICE;
			break;

		case Tabs.SUMMARY:
			if (App.btrfs_mode){
				if ((App.snapshot_to_restore != null) && App.snapshot_to_restore.subvolumes.has_key("@home")){
					notebook.page = Tabs.USERS;
				}
				else {
					return;
				}
			}
			else if (check_before_restore){
				// the log is still on screen; do not re-open it
				notebook.page = Tabs.SHOW_LOG;
				update_step_label();
				set_actions(true, true, false, true);
				set_closable(true);
				return;
			}
			else {
				notebook.page = Tabs.TARGET_DEVICE;
			}
			break;

		default:
			return;
		}

		initialize_tab();
	}

	private bool can_go_back(){

		switch(notebook.page){
		case Tabs.SHOW_LOG:
			return true;
		case Tabs.SUMMARY:
			if (App.btrfs_mode){
				return (App.snapshot_to_restore != null) && App.snapshot_to_restore.subvolumes.has_key("@home");
			}
			return true;
		default:
			return false;
		}
	}

	protected override void go_next(){

		if (aborted){ return; }

		// finish any pending Gtk events before showing the next page
		gtk_set_busy(true, this);
		gtk_do_events();
		gtk_set_busy(false, this);

		if (!validate_current_tab()){
			return;
		}

		switch(notebook.page){
		case Tabs.TARGET_DEVICE:
			if (!App.btrfs_mode && check_before_restore){
				notebook.page = Tabs.CHECK;
			}
			else{
				notebook.page = Tabs.SUMMARY;
			}
			break;

		case Tabs.CHECK:
			notebook.page = Tabs.SHOW_LOG;
			break;

		case Tabs.SHOW_LOG:
			notebook.page = Tabs.SUMMARY;
			break;

		case Tabs.USERS:
			notebook.page = Tabs.SUMMARY;
			break;

		case Tabs.SUMMARY:
			notebook.page = Tabs.RESTORE;
			break;

		case Tabs.RESTORE:
			notebook.page = Tabs.FINISH;
			break;

		case Tabs.FINISH:
			close_wizard();
			break;
		}

		gtk_do_events();

		initialize_tab();
	}

	private void initialize_tab(){

		if (aborted || (notebook.page < 0)){ return; }

		log_debug("initialize_tab: %d".printf(notebook.page));

		// header first: CHECK and RESTORE block below
		update_step_label();

		switch(notebook.page){
		case Tabs.RESTORE:
		case Tabs.CHECK:
			set_actions(false, false, false, true);
			set_closable(false);
			break;

		case Tabs.TARGET_DEVICE:
		case Tabs.SUMMARY:
		case Tabs.USERS:
		case Tabs.SHOW_LOG:
			set_actions(can_go_back(), true, false, true);
			set_closable(true);
			break;

		case Tabs.FINISH:
			set_actions(false, false, true, false);
			set_closable(true);
			break;
		}

		gtk_do_events();

		// actions ---------------------------------------------------

		switch(notebook.page){
		case Tabs.TARGET_DEVICE:
			restore_device_box.refresh(false); // false: App.init_mount_list() will be called before this window is shown
			break;

		case Tabs.CHECK:
			App.dry_run = true;
			success = check_box.restore();
			if (aborted){ return; } // cancelled during the dry run

			/* The dry run just itemised every line the real run will print.
			 * That measured count is a far better denominator for the
			 * restore's progress bar than a guessed file count. */
			if (success){
				App.restore_line_count_estimate = App.task.status_line_count;
			}

			go_next();
			break;

		case Tabs.SHOW_LOG:
			// App.restore_log_file, not the snapshot-relative property: for a
			// remote repo the log is written locally under TEMP_DIR, and
			// checking the remote path made every remote restore report
			// "Error running Rsync" even on success. The two coincide for a
			// local repo, which is why this went unnoticed.
			if (file_exists(App.restore_log_file)){
				// parse_log_file() pumps the main loop; leaving Back/Next live
				// would let a second parser start over the same App.task
				set_actions(false, false, false, true);
				log_box.open_log(App.restore_log_file);
			}
			else{
				notebook.page = Tabs.FINISH;
				initialize_tab();
				show_finish(false, _("Error running Rsync"), "");
			}
			break;

		case Tabs.USERS:
			users_box.refresh();
			break;

		case Tabs.SUMMARY:
			summary_box.refresh();
			break;

		case Tabs.RESTORE:
			App.dry_run = false;
			success = restore_box.restore();
			if (aborted){ return; }
			go_next();
			break;

		case Tabs.FINISH:
			show_restore_outcome();
			// do not auto-close the restore window
			break;
		}

		gtk_do_events();
	}

	/* What actually happened, in the user's words.
	 *
	 * This page used to be show_finish(success, "", "") -- a bare bool with an
	 * empty header and an empty body, so a restore that copied everything and
	 * only failed to install a boot loader was indistinguishable from one that
	 * copied nothing, and both said "Completed With Errors" over the same
	 * boilerplate advice. */
	private void show_restore_outcome(){

		/* Whole msgids, not "Restore" + " " + "Failed": concatenated fragments
		 * cannot be reassembled in languages with a different word order. */
		string header;

		var lines = new Gee.ArrayList<string>();

		switch(App.restore_outcome){

		case Main.RestoreOutcome.FAILED:
			header = App.mirror_system ? _("Cloning Failed") : _("Restore Failed");
			break;

		case Main.RestoreOutcome.WARNINGS:
			header = App.mirror_system
				? _("Cloning Completed With Warnings") : _("Restore Completed With Warnings");
			break;

		default:
			header = App.mirror_system ? _("Cloning Completed") : _("Restore Completed");
			break;
		}

		foreach(string line in App.restore_outcome_messages){
			lines.add(line);
		}

		if (App.restore_outcome == Main.RestoreOutcome.OK){

			if (App.btrfs_mode && App.restore_current_system){
				lines.add(_("Restored subvolumes will become active after system is restarted."));
				lines.add(_("You can continue working on the current system. After restart, the current system will be visible as a new snapshot. This snapshot can be restored later if required, to 'undo' the restore."));
			}

			if (!App.btrfs_mode){
				lines.add(_("If the restored system fails to boot, then boot from the Live CD/USB, install Timeshift, and try restoring another snapshot."));
			}
		}

		/* Re-running is cheap and safe, and nothing said so: rsync is
		 * incremental and the transfer keeps a --partial-dir, so a second run
		 * continues instead of re-copying everything. Without this, cancelling
		 * a stalled restore looks like throwing away hours of work. */
		if (App.restore_outcome == Main.RestoreOutcome.FAILED){
			lines.add(_("Running the restore again resumes from where it stopped; the files already copied are kept."));
		}

		/* The step log is named only when something went wrong with a step --
		 * that is the one case where its contents matter, and it is what was
		 * missing when grub-install failed with nothing but an exit code. */
		if (App.restore_failed_step.length > 0){
			// the real path, not a hardcoded one: for a remote repository the
			// log lives wherever restore_log_file was actually placed
			lines.add(_("Step output: %s").printf(App.restore_steps_log_file()));
		}

		finish_box.set_header(header);
		finish_box.set_outcome(App.restore_outcome == Main.RestoreOutcome.OK);
		finish_box.set_bullets(lines.to_array());
		finish_box.set_footer(_("Close window to exit"));
	}

	private void show_finish(bool success, string message_header, string message_body){

		// header -----------------------------------------

		string txt = "";

		if (message_header.length > 0){
			txt = message_header;
		}
		else{
			txt = App.mirror_system ? _("Cloning") : _("Restore");
			txt += " " + (success ? _("Completed") : _("Completed With Errors"));
		}

		finish_box.set_header(txt);
		finish_box.set_outcome(success);

		// body -------------------------------------------

		if (message_body.length > 0){
			finish_box.set_body(message_body);
		}
		else {
			string[] lines = {};

			if (App.btrfs_mode && App.restore_current_system){
				lines += _("Restored subvolumes will become active after system is restarted.");
				lines += _("You can continue working on the current system. After restart, the current system will be visible as a new snapshot. This snapshot can be restored later if required, to 'undo' the restore.");
			}

			if (!App.btrfs_mode){
				lines += _("If the restored system fails to boot, then boot from the Live CD/USB, install Timeshift, and try restoring another snapshot.");
			}

			finish_box.set_bullets(lines);
		}

		finish_box.set_footer(_("Close window to exit"));
	}

	private bool validate_current_tab(){

		if (notebook.page == Tabs.TARGET_DEVICE){

			bool ok = restore_device_box.check_and_mount_devices();

			if (ok){
				App.add_app_exclude_entries();
			}

			return ok;
		}

		return true;
	}

	public enum Tabs{
		// indexes here should match the order in which tabs were added to Notebook
		TARGET_DEVICE = 0,
		CHECK = 1,
		SHOW_LOG = 2,
		USERS = 3,
		SUMMARY = 4,
		RESTORE = 5,
		FINISH = 6
	}
}
