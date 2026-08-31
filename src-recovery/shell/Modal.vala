/*
 * Modal.vala
 *
 * The in-app dialog layer for the Timeshift recovery shell.
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

public delegate void ConfirmFunc();
public delegate void PasswordFunc(string password);

/* Hand-rolled rather than Gtk.AlertDialog.
 *
 * AlertDialog spawns its own toplevel, which under a bare labwc session gets
 * no decoration and none of this program's stylesheet -- it rendered as a
 * cramped box with an empty strip above the text.
 *
 * The layer is an overlay child above the whole page stack, so a dialog raised
 * from the network page does not vanish when the stack switches. */
public class Modal : GLib.Object {

	private Gtk.Box layer;

	public Modal(Gtk.Overlay overlay) {
		layer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		layer.add_css_class("rs-modal-scrim");
		layer.halign = Gtk.Align.FILL;
		layer.valign = Gtk.Align.FILL;
		layer.visible = false;
		overlay.add_overlay(layer);
	}

	public void close() {
		Gtk.Widget? child = layer.get_first_child();
		while (child != null) {
			Gtk.Widget? next = child.get_next_sibling();
			layer.remove(child);
			child = next;
		}
		layer.visible = false;
	}

	public Gtk.Box open(string title, string body) {

		close();

		var card = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_L);
		card.add_css_class("rs-dialog");
		card.halign = Gtk.Align.CENTER;
		// valign only centers a Box child that has room to move in
		card.vexpand = true;
		card.valign = Gtk.Align.CENTER;
		card.set_size_request(460, -1);

		var t = new Gtk.Label(title);
		t.add_css_class("rs-dialog-title");
		t.halign = Gtk.Align.START;
		t.wrap = true;
		t.xalign = 0;
		card.append(t);

		if (body.length > 0) {
			var b = new Gtk.Label(body);
			b.add_css_class("rs-dialog-body");
			b.halign = Gtk.Align.START;
			b.wrap = true;
			b.xalign = 0;
			card.append(b);
		}

		layer.append(card);
		layer.visible = true;

		return card;
	}

	public Gtk.Box buttons(Gtk.Box card) {
		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_S);
		row.halign = Gtk.Align.END;
		row.margin_top = SPACE_S;
		card.append(row);
		return row;
	}

	public void message(string title, string body) {
		var card = open(title, body);
		var row = buttons(card);
		var ok = new Gtk.Button.with_label("OK");
		ok.add_css_class("rs-primary");
		ok.clicked.connect(() => { close(); });
		row.append(ok);
	}

	public void confirm(string title, string body, string confirm_label,
	                    bool destructive, owned ConfirmFunc on_confirm) {

		var card = open(title, body);
		var row = buttons(card);

		var cancel = new Gtk.Button.with_label("Cancel");
		cancel.clicked.connect(() => { close(); });
		row.append(cancel);

		var go = new Gtk.Button.with_label(confirm_label);
		go.add_css_class(destructive ? "rs-danger" : "rs-primary");
		go.clicked.connect(() => { close(); on_confirm(); });
		row.append(go);
	}

	public void password(string title, string body, owned PasswordFunc on_ok) {

		var card = open(title, body);

		var entry = new Gtk.PasswordEntry();
		entry.show_peek_icon = true;
		entry.hexpand = true;
		card.append(entry);

		var row = buttons(card);

		var cancel = new Gtk.Button.with_label("Cancel");
		cancel.clicked.connect(() => { close(); });
		row.append(cancel);

		var go = new Gtk.Button.with_label("Connect");
		go.add_css_class("rs-primary");
		go.clicked.connect(() => {
			string pw = entry.text;
			close();
			on_ok(pw);
		});
		row.append(go);

		// Enter submits, which is what anyone typing a passphrase expects.
		entry.activate.connect(() => { go.clicked(); });
		entry.grab_focus();
	}
}
