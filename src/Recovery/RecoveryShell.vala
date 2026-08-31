/*
 * RecoveryShell.vala
 *
 * The launcher shown in the Timeshift recovery environment.
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

/* This is deliberately NOT built from the Timeshift core.
 *
 * The launcher needs to run a program, run a program in a terminal, list block
 * devices, mount one, and drive NetworkManager. Core's Device is a 2100-line
 * model built for Timeshift's restore logic, and reaching it means linking Main
 * -- the god object that owns all config and all discovered system state, and
 * that AppTheme also reaches through the global App. Pulling that in would make
 * the recovery shell fail to start for any reason Timeshift itself can fail to
 * start, which is precisely the situation this environment exists to recover
 * from.
 *
 * So this shells out to nmcli, lsblk and udisksctl, which is what Core does
 * underneath anyway.
 *
 * Deliberately English-only, no _() marking: the recovery image ships no
 * locale data (mmdebstrap --variant=important carries no language packs), so
 * gettext could never translate these strings at runtime anyway.
 */

using GLib;
using Gtk;

/* Vala marks the whole Gtk.StyleContext class deprecated, but in GTK4 only its
 * instance methods are -- gtk_style_context_add_provider_for_display() is still
 * the supported way to register a provider, so bind it directly. Same binding
 * as AppTheme uses, for the same reason. */
[CCode (cname = "gtk_style_context_add_provider_for_display")]
extern void style_context_add_provider_for_display(Gdk.Display display, Gtk.StyleProvider provider, uint priority);

public class RecoveryShell : GLib.Object {

	private const string APP_TITLE = "Timeshift Recovery";

	private Gtk.Window window;
	private Gtk.Stack stack;
	private Gtk.Label status_label;

	private Vte.Terminal term;
	private Gtk.Label term_title;
	private Gtk.Button term_back;

	private Gtk.ListBox drive_list;

	// A launched app (timeshift-gtk) that owns the screen until it exits.
	private Pid child_pid = 0;
	private bool child_running = false;
	private Gtk.Button? restore_button = null;

	// network page
	private Gtk.Box net_body;
	private Gtk.Label net_status;
	private Gtk.Button net_rescan;

	// device -> the label showing its throughput, and its last/first counters
	private Gee.HashMap<string, Gtk.Label> rate_labels;
	private Gee.HashMap<string, string> prev_counters;
	private Gee.HashMap<string, string> base_counters;

	private Gtk.TextView diag_view;

	// modal
	private Gtk.Overlay overlay;
	private Gtk.Box modal_layer;

	/* Every colour is stated outright. The environment has no desktop settings
	 * daemon, so whichever GTK theme happens to be present decides the defaults,
	 * and a half-styled window is worse than an unstyled one. Buttons also need
	 * background-image cleared: GTK themes paint a gradient there that sits on
	 * top of any background-color. */

	/* Layout tokens. Same vocabulary as timeshift-gtk's ThemeStyle, but that
	 * file is not linkable here (it reaches Main through the global App), so
	 * the values are restated. Used from code and spliced into the CSS below.
	 * All values are logical px; the compositor scale multiplies them. */
	private const int SPACE_XS = 4;    // label-to-label inside a text stack
	private const int SPACE_S = 8;     // related controls, small gaps
	private const int SPACE_M = 12;    // siblings in a group: cards in a list, buttons in a bar
	private const int SPACE_L = 16;    // icon-to-text in a row, block-to-block
	private const int SPACE_XL = 24;   // page top/bottom margins, dialog padding
	private const int SPACE_PAGE = 48; // page side margins
	private const int RADIUS_S = 8;    // buttons, entries, list rows
	private const int RADIUS_M = 12;   // cards
	private const int RADIUS_L = 16;   // the modal dialog

	// The colours the VTE terminal must share with the stylesheet.
	private const string C_BG = "#14161d";
	private const string C_TEXT = "#e6eaf2";

	/* xterm's 16 slots, tuned to sit on C_BG: normal colours first, then
	 * bright. Slot 0 is the terminal's "black", kept a step above the
	 * background so reverse-video text stays visible. */
	private const string[] TERM_PALETTE = {
		"#1a1e26", "#d3696f", "#6cbf7f", "#e3b34c",
		"#5b8def", "#b98ad4", "#5fb8c2", "#c7cedb",
		"#3b4353", "#e08a8f", "#8ed49e", "#eec97e",
		"#82a8f2", "#cfa8e0", "#84cdd6", "#e6eaf2"
	};

	private const string CSS = """
		window { background-color: $C_BG; color: $C_FG; }

		.rs-title      { font-size: 28px; font-weight: 700; color: $C_FG; }
		.rs-subtitle   { font-size: 14px; color: #9aa4b6; }
		.rs-page-title { font-size: 16px; font-weight: 600; color: $C_FG; }
		.rs-action      { font-size: 16px; font-weight: 600; color: $C_FG; }
		.rs-action-desc { font-size: 12px; color: #9aa4b6; }
		.rs-status { font-size: 12px; color: #9aa4b6; padding: $SPACE_S 2px; }
		.rs-warn   { font-size: 12px; color: #e3b34c; padding: $SPACE_S 2px; }

		/* The caps strings come from the call sites; spacing and a slightly
		 * brighter grey carry the hierarchy instead of pure dimness. */
		.rs-section {
			font-size: 11px; font-weight: 600; color: #8a94a8;
			letter-spacing: 1.5px;
			margin-top: $SPACE_S; padding: 2px;
		}

		separator { background-color: #262c37; min-height: 1px; margin: $SPACE_XS 0; }

		/* Padding lives on the card, not on .rs-action: label padding indented
		 * titles further than their own descriptions. */
		.rs-card {
			background-color: #1c2028;
			background-image: none;
			border: 1px solid #2a303c;
			border-radius: $RADIUS_M;
			padding: 14px $SPACE_L;
			box-shadow: none;
			color: $C_FG;
			transition: background-color 150ms ease, border-color 150ms ease;
		}
		.rs-card:hover  { background-color: #242a35; border-color: #3b4353; }
		.rs-card:active { background-color: #181c24; }
		.rs-card image  { color: #9aa4b6; }
		.rs-card:hover image { color: $C_FG; }

		/* Every button, not just the cards: page headers use plain Gtk.Button
		 * and were left rendering in the light theme. */
		button {
			background-image: none;
			background-color: #1f242e;
			border: 1px solid #2f3644;
			border-radius: $RADIUS_S;
			color: $C_FG;
			font-weight: 500;
			padding: $SPACE_S $SPACE_L;
			transition: background-color 120ms ease, border-color 120ms ease;
		}
		button:hover   { background-color: #262d3a; border-color: #3b4353; }
		button:active  { background-color: #1a1f28; }
		button:disabled {
			color: #5f6878; background-color: #191d25; border-color: #232834;
		}
		button.rs-primary { background-color: #4f80e8; border-color: #4f80e8; color: #ffffff; }
		button.rs-primary:hover  { background-color: #6191f0; border-color: #6191f0; }
		button.rs-primary:active { background-color: #3e6cd0; }
		button.rs-danger { background-color: #963c41; border-color: #963c41; color: #ffffff; }
		button.rs-danger:hover  { background-color: #a84850; border-color: #a84850; }
		button.rs-danger:active { background-color: #83343a; }

		/* Keyboard navigation is first-class: this UI may be driven on a
		 * machine whose pointer does not work. */
		button:focus-visible, .rs-card:focus-visible, row:focus-visible {
			outline: 2px solid rgba(79, 128, 232, 0.6);
			outline-offset: 2px;
		}

		.rs-badge {
			font-size: 11px; font-weight: 600; color: #9aa4b6;
			background-color: rgba(154, 164, 182, 0.10);
			border: 1px solid rgba(154, 164, 182, 0.18);
			border-radius: 999px;
			padding: 2px 10px;
		}
		.rs-badge-warn {
			color: #e3b34c;
			background-color: rgba(227, 179, 76, 0.10);
			border-color: rgba(227, 179, 76, 0.24);
		}
		.rs-badge-accent {
			color: #86abf4;
			background-color: rgba(79, 128, 232, 0.12);
			border-color: rgba(79, 128, 232, 0.28);
		}

		listbox.rs-card { padding: $SPACE_XS; }
		listbox.rs-card > row {
			background-color: transparent;
			border-radius: $RADIUS_S;
			padding: $SPACE_M;
			transition: background-color 120ms ease;
		}
		listbox.rs-card > row:hover { background-color: rgba(230, 234, 242, 0.03); }
		listbox.rs-card > row:not(:last-child) { border-bottom: 1px solid #232834; }

		scrollbar        { background-color: transparent; }
		scrollbar trough { background-color: transparent; }
		scrollbar slider {
			background-color: rgba(154, 164, 182, 0.25);
			border-radius: 999px;
			border: none;
			min-width: 6px; min-height: 6px;
		}
		scrollbar slider:hover { background-color: rgba(154, 164, 182, 0.45); }

		/* In-app modal. Gtk.AlertDialog spawns its own toplevel, which under a
		 * bare labwc session gets no decoration and none of this stylesheet --
		 * it rendered as a cramped box with an empty strip above the text. */
		.rs-modal-scrim { background-color: rgba(8, 10, 14, 0.65); }
		.rs-dialog {
			background-color: #1c2028;
			border: 1px solid #333a48;
			border-radius: $RADIUS_L;
			padding: $SPACE_XL;
			box-shadow: 0 20px 60px rgba(0, 0, 0, 0.55), 0 2px 8px rgba(0, 0, 0, 0.35);
		}
		.rs-dialog-title { font-size: 20px; font-weight: 700; color: $C_FG; }
		.rs-dialog-body  { font-size: 14px; color: #b7c0d0; }

		entry {
			background-color: $C_BG;
			background-image: none;
			color: $C_FG;
			caret-color: #4f80e8;
			border: 1px solid #333a48;
			border-radius: $RADIUS_S;
			padding: 10px $SPACE_M;
		}
		entry:focus-within { border-color: #4f80e8; }
		entry image        { color: #9aa4b6; }
		entry image:hover  { color: $C_FG; }

		/* GTK4 TextView paints content on an inner `text` node; styling only
		 * the widget leaves the text area on the theme's colours. */
		.rs-log      { font-family: monospace; font-size: 12px; background-color: $C_BG; }
		.rs-log text { background-color: $C_BG; color: #b7c0d0; }
	""";

