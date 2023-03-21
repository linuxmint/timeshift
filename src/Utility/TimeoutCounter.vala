
/*
 * TimeoutCounter.vala
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
using TeeJee.Misc;

public class TimeoutCounter : GLib.Object {

	public bool active = false;
	public string process_to_kill = "";
	public const int DEFAULT_SECONDS_TO_WAIT = 60;
	public int seconds_to_wait = 60;
	public bool exit_app = false;
	
	public void kill_process_on_timeout(
		string process_to_kill, int seconds_to_wait = DEFAULT_SECONDS_TO_WAIT, bool exit_app = false){

		this.process_to_kill = process_to_kill;
		this.seconds_to_wait = seconds_to_wait;
		this.exit_app = exit_app;
			
		try {
			active = true;
			new Thread<void>.try ("timeout-counter",() => { start_counter_thread();});
		}
		catch (Error e) {
			log_error (e.message);
		}
	}

	public void exit_on_timeout(int seconds_to_wait = DEFAULT_SECONDS_TO_WAIT){
		this.process_to_kill = "";
		this.seconds_to_wait = seconds_to_wait;
		this.exit_app = true;
			
		try {
			active = true;
			new Thread<void>.try ("timeout-counter", () => {start_counter_thread();});
		}
		catch (Error e) {
			log_error (e.message);
		}
	}

	public void stop(){
		active = false;
	}
	
	public void start_counter_thread(){
		int secs = 0;
		
		while (active && (secs < seconds_to_wait)){
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 1000);
			secs += 1;
		}

		if (active){
			active = false;
			stdout.printf("\n");

			if (process_to_kill.length > 0){
				Posix.system("killall " + process_to_kill);
				log_debug("[timeout] Killed process" + ": %s".printf(process_to_kill));
			}

			if (exit_app){
				log_debug("[timeout] Exit application");
				exit(0);
			}
		}
	}
}

