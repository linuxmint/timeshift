/*
 * BackupBox.vala
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
 *
 */

using Gtk;
using Gee;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

class BackupDeviceBox : Gtk.Box{

	private Gtk.TreeView tv_devices;
	private Gtk.ScrolledWindow sw_devices;
	private Gtk.Button btn_refresh;
	private Gtk.InfoBar infobar_location;
	private Gtk.Label lbl_infobar_location;
	private Gtk.Label lbl_common;

	// remote (SSH) location
	private Gtk.RadioButton opt_local;
	private Gtk.RadioButton opt_ssh;
	private Gtk.Box vbox_ssh;
	private Gtk.Entry txt_ssh_url;
	private Gtk.Entry txt_ssh_key;
	private Gtk.SpinButton spin_ssh_port;
	private Gtk.CheckButton chk_ssh_fake_super;
	
	private Gtk.Window parent_window;

	public BackupDeviceBox (Gtk.Window _parent_window) {

		log_debug("BackupDeviceBox: BackupDeviceBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		add(hbox);

		add_label_header(hbox, _("Select Snapshot Location"), true);

		// buffer
		var label = add_label(hbox, "");
        label.hexpand = true;
       
		// refresh device button
		
		var size_group = new Gtk.SizeGroup(SizeGroupMode.HORIZONTAL);
		btn_refresh = add_button(hbox, _("Refresh"), "", size_group, null);
        btn_refresh.clicked.connect(()=>{
			App.update_partitions();
			tv_devices_refresh();
		});

		// local / remote selector
		init_location_type();

		// remote (SSH) settings
		init_ssh_box();

		// TODO: show this message somewhere
		
		//var msg = _("Only Linux partitions are supported.");
		//msg += "\n" + _("Snapshots will be saved in folder /timeshift");

		// treeview
		init_tv_devices();

		// tooltips
		//tv_devices.set_tooltip_text(msg);

		// infobar
		init_infobar_location();

		log_debug("BackupDeviceBox: BackupDeviceBox(): exit");
    }

    public void refresh(){

		// reflect the stored settings in the form
		txt_ssh_url.text = App.backup_ssh_url;
		txt_ssh_key.text = App.backup_ssh_key;
		spin_ssh_port.set_value((App.backup_ssh_port > 0) ? App.backup_ssh_port : 22);
		chk_ssh_fake_super.active = App.backup_ssh_fake_super;

		tv_devices_refresh();
		
		check_backup_location();

		// must run last: the parent windows call show_all() on this box
		update_location_widgets();
	}

	/* Local device vs remote (SSH) selector. Both parents of this box
	 * (SettingsWindow and SetupWizardWindow) embed it, so putting the choice
	 * here makes remote locations available in the wizard too. */
	private void init_location_type(){

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
		add(hbox);

		opt_local = new Gtk.RadioButton.with_label_from_widget(null, _("Local device"));
		opt_local.set_tooltip_text(_("Save snapshots to a disk attached to this computer"));
		hbox.add(opt_local);

		opt_ssh = new Gtk.RadioButton.with_label_from_widget(opt_local, _("Remote (SSH)"));
		opt_ssh.set_tooltip_text(_("Save snapshots to another computer over SSH"));
		hbox.add(opt_ssh);

		// toggled fires on both the activated and the deactivated button
		opt_local.toggled.connect(()=>{
			if (!opt_local.active){ return; }
			if (App.backup_location_type == "local"){ return; }

			App.backup_location_type = "local";

			// Drop the remote repo first: try_select_default_device_for_backup()
			// deliberately leaves a remote repository alone, so it would not
			// pick a local device while the old one is still in place.
			App.repo = new SnapshotRepo.from_null();
			App.try_select_default_device_for_backup(parent_window);

			update_location_widgets();
			tv_devices_refresh();
			check_backup_location();
		});

		opt_ssh.toggled.connect(()=>{
			if (!opt_ssh.active){ return; }
			if (App.backup_location_type == "ssh"){ return; }

			// Switch the mode up front so the form stays visible even when the
			// location is still blank or unreachable - otherwise
			// update_location_widgets() would snap the radio back to Local.
			App.backup_location_type = "ssh";
			App.btrfs_mode = false;

			update_location_widgets();
			change_backup_ssh();
		});
	}

	private void init_ssh_box(){

		vbox_ssh = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
		// parents call show_all(); no_show_all keeps this hidden in local mode
		vbox_ssh.no_show_all = true;
		add(vbox_ssh);

		var sg_label = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);

		// location ------------------------------------------------

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		vbox_ssh.add(hbox);

		var label = add_label(hbox, _("Location"));
		sg_label.add_widget(label);

		txt_ssh_url = new Gtk.Entry();
		txt_ssh_url.hexpand = true;
		txt_ssh_url.placeholder_text = "user@host:/path";
		txt_ssh_url.set_tooltip_text(_("Example") + ": user@nas:/backups");
		hbox.add(txt_ssh_url);

		txt_ssh_url.focus_out_event.connect((w, e) => {
			App.backup_ssh_url = txt_ssh_url.text.strip();
			return false;
		});

		// ssh key -------------------------------------------------

		hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		vbox_ssh.add(hbox);

		label = add_label(hbox, _("SSH key"));
		sg_label.add_widget(label);

		txt_ssh_key = new Gtk.Entry();
		txt_ssh_key.hexpand = true;
		txt_ssh_key.placeholder_text = "/etc/timeshift/ssh/id_ed25519";
		txt_ssh_key.set_tooltip_text(_("Private key used to connect. Use 'Set up with password' if you do not have one yet."));
		hbox.add(txt_ssh_key);

		txt_ssh_key.focus_out_event.connect((w, e) => {
			App.backup_ssh_key = txt_ssh_key.text.strip();
			return false;
		});

		var btn_browse = add_button(hbox, _("Browse"), "", null, null);
		btn_browse.clicked.connect(()=>{
			string? path = browse_ssh_key();
			if (path != null){
				txt_ssh_key.text = path;
				App.backup_ssh_key = path;
			}
		});

		// port ----------------------------------------------------

		hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		vbox_ssh.add(hbox);

		label = add_label(hbox, _("Port"));
		sg_label.add_widget(label);

		spin_ssh_port = add_spin(hbox, 1, 65535, 22);
		spin_ssh_port.value_changed.connect(()=>{
			App.backup_ssh_port = (int) spin_ssh_port.get_value();
		});

		// fake-super ----------------------------------------------

		chk_ssh_fake_super = add_checkbox(vbox_ssh,
			_("Remote account is not root"));

		chk_ssh_fake_super.set_tooltip_text(_("Store file ownership in extended attributes (rsync --fake-super). Required when you cannot log in as root on the remote host, otherwise restored files would lose their owner."));

		chk_ssh_fake_super.toggled.connect(()=>{
			App.backup_ssh_fake_super = chk_ssh_fake_super.active;
		});

		// test connection -----------------------------------------

		hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		vbox_ssh.add(hbox);

		label = add_label(hbox, "");
		sg_label.add_widget(label);

		var btn_test = add_button(hbox, _("Test connection"), "", null, null);
		btn_test.clicked.connect(()=>{
			change_backup_ssh();
		});

		var btn_setup = add_button(hbox, _("Set up with password"),
			_("Log in once with a password to install a key, so that scheduled snapshots can run without one"),
			null, null);

		btn_setup.clicked.connect(()=>{
			setup_ssh_key();
		});
	}