	private static string px(int v) { return "%dpx".printf(v); }

	/* replace() is plain substring substitution. No token name is a substring
	 * of another, which is what makes the order below irrelevant -- keep that
	 * property when adding tokens, or replace the longer name first. */
	private static string themed_css() {
		return CSS
			.replace("$SPACE_XS", px(SPACE_XS))
			.replace("$SPACE_XL", px(SPACE_XL))
			.replace("$SPACE_S", px(SPACE_S))
			.replace("$SPACE_M", px(SPACE_M))
			.replace("$SPACE_L", px(SPACE_L))
			.replace("$RADIUS_S", px(RADIUS_S))
			.replace("$RADIUS_M", px(RADIUS_M))
			.replace("$RADIUS_L", px(RADIUS_L))
			.replace("$C_BG", C_BG)
			.replace("$C_FG", C_TEXT);
	}

	public static int main(string[] args) {

		foreach (string arg in args) {
			if (arg == "--help" || arg == "-h") {
				stdout.printf(help_message());
				return 0;
			}
			if (arg == "--version") {
				stdout.printf("%s %s\n", APP_TITLE, Constants.VERSION);
				return 0;
			}
		}

		Gtk.init();

		var shell = new RecoveryShell();
		shell.build();

		var loop = new GLib.MainLoop();
		shell.window.close_request.connect(() => {
			/* Never closable. This is the session's only client, so closing it
			 * leaves a compositor with no windows: a black screen with nothing
			 * to click and nowhere to type. Reboot and Power off are the ways
			 * out, and the supervisor restarts this if it ever dies. */
			return true;
		});
		shell.window.present();
		loop.run();

		return 0;
	}

	private static string help_message() {
		string msg = "\n%s %s\n".printf(APP_TITLE, Constants.VERSION);
		msg += "\n";
		msg += "Syntax: timeshift-recovery-shell [options]\n";
		msg += "\n";
		msg += "The launcher shown in the Timeshift recovery environment. It connects\n";
		msg += "the network, mounts drives and starts a restore.\n";
		msg += "\n";
		msg += "Options:\n";
		msg += "\n";
		msg += "  --help, -h   Show all options\n";
		msg += "  --version    Print version number\n";
		msg += "\n";
		return msg;
	}

	// --- construction -------------------------------------------------------

