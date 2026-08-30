/*
 * ExcludeListSummaryWindow.vala
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

class ExcludeListSummaryWindow : AppWindow {
	
	private Gtk.Label lbl_list;
	private bool for_restore = false;
	
	private int def_width = 560;
	private int def_height = 480;

	public ExcludeListSummaryWindow(bool _for_restore) {

		log_debug("ExcludeListSummaryWindow: ExcludeListSummaryWindow()");
		
		this.title = _("Exclude List Summary");
        this.modal = true;
        this.set_default_size (def_width, def_height);

		this.close_request.connect(() => { notify_closed(); return false; });

		for_restore = _for_restore;

		var header = new Gtk.HeaderBar();
		set_titlebar(header);
		
        var vbox_main = new Gtk.Box(Orientation.VERTICAL, Ui.Spacing.SM);
        Ui.as_page(vbox_main);
        set_child(vbox_main);

		Ui.add_body(vbox_main, _("Files & directories matching the patterns below will be excluded. Patterns starting with a + will include the item instead of excluding."));

		lbl_list = new Gtk.Label("");
		lbl_list.xalign = (float) 0.0;
		lbl_list.yalign = (float) 0.0;
		lbl_list.wrap = true;
		lbl_list.wrap_mode = Pango.WrapMode.WORD_CHAR;
		lbl_list.selectable = true;
		lbl_list.add_css_class("ts-body");
		set_margin_all(lbl_list, Ui.Spacing.SM);

		var scroll = Ui.add_boxed_list(vbox_main, lbl_list);
		scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

		refresh();
		
		present();

		log_debug("ExcludeListSummaryWindow: ExcludeListSummaryWindow(): exit");
    }

	public void refresh(){

		Gee.ArrayList<string> list;
		
		if (for_restore){
			list = App.create_exclude_list_for_restore();
		}
		else{
			list = App.create_exclude_list_for_backup();
		}
		
		var txt = "";
		foreach(var pattern in list){
			if (pattern.strip().length > 0){
				txt += "%s\n".printf(pattern);
			}
		}
		
		lbl_list.label = txt;
	}
}
