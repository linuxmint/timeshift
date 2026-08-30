/*
 * StatusPage.vala
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
 */

/* Empty-state page: a large dim icon, a title, a description and an optional
 * action, centred in whatever space it is given. */

public class StatusPage : Gtk.Box {

	private Gtk.Image image;
	private Gtk.Label lbl_title;
	private Gtk.Label lbl_description;
	private Gtk.Box action_slot;
	private Gtk.Widget? action = null;

	public StatusPage(string icon_name, string title, string description){

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM);

		add_css_class("ts-status-page");
		halign = Gtk.Align.CENTER;
		valign = Gtk.Align.CENTER;
		hexpand = true;
		vexpand = true;

		image = new Gtk.Image();
		image.pixel_size = 96;
		image.halign = Gtk.Align.CENTER;
		image.margin_bottom = Ui.Spacing.SM;
		append(image);

		lbl_title = new Gtk.Label("");
		lbl_title.add_css_class("ts-title-1");
		lbl_title.justify = Gtk.Justification.CENTER;
		lbl_title.wrap = true;
		lbl_title.max_width_chars = 40;
		append(lbl_title);

		lbl_description = new Gtk.Label("");
		lbl_description.add_css_class("ts-body");
		lbl_description.add_css_class("ts-dim");
		lbl_description.justify = Gtk.Justification.CENTER;
		lbl_description.wrap = true;
		lbl_description.wrap_mode = Pango.WrapMode.WORD_CHAR;
		lbl_description.max_width_chars = 60;
		append(lbl_description);

		action_slot = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		action_slot.halign = Gtk.Align.CENTER;
		action_slot.margin_top = Ui.Spacing.MD;
		action_slot.visible = false;
		append(action_slot);

		set_icon(icon_name);
		set_title(title);
		set_description(description);
	}

	public void set_icon(string icon_name){
		image.set_from_icon_name(icon_name);
	}

	public void set_title(string text){
		lbl_title.label = text;
	}

	public void set_description(string text){
		lbl_description.label = text;
		lbl_description.visible = (text.length > 0);
	}

	public void set_action(Gtk.Widget? widget){

		if (action != null){
			action_slot.remove(action);
		}

		action = widget;

		if (action != null){
			action_slot.append(action);
		}

		action_slot.visible = (action != null);
	}
}
