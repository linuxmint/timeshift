/*
 * HomePage.vala
 *
 * The front page of the Timeshift recovery shell.
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

public delegate void ActionFunc();

public class HomePage : Page {

	private Gtk.Label status_label;
	private Gtk.Button? restore_button = null;

	public HomePage(RecoveryWindow shell) {
		base(shell);
	}

	public override string key() { return "home"; }

	public override Gtk.Widget build() {

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
			() => { shell.show_page("network"); });

		add_action(box, "drive-harddisk-symbolic", "Storage",
			"Mount an external drive holding snapshots.",
			() => { shell.show_page("drives"); });

		restore_button = add_action(box, "document-revert-symbolic", "Restore system",
			"Open Timeshift and restore a snapshot onto this machine.",
			() => { shell.launch_app("timeshift-gtk"); });

		add_action(box, "utilities-terminal-symbolic", "Terminal",
			"A root shell, for anything the buttons above do not cover.",
			() => { shell.open_terminal("Terminal", { "/bin/bash" }); });

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
		diag.clicked.connect(() => { shell.show_page("diagnostics"); });
		footer.append(diag);

		var reboot = new Gtk.Button.with_label("Reboot");
		reboot.clicked.connect(() => {
			shell.show_confirm("Reboot now?",
				"The environment runs from RAM; nothing here is kept.",
				"Reboot", false, () => { shell.launch("reboot"); });
		});
		footer.append(reboot);

		var poweroff = new Gtk.Button.with_label("Power off");
		poweroff.clicked.connect(() => {
			shell.show_confirm("Power off now?",
				"The environment runs from RAM; nothing here is kept.",
				"Power off", false, () => { shell.launch("poweroff"); });
		});
		footer.append(poweroff);

		outer.append(footer);

		return outer;
	}

	/* Disabled while a launched app owns the screen, so a second Restore
	 * cannot start a second Timeshift. */
	public void set_restore_sensitive(bool sensitive) {
		if (restore_button != null) { restore_button.sensitive = sensitive; }
	}

	/* The thing that silently breaks a restore: the environment booted from an
	 * image on the disk it is about to rewrite, and that disk is still mounted.
	 * Say so on the front page rather than letting the restore fail. */
	public void refresh_status() {

		if (status_label == null) { return; }

		status_label.remove_css_class("rs-warn");

		string cmdline = SysInfo.read_file("/proc/cmdline");
		bool toram = cmdline.contains("toram");

		if (!toram && cmdline.contains("iso-scan/filename=")) {
			status_label.add_css_class("rs-warn");
			status_label.label =
				"Warning: booted from an image on this machine's disk without toram. "
				+ "Restoring to that disk will fail while it is still mounted.";
			return;
		}

		if (SysInfo.is_mounted("/isodevice")) {
			status_label.add_css_class("rs-warn");
			status_label.label =
				"Warning: the boot medium's disk is still mounted at /isodevice. "
				+ "Run /usr/lib/timeshift-recovery/release-medium from the terminal "
				+ "before restoring to it.";
			return;
		}

		string repo = SysInfo.snapshot_location();
		status_label.label = (repo.length > 0)
			? "Snapshots: %s".printf(repo)
			: "No snapshot location is configured. Set one in Timeshift.";
	}

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
}
