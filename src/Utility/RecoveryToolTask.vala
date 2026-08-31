/*
 * RecoveryToolTask.vala
 *
 * Copyright 2026 makeafide <willsmit4433@gmail.com>
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

/* Runs one timeshift-recovery command and keeps its output for a UI.
 *
 * The recovery environment is provisioned by a separate tool so that its
 * failure modes can never take the restore path down with them. This task
 * only wraps it: it exists so the Settings page can run a minutes-long
 * install without freezing, streaming the tool's own output. */
public class RecoveryToolTask : AsyncTask {

	public const string TOOL = "/usr/sbin/timeshift-recovery";

	public string args_line = "";

	/* The pipes are read on worker threads and the buffer is emptied from
	 * the main thread, so it is guarded and handed over in one go. Capped:
	 * an install's package output is long and only the tail matters. */
	private Gee.ArrayList<string> pending;
	private GLib.Mutex pending_mutex;

	private const int PENDING_MAX = 5000;

	public RecoveryToolTask(string _args_line){
		args_line = _args_line;
		pending = new Gee.ArrayList<string>();
		pending_mutex = GLib.Mutex();
	}

	protected override string build_script(){
		/* No trailing 'exit $?' here: the wrapper script appends the status
		 * write that read_exit_code() consumes, and an early exit would skip
		 * it and lose the tool's real status. */
		return "%s %s".printf(TOOL, args_line);
	}

	protected override void parse_stdout_line(string out_line){
		capture(out_line);
	}

	protected override void parse_stderr_line(string err_line){
		capture(err_line);
	}

	private void capture(string line){

		pending_mutex.lock();

		pending.add(line);

		while (pending.size > PENDING_MAX){
			pending.remove_at(0);
		}

		pending_mutex.unlock();
	}

	/* Every line captured since the last call, oldest first. */
	public string[] drain_output(){

		string[] lines = {};

		if (pending_mutex.trylock()){

			if (pending.size > 0){
				lines = pending.to_array();
				pending.clear();
			}

			pending_mutex.unlock();
		}

		return lines;
	}
}
