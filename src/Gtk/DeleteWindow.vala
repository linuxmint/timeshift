/*
 * DeleteWindow.vala
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

class DeleteWindow : WizardWindow {

	// tabs
	private SnapshotListBox snapshot_list_box;
	private DeleteBox delete_box;
	private SummaryBox finish_box;

	private uint tmr_init;
	private bool success = false;

	/* The wizard starts at Delete when snapshots are already queued, so the
	 * step list depends on where it was entered. */
	private Tabs[] walked_route = {};

	public DeleteWindow() {

		base(_("Delete Snapshots"), 640, 520);

		log_debug("DeleteWindow: DeleteWindow()");

		add_page(build_select_page(), false);

		delete_box = new DeleteBox(this);
		add_page(delete_box);

		finish_box = new SummaryBox(_("Completed"));
		add_page(finish_box);

		// the select page's Next is the deletion itself
		lbl_next.label = _("Delete");
		btn_next.remove_css_class("suggested-action");
		btn_next.add_css_class("destructive-action");

		btn_finish.label = _("Close");
		finish_is_primary = false;

		present();

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("DeleteWindow: DeleteWindow(): exit");
	}

	private Gtk.Widget build_select_page(){

		var vbox = new Gtk.Box(Orientation.VERTICAL, Ui.Spacing.SM);

		Ui.add_title(vbox, _("Select Snapshots"));

		Ui.add_dim_label(vbox, _("Select the snapshots to be deleted"));

		snapshot_list_box = new SnapshotListBox(this);
		snapshot_list_box.hide_context_menu();
		snapshot_list_box.vexpand = true;
		vbox.append(snapshot_list_box);

		return vbox;
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

	protected override void on_cancel(){

		// clear queue
		App.delete_list.clear();

		// kill current task
		if (App.delete_file_task != null){
			if (!DaemonBridge.cancel_active()){
				App.delete_file_task.stop(AppStatus.CANCELLED);
			}
		}

		close_wizard();
	}

	protected override void on_finish(){
		close_wizard();
	}

	protected override string[] step_titles(){

		string[] titles = {};

		foreach (var tab in walked_route){
			switch (tab){
			case Tabs.SNAPSHOT_LIST: titles += _("Select"); break;
			case Tabs.DELETE:        titles += _("Delete"); break;
			default:                 titles += _("Finished"); break;
			}
		}

		return titles;
	}

	protected override int current_step(){

		for (int i = 0; i < walked_route.length; i++){
			if (walked_route[i] == notebook.page){ return i; }
		}
		return -1;
	}

	// navigation --------------------------------------------------------

	private void go_first(){

		if ((App.delete_list.size == 0) && !App.thread_delete_running){
			walked_route = { Tabs.SNAPSHOT_LIST, Tabs.DELETE, Tabs.DELETE_FINISH };
			notebook.page = Tabs.SNAPSHOT_LIST;
		}
		else {
			walked_route = { Tabs.DELETE, Tabs.DELETE_FINISH };
			notebook.page = Tabs.DELETE;
		}

		initialize_tab();
	}

	protected override void go_next(){

		if (aborted){ return; }

		if (!validate_current_tab()){
			return;
		}

		switch(notebook.page){
		case Tabs.SNAPSHOT_LIST:
			App.delete_list = snapshot_list_box.selected_snapshots();
			notebook.page = Tabs.DELETE;
			break;

		case Tabs.DELETE:
			notebook.page = Tabs.DELETE_FINISH;
			break;

		case Tabs.DELETE_FINISH:
			close_wizard();
			break;
		}

		initialize_tab();
	}

	private void initialize_tab(){

		if (aborted || (notebook.page < 0)){ return; }

		log_msg("");
		log_debug("page: %d".printf(notebook.page));

		update_step_label();

		switch(notebook.page){
		case Tabs.DELETE:
			// closing the window hides it; deletion continues in the background
			set_actions(false, false, false, true);
			set_closable(true);
			break;

		case Tabs.SNAPSHOT_LIST:
			set_actions(false, true, false, true);
			set_closable(true);
			break;

		case Tabs.DELETE_FINISH:
			set_actions(false, false, true, false);
			set_closable(true);
			break;
		}

		// actions

		switch(notebook.page){
		case Tabs.SNAPSHOT_LIST:
			snapshot_list_box.refresh();
			break;
		case Tabs.DELETE:
			success = delete_box.delete_snapshots();
			if (aborted){ return; } // window hidden/cancelled during deletion
			go_next();
			break;
		case Tabs.DELETE_FINISH:
			show_finish(success);
			gtk_wait(1000);
			close_wizard();
			break;
		}
	}

	private void show_finish(bool success){

		string txt = _("Snapshot(s) Deleted");
		if (!success){
			txt += " " + _("With Errors");
		}

		finish_box.set_header(txt);
		finish_box.set_outcome(success);
		finish_box.set_body("");
		finish_box.set_footer(_("Close window to exit"));
	}

	private bool validate_current_tab(){

		switch(notebook.page){
		case Tabs.SNAPSHOT_LIST:
			if (snapshot_list_box.selected_snapshots().size == 0){
				gtk_messagebox(
					_("No Snapshots Selected"),
					_("Select snapshots to delete"),
					this, false);
				return false;
			}
			else{
				return true;
			}

		default:
			return true;
		}
	}

	public enum Tabs{
		SNAPSHOT_LIST = 0,
		DELETE = 1,
		DELETE_FINISH = 2
	}
}
