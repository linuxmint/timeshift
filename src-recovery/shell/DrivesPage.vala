/*
 * DrivesPage.vala
 *
 * Mounting, unmounting and unlocking drives in the Timeshift recovery shell.
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

public class DrivesPage : Page {

	private Gtk.ListBox list;

	public DrivesPage(RecoveryWindow shell) {
		base(shell);
	}

	public override string key() { return "drives"; }

	public override void on_shown() {
		refresh();
	}

	public override Gtk.Widget build() {

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		box.margin_top = SPACE_XL;
		box.margin_bottom = SPACE_XL;
		box.margin_start = SPACE_PAGE;
		box.margin_end = SPACE_PAGE;

		Gtk.Box trailing;
		box.append(page_header("Storage", out trailing));

		var refresh_button = new Gtk.Button.with_label("Refresh");
		refresh_button.clicked.connect(() => { refresh(); });
		trailing.append(refresh_button);

		list = new Gtk.ListBox();
		list.add_css_class("rs-card");
		list.selection_mode = Gtk.SelectionMode.NONE;
		list.margin_top = SPACE_L;
		// hug the rows; a card stretched to the page bottom reads as empty
		list.valign = Gtk.Align.START;

		var scroll = new Gtk.ScrolledWindow();
		scroll.vexpand = true;
		scroll.child = list;
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

	private void refresh() {

		SysInfo.clear_listbox(list);

		/* LVM volumes inside an already-unlocked container are invisible to
		 * lsblk until the volume group is activated, and a Timeshift restore
		 * cannot select a device it cannot see. Cheap, idempotent, and quiet
		 * when there is no LVM at all. */
		string ignored;
		Sh.run_sync({ "vgchange", "-ay" }, out ignored);

		string output;
		if (!Sh.run_sync({ "lsblk", "-J", "-b", "-o",
		                   "PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,RM,MODEL" }, out output)) {
			add_message("Could not read the drive list (lsblk failed).");
			return;
		}

		int shown = 0;

		try {
			var parser = new Json.Parser();
			parser.load_from_data(output);

			var root = parser.get_root();
			if (root == null) { add_message("Could not read the drive list."); return; }

			var devices = root.get_object().get_array_member("blockdevices");
			if (devices == null) { add_message("No drives found."); return; }

			foreach (var element in devices.get_elements()) {
				shown += add_device_rows(element.get_object(), "");
			}
		}
		catch (Error e) {
			add_message("Could not read the drive list: %s".printf(e.message));
			return;
		}

		if (shown == 0) {
			add_message("No mountable drives found. Attach one and press Refresh.");
		}
	}

	/* lsblk nests partitions under their disk, so walk children too. Only rows
	 * with a filesystem are actionable; a bare disk or an extended partition
	 * would just be noise on a page whose only purpose is "mount this". */
	private int add_device_rows(Json.Object dev, string parent_model) {

		int count = 0;

		string path = SysInfo.json_str(dev, "path");
		string fstype = SysInfo.json_str(dev, "fstype");
		string label = SysInfo.json_str(dev, "label");
		string mountpoint = SysInfo.json_str(dev, "mountpoint");
		string model = SysInfo.json_str(dev, "model");
		if (model.length == 0) { model = parent_model; }

		int64 size = 0;
		if (dev.has_member("size") && dev.get_member("size").get_value_type() == typeof(int64)) {
			size = dev.get_int_member("size");
		}

		if (fstype.length > 0 && fstype != "squashfs" && path.length > 0) {
			add_row(path, fstype, label, mountpoint, model, size);
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

	private void add_row(string path, string fstype, string label,
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
		detail.append("%s  %s".printf(path, SysInfo.format_size(size)));
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

		list.append(row);
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

		if (!Sh.run_sync({ "mkdir", "-p", target }, out output)) {
			shell.show_message("Could not create %s".printf(target), output);
			return;
		}

		if (!Sh.run_sync({ "mount", path, target }, out output)) {
			// leave no empty directory behind to confuse the next attempt
			string ignored;
			Sh.run_sync({ "rmdir", target }, out ignored);

			shell.show_message("Could not mount %s".printf(path),
				output.length > 0 ? output : "The operation failed.");
		}

		refresh();
	}

	private void unmount_path(string mountpoint) {

		string output;

		if (!Sh.run_sync({ "umount", mountpoint }, out output)) {
			shell.show_message("Could not unmount %s".printf(mountpoint),
				output.length > 0 ? output : "Something is still using it.");
		}
		else if (mountpoint.has_prefix("/media/")) {
			string ignored;
			Sh.run_sync({ "rmdir", mountpoint }, out ignored);
		}

		refresh();
	}

	private void unlock_luks(string path) {

		shell.show_password_prompt("Unlock %s".printf(path),
			"Enter the passphrase for this encrypted device.", (passphrase) => {

			string name = "luks-" + Path.get_basename(path);

			/* The passphrase goes in on stdin -- never on a command line,
			 * where it would be visible in /proc to anything that looked. */
			string output;
			if (!Sh.run_with_input({ "cryptsetup", "luksOpen", path, name },
			                       passphrase + "\n", out output)) {
				shell.show_message("Could not unlock %s".printf(path),
					output.length > 0 ? output : "The passphrase may be wrong.");
				return;
			}

			// an unlocked container usually holds LVM; make its volumes visible
			string ignored;
			Sh.run_sync({ "vgchange", "-ay" }, out ignored);

			refresh();
		});
	}

	private void add_message(string text) {
		var l = new Gtk.Label(text);
		l.margin_top = SPACE_L;
		l.margin_bottom = SPACE_L;
		l.wrap = true;
		l.add_css_class("rs-action-desc");
		list.append(l);
	}
}