	/* Reads the entries into App, rebuilds the repository and reports the
	 * outcome through the existing infobar. */
	private void change_backup_ssh(){

		read_ssh_fields();

		if (App.backup_ssh_url.length == 0){
			show_location_error(_("Enter a remote location"),
				_("Use one of these forms") + ":\n    user@host:/path\n    ssh://user@host:port/path");
			return;
		}

		gtk_set_busy(true, parent_window);

		App.backup_location_type = "ssh";
		App.btrfs_mode = false; // btrfs snapshots need a local filesystem

		App.repo = new SnapshotRepo.from_ssh(
			App.backup_ssh_url, App.backup_ssh_key, App.backup_ssh_port,
			App.backup_ssh_fake_super, parent_window);

		// an explicit test should really re-probe, not reuse the cache
		App.repo.invalidate_capability_cache();

		check_backup_location();

		gtk_set_busy(false, parent_window);
	}

	/* Logs in once with a password to install a key, so later scheduled runs
	 * need no password.
	 *
	 * The password is transient: it is handed straight to the backend, which
	 * passes it to ssh through its askpass mechanism. It is never stored,
	 * never put on a command line, and never logged. */
	private void setup_ssh_key(){

		read_ssh_fields();

		if (App.backup_ssh_url.length == 0){
			show_location_error(_("Enter a remote location"),
				_("Use one of these forms") + ":\n    user@host:/path\n    ssh://user@host:port/path");
			return;
		}

		string user, host, path;
		int parsed_port;

		if (!SshRepoBackend.parse_url(App.backup_ssh_url, out user, out host,
			out parsed_port, out path)){
			show_location_error(_("Invalid remote location"),
				_("Use one of these forms") + ":\n    user@host:/path\n    ssh://user@host:port/path");
			return;
		}

		if (App.backup_ssh_port > 0){ parsed_port = App.backup_ssh_port; }

		var backend = new SshRepoBackend(user, host, parsed_port,
			"", App.backup_ssh_fake_super, App.mount_point_app);

		// 1. let the user confirm the host before the password goes anywhere
		gtk_set_busy(true, parent_window);
		string key_line, fingerprint;
		bool scanned = backend.scan_host_key(out key_line, out fingerprint);
		gtk_set_busy(false, parent_window);

		if (!scanned){
			show_location_error(_("Could not reach the remote host"), backend.last_error);
			return;
		}

		string msg = _("Timeshift will add its public key to the authorized_keys file of this account:");
		msg += "\n\n    %s\n\n".printf(backend.display_name);
		msg += _("Check this fingerprint against the remote host before continuing.");
		msg += "\n\n    %s\n\n".printf(fingerprint);
		msg += _("Your password will be sent to this host.");

		var dlg = new CustomMessageDialog(_("Verify the remote host"), msg,
			Gtk.MessageType.QUESTION, parent_window, Gtk.ButtonsType.YES_NO);

		var resp = dlg.run();
		dlg.destroy();
		gtk_do_events();

		if (resp != Gtk.ResponseType.YES){ return; }

		if (!backend.trust_host_key(key_line)){
			show_location_error(_("Failed to record the host key"), backend.last_error);
			return;
		}

		// 2. password. null means Cancel; the window-manager close returns ""
		string? password = gtk_inputbox(
			_("Password"),
			_("Enter the password for") + " %s".printf(backend.display_name),
			parent_window, true);

		if ((password == null) || (password.length == 0)){ return; }

		// 3. key, install, verify
		string key_path = App.backup_ssh_key;
		if (key_path.length == 0){
			key_path = SshRepoBackend.default_key_file();
		}

		gtk_set_busy(true, parent_window);

		string message = "";
		bool ok = backend.ensure_keypair(key_path, out message);

		if (ok){
			backend.key_file = key_path;
			ok = backend.install_public_key(password, out message);
		}

		// ssh-copy-id exits 0 even on a wrong password, so the verify below is
		// what actually decides success
		if (ok){
			ok = backend.verify_key_auth(out message);
		}

		// only once the new key is proven to work: remove earlier keys this
		// machine installed whose private half is gone
		int removed = 0;
		if (ok){
			string clean_msg;
			backend.remove_stale_keys(out removed, out clean_msg);
		}

		password = null;

		gtk_set_busy(false, parent_window);

		if (!ok){
			show_location_error(_("Could not set up key-based login"), message);
			return;
		}

		// 4. adopt the key and rebuild the repository
		App.backup_ssh_key = key_path;
		txt_ssh_key.text = key_path;

		if (removed > 0){
			log_msg(_("Removed old Timeshift keys from the remote") + ": %d".printf(removed));
		}

		change_backup_ssh();
	}

