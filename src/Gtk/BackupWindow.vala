/*
 * BackupWindow.vala
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

class BackupWindow : WizardWindow {

	// tabs
	private EstimateBox estimate_box;
	private BackupDeviceBox backup_dev_box;
	private BackupBox backup_box;
	private SummaryBox finish_box;

	// header actions
	private Gtk.Button btn_pause;
	private Gtk.Image img_pause;
	private Gtk.Label lbl_pause;

	private uint tmr_init;
	private bool success = false;

	/* Fixed at go_first(): the estimate changes Main.first_snapshot_size, so a
	 * recomputed route would renumber the steps underneath the user. */
	private Tabs[] walked_route = {};

	public BackupWindow() {

		base(_("Create Snapshot"), 560, 520);

		log_debug("BackupWindow: BackupWindow()");

		estimate_box = new EstimateBox(this);
		add_page(estimate_box);

		backup_dev_box = new BackupDeviceBox(this);
		add_page(backup_dev_box, false);

		backup_box = new BackupBox(this);
		add_page(backup_box);

		finish_box = new SummaryBox(_("Completed"));
		add_page(finish_box);

		create_pause_action();

		btn_finish.label = _("Close");
		finish_is_primary = false;

		present();

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("BackupWindow: BackupWindow(): exit");
	}

	private bool init_delayed(){

		if (tmr_init > 0){
			Source.remove(tmr_init);
			tmr_init = 0;
		}

		go_first();

		return false;
	}

	private void create_pause_action(){

		btn_pause = new Gtk.Button();
		var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		img_pause = new Gtk.Image.from_icon_name("media-playback-pause-symbolic");
		lbl_pause = new Gtk.Label(_("Pause"));
		box.append(img_pause);
		box.append(lbl_pause);
		btn_pause.set_child(box);
		btn_pause.visible = false;
		add_header_action(btn_pause, Gtk.PackType.END);

		btn_pause.clicked.connect(() => {
			if (App.task == null){ return; }
			if (App.task.status == AppStatus.PAUSED){
				App.task.resume();
				backup_box.resume();
				img_pause.icon_name = "media-playback-pause-symbolic";
				lbl_pause.label = _("Pause");
			}
			else {
				App.task.pause();
				backup_box.pause();
				img_pause.icon_name = "media-playback-start-symbolic";
				lbl_pause.label = _("Resume");
			}
		});
	}

	// WizardWindow contract -------------------------------------------

	protected override bool handle_close(){
		save_changes();
		notify_closed();
		return false;
	}

	protected override void on_cancel(){

		if (App.task != null){
			App.task.stop(AppStatus.CANCELLED);
		}

		// the Location page's Cancel is the old Close: it must still persist
		// whatever the user chose there
		save_changes();

		close_wizard();
	}

	protected override void on_finish(){
		save_changes();
		close_wizard();
	}

	/* Mirrors go_first() + go_next(): only the pages actually walked. */
	private Tabs[] route(){

		Tabs[] r = {};

		if (!App.btrfs_mode){
			if (Main.first_snapshot_size == 0){
				r += Tabs.ESTIMATE;
				r += Tabs.BACKUP_DEVICE;
			}
			else if (!App.repo.available() || !App.repo.has_space()){
				r += Tabs.BACKUP_DEVICE;
			}
		}

		r += Tabs.BACKUP;
		r += Tabs.BACKUP_FINISH;

		return r;
	}

	private string tab_title(Tabs tab){

		switch (tab){
		case Tabs.ESTIMATE:      return _("Estimate");
		case Tabs.BACKUP_DEVICE: return _("Location");
		case Tabs.BACKUP:        return _("Create");
		default:                 return _("Finished");
		}
	}

	protected override string[] step_titles(){

		string[] titles = {};
		foreach (var tab in walked_route){ titles += tab_title(tab); }
		return titles;
	}

	protected override int current_step(){

		for (int i = 0; i < walked_route.length; i++){
			if (walked_route[i] == notebook.page){ return i; }
		}
		return -1;
	}

	private void save_changes(){

		App.cron_job_update();
	}

	// navigation --------------------------------------------------------

	private void go_first(){

		walked_route = route();

		if (App.btrfs_mode){
			notebook.page = Tabs.BACKUP;
		}
		else{
			if (Main.first_snapshot_size == 0){
				notebook.page = Tabs.ESTIMATE;
			}
			else if (!App.repo.available() || !App.repo.has_space()){
				notebook.page = Tabs.BACKUP_DEVICE;
			}
			else{
				notebook.page = Tabs.BACKUP;
			}
		}

		initialize_tab();
	}

	protected override void go_next(){

		if (aborted){ return; }

		if (!validate_current_tab()){
			return;
		}

		switch(notebook.page){
		case Tabs.ESTIMATE:
			notebook.page = Tabs.BACKUP_DEVICE;
			break;
		case Tabs.BACKUP_DEVICE:
			notebook.page = Tabs.BACKUP;
			break;
		case Tabs.BACKUP:
			notebook.page = Tabs.BACKUP_FINISH;
			break;
		case Tabs.BACKUP_FINISH:
			close_wizard();
			break;
		}

		initialize_tab();
	}

	private void initialize_tab(){

		if (aborted || (notebook.page < 0)){ return; }

		log_msg("");
		log_debug("page: %d".printf(notebook.page));

		// header first: the pages below block while they work
		update_step_label();

		switch(notebook.page){
		case Tabs.ESTIMATE:
			set_actions(false, false, false, true);
			btn_pause.visible = false;
			set_closable(true);
			break;
		case Tabs.BACKUP:
			set_actions(false, false, false, true);
			btn_pause.visible = true;
			set_closable(false);
			break;
		case Tabs.BACKUP_DEVICE:
			set_actions(false, true, false, true);
			btn_pause.visible = false;
			set_closable(true);
			break;
		case Tabs.BACKUP_FINISH:
			set_actions(false, false, true, false);
			btn_pause.visible = false;
			set_closable(true);
			break;
		}

		// actions

		switch(notebook.page){
		case Tabs.ESTIMATE:
			estimate_box.estimate_system_size();
			if (aborted){ return; } // cancelled while the estimate ran
			go_next(); // validate and go next
			break;
		case Tabs.BACKUP_DEVICE:
			backup_dev_box.refresh();
			if (aborted){ return; }
			go_next(); // validate and go next
			break;
		case Tabs.BACKUP:
			success = backup_box.take_snapshot();
			if (aborted){ return; }
			go_next(); // close window
			break;
		case Tabs.BACKUP_FINISH:
			show_finish(success);
			if (App.repo.status_code == SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE){
				this.visible = false;
				gtk_messagebox(App.repo.status_message, App.repo.status_details, this, true);
				close_wizard();
			}
			else {
				gtk_wait(1000);
				close_wizard();
			}
			break;
		}
	}

	private void show_finish(bool success){

		string txt = _("Snapshot Created");
		if (!success){
			txt += " " + _("With Errors");
		}

		finish_box.set_header(txt);
		finish_box.set_outcome(success);
		finish_box.set_body("");
		finish_box.set_footer(_("Close window to exit"));
	}

	private bool validate_current_tab(){

		if (notebook.page == Tabs.BACKUP_DEVICE){
			if (!App.repo.available() || !App.repo.has_space()){

				gtk_messagebox(App.repo.status_message,
					App.repo.status_details, this, true);

				return false;
			}
		}

		return true;
	}

	public enum Tabs{
		ESTIMATE = 0,
		BACKUP_DEVICE = 1,
		BACKUP = 2,
		BACKUP_FINISH = 3
	}
}
