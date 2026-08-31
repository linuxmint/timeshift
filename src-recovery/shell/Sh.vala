/*
 * Sh.vala
 *
 * Subprocess helpers for the Timeshift recovery shell.
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
 */

/* Everything the shell does to the machine goes through here: nmcli, lsblk,
 * mount, cryptsetup, tailscale. Argv arrays throughout -- nothing is ever
 * assembled into a command string, so nothing needs quoting. */
namespace Sh {

	public bool run_sync(string[] argv, out string output) {
		output = "";
		try {
			string std_out, std_err;
			int status;
			GLib.Process.spawn_sync(null, argv, null,
				SpawnFlags.SEARCH_PATH, null,
				out std_out, out std_err, out status);

			/* On failure prefer stderr: a command that printed something to
			 * stdout and then failed used to report only the stdout, hiding
			 * the actual reason. */
			if (status != 0) {
				output = (std_err.length > 0) ? std_err : std_out;
			}
			else {
				output = (std_out.length > 0) ? std_out : std_err;
			}

			return (status == 0);
		}
		catch (Error e) {
			output = e.message;
			return false;
		}
	}

	/* Like run_sync, but writes to the child's stdin. That is the only safe way
	 * to hand cryptsetup a passphrase: as an argument it would sit in /proc,
	 * readable by anything, for the life of the process. */
	public bool run_with_input(string[] argv, string input, out string output) {

		output = "";

		try {
			var proc = new GLib.Subprocess.newv(argv,
				GLib.SubprocessFlags.STDIN_PIPE
				| GLib.SubprocessFlags.STDOUT_PIPE
				| GLib.SubprocessFlags.STDERR_PIPE);

			string std_out, std_err;
			proc.communicate_utf8(input, null, out std_out, out std_err);

			bool ok = proc.get_successful();

			output = ok
				? ((std_out.length > 0) ? std_out : std_err)
				: ((std_err.length > 0) ? std_err : std_out);

			return ok;
		}
		catch (Error e) {
			output = e.message;
			return false;
		}
	}

	/* Connecting to a network takes seconds. Doing that synchronously freezes
	 * the whole launcher, which on a machine someone is already worried about
	 * looks exactly like a crash. */
	public async bool run_async(string[] argv, out string output) {
		output = "";
		try {
			var proc = new GLib.Subprocess.newv(argv,
				GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE);

			string std_out, std_err;
			yield proc.communicate_utf8_async(null, null, out std_out, out std_err);

			output = (std_err != null && std_err.length > 0) ? std_err : (std_out ?? "");
			return proc.get_successful();
		}
		catch (Error e) {
			output = e.message;
			return false;
		}
	}

	/* Fire-and-forget: reboot, poweroff. Nothing comes back from these. */
	public bool spawn_detached(string command, out string error_message) {
		error_message = "";
		try {
			string[] argv = { command };
			GLib.Process.spawn_async(null, argv, null,
				SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, null);
			return true;
		}
		catch (Error e) {
			error_message = e.message;
			return false;
		}
	}

	/* Same, but hands back the pid so the caller can watch for its exit.
	 * DO_NOT_REAP_CHILD is what makes ChildWatch.add() possible. */
	public bool spawn_watched(string command, out Pid pid, out string error_message) {
		pid = 0;
		error_message = "";
		try {
			string[] argv = { command };
			GLib.Process.spawn_async(null, argv, null,
				SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD,
				null, out pid);
			return true;
		}
		catch (Error e) {
			error_message = e.message;
			return false;
		}
	}
}
