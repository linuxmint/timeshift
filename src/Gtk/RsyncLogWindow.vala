/*
 * RsyncLogWindow.vala
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

public class RsyncLogWindow : AppWindow {

	//window
	private int def_width = 900;
	private int def_height = 640;

	private RsyncLogBox logbox;
	private string rsync_log_file;

	/* A snapshot's log, read by the daemon.
	 *
	 * snapshot may be empty, which is the restore wizard's case: the log is
	 * then parsed locally from the path, because it is being written by the
	 * restore running in this process. */
	public RsyncLogWindow.for_snapshot(string snapshot, string log_name,
		string nominal_path) {

		this(nominal_path, snapshot, log_name);
	}

	public RsyncLogWindow(string _rsync_log_file, string snapshot = "",
		string log_name = "") {

		log_debug("RsyncLogWindow: RsyncLogWindow()");
		
		this.title = _("Rsync Log Viewer");
		this.set_default_size(def_width, def_height);
		this.resizable = true;
		this.modal = true;

		this.close_request.connect(on_delete_event);

		var header = new Gtk.HeaderBar();
		set_titlebar(header);

		Ui.close_on_escape(this); // blocked by on_delete_event while parsing

		rsync_log_file = _rsync_log_file;
		
		logbox = new RsyncLogBox(this);
		Ui.as_page(logbox);
		this.set_child(logbox);
		
		this.visible = true;

		if (snapshot.length > 0){
			logbox.open_snapshot_log(snapshot, log_name, rsync_log_file);
		}
		else {
			logbox.open_log(rsync_log_file);
		}

		log_debug("RsyncLogWindow: RsyncLogWindow(): exit");
	}

	private bool on_delete_event(){
		
		if (logbox.is_running){
			return true; // keep window open
		}
		else{
			this.close_request.disconnect(on_delete_event); //disconnect this handler
			notify_closed();
			return false; // close window
		}
	}

}
