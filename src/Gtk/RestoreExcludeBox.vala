/*
 * RestoreExcludeBox.vala
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

class RestoreExcludeBox : Gtk.Box{
	
	//private Gtk.CheckButton chk_web;
	private Gtk.CheckButton chk_other;
	private Gtk.CheckButton chk_web;
	private Gtk.CheckButton chk_torrent;
	
	private Gtk.Window parent_window;

	public RestoreExcludeBox (Gtk.Window _parent_window) {

		log_debug("RestoreExcludeBox: RestoreExcludeBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;

		// app settings header --------------------------------
		
		var label = add_label_header(this, _("Exclude Application Settings"), true);

		add_label(this, _("Select applications to exclude from restore"));

		// web browsers --------------------------------

		var chk = add_checkbox(this, _("Web Browsers") + " (%s)".printf(_("Recommended")));
		chk.active = true;
		chk.margin_top = 12;
		chk.margin_bottom = 0;
		chk_web = chk;
		
		chk.toggled.connect(()=>{
			foreach(var name in new string[]{
				"chromium", "google-chrome", "mozilla", "midori", "epiphany",
				"opera", "opera-stable", "opera-beta", "opera-developer" }){
				if (AppExcludeEntry.app_map.has_key(name)){
					AppExcludeEntry.app_map[name].enabled = chk_web.active;
				}
			}
		});
		
		label = add_label(
			this, _("Firefox, Chromium, Chrome, Opera, Epiphany, Midori"), false, true);
		label.margin_top = 0;
		label.margin_bottom = 6;
		label.margin_start = 24;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD_CHAR;

		var tt = _("Keep configuration files for web browsers like Firefox and Chrome. If un-checked, previous configuration files will be restored from snapshot");
		chk.set_tooltip_text(tt);
		label.set_tooltip_text(tt);

		// torrent clients ----------------------------
		
		chk = add_checkbox(this, _("Bittorrent Clients") + " (%s)".printf(_("Recommended")));
		chk.active = true;
		chk.margin_bottom = 0;
		chk_torrent = chk;
		
		chk.toggled.connect(()=>{
			foreach(var name in new string[]{
				"deluge", "transmission" }){
				if (AppExcludeEntry.app_map.has_key(name)){
					AppExcludeEntry.app_map[name].enabled = chk_torrent.active;
				}
			}
		});
		
		label = add_label(this, _("Deluge, Transmission"), false, true);
		label.margin_top = 0;
		label.margin_bottom = 6;
		label.margin_start = 24;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD_CHAR;

		tt = _("Keep configuration files for bittorrent clients like Deluge, Transmission, etc. If un-checked, previous configuration files will be restored from snapshot.");
		chk.set_tooltip_text(tt);
		label.set_tooltip_text(tt);

		// all apps ----------------------------
		
		chk = add_checkbox(this, _("Other applications (next page)"));
		chk_other = chk;

		tt = _("Show more applications to exclude on the next page");
		chk.set_tooltip_text(tt);

		// TODO: medium: add more exclude options

		log_debug("RestoreExcludeBox: RestoreExcludeBox(): exit");
    }

    public void refresh(){
		
		chk_web.toggled();
		chk_torrent.toggled();
	}

	public bool show_all_apps(){
		
		return chk_other.active;
	}	
}
