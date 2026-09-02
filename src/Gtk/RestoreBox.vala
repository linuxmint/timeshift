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

/* The wizard's restore page, and the driver behind both restore views.
 *
 * Restoring over the running system takes over the screen: the wizard goes
 * away and RestoreProgressWindow appears, because there is no going back and
 * nothing else to do until it finishes. Restoring anywhere else - and the dry
 * run - stays on this page. Either way the work happens on a worker thread and
 * this loop, on the main thread, is the only thing that touches widgets. */

class RestoreBox : RestoreProgressBox {

	private weak Gtk.Window parent_window; // back-reference: the window owns this box

	private bool thread_is_running = false;

	/* Where the polling loop writes: this page, or the full-screen window's
	 * copy of it. */
	private RestoreProgressBox view;

	private RestoreProgressWindow? fullscreen_win = null;

	/* The checklist currently on screen. Compared by identity: Core publishes
	 * a finished list in one assignment, so a new reference means new steps. */
	private Gee.ArrayList<RestorePhase>? phases_shown = null;

	public RestoreBox(Gtk.Window _parent_window) {

		base(App.dry_run ? _("Comparing Files (Dry Run)...") : _("Restoring Snapshot..."), false);

		log_debug("RestoreBox: RestoreBox()");

		parent_window = _parent_window;

		view = this;

		log_debug("RestoreBox: RestoreBox(): exit");
    }

	public bool restore(){

		log_debug("RestoreBox: restore()");

		// the debug terminal takes the screen itself; do not stack two windows
		bool takeover = App.restore_current_system && !App.dry_run
			&& !App.restore_uses_terminal();

		string header = App.dry_run ? _("Comparing Files (Dry Run)...") : _("Restoring Snapshot...");

		if (takeover){

			/* Built and shown from the main thread, before any worker
			 * starts. The wizard hides behind it and comes back only if the
			 * restore returns instead of rebooting. */
			fullscreen_win = new RestoreProgressWindow(parent_window, header);
			fullscreen_win.is_running = true;
			view = fullscreen_win.box;

			if (App.snapshot_to_restore != null){
				view.set_subtitle("%s ~ %s".printf(
					App.snapshot_to_restore.name, App.snapshot_to_restore.description));
			}

			view.set_banner(
				_("Do not turn off your computer. It will restart by itself once the restore is finished."),
				Gtk.MessageType.WARNING);

			fullscreen_win.present();
			parent_window.visible = false;
		}
		else{
			view = this;
			set_header(header);

			if (App.restore_current_system && !App.dry_run){
				// the terminal is about to cover everything anyway
				parent_window.visible = false;
			}

			if (!App.dry_run){
				view.set_banner(
					_("Do not interrupt the restore. The target system stays inconsistent until it finishes."),
					Gtk.MessageType.WARNING);
			}
		}

		view.clear_log();
		phases_shown = null;

		gtk_do_events();

		/* The daemon owns the restore when it can.
		 *
		 * The local core below is still reached when no daemon is running,
		 * which during the migration is an ordinary state. Both paths write
		 * the same fields, because every polling loop in this file reads
		 * App.task and App.restore_* rather than observing anything. */
		bridge = new DaemonBridge();

		if (bridge.available() && begin_restore_via_daemon()){

			thread_is_running = true;

			bridge.finished.connect((ok, msg) => {
				thread_is_running = false;
			});
		}
		else {
			bridge = null;

			try {
				thread_is_running = true;
				new Thread<void>.try ("restore", () => {restore_thread();});
			}
			catch (Error e) {
				log_error (e.message);
			}
		}

		//string last_message = "";
		int wait_interval_millis = 100;
		int status_line_counter = 0;
		int status_line_counter_default = 1000 / wait_interval_millis;
		string status_line = "";
		string last_status_line = "";
		int remaining_counter = 10;
		
		while (thread_is_running){

			status_line = App.task.status_line;
			
			if (status_line != last_status_line){
				
				view.lbl_status.label = status_line;
				last_status_line = status_line;
				status_line_counter = status_line_counter_default;
			}
			else{
				status_line_counter--;
				
				if (status_line_counter < 0){
					status_line_counter = status_line_counter_default;
					view.lbl_status.label = "";
				}
			}

			double fraction = App.task.progress;

			// time remaining
			remaining_counter--;
			
			if (remaining_counter == 0){
				
				view.lbl_remaining.label = App.task.stat_time_remaining + " " + _("remaining");

				remaining_counter = 10;
			}	
			
			if (fraction < 0.99){
				
				view.progressbar.fraction = fraction;

				LauncherEntry.set_progress((int)(fraction * 100.0));
			}

			/* A dropped link must not look like a hang. While the script is
			 * waiting for the snapshot location to answer, say so instead of
			 * leaving the last progress line frozen on screen -- that stale
			 * frame is exactly what makes a working retry look like a crash. */
			var rtask = App.restore_script_task;
			if ((rtask != null) && (rtask.reconnect_status.length > 0)){
				view.lbl_msg.label = reconnect_message(rtask);
			}
			else {
				view.lbl_msg.label = App.progress_text;
			}

			view.update_counts(App.task);

			// the checklist is only known once the scripts have been written
			refresh_phases();

			view.set_phase(App.restore_phase);

			drain_output();

			gtk_do_events();

			sleep(100);
			//gtk_do_events();
		}

		drain_output();

		// whatever the script did not announce, it got through
		if (App.task.exit_code == 0){
			view.complete_phases();
		}

		LauncherEntry.set_progress(0);

		if (fullscreen_win != null){
			fullscreen_win.finish();
			fullscreen_win = null;
			view = this;
		}

		if (App.restore_current_system && !App.dry_run){
			parent_window.visible = true;
		}

		log_debug("RestoreBox: restore(): exit");

		/* The dry run has no outcome of its own -- it only measures. The real
		 * run reports what Main decided, which is the only thing that knows
		 * the difference between a lost transfer and a failed bootloader step;
		 * App.task.exit_code alone could not tell them apart. */
		if (App.dry_run){
			return (App.task.exit_code == 0);
		}

		return (App.restore_outcome != Main.RestoreOutcome.FAILED);
	}

