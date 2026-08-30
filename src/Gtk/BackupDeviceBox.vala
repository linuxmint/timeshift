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

/* Row object for the device tree. GTK4 builds hierarchies from a
 * Gtk.TreeListModel over per-row child models rather than from a TreeStore. */
public enum DeviceField {
	TYPE,
	SIZE,
	FREE,
	NAME,
	LABEL
}

public class DeviceRow : GLib.Object {

	public Device dev { get; set; }
	public string icon { get; set; }
	public bool selected { get; set; }
	public GLib.ListStore children { get; set; }

	public DeviceRow(Device _dev, string _icon){
		dev = _dev;
		icon = _icon;
		selected = false;
		children = new GLib.ListStore(typeof(DeviceRow));
	}
}

class BackupDeviceBox : Gtk.Box{

	private Gtk.ColumnView tv_devices;
	private GLib.ListStore device_root;
	private Gtk.TreeListModel device_tree;
	private Gtk.SingleSelection device_selection;
	private Gtk.ScrolledWindow sw_devices;
	private Gtk.Button btn_refresh;
	private Banner infobar_location;
	private Gtk.Box card_common;
	private Gtk.Box bullets_common;

	// remote (SSH) location
	private Gtk.CheckButton opt_local;
	private Gtk.CheckButton opt_ssh;
	private Gtk.Box vbox_ssh;
	private Gtk.Entry txt_ssh_url;
	private Gtk.Entry txt_ssh_key;
	private Gtk.SpinButton spin_ssh_port;
	private Gtk.CheckButton chk_ssh_fake_super;
	
	private Gtk.Window parent_window;

	public BackupDeviceBox (Gtk.Window _parent_window) {

		log_debug("BackupDeviceBox: BackupDeviceBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		append(hbox);

		var title = Ui.add_title(hbox, _("Select Snapshot Location"));
		title.hexpand = true;
		title.margin_bottom = 0;

		// refresh device button
		btn_refresh = Ui.add_icon_only_button(hbox, "view-refresh-symbolic", _("Refresh"));
		btn_refresh.add_css_class("flat");
		btn_refresh.valign = Gtk.Align.START;
        btn_refresh.clicked.connect(()=>{
			App.update_partitions();
			tv_devices_refresh();
		});

		Ui.add_dim_label(this, _("Where snapshots are stored. Choose a disk other than the system disk to survive a drive failure."));

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

		// must run last: it depends on the widgets built above
		update_location_widgets();
	}

	/* Local device vs remote (SSH) selector. Both parents of this box
	 * (SettingsWindow and SetupWizardWindow) embed it, so putting the choice
	 * here makes remote locations available in the wizard too. */
	private void init_location_type(){

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.SM);
		append(hbox);

		opt_local = Ui.add_radio(hbox, _("Local device"), null);
		opt_local.set_tooltip_text(_("Save snapshots to a disk attached to this computer"));

		opt_ssh = Ui.add_radio(hbox, _("Remote (SSH)"), opt_local);
		opt_ssh.set_tooltip_text(_("Save snapshots to another computer over SSH"));

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

		vbox_ssh = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.SM);
		vbox_ssh.visible = false; // local mode until refresh() says otherwise
		append(vbox_ssh);

		var card = Ui.add_card(vbox_ssh);

		var grid = new Gtk.Grid();
		grid.column_spacing = Ui.Spacing.SM;
		grid.row_spacing = Ui.Spacing.XS;
		card.append(grid);

		int row = 0;

		// location ------------------------------------------------

		grid.attach(form_label(_("Location")), 0, row, 1, 1);

		txt_ssh_url = new Gtk.Entry();
		txt_ssh_url.hexpand = true;
		txt_ssh_url.placeholder_text = "user@host:/path";
		txt_ssh_url.set_tooltip_text(_("Example") + ": user@nas:/backups");
		grid.attach(txt_ssh_url, 1, row, 2, 1);
		row++;

