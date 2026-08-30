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

	/* The complete script, including its rsync invocation. */
	public string script_text = "";

	/* The key of the phase the script last announced. Written from the pipe
	 * reader thread and read by the polling loop, like every other field the
	 * progress pages poll. */
	public string current_phase = "";

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
			return;
		}

		update_progress_parse_console_output(line);
	}
}
