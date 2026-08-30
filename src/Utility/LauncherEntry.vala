/*
 * LauncherEntry.vala
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
 */

using TeeJee.Logging;

/* Taskbar progress reporting.
 *
 * This replaces libxapp's xapp_set_window_progress(), which has no GTK4 build
 * and which worked by setting the X11 window properties _NET_WM_XAPP_PROGRESS
 * and _NET_WM_XAPP_PROGRESS_PULSE -- X11 only, with no Wayland support.
 *
 * The Unity LauncherEntry DBus protocol used here is toolkit-independent, works
 * under both Wayland and X11, and is consumed by Cinnamon, KDE Plasma,
 * Dash-to-Dock and Plank. Where nothing listens, the signal is simply ignored.
 */

namespace LauncherEntry {

	private const string APP_URI = "application://timeshift-gtk.desktop";
	private const string OBJECT_PATH = "/com/canonical/unity/launcherentry/timeshift";
	private const string INTERFACE = "com.canonical.Unity.LauncherEntry";

	private DBusConnection? connection = null;
	private bool connection_checked = false;

	private DBusConnection? get_connection(){

		/* Running under pkexec as root there is often no session bus at all;
		 * probe once and stay quiet about it afterwards. */

		if (connection_checked){ return connection; }

		connection_checked = true;

		try {
			connection = GLib.Bus.get_sync(GLib.BusType.SESSION, null);
		}
		catch (Error e) {
			log_debug("LauncherEntry: no session bus: %s".printf(e.message));
			connection = null;
		}

		return connection;
	}

	private void emit_update(double progress, bool visible){

		var conn = get_connection();
		if (conn == null){ return; }

		var builder = new GLib.VariantBuilder(new GLib.VariantType("a{sv}"));
		builder.add("{sv}", "progress", new GLib.Variant.double(progress));
		builder.add("{sv}", "progress-visible", new GLib.Variant.boolean(visible));

		try {
			conn.emit_signal(null, OBJECT_PATH, INTERFACE, "Update",
				new GLib.Variant("(sa{sv})", APP_URI, builder));
		}
		catch (Error e) {
			log_debug("LauncherEntry: %s".printf(e.message));
		}
	}

	public void set_progress(int percent){

		/* zero or negative hides the indicator, as libxapp did */

		if (percent <= 0){
			emit_update(0.0, false);
			return;
		}

		if (percent > 100){ percent = 100; }

		emit_update(percent / 100.0, true);
	}

	public void set_progress_pulse(bool active){

		/* The protocol has no indeterminate mode, so a pulse is shown as a
		 * visible bar sitting at zero and cleared when it stops. */

		emit_update(0.0, active);
	}
}
