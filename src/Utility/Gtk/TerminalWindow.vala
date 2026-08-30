/*
 * TerminalWindow.vala
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

public class TerminalWindow : AppWindow {
	
	private Gtk.Box vbox_main;
	private Vte.Terminal term;
	private Gtk.HeaderBar header;

	private Pid child_pid;
	private Gtk.Window parent_win = null;
	public bool is_running = false;
	private bool child_exited_connected = false;
	
	// init
	
	public TerminalWindow.with_parent(Gtk.Window? parent) {
		
		if (parent != null){
			set_transient_for(parent);
			parent_win = parent;
		}
		
		set_modal(true);
		fullscreen();

		this.close_request.connect(()=>{
			// the script must run to completion; afterwards the window may go
			if (is_running){ return true; }
			notify_closed();
			return false;
		});
		
		init_window();
	}

	public void init_window () {
		
		this.title = _("Restore");
		this.resizable = true;

		// no close button while the script runs; see close_request
		header = new Gtk.HeaderBar();
		header.show_title_buttons = false;
		set_titlebar(header);
		
		// vbox_main ---------------
		
		vbox_main = new Gtk.Box(Orientation.VERTICAL, 0);
		set_child (vbox_main);

		// terminal ----------------------
		
		term = new Vte.Terminal();
		term.hexpand = true;
		term.vexpand = true;
		vbox_main.append(term);

		term.input_enabled = true;
		term.backspace_binding = Vte.EraseBinding.AUTO;
		term.cursor_blink_mode = Vte.CursorBlinkMode.SYSTEM;
		term.cursor_shape = Vte.CursorShape.UNDERLINE;
		//term.rewrap_on_resize = true;
		
		term.scroll_on_keystroke = true;
		term.scroll_on_output = true;

		// colors -----------------------------

		/* No explicit palette: with foreground and background left unset VTE
		 * draws from the widget's style colours, so the terminal follows the
		 * light/dark theme instead of staying a fixed grey slab in both. */
		term.set_colors(null, null, null);
		
		// grab focus ----------------
		
		term.grab_focus();

		present();
	}

	public void start_shell(){
		
		string[] argv = new string[1];
		argv[0] = "/bin/sh";

		string[] env = Environ.get();
		
		is_running = true;

		/* VTE removed spawn_sync; spawn_async also sets up the child watch. */
		term.spawn_async(
			Vte.PtyFlags.DEFAULT, //pty_flags
			TEMP_DIR, //working_directory
			argv, //argv
			env, //env
			GLib.SpawnFlags.SEARCH_PATH, //spawn_flags
			null, //child_setup
			-1, //timeout
			null, //cancellable
			(terminal, pid, error) => {
				if (error != null){
					log_error (error.message);
					is_running = false;
					return;
				}
				child_pid = pid;
			}
		);
	}

	public void execute_script(string script_path, bool wait = false){
		
		string[] argv = new string[1];
		argv[0] = script_path;
		
		string[] env = Environ.get();

		is_running = true;

		if (!child_exited_connected){
			term.child_exited.connect(script_exit);
			child_exited_connected = true;
		}

		/* VTE removed spawn_sync; spawn_async also sets up the child watch. */
		term.spawn_async(
			Vte.PtyFlags.DEFAULT, //pty_flags
			TEMP_DIR, //working_directory
			argv, //argv
			env, //env
			GLib.SpawnFlags.SEARCH_PATH, //spawn_flags
			null, //child_setup
			-1, //timeout
			null, //cancellable
			(terminal, pid, error) => {
				if (error != null){
					log_error (error.message);
					is_running = false;
					return;
				}
				child_pid = pid;
			}
		);

		if (wait){
			while (is_running){
				sleep(200);
				gtk_do_events();
			}
		}
	}

	public void script_exit(int status){

		is_running = false;

		header.show_title_buttons = true;
		
		this.visible = false;

		//no need to check status again
		
		//destroying parent will display main window
		if (parent_win != null){
			parent_win.destroy();
		}
	}
}


