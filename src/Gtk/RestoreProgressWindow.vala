/*
 * RestoreProgressWindow.vala
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

using Gtk;
using Gee;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

/* The screen that takes over while the running system is being overwritten.
 *
 * It replaces the full-screen VTE terminal, and keeps that window's one
 * essential property: it cannot be dismissed. The restore has to run to
 * completion - the root filesystem is inconsistent until it does - so the
 * title buttons stay hidden and the close request is swallowed, which also
 * takes care of Alt+F4.
 *
 * The window holds no logic of its own. RestoreBox owns the thread and the
 * polling loop, and writes into `box`. */

public class RestoreProgressWindow : AppWindow {

	public RestoreProgressBox box;

	private Gtk.HeaderBar header;

	public bool is_running = false;

	public RestoreProgressWindow(Gtk.Window? parent, string title){

		if (parent != null){
			set_transient_for(parent);
		}

		set_modal(true);

		/* Fullscreen is a request: a compositor can refuse it, and a plain X
		 * server with no window manager ignores it outright. Without a
		 * default size the window would then come up collapsed. */
		set_default_size(1100, 800);
		fullscreen();

		this.title = _("Restore");

		header = new Gtk.HeaderBar();
		header.show_title_buttons = false; // nothing to press until it is over
		set_titlebar(header);

		this.close_request.connect(() => {
			if (is_running){ return true; }
			notify_closed();
			return false;
		});

		box = new RestoreProgressBox(title, true);
		box.valign = Gtk.Align.START;
		box.hexpand = true;
		Ui.as_page(box);

		/* Wider than a wizard form: this is the whole screen, and the
		 * output pane wants the room. Scrolled, because a VM console can
		 * be shorter than the checklist. */
		var clamp = new ContentClamp(box);
		clamp.maximum_size = 900;

		var scroller = new Gtk.ScrolledWindow();
		scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
		scroller.has_frame = false;
		scroller.hexpand = true;
		scroller.vexpand = true;
		scroller.propagate_natural_height = true;
		scroller.set_child(clamp);

		set_child(scroller);
	}

	public void finish(){

		is_running = false;

		close_self();
	}
}
