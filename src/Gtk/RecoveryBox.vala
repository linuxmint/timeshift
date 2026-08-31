/*
 * RecoveryBox.vala
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
 *
 *
 */

using Gtk;
using Gee;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

/* Settings page for the press-a-key recovery environment.
 *
 * Provisioning is done by the external timeshift-recovery tool; this page
 * only reads its machine status and wraps its verbs. Enable/disable are
 * instant (they toggle the GRUB entry, the payload stays on disk); install
 * builds an image and takes minutes, so it streams the tool's output. */
class RecoveryBox : Gtk.Box {

	private Gtk.Window parent_window;

	private StatusCard card;
	private Banner banner;
	private Gtk.Box detail_box;
	private Gtk.Button btn_install;
	private Gtk.Button btn_enable;
	private Gtk.Button btn_disable;
	private LogPane log_pane;

	private bool op_running = false;
	private bool refreshing = false;

	private Gee.HashMap<string,string> stat = new Gee.HashMap<string,string>();

	public RecoveryBox(Gtk.Window _parent_window){

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.MD);

		parent_window = _parent_window;

		Ui.add_title(this, _("Recovery Environment"), 2);
		Ui.add_body(this, _("A minimal system stored on this machine that can restore a snapshot even when the installed system no longer boots. Press the hotkey while the machine starts to enter it."));

		card = new StatusCard();
		append(card);

		banner = new Banner();
		append(banner);

