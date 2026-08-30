/*
 * RestoreDeviceBox.vala
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

/* Row object for the per-mount device drop-down. A GLib.ListStore cannot hold
 * nulls, and the "Keep on Root Device" row has no Device, so the pair is
 * wrapped. */
public class RestoreDeviceOption : GLib.Object {

	public Device? dev { get; set; }
	public MountEntry entry { get; set; }

	public RestoreDeviceOption(Device? _dev, MountEntry _entry){
		dev = _dev;
		entry = _entry;
	}
}

class RestoreDeviceBox : Gtk.Box{

	private Gtk.Grid option_grid;
	private Gtk.Label lbl_header_subvol;
	private bool show_volume_name = false;
	private int option_rows = 0;
	private weak Gtk.Window parent_window; // back-reference: the window owns this box

	public RestoreDeviceBox (Gtk.Window _parent_window) {

		log_debug("RestoreDeviceBox: RestoreDeviceBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		append(hbox);

		var title = Ui.add_title(hbox, _("Select Target Device"));
		title.hexpand = true;
		title.margin_bottom = 0;

		// refresh device button
		var btn_refresh = Ui.add_icon_only_button(hbox, "view-refresh-symbolic", _("Refresh"));
		btn_refresh.add_css_class("flat");
		btn_refresh.valign = Gtk.Align.START;
        btn_refresh.clicked.connect(()=>{
			App.update_partitions();
			refresh();
		});

		if (App.mirror_system){
			Ui.add_dim_label(this,
				_("Select the target devices where system will be cloned."));
		}
		else{
			Ui.add_dim_label(this,
				_("Select the devices where files will be restored.") + "\n" +
				_("Devices from which snapshot was created are pre-selected."));
		}

		// mount table: caption header row, then one row per mount point

		var card = Ui.add_card(this);

		option_grid = new Gtk.Grid();
		option_grid.column_spacing = Ui.Spacing.MD;
		option_grid.row_spacing = Ui.Spacing.XS;
		option_grid.hexpand = true;
		card.append(option_grid);

		// bootloader
		
		add_boot_options();


		log_debug("RestoreDeviceBox: RestoreDeviceBox(): exit");
    }

    public void refresh(bool reset_device_selections = true){
		
		log_debug("RestoreDeviceBox: refresh()");
		App.update_partitions();
		create_device_selection_options(reset_device_selections);
		App.init_boot_options();
		log_debug("RestoreDeviceBox: refresh(): exit");
	}

	private void create_device_selection_options(bool reset_device_selections){
		
		if (reset_device_selections){
			App.init_mount_list();
		}

		show_volume_name = false;
		foreach(var entry in App.mount_list){
			if ((entry.device != null) && ((entry.subvolume_name().length > 0) || (entry.lvm_name().length > 0))){
				// subvolumes are used - show the mount options column
				show_volume_name = true;
				break;
			}
		}

		/* GTK4 has no Container.get_children(); walk the sibling chain. */
		var child = option_grid.get_first_child();
		while (child != null){
			var next = child.get_next_sibling();
			option_grid.remove(child);
			child = next;
		}
		option_rows = 0;

		// header row
		var caption = new Gtk.Label(_("Path"));
		caption.xalign = (float) 0.0;
		caption.add_css_class("ts-caption");
		option_grid.attach(caption, 0, 0, 1, 1);

		caption = new Gtk.Label(_("Device"));
		caption.xalign = (float) 0.0;
		caption.add_css_class("ts-caption");
		option_grid.attach(caption, 1, 0, 1, 1);

		lbl_header_subvol = new Gtk.Label(_("Subvolume"));
		lbl_header_subvol.xalign = (float) 0.0;
		lbl_header_subvol.add_css_class("ts-caption");
		lbl_header_subvol.visible = show_volume_name;
		option_grid.attach(lbl_header_subvol, 2, 0, 1, 1);
		option_rows = 1;

		foreach(MountEntry entry in App.mount_list){
			add_device_selection_option(entry);
		}

		this.visible = true;
	}

	private void add_device_selection_option(MountEntry entry){

		int row = option_rows++;

		var label = new Gtk.Label(entry.mount_point);
		label.xalign = (float) 0.0;
		label.add_css_class("ts-heading");
		label.valign = Gtk.Align.CENTER;
		option_grid.attach(label, 0, row, 1, 1);
		
		var combo = add_device_combo(entry);
		combo.hexpand = true;
		option_grid.attach(combo, 1, row, 1, 1);

		if (show_volume_name){
			string txt = "";
			if (entry.subvolume_name().length > 0){
				txt = "%s".printf(entry.subvolume_name());
			}
			else {
				txt = "%s".printf(entry.lvm_name());
			}
			label = new Gtk.Label(txt);
			label.xalign = (float) 0.0;
			label.add_css_class("ts-body");
			label.valign = Gtk.Align.CENTER;
			option_grid.attach(label, 2, row, 1, 1);
		}
	}

	private Gtk.DropDown add_device_combo(MountEntry entry){

		/* GTK4 deprecates Gtk.ComboBox; a Gtk.DropDown with a factory replaces
		 * the cell renderers and their data functions. */

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);

			var img = new Gtk.Image();
			IconManager.set_image_icon(img, IconManager.ICON_HARDDRIVE, 16);
			hbox.append(img);

			var lbl = new Gtk.Label("");
			lbl.xalign = (float) 0.0;
			hbox.append(lbl);

			list_item.set_child(hbox);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var hbox = (Gtk.Box) list_item.get_child();
			var img = (Gtk.Image) hbox.get_first_child();
			var lbl = (Gtk.Label) img.get_next_sibling();
			var option = (RestoreDeviceOption) list_item.get_item();
			var dev = option.dev;

			if (dev != null){
				img.visible = (dev.type == "disk");
				lbl.label = dev.description_simple();
				lbl.sensitive = (dev.type != "disk");
			}
			else{
				img.visible = false;
				lbl.label = (option.entry.mount_point == "/")
					? _("Select a device") : _("Keep on Root Device");
				lbl.sensitive = true;
			}
		});

		var combo = new Gtk.DropDown(null, null);
		combo.factory = factory;

		combo.has_tooltip = true;
		combo.query_tooltip.connect((x, y, keyboard_tooltip, tooltip) => {

			var option = combo.get_selected_item() as RestoreDeviceOption;
			if (option == null) { return true; }

			tooltip.set_icon_from_icon_name(IconManager.ICON_HARDDRIVE);

			if (option.dev != null){
				tooltip.set_markup(option.dev.tooltip_text());
			}
			else{
				tooltip.set_text(_("Keep this mount path on the root filesystem"));
			}

			return true;
		});

		// populate combo
		var model = new GLib.ListStore(typeof(RestoreDeviceOption));
		combo.model = model;

		uint active = Gtk.INVALID_LIST_POSITION;
		int index = -1;

		/* Index 0 is always the "no device" row. For "/" it reads as a prompt
		 * rather than an option: Gtk.DropDown autoselects row 0 and cannot be
		 * left unselected, so without it the combo would display a real device
		 * while entry.device stayed null. */
		index++;
		model.append(new RestoreDeviceOption(null, entry));
		
		foreach(var dev in App.partitions){
			// skip disk and loop devices
			//if ((dev.type == "disk")||(dev.type == "loop")){
			//	continue;
			//}

			if ((dev.type == "loop") || (dev.fstype == "iso9660")){
				continue;
			}

			if (dev.type != "disk"){

				// display only linux filesystem for / and /home
				if ((entry.mount_point == "/") || (entry.mount_point == "/home")){
					if (!dev.has_linux_filesystem()){
						continue;
					}
				}

				if (dev.has_children()){
					continue; // skip parent partitions of unlocked volumes (luks)
				}
			}
			
			index++;
			model.append(new RestoreDeviceOption(dev, entry));

			if (entry.device != null){
				if (dev.uuid == entry.device.uuid){
					active = (uint) index;
				}
				else if (dev.has_parent() && (dev.parent.uuid == entry.device.uuid)){
					active = (uint) index;
				}
				else if (dev.has_children() && (dev.children[0].uuid == entry.device.uuid)){
					// this will not occur since we are skipping parent devices in this loop
					active = (uint) index;
				}
			}
		}

		if ((active == Gtk.INVALID_LIST_POSITION) && (entry.mount_point != "/")){
			active = 0; // keep on root device
		}

		combo.selected = active;

		combo.notify["selected"].connect(() => {

			var option = combo.get_selected_item() as RestoreDeviceOption;
			if (option == null){
				log_debug("device combo: nothing selected");
				return;
			}

			var current_dev = option.dev;
			var current_entry = option.entry;

			var store = (GLib.ListStore) combo.model;

			if ((current_dev != null) && current_dev.is_encrypted_partition()){

				log_debug("add_device_combo().changed: unlocking encrypted device..");
				
				string msg_out, msg_err;
				var luks_unlocked = Device.luks_unlock(
					current_dev, "", "", parent_window, out msg_out, out msg_err);

				if (luks_unlocked == null){

					log_debug("add_device_combo().changed: failed to unlock");
					
					// reset the selection
					
					if (current_entry.mount_point == "/"){

						// reset to default device
						
						for (uint i = 0; i < store.get_n_items(); i++) {

							var opt_iter = (RestoreDeviceOption) store.get_item(i);
							var dev_iter = opt_iter.dev;

							if ((dev_iter != null) && (dev_iter.device == current_entry.device.device)){
								combo.selected = i;
							}
						}
					}
					else{
						combo.selected = 0; // keep on root device
					}
					
					return;
				}
				else{

					log_debug("add_device_combo().changed: unlocked");
					
					// update current entry
					
					if (current_entry.mount_point == "/"){
						App.dst_root = luks_unlocked;
						App.init_boot_options();
					}

					current_entry.device = luks_unlocked;

					// refresh devices

					refresh(false); // do not reset selections
					return; // no need to continue
				}
			}

			current_entry.device = current_dev;
			
			if (current_entry.mount_point == "/"){
				App.init_boot_options();
			}
		});

		return combo;
	}

	private void add_boot_options(){

		var hbox = Ui.add_button_row(this, Gtk.Align.START);
		hbox.margin_top = Ui.Spacing.XS;
		
		string tt = _("[For Experienced Users] Change these settings if the restored system fails to boot.");
		var button = add_button(hbox, _("Bootloader Options (Advanced)"), tt, null, null);
		var btn_boot_options = button;

        btn_boot_options.clicked.connect(()=>{
			var win = new BootOptionsWindow();
			win.set_transient_for(parent_window);
		});
	}

	public bool check_and_mount_devices(){

		// check if we are restoring the current system
		
		if (App.dst_root == App.sys_root){
			return true; // all required devices are already mounted
		}
		
		// check if target device is selected for /
		
		foreach(var entry in App.mount_list){
			if ((entry.mount_point == "/") && (entry.device == null)){
				
				gtk_messagebox(
					_("Root device not selected"),
					_("Select the device for root file system (/)"),
					parent_window, true);
				
				return false;
			}
		}

		// verify that target device for / is not same as system in clone mode
		
		if (App.mirror_system){

			foreach(var entry in App.mount_list){
				if (entry.mount_point != "/"){ continue; }

				bool same = false;
				if (entry.device.uuid == App.sys_root.uuid){
					same = true;
				}
				else if (entry.device.has_parent() && App.sys_root.has_parent()){
					if (entry.device.uuid == App.sys_root.parent.uuid){
						same = true;
					}
				}
				
				if (same){
					
					gtk_messagebox(
						_("Target device is same as system device"),
						_("Select another device for root file system (/)"),
						parent_window, true);
						
					return false;
				}

				break;
			}
		}

		// check if /boot device is selected for luks partitions
		
		foreach(var entry in App.mount_list){
			if ((entry.mount_point == "/boot") && (entry.device == null)){

				if ((App.dst_root != null) && (App.dst_root.is_on_encrypted_partition())){

					gtk_messagebox(
						_("Boot device not selected"),
						_("An encrypted device is selected for root file system (/). The boot directory (/boot) must be mounted on a non-encrypted device for the system to boot successfully.\n\nEither select a non-encrypted device for boot directory or select a non-encrypted device for root filesystem."),
						parent_window, true);

					return false;
				}
			}
		}

		//check if grub device selected ---------------

		if (App.reinstall_grub2 && (App.grub_device.length == 0)){
			string title =_("GRUB device not selected");
			string msg = _("Please select the GRUB device");
			gtk_messagebox(title, msg, parent_window, true);
			return false;
		}

		// check BTRFS subvolume layout --------------

		bool supported = App.check_btrfs_layout(App.dst_root, App.dst_home, false);
		
		if (!supported){
			var title = _("Unsupported Subvolume Layout")
				+ " (%s)".printf(App.dst_root.device);
			var msg = _("Partition has an unsupported subvolume layout.") + " ";
			msg += _("Only ubuntu-type layouts with @ and @home subvolumes are currently supported.") + "\n\n";
			gtk_messagebox(title, msg, parent_window, true);
			return false;
		}

		// mount target device -------------

		bool status = App.mount_target_devices(parent_window);
		if (status == false){
			string title = _("Error");
			string msg = _("Failed to mount devices");
			gtk_messagebox(title, msg, parent_window, true);
			return false;
		}

		return true;
	}
}
