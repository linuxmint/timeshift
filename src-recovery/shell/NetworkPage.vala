/*
 * NetworkPage.vala
 *
 * Wi-Fi, ethernet and Tailscale for the Timeshift recovery shell.
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

public class NetworkPage : Page {

	private Gtk.Box body;
	private Gtk.Label status;
	private Gtk.Button rescan_button;

	// device -> the label showing its throughput, and its last/first counters
	private Gee.HashMap<string, Gtk.Label> rate_labels;
	private Gee.HashMap<string, string> prev_counters;
	private Gee.HashMap<string, string> base_counters;

	public NetworkPage(RecoveryWindow shell) {
		base(shell);
	}

	public override string key() { return "network"; }

	public override void on_shown() {
		refresh.begin();
	}

	public override Gtk.Widget build() {

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		box.margin_top = SPACE_XL;
		box.margin_bottom = SPACE_XL;
		box.margin_start = SPACE_PAGE;
		box.margin_end = SPACE_PAGE;

		Gtk.Box trailing;
		box.append(page_header("Network", out trailing));

		rescan_button = new Gtk.Button.with_label("Rescan");
		rescan_button.clicked.connect(() => { rescan_wifi.begin(); });
		trailing.append(rescan_button);

		status = new Gtk.Label("");
		status.halign = Gtk.Align.START;
		status.wrap = true;
		status.add_css_class("rs-status");
		status.margin_top = SPACE_S;
		box.append(status);

		body = new Gtk.Box(Gtk.Orientation.VERTICAL, SPACE_M);
		body.margin_top = SPACE_S;

		var scroll = new Gtk.ScrolledWindow();
		scroll.vexpand = true;
		scroll.child = body;
		box.append(scroll);

		rate_labels = new Gee.HashMap<string, Gtk.Label>();
		prev_counters = new Gee.HashMap<string, string>();
		base_counters = new Gee.HashMap<string, string>();

		/* Throughput ticks on its own timer reading /sys directly -- no
		 * subprocess, no relayout, so it stays smooth even while a restore has
		 * the machine busy. During a remote restore this number is the only
		 * sign that data is actually moving. */
		GLib.Timeout.add_seconds(1, () => {
			if (shell.current_page() == "network") { update_rates(); }
			return true;
		});

		return box;
	}

	/* Every read here used to run synchronously on the main thread: one nmcli
	 * for device status, ANOTHER nmcli per device for its IP, one for the wifi
	 * list, then tailscale twice. Fifteen-plus blocking spawns per refresh, and
	 * the UI froze for all of them -- badly so while a restore is using the CPU.
	 *
	 * Now: await everything, and ask for the IPs of all devices in ONE call
	 * rather than one call each. */
	private async void refresh() {

		rescan_button.sensitive = false;
		status.remove_css_class("rs-warn");
		status.label = "Reading network state...";

		string devs, ips, wifi, rf;
		yield Sh.run_async({ "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION",
		                     "device", "status" }, out devs);
		yield Sh.run_async({ "nmcli", "-t", "-f", "DEVICE,IP4.ADDRESS",
		                     "device", "show" }, out ips);
		yield Sh.run_async({ "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY",
		                     "device", "wifi", "list" }, out wifi);
		yield Sh.run_async({ "rfkill", "list", "wifi" }, out rf);

		bool have_ts = Tailscale.is_installed();
		string ts_ip = "", ts_prefs = "";
		if (have_ts) {
			ts_ip = yield Tailscale.ip();
			ts_prefs = yield Tailscale.prefs();
		}

		SysInfo.clear_box(body);
		rate_labels.clear();
		status.label = "";
		rescan_button.sensitive = true;

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

			body.append(warn_row);
		}

		if (devs.strip().length == 0) {
			status.add_css_class("rs-warn");
			status.label = "NetworkManager is not responding. Is it running?";
			return;
		}

		// One pass over `device show` builds device -> IP, instead of spawning
		// nmcli once per interface.
		var ip_map = new Gee.HashMap<string, string>();
		string current_dev = "";
		foreach (string line in ips.split("\n")) {
			string[] f = SysInfo.split_terse(line);
			if (f.length < 2) { continue; }
			if (f[0] == "DEVICE") { current_dev = f[1]; continue; }
			if (f[0].has_prefix("IP4.ADDRESS") && current_dev.length > 0) {
				if (!ip_map.has_key(current_dev) && f[1].length > 0 && f[1] != "--") {
					ip_map.set(current_dev, f[1]);
				}
			}
		}

		section(body, "INTERFACES");

		bool any_device = false;
		foreach (string line in devs.split("\n")) {
			if (line.strip().length == 0) { continue; }
			string[] f = SysInfo.split_terse(line);
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
			body.append(l);
		}

		if (wifi.strip().length > 0) {
			section(body, "WI-FI NETWORKS");

			var seen = new Gee.HashSet<string>();
			foreach (string line in wifi.split("\n")) {
				if (line.strip().length == 0) { continue; }
				string[] f = SysInfo.split_terse(line);
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

		body.append(row);
	}

	/* Kernel counters straight from /sys: no subprocess, so this can run every
	 * second without the stutter that made the menu feel frozen. */
	private void update_rates() {

		foreach (var dev in rate_labels.keys) {

			string rx = SysInfo.read_file("/sys/class/net/%s/statistics/rx_bytes".printf(dev)).strip();
			string tx = SysInfo.read_file("/sys/class/net/%s/statistics/tx_bytes".printf(dev)).strip();
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
						SysInfo.format_size((int64) rx_rate), SysInfo.format_size((int64) tx_rate));
				}
			}

			string[] b = base_counters.get(dev).split(":");
			if (b.length == 2) {
				uint64 total = rx_now - uint64.parse(b[0]);
				if (total > 0) {
					label += "   %s received this session".printf(SysInfo.format_size((int64) total));
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

		body.append(row);
	}

	private void add_tailscale_section(string ip, string prefs) {

		section(body, "TAILSCALE");

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
			detail += Tailscale.accepting_routes(prefs)
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
			bool accepting = Tailscale.accepting_routes(prefs);

			var btn = new Gtk.Button.with_label(
				accepting ? "Stop using subnet routes" : "Use subnet routes");
			btn.valign = Gtk.Align.CENTER;
			btn.clicked.connect(() => { tailscale_set_routes.begin(!accepting); });
			row.append(btn);
		}

		body.append(row);
	}

	// --- actions (async: these block for seconds) ---------------------------

	private void set_busy(string message) {
		status.remove_css_class("rs-warn");
		status.label = message;
		rescan_button.sensitive = false;
	}

	private async void unblock_wifi() {
		set_busy("Unblocking Wi-Fi...");
		string o;
		yield Sh.run_async({ "rfkill", "unblock", "wifi" }, out o);
		yield refresh();
	}

	private async void rescan_wifi() {
		set_busy("Scanning for networks...");
		string o;
		yield Sh.run_async({ "nmcli", "device", "wifi", "rescan" }, out o);
		yield refresh();
	}

	private async void run_device_action(string dev, bool connected) {
		set_busy(connected ? "Disconnecting %s...".printf(dev)
		                   : "Connecting %s...".printf(dev));
		string o;
		bool ok = yield Sh.run_async(
			{ "nmcli", "device", connected ? "disconnect" : "connect", dev }, out o);
		if (!ok) { shell.show_message("Could not %s %s".printf(
			connected ? "disconnect" : "connect", dev), o); }
		yield refresh();
	}

	/* A saved network -- and the environment carries the host's saved networks
	 * -- connects with no prompt. Only ask for a passphrase when there is
	 * nothing stored to try. */
	private async void start_wifi_connect(string ssid, bool open_network) {

		if (open_network) { yield connect_wifi(ssid, null); return; }

		string o;
		bool saved = false;
		if (yield Sh.run_async({ "nmcli", "-t", "-f", "NAME", "connection", "show" }, out o)) {
			foreach (string line in o.split("\n")) {
				if (line.strip() == ssid) { saved = true; break; }
			}
		}

		if (saved) { yield connect_wifi(ssid, null); }
		else { shell.show_password(ssid, (pw) => { connect_wifi.begin(ssid, pw); }); }
	}

	private async void connect_wifi(string ssid, string? password) {
		set_busy("Connecting to %s...".printf(ssid));

		string o;
		bool ok;
		if (password == null) {
			ok = yield Sh.run_async({ "nmcli", "device", "wifi", "connect", ssid }, out o);
		}
		else {
			ok = yield Sh.run_async(
				{ "nmcli", "device", "wifi", "connect", ssid, "password", password }, out o);
		}

		if (!ok) { shell.show_message("Could not connect to %s".printf(ssid), o); }
		yield refresh();
	}

	private async void tailscale_set_routes(bool accept) {

		set_busy(accept ? "Accepting subnet routes..." : "Dropping subnet routes...");

		string o;
		bool ok = yield Tailscale.set_routes(accept, out o);

		if (!ok) {
			shell.show_message("Could not change subnet routes", o);
		}

		yield refresh();
	}

	private async void tailscale_up() {
		set_busy("Joining the tailnet...");

		string o;
		bool ok = yield Tailscale.up(out o);

		if (!ok) {
			// A login URL means the copied node identity was not accepted.
			if (o.contains("https://login.tailscale.com")) {
				shell.show_message("Tailscale needs a login",
					"Open this URL on another device to authorise this machine:\n\n" + o.strip());
			}
			else {
				shell.show_message("Could not join the tailnet", o);
			}
		}
		yield refresh();
	}
}