	/* Entries commit on focus-out, which can be missed if the user types and
	 * immediately clicks. Re-read them whenever the values are actually used. */
	private void read_ssh_fields(){

		App.backup_ssh_url = txt_ssh_url.text.strip();
		App.backup_ssh_key = txt_ssh_key.text.strip();
		App.backup_ssh_port = (int) spin_ssh_port.get_value();
		App.backup_ssh_fake_super = chk_ssh_fake_super.active;
	}

	private void show_location_error(string message, string details){

		lbl_infobar_location.label = "<span weight=\"bold\">%s</span>\n%s".printf(
			escape_html(message), escape_html(details));

		infobar_location.message_type = Gtk.MessageType.ERROR;
		infobar_location.no_show_all = false;
		infobar_location.show_all();
	}

	private string? browse_ssh_key(){

		var dialog = new Gtk.FileChooserDialog(
			_("Select SSH private key"), parent_window,
			Gtk.FileChooserAction.OPEN,
			"gtk-cancel", Gtk.ResponseType.CANCEL,
			"gtk-open", Gtk.ResponseType.ACCEPT);

		dialog.action = FileChooserAction.OPEN;
		dialog.set_transient_for(parent_window);
		dialog.local_only = true;
		dialog.set_modal(true);
		dialog.set_select_multiple(false);

		string? selected = null;

		var resp = dialog.run();
		if (resp != Gtk.ResponseType.CANCEL){
			var list = dialog.get_filenames();
			if (list.length() > 0){
				selected = list.nth_data(0);
			}
		}

		dialog.destroy();

		return selected;
	}

