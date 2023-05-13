/*
 * RestoreBox.vala
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

#if XAPP
using XApp;
#endif

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

class RestoreBox : Gtk.Box{

	public Gtk.Label lbl_header;
	
	private Gtk.Spinner spinner;
	public Gtk.Label lbl_msg;
	public Gtk.Label lbl_status;
	public Gtk.Label lbl_remaining;
	public Gtk.ProgressBar progressbar;
	public Gtk.Label lbl_unchanged;
	public Gtk.Label lbl_created;
	public Gtk.Label lbl_deleted;
	public Gtk.Label lbl_modified;
	public Gtk.Label lbl_checksum;
	public Gtk.Label lbl_size;
	public Gtk.Label lbl_timestamp;
	public Gtk.Label lbl_permissions;
	public Gtk.Label lbl_owner;
	public Gtk.Label lbl_group;

	private Gtk.Window parent_window;

	private bool thread_is_running = false;

	public RestoreBox(Gtk.Window _parent_window) {

		log_debug("RestoreBox: RestoreBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;

		// header
		if (App.dry_run){
			lbl_header = add_label_header(this, _("Comparing Files (Dry Run)..."), true);
		}
		else{
			lbl_header = add_label_header(this, _("Restoring Snapshot..."), true);
		}

		var hbox_status = new Gtk.Box(Orientation.HORIZONTAL, 6);
		add (hbox_status);
		
		spinner = new Gtk.Spinner();
		spinner.active = true;
		hbox_status.add(spinner);
		
		//lbl_msg
		lbl_msg = add_label(hbox_status, _("Preparing..."));
		lbl_msg.hexpand = true;
		lbl_msg.ellipsize = Pango.EllipsizeMode.END;
		lbl_msg.max_width_chars = 50;

		lbl_remaining = add_label(hbox_status, "");

		//progressbar
		progressbar = new Gtk.ProgressBar();
		//progressbar.set_size_request(-1,25);
		//progressbar.show_text = true;
		//progressbar.pulse_step = 0.1;
		add (progressbar);

		//lbl_status

		lbl_status = add_label(this, "");
		lbl_status.ellipsize = Pango.EllipsizeMode.MIDDLE;
		lbl_status.max_width_chars = 45;
		lbl_status.margin_bottom = 12;

		// TODO: Add move to background button

		var label = add_label(this, "");
		label.vexpand = true;
		
		// add count labels ---------------------------------
		
		Gtk.SizeGroup sg_label = null;
		Gtk.SizeGroup sg_value = null;

		label = add_label(this, _("Files and directory counts:"), true);
		label.margin_bottom = 6;
		
		lbl_unchanged = add_count_label(this, _("No Change"), ref sg_label, ref sg_value);
		lbl_created = add_count_label(this, _("Created"), ref sg_label, ref sg_value);
		lbl_deleted = add_count_label(this, _("Deleted"), ref sg_label, ref sg_value);
		lbl_modified = add_count_label(this, _("Changed"), ref sg_label, ref sg_value, 12);

		label = add_label(this, _("Changed items:"), true);
		label.margin_bottom = 6;
		
		lbl_checksum = add_count_label(this, _("Checksum"), ref sg_label, ref sg_value);
		lbl_size = add_count_label(this, _("Size"), ref sg_label, ref sg_value);
		lbl_timestamp = add_count_label(this, _("Timestamp"), ref sg_label, ref sg_value);
		lbl_permissions = add_count_label(this, _("Permissions"), ref sg_label, ref sg_value);
		lbl_owner = add_count_label(this, _("Owner"), ref sg_label, ref sg_value);
		lbl_group = add_count_label(this, _("Group"), ref sg_label, ref sg_value, 24);

		log_debug("RestoreBox: RestoreBox(): exit");
    }

	private Gtk.Label add_count_label(Gtk.Box box, string text,
		ref Gtk.SizeGroup? sg_label, ref Gtk.SizeGroup? sg_value,
		int add_margin_bottom = 0){
			
		var hbox = new Gtk.Box(Orientation.HORIZONTAL, 6);
		box.add (hbox);

		var label = add_label(hbox, text + ":");
		label.xalign = (float) 1.0;
		label.margin_start = 12;
		label.margin_end = 6;

		if (add_margin_bottom > 0){
			label.margin_bottom = add_margin_bottom;
		}

		// add to size group
		if (sg_label == null){
			sg_label = new Gtk.SizeGroup(SizeGroupMode.HORIZONTAL);
		}
		sg_label.add_widget(label);

		label = add_label(hbox, "");
		label.xalign = (float) 0.0;

		if (add_margin_bottom > 0){
			label.margin_bottom = add_margin_bottom;
		}

		// add to size group
		if (sg_value == null){
			sg_value = new Gtk.SizeGroup(SizeGroupMode.HORIZONTAL);
		}
		sg_value.add_widget(label);

		return label;
	}

	public bool restore(){

		log_debug("RestoreBox: restore()");
		
		if (App.restore_current_system && !App.dry_run){
			parent_window.hide();
		}

		if (App.dry_run){
			lbl_header.label = format_text(_("Comparing Files (Dry Run)..."), true, false, true);
		}
		else{
			lbl_header.label = format_text(_("Restoring Snapshot..."), true, false, true);
		}
		
		try {
			thread_is_running = true;
			new Thread<void>.try ("restore", () => {restore_thread();});
		}
		catch (Error e) {
			log_error (e.message);
		}

		//string last_message = "";
		int wait_interval_millis = 100;
		int status_line_counter = 0;
		int status_line_counter_default = 1000 / wait_interval_millis;
		string status_line = "";
		string last_status_line = "";
		int remaining_counter = 10;
		
		while (thread_is_running){

			status_line = escape_html(App.task.status_line);
			
			if (status_line != last_status_line){
				
				lbl_status.label = status_line;
				last_status_line = status_line;
				status_line_counter = status_line_counter_default;
			}
			else{
				status_line_counter--;
				
				if (status_line_counter < 0){
					status_line_counter = status_line_counter_default;
					lbl_status.label = "";
				}
			}

			// TODO: show estimated time remaining and file counts

			double fraction = App.task.progress;

			// time remaining
			remaining_counter--;
			
			if (remaining_counter == 0){
				
				lbl_remaining.label = App.task.stat_time_remaining + " " + _("remaining");

				remaining_counter = 10;
			}	
			
			if (fraction < 0.99){
				
				progressbar.fraction = fraction;

				#if XAPP
				XApp.set_window_progress(parent_window, (int)(fraction * 100.0));
				#endif
			}

			lbl_msg.label = App.progress_text;

			lbl_unchanged.label = "%'d".printf(App.task.count_unchanged);
			lbl_created.label = "%'d".printf(App.task.count_created);
			lbl_deleted.label = "%'d".printf(App.task.count_deleted);
			lbl_modified.label = "%'d".printf(App.task.count_modified);
			lbl_checksum.label = "%'d".printf(App.task.count_checksum);
			lbl_size.label = "%'d".printf(App.task.count_size);
			lbl_timestamp.label = "%'d".printf(App.task.count_timestamp);
			lbl_permissions.label = "%'d".printf(App.task.count_permissions);
			lbl_owner.label = "%'d".printf(App.task.count_owner);
			lbl_group.label = "%'d".printf(App.task.count_group);

			gtk_do_events();

			sleep(100);
			//gtk_do_events();
		}

		#if XAPP
		XApp.set_window_progress(parent_window, 0);
		#endif
		
		if (App.restore_current_system && !App.dry_run){
			parent_window.show();
		}

		log_debug("RestoreBox: restore(): exit");

		return (App.task.exit_code == 0);
	}
	
	private void restore_thread(){
		
		log_debug("RestoreBox: restore_thread()");
		App.restore_snapshot(parent_window);
		thread_is_running = false;
		log_debug("RestoreBox: restore_thread(): exit");
	}
}
