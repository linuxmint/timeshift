/*
 * LogPane.vala
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

/* The raw output of a long-running script, tucked behind a disclosure.
 *
 * This is what the full-screen VTE terminal used to be: everything the script
 * prints, verbatim. It stays collapsed unless asked for, because the designed
 * progress view above it answers the question the terminal never could.
 *
 * The buffer is capped - a full-system restore itemises hundreds of thousands
 * of files - and follows the tail only while the reader is already at the
 * bottom, so scrolling back to read something does not yank the view away. */

public class LogPane : Gtk.Box {

	private Gtk.Expander expander;
	private Gtk.ScrolledWindow scroller;
	private Gtk.TextView view;
	private Gtk.TextBuffer buffer;
	private Gtk.TextMark tail;

	private int line_count = 0;

	private const int MAX_LINES = 5000;
	private const int TRIM_TO = 4000;

	public LogPane(){

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);

		expander = new Gtk.Expander(_("Show technical details"));
		expander.expanded = false;
		append(expander);

		var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.XS);
		vbox.margin_top = Ui.Spacing.XS;
		expander.set_child(vbox);

		// output ------------------------------------------------------

		buffer = new Gtk.TextBuffer(null);

		/* Right gravity, so it stays at the end as text is inserted. Scrolling
		 * to a mark lets GTK do it after the next size allocation; setting the
		 * adjustment by hand reads an upper bound that has not been remeasured
		 * yet, and lands short of the bottom. */
		Gtk.TextIter tail_iter;
		buffer.get_end_iter(out tail_iter);
		tail = buffer.create_mark(null, tail_iter, false);

		view = new Gtk.TextView.with_buffer(buffer);
		view.editable = false;
		view.cursor_visible = false;
		view.monospace = true;
		view.wrap_mode = Gtk.WrapMode.NONE;
		view.left_margin = Ui.Spacing.XS;
		view.right_margin = Ui.Spacing.XS;
		view.top_margin = Ui.Spacing.XS;
		view.bottom_margin = Ui.Spacing.XS;
		view.add_css_class("ts-log");

		scroller = new Gtk.ScrolledWindow();
		scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
		scroller.has_frame = false;
		scroller.min_content_height = 200;
		scroller.hexpand = true;
		scroller.vexpand = true;
		scroller.add_css_class("ts-log-frame");
		scroller.set_child(view);
		vbox.append(scroller);

		// actions -----------------------------------------------------

		var hbox = Ui.add_button_row(vbox);

		var btn_copy = new Gtk.Button.with_label(_("Copy"));
		btn_copy.set_tooltip_text(_("Copy the output to the clipboard"));
		btn_copy.clicked.connect(copy_to_clipboard);
		hbox.append(btn_copy);

		/* Only claim vertical space while the pane is open, so a collapsed
		 * disclosure stays a single row on a crowded wizard page. */
		expander.notify["expanded"].connect(() => {
			this.vexpand = expander.expanded;
		});
	}

	public bool expanded {
		get { return expander.expanded; }
		set { expander.expanded = value; }
	}

	public void set_label(string text){
		expander.label = text;
	}

	public void clear(){
		buffer.set_text("", 0);
		line_count = 0;
	}

	public void append_lines(string[] lines){

		if (lines.length == 0){ return; }

		bool follow = at_bottom();

		var sb = new StringBuilder();

		foreach(string line in lines){
			sb.append(line);
			sb.append("\n");
		}

		Gtk.TextIter iter;
		buffer.get_end_iter(out iter);
		buffer.insert(ref iter, sb.str, -1);

		line_count += lines.length;

		if (line_count > MAX_LINES){
			trim();
		}

		if (follow){
			buffer.get_end_iter(out iter);
			buffer.move_mark(tail, iter);
			view.scroll_to_mark(tail, 0, true, 0, 1);
		}
	}

	private void trim(){

		Gtk.TextIter start, cut;
		buffer.get_start_iter(out start);
		buffer.get_iter_at_line(out cut, line_count - TRIM_TO);
		buffer.delete(ref start, ref cut);

		line_count = TRIM_TO;
	}

	private bool at_bottom(){

		var adj = scroller.vadjustment;

		if (adj == null){ return true; }

		// within one line of the end counts as "still following"
		return ((adj.value + adj.page_size) >= (adj.upper - 24));
	}

	private void copy_to_clipboard(){

		var display = Gdk.Display.get_default();

		if (display == null){ return; }

		display.get_clipboard().set_text(buffer.text);
	}
}