	/* Shows either the device list or the SSH form. Called at the end of
	 * refresh(), which every parent window invokes. */
	private void update_location_widgets(){

		bool is_ssh = (App.backup_location_type == "ssh");

		// The help text has to follow the selected mode. It used to be set
		// only in refresh(), so toggling the radio left the local bullets on
		// screen while the remote form was showing.
		if (is_ssh){
			lbl_common.label = "<i>• %s\n• %s\n• %s</i>".printf(
				_("Snapshots are sent over SSH and saved to /timeshift on the remote host."),
				_("Connect as root, or tick the option above, so that file ownership is preserved."),
				_("Key-based authentication only. Scheduled snapshots need a key without a passphrase.")
			);
		}
		else if (App.btrfs_mode){
			lbl_common.label = "<i>• %s\n• %s\n• %s</i>".printf(
				_("Devices displayed above have BTRFS file systems."),
				_("BTRFS snapshots are saved on system partition. Other partitions are not supported."),
				_("Snapshots are saved to /timeshift-btrfs on selected partition. Other locations are not supported.")
			);
		}
		else {
			lbl_common.label = "<i>• %s\n• %s\n• %s</i>".printf(
				_("Devices displayed above have Linux file systems."),
				_("Devices with Windows file systems are not supported (NTFS, FAT, etc)."),
				_("Snapshots are saved to /timeshift on selected partition. Other locations are not supported.")
			);
		}

		opt_local.active = !is_ssh;
		opt_ssh.active = is_ssh;

		if (sw_devices != null){
			sw_devices.no_show_all = is_ssh;
			sw_devices.visible = !is_ssh;
		}

		btn_refresh.visible = !is_ssh;

		vbox_ssh.no_show_all = !is_ssh;
		vbox_ssh.visible = is_ssh;

		if (is_ssh){
			vbox_ssh.show_all();
		}
	}

