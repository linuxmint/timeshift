/*
 * Tailscale.vala
 *
 * The tailscale command surface used by the Timeshift recovery shell.
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

/* No GTK here on purpose: this is the command surface only, so the network
 * page owns every widget and this file stays testable by eye. */
namespace Tailscale {

	public bool is_installed() {
		return SysInfo.file_exists("/usr/bin/tailscale");
	}

	public async string ip() {
		string o;
		yield Sh.run_async({ "tailscale", "ip", "-4" }, out o);
		return o;
	}

	public async string prefs() {
		string o;
		yield Sh.run_async({ "tailscale", "debug", "prefs" }, out o);
		return o;
	}

	/* Does this prefs dump say peers' subnet routes are being imported?
	 * "tailscale debug prefs" reports it as RouteAll, which is the flag
	 * --accept-routes sets. */
	public bool accepting_routes(string prefs_text) {
		return prefs_text.contains("\"RouteAll\": true");
	}

	/* The same question asked synchronously, for the diagnostics report. */
	public bool accept_routes_enabled() {

		string o;

		if (!Sh.run_sync({ "tailscale", "debug", "prefs" }, out o)) { return false; }

		foreach (string line in o.split("\n")) {
			if (line.contains("\"RouteAll\"")) {
				return line.contains("true");
			}
		}

		return false;
	}

	public bool routes_via(string host) {

		string o;

		if (!Sh.run_sync({ "ip", "route", "get", host }, out o)) { return false; }

		return o.contains("tailscale");
	}

	/* --accept-routes is the point: the backup host is reached over a peer's
	 * advertised subnet route, and without this flag that route is ignored. */
	public async bool up(out string output) {
		return yield Sh.run_async(
			{ "tailscale", "up", "--accept-routes", "--timeout=30s" }, out output);
	}

	/* Turn peers' subnet routes on or off without leaving the tailnet.
	 *
	 * "tailscale up --accept-routes=false" keeps the node connected but stops
	 * importing routes, so a backup host on the local network goes back to
	 * being reached directly. */
	public async bool set_routes(bool accept, out string output) {
		return yield Sh.run_async({ "tailscale", "up",
			accept ? "--accept-routes=true" : "--accept-routes=false",
			"--timeout=30s" }, out output);
	}
}
