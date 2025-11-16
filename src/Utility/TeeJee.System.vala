
/*
 * TeeJee.System.vala
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
 
namespace TeeJee.System{

	using TeeJee.ProcessHelper;
	using TeeJee.Logging;
	using TeeJee.Misc;
	using TeeJee.FileSystem;
	
	// user ---------------------------------------------------

	public bool user_is_admin(){
		
		return (get_user_id_effective() == 0);
	}
	
	public int get_user_id(){

		// returns actual user id of current user (even for applications executed with sudo and pkexec)
		
		string pkexec_uid = GLib.Environment.get_variable("PKEXEC_UID");

		if (pkexec_uid != null){
			return int.parse(pkexec_uid);
		}

		string sudo_user = GLib.Environment.get_variable("SUDO_UID");

		if (sudo_user != null){
			return int.parse(sudo_user);
		}

		return get_user_id_effective(); // normal user
	}

	private int euid = -1; // cache for get_user_id_effective (its never going to change)
	public int get_user_id_effective(){
		// returns effective user id (0 for applications executed with sudo and pkexec)
		if (euid < 0) {
			euid = (int) Posix.geteuid();
		}

		return euid;
	}
	
	public string? get_username_from_uid(int user_id){
		unowned Posix.Passwd? pw = Posix.getpwuid(user_id);
		return pw?.pw_name;
	}

	// system ------------------------------------

	public double get_system_uptime_seconds(){

		/* Returns the system up-time in seconds */

		string uptime = file_read("/proc/uptime").split(" ")[0];
		double secs = double.parse(uptime);
		return secs;
	}

	// open -----------------------------

	public static bool xdg_open (string file){
		if (!TeeJee.ProcessHelper.cmd_exists("xdg-open")) {
			return false;
		}

		string cmd = "xdg-open '%s'".printf(escape_single_quote(file));

		return exec_user_async(cmd) == 0;
	}

	public bool exo_open_folder (string dir_path, bool xdg_open_try_first = true){

		/* Tries to open the given directory in a file manager */

		/*
		xdg-open is a desktop-independent tool for configuring the default applications of a user.
		Inside a desktop environment (e.g. GNOME, KDE, Xfce), xdg-open simply passes the arguments
		to that desktop environment's file-opener application (gvfs-open, kde-open, exo-open, respectively).
		We will first try using xdg-open and then check for specific file managers if it fails.
		*/

		bool xdgAvailable = cmd_exists("xdg-open");
		string escaped_dir_path = escape_single_quote(dir_path);
		int status = -1;

		if (xdg_open_try_first && xdgAvailable){
			//try using xdg-open
			string cmd = "xdg-open '%s'".printf(escaped_dir_path);
			status = exec_script_async (cmd);
			return (status == 0);
		}

		foreach(string app_name in
			new string[]{ "nemo", "nautilus", "thunar", "io.elementary.files", "pantheon-files", "marlin", "dolphin" }){
			if(!cmd_exists(app_name)) {
				continue;
			}

			string cmd = "%s '%s'".printf(app_name, escaped_dir_path);
			status = exec_script_async (cmd);

			if(status == 0) {
				return true;
			}
		}

		if (!xdg_open_try_first && xdgAvailable){
			//try using xdg-open
			string cmd = "xdg-open '%s'".printf(escaped_dir_path);
			status = exec_script_async (cmd);
			return (status == 0);
		}

		return false;
	}

	public bool using_efi_boot(){
		
		/* Returns true if the system was booted in EFI mode
		 * and false for BIOS mode */
		 
		return dir_exists("/sys/firmware/efi");
	}

	// timers --------------------------------------------------
	
	public GLib.Timer timer_start(){
		var timer = new GLib.Timer();
		timer.start();
		return timer;
	}

	public ulong timer_elapsed(GLib.Timer timer, bool stop = true){
		ulong microseconds;
		double seconds;
		seconds = timer.elapsed (out microseconds);
		if (stop){
			timer.stop();
		}
		return (ulong)((seconds * 1000 ) + (microseconds / 1000));
	}

	public void sleep(int milliseconds){
		Thread.usleep ((ulong) milliseconds * 1000);
	}

	public string timer_elapsed_string(GLib.Timer timer, bool stop = true){
		ulong microseconds;
		double seconds;
		seconds = timer.elapsed (out microseconds);
		if (stop){
			timer.stop();
		}
		return "%.0f ms".printf((seconds * 1000 ) + microseconds/1000);
	}

	public void set_numeric_locale(string type){
		Intl.setlocale(GLib.LocaleCategory.NUMERIC, type);
	    Intl.setlocale(GLib.LocaleCategory.COLLATE, type);
	    Intl.setlocale(GLib.LocaleCategory.TIME, type);
	}
}
