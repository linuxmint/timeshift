/*
 * RestoreScriptTask.vala
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

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.ProcessHelper;
using TeeJee.Misc;

/* One step of a restore, as it appears in the progress checklist.
 *
 * The key is ASCII and never translated: it is what the generated shell script
 * echoes as "@@TS_PHASE:<key>", so matching stays locale-independent. The
 * title is the translated string built alongside it in
 * Main.create_restore_scripts(). */
public class RestorePhase : GLib.Object {

	public string key { get; set; }
	public string title { get; set; }

	public RestorePhase(string _key, string _title){
		key = _key;
		title = _title;
	}
}

/* Runs a restore script written by Main.create_restore_scripts() and turns its
 * output into progress.
 *
 * It subclasses RsyncTask rather than AsyncTask so that every field the GUI
 * polling loops already read - progress, status_line, the ten counters,
 * stat_time_remaining, exit_code - keeps working unchanged, and so the
 * inherited finish_task() still writes the "-changes" sidecar. The script is
 * supplied whole instead of being assembled here, which is the only reason
 * build_script() is overridden. */
public class RestoreScriptTask : RsyncTask {

	public const string PHASE_MARKER = "@@TS_PHASE:";

	/* Transient: the link dropped and the script is waiting for it. Not a
	 * phase -- the checklist would gain a step that comes and goes. */
	public const string RECONNECT_MARKER = "@@TS_RECONNECT:";

	/* Terminal: rsync failed and the script is about to abort BEFORE the
	 * finish steps. Needed because the console restore path runs through
	 * exec_script_sync(), which always reports success. */
	public const string FAILED_MARKER = "@@TS_RESTORE_FAILED:";

	/* rsync could not transfer everything, but the rest went through and the
	 * finish steps still ran. */
	public const string WARNINGS_MARKER = "@@TS_RESTORE_WARNINGS";

	/* A step AFTER the transfer failed (grub_install, update_initramfs, ...).
	 * Carries "<phase>:<rc>". Worth distinguishing: the files are restored and
	 * only that step needs redoing, which is a different remedy entirely. */
	public const string STEP_FAILED_MARKER = "@@TS_STEP_FAILED:";

	/* The complete script, including its rsync invocation. */
	public string script_text = "";

	/* The key of the phase the script last announced. Written from the pipe
	 * reader thread and read by the polling loop, like every other field the
	 * progress pages poll. */
	public string current_phase = "";

	/* Set while the script is waiting out a dropped link, and cleared when the
	 * transfer resumes. The progress pages poll it like current_phase. Not a
	 * phase itself: a reconnect comes and goes, and adding it to the checklist
	 * would put a step in the list that sometimes never happens. */
	public string reconnect_status = "";

	/* rsync's exit code for the drop, and when the wait began. A static
	 * "Connection lost - reconnecting" is indistinguishable from a hang; an
	 * attempt count and a running clock are not. */
	public string reconnect_code = "";
	public DateTime? reconnect_since = null;

	/* Non-empty once the script has told us it is aborting before the finish
	 * steps. Carries rsync's exit code. */
	public string failure_code = "";

	/* The transfer finished but could not copy everything (rsync exit 23).
	 * Not a failure: the finish steps still run. */
	public bool had_warnings = false;

	/* Set when a step after the transfer failed. "<phase>:<rc>". */
	public string failed_step = "";
	public string failed_step_rc = "";

	/* What rsync complained about, for the summary. Capped: a permission
	 * problem on a big tree can produce thousands of these, and the finish
	 * screen only needs enough to recognise the pattern. */
	public Gee.ArrayList<string> error_lines = new Gee.ArrayList<string>();
	public int error_line_count = 0;

	private const int MAX_ERROR_LINES = 20;

	public RestoreScriptTask(){
		capture_output = true; // the whole point: the output is on screen

		/* The script is the restore. Leaving AsyncTask's default idle IO
		 * priority in place would make it crawl, where the terminal it
		 * replaces ran at normal priority. */
		io_nice = false;
	}

	protected override string build_script() {
		return script_text;
	}

	public override void parse_stdout_line(string out_line){
		parse_line(out_line);
	}

	public override void parse_stderr_line(string err_line){
		parse_line(err_line);
	}

	private void parse_line(string line){

		if (line.has_prefix(PHASE_MARKER)){
			// internal bookkeeping, not output: it neither counts towards
			// progress nor belongs in the log pane
			current_phase = line.substring(PHASE_MARKER.length).strip();
			// A phase advancing means the transfer is moving again.
			reconnect_status = "";
			reconnect_code = "";
			reconnect_since = null;
			return;
		}

		if (line.has_prefix(RECONNECT_MARKER)){

			// "<attempt>:<rsync exit code>"
			string detail = line.substring(RECONNECT_MARKER.length).strip();

			int sep = detail.index_of(":");

			if (sep > 0){
				reconnect_status = detail.substring(0, sep);
				reconnect_code = detail.substring(sep + 1);
			}
			else {
				reconnect_status = detail;
				reconnect_code = "";
			}

			// so the page can say how long this wait has been going on
			reconnect_since = new DateTime.now_local();
			return;
		}

		if (line.has_prefix(FAILED_MARKER)){
			failure_code = line.substring(FAILED_MARKER.length).strip();
			return;
		}

		if (line.has_prefix(WARNINGS_MARKER)){
			had_warnings = true;
			return;
		}

		if (line.has_prefix(STEP_FAILED_MARKER)){

			string detail = line.substring(STEP_FAILED_MARKER.length).strip();

			// "<phase>:<rc>"
			int sep = detail.last_index_of(":");

			if (sep > 0){
				failed_step = detail.substring(0, sep);
				failed_step_rc = detail.substring(sep + 1);
			}
			else{
				failed_step = detail;
			}

			return;
		}

		collect_error_line(line);

		update_progress_parse_console_output(line);
	}

	/* rsync names what it could not transfer on stderr, one line each:
	 *   rsync: [sender] send_files failed to open "/x": Permission denied (13)
	 *   rsync: recv_generator: mkdir "/y" failed: Read-only file system (30)
	 * Those paths are the only actionable thing in a 12 GB transfer that
	 * ended in exit 23, so they are kept for the finish screen. */
	private void collect_error_line(string line){

		string txt = line.strip();

		if (!txt.has_prefix("rsync:") && !txt.has_prefix("rsync error:")){ return; }

		error_line_count++;

		if (error_lines.size < MAX_ERROR_LINES){
			error_lines.add(txt);
		}
	}
}
