/*
 * TerminalPage.vala
 *
 * The VTE terminal page of the Timeshift recovery shell.
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

public class TerminalPage : Page {

	private Vte.Terminal term;
	private Gtk.Label title_label;
	private Gtk.Button back_button;

	public TerminalPage(RecoveryWindow shell) {
		base(shell);
	}

	public override string key() { return "terminal"; }

	public override Gtk.Widget build() {

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

		var bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_M);
		bar.margin_top = SPACE_M;
		bar.margin_bottom = SPACE_M;
		bar.margin_start = SPACE_L;
		bar.margin_end = SPACE_L;

		back_button = new Gtk.Button.with_label("Back");
		back_button.clicked.connect(() => { shell.go_home(); });
		bar.append(back_button);

		title_label = new Gtk.Label("");
		title_label.add_css_class("rs-page-title");
		bar.append(title_label);

		box.append(bar);

		term = new Vte.Terminal();
		term.hexpand = true;
		term.vexpand = true;
		term.input_enabled = true;
		term.scroll_on_keystroke = true;
		term.scroll_on_output = true;
		/* VTE ignores the GTK stylesheet: colours and font go in through its
		 * own API, from the same palette. The background equals the window
		 * background, so the margins read as padding with no visible seam. */
		var fg = Gdk.RGBA();
		fg.parse(C_TEXT);
		var bg = Gdk.RGBA();
		bg.parse(C_BG);
		var pal = new Gdk.RGBA[16];
		for (int i = 0; i < TERM_PALETTE.length; i++) {
			pal[i] = Gdk.RGBA();
			pal[i].parse(TERM_PALETTE[i]);
		}
		term.set_colors(fg, bg, pal);
		term.set_font(Pango.FontDescription.from_string("Monospace 11"));
		term.set_scrollback_lines(10000);
		term.margin_start = SPACE_M;
		term.margin_end = SPACE_M;
		term.margin_bottom = SPACE_M;
		box.append(term);

		term.child_exited.connect((status) => {
			back_button.label = "Back";
		});

		return box;
	}

	public void open(string title, string[] argv) {

		title_label.label = title;
		shell.show_page("terminal");

		back_button.label = "Back (running)";

		/* Set TERM explicitly. The shell is started by labwc from a profile with
		 * no TERM, and a curses program inheriting that draws nothing. */
		var env = new Gee.ArrayList<string>();
		foreach (string e in Environ.get()) {
			if (!e.has_prefix("TERM=")) { env.add(e); }
		}
		env.add("TERM=xterm-256color");

		try {
			term.spawn_async(
				Vte.PtyFlags.DEFAULT,
				"/root",
				argv,
				env.to_array(),
				GLib.SpawnFlags.SEARCH_PATH,
				null,
				-1,
				null,
				(terminal, pid, error) => {
					if (error != null) {
						warning("could not start %s: %s", title, error.message);
					}
				}
			);
		}
		catch (Error e) {
			warning("could not start %s: %s", title, e.message);
		}

		term.grab_focus();
	}
}