	public void build() {

		var css = new Gtk.CssProvider();
		css.load_from_string(themed_css());
		style_context_add_provider_for_display(
			Gdk.Display.get_default(), css,
			Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

		window = new Gtk.Window();
		window.title = APP_TITLE;
		window.fullscreen();

		stack = new Gtk.Stack();
		stack.transition_type = Gtk.StackTransitionType.CROSSFADE;

		stack.add_named(build_home(), "home");
		stack.add_named(build_terminal_page(), "terminal");
		stack.add_named(build_drives_page(), "drives");
		stack.add_named(build_network_page(), "network");
		stack.add_named(build_diagnostics_page(), "diagnostics");
		stack.visible_child_name = "home";

		// The modal lives above every page, so a dialog raised from the network
		// page does not vanish when the stack switches.
		overlay = new Gtk.Overlay();
		overlay.set_child(stack);

		modal_layer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		modal_layer.add_css_class("rs-modal-scrim");
		modal_layer.halign = Gtk.Align.FILL;
		modal_layer.valign = Gtk.Align.FILL;
		modal_layer.visible = false;
		overlay.add_overlay(modal_layer);

		window.set_child(overlay);

		refresh_status();
	}

	private Gtk.Widget build_home() {

		/* The menu has to survive a small screen.
		 *
		 * A machine whose graphics are part of what is broken can land on a
		 * fallback mode -- 640x480 is what QEMU gives with no DRM driver -- and
		 * at that size the fixed layout ran off the bottom: the Terminal button
		 * was cut off with no way to reach it, on the one screen someone needs
		 * when nothing else works. So the cards scroll, and the power buttons
		 * stay pinned outside the scroller where they are always reachable. */
		var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_M);
		box.halign = Gtk.Align.CENTER;
		box.valign = Gtk.Align.CENTER;
		box.vexpand = true;
		box.margin_top = SPACE_XL;
		box.margin_bottom = SPACE_M;
		box.margin_start = SPACE_XL;
		box.margin_end = SPACE_XL;
		// 480 + margins fits a 640-wide fallback screen; the old 560 minimum
		// did not, so the cards were clipped horizontally as well.
		box.set_size_request(480, -1);

		var title = new Gtk.Label("Timeshift Recovery");
		title.add_css_class("rs-title");
		title.halign = Gtk.Align.START;
		box.append(title);

		var subtitle = new Gtk.Label(
			"This environment runs from RAM. Get online, then restore a snapshot.");
		subtitle.add_css_class("rs-subtitle");
		subtitle.halign = Gtk.Align.START;
		subtitle.wrap = true;
		box.append(subtitle);

		box.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));

		add_action(box, "network-wireless-symbolic", "Network",
			"Connect to wifi or ethernet. Needed before restoring from a remote host.",
			() => { show_network(); });

		add_action(box, "drive-harddisk-symbolic", "Storage",
			"Mount an external drive holding snapshots.",
			() => { refresh_drives(); stack.visible_child_name = "drives"; });

		restore_button = add_action(box, "document-revert-symbolic", "Restore system",
			"Open Timeshift and restore a snapshot onto this machine.",
			() => { launch_app("timeshift-gtk"); });

		add_action(box, "utilities-terminal-symbolic", "Terminal",
			"A root shell, for anything the buttons above do not cover.",
			() => { open_terminal("Terminal", { "/bin/bash" }); });

		status_label = new Gtk.Label("");
		status_label.halign = Gtk.Align.START;
		status_label.wrap = true;
		status_label.add_css_class("rs-status");
		box.append(status_label);

		var scroller = new Gtk.ScrolledWindow();
		scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scroller.vexpand = true;
		scroller.child = box;
		outer.append(scroller);

		var footer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_S);
		footer.halign = Gtk.Align.END;
		footer.margin_bottom = SPACE_M;
		footer.margin_end = SPACE_XL;
		footer.margin_top = SPACE_S;

		var diag = new Gtk.Button.with_label("Diagnostics");
		diag.clicked.connect(() => { refresh_diagnostics(); stack.visible_child_name = "diagnostics"; });
		footer.append(diag);

		var reboot = new Gtk.Button.with_label("Reboot");
		reboot.clicked.connect(() => {
			show_confirm("Reboot now?",
				"The environment runs from RAM; nothing here is kept.",
				"Reboot", false, () => { launch("reboot"); });
		});
		footer.append(reboot);

		var poweroff = new Gtk.Button.with_label("Power off");
		poweroff.clicked.connect(() => {
			show_confirm("Power off now?",
				"The environment runs from RAM; nothing here is kept.",
				"Power off", false, () => { launch("poweroff"); });
		});
		footer.append(poweroff);

		outer.append(footer);

		return outer;
	}

	private delegate void ActionFunc();

	private Gtk.Button add_action(Gtk.Box box, string icon, string label,
	                              string description, owned ActionFunc action) {

		var button = new Gtk.Button();
		button.add_css_class("rs-card");
		button.hexpand = true;

		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_L);

		var img = new Gtk.Image.from_icon_name(icon);
		img.pixel_size = 24;
		row.append(img);

		var text = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_XS);
		text.hexpand = true;

		var l = new Gtk.Label(label);
		l.halign = Gtk.Align.START;
		l.add_css_class("rs-action");
		text.append(l);

		var d = new Gtk.Label(description);
		d.halign = Gtk.Align.START;
		d.wrap = true;
		d.xalign = 0;
		d.add_css_class("rs-action-desc");
		text.append(d);

		row.append(text);
		button.set_child(row);

		button.clicked.connect(() => { action(); });

		box.append(button);

		return button;
	}

	/* A page header: Back on the left, title, then optional trailing widgets. */
	private Gtk.Box page_header(string title, out Gtk.Box trailing) {

		var bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_M);
		bar.margin_bottom = SPACE_S;

		var back = new Gtk.Button();
		var back_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_S);
		back_row.append(new Gtk.Image.from_icon_name("go-previous-symbolic"));
		back_row.append(new Gtk.Label("Back"));
		back.set_child(back_row);
		back.clicked.connect(() => { stack.visible_child_name = "home"; refresh_status(); });
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

	// --- status -------------------------------------------------------------

	/* The thing that silently breaks a restore: the environment booted from an
	 * image on the disk it is about to rewrite, and that disk is still mounted.
	 * Say so on the front page rather than letting the restore fail. */
	private void refresh_status() {

		status_label.remove_css_class("rs-warn");

		string cmdline = read_file("/proc/cmdline");
		bool toram = cmdline.contains("toram");

		if (!toram && cmdline.contains("iso-scan/filename=")) {
			status_label.add_css_class("rs-warn");
			status_label.label =
				"Warning: booted from an image on this machine's disk without toram. "
				+ "Restoring to that disk will fail while it is still mounted.";
			return;
		}

		if (is_mounted("/isodevice")) {
			status_label.add_css_class("rs-warn");
			status_label.label =
				"Warning: the boot medium's disk is still mounted at /isodevice. "
				+ "Run /usr/lib/timeshift-recovery/release-medium from the terminal "
				+ "before restoring to it.";
			return;
		}

		string repo = snapshot_location();
		status_label.label = (repo.length > 0)
			? "Snapshots: %s".printf(repo)
			: "No snapshot location is configured. Set one in Timeshift.";
	}

	/* Read the configured repository straight out of Timeshift's config, so the
	 * front page can say where a restore would come from without starting it. */
	/* One string key out of the seeded Timeshift config; "" when absent. */
	private string timeshift_config_value(string key) {

		string text = read_file("/etc/timeshift/timeshift.json");
		if (text.length == 0) { return ""; }

		try {
			var parser = new Json.Parser();
			parser.load_from_data(text);
			var root = parser.get_root();
			if (root == null) { return ""; }

			var obj = root.get_object();
			if (obj == null || !obj.has_member(key)) { return ""; }

			return obj.get_string_member(key);
		}
		catch (Error e) {
			return "";
		}
	}

	private string snapshot_location() {

		string text = read_file("/etc/timeshift/timeshift.json");
		if (text.length == 0) { return ""; }

		try {
			var parser = new Json.Parser();
			parser.load_from_data(text);
			var root = parser.get_root();
			if (root == null) { return ""; }

			var obj = root.get_object();
			if (obj == null) { return ""; }

			if (obj.has_member("backup_location_type")
				&& obj.get_string_member("backup_location_type") == "ssh"
				&& obj.has_member("backup_ssh_url")) {

				string url = obj.get_string_member("backup_ssh_url");
				if (url.length > 0) { return url; }
			}

			if (obj.has_member("backup_device_uuid")) {
				string uuid = obj.get_string_member("backup_device_uuid");
				if (uuid.length > 0) { return "local device %s".printf(uuid); }
			}
		}
		catch (Error e) {
			warning("could not parse /etc/timeshift/timeshift.json: %s", e.message);
		}

		return "";
	}

	// --- modal dialogs ------------------------------------------------------

	private delegate void ConfirmFunc();
	private delegate void PasswordFunc(string password);

	private void close_modal() {
		Gtk.Widget? child = modal_layer.get_first_child();
		while (child != null) {
			Gtk.Widget? next = child.get_next_sibling();
			modal_layer.remove(child);
			child = next;
		}
		modal_layer.visible = false;
	}

	private Gtk.Box open_modal(string title, string body) {

		close_modal();

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

		modal_layer.append(card);
		modal_layer.visible = true;

		return card;
	}

	private Gtk.Box modal_buttons(Gtk.Box card) {
		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_S);
		row.halign = Gtk.Align.END;
		row.margin_top = SPACE_S;
		card.append(row);
		return row;
	}

	private void show_message(string title, string body) {
		var card = open_modal(title, body);
		var row = modal_buttons(card);
		var ok = new Gtk.Button.with_label("OK");
		ok.add_css_class("rs-primary");
		ok.clicked.connect(() => { close_modal(); });
		row.append(ok);
	}

	private void show_confirm(string title, string body, string confirm_label,
	                          bool destructive, owned ConfirmFunc on_confirm) {

		var card = open_modal(title, body);
		var row = modal_buttons(card);

		var cancel = new Gtk.Button.with_label("Cancel");
		cancel.clicked.connect(() => { close_modal(); });
		row.append(cancel);

		var go = new Gtk.Button.with_label(confirm_label);
		go.add_css_class(destructive ? "rs-danger" : "rs-primary");
		go.clicked.connect(() => { close_modal(); on_confirm(); });
		row.append(go);
	}

	private void show_password(string ssid, owned PasswordFunc on_ok) {
		show_password_prompt("Connect to %s".printf(ssid),
			"Enter the network password.", (owned) on_ok);
	}

	private void show_password_prompt(string title, string body, owned PasswordFunc on_ok) {

		var card = open_modal(title, body);

		var entry = new Gtk.PasswordEntry();
		entry.show_peek_icon = true;
		entry.hexpand = true;
		card.append(entry);

		var row = modal_buttons(card);

		var cancel = new Gtk.Button.with_label("Cancel");
		cancel.clicked.connect(() => { close_modal(); });
		row.append(cancel);

		var go = new Gtk.Button.with_label("Connect");
		go.add_css_class("rs-primary");
		go.clicked.connect(() => {
			string pw = entry.text;
			close_modal();
			on_ok(pw);
		});
		row.append(go);

		// Enter submits, which is what anyone typing a passphrase expects.
		entry.activate.connect(() => { go.clicked(); });
		entry.grab_focus();
	}

	// --- network page -------------------------------------------------------

	private Gtk.Widget build_network_page() {

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		box.margin_top = SPACE_XL;
		box.margin_bottom = SPACE_XL;
		box.margin_start = SPACE_PAGE;
		box.margin_end = SPACE_PAGE;

		Gtk.Box trailing;
		box.append(page_header("Network", out trailing));

		net_rescan = new Gtk.Button.with_label("Rescan");
		net_rescan.clicked.connect(() => { rescan_wifi.begin(); });
		trailing.append(net_rescan);

		net_status = new Gtk.Label("");
		net_status.halign = Gtk.Align.START;
		net_status.wrap = true;
		net_status.add_css_class("rs-status");
		net_status.margin_top = SPACE_S;
		box.append(net_status);

		net_body = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_M);
		net_body.margin_top = SPACE_S;

		var scroll = new Gtk.ScrolledWindow();
		scroll.vexpand = true;
		scroll.child = net_body;
		box.append(scroll);

		rate_labels = new Gee.HashMap<string, Gtk.Label>();
		prev_counters = new Gee.HashMap<string, string>();
		base_counters = new Gee.HashMap<string, string>();

		/* Throughput ticks on its own timer reading /sys directly -- no
		 * subprocess, no relayout, so it stays smooth even while a restore has
		 * the machine busy. During a remote restore this number is the only
		 * sign that data is actually moving. */
		GLib.Timeout.add_seconds(1, () => {
			if (stack.visible_child_name == "network") { update_rates(); }
			return true;
		});

		return box;
	}

	private void show_network() {
		stack.visible_child_name = "network";
		refresh_network.begin();
	}

	private void section(Gtk.Box box, string title) {
		var l = new Gtk.Label(title);
		l.halign = Gtk.Align.START;
		l.add_css_class("rs-section");
		box.append(l);
	}

	/* Every read here used to run synchronously on the main thread: one nmcli
	 * for device status, ANOTHER nmcli per device for its IP, one for the wifi
	 * list, then tailscale twice. Fifteen-plus blocking spawns per refresh, and
	 * the UI froze for all of them -- badly so while a restore is using the CPU.
	 *
	 * Now: await everything, and ask for the IPs of all devices in ONE call
	 * rather than one call each. */
	private async void refresh_network() {

		net_rescan.sensitive = false;
		net_status.remove_css_class("rs-warn");
		net_status.label = "Reading network state...";

		string devs, ips, wifi, rf, ts_ip, ts_prefs;
		yield run_async({ "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION",
		                  "device", "status" }, out devs);
		yield run_async({ "nmcli", "-t", "-f", "DEVICE,IP4.ADDRESS",
		                  "device", "show" }, out ips);
		yield run_async({ "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY",
		                  "device", "wifi", "list" }, out wifi);
		yield run_async({ "rfkill", "list", "wifi" }, out rf);

		bool have_ts = file_exists("/usr/bin/tailscale");
		ts_ip = ""; ts_prefs = "";
		if (have_ts) {
			yield run_async({ "tailscale", "ip", "-4" }, out ts_ip);
			yield run_async({ "tailscale", "debug", "prefs" }, out ts_prefs);
		}

		clear_box(net_body);
		rate_labels.clear();
		net_status.label = "";
		net_rescan.sensitive = true;

		// rfkill first: a wireless switch left off makes everything below look
		// broken for no visible reason.
		if (rf.contains("Soft blocked: yes")) {
			var warn_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_M);
			warn_row.add_css_class("rs-card");

			var wl = new Gtk.Label("Wi-Fi is blocked by rfkill.");
			wl.add_css_class("rs-warn");
			wl.halign = Gtk.Align.START;
			wl.hexpand = true;
			warn_row.append(wl);

			var unblock = new Gtk.Button.with_label("Unblock");
			unblock.add_css_class("rs-primary");
			unblock.valign = Gtk.Align.CENTER;
			unblock.clicked.connect(() => { unblock_wifi.begin(); });
			warn_row.append(unblock);

			net_body.append(warn_row);
		}

		if (devs.strip().length == 0) {
			net_status.add_css_class("rs-warn");
			net_status.label = "NetworkManager is not responding. Is it running?";
			return;
		}

		// One pass over `device show` builds device -> IP, instead of spawning
		// nmcli once per interface.
		var ip_map = new Gee.HashMap<string, string>();
		string current_dev = "";
		foreach (string line in ips.split("\n")) {
			string[] f = split_terse(line);
			if (f.length < 2) { continue; }
			if (f[0] == "DEVICE") { current_dev = f[1]; continue; }
			if (f[0].has_prefix("IP4.ADDRESS") && current_dev.length > 0) {
				if (!ip_map.has_key(current_dev) && f[1].length > 0 && f[1] != "--") {
					ip_map.set(current_dev, f[1]);
				}
			}
		}

		section(net_body, "INTERFACES");

		bool any_device = false;
		foreach (string line in devs.split("\n")) {
			if (line.strip().length == 0) { continue; }
			string[] f = split_terse(line);
			if (f.length < 3) { continue; }

			string dev = f[0], type = f[1], state = f[2];
			string conn = (f.length > 3) ? f[3] : "";

			/* Loopback and the tailnet's own tun are not things anyone connects
			 * or disconnects here; tailscale0 reports "connected (externally)"
			 * and would offer a Disconnect that does the wrong thing. */
			if (type == "loopback" || dev == "lo") { continue; }
			if (type == "tun" || dev.has_prefix("tailscale")) { continue; }
			any_device = true;

			string detail = "%s  %s".printf(type, state);
			if (conn.length > 0 && conn != "--") { detail += "  %s".printf(conn); }
			if (ip_map.has_key(dev)) { detail += "  %s".printf(ip_map.get(dev)); }

			add_interface_row(dev, detail, state.has_prefix("connected"));
		}

		if (!any_device) {
			var l = new Gtk.Label(
				"NetworkManager reports no managed interfaces. If this machine has "
				+ "wired ethernet, the environment's manage-all override may be missing.");
			l.wrap = true;
			l.xalign = 0;
			l.add_css_class("rs-warn");
			net_body.append(l);
		}

		if (wifi.strip().length > 0) {
			section(net_body, "WI-FI NETWORKS");

			var seen = new Gee.HashSet<string>();
			foreach (string line in wifi.split("\n")) {
				if (line.strip().length == 0) { continue; }
				string[] f = split_terse(line);
				if (f.length < 4) { continue; }

				bool in_use = (f[0] == "*");
				string ssid = f[1];
				if (ssid.length == 0) { continue; }   // hidden network
				if (ssid in seen) { continue; }       // same SSID on 2.4 and 5 GHz
				seen.add(ssid);

				add_wifi_row(ssid, f[2], f[3], in_use);
			}
		}

		if (have_ts) { add_tailscale_section(ts_ip, ts_prefs); }

		update_rates();
	}

	private void add_interface_row(string dev, string detail, bool connected) {

		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_L);
		row.add_css_class("rs-card");

		var text = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_XS);
		text.hexpand = true;

		var nl = new Gtk.Label(dev);
		nl.halign = Gtk.Align.START;
		nl.add_css_class("rs-action");
		text.append(nl);

		var dl = new Gtk.Label(detail);
		dl.halign = Gtk.Align.START;
		dl.add_css_class("rs-action-desc");
		text.append(dl);

		// Filled by the throughput timer.
		var rl = new Gtk.Label("");
		rl.halign = Gtk.Align.START;
		rl.add_css_class("rs-action-desc");
		text.append(rl);
		rate_labels.set(dev, rl);

		row.append(text);

		var btn = new Gtk.Button.with_label(connected ? "Disconnect" : "Connect");
		btn.valign = Gtk.Align.CENTER;
		string dev_name = dev;
		bool was_connected = connected;
		btn.clicked.connect(() => { run_device_action.begin(dev_name, was_connected); });
		row.append(btn);

		net_body.append(row);
	}

	/* Kernel counters straight from /sys: no subprocess, so this can run every
	 * second without the stutter that made the menu feel frozen. */
	private void update_rates() {

		foreach (var dev in rate_labels.keys) {

			string rx = read_file("/sys/class/net/%s/statistics/rx_bytes".printf(dev)).strip();
			string tx = read_file("/sys/class/net/%s/statistics/tx_bytes".printf(dev)).strip();
			if (rx.length == 0 || tx.length == 0) { continue; }

			uint64 rx_now = uint64.parse(rx);
			uint64 tx_now = uint64.parse(tx);

			if (!base_counters.has_key(dev)) {
				base_counters.set(dev, "%s:%s".printf(rx, tx));
			}

			string label = "";
			if (prev_counters.has_key(dev)) {
				string[] prev = prev_counters.get(dev).split(":");
				if (prev.length == 2) {
					uint64 rx_prev = uint64.parse(prev[0]);
					uint64 tx_prev = uint64.parse(prev[1]);
					// The timer is 1s, so the delta is already a per-second rate.
					uint64 rx_rate = (rx_now > rx_prev) ? rx_now - rx_prev : 0;
					uint64 tx_rate = (tx_now > tx_prev) ? tx_now - tx_prev : 0;
					label = "down %s/s   up %s/s".printf(
						format_size((int64) rx_rate), format_size((int64) tx_rate));
				}
			}

			string[] b = base_counters.get(dev).split(":");
			if (b.length == 2) {
				uint64 total = rx_now - uint64.parse(b[0]);
				if (total > 0) {
					label += "   %s received this session".printf(format_size((int64) total));
				}
			}

			var l = rate_labels.get(dev);
			if (l != null) { l.label = label; }

			prev_counters.set(dev, "%s:%s".printf(rx, tx));
		}
	}

	private void add_wifi_row(string ssid, string signal, string security, bool in_use) {

		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_L);
		row.add_css_class("rs-card");

		var text = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_XS);
		text.hexpand = true;

		var nl = new Gtk.Label(ssid);
		nl.halign = Gtk.Align.START;
		nl.add_css_class("rs-action");
		text.append(nl);

		string sec = (security.length == 0 || security == "--") ? "open" : security;
		var dl = new Gtk.Label("signal %s%%  %s".printf(signal, sec));
		dl.halign = Gtk.Align.START;
		dl.add_css_class("rs-action-desc");
		text.append(dl);

		row.append(text);

		if (in_use) {
			var badge = new Gtk.Label("Connected");
			badge.valign = Gtk.Align.CENTER;
			badge.add_css_class("rs-badge-accent");
			row.append(badge);
		}
		else {
			var btn = new Gtk.Button.with_label("Connect");
			btn.valign = Gtk.Align.CENTER;
			string s = ssid;
			bool open_network = (sec == "open");
			btn.clicked.connect(() => { start_wifi_connect.begin(s, open_network); });
			row.append(btn);
		}

		net_body.append(row);
	}

	private void add_tailscale_section(string ip, string prefs) {

		section(net_body, "TAILSCALE");

		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_L);
		row.add_css_class("rs-card");

		var text = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_XS);
		text.hexpand = true;

		bool up = (ip.strip().length > 0);

		var nl = new Gtk.Label(up ? "Connected" : "Not connected");
		nl.halign = Gtk.Align.START;
		nl.add_css_class("rs-action");
		text.append(nl);

		string detail;
		if (up) {
			detail = "tailnet address %s".printf(ip.strip());
			detail += prefs.contains("\"RouteAll\": true")
				? "  accepting subnet routes"
				: "  NOT accepting subnet routes";
		}
		else {
			detail = "Reaches a backup host on a remote network via the tailnet.";
		}

		var dl = new Gtk.Label(detail);
		dl.halign = Gtk.Align.START;
		dl.wrap = true;
		dl.xalign = 0;
		dl.add_css_class("rs-action-desc");
		text.append(dl);

		row.append(text);

		if (!up) {
			var btn = new Gtk.Button.with_label("Connect");
			btn.add_css_class("rs-primary");
			btn.valign = Gtk.Align.CENTER;
			btn.clicked.connect(() => { tailscale_up.begin(); });
			row.append(btn);
		}
		else {
			/* The escape hatch for a tailnet route shadowing a healthy LAN.
			 *
			 * A peer advertising the backup host's subnet wins over the direct
			 * path, so if the tailnet is degraded the repository becomes
			 * unreachable even though it is on the same network -- and the
			 * only symptom is ssh timing out while ping still answers. */
			bool accepting = prefs.contains("\"RouteAll\": true");

			var btn = new Gtk.Button.with_label(
				accepting ? "Stop using subnet routes" : "Use subnet routes");
			btn.valign = Gtk.Align.CENTER;
			btn.clicked.connect(() => { tailscale_set_routes.begin(!accepting); });
			row.append(btn);
		}

		net_body.append(row);
	}

	// --- network actions (async: these block for seconds) -------------------

	private void set_busy(string message) {
		net_status.remove_css_class("rs-warn");
		net_status.label = message;
		net_rescan.sensitive = false;
	}

	private async void unblock_wifi() {
		set_busy("Unblocking Wi-Fi...");
		string o;
		yield run_async({ "rfkill", "unblock", "wifi" }, out o);
		yield refresh_network();
	}

	private async void rescan_wifi() {
		set_busy("Scanning for networks...");
		string o;
		yield run_async({ "nmcli", "device", "wifi", "rescan" }, out o);
		yield refresh_network();
	}

	private async void run_device_action(string dev, bool connected) {
		set_busy(connected ? "Disconnecting %s...".printf(dev)
		                   : "Connecting %s...".printf(dev));
		string o;
		bool ok = yield run_async(
			{ "nmcli", "device", connected ? "disconnect" : "connect", dev }, out o);
		if (!ok) { show_message("Could not %s %s".printf(
			connected ? "disconnect" : "connect", dev), o); }
		yield refresh_network();
	}

	/* A saved network -- and the environment carries the host's saved networks
	 * -- connects with no prompt. Only ask for a passphrase when there is
	 * nothing stored to try. */
	private async void start_wifi_connect(string ssid, bool open_network) {

		if (open_network) { yield connect_wifi(ssid, null); return; }

		string o;
		bool saved = false;
		if (yield run_async({ "nmcli", "-t", "-f", "NAME", "connection", "show" }, out o)) {
			foreach (string line in o.split("\n")) {
				if (line.strip() == ssid) { saved = true; break; }
			}
		}

		if (saved) { yield connect_wifi(ssid, null); }
		else { show_password(ssid, (pw) => { connect_wifi.begin(ssid, pw); }); }
	}

	private async void connect_wifi(string ssid, string? password) {
		set_busy("Connecting to %s...".printf(ssid));

		string o;
		bool ok;
		if (password == null) {
			ok = yield run_async({ "nmcli", "device", "wifi", "connect", ssid }, out o);
		}
		else {
			ok = yield run_async(
				{ "nmcli", "device", "wifi", "connect", ssid, "password", password }, out o);
		}

		if (!ok) { show_message("Could not connect to %s".printf(ssid), o); }
		yield refresh_network();
	}

	/* Turn peers' subnet routes on or off without leaving the tailnet.
	 *
	 * "tailscale up --accept-routes=false" keeps the node connected but stops
	 * importing routes, so a backup host on the local network goes back to
	 * being reached directly. */
	private async void tailscale_set_routes(bool accept) {

		set_busy(accept ? "Accepting subnet routes..." : "Dropping subnet routes...");

		string o;
		bool ok = yield run_async({ "tailscale", "up",
			accept ? "--accept-routes=true" : "--accept-routes=false",
			"--timeout=30s" }, out o);

		if (!ok) {
			show_message("Could not change subnet routes", o);
		}

		yield refresh_network();
	}

	private async void tailscale_up() {
		set_busy("Joining the tailnet...");

		/* --accept-routes is the point: the backup host is reached over a peer's
		 * advertised subnet route, and without this flag that route is ignored. */
		string o;
		bool ok = yield run_async(
			{ "tailscale", "up", "--accept-routes", "--timeout=30s" }, out o);

		if (!ok) {
			// A login URL means the copied node identity was not accepted.
			if (o.contains("https://login.tailscale.com")) {
				show_message("Tailscale needs a login",
					"Open this URL on another device to authorise this machine:\n\n" + o.strip());
			}
			else {
				show_message("Could not join the tailnet", o);
			}
		}
		yield refresh_network();
	}

	// --- terminal page ------------------------------------------------------

	private Gtk.Widget build_terminal_page() {

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

		var bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_M);
		bar.margin_top = SPACE_M;
		bar.margin_bottom = SPACE_M;
		bar.margin_start = SPACE_L;
		bar.margin_end = SPACE_L;

		term_back = new Gtk.Button.with_label("Back");
		term_back.clicked.connect(() => { stack.visible_child_name = "home"; refresh_status(); });
		bar.append(term_back);

		term_title = new Gtk.Label("");
		term_title.add_css_class("rs-page-title");
		bar.append(term_title);

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
			term_back.label = "Back";
		});

		return box;
	}

	private void open_terminal(string title, string[] argv) {

		term_title.label = title;
		stack.visible_child_name = "terminal";

		term_back.label = "Back (running)";

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

	// --- drives page --------------------------------------------------------

	private Gtk.Widget build_drives_page() {

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		box.margin_top = SPACE_XL;
		box.margin_bottom = SPACE_XL;
		box.margin_start = SPACE_PAGE;
		box.margin_end = SPACE_PAGE;

		Gtk.Box trailing;
		box.append(page_header("Storage", out trailing));

		var refresh = new Gtk.Button.with_label("Refresh");
		refresh.clicked.connect(() => { refresh_drives(); });
		trailing.append(refresh);

		drive_list = new Gtk.ListBox();
		drive_list.add_css_class("rs-card");
		drive_list.selection_mode = Gtk.SelectionMode.NONE;
		drive_list.margin_top = SPACE_L;
		// hug the rows; a card stretched to the page bottom reads as empty
		drive_list.valign = Gtk.Align.START;

		var scroll = new Gtk.ScrolledWindow();
		scroll.vexpand = true;
		scroll.child = drive_list;
		box.append(scroll);

		return box;
	}

	/* Mountpoints casper uses for the live medium. Offering to unmount any of
	 * these would pull the running environment out from under itself. */
	private bool is_live_mountpoint(string mp) {
		if (mp.length == 0) { return false; }
		return mp == "/cdrom"
			|| mp == "/isodevice"
			|| mp == "/run/live/medium"
			|| mp.has_prefix("/run/live/");
	}

	private void refresh_drives() {

		clear_box_listbox(drive_list);

		/* LVM volumes inside an already-unlocked container are invisible to
		 * lsblk until the volume group is activated, and a Timeshift restore
		 * cannot select a device it cannot see. Cheap, idempotent, and quiet
		 * when there is no LVM at all. */
		string ignored;
		run_sync({ "vgchange", "-ay" }, out ignored);

		string output;
		if (!run_sync({ "lsblk", "-J", "-b", "-o",
		                "PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,RM,MODEL" }, out output)) {
			add_drive_message("Could not read the drive list (lsblk failed).");
			return;
		}

		int shown = 0;

		try {
			var parser = new Json.Parser();
			parser.load_from_data(output);

			var root = parser.get_root();
			if (root == null) { add_drive_message("Could not read the drive list."); return; }

			var devices = root.get_object().get_array_member("blockdevices");
			if (devices == null) { add_drive_message("No drives found."); return; }

			foreach (var element in devices.get_elements()) {
				shown += add_device_rows(element.get_object(), "");
			}
		}
		catch (Error e) {
			add_drive_message("Could not read the drive list: %s".printf(e.message));
			return;
		}

		if (shown == 0) {
			add_drive_message("No mountable drives found. Attach one and press Refresh.");
		}
	}

	/* lsblk nests partitions under their disk, so walk children too. Only rows
	 * with a filesystem are actionable; a bare disk or an extended partition
	 * would just be noise on a page whose only purpose is "mount this". */
	private int add_device_rows(Json.Object dev, string parent_model) {

		int count = 0;

		string path = json_str(dev, "path");
		string fstype = json_str(dev, "fstype");
		string label = json_str(dev, "label");
		string mountpoint = json_str(dev, "mountpoint");
		string model = json_str(dev, "model");
		if (model.length == 0) { model = parent_model; }

		int64 size = 0;
		if (dev.has_member("size") && dev.get_member("size").get_value_type() == typeof(int64)) {
			size = dev.get_int_member("size");
		}

		if (fstype.length > 0 && fstype != "squashfs" && path.length > 0) {
			add_drive_row(path, fstype, label, mountpoint, model, size);
			count++;
		}

		if (dev.has_member("children")) {
			var children = dev.get_array_member("children");
			if (children != null) {
				foreach (var element in children.get_elements()) {
					count += add_device_rows(element.get_object(), model);
				}
			}
		}

		return count;
	}

	private void add_drive_row(string path, string fstype, string label,
	                           string mountpoint, string model, int64 size) {

		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, SPACE_L);

		var text = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_XS);
		text.hexpand = true;

		string name = (label.length > 0) ? label : path;
		var l = new Gtk.Label(name);
		l.halign = Gtk.Align.START;
		l.add_css_class("rs-action");
		text.append(l);

		bool live = is_live_mountpoint(mountpoint);

		var detail = new StringBuilder();
		detail.append("%s  %s".printf(path, format_size(size)));
		if (fstype.length > 0) { detail.append("  %s".printf(fstype)); }
		if (model.length > 0) { detail.append("  %s".printf(model.strip())); }
		if (mountpoint.length > 0) { detail.append("  mounted at %s".printf(mountpoint)); }
		if (live) { detail.append("  - this is the boot medium"); }

		var d = new Gtk.Label(detail.str);
		d.halign = Gtk.Align.START;
		d.add_css_class(live ? "rs-warn" : "rs-action-desc");
		text.append(d);

		row.append(text);

		/* Never offer to unmount the medium the environment is running from.
		 * Show it, so the list does not look wrong, but with no action. */
		if (live) {
			var badge = new Gtk.Label("in use");
			badge.valign = Gtk.Align.CENTER;
			badge.add_css_class("rs-badge-warn");
			row.append(badge);
		}
		else if (fstype == "crypto_LUKS") {

			/* An encrypted root is the common case on an Ubuntu install, and
			 * without this the disk holding the system to be restored simply
			 * cannot be opened from here. */
			var button = new Gtk.Button.with_label("Unlock");
			button.valign = Gtk.Align.CENTER;
			button.clicked.connect(() => { unlock_luks(path); });
			row.append(button);
		}
		else if (fstype == "LVM2_member") {

			var badge = new Gtk.Label("LVM");
			badge.valign = Gtk.Align.CENTER;
			badge.add_css_class("rs-badge");
			row.append(badge);
		}
		else {
			bool mounted = (mountpoint.length > 0);
			var button = new Gtk.Button.with_label(mounted ? "Unmount" : "Mount");
			button.valign = Gtk.Align.CENTER;
			button.clicked.connect(() => {
				if (mounted) { unmount_path(mountpoint); } else { mount_device(path, label); }
			});
			row.append(button);
		}

		drive_list.append(row);
	}

	/* mount(8), not "udisksctl mount".
	 *
	 * udisks needs org.freedesktop.udisks2.filesystem-mount-system for an
	 * internal disk, which is auth_admin -- and this image has polkitd but no
	 * authentication agent to answer the prompt, so mounting an internal
	 * partition always came back "Not authorized". The whole session is root,
	 * so mount does the job with nothing in the way. */
	private void mount_device(string path, string label) {

		string name = (label.length > 0) ? label : Path.get_basename(path);
		string target = "/media/" + name.replace("/", "_");

		string output;

		if (!run_sync({ "mkdir", "-p", target }, out output)) {
			show_message("Could not create %s".printf(target), output);
			return;
		}

		if (!run_sync({ "mount", path, target }, out output)) {
			// leave no empty directory behind to confuse the next attempt
			string ignored;
			run_sync({ "rmdir", target }, out ignored);

			show_message("Could not mount %s".printf(path),
				output.length > 0 ? output : "The operation failed.");
		}

		refresh_drives();
	}

	private void unmount_path(string mountpoint) {

		string output;

		if (!run_sync({ "umount", mountpoint }, out output)) {
			show_message("Could not unmount %s".printf(mountpoint),
				output.length > 0 ? output : "Something is still using it.");
		}
		else if (mountpoint.has_prefix("/media/")) {
			string ignored;
			run_sync({ "rmdir", mountpoint }, out ignored);
		}

		refresh_drives();
	}

	private void unlock_luks(string path) {

		show_password_prompt("Unlock %s".printf(path),
			"Enter the passphrase for this encrypted device.", (passphrase) => {

			string name = "luks-" + Path.get_basename(path);

			/* The passphrase goes in on stdin -- never on a command line,
			 * where it would be visible in /proc to anything that looked. */
			string output;
			if (!run_with_input({ "cryptsetup", "luksOpen", path, name }, passphrase + "\n", out output)) {
				show_message("Could not unlock %s".printf(path),
					output.length > 0 ? output : "The passphrase may be wrong.");
				return;
			}

			// an unlocked container usually holds LVM; make its volumes visible
			string ignored;
			run_sync({ "vgchange", "-ay" }, out ignored);

			refresh_drives();
		});
	}

	private void add_drive_message(string text) {
		var l = new Gtk.Label(text);
		l.margin_top = SPACE_L;
		l.margin_bottom = SPACE_L;
		l.wrap = true;
		l.add_css_class("rs-action-desc");
		drive_list.append(l);
	}

	/* Does tailscale currently import peers' subnet routes?
	 * "tailscale debug prefs" reports this as RouteAll, which is the flag
	 * --accept-routes sets. */
	private bool accept_routes_enabled() {

		string o;

		if (!run_sync({ "tailscale", "debug", "prefs" }, out o)) { return false; }

		foreach (string line in o.split("\n")) {
			if (line.contains("\"RouteAll\"")) {
				return line.contains("true");
			}
		}

		return false;
	}

	private bool route_via_tailscale(string host) {

		string o;

		if (!run_sync({ "ip", "route", "get", host }, out o)) { return false; }

		return o.contains("tailscale");
	}

	// --- diagnostics page ---------------------------------------------------

	private Gtk.Widget build_diagnostics_page() {

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		box.margin_top = SPACE_XL;
		box.margin_bottom = SPACE_XL;
		box.margin_start = SPACE_PAGE;
		box.margin_end = SPACE_PAGE;

		Gtk.Box trailing;
		box.append(page_header("Diagnostics", out trailing));

		var refresh = new Gtk.Button.with_label("Refresh");
		refresh.clicked.connect(() => { refresh_diagnostics(); });
		trailing.append(refresh);

		diag_view = new Gtk.TextView();
		diag_view.editable = false;
		diag_view.monospace = true;
		diag_view.add_css_class("rs-log");
		diag_view.margin_top = SPACE_L;
		// TextView's own margins pad the text inside the inner `text` node,
		// where CSS padding is unreliable.
		diag_view.left_margin = SPACE_M;
		diag_view.right_margin = SPACE_M;
		diag_view.top_margin = SPACE_M;
		diag_view.bottom_margin = SPACE_M;

		var scroll = new Gtk.ScrolledWindow();
		scroll.vexpand = true;
		scroll.child = diag_view;
		box.append(scroll);

		return box;
	}

	private void refresh_diagnostics() {

		var b = new StringBuilder();
		string o;

		string cmdline = read_file("/proc/cmdline");
		bool toram = cmdline.contains("toram");
		bool iso_scan = cmdline.contains("iso-scan/filename=");

		b.append("BOOT\n");
		b.append("  mode:            %s\n".printf(
			iso_scan ? "image on the system disk (iso-scan)" : "dedicated medium"));
		b.append("  toram:           %s\n".printf(toram ? "yes" : "no"));
		b.append("  medium mounted:  %s\n".printf(
			is_mounted("/isodevice") ? "/isodevice STILL MOUNTED"
			                         : "released (or not applicable)"));
		if (iso_scan && is_mounted("/isodevice")) {
			b.append("  WARNING: restoring to that disk will fail while it is mounted.\n");
			b.append("           run /usr/lib/timeshift-recovery/release-medium\n");
		}
		b.append("  cmdline:         %s\n".printf(cmdline.strip()));

		b.append("\nNETWORK\n");
		if (run_sync({ "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION",
		               "device", "status" }, out o)) {
			foreach (string line in o.split("\n")) {
				if (line.strip().length > 0) { b.append("  %s\n".printf(line)); }
			}
		}
		else { b.append("  nmcli failed - is NetworkManager running?\n"); }

		if (file_exists("/usr/bin/tailscale")) {
			b.append("\nTAILSCALE\n");
			if (run_sync({ "tailscale", "status", "--peers=false" }, out o)) {
				foreach (string line in o.split("\n")) {
					if (line.strip().length > 0) { b.append("  %s\n".printf(line)); }
				}
			}
			else { b.append("  %s\n".printf(o.strip())); }

			/* Whether subnet routes advertised by peers are being imported.
			 * This is what --accept-routes sets, and it can silently take a
			 * LAN host away from a working direct path. */
			b.append("  subnet routes:   %s\n".printf(
				accept_routes_enabled() ? "accepted (--accept-routes)" : "not accepted"));
		}

		b.append("\nSNAPSHOT REPOSITORY\n");
		string repo = snapshot_location();
		b.append("  configured:      %s\n".printf(repo.length > 0 ? repo : "(none)"));

		if (repo.contains("@")) {

			string hostpart = repo.split(":")[0];
			string host = hostpart.contains("@") ? hostpart.split("@")[1] : hostpart;

			/* Ping and TCP are reported separately and on purpose.
			 *
			 * "I could ping it fine" is the most misleading thing a network
			 * can tell you here: ICMP answering while TCP/22 times out is a
			 * routing problem, not a host-is-down problem -- and under a VM's
			 * user-mode networking ICMP is emulated separately, so a reply
			 * proves nothing at all about whether ssh can connect. */
			bool icmp = run_sync({ "ping", "-c", "1", "-W", "3", host }, out o);

			/* Unmultiplexed on purpose, exactly as the restore's own probe
			 * now is: a client attaching to a wedged ControlMaster socket
			 * never performs connect(), so ConnectTimeout would not apply.
			 *
			 * Key and port come from the seeded config: probing with the
			 * default key against a custom-key setup would report FAILED for
			 * a repository the restore can actually reach. */
			string key_file = timeshift_config_value("backup_ssh_key");
			if (key_file.length == 0) { key_file = "/etc/timeshift/ssh/id_ed25519"; }
			string port = timeshift_config_value("backup_ssh_port");

			string[] ssh_cmd = { "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
			                     "-o", "ControlMaster=no", "-o", "ControlPath=none",
			                     "-o", "StrictHostKeyChecking=no",
			                     "-i", key_file };
			if (port.length > 0) { ssh_cmd += "-p"; ssh_cmd += port; }
			ssh_cmd += hostpart;
			ssh_cmd += "true";
			bool tcp = run_sync(ssh_cmd, out o);

			b.append("  ping (ICMP):     %s\n".printf(icmp ? "answers" : "no reply"));
			b.append("  ssh (TCP):       %s\n".printf(
				tcp ? "connects" : "FAILED - %s".printf(o.strip())));

			// which way out the traffic actually goes
			string route;
			if (run_sync({ "ip", "route", "get", host }, out route)) {
				b.append("  route:           %s\n".printf(route.strip().split("\n")[0]));
			}

			if (icmp && !tcp) {
				b.append("\n  ICMP answers but TCP does not. That is a routing or firewall\n");
				b.append("  problem, not an unreachable host -- do not trust ping here.\n");
				if (route_via_tailscale(host)) {
					b.append("  This host currently routes over the tailnet. If it is on the\n");
					b.append("  same network as this machine, turn subnet routes off on the\n");
					b.append("  Network page so the direct path is used instead.\n");
				}
			}
		}

		b.append("\nRECENT ERRORS\n");
		if (run_sync({ "journalctl", "-p", "err", "-n", "25", "--no-pager" }, out o)) {
			foreach (string line in o.split("\n")) {
				if (line.strip().length > 0) { b.append("  %s\n".printf(line)); }
			}
		}

		diag_view.buffer.text = b.str;
	}

	// --- helpers ------------------------------------------------------------

	/* nmcli terse output separates fields with ':' and escapes literal colons as
	 * '\:'. Splitting naively mangles any SSID or MAC containing one. */
	private string[] split_terse(string line) {
		var fields = new Gee.ArrayList<string>();
		var cur = new StringBuilder();
		bool escaped = false;

		for (int i = 0; i < line.length; i++) {
			char c = line[i];
			if (escaped) { cur.append_c(c); escaped = false; continue; }
			if (c == '\\') { escaped = true; continue; }
			if (c == ':') { fields.add(cur.str); cur.erase(); continue; }
			cur.append_c(c);
		}
		fields.add(cur.str);

		return fields.to_array();
	}

	/* Fire-and-forget: reboot, poweroff. Nothing comes back from these. */
	private void launch(string command) {
		try {
			string[] argv = { command };
			GLib.Process.spawn_async(null, argv, null,
				SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, null);
		}
		catch (Error e) {
			show_message("Could not start %s".printf(command), e.message);
		}
	}

	/* Hand the screen to another application until it exits.
	 *
	 * This launcher is fullscreen, so clicking it raises it over whatever it
	 * started and the other window looks like it vanished. Worse, the obvious
	 * response -- press Restore again -- starts a SECOND timeshift, which its
	 * own AppLock refuses with "Scheduled snapshot in progress", a message that
	 * has nothing to do with what happened.
	 *
	 * So hide this window while the child owns the screen, and bring it back
	 * when the child exits. Hiding also makes a second launch unreachable,
	 * which is the real cure for the lock collision. */
	private void launch_app(string command) {

		if (child_running) { return; }

		try {
			string[] argv = { command };
			GLib.Process.spawn_async(null, argv, null,
				SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD,
				null, out child_pid);
		}
		catch (Error e) {
			show_message("Could not start %s".printf(command), e.message);
			return;
		}

		child_running = true;
		if (restore_button != null) { restore_button.sensitive = false; }

		/* The watch is what guarantees the launcher comes back. If the child
		 * dies immediately -- a stale lock, a missing dependency -- this fires
		 * at once and the user is never left staring at an empty compositor. */
		ChildWatch.add(child_pid, (pid, status) => {
			GLib.Process.close_pid(pid);
			child_pid = 0;
			child_running = false;
			if (restore_button != null) { restore_button.sensitive = true; }
			refresh_status();
			window.present();

			/* status was bound and never read, so a child that died on
			 * startup -- a stale lock file, a missing dependency, an
			 * unreadable config -- put the user back on this menu with no
			 * indication that anything had gone wrong, and the obvious
			 * response was to press the same button again. */
			report_child_exit(command, status);
		});

		window.set_visible(false);
	}

	/* Turn a wait status into something worth reading. A clean exit says
	 * nothing; anything else is worth a word, because the alternative is a
	 * window that silently reappears. */
	private void report_child_exit(string command, int status) {

		if (Process.if_exited(status)) {

			int code = Process.exit_status(status);

			if (code == 0) { return; }

			show_message("%s exited with an error".printf(command),
				"Exit code %d. The session log is /tmp/timeshift-recovery-session.log.".printf(code));
			return;
		}

		if (Process.if_signaled(status)) {
			show_message("%s stopped unexpectedly".printf(command),
				"It was terminated by signal %d.".printf((int) Process.term_sig(status)));
		}
	}

	private bool run_sync(string[] argv, out string output) {
		output = "";
		try {
			string std_out, std_err;
			int status;
			GLib.Process.spawn_sync(null, argv, null,
				SpawnFlags.SEARCH_PATH, null,
				out std_out, out std_err, out status);

			/* On failure prefer stderr: a command that printed something to
			 * stdout and then failed used to report only the stdout, hiding
			 * the actual reason. */
			if (status != 0) {
				output = (std_err.length > 0) ? std_err : std_out;
			}
			else {
				output = (std_out.length > 0) ? std_out : std_err;
			}

			return (status == 0);
		}
		catch (Error e) {
			output = e.message;
			return false;
		}
	}

	/* Like run_sync, but writes to the child's stdin. That is the only safe way
	 * to hand cryptsetup a passphrase: as an argument it would sit in /proc,
	 * readable by anything, for the life of the process. */
	private bool run_with_input(string[] argv, string input, out string output) {

		output = "";

		try {
			var proc = new GLib.Subprocess.newv(argv,
				GLib.SubprocessFlags.STDIN_PIPE
				| GLib.SubprocessFlags.STDOUT_PIPE
				| GLib.SubprocessFlags.STDERR_PIPE);

			string std_out, std_err;
			proc.communicate_utf8(input, null, out std_out, out std_err);

			bool ok = proc.get_successful();

			output = ok
				? ((std_out.length > 0) ? std_out : std_err)
				: ((std_err.length > 0) ? std_err : std_out);

			return ok;
		}
		catch (Error e) {
			output = e.message;
			return false;
		}
	}

	/* Connecting to a network takes seconds. Doing that synchronously freezes
	 * the whole launcher, which on a machine someone is already worried about
	 * looks exactly like a crash. */
	private async bool run_async(string[] argv, out string output) {
		output = "";
		try {
			var proc = new GLib.Subprocess.newv(argv,
				GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE);

			string std_out, std_err;
			yield proc.communicate_utf8_async(null, null, out std_out, out std_err);

			output = (std_err != null && std_err.length > 0) ? std_err : (std_out ?? "");
			return proc.get_successful();
		}
		catch (Error e) {
			output = e.message;
			return false;
		}
	}

	private string read_file(string path) {
		try {
			string contents;
			if (FileUtils.get_contents(path, out contents)) { return contents; }
		}
		catch (Error e) {
			// Absent files are ordinary here: the environment may boot before
			// anything has been configured.
		}
		return "";
	}

	private bool file_exists(string path) {
		return FileUtils.test(path, FileTest.EXISTS);
	}

	private bool is_mounted(string path) {
		return read_file("/proc/mounts").contains(" %s ".printf(path));
	}

	private void clear_box(Gtk.Box box) {
		Gtk.Widget? child = box.get_first_child();
		while (child != null) {
			Gtk.Widget? next = child.get_next_sibling();
			box.remove(child);
			child = next;
		}
	}

	private void clear_box_listbox(Gtk.ListBox box) {
		Gtk.Widget? child = box.get_first_child();
		while (child != null) {
			Gtk.Widget? next = child.get_next_sibling();
			box.remove(child);
			child = next;
		}
	}

	private string json_str(Json.Object obj, string member) {
		if (!obj.has_member(member)) { return ""; }
		var node = obj.get_member(member);
		if (node.is_null()) { return ""; }
		if (node.get_value_type() != typeof(string)) { return ""; }
		return node.get_string();
	}

	private string format_size(int64 bytes) {
		if (bytes <= 0) { return ""; }
		double b = (double) bytes;
		string[] units = { "B", "KB", "MB", "GB", "TB" };
		int i = 0;
		while (b >= 1000 && i < units.length - 1) { b /= 1000; i++; }
		return (i == 0) ? "%.0f %s".printf(b, units[i]) : "%.1f %s".printf(b, units[i]);
	}
}
