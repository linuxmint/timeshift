/*
 * RecoveryApp.vala
 *
 * Entry point for timeshift-recovery-shell, the launcher shown in the
 * Timeshift recovery environment.
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

/* This is deliberately NOT built from the Timeshift core.
 *
 * The launcher needs to run a program, run a program in a terminal, list block
 * devices, mount one, and drive NetworkManager. Core's Device is a 2100-line
 * model built for Timeshift's restore logic, and reaching it means linking Main
 * -- the god object that owns all config and all discovered system state, and
 * that AppTheme also reaches through the global App. Pulling that in would make
 * the recovery shell fail to start for any reason Timeshift itself can fail to
 * start, which is precisely the situation this environment exists to recover
 * from.
 *
 * So this shells out to nmcli, lsblk and cryptsetup, which is what Core does
 * underneath anyway. Nothing here may reference src/Core or src/Utility, and
 * the build carries no sources_* list for exactly that reason.
 *
 * Deliberately English-only, no _() marking: the recovery image ships no
 * locale data (mmdebstrap --variant=important carries no language packs), so
 * gettext could never translate these strings at runtime anyway.
 */

using GLib;
using Gtk;

public class RecoveryApp {

	public static int main(string[] args) {

		foreach (string arg in args) {
			if (arg == "--help" || arg == "-h") {
				stdout.printf(help_message());
				return 0;
			}
			if (arg == "--version") {
				stdout.printf("%s %s\n", RecoveryWindow.APP_TITLE, Constants.VERSION);
				return 0;
			}
		}

		Gtk.init();

		var shell = new RecoveryWindow();
		shell.build();

		var loop = new GLib.MainLoop();
		shell.window.close_request.connect(() => {
			/* Never closable. This is the session's only client, so closing it
			 * leaves a compositor with no windows: a black screen with nothing
			 * to click and nowhere to type. Reboot and Power off are the ways
			 * out, and the supervisor restarts this if it ever dies. */
			return true;
		});
		shell.window.present();
		loop.run();

		return 0;
	}

	private static string help_message() {
		string msg = "\n%s %s\n".printf(RecoveryWindow.APP_TITLE, Constants.VERSION);
		msg += "\n";
		msg += "Syntax: timeshift-recovery-shell [options]\n";
		msg += "\n";
		msg += "The launcher shown in the Timeshift recovery environment. It connects\n";
		msg += "the network, mounts drives and starts a restore.\n";
		msg += "\n";
		msg += "Options:\n";
		msg += "\n";
		msg += "  --help, -h   Show all options\n";
		msg += "  --version    Print version number\n";
		msg += "\n";
		return msg;
	}
}
