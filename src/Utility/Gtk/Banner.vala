/*
 * Banner.vala
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

/* Replacement for Gtk.InfoBar, which GTK4 deprecates.
 *
 * A coloured strip with an icon and a message. Colours come from the app
 * stylesheet (AppTheme) through the .ts-banner.{info,success,warning,error}
 * classes, so they follow the palette live. The strip hides itself while it
 * has nothing to say. */

public class Banner : Gtk.Box {

	private Gtk.Image image;
	private Gtk.Label label;

	private Gtk.MessageType _message_type = Gtk.MessageType.INFO;

	public Gtk.MessageType message_type {
		get { return _message_type; }
		set {
			_message_type = value;
			apply_style();
		}
	}

	public Banner(){

		GLib.Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: ThemeStyle.SPACE_S);

		add_css_class("ts-banner");

		image = new Gtk.Image();
		image.valign = Gtk.Align.START;
		image.pixel_size = 16;
		append(image);

		label = new Gtk.Label("");
		label.xalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD_CHAR;
		label.hexpand = true;
		label.add_css_class("ts-heading");
		append(label);

		visible = false;

		apply_style();
	}

	/* Plain text -- not markup -- so device names and paths need no escaping.
	 * An empty text hides the strip. */
	public void set_message(string text, Gtk.MessageType type = Gtk.MessageType.INFO){

		label.label = text;
		message_type = type;
		visible = (text.length > 0);
	}

	public void clear(){
		set_message("");
	}

	private void apply_style(){

		remove_css_class("error");
		remove_css_class("warning");
		remove_css_class("info");
		remove_css_class("success");

		switch (_message_type){
		case Gtk.MessageType.ERROR:
			add_css_class("error");
			image.icon_name = "dialog-error-symbolic";
			break;
		case Gtk.MessageType.WARNING:
			add_css_class("warning");
			image.icon_name = "dialog-warning-symbolic";
			break;
		case Gtk.MessageType.OTHER:
			add_css_class("success");
			image.icon_name = "emblem-ok-symbolic";
			break;
		default:
			add_css_class("info");
			image.icon_name = "dialog-information-symbolic";
			break;
		}
	}
}
