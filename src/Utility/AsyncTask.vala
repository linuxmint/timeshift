/*
 * AsyncTask.vala
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
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.System;
using TeeJee.Misc;

public abstract class AsyncTask : GLib.Object{
	
	private string err_line = "";
	private string out_line = "";
	private DataOutputStream dos_in = null;
	private DataInputStream dis_out = null;
	private DataInputStream dis_err = null;
	protected DataOutputStream dos_log = null;

	private bool stdout_is_open = false;
	private bool stderr_is_open = false;

	protected Pid child_pid = 0;
	private int input_fd = -1;
	private int output_fd = -1;
	private int error_fd = -1;
	private bool finish_called = false;

	protected string script_file = "";
	protected string working_dir = "";

	// public
	public AppStatus status = AppStatus.NOT_STARTED;

    private string _status_line = "";
    public GLib.Mutex status_line_mutex;

	public int exit_code = 0;
	public GLib.Timer timer;
	private double timerOffset = 0.0; // milliseconds to be added to the current timer - this is to compensate for pauses (timer restarts)
	public double progress = 0.0;
	public double percent = 0.0;
	public int64 prg_count = 0;
	public int64 prg_count_total = 0;

	public bool io_nice = true; // renice child processes to IDlE PRIO

	// signals
	public signal void stdout_line_read(string line);
	public signal void stderr_line_read(string line);
	public signal void task_complete();

    [CCode(notify = false)]
    public string status_line
    {
        owned get {
            return _get_status_line();
        }

        set
        {
            status_line_mutex.lock();
            _status_line = value;
            status_line_mutex.unlock();
        }
    }

    private string _get_status_line() {
        string ret = "";

        if (status_line_mutex.trylock()) {
            ret = _status_line;
            status_line_mutex.unlock();
        }

        return ret;
    }

	protected AsyncTask(){
		working_dir = TEMP_DIR + "/" + timestamp_for_path();
		script_file = path_combine(working_dir, "script.sh");

        status_line_mutex = GLib.Mutex();

		dir_create(working_dir);
	}

	public virtual void prepare() {
		string script_text = build_script();
		log_debug(script_text);
		save_bash_script_temp(script_text, script_file);

		log_debug("AsyncTask:prepare(): saved: %s".printf(script_file));
	}

	protected abstract string build_script();

	protected virtual bool begin() {
		status = AppStatus.RUNNING;
		
		bool has_started = true;
		finish_called = false;

		prg_count = 0;

		string[] spawn_args = new string[1];
		spawn_args[0] = script_file;
		
		string[] spawn_env = Environ.get();
		
		try {
			// start timer
			timer = new GLib.Timer();
			timer.start();

			GLib.SpawnChildSetupFunc? childsetup = null;

			if(this.io_nice) {
				// change io prio of process, right before it execs
				childsetup = () => TeeJee.ProcessHelper.ioprio_set(0, IoPrio.prioValue(IoPrio.PrioClass.IDLE, 0));
			}

			// execute script file
			Process.spawn_async_with_pipes(
			    working_dir, // working dir
			    spawn_args,  // argv
			    spawn_env,   // environment
			    SpawnFlags.SEARCH_PATH,
			    childsetup,        // child_setup
			    out child_pid,
			    out input_fd,
			    out output_fd,
			    out error_fd);

			log_debug("AsyncTask: child_pid: %d".printf(child_pid));

			// create stream readers
			UnixOutputStream uos_in = new UnixOutputStream(input_fd, true);
			UnixInputStream uis_out = new UnixInputStream(output_fd, true);
			UnixInputStream uis_err = new UnixInputStream(error_fd, true);
			dos_in = new DataOutputStream(uos_in);
			dis_out = new DataInputStream(uis_out);
			dis_err = new DataInputStream(uis_err);
			dis_out.newline_type = DataStreamNewlineType.ANY;
			dis_err.newline_type = DataStreamNewlineType.ANY;

			try {
				//start thread for reading output stream
				new Thread<void>.try ("async-task-stdout-reader", read_stdout);
			} catch (GLib.Error e) {
				log_error ("AsyncTask.begin():create_thread:read_stdout()");
				log_error (e.message);
			}

			try {
				//start thread for reading error stream
				new Thread<void>.try ("async-task-stderr-reader", read_stderr);
			} catch (GLib.Error e) {
				log_error ("AsyncTask.begin():create_thread:read_stderr()");
				log_error (e.message);
			}
		}
		catch (Error e) {
			log_error ("AsyncTask.begin()");
			log_error(e.message);
			has_started = false;
			//status = AppStatus.FINISHED;
		}

		return has_started;
	}

	private void read_stdout() {
		try {
			stdout_is_open = true;
			
			out_line = dis_out.read_line (null);
			while (out_line != null) {
				//log_msg("O: " + out_line);
				if (out_line.length > 0) {
					parse_stdout_line(out_line);
					stdout_line_read(out_line); //signal
				}
				out_line = dis_out.read_line (null); //read next
			}

			stdout_is_open = false;

			// dispose stdout
			try {
				if (dis_out != null) {
					dis_out.close();
				}
			}
			catch (GLib.Error ignored) {}
			dis_out = null;

			// check if complete
			if (!stdout_is_open && !stderr_is_open){
				finish();
			}
		}
		catch (Error e) {
			log_error ("AsyncTask.read_stdout()");
			log_error (e.message);
		}
	}
	
	private void read_stderr() {
		try {
			stderr_is_open = true;
			
			err_line = dis_err.read_line (null);
			while (err_line != null) {
				if (err_line.length > 0){
					parse_stderr_line(err_line);
					stderr_line_read(err_line); //signal
				}
				err_line = dis_err.read_line (null); //read next
			}

			stderr_is_open = false;

			// dispose stderr
			try {
				if (dis_err != null) {
					dis_err.close();
				}
			}
			catch (GLib.Error ignored) {}
			dis_err = null;

			// check if complete
			if (!stdout_is_open && !stderr_is_open){
				finish();
			}
		}
		catch (Error e) {
			log_error ("AsyncTask.read_stderr()");
			log_error (e.message);
		}
	}

	public void write_stdin(string line){
		try{
			if (status == AppStatus.RUNNING){
				dos_in.put_string(line + "\n");
			}
			else{
				log_error ("AsyncTask.write_stdin(): NOT RUNNING");
			}
		}
		catch(Error e){
			log_error ("AsyncTask.write_stdin(): %s".printf(line));
			log_error (e.message);
		}
	}

	public virtual void execute() {
		log_debug("AsyncTask:execute()");
		prepare();
		begin();
	}
	
	protected abstract void parse_stdout_line(string out_line);
	
	protected abstract void parse_stderr_line(string err_line);
	
	private void finish(){
		
		// finish() gets called by 2 threads but should be executed only once
		if (finish_called) { return; }
		finish_called = true;
		
		log_debug("AsyncTask: finish(): enter");
		
		// dispose stdin
		try{
			if (dos_in != null) {
				dos_in.close();
			}
		}
		catch(GLib.IOError e) {
			// ignore
		}
		dos_in = null;

		// dispose child process
		Process.close_pid(child_pid); //required on Windows, doesn't do anything on Unix

		read_exit_code();
		
		status_line = "";
		err_line = "";
		out_line = "";

		timer.stop();
		
		finish_task();

		if ((status != AppStatus.CANCELLED) && (status != AppStatus.PASSWORD_REQUIRED)) {
			status = AppStatus.FINISHED;
		}

		//dir_delete(working_dir);
		
		task_complete(); //signal
	}

	// can be overloaded by subclasses, that wish to do special stuff during finish
	protected virtual void finish_task() {}

	protected int read_exit_code(){
		
		exit_code = -1;
		var path = file_parent(script_file) + "/status";
		if (file_exists(path)){
			var txt = file_read(path);
			exit_code = int.parse(txt);
		}
		log_debug("exit_code: %d".printf(exit_code));
		return exit_code;
	}

	public bool is_running(){
		return (status == AppStatus.RUNNING);
	}
	
	// public actions --------------

	public void stop(AppStatus status_to_update = AppStatus.CANCELLED) {
		status = status_to_update;

		if(0 != child_pid) {
			process_quit(child_pid);
			child_pid = 0;

			log_debug("process_quit: %d  ".printf(child_pid));
		}
	}

	public void pause(AppStatus status_to_update = AppStatus.PAUSED) {
		status = status_to_update;

		if(0 != child_pid) {
			TeeJee.ProcessHelper.process_send_signal(this.child_pid, Posix.Signal.STOP, true);

			// "pause" timer
			this.timerOffset += TeeJee.System.timer_elapsed(this.timer, true);

			log_debug("process_paused: %d  ".printf(this.child_pid));
		}
	}

	// unpause (continue) the task
	public void resume(AppStatus status_to_update = AppStatus.RUNNING) {
		status = status_to_update;

		if(0 != child_pid) {
			TeeJee.ProcessHelper.process_send_signal(this.child_pid, Posix.Signal.CONT, true);

			// restart timer
			this.timer = new GLib.Timer();
			this.timer.start();

			log_debug("process_resumed: %d  ".printf(this.child_pid));
		}
	}

	private double elapsed {
		get {
			double elapsed = timerOffset;
			if(this.status != AppStatus.PAUSED) {
				elapsed += TeeJee.System.timer_elapsed(timer);
			}
			return elapsed;
		}
	}

	public string stat_time_elapsed{
		owned get{
			return TeeJee.Misc.format_duration(this.elapsed);
		}
	}

	public string stat_time_remaining{
		owned get{
			if (this.progress > 0){
				double remaining = ((this.elapsed / this.progress) * (1.0 - this.progress));
				if (remaining < 0){
					remaining = 0;
				}
				return TeeJee.Misc.format_duration(remaining);
			}
			else{
				return "???";
			}
		}
	}

	public void print_app_status(){
		
		switch(status){
		case AppStatus.NOT_STARTED:
			log_debug("status=%s".printf("NOT_STARTED"));
			break;
		case AppStatus.RUNNING:
			log_debug("status=%s".printf("RUNNING"));
			break;
		case AppStatus.PAUSED:
			log_debug("status=%s".printf("PAUSED"));
			break;
		case AppStatus.FINISHED:
			log_debug("status=%s".printf("FINISHED"));
			break;
		case AppStatus.CANCELLED:
			log_debug("status=%s".printf("CANCELLED"));
			break;
		case AppStatus.PASSWORD_REQUIRED:
			log_debug("status=%s".printf("PASSWORD_REQUIRED"));
			break;
		}
	}
}

public enum AppStatus {
	NOT_STARTED,
	RUNNING,
	PAUSED,
	FINISHED,
	CANCELLED,
	PASSWORD_REQUIRED
}

/* Sample Subclass:
public class RsyncTask : AsyncTask{

	public bool delete_extra = true;
	public string rsync_log_file = "";
	public string exclude_from_file = "";
	public string source_path = "";
	public string dest_path = "";
	public bool verbose = true;
	
	public RsyncTask(string _script_file, string _working_dir, string _log_file){
		working_dir = _working_dir;
		script_file = _script_file;
		log_file = _log_file;
	}

	protected override string build_script() {
		var cmd = "rsync -ai";

		if (verbose){
			cmd += " --verbose";
		}
		else{
			cmd += " --quiet";
		}

		if (delete_extra){
			cmd += " --delete";
		}

		cmd += " --numeric-ids --stats --relative --delete-excluded";

		if (rsync_log_file.length > 0){
			cmd += " --log-file='%s'".printf(escape_single_quote(rsync_log_file));
		}

		if (exclude_from_file.length > 0){
			cmd += " --exclude-from='%s'".printf(escape_single_quote(exclude_from_file));
		}

		source_path = remove_trailing_slash(source_path);
		
		dest_path = remove_trailing_slash(dest_path);
		
		cmd += " '%s/'".printf(escape_single_quote(source_path));

		cmd += " '%s/'".printf(escape_single_quote(dest_path));
		
		//cmd += " /. \"%s\"".printf(sync_path + "/localhost/");

		return cmd;
	}
	 
	// execution ----------------------------

	public override void parse_stdout_line(string out_line){
		update_progress_parse_console_output(out_line);
	}
	
	public override void parse_stderr_line(string err_line){
		update_progress_parse_console_output(err_line);
	}

	public bool update_progress_parse_console_output (string line) {
		if ((line == null) || (line.length == 0)) {
			return true;
		}

		return true;
	}
}
*/