		detail_box = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.XS);
		append(detail_box);

		var action_row = Ui.add_button_row(this);

		btn_install = new Gtk.Button.with_label(_("Install..."));
		btn_install.clicked.connect(on_install);
		action_row.append(btn_install);

		btn_enable = new Gtk.Button.with_label(_("Enable"));
		btn_enable.add_css_class("suggested-action");
		btn_enable.clicked.connect(on_enable);
		action_row.append(btn_enable);

		btn_disable = new Gtk.Button.with_label(_("Disable"));
		btn_disable.clicked.connect(on_disable);
		action_row.append(btn_disable);

		log_pane = new LogPane();
		append(log_pane);

		/* Refresh whenever the page becomes visible: the state can change
		 * underneath us (the package trigger's refresh service, a terminal). */
		this.map.connect(() => { refresh(); });
	}

	// --- status -------------------------------------------------------------

	private string stat_val(string key, string def){
		return stat.has_key(key) ? stat.get(key) : def;
	}

	public void refresh(){

		if (op_running || refreshing){ return; }

		if (!file_exists(RecoveryToolTask.TOOL)){
			render_missing();
			return;
		}

		refreshing = true;

		string std_out = "";
		bool thr_running = true;

		try {
			new Thread<bool>.try("recovery-status", () => {
				string o, e;
				exec_script_sync(RecoveryToolTask.TOOL + " status --machine\n",
					out o, out e, true);
				std_out = (o == null) ? "" : o;
				thr_running = false;
				return true;
			});
		}
		catch (Error err){
			log_error(err.message);
			thr_running = false;
		}

		gtk_set_busy(true, parent_window);
		while (thr_running){
			gtk_do_events();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 50);
		}
		gtk_set_busy(false, parent_window);

		stat.clear();
		foreach (string line in std_out.split("\n")){
			int eq = line.index_of("=");
			if (eq > 0){
				stat.set(line.substring(0, eq), line.substring(eq + 1).strip());
			}
		}

		refreshing = false;
		render();
	}

	private void render_missing(){

		card.set_shield(IconManager.SHIELD_LOW);
		card.set_title(_("Recovery tool not installed"));
		card.set_subtitle(_("Install the timeshift-recovery package to provision a bootable recovery environment"));

		banner.clear();
		Ui.clear_children(detail_box);

		btn_install.visible = false;
		btn_enable.visible = false;
		btn_disable.visible = false;
	}

	private void render(){

		banner.clear();
		Ui.clear_children(detail_box);

		bool installed = (stat_val("INSTALLED", "0") == "1");
		bool disabled = (stat_val("DISABLED", "0") == "1");
		bool stale = (stat_val("STALE", "0") == "1");
		bool grub_ok = (stat_val("GRUB_OK", "0") == "1");
		string hotkey = stat_val("HOTKEY", "r");

		if (!installed){
			card.set_shield(IconManager.SHIELD_LOW);
			card.set_title(_("Not installed"));
			card.set_subtitle(_("No recovery environment is provisioned on this machine"));

			btn_install.visible = true;
			btn_enable.visible = false;
			btn_disable.visible = false;
			return;
		}

		if (disabled){
			card.set_shield(IconManager.SHIELD_MED);
			card.set_title(_("Disabled"));
			card.set_subtitle(_("The boot entry is removed; the payload is kept, so enabling is instant"));
		}
		else if (!grub_ok){
			card.set_shield(IconManager.SHIELD_MED);
			card.set_title(_("Installed, but the hotkey will not work"));
			card.set_subtitle(_("The boot entry exists but cannot be reached at startup"));

			/* The likeliest cause on Ubuntu: another drop-in resetting
			 * GRUB_TIMEOUT to 0, after which GRUB reads no keys at all. */
			banner.set_message(_("The effective GRUB timeout is 0, so GRUB reads no keys at startup. Another configuration file is overriding the timeout this feature needs."),
				Gtk.MessageType.WARNING);
		}
		else {
			card.set_shield(IconManager.SHIELD_HIGH);
			card.set_title(_("Installed"));
			card.set_subtitle(_("Press '%s' while the machine starts to enter the recovery environment").printf(hotkey));
		}

		btn_install.visible = false;
		btn_enable.visible = disabled;
		btn_disable.visible = !disabled;

		add_detail(_("Target"), "%s (%s)".printf(
			stat_val("TARGET_DEV", ""), stat_val("TARGET_KIND", "")));

		string env_ver = stat_val("ENV_VERSION", "");
		string host_ver = stat_val("HOST_VERSION", "");
		if ((env_ver != host_ver) && (host_ver.length > 0)){
			add_detail(_("Version"), "%s (%s %s)".printf(env_ver, _("system has"), host_ver));
		}
		else {
			add_detail(_("Version"), env_ver);
		}

		add_detail(_("Installed"), stat_val("INSTALLED_AT", ""));

		if (stale){
			Ui.add_caption(detail_box, _("An update is pending; it is applied automatically after package upgrades."));
		}
	}

	private void add_detail(string label, string value){
		if (value.strip().length == 0){ return; }
		Ui.add_caption(detail_box, "%s: %s".printf(label, value));
	}

	// --- actions ------------------------------------------------------------

	private void on_enable(){
		// Non-destructive and instant; no confirmation needed.
		run_short("enable --yes", _("Could not enable the recovery environment"));
	}

	private void on_disable(){

		var dlg = new CustomMessageDialog(
			_("Disable the recovery environment?"),
			_("Pressing the hotkey at startup will stop working until it is enabled again. The payload stays on disk, so enabling it later is instant."),
			Gtk.MessageType.QUESTION, parent_window, Gtk.ButtonsType.YES_NO);

		var resp = dlg.run();

		if (resp != Gtk.ResponseType.YES){ return; }

		run_short("disable --yes", _("Could not disable the recovery environment"));
	}

	/* Enable/disable only toggle the GRUB entry: seconds, no progress worth
	 * showing. A worker thread keeps the window alive through update-grub. */
	private void run_short(string args_line, string fail_title){

		if (op_running){ return; }
		op_running = true;

		string std_err = "";
		int rc = -1;
		bool thr_running = true;

		try {
			new Thread<bool>.try("recovery-op", () => {
				string o, e;
				rc = exec_script_sync(
					"%s %s\nexit $?\n".printf(RecoveryToolTask.TOOL, args_line),
					out o, out e, true);
				std_err = (e == null) ? "" : e.strip();
				thr_running = false;
				return true;
			});
		}
		catch (Error err){
			log_error(err.message);
			thr_running = false;
		}

		gtk_set_busy(true, parent_window);
		while (thr_running){
			gtk_do_events();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 100);
		}
		gtk_set_busy(false, parent_window);

		op_running = false;

		if (rc != 0){
			gtk_messagebox(fail_title,
				(std_err.length > 0) ? std_err : _("The operation failed. See /var/log/timeshift-recovery.log"),
				parent_window, true);
		}

		refresh();
	}

	private void on_install(){

		if (op_running){ return; }

		/* The credential note mirrors the CLI's install warning: embedding is
		 * what makes an unattended restore possible on a broken machine, and
		 * the cost belongs in front of the user before the build starts. */
		var dlg = new CustomMessageDialog(
			_("Install the recovery environment?"),
			_("This downloads packages and builds a bootable image; it can take several minutes.\n\nThe image embeds the SSH key, saved Wi-Fi passphrases and the Tailscale identity so an unattended restore works. They are readable by anyone who can boot this machine; opt-outs are described in /etc/timeshift-recovery/config."),
			Gtk.MessageType.QUESTION, parent_window, Gtk.ButtonsType.YES_NO);

		var resp = dlg.run();

		if (resp != Gtk.ResponseType.YES){ return; }

		op_running = true;
		set_buttons_sensitive(false);

		log_pane.clear();
		log_pane.expanded = true;

		var task = new RecoveryToolTask("install --yes");
		task.execute();

		while (task.status == AppStatus.RUNNING){
			log_pane.append_lines(task.drain_output());
			gtk_do_events();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 100);
		}

		log_pane.append_lines(task.drain_output());

		set_buttons_sensitive(true);
		op_running = false;

		if (task.exit_code != 0){
			gtk_messagebox(_("Could not install the recovery environment"),
				_("See the details below, or /var/log/timeshift-recovery.log"),
				parent_window, true);
		}

		refresh();
	}

	private void set_buttons_sensitive(bool sensitive){
		btn_install.sensitive = sensitive;
		btn_enable.sensitive = sensitive;
		btn_disable.sensitive = sensitive;
	}
}
