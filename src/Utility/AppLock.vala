/*
 * AppLock.vala
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
 
public class AppLock : GLib.Object {
	public string lock_file = "";
	public string lock_message = "";
	public string status_file = "";
	private string lock_mode = "";
	
	public bool create(string app_name, string message){

		var lock_dir = "/var/run/lock/%s".printf(app_name);
		dir_create(lock_dir);
		lock_file = path_combine(lock_dir, "lock");
		status_file = path_combine(lock_dir, "status");
		lock_mode = message;
		
		try{
			var file = File.new_for_path(lock_file);
			if (file.query_exists()) {

				string txt = file_read(lock_file);
				string process_id = txt.split(";")[0].strip();
				lock_message = txt.split(";")[1].strip();
				long pid = long.parse(process_id);

				if (get_process_exe_name(pid).contains("timeshift")){
					log_msg(_("Another instance of this application is running")
						+ " (PID=%ld)".printf(pid));
					return false;
				}
				else{
					log_msg(_("[Warning] Deleted invalid lock"));
					file.delete();
					write_lock_file(message);
					return true;
				}
			}
			else{
				write_lock_file(message);
				return true;
			}
		}
		catch (Error e) {
			log_error (e.message);
			return false;
		}
	}

	// Tells whether a live Timeshift process holds the lock, and in which mode
	// ("backup" for the scheduled check, "" for a window).
	public static bool read_holder(string app_name, out long pid, out string mode){
		pid = 0;
		mode = "";

		string path = "/var/run/lock/%s/lock".printf(app_name);
		if (!file_exists(path)){
			return false;
		}

		string txt = file_read(path);
		if (txt == null){
			return false;
		}

		var parts = txt.split(";");
		pid = long.parse(parts[0].strip());
		mode = (parts.length > 1) ? parts[1].strip() : "";

		return (pid > 0) && get_process_exe_name(pid).contains("timeshift");
	}

	private void write_lock_file(string message){
		string current_pid = ((long) Posix.getpid()).to_string();
		file_write(lock_file, "%s;%s".printf(current_pid, message));
	}
	
	// Publishes what this instance is doing and how far it has got, so that other programs
	// (a panel applet, a second window) can show it. The file is readable by every user,
	// is replaced on every update and is removed together with the lock.
	public void write_status(string action, string snapshot_name, AsyncTask? task){
		var builder = new Json.Builder();
		builder.begin_object();
		builder.set_member_name("pid");
		builder.add_int_value(Posix.getpid());
		builder.set_member_name("mode");
		builder.add_string_value(lock_mode);
		builder.set_member_name("action");
		builder.add_string_value(action);
		builder.set_member_name("snapshot");
		builder.add_string_value(snapshot_name);
		if (task != null){
			builder.set_member_name("progress");
			builder.add_double_value(task.progress);
			builder.set_member_name("seconds_remaining");
			builder.add_int_value((int64) task.seconds_remaining);
			builder.set_member_name("count");
			builder.add_int_value(task.prg_count);
			builder.set_member_name("count_total");
			builder.add_int_value(task.prg_count_total);
		}
		builder.set_member_name("updated");
		builder.add_int_value(new DateTime.now_utc().to_unix());
		builder.end_object();

		var generator = new Json.Generator();
		generator.set_root(builder.get_root());

		// write to a temporary file and rename it, so that a reader never sees half a file
		string tmp_file = status_file + ".tmp";
		if (file_write(tmp_file, generator.to_data(null))){
			FileUtils.rename(tmp_file, status_file);
		}
	}

	public void clear_status(){
		if (status_file.length > 0){
			FileUtils.unlink(status_file);
		}
	}

	public void remove(){
		clear_status();
		try{
			var file = File.new_for_path (lock_file);
			if (file.query_exists()) {
				file.delete();
			}
		}
		catch (Error e) {
			log_error (e.message);
		}
	}

}
