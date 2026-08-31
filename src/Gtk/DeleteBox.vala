/*
 * DeleteBox.vala
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

class DeleteBox : TaskProgressBox {

	private weak Gtk.Window parent_window; // back-reference: the window owns this box

	public DeleteBox (Gtk.Window _parent_window) {

		base(_("Deleting Snapshots..."), false);

		log_debug("DeleteBox: DeleteBox()");

		parent_window = _parent_window;

		// a pulse of the default size at a 100ms tick is frantic
		progressbar.pulse_step = 0.02;

		log_debug("DeleteBox: DeleteBox(): exit");
    }

	public bool delete_snapshots(){

		log_debug("DeleteBox: delete_snapshots()");

		if (!App.thread_delete_running){
			App.delete_begin();
		}

		/* btrfs deletes a subvolume at a time with nothing to count, so the
		 * only honest bar is a pulsing one; the message carries which
		 * snapshot of how many is going. */
		if (App.btrfs_mode){
			
			lbl_remaining.label = "";

			while (App.thread_delete_running){
				
				lbl_msg.label = App.progress_text;
				progressbar.pulse();
				gtk_do_events();
				sleep(200);

				LauncherEntry.set_progress_pulse(true);
			}

			LauncherEntry.set_progress_pulse(false);
		}
		else{
			
			int wait_interval_millis = 100;
			int status_line_counter = 0;
			int status_line_counter_default = 1000 / wait_interval_millis;
			string status_line = "";
			string last_status_line = "";
			int remaining_counter = 10;
			
			while (App.thread_delete_running){

				/* Taken once per pass: the delete thread swaps in the next
				 * snapshot's task between snapshots. */
				var task = App.delete_file_task;

				if (task == null){
					gtk_do_events();
					sleep(100);
					continue;
				}

				/* An empty read means the task's mutex was busy, not that
				 * there is nothing to show - keep the last line instead of
				 * blinking it away. The decay below still clears a line that
				 * has genuinely gone stale. */
				status_line = task.status_line;

				if ((status_line.length > 0) && (status_line != last_status_line)){
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

				remaining_counter--;

				if (task.prg_count_total > 0){

					double fraction = task.progress;

					if (remaining_counter == 0){
						lbl_remaining.label = task.stat_time_remaining + " " + _("remaining");
					}

					if (fraction < 0.99){
						progressbar.fraction = fraction;

						LauncherEntry.set_progress((int)(fraction * 100.0));
					}
				}
				else {
					/* No file count for this snapshot, so a fraction would be
					 * a fiction: pulse and report what has gone so far. */
					progressbar.pulse();

					if (remaining_counter == 0){
						lbl_remaining.label = _("%lld items removed").printf(task.status_line_count);
					}

					LauncherEntry.set_progress_pulse(true);
				}

				if (remaining_counter == 0){
					remaining_counter = 10;
				}

				lbl_msg.label = App.progress_text;

				gtk_do_events();

				sleep(100);
			}

			LauncherEntry.set_progress_pulse(false);
			LauncherEntry.set_progress(0);
		}
		
		//parent_window.destroy();

		return App.thread_delete_success;
	}
}
