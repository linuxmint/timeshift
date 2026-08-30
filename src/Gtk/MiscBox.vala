/*
 * MiscBox.vala
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

class MiscBox : Gtk.Box{
	
	private Gtk.Window parent_window;
	private bool restore_mode = false;

	public MiscBox (Gtk.Window _parent_window, bool _restore_mode) {

		log_debug("MiscBox: MiscBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		restore_mode = _restore_mode;
		
		var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
		vbox.hexpand = true;
		vbox.vexpand = true;
		this.append(vbox);

		// ------------------------
		
		init_date_format_option(vbox);

		refresh();
		
		log_debug("MiscBox: MiscBox(): exit");
    }

	private void init_date_format_option(Gtk.Box box){

		log_debug("MiscBox: init_date_format_option()");

		Ui.add_heading(box, _("Date Format"));

		Ui.add_dim_label(box, _("How snapshot dates are shown in the list."));

		var card = Ui.add_card(box);

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		card.append(hbox);

		/* GTK4 deprecates Gtk.ComboBox; Gtk.DropDown over a Gtk.StringList of
		 * the raw format strings, with a factory rendering a live preview. */

		var formats = new string[]{
			"", // custom
			"%Y-%m-%d %H:%M:%S", // 2019-08-11 20:00:00
			"%Y-%m-%d %I:%M %p", // 2019-08-11 08:00 PM
			"%d %b %Y %I:%M %p", // 11 Aug 2019 08:00 PM
			"%Y %b %d, %I:%M %p", // 2019 Aug 11, 08:00 PM
			"%c"                 // Sunday, 11 August 2019 08:00:00 PM IST
			};

		var now = new DateTime.local(2019, 8, 11, 20, 25, 43);

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = new Gtk.Label("");
			lbl.xalign = (float) 0.0;
			list_item.set_child(lbl);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = (Gtk.Label) list_item.get_child();
			var str_obj = (Gtk.StringObject) list_item.get_item();
			string txt = str_obj.get_string();
			lbl.label = (txt.length == 0) ? _("Custom") : now.format(txt);
		});

		var combo = new Gtk.DropDown(new Gtk.StringList(formats), null);
		combo.factory = factory;
		combo.hexpand = true;
		hbox.append(combo);

		var entry = new Gtk.Entry();
		entry.hexpand = true;
		hbox.append(entry);

		uint active = 0;
		for (uint i = 0; i < formats.length; i++){
			if (App.date_format == formats[i]){
				active = i;
				break;
			}
		}

		combo.selected = active;

		combo.notify["selected"].connect(() => {

			uint selected = combo.selected;
			if (selected == Gtk.INVALID_LIST_POSITION){ return; }

			string txt = formats[selected];

			string fmt = Main.date_format_default;
			if (txt.length > 0){
				fmt = txt;
			}

			entry.text = fmt;

			entry.sensitive = (txt.length == 0);

			App.date_format = fmt;
		});

		entry.text = App.date_format;

		entry.sensitive = (combo.selected == 0);

		var focus = new Gtk.EventControllerFocus();
		focus.leave.connect(() => {
			App.date_format = entry.text;
			log_debug("saved date_format: %s".printf(App.date_format));
		});
		entry.add_controller(focus);
		
		this.visible = true;

		log_debug("MiscBox: init_date_format_option(): exit");
	}

	// helpers

	public void refresh(){

		if (App.btrfs_mode){

			//chk_include_btrfs_home.active = App.include_btrfs_home_for_restore;
		}
		else{

			//chk_include_btrfs_home
		}

		this.visible = true;
	}
}
