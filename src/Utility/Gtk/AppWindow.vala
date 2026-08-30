/*
 * AppWindow.vala
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

/* Base for the app's top-level windows.
 *
 * GTK3 code could rely on Gtk.Widget::destroy to learn that a window had
 * finished: gtk_widget_destroy() emitted it synchronously. GTK4 has no
 * equivalent guarantee -- gtk_window_destroy() drops GTK's own reference, but
 * ::destroy is emitted from dispose, which only runs once the LAST reference
 * goes away. A caller that still holds the window in a local or a closure
 * therefore never sees the signal, and its cleanup never runs.
 *
 * Windows here announce their own closing instead, so callers get a
 * deterministic notification whichever way the window went away. */

public class AppWindow : Gtk.Window {

	public signal void closed();

	private bool closed_emitted = false;

	/* Announce the close exactly once, whatever route it came by. Call this
	 * from a close_request handler on the branch that lets the window go. */
	protected void notify_closed(){

		if (closed_emitted){ return; }

		closed_emitted = true;

		closed();
	}

	/* Close this window programmatically. Use in place of destroy(), which on
	 * its own tells nobody. */
	public void close_self(){

		notify_closed();

		this.destroy();
	}
}
