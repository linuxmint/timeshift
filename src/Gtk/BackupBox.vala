/*
 * BackupBox.vala
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

class BackupBox : TaskProgressBox {

	private weak Gtk.Window parent_window; // back-reference: the window owns this box

	private bool thread_is_running = false;
	private bool thread_status_success = false;

	public BackupBox (Gtk.Window _parent_window) {

		base(_("Creating Snapshot..."), true);

		log_debug("BackupBox: BackupBox()");

		parent_window = _parent_window;

		lbl_deleted.sensitive = false;

		log_debug("BackupBox: BackupBox(): exit");
    }

	public void pause() {
		set_paused(true);
	}

	public void resume() {
		set_paused(false);
	}

	private DaemonBridge? bridge = null;

	public bool take_snapshot(){

		/* Hand the work to the daemon when there is one.
		 *
		 * Not an optimisation: a snapshot taken by the daemon has an id, and
		 * anyone else -- a second window, the CLI, apt-snapshot-guard -- can
		 * attach to it and watch. One taken in this process is visible only to
		 * this process, which is the defect the whole port exists to remove.
		 *
		 * attach_existing means clicking Create while apt is already
		 * snapshotting watches that job rather than queueing a second copy of
		 * the same moment.
		 *
		 * A daemon that is absent, stopped or speaking another protocol
		 * version falls through to the local core below and everything works
		 * exactly as it did. */
		bridge = new DaemonBridge();

		if (bridge.available() &&
			bridge.begin_create(App.cmd_comments, {"O"}, true)){

			thread_is_running = true;
			bridge.finished.connect((ok, msg) => {
				thread_status_success = ok;
				thread_is_running = false;
				if (!ok && (msg.length > 0)){
					log_error(msg);
				}
			});
		}
		else {
			bridge = null;
			try {
				thread_is_running = true;
				new Thread<void>.try ("snapshot-taker", () => {take_snapshot_thread();});
			}
			catch (Error e) {
				log_error (e.message);
				return false;
			}
		}

		if (App.btrfs_mode){
			
			while (thread_is_running){
				
				gtk_do_events();
				sleep(200);

				LauncherEntry.set_progress_pulse(true);
			}

			LauncherEntry.set_progress_pulse(false);
		}
		else{
			
			//string last_message = "";
			int wait_interval_millis = 100;
			int status_line_counter = 0;
			int status_line_counter_default = 1000 / wait_interval_millis;
			string status_line = "";
			string last_status_line = "";
			int remaining_counter = 10;

			while (thread_is_running){
                string task_status_line;
                double fraction;
                string task_stat_time_remaining;

				/* Snapshot the reference: the worker thread clears
				 * App.space_check_task the moment the space check ends, which
				 * would otherwise null it between this test and the reads. */
				var check_task = App.space_check_task;
				bool checking = (check_task != null);

				set_counts_visible(!checking);

                if (checking)
                {
                    task_status_line = check_task.status_line;
                    fraction = check_task.progress;
                    task_stat_time_remaining = check_task.stat_time_remaining;
                }
                else
                {
                    task_status_line = App.task.status_line;
                    fraction = App.task.progress;
                    task_stat_time_remaining = App.task.stat_time_remaining;
                }

				status_line = task_status_line;
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

				// time remaining
				remaining_counter--;
				if (remaining_counter == 0){
					lbl_remaining.label =
						task_stat_time_remaining + " " + _("remaining");

					remaining_counter = 10;
				}	
				
				if (fraction < 0.99){
					progressbar.fraction = fraction;
					LauncherEntry.set_progress((int)(fraction * 100.0));
				}

				if(App.task.status == AppStatus.PAUSED) {
					lbl_msg.label = _("Paused");
				} else {
					lbl_msg.label = App.progress_text;
				}

				if (!checking)
				{
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
				}

				gtk_do_events();

				sleep(100);
				//gtk_do_events();
			}

			LauncherEntry.set_progress(0);
		}

		return thread_status_success;

		//TODO: low: check if snapshot was created successfully.
	}
	
	private void take_snapshot_thread(){
		
		thread_status_success = App.create_snapshot(true,parent_window);
		thread_is_running = false;
	}
}
