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
	
	private weak Gtk.Window parent_window; // back-reference: the window owns this box
	
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

		/* Measure in the daemon when there is one.
		 *
		 * An estimate is a full filesystem walk, and doing it here means doing
		 * it again in the daemon later for the same number. The daemon writes
		 * the result to timeshift.json, which is where the first backup's
		 * progress denominator comes from, so both ends end up agreeing.
		 *
		 * A daemon that is absent falls through to the local walk. */
		var bridge = new DaemonBridge();

		if (bridge.available() && bridge.begin_estimate()){

			/* Nothing to count -- a dry run's whole output is one number at
			 * the end -- so the bar pulses while the event loop is pumped. */
			while (bridge.running){
				progressbar.pulse();
				gtk_do_events();
				sleep(200);
			}
		}
		else {
			/* No local walk behind this any more. The daemon persists the
			 * result to timeshift.json, and a second estimator writing the
			 * same key from this side is how the two ends come to disagree
			 * about the first backup's denominator. */
			log_error(_("The Timeshift service is not available"));
		}

		LauncherEntry.set_progress_pulse(false);
	}
}
