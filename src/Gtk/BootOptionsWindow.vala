/*
 * BootOptionsWindow.vala
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

class BootOptionsWindow : AppWindow {
	
	private BootOptionsBox boot_options_box;

	public BootOptionsWindow() {

		log_debug("BootOptionsWindow: BootOptionsWindow()");
		
		this.title = _("Bootloader Options");
        this.modal = true;
        this.set_default_size(520, -1);

		this.close_request.connect(on_delete_event);

		var header = new Gtk.HeaderBar();
		set_titlebar(header);

		boot_options_box = new BootOptionsBox(this);
		Ui.as_page(boot_options_box);
		boot_options_box.hexpand = true;
		boot_options_box.vexpand = true;
		set_child(boot_options_box);

		present();

		log_debug("BootOptionsWindow: BootOptionsWindow(): exit");
    }

	private bool on_delete_event(){

		notify_closed();
		
		return false; // close window
	}
}
