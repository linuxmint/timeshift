/*
 * SetupWizardWindow.vala
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

class SetupWizardWindow : WizardWindow {

	// tabs
	private SnapshotBackendBox backend_box;
	private EstimateBox estimate_box;
	private BackupDeviceBox backup_dev_box;
	private SummaryBox finish_box;
	private ScheduleBox schedule_box;
	private UsersBox users_box;

	private bool schedule_accepted = false;

	private uint tmr_init;

	public SetupWizardWindow() {

		base(_("Setup Wizard"), 640, 560);

		log_debug("SetupWizardWindow: SetupWizardWindow()");

		if (App.first_run && !schedule_accepted){
			App.schedule_boot = false;
			App.schedule_hourly = false;
			App.schedule_daily = true; // set
			log_debug("Setting schedule_daily for first run");
			App.schedule_weekly = false;
			App.schedule_monthly = false;
		}

		backend_box = new SnapshotBackendBox(this);
		add_page(backend_box);

		estimate_box = new EstimateBox(this);
		add_page(estimate_box);

		backup_dev_box = new BackupDeviceBox(this);
		add_page(backup_dev_box, false);

		schedule_box = new ScheduleBox(this);
		add_page(schedule_box);

		var exclude_box = new ExcludeBox(this);
		users_box = new UsersBox(this, exclude_box, false);
		add_page(users_box, false);

		finish_box = new SummaryBox(_("Setup Complete"));
		add_page(finish_box);

		present();

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("SetupWizardWindow: SetupWizardWindow(): exit");
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

		if (App.first_run && !schedule_accepted){
			App.schedule_boot = false;
			App.schedule_hourly = false;
			App.schedule_daily = false; // unset
			App.schedule_weekly = false;
			App.schedule_monthly = false;
		}

		save_changes();

		notify_closed();

		return false; // close window
	}

	protected override void on_cancel(){

		if (App.task != null){
			if (!DaemonBridge.cancel_active()){
				App.task.stop(AppStatus.CANCELLED);
			}
		}

		close_wizard();
	}

	protected override void on_finish(){
		save_changes();
		close_wizard();
	}

	private Tabs[] route(){

		Tabs[] r = {};

		r += Tabs.SNAPSHOT_BACKEND;
		if (!App.btrfs_mode){ r += Tabs.ESTIMATE; }
		r += Tabs.BACKUP_DEVICE;
		if (!App.live_system()){
			r += Tabs.SCHEDULE;
			r += Tabs.USERS;
			r += Tabs.FINISH;
		}

		return r;
	}

	private string tab_title(Tabs tab){

		switch (tab){
		case Tabs.SNAPSHOT_BACKEND: return _("Snapshot Type");
		case Tabs.ESTIMATE:         return _("Estimate");
		case Tabs.BACKUP_DEVICE:    return _("Location");
		case Tabs.SCHEDULE:         return _("Schedule");
		case Tabs.USERS:            return _("Users");
		default:                    return _("Finished");
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


		App.first_run = false;
	}

	// navigation --------------------------------------------------------

	private void go_first(){

		notebook.page = Tabs.SNAPSHOT_BACKEND;

		initialize_tab();
	}

	protected override void go_prev(){

		switch(notebook.page){
		case Tabs.SNAPSHOT_BACKEND:
		case Tabs.ESTIMATE:
			// Back is hidden for these pages
			break;
		case Tabs.BACKUP_DEVICE:
			notebook.page = Tabs.SNAPSHOT_BACKEND;
			break;
		case Tabs.SCHEDULE:
			notebook.page = Tabs.BACKUP_DEVICE;
			break;
		case Tabs.USERS:
			notebook.page = Tabs.SCHEDULE;
			break;
		case Tabs.FINISH:
			notebook.page = Tabs.USERS;
			break;
		}

		initialize_tab();
	}

	protected override void go_next(){

		if (aborted){ return; }

		if (!validate_current_tab()){
			return;
		}

		switch(notebook.page){
		case Tabs.SNAPSHOT_BACKEND:
			if (App.btrfs_mode){
				notebook.page = Tabs.BACKUP_DEVICE;
			}
			else{
				notebook.page = Tabs.ESTIMATE; // rsync mode only
			}
			break;

		case Tabs.ESTIMATE:
			notebook.page = Tabs.BACKUP_DEVICE;
			break;

		case Tabs.BACKUP_DEVICE:
			if (App.live_system()){
				close_wizard();
			}
			else{
				notebook.page = Tabs.SCHEDULE;
			}
			break;

		case Tabs.SCHEDULE:
			notebook.page = Tabs.USERS;
			schedule_accepted = true;
			break;

		case Tabs.USERS:
			notebook.page = Tabs.FINISH;
			break;

		case Tabs.FINISH:
			// Next is hidden for this page
			break;
		}

		initialize_tab();
	}

	private void initialize_tab(){

		if (aborted || (notebook.page < 0)){
			return;
		}

		log_msg("");
		log_debug("page: %d".printf(notebook.page));

		update_step_label();

		// Finish is always available: closing the wizard early keeps whatever
		// has been chosen so far, exactly as the window's close button does.
		switch(notebook.page){
		case Tabs.SNAPSHOT_BACKEND:
			set_actions(false, true, true, false);
			break;
		case Tabs.ESTIMATE:
			set_actions(false, false, false, false);
			break;
		case Tabs.BACKUP_DEVICE:
		case Tabs.SCHEDULE:
		case Tabs.USERS:
			set_actions(true, true, true, false);
			break;
		case Tabs.FINISH:
			set_actions(true, false, true, false);
			break;
		}

		// actions

		switch(notebook.page){
		case Tabs.SNAPSHOT_BACKEND:
			backend_box.refresh();
			break;
		case Tabs.ESTIMATE:
			if (App.btrfs_mode){
				go_next();
			}
			else{
				estimate_box.estimate_system_size();
				if (aborted){ return; } // closed while the estimate ran
				go_next();
			}
			break;
		case Tabs.BACKUP_DEVICE:
			backup_dev_box.refresh();
			break;
		case Tabs.SCHEDULE:
			schedule_box.update_statusbar();
			break;
		case Tabs.USERS:
			users_box.refresh();
			break;
		case Tabs.FINISH:
			show_finish();
			break;
		}
	}

	private void show_finish(){

		string[] lines = {};

		if (App.scheduled){
			lines += _("Scheduled snapshots are enabled. Snapshots will be created automatically for selected levels.");
		}
		else{
			lines += _("Scheduled snapshots are disabled. It's recommended to enable it.");
		}

		lines += _("System can be rolled-back to a previous date by restoring a snapshot.");

		if (App.btrfs_mode){
			lines += _("Restoring a snapshot will replace system subvolumes, and system subvolumes currently in use will be preserved as a new snapshot. If required, this snapshot can be restored later to 'undo' the restore.");
		}
		else{
			lines += _("Restoring snapshots only replaces system files and settings. Non-hidden files and directories in user home directories will not be touched. This behaviour can be changed by adding a filter to include these files. Included files will be backed up when snapshot is created, and replaced when snapshot is restored.");
		}

		if (App.btrfs_mode){
			lines += _("BTRFS snapshots are saved on the same disk from which it is created. If the system disk fails, snapshots will be lost along with the system. Save snapshots to an external non-system disk in RSYNC mode to guard against disk failures.");
		}
		else{
			lines += _("Save snapshots to an external disk instead of the system disk to guard against drive failures.");
			lines += _("Saving snapshots to a non-system disk allows you to format and re-install the OS on the system disk without losing snapshots stored on it. You can even install another Linux distribution and later roll-back the previous distribution by restoring a snapshot.");
		}

		finish_box.set_outcome(true);
		finish_box.set_bullets(lines);
		finish_box.set_footer(_("Close window to exit"));
	}

	private bool validate_current_tab(){

		if (notebook.page == Tabs.SNAPSHOT_BACKEND){
			return true;
		}
		else if (notebook.page == Tabs.BACKUP_DEVICE){
			if (!App.repo.available() || !App.repo.has_space()){

				gtk_messagebox(App.repo.status_message,
					App.repo.status_details, this, true);

				return false;
			}
		}

		return true;
	}

	public enum Tabs{
		SNAPSHOT_BACKEND = 0,
		ESTIMATE = 1,
		BACKUP_DEVICE = 2,
		SCHEDULE = 3,
		USERS = 4,
		FINISH = 5
	}
}