	/* What the restore is waiting for, and for how long.
	 *
	 * The old banner was a fixed "Connection lost - reconnecting (3)", which
	 * looks exactly like a hang: no way to tell a working retry from a stuck
	 * one, and nothing to say whether the work already done is safe. */
	private string reconnect_message(RestoreScriptTask task){

		/* One whole msgid; the parenthetical detail is data, assembled first. */
		string detail = task.reconnect_status;

		if (task.reconnect_since != null){

			var elapsed = (int) (new DateTime.now_local().difference(task.reconnect_since)
				/ GLib.TimeSpan.SECOND);

			if (elapsed > 0){
				detail += ", %s".printf(format_duration_short(elapsed));
			}
		}

		string msg = _("Connection lost - reconnecting (attempt %s)").printf(detail);

		string meaning = App.rsync_exit_meaning_public(task.reconnect_code);
		if (meaning.length > 0){
			msg += " - " + meaning;
		}

		// cancelling here is safe, and that is not otherwise obvious
		msg += "\n" + _("The transfer resumes where it stopped; nothing already copied is lost.");

		return msg;
	}

	/* Deliberately untranslated: "5m 12s" is technical notation, and a bare
	 * format string makes a meaningless msgid. */
	private string format_duration_short(int seconds){

		if (seconds < 60){
			return "%ds".printf(seconds);
		}

		return "%dm %ds".printf(seconds / 60, seconds % 60);
	}

	/* The steps are decided by create_restore_scripts(), which runs on the
	 * worker thread, so the list appears a moment after the page does. */
	private void refresh_phases(){

		if (App.restore_phases == phases_shown){ return; }

		phases_shown = App.restore_phases;
		view.set_phases(phases_shown);
	}

	/* Raw output comes from whichever task is producing it: the rsync task
	 * during the sync, the script task during the bootloader and hook steps.
	 * On a current-system restore they are the same object. */
	private void drain_output(){

		var rsync_task = App.task;

		if (rsync_task != null){
			view.append_log(rsync_task.drain_output());
		}

		var script_task = App.restore_script_task;

		if ((script_task != null) && (script_task != rsync_task)){
			view.append_log(script_task.drain_output());
		}
	}

	private DaemonBridge? bridge = null;

	/* Hands the daemon everything the wizard collected.
	 *
	 * The mount selection travels WHOLE rather than as a patch: the daemon
	 * builds the default from the snapshot's own fstab when it is given
	 * nothing, so sending half a selection would silently mix two plans. */
	private bool begin_restore_via_daemon(){

		if (App.snapshot_to_restore == null){ return false; }

		var mounts = new Gee.HashMap<string,string>();
		foreach (var entry in App.mount_list){
			if (entry.mount_point.length == 0){ continue; }
			// An entry with no device is deliberately left on the root
			// filesystem, which the daemon spells as the empty string.
			mounts.set(entry.mount_point,
				(entry.device == null) ? "" : entry.device.device);
		}

		/* skip_grub is the inverse of the checkbox, and the two other steps
		 * are sent as themselves. They used to be hard-coded true in the
		 * daemon, which made those checkboxes decorative. */
		return bridge.begin_restore(
			App.snapshot_to_restore.name,
			mounts,
			App.restore_current_system,
			App.dry_run,
			!App.reinstall_grub2,
			(App.grub_device == null) ? "" : App.grub_device,
			App.restore_line_count_estimate,
			App.update_initramfs,
			App.update_grub);
	}

	private void restore_thread(){
		
		log_debug("RestoreBox: restore_thread()");
		App.restore_snapshot(parent_window);
		thread_is_running = false;
		log_debug("RestoreBox: restore_thread(): exit");
	}
}
