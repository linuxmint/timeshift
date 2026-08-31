/*
 * DiagnosticsPage.vala
 *
 * The "why can it not reach the repository" report of the recovery shell.
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

public class DiagnosticsPage : Page {

	private Gtk.TextView view;

	public DiagnosticsPage(RecoveryWindow shell) {
		base(shell);
	}

	public override string key() { return "diagnostics"; }

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
		box.append(page_header("Diagnostics", out trailing));

		var refresh_button = new Gtk.Button.with_label("Refresh");
		refresh_button.clicked.connect(() => { refresh(); });
		trailing.append(refresh_button);

		view = new Gtk.TextView();
		view.editable = false;
		view.monospace = true;
		view.add_css_class("rs-log");
		view.margin_top = SPACE_L;
		// TextView's own margins pad the text inside the inner `text` node,
		// where CSS padding is unreliable.
		view.left_margin = SPACE_M;
		view.right_margin = SPACE_M;
		view.top_margin = SPACE_M;
		view.bottom_margin = SPACE_M;

		var scroll = new Gtk.ScrolledWindow();
		scroll.vexpand = true;
		scroll.child = view;
		box.append(scroll);

		return box;
	}

	private void refresh() {

		var b = new StringBuilder();
		string o;

		string cmdline = SysInfo.read_file("/proc/cmdline");
		bool toram = cmdline.contains("toram");
		bool iso_scan = cmdline.contains("iso-scan/filename=");

		b.append("BOOT\n");
		b.append("  mode:            %s\n".printf(
			iso_scan ? "image on the system disk (iso-scan)" : "dedicated medium"));
		b.append("  toram:           %s\n".printf(toram ? "yes" : "no"));
		b.append("  medium mounted:  %s\n".printf(
			SysInfo.is_mounted("/isodevice") ? "/isodevice STILL MOUNTED"
			                                 : "released (or not applicable)"));
		if (iso_scan && SysInfo.is_mounted("/isodevice")) {
			b.append("  WARNING: restoring to that disk will fail while it is mounted.\n");
			b.append("           run /usr/lib/timeshift-recovery/release-medium\n");
		}
		b.append("  cmdline:         %s\n".printf(cmdline.strip()));

		b.append("\nNETWORK\n");
		if (Sh.run_sync({ "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION",
		                  "device", "status" }, out o)) {
			foreach (string line in o.split("\n")) {
				if (line.strip().length > 0) { b.append("  %s\n".printf(line)); }
			}
		}
		else { b.append("  nmcli failed - is NetworkManager running?\n"); }

		if (Tailscale.is_installed()) {
			b.append("\nTAILSCALE\n");
			if (Sh.run_sync({ "tailscale", "status", "--peers=false" }, out o)) {
				foreach (string line in o.split("\n")) {
					if (line.strip().length > 0) { b.append("  %s\n".printf(line)); }
				}
			}
			else { b.append("  %s\n".printf(o.strip())); }

			/* Whether subnet routes advertised by peers are being imported.
			 * This is what --accept-routes sets, and it can silently take a
			 * LAN host away from a working direct path. */
			b.append("  subnet routes:   %s\n".printf(
				Tailscale.accept_routes_enabled() ? "accepted (--accept-routes)" : "not accepted"));
		}

		b.append("\nSNAPSHOT REPOSITORY\n");
		string repo = SysInfo.snapshot_location();
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
			bool icmp = Sh.run_sync({ "ping", "-c", "1", "-W", "3", host }, out o);

			/* Unmultiplexed on purpose, exactly as the restore's own probe
			 * now is: a client attaching to a wedged ControlMaster socket
			 * never performs connect(), so ConnectTimeout would not apply.
			 *
			 * Key and port come from the seeded config: probing with the
			 * default key against a custom-key setup would report FAILED for
			 * a repository the restore can actually reach. */
			string key_file = SysInfo.timeshift_config_value("backup_ssh_key");
			if (key_file.length == 0) { key_file = "/etc/timeshift/ssh/id_ed25519"; }
			string port = SysInfo.timeshift_config_value("backup_ssh_port");

			string[] ssh_cmd = { "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
			                     "-o", "ControlMaster=no", "-o", "ControlPath=none",
			                     "-o", "StrictHostKeyChecking=no",
			                     "-i", key_file };
			if (port.length > 0) { ssh_cmd += "-p"; ssh_cmd += port; }
			ssh_cmd += hostpart;
			ssh_cmd += "true";
			bool tcp = Sh.run_sync(ssh_cmd, out o);

			b.append("  ping (ICMP):     %s\n".printf(icmp ? "answers" : "no reply"));
			b.append("  ssh (TCP):       %s\n".printf(
				tcp ? "connects" : "FAILED - %s".printf(o.strip())));

			// which way out the traffic actually goes
			string route;
			if (Sh.run_sync({ "ip", "route", "get", host }, out route)) {
				b.append("  route:           %s\n".printf(route.strip().split("\n")[0]));
			}

			if (icmp && !tcp) {
				b.append("\n  ICMP answers but TCP does not. That is a routing or firewall\n");
				b.append("  problem, not an unreachable host -- do not trust ping here.\n");
				if (Tailscale.routes_via(host)) {
					b.append("  This host currently routes over the tailnet. If it is on the\n");
					b.append("  same network as this machine, turn subnet routes off on the\n");
					b.append("  Network page so the direct path is used instead.\n");
				}
			}
		}

		b.append("\nRECENT ERRORS\n");
		if (Sh.run_sync({ "journalctl", "-p", "err", "-n", "25", "--no-pager" }, out o)) {
			foreach (string line in o.split("\n")) {
				if (line.strip().length > 0) { b.append("  %s\n".printf(line)); }
			}
		}

		view.buffer.text = b.str;
	}
}
