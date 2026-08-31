/*
 * SysInfo.vala
 *
 * File, mount, JSON and formatting helpers for the Timeshift recovery shell.
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

namespace SysInfo {

	public const string CONFIG_PATH = "/etc/timeshift/timeshift.json";

	public string read_file(string path) {
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

	public bool file_exists(string path) {
		return FileUtils.test(path, FileTest.EXISTS);
	}

	public bool is_mounted(string path) {
		return read_file("/proc/mounts").contains(" %s ".printf(path));
	}

	public string json_str(Json.Object obj, string member) {
		if (!obj.has_member(member)) { return ""; }
		var node = obj.get_member(member);
		if (node.is_null()) { return ""; }
		if (node.get_value_type() != typeof(string)) { return ""; }
		return node.get_string();
	}

	public string format_size(int64 bytes) {
		if (bytes <= 0) { return ""; }
		double b = (double) bytes;
		string[] units = { "B", "KB", "MB", "GB", "TB" };
		int i = 0;
		while (b >= 1000 && i < units.length - 1) { b /= 1000; i++; }
		return (i == 0) ? "%.0f %s".printf(b, units[i]) : "%.1f %s".printf(b, units[i]);
	}

	/* nmcli terse output separates fields with ':' and escapes literal colons as
	 * '\:'. Splitting naively mangles any SSID or MAC containing one. */
	public string[] split_terse(string line) {
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

	public void clear_box(Gtk.Box box) {
		Gtk.Widget? child = box.get_first_child();
		while (child != null) {
			Gtk.Widget? next = child.get_next_sibling();
			box.remove(child);
			child = next;
		}
	}

	public void clear_listbox(Gtk.ListBox box) {
		Gtk.Widget? child = box.get_first_child();
		while (child != null) {
			Gtk.Widget? next = child.get_next_sibling();
			box.remove(child);
			child = next;
		}
	}

	/* One string key out of the seeded Timeshift config; "" when absent. */
	public string timeshift_config_value(string key) {

		string text = read_file(CONFIG_PATH);
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

	/* Read the configured repository straight out of Timeshift's config, so the
	 * front page can say where a restore would come from without starting it. */
	public string snapshot_location() {

		string text = read_file(CONFIG_PATH);
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
			warning("could not parse %s: %s", CONFIG_PATH, e.message);
		}

		return "";
	}
}
