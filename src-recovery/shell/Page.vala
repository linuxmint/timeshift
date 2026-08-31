/*
 * Page.vala
 *
 * The base class every screen of the Timeshift recovery shell derives from.
 *
 * Copyright 2026 makeafide <willsmit4433@gmail.com>
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
 */

using RecoveryTheme;

/* A page owns its widgets and nothing else. Everything shared -- navigation,
 * dialogs, the terminal, launching a program -- is reached through `shell`,
 * which is the only reference a page holds outside itself. */
public abstract class Page : GLib.Object {

	protected RecoveryWindow shell;

	protected Page(RecoveryWindow shell) {
		this.shell = shell;
	}

	/* The Gtk.Stack name. Also what show_page() is called with. */
	public abstract string key();

	/* Called once, at construction. */
	public abstract Gtk.Widget build();

	/* Called every time the page is navigated to. Pages that read the machine
	 * refresh here rather than making every caller remember to. */
	public virtual void on_shown() { }

	/* A page header: Back on the left, title, then optional trailing widgets. */
	protected Gtk.Box page_header(string title, out Gtk.Box trailing) {

		var bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_M);
		bar.margin_bottom = SPACE_S;

		var back = new Gtk.Button();
		var back_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_S);
		back_row.append(new Gtk.Image.from_icon_name("go-previous-symbolic"));
		back_row.append(new Gtk.Label("Back"));
		back.set_child(back_row);
		back.clicked.connect(() => { shell.go_home(); });
		bar.append(back);

		var l = new Gtk.Label(title);
		l.add_css_class("rs-page-title");
		bar.append(l);

		var spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		spacer.hexpand = true;
		bar.append(spacer);

		trailing = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_S);
		bar.append(trailing);

		return bar;
	}

	/* A small caps heading between groups of rows. The caps come from the call
	 * site; spacing and a brighter grey carry the hierarchy, not pure dimness. */
	protected void section(Gtk.Box box, string title) {
		var l = new Gtk.Label(title);
		l.halign = Gtk.Align.START;
		l.add_css_class("rs-section");
		box.append(l);
	}
}