	private void init_tv_devices(){
		
		tv_devices = add_treeview(this);
		tv_devices.vexpand = true;

		// add_treeview() creates a ScrolledWindow and discards the reference;
		// keep it so the device list can be hidden in remote mode
		sw_devices = tv_devices.get_parent() as Gtk.ScrolledWindow;
		tv_devices.headers_clickable = true;
		//tv_devices.rules_hint = true;
		tv_devices.activate_on_single_click = true;
		//tv_devices.headers_clickable  = true;
		
		// device name
		
		Gtk.CellRendererPixbuf cell_pix;
		Gtk.CellRendererToggle cell_radio;
		Gtk.CellRendererText cell_text;
		//var col = add_column_radio_and_text(tv_devices, _("Disk"), out cell_radio, out cell_text);
		var col = add_column_icon_radio_text(tv_devices, _("Disk"),
			out cell_pix, out cell_radio, out cell_text);

		col.resizable = true;
		
		col.set_cell_data_func(cell_pix, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);

			((Gtk.CellRendererPixbuf)cell).visible = (dev.type == "disk");
			
		});

        col.add_attribute(cell_pix, "icon-name", 2);

		col.set_cell_data_func(cell_radio, (cell_layout, cell, model, iter)=>{
			Device dev;
			bool selected;
			model.get (iter, 0, out dev, 3, out selected, -1);

			((Gtk.CellRendererToggle)cell).active = selected;

			((Gtk.CellRendererToggle)cell).visible =
				(dev.size_bytes > 10 * KB) && (dev.type != "disk") && (dev.children.size == 0);
		});

		//cell_radio.toggled.connect((path)=>{});

		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);

			/*if (dev.type == "disk"){
				var txt = "%s %s".printf(dev.model, dev.vendor).strip();
				if (txt.length == 0){
					txt = "%s Disk".printf(format_file_size(dev.size_bytes));
				}
				else{
					txt += " (%s Disk)".printf(format_file_size(dev.size_bytes));
				}
				(cell as Gtk.CellRendererText).text = txt.strip();
			}
			else {
				(cell as Gtk.CellRendererText).text = dev.description_full_free();
			}*/

			if (dev.type == "disk"){
				var txt = "%s %s".printf(dev.model, dev.vendor).strip();
				if (txt.length == 0){
					txt = "%s Disk".printf(format_file_size(dev.size_bytes));
				}
				((Gtk.CellRendererText)cell).text = txt.strip();
			}
			else {
				((Gtk.CellRendererText)cell).text = dev.kname;
			}

			//(cell as Gtk.CellRendererText).sensitive = (dev.type != "disk");
		});

		
		// type
		
		col = add_column_text(tv_devices, _("Type"), out cell_text);

		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);
			((Gtk.CellRendererText)cell).text = dev.fstype;

			//(cell as Gtk.CellRendererText).sensitive = (dev.type != "disk");
		});

		// size
		
		col = add_column_text(tv_devices, _("Size"), out cell_text);
		cell_text.xalign = (float) 1.0;
		
		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);

			((Gtk.CellRendererText)cell).text =
					(dev.size_bytes > 0) ? format_file_size(dev.size_bytes, false, "", true, 0) : "";
		});

		// free
		
		col = add_column_text(tv_devices, _("Free"), out cell_text);
		cell_text.xalign = (float) 1.0;
		
		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);

			if (dev.type == "disk"){
				((Gtk.CellRendererText)cell).text = "";
			}
			else{
				((Gtk.CellRendererText)cell).text =
					(dev.free_bytes > 0) ? format_file_size(dev.free_bytes, false, "", true, 0) : "";
			}

			((Gtk.CellRendererText)cell).sensitive = (dev.type != "disk");
		});

		// name
		
		col = add_column_text(tv_devices, _("Name"), out cell_text);
		cell_text.xalign = 0.0f;
		
		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);

			if (dev.type == "disk"){
				((Gtk.CellRendererText)cell).text = "";
			}
			else{
				((Gtk.CellRendererText)cell).text = dev.partlabel;
			}

			((Gtk.CellRendererText)cell).sensitive = (dev.type != "disk");
		});

		// label
		
		col = add_column_text(tv_devices, _("Label"), out cell_text);
		cell_text.xalign = 0.0f;
		
		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);

			if (dev.type == "disk"){
				((Gtk.CellRendererText)cell).text = "";
			}
			else{
				((Gtk.CellRendererText)cell).text = dev.label;
			}

			((Gtk.CellRendererText)cell).sensitive = (dev.type != "disk");
		});
		
		// buffer

		col = add_column_text(tv_devices, "", out cell_text);
		col.expand = true;
		
		/*// label
		
		col = add_column_text(tv_devices, _("Label"), out cell_text);

		col.set_cell_data_func(cell_text, (cell_layout, cell, model, iter)=>{
			Device dev;
			model.get (iter, 0, out dev, -1);
			(cell as Gtk.CellRendererText).text = dev.label;

			(cell as Gtk.CellRendererText).sensitive = (dev.type != "disk");
		});*/

		
		
		// events

		tv_devices.row_activated.connect((path, column) => {
			var store = (Gtk.TreeStore) tv_devices.model;
			var selection = tv_devices.get_selection();

			selection.selected_foreach((model, path, iter) => {
				Device dev;
				store.get (iter, 0, out dev);

				if ((App.repo.device == null) || (App.repo.device.uuid != dev.uuid)){
					try_change_device(dev);
				}
				else{
					return;
				}
			});

			store.foreach((model, path, iter) => {
				Device dev;
				store.get (iter, 0, out dev);
				
				if ((App.repo.device != null) && (App.repo.device.uuid == dev.uuid)){
					store.set (iter, 3, true);
					//tv_devices.get_selection().select_iter(iter);
				}
				else{
					store.set (iter, 3, false);
				}

				return false; // continue
			});
		});
	}

	private void init_infobar_location(){
		
		var infobar = new Gtk.InfoBar();
		infobar.no_show_all = true;
		add(infobar);
		infobar_location = infobar;
		
		var content = (Gtk.Box) infobar.get_content_area();
		var label = add_label(content, "");
		lbl_infobar_location = label;

		// scrolled
		var scrolled = new Gtk.ScrolledWindow(null, null);
		scrolled.set_shadow_type (ShadowType.ETCHED_IN);
		scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scrolled.vscrollbar_policy = Gtk.PolicyType.NEVER;
		scrolled.set_size_request(-1, 100);
		this.add(scrolled);
		
		label = new Gtk.Label("");
		label.set_use_markup(true);
		label.xalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD;
		label.margin = 6;
		scrolled.add(label);
		lbl_common = label;
	}

	private void try_change_device(Device dev){

		log_debug("try_change_device: %s".printf(dev.device));
		
		if (dev.type == "disk"){

			bool found_child = false;

			if ((App.btrfs_mode && (dev.fstype == "btrfs")) || (!App.btrfs_mode && dev.has_linux_filesystem())){
				
				change_backup_device(dev);
				found_child = true;
			}

			if (!found_child){

				// find first valid partition
				
				foreach (var child in dev.children){
					
					if ((App.btrfs_mode && (child.fstype == "btrfs")) || (!App.btrfs_mode && child.has_linux_filesystem())){
						
						change_backup_device(child);
						found_child = true;
						break;
					}
				}
			}
			
			if (!found_child){
				
				string msg = _("Selected device does not have Linux partition");
				
				if (App.btrfs_mode){
					msg = _("Selected device does not have BTRFS partition");
				}
				
				lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(msg);
				infobar_location.message_type = Gtk.MessageType.ERROR;
				infobar_location.no_show_all = false;
				infobar_location.show_all();
			}
		}
		else if (dev.has_children()){
			
			// select the child instead of parent
			change_backup_device(dev.children[0]);
		}
		else if (!dev.has_children()){
			
			// select the device
			change_backup_device(dev);
		}
		else {
			
			// ask user to select
			lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(_("Select a partition on this disk"));
			infobar_location.message_type = Gtk.MessageType.ERROR;
			infobar_location.no_show_all = false;
			infobar_location.show_all();
		}
	}

	private void change_backup_device(Device pi){
		
		// return if device has not changed
		if ((App.repo.device != null) && (pi.uuid == App.repo.device.uuid)){ return; }

		gtk_set_busy(true, parent_window);

		log_debug("\n");
		log_msg("selected device: %s".printf(pi.device));
		log_debug("fstype: %s".printf(pi.fstype));

		App.repo = new SnapshotRepo.from_device(pi, parent_window, App.btrfs_mode);

		if (pi.fstype == "luks"){
			
			App.update_partitions();

			var dev = Device.find_device_in_list(App.partitions, pi.uuid);
			
			if (dev.has_children()){
				
				log_debug("has children");
				
				if (dev.children[0].has_linux_filesystem()){
					
					log_debug("has linux filesystem: %s".printf(dev.children[0].fstype));
					log_msg("selecting child device: %s".printf(dev.children[0].device));
						
					App.repo = new SnapshotRepo.from_device(dev.children[0], parent_window, App.btrfs_mode);
					tv_devices_refresh();
				}
				else{
					log_debug("does not have linux filesystem");
				}
			}
		}

		check_backup_location();

		gtk_set_busy(false, parent_window);
	}

	private bool check_backup_location(){
		
		bool ok = true;

		App.repo.check_status();
		string message = App.repo.status_message;
		string details = App.repo.status_details;
		int status_code = App.repo.status_code;
		
		// TODO: call check on repo directly
		
		message = escape_html(message);
		details = escape_html(details);
		
		if (App.live_system()){
			
			switch (status_code){
			case SnapshotLocationStatus.NOT_SELECTED:
				lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(details);
				infobar_location.message_type = Gtk.MessageType.ERROR;
				infobar_location.no_show_all = false;
				infobar_location.show_all();
				ok = false;
				break;
				
			case SnapshotLocationStatus.NOT_AVAILABLE:
				lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(message);
				infobar_location.message_type = Gtk.MessageType.ERROR;
				infobar_location.no_show_all = false;
				infobar_location.show_all();
				ok = false;
				break;

			case SnapshotLocationStatus.READ_ONLY_FS:
			case SnapshotLocationStatus.HARDLINKS_NOT_SUPPORTED:
				lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(message);
				infobar_location.message_type = Gtk.MessageType.ERROR;
				infobar_location.no_show_all = false;
				infobar_location.show_all();
				ok = false;
				break;

			case SnapshotLocationStatus.NO_BTRFS_SYSTEM:
				lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(details);
				infobar_location.message_type = Gtk.MessageType.ERROR;
				infobar_location.no_show_all = false;
				infobar_location.show_all();
				ok = false;
				break;

			case SnapshotLocationStatus.NO_SNAPSHOTS_HAS_SPACE:
			case SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE:
				lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(
					_("There are no snapshots on this device"));
				infobar_location.message_type = Gtk.MessageType.ERROR;
				infobar_location.no_show_all = false;
				infobar_location.show_all();
				//ok = false;
				break;

			case SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE:
			case SnapshotLocationStatus.HAS_SNAPSHOTS_HAS_SPACE:
				infobar_location.hide();
				break;
			}
		}
		else{
			switch (status_code){
				case SnapshotLocationStatus.NOT_SELECTED:
					lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(details);
					infobar_location.message_type = Gtk.MessageType.ERROR;
					infobar_location.no_show_all = false;
					infobar_location.show_all();
					ok = false;
					break;
					
				case SnapshotLocationStatus.NOT_AVAILABLE:
				case SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE:
				case SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE:
					lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(
						message.replace("<","&lt;"));
					infobar_location.message_type = Gtk.MessageType.ERROR;
					infobar_location.no_show_all = false;
					infobar_location.show_all();
					ok = false;
					break;

				case SnapshotLocationStatus.READ_ONLY_FS:
				case SnapshotLocationStatus.HARDLINKS_NOT_SUPPORTED:
					lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(message);
					infobar_location.message_type = Gtk.MessageType.ERROR;
					infobar_location.no_show_all = false;
					infobar_location.show_all();
					ok = false;
					break;

				case SnapshotLocationStatus.NO_BTRFS_SYSTEM:
					lbl_infobar_location.label = "<span weight=\"bold\">%s</span>".printf(details);
					infobar_location.message_type = Gtk.MessageType.ERROR;
					infobar_location.no_show_all = false;
					infobar_location.show_all();
					ok = false;
					break;

				case 3:
				case 0:
					infobar_location.hide();
					// TODO: Show a disk icon with stats when selected device is OK
					break;
			}

		}
		
		return ok;
	}

	private void tv_devices_refresh(){
		
		App.update_partitions();

		var model = new Gtk.TreeStore(4,
			typeof(Device),
			typeof(string),
			typeof(string),
			typeof(bool));
		
		tv_devices.set_model (model);

		TreeIter iter0;

		foreach(var disk in App.partitions) {
			
			if (disk.type != "disk") { continue; }

			model.append(out iter0, null);
			model.set(iter0, 0, disk, -1);
			model.set(iter0, 1, disk.tooltip_text(), -1);
			model.set(iter0, 2, IconManager.ICON_HARDDRIVE, -1);
			model.set(iter0, 3, false, -1);

			tv_append_child_volumes(ref model, ref iter0, disk);
		}

		tv_devices.expand_all();
		tv_devices.columns_autosize();
	}

	private void tv_append_child_volumes(
		ref Gtk.TreeStore model, ref Gtk.TreeIter iter0, Device parent){

		foreach(var part in App.partitions) {

			if (!part.has_linux_filesystem()){ continue; }

			if (App.btrfs_mode){
				if (part.is_encrypted_partition() && (!part.has_children() || (part.children[0].fstype == "btrfs"))){
					//ok
				}
				else if (part.is_lvm_partition() && (!part.has_children() || (part.children[0].fstype == "btrfs"))){
					//ok
				}
				else if (part.fstype == "btrfs"){
					//ok
				}
				else{
					continue;
				}
			}
			
			if (part.pkname == parent.kname) {
				
				TreeIter iter1;
				model.append(out iter1, iter0);
				model.set(iter1, 0, part, -1);
				model.set(iter1, 1, part.tooltip_text(), -1);
				model.set(iter1, 2, (part.fstype == "luks") ? "locked" : IconManager.ICON_HARDDRIVE, -1);
				
				if (parent.fstype == "luks"){
					// change parent's icon to unlocked
					model.set(iter0, 2, "unlocked", -1);
				}

				if ((App.repo.device != null) && (part.uuid == App.repo.device.uuid)){
					model.set(iter1, 3, true, -1);
				}
				else{
					model.set(iter1, 3, false, -1);
				}

				tv_append_child_volumes(ref model, ref iter1, part);
			}
			else if ((part.kname == parent.kname) && (part.type == "disk")
				&& part.has_linux_filesystem() && !part.has_children()){
				
				// partition-less disk with linux filesystem

				// create a dummy partition
				var part2 = new Device();
				part2.copy_fields_from(part);
				part2.type = "part";
				part2.pkname = part.device.replace("/dev/","");
				part2.parent = part;

				TreeIter iter1;
				model.append(out iter1, iter0);
				model.set(iter1, 0, part2, -1);
				model.set(iter1, 1, part2.tooltip_text(), -1);
				model.set(iter1, 2, (part2.fstype == "luks") ? "locked" : IconManager.ICON_HARDDRIVE, -1);
				
				if ((App.repo.device != null) && (part2.uuid == App.repo.device.uuid)){
					model.set(iter1, 3, true, -1);
				}
				else{
					model.set(iter1, 3, false, -1);
				}
			}
		}
	}
}
