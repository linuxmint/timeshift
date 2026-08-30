/*
 * StatusCard.vala
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

/* Shield icon beside a title and a subtitle, on the card surface. Used for
 * the protection status on the main window and the schedule page. */

public class StatusCard : Gtk.Box {

	private Gtk.Image image;
	private Gtk.Label lbl_title;
	private Gtk.Label lbl_subtitle;

	public StatusCard(){

		GLib.Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: Ui.Spacing.MD);

		add_css_class("ts-card");
		hexpand = true;

		image = new Gtk.Image();
		image.pixel_size = IconManager.SHIELD_ICON_SIZE;
		image.valign = Gtk.Align.CENTER;
		append(image);

		var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.XS / 2);
		vbox.hexpand = true;
		vbox.valign = Gtk.Align.CENTER;
		append(vbox);

		lbl_title = new Gtk.Label("");
		lbl_title.add_css_class("ts-title-2");
		lbl_title.xalign = (float) 0.0;
		lbl_title.wrap = true;
		lbl_title.wrap_mode = Pango.WrapMode.WORD_CHAR;
		vbox.append(lbl_title);

		lbl_subtitle = new Gtk.Label("");
		lbl_subtitle.add_css_class("ts-body");
		lbl_subtitle.add_css_class("ts-dim");
		lbl_subtitle.xalign = (float) 0.0;
		lbl_subtitle.wrap = true;
		lbl_subtitle.wrap_mode = Pango.WrapMode.WORD_CHAR;
		vbox.append(lbl_subtitle);
	}

	/* The three timeshift-shield-* files are full-colour art and go through
	 * the texture path; anything else is a themed (recolouring) icon. */
	public void set_shield(string icon_name){

		if (icon_name.has_prefix("timeshift-shield")){
			image.paintable = IconManager.lookup_texture(icon_name, IconManager.SHIELD_ICON_SIZE, image.scale_factor);
		}
		else {
			IconManager.set_image_icon(image, icon_name, IconManager.SHIELD_ICON_SIZE);
		}
	}

	public void set_title(string text){
		lbl_title.label = text;
	}

	public void set_subtitle(string text){
		lbl_subtitle.label = text;
		lbl_subtitle.visible = (text.length > 0);
	}
}
