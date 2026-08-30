/*
 * StatTile.vala
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

/* A big value over its caption over a small subnote, on the card surface. */

public class StatTile : Gtk.Box {

	private Gtk.Label lbl_value;
	private Gtk.Label lbl_caption;
	private Gtk.Label lbl_subnote;

	public StatTile(string caption){

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);

		add_css_class("ts-card");
		halign = Gtk.Align.FILL;
		valign = Gtk.Align.FILL;

		lbl_value = new Gtk.Label("");
		lbl_value.add_css_class("ts-hero-value");
		lbl_value.justify = Gtk.Justification.CENTER;
		append(lbl_value);

		lbl_caption = new Gtk.Label(caption);
		lbl_caption.add_css_class("ts-body");
		lbl_caption.justify = Gtk.Justification.CENTER;
		append(lbl_caption);

		lbl_subnote = new Gtk.Label("");
		lbl_subnote.add_css_class("ts-caption");
		lbl_subnote.justify = Gtk.Justification.CENTER;
		lbl_subnote.ellipsize = Pango.EllipsizeMode.MIDDLE;
		lbl_subnote.max_width_chars = 24;
		append(lbl_subnote);
	}

	public void set_value(string text){
		lbl_value.label = text;
	}

	public void set_subnote(string text){
		lbl_subnote.label = text;
		lbl_subnote.visible = (text.length > 0);
	}
}
