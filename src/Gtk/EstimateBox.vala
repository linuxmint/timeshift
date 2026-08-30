/*
 * EstimateBox.vala
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

class EstimateBox : TaskProgressBox {
	
	private Gtk.Window parent_window;
	
	public EstimateBox (Gtk.Window _parent_window) {

		base(_("Estimating System Size..."), false);

		log_debug("EstimateBox: EstimateBox()");

		parent_window = _parent_window;

		lbl_msg.label = _("Please wait...");
		lbl_status.visible = false;
		progressbar.pulse_step = 0.01;

		log_debug("EstimateBox: EstimateBox(): exit");
    }

	public void estimate_system_size() {

		if (Main.first_snapshot_size > 0){
			log_debug("EstimateBox: size > 0");
			return;
		}

		// start the estimation if not already running

		log_debug("EstimateBox: thread started");

		LauncherEntry.set_progress_pulse(true);
		progressbar.pulse();

		App.estimate_system_size(progressbar.pulse);

		LauncherEntry.set_progress_pulse(false);
	}
}
