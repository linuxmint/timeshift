/*
 * RunningTaskWindow.vala
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
 */

using Gtk;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.ProcessHelper;
using TeeJee.Misc;

// Shown instead of the main window while another Timeshift process, usually the scheduled
// check, is working. It follows that process through the status file it publishes next to
// the lock, and closes by itself when the process ends so that the main window can open.
public class RunningTaskWindow : Gtk.Window {

	private long holder_pid;
	private string holder_mode;
	private string status_file = "/var/run/lock/timeshift/status";

	private Gtk.Label lbl_action;
	private Gtk.ProgressBar progressbar;
	private Gtk.Label lbl_remaining;

	private bool finished = false;

	// Returns false if the user closed the window before the other process was done.
	public static bool wait_for_running_instance(){
		long pid;
		string mode;

		// nothing running, or another window: Main shows its usual message
		if (!AppLock.read_holder("timeshift", out pid, out mode) || (mode.length == 0)){
			return true;
		}

		log_msg("Waiting for running instance (PID=%ld, mode=%s)".printf(pid, mode));

		var win = new RunningTaskWindow(pid, mode);
		win.show_all();
		Gtk.main();

		return win.finished;
	}

	public RunningTaskWindow(long pid, string mode){
		holder_pid = pid;
		holder_mode = mode;

		title = "Timeshift";
		set_icon_name("timeshift");
		window_position = WindowPosition.CENTER;
		resizable = false;
		set_default_size(450, -1);

		var vbox = new Gtk.Box(Orientation.VERTICAL, 12);
		vbox.margin = 18;
		add(vbox);

		lbl_action = new Gtk.Label("");
		lbl_action.xalign = 0;
		lbl_action.wrap = true;
		vbox.add(lbl_action);

		progressbar = new Gtk.ProgressBar();
		progressbar.show_text = true;
		vbox.add(progressbar);

		lbl_remaining = new Gtk.Label("");
		lbl_remaining.xalign = 0;
		vbox.add(lbl_remaining);

		var lbl_note = new Gtk.Label(_("Timeshift will open when this has finished."));
		lbl_note.xalign = 0;
		lbl_note.get_style_context().add_class("dim-label");
		vbox.add(lbl_note);

		var bbox = new Gtk.ButtonBox(Orientation.HORIZONTAL);
		bbox.layout_style = Gtk.ButtonBoxStyle.END;
		vbox.add(bbox);

		var btn_close = new Gtk.Button.with_label(_("Close"));
		btn_close.clicked.connect(() => { destroy(); });
		bbox.add(btn_close);

		destroy.connect(Gtk.main_quit);

		update();
		Timeout.add_seconds(1, update);
	}

	private bool update(){

		if (!get_process_exe_name(holder_pid).contains("timeshift")){
			log_msg("Running instance has finished");
			finished = true;
			destroy();
			return false;
		}

		string action = "";
		string snapshot = "";
		double progress = -1;
		int64 seconds_remaining = -1;

		if (file_exists(status_file)){
			try{
				var parser = new Json.Parser();
				parser.load_from_file(status_file);
				var node = parser.get_root().get_object();
				action = node.get_string_member_with_default("action", "");
				snapshot = node.get_string_member_with_default("snapshot", "");
				progress = node.get_double_member_with_default("progress", -1);
				seconds_remaining = node.get_int_member_with_default("seconds_remaining", -1);
			}
			catch (Error e){
				// replaced while reading, try again next second
			}
		}

		switch (action){
		case "checking-space":
			lbl_action.label = _("Calculating required disk space...");
			break;
		case "creating":
			if (holder_mode == "backup"){
				lbl_action.label = _("Creating scheduled snapshot %s").printf(snapshot);
			}
			else{
				lbl_action.label = _("Creating snapshot %s").printf(snapshot);
			}
			break;
		case "deleting":
			lbl_action.label = _("Removing snapshot %s").printf(snapshot);
			break;
		case "restoring":
		case "comparing":
			lbl_action.label = _("Restoring snapshot %s").printf(snapshot);
			break;
		default:
			if (holder_mode == "backup"){
				lbl_action.label = _("Another instance of Timeshift is creating a snapshot.");
			}
			else{
				lbl_action.label = _("Another instance of timeshift is currently running!");
			}
			break;
		}

		if (progress >= 0){
			progressbar.fraction = double.min(progress, 1.0);
			progressbar.text = "%.0f %%".printf(progress * 100.0);
		}
		else{
			progressbar.pulse();
			progressbar.text = "";
		}

		if (seconds_remaining >= 0){
			lbl_remaining.label = format_duration(seconds_remaining * 1000.0) + " " + _("remaining");
		}
		else{
			lbl_remaining.label = "";
		}

		return true;
	}
}