		var focus_txt_ssh_url = new Gtk.EventControllerFocus();
		focus_txt_ssh_url.leave.connect(() => {
			App.backup_ssh_url = txt_ssh_url.text.strip();
		});
		txt_ssh_url.add_controller(focus_txt_ssh_url);

		// ssh key -------------------------------------------------

		grid.attach(form_label(_("SSH key")), 0, row, 1, 1);

		txt_ssh_key = new Gtk.Entry();
		txt_ssh_key.hexpand = true;
		txt_ssh_key.placeholder_text = "/etc/timeshift/ssh/id_ed25519";
		txt_ssh_key.set_tooltip_text(_("Private key used to connect. Use 'Set up with password' if you do not have one yet."));
		grid.attach(txt_ssh_key, 1, row, 1, 1);

		var focus_txt_ssh_key = new Gtk.EventControllerFocus();
		focus_txt_ssh_key.leave.connect(() => {
			App.backup_ssh_key = txt_ssh_key.text.strip();
		});
		txt_ssh_key.add_controller(focus_txt_ssh_key);

		var btn_browse = Ui.add_icon_only_button(new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0), "folder-open-symbolic", _("Browse"));
		btn_browse.unparent();
		grid.attach(btn_browse, 2, row, 1, 1);
		row++;

		btn_browse.clicked.connect(()=>{
			string? path = browse_ssh_key();
			if (path != null){
				txt_ssh_key.text = path;
				App.backup_ssh_key = path;
			}
		});

		// port ----------------------------------------------------

		grid.attach(form_label(_("Port")), 0, row, 1, 1);

		var port_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		spin_ssh_port = add_spin(port_box, 1, 65535, 22);
		spin_ssh_port.halign = Gtk.Align.START;
		grid.attach(port_box, 1, row, 2, 1);
		row++;

		spin_ssh_port.value_changed.connect(()=>{
			App.backup_ssh_port = (int) spin_ssh_port.get_value();
		});

		// fake-super ----------------------------------------------

		var chk_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		chk_ssh_fake_super = add_checkbox(chk_box, _("Remote account is not root"));
		grid.attach(chk_box, 1, row, 2, 1);
		row++;

		chk_ssh_fake_super.set_tooltip_text(_("Store file ownership in extended attributes (rsync --fake-super). Required when you cannot log in as root on the remote host, otherwise restored files would lose their owner."));

		chk_ssh_fake_super.toggled.connect(()=>{
			App.backup_ssh_fake_super = chk_ssh_fake_super.active;
		});

		// test connection -----------------------------------------

		var actions = Ui.add_button_row(vbox_ssh, Gtk.Align.START);

		var btn_test = add_button(actions, _("Test connection"), "", null, null);
		btn_test.clicked.connect(()=>{
			change_backup_ssh();
		});

		var btn_setup = add_button(actions, _("Set up with password"),
			_("Log in once with a password to install a key, so that scheduled snapshots can run without one"),
			null, null);

		btn_setup.clicked.connect(()=>{
			setup_ssh_key();
		});
	}

	private Gtk.Label form_label(string text){

		var label = new Gtk.Label(text);
		label.xalign = (float) 1.0;
		label.add_css_class("ts-dim");
		return label;
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

		infobar_location.set_message("%s\n%s".printf(message, details), Gtk.MessageType.ERROR);
	}

	private string? browse_ssh_key(){

		/* GTK4 replaces Gtk.FileChooserDialog with the async Gtk.FileDialog.
		 * Callers here are synchronous, so block on a nested main loop. */

		var dialog = new Gtk.FileDialog();
		dialog.set_title(_("Select SSH private key"));
		dialog.set_modal(true);

		string? selected = null;
		var loop = new GLib.MainLoop();

		dialog.open.begin(parent_window, null, (obj, res) => {
			try {
				var file = dialog.open.end(res);
				if (file != null){ selected = file.get_path(); }
			}
			catch (Error e){
				// the user cancelled, or the portal refused
				log_debug(e.message);
			}
			loop.quit();
		});

		loop.run();

		return selected;
	}

	/* Shows either the device list or the SSH form. Called at the end of
	 * refresh(), which every parent window invokes. */
	private void update_location_widgets(){

		bool is_ssh = (App.backup_location_type == "ssh");

		// The help text has to follow the selected mode. It used to be set
		// only in refresh(), so toggling the radio left the local bullets on
		// screen while the remote form was showing.
		card_common.remove(bullets_common);

		if (is_ssh){
			bullets_common = Ui.add_bullets(card_common, {
				_("Snapshots are sent over SSH and saved to /timeshift on the remote host."),
				_("Connect as root, or tick the option above, so that file ownership is preserved."),
				_("Key-based authentication only. Scheduled snapshots need a key without a passphrase.")
			}, "ts-dim");
		}
		else if (App.btrfs_mode){
			bullets_common = Ui.add_bullets(card_common, {
				_("Devices displayed above have BTRFS file systems."),
				_("BTRFS snapshots are saved on system partition. Other partitions are not supported."),
				_("Snapshots are saved to /timeshift-btrfs on selected partition. Other locations are not supported.")
			}, "ts-dim");
		}
		else {
			bullets_common = Ui.add_bullets(card_common, {
				_("Devices displayed above have Linux file systems."),
				_("Devices with Windows file systems are not supported (NTFS, FAT, etc)."),
				_("Snapshots are saved to /timeshift on selected partition. Other locations are not supported.")
			}, "ts-dim");
		}

		opt_local.active = !is_ssh;
		opt_ssh.active = is_ssh;

		if (sw_devices != null){
			sw_devices.visible = !is_ssh;
		}

		btn_refresh.visible = !is_ssh;
		vbox_ssh.visible = is_ssh;
		card_common.visible = true;
	}

	private void init_tv_devices(){

		/* GTK4 deprecates Gtk.TreeView/Gtk.TreeStore. The disk -> partition
		 * hierarchy is now a Gtk.TreeListModel of DeviceRow, rendered by a
		 * Gtk.ColumnView with a Gtk.TreeExpander in the first column. */

		device_root = new GLib.ListStore(typeof(DeviceRow));

		/* The -Wincompatible-pointer-types warning gcc emits here is a Vala
		 * binding artifact: gtk4.vapi types the create-func's first parameter
		 * as GLib.Object, while GTK's C typedef uses gpointer. Same ABI. */
		device_tree = new Gtk.TreeListModel(device_root, false, true, (item) => {
			var row = (DeviceRow) item;
			return (row.children.get_n_items() > 0) ? row.children : null;
		});

		device_selection = new Gtk.SingleSelection(device_tree);
		device_selection.autoselect = false;
		device_selection.can_unselect = true;

		tv_devices = new Gtk.ColumnView(device_selection);
		tv_devices.vexpand = true;

		sw_devices = Ui.add_boxed_list(this, tv_devices);

		tv_devices.append_column(make_disk_column());
		tv_devices.append_column(make_device_text_column(_("Type"), DeviceField.TYPE));
		tv_devices.append_column(make_device_text_column(_("Size"), DeviceField.SIZE));
		tv_devices.append_column(make_device_text_column(_("Free"), DeviceField.FREE));
		tv_devices.append_column(make_device_text_column(_("Name"), DeviceField.NAME));
		tv_devices.append_column(make_device_text_column(_("Label"), DeviceField.LABEL));
	}

	private DeviceRow? row_at(uint position){

		var list_row = device_tree.get_row(position);
		return (list_row == null) ? null : (DeviceRow) list_row.get_item();
	}

	private void device_selected(DeviceRow row){

		var dev = row.dev;

		if ((App.repo.device == null) || (App.repo.device.uuid != dev.uuid)){
			try_change_device(dev);
		}

		// refresh the radio state across the whole tree
		update_device_selection_flags();
	}

	private void update_device_selection_flags(){

		for (uint i = 0; i < device_tree.get_n_items(); i++){
			var row = row_at(i);
			if (row == null){ continue; }
			row.selected = (App.repo.device != null) && (App.repo.device.uuid == row.dev.uuid);
		}
	}

	private Gtk.ColumnViewColumn make_disk_column(){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var expander = new Gtk.TreeExpander();

			var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);

			var img = new Gtk.Image();
			img.pixel_size = 16;
			hbox.append(img);

			var chk = new Gtk.CheckButton();
			chk.set_group(null);
			hbox.append(chk);

			var lbl = new Gtk.Label("");
			lbl.xalign = (float) 0.0;
			hbox.append(lbl);

			chk.toggled.connect(() => {
				if (!chk.active){ return; }

				var row = chk.get_data<DeviceRow>("row");
				if (row == null){ return; }

				device_selected(row);
			});

			expander.set_child(hbox);
			list_item.set_child(expander);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var expander = (Gtk.TreeExpander) list_item.get_child();
			var list_row = (Gtk.TreeListRow) list_item.get_item();
			var row = (DeviceRow) list_row.get_item();
			var dev = row.dev;

			expander.set_list_row(list_row);

			var hbox = (Gtk.Box) expander.get_child();
			var img = (Gtk.Image) hbox.get_first_child();
			var chk = (Gtk.CheckButton) img.get_next_sibling();
			var lbl = (Gtk.Label) chk.get_next_sibling();

			img.visible = (dev.type == "disk");
			IconManager.set_image_icon(img, row.icon, 16);

			chk.visible = (dev.size_bytes > 10 * KB) && (dev.type != "disk")
				&& (dev.children.size == 0);

			chk.steal_data<DeviceRow>("row");
			chk.active = row.selected;
			chk.set_data<DeviceRow>("row", row);

			if (dev.type == "disk"){
				var txt = "%s %s".printf(dev.model, dev.vendor).strip();
				if (txt.length == 0){
					txt = "%s Disk".printf(format_file_size(dev.size_bytes));
				}
				lbl.label = txt.strip();
			}
			else {
				lbl.label = dev.kname;
			}

			hbox.set_tooltip_markup(dev.tooltip_text());
		});

		var col = new Gtk.ColumnViewColumn(_("Disk"), factory);
		col.resizable = true;
		col.fixed_width = 220;
		return col;
	}

	private Gtk.ColumnViewColumn make_device_text_column(string title, DeviceField field){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = new Gtk.Label("");
			lbl.xalign = ((field == DeviceField.SIZE) || (field == DeviceField.FREE))
				? (float) 1.0 : (float) 0.0;
			list_item.set_child(lbl);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = (Gtk.Label) list_item.get_child();
			var list_row = (Gtk.TreeListRow) list_item.get_item();
			var dev = ((DeviceRow) list_row.get_item()).dev;

			bool is_disk = (dev.type == "disk");

			/* Build the text in an explicit local. A nested ternary mixing a
			 * string literal with a function returning an owned string makes
			 * Vala free the temporary before the label reads it, which rendered
			 * the Free column as garbage bytes. */
			string txt = "";

			switch (field){
			case DeviceField.TYPE:
				txt = dev.fstype;
				break;
			case DeviceField.SIZE:
				if (dev.size_bytes > 0){
					txt = format_file_size(dev.size_bytes, false, "", true, 0);
				}
				break;
			case DeviceField.FREE:
				if (!is_disk && (dev.free_bytes > 0)){
					txt = format_file_size(dev.free_bytes, false, "", true, 0);
				}
				lbl.sensitive = !is_disk;
				break;
			case DeviceField.NAME:
				if (!is_disk){ txt = dev.partlabel; }
				lbl.sensitive = !is_disk;
				break;
			case DeviceField.LABEL:
				if (!is_disk){ txt = dev.label; }
				lbl.sensitive = !is_disk;
				break;
			}

			lbl.label = txt;
		});

		var col = new Gtk.ColumnViewColumn(title, factory);
		col.resizable = true;
		return col;
	}

	private void init_infobar_location(){
		
		infobar_location = new Banner();
		append(infobar_location);

		card_common = Ui.add_card(this);
		card_common.visible = false; // empty until update_location_widgets()

		bullets_common = Ui.add_bullets(card_common, {}, "ts-dim");
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
				
				infobar_location.set_message(msg, Gtk.MessageType.WARNING);
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
			infobar_location.set_message(_("Select a partition on this disk"), Gtk.MessageType.INFO);
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
		
		message = message;
		details = details;
		
		if (App.live_system()){
			
			switch (status_code){
			case SnapshotLocationStatus.NOT_SELECTED:
				infobar_location.set_message(details, Gtk.MessageType.INFO);
				ok = false;
				break;
				
			case SnapshotLocationStatus.NOT_AVAILABLE:
				infobar_location.set_message(message, Gtk.MessageType.ERROR);
				ok = false;
				break;

			case SnapshotLocationStatus.READ_ONLY_FS:
			case SnapshotLocationStatus.HARDLINKS_NOT_SUPPORTED:
				infobar_location.set_message(message, Gtk.MessageType.ERROR);
				ok = false;
				break;

			case SnapshotLocationStatus.NO_BTRFS_SYSTEM:
				infobar_location.set_message(details, Gtk.MessageType.ERROR);
				ok = false;
				break;

			case SnapshotLocationStatus.NO_SNAPSHOTS_HAS_SPACE:
			case SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE:
				infobar_location.set_message(_("There are no snapshots on this device"), Gtk.MessageType.INFO);
				//ok = false;
				break;

			case SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE:
			case SnapshotLocationStatus.HAS_SNAPSHOTS_HAS_SPACE:
				infobar_location.visible = false;
				break;
			}
		}
		else{
			switch (status_code){
				case SnapshotLocationStatus.NOT_SELECTED:
					infobar_location.set_message(details, Gtk.MessageType.INFO);
					ok = false;
					break;
					
				case SnapshotLocationStatus.NOT_AVAILABLE:
					infobar_location.set_message(message, Gtk.MessageType.ERROR);
					ok = false;
					break;

				case SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE:
				case SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE:
					infobar_location.set_message(message, Gtk.MessageType.WARNING);
					ok = false;
					break;

				case SnapshotLocationStatus.READ_ONLY_FS:
				case SnapshotLocationStatus.HARDLINKS_NOT_SUPPORTED:
					infobar_location.set_message(message, Gtk.MessageType.ERROR);
					ok = false;
					break;

				case SnapshotLocationStatus.NO_BTRFS_SYSTEM:
					infobar_location.set_message(details, Gtk.MessageType.ERROR);
					ok = false;
					break;

				case 3:
				case 0:
					infobar_location.visible = false;
					// TODO: Show a disk icon with stats when selected device is OK
					break;
			}

		}
		
		return ok;
	}

	private void tv_devices_refresh(){

		App.update_partitions();

		device_root.remove_all();

		foreach(var disk in App.partitions) {

			if (disk.type != "disk") { continue; }

			var row0 = new DeviceRow(disk, IconManager.ICON_HARDDRIVE);

			/* Children must exist BEFORE the row joins the model: with
			 * autoexpand set, Gtk.TreeListModel asks the create-func for
			 * children at insertion time, and a row that answers "none" is
			 * marked non-expandable for good. */
			tv_append_child_volumes(row0, disk);

			device_root.append(row0);
		}

		update_device_selection_flags();
	}

	private void tv_append_child_volumes(DeviceRow row0, Device parent){

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

				var row1 = new DeviceRow(part,
					(part.fstype == "luks") ? "changes-prevent-symbolic" : IconManager.ICON_HARDDRIVE);
				row0.children.append(row1);

				if (parent.fstype == "luks"){
					// change parent's icon to unlocked
					row0.icon = "changes-allow-symbolic";
				}

				tv_append_child_volumes(row1, part);
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

				var row1 = new DeviceRow(part2,
					(part2.fstype == "luks") ? "changes-prevent-symbolic" : IconManager.ICON_HARDDRIVE);
				row0.children.append(row1);
			}
		}
	}
}
