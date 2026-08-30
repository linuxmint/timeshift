/*
 * RestoreBox.vala
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

class RestoreBox : Gtk.Box{

	private TaskProgressBox progress;

	public Gtk.Label lbl_header;
	public Gtk.Label lbl_msg;
	public Gtk.Label lbl_status;
	public Gtk.Label lbl_remaining;
	public Gtk.ProgressBar progressbar;
	public Gtk.Label lbl_unchanged;
	public Gtk.Label lbl_created;
	public Gtk.Label lbl_deleted;
	public Gtk.Label lbl_modified;
	public Gtk.Label lbl_checksum;
	public Gtk.Label lbl_size;
	public Gtk.Label lbl_timestamp;
	public Gtk.Label lbl_permissions;
	public Gtk.Label lbl_owner;
	public Gtk.Label lbl_group;

	private Gtk.Window parent_window;

	private bool thread_is_running = false;

	public RestoreBox(Gtk.Window _parent_window) {

		log_debug("RestoreBox: RestoreBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		progress = new TaskProgressBox(
			App.dry_run ? _("Comparing Files (Dry Run)...") : _("Restoring Snapshot..."), true);
		append(progress);

		lbl_header = progress.lbl_header;
		lbl_msg = progress.lbl_msg;
		lbl_status = progress.lbl_status;
		lbl_remaining = progress.lbl_remaining;
		progressbar = progress.progressbar;
		lbl_unchanged = progress.lbl_unchanged;
		lbl_created = progress.lbl_created;
		lbl_deleted = progress.lbl_deleted;
		lbl_modified = progress.lbl_modified;
		lbl_checksum = progress.lbl_checksum;
		lbl_size = progress.lbl_size;
		lbl_timestamp = progress.lbl_timestamp;
		lbl_permissions = progress.lbl_permissions;
		lbl_owner = progress.lbl_owner;
		lbl_group = progress.lbl_group;

		log_debug("RestoreBox: RestoreBox(): exit");
    }

	public bool restore(){

		log_debug("RestoreBox: restore()");
		
		if (App.restore_current_system && !App.dry_run){
			parent_window.visible = false;
		}

		progress.set_header(App.dry_run ? _("Comparing Files (Dry Run)...") : _("Restoring Snapshot..."));
		
		try {
			thread_is_running = true;
			new Thread<void>.try ("restore", () => {restore_thread();});
		}
		catch (Error e) {
			log_error (e.message);
		}

		//string last_message = "";
		int wait_interval_millis = 100;
		int status_line_counter = 0;
		int status_line_counter_default = 1000 / wait_interval_millis;
		string status_line = "";
		string last_status_line = "";
		int remaining_counter = 10;
		
		while (thread_is_running){

			status_line = escape_html(App.task.status_line);
			
			if (status_line != last_status_line){
				
				lbl_status.label = status_line;
				last_status_line = status_line;
				status_line_counter = status_line_counter_default;
			}
			else{
				status_line_counter--;
				
				if (status_line_counter < 0){
					status_line_counter = status_line_counter_default;
					lbl_status.label = "";
				}
			}

			// TODO: show estimated time remaining and file counts

			double fraction = App.task.progress;

			// time remaining
			remaining_counter--;
			
			if (remaining_counter == 0){
				
				lbl_remaining.label = App.task.stat_time_remaining + " " + _("remaining");

				remaining_counter = 10;
			}	
			
			if (fraction < 0.99){
				
				progressbar.fraction = fraction;

				LauncherEntry.set_progress((int)(fraction * 100.0));
			}

			lbl_msg.label = App.progress_text;

			lbl_unchanged.label = "%'d".printf(App.task.count_unchanged);
			lbl_created.label = "%'d".printf(App.task.count_created);
			lbl_deleted.label = "%'d".printf(App.task.count_deleted);
			lbl_modified.label = "%'d".printf(App.task.count_modified);
			lbl_checksum.label = "%'d".printf(App.task.count_checksum);
			lbl_size.label = "%'d".printf(App.task.count_size);
			lbl_timestamp.label = "%'d".printf(App.task.count_timestamp);
			lbl_permissions.label = "%'d".printf(App.task.count_permissions);
			lbl_owner.label = "%'d".printf(App.task.count_owner);
			lbl_group.label = "%'d".printf(App.task.count_group);

			gtk_do_events();

			sleep(100);
			//gtk_do_events();
		}

		LauncherEntry.set_progress(0);
		
		if (App.restore_current_system && !App.dry_run){
			parent_window.visible = true;
		}

		log_debug("RestoreBox: restore(): exit");

		return (App.task.exit_code == 0);
	}
	
	private void restore_thread(){
		
		log_debug("RestoreBox: restore_thread()");
		App.restore_snapshot(parent_window);
		thread_is_running = false;
		log_debug("RestoreBox: restore_thread(): exit");
	}
}
