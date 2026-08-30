/*
 * Ui.vala
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

/* Layout vocabulary for the GTK layer.
 *
 * Text helpers attach a .ts-* class from the app stylesheet instead of building
 * Pango markup, so typography is defined once (ThemeStyle) and follows the
 * palette live. Container helpers apply the spacing scale; the rule is that
 * containers own outer margins and boxes own none. */

namespace Ui {

	public const int MAX_CONTENT_WIDTH = 720;

	public enum Spacing {
		XXS = 3,                    // between tightly related lines (grid rows)
		XS = ThemeStyle.SPACE_XS,   // inside a row: icon<->label, linked buttons
		SM = ThemeStyle.SPACE_S,    // between rows inside a card or form
		MD = ThemeStyle.SPACE_M,    // card inner padding; card<->card gap
		LG = ThemeStyle.SPACE_L,    // page outer padding; section gap
		XL = ThemeStyle.SPACE_XL    // status page / hero vertical padding
	}

	// text ---------------------------------------------------------------

	private Gtk.Label make_label(string text, string css_class, bool wrap){

		var label = new Gtk.Label(text);
		label.use_markup = false;
		label.xalign = (float) 0.0;
		label.wrap = wrap;
		label.wrap_mode = Pango.WrapMode.WORD_CHAR;
		label.add_css_class(css_class);
		return label;
	}

	public Gtk.Label add_title(Gtk.Box box, string text, int level = 1){

		var label = make_label(text, (level == 1) ? "ts-title-1" : "ts-title-2", true);
		label.margin_bottom = Spacing.SM;
		box.append(label);
		return label;
	}

	public Gtk.Label add_heading(Gtk.Box box, string text){

		var label = make_label(text, "ts-heading", true);
		box.append(label);
		return label;
	}

	public Gtk.Label add_body(Gtk.Box box, string text, bool wrap = true){

		var label = make_label(text, "ts-body", wrap);
		box.append(label);
		return label;
	}

	public Gtk.Label add_caption(Gtk.Box box, string text){

		var label = make_label(text, "ts-caption", true);
		box.append(label);
		return label;
	}

	public Gtk.Label add_dim_label(Gtk.Box box, string text){

		var label = make_label(text, "ts-dim", true);
		box.append(label);
		return label;
	}

	/* Swap one ts-* text class for another at runtime. */
	public void set_text_style(Gtk.Label label, string css_class){

		foreach (string cls in new string[]{ "ts-title-1", "ts-title-2", "ts-heading",
			"ts-body", "ts-caption", "ts-dim", "ts-hero-value",
			"ts-success", "ts-warning", "ts-error", "ts-accent" }){
			label.remove_css_class(cls);
		}
		label.add_css_class(css_class);
	}

	// containers ---------------------------------------------------------

	/* A framed group with the card surface. */
	public Gtk.Box add_card(Gtk.Box box, Gtk.Orientation orientation = Gtk.Orientation.VERTICAL, int spacing = Spacing.SM){

		var card = new Gtk.Box(orientation, spacing);
		card.add_css_class("ts-card");
		box.append(card);
		return card;
	}

	/* Wraps a list widget in a scroller with the boxed-list frame. */
	public Gtk.ScrolledWindow add_boxed_list(Gtk.Box box, Gtk.Widget list, bool expand = true){

		var scroll = new Gtk.ScrolledWindow();
		scroll.hscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
		scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
		scroll.hexpand = true;
		scroll.vexpand = expand;
		scroll.has_frame = false;
		scroll.add_css_class("ts-boxed-list");
		scroll.set_child(list);
		box.append(scroll);
		return scroll;
	}

	/* Page padding, applied once by the container that hosts a page. */
	public Gtk.Widget as_page(Gtk.Widget page){

		page.add_css_class("ts-page");
		return page;
	}

	/* Removes every child (GTK4 has no Container.get_children()). */
	public void clear_children(Gtk.Box box){

		Gtk.Widget? child = box.get_first_child();
		while (child != null){
			Gtk.Widget? next = child.get_next_sibling();
			box.remove(child);
			child = next;
		}
	}

	/* One row per line, each with a leading accent-coloured bullet. Plain
	 * text; replaces the "&bull; ...\n" markup blobs. */
	public Gtk.Box add_bullets(Gtk.Box box, string[] lines, string css_class = "ts-body"){

		var list = new Gtk.Box(Gtk.Orientation.VERTICAL, Spacing.XS);
		box.append(list);

		foreach (string line in lines){
			if (line.strip().length == 0){ continue; }

			var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Spacing.XS);
			list.append(row);

			var bullet = new Gtk.Label("•");
			bullet.valign = Gtk.Align.START;
			bullet.add_css_class("ts-accent");
			row.append(bullet);

			var label = make_label(line, css_class, true);
			label.hexpand = true;
			row.append(label);
		}

		return list;
	}

	/* A row of buttons. Not homogeneous: buttons take their natural width. */
	public Gtk.Box add_button_row(Gtk.Box box, Gtk.Align align = Gtk.Align.END){

		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Spacing.XS);
		row.halign = align;
		box.append(row);
		return row;
	}

	/* Takes up the slack in a box (replaces the empty-label idiom). */
	public Gtk.Box add_spacer(Gtk.Box box){

		var spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		spacer.hexpand = true;
		spacer.vexpand = true;
		box.append(spacer);
		return spacer;
	}

	// controls -----------------------------------------------------------

	/* Radio semantics via CheckButton.set_group(); pass null for the first. */
	public Gtk.CheckButton add_radio(Gtk.Box box, string text, Gtk.CheckButton? group){

		var radio = new Gtk.CheckButton.with_label(text);
		if (group != null){ radio.set_group(group); }
		box.append(radio);
		return radio;
	}

	/* Icon beside label, the way GTK4 wants it composed. */
	public Gtk.Button add_icon_button(Gtk.Box box, string icon_name, string label, string tooltip){

		var button = new Gtk.Button();
		button.tooltip_text = tooltip;

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Spacing.XS);
		hbox.halign = Gtk.Align.CENTER;

		var img = new Gtk.Image();
		IconManager.set_image_icon(img, icon_name, 16);
		hbox.append(img);

		hbox.append(new Gtk.Label(label));

		button.set_child(hbox);
		box.append(button);
		return button;
	}

	/* Icon-only button, tooltip carries the name. */
	public Gtk.Button add_icon_only_button(Gtk.Box box, string icon_name, string tooltip){

		var button = new Gtk.Button();
		button.tooltip_text = tooltip;

		var img = new Gtk.Image();
		IconManager.set_image_icon(img, icon_name, 16);
		button.set_child(img);

		box.append(button);
		return button;
	}
}
