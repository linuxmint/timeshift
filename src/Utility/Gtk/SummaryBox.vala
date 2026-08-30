/*
 * SummaryBox.vala
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

using TeeJee.GtkHelper;

/* The finish page shared by the wizards: an outcome icon and header, a body
 * of bullet points (or prose), and a footer line. */

public class SummaryBox : Gtk.Box {

	private Gtk.Image image;
	private Gtk.Label lbl_header;
	private Gtk.Box body;
	private Gtk.Label lbl_footer;

	public SummaryBox(string header){

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM);

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.SM);
		append(hbox);

		image = new Gtk.Image();
		image.pixel_size = 32;
		image.valign = Gtk.Align.CENTER;
		image.visible = false;
		hbox.append(image);

		lbl_header = new Gtk.Label(header);
		lbl_header.add_css_class("ts-title-1");
		lbl_header.xalign = (float) 0.0;
		lbl_header.wrap = true;
		lbl_header.wrap_mode = Pango.WrapMode.WORD_CHAR;
		lbl_header.hexpand = true;
		hbox.append(lbl_header);

		var scroll = new Gtk.ScrolledWindow();
		scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
		scroll.hexpand = true;
		scroll.vexpand = true;
		append(scroll);

		body = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.SM);
		body.margin_top = Ui.Spacing.SM;
		scroll.set_child(body);

		lbl_footer = new Gtk.Label("");
		lbl_footer.add_css_class("ts-heading");
		lbl_footer.xalign = (float) 0.0;
		lbl_footer.margin_top = Ui.Spacing.SM;
		lbl_footer.visible = false;
		append(lbl_footer);
	}

	public void set_header(string text){
		lbl_header.label = text;
	}

	/* success -> a tick, failure -> a warning; null hides the icon. */
	public void set_outcome(bool? success){

		if (success == null){
			image.visible = false;
			return;
		}

		image.set_from_icon_name(success ? "emblem-ok-symbolic" : "dialog-warning-symbolic");
		image.remove_css_class("ts-success");
		image.remove_css_class("ts-warning");
		image.add_css_class(success ? "ts-success" : "ts-warning");
		image.visible = true;
	}

	private void clear_body(){

		Gtk.Widget? child = body.get_first_child();
		while (child != null){
			Gtk.Widget? next = child.get_next_sibling();
			body.remove(child);
			child = next;
		}
	}

	/* One row per line, each prefixed with a bullet. Plain text. */
	public void set_bullets(string[] lines){

		clear_body();

		foreach (string line in lines){
			if (line.strip().length == 0){ continue; }

			var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
			body.append(row);

			var bullet = new Gtk.Label("•");
			bullet.valign = Gtk.Align.START;
			bullet.add_css_class("ts-accent");
			row.append(bullet);

			var label = new Gtk.Label(line);
			label.add_css_class("ts-body");
			label.xalign = (float) 0.0;
			label.wrap = true;
			label.wrap_mode = Pango.WrapMode.WORD_CHAR;
			label.hexpand = true;
			row.append(label);
		}
	}

	/* Prose body; markup only when the caller says so (core-generated text). */
	public void set_body(string text, bool markup = false){

		clear_body();

		var label = new Gtk.Label(text);
		label.use_markup = markup;
		label.add_css_class("ts-body");
		label.xalign = (float) 0.0;
		label.yalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD_CHAR;
		label.hexpand = true;
		body.append(label);
	}

	public void set_footer(string text){
		lbl_footer.label = text;
		lbl_footer.visible = (text.length > 0);
	}
}
