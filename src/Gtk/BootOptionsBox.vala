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

class BootOptionsBox : Gtk.Box{
	
	private Gtk.Box option_box;
	private Gtk.DropDown cmb_grub_dev;

	private Gtk.CheckButton chk_reinstall_grub;
	private Gtk.CheckButton chk_update_initramfs;
	private Gtk.CheckButton chk_update_grub;
	private weak Gtk.Window parent_window; // back-reference: the window owns this box

	/* Gtk.DropDown's internal GtkSingleSelection has autoselect = TRUE, so
	 * assigning the model selects row 0 and notifies. Without this guard that
	 * notification writes the first block device lsblk returned into
	 * App.grub_device, overwriting the target Main.init_boot_options() chose. */
	private bool updating = false;

	public BootOptionsBox (Gtk.Window _parent_window) {

		log_debug("BootOptionsBox: BootOptionsBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		Ui.add_title(this, _("Bootloader Options"));

		Ui.add_dim_label(this, _("[For Experienced Users] Change these settings if the restored system fails to boot."));

		// options
		option_box = Ui.add_card(this, Gtk.Orientation.VERTICAL, Ui.Spacing.XS);

		add_bootloader_options();

		refresh_options();

		log_debug("BootOptionsBox: BootOptionsBox(): exit");
    }

	private void add_bootloader_options(){

		add_chk_reinstall_grub();
		
		var hbox = new Gtk.Box(Orientation.HORIZONTAL, Ui.Spacing.XS);
		hbox.margin_start = Ui.Spacing.LG;
		hbox.margin_bottom = Ui.Spacing.XS;
        option_box.append(hbox);

		/* GTK4 deprecates Gtk.ComboBox; Device is already a GObject, so it can
		 * go straight into a GLib.ListStore behind a Gtk.DropDown. */

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = new Gtk.Label("");
			lbl.xalign = (float) 0.0;
			list_item.set_child(lbl);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var lbl = (Gtk.Label) list_item.get_child();
			var dev = (Device) list_item.get_item();

			if (dev.device.length == 0){
				// the "no device" sentinel; autoselect cannot leave a
				// Gtk.DropDown unselected, so "none" needs a real row
				lbl.label = _("Do not install");
				Ui.set_text_style(lbl, "ts-dim");
			}
			else if (dev.type == "disk"){
				lbl.label = "%s (MBR)".printf(dev.description());
				Ui.set_text_style(lbl, "ts-heading");
			}
			else{
				lbl.label = dev.description();
				Ui.set_text_style(lbl, "ts-body");
			}
		});

		cmb_grub_dev = new Gtk.DropDown(null, null);
		cmb_grub_dev.factory = factory;
		cmb_grub_dev.hexpand = true;
		hbox.append(cmb_grub_dev);

		cmb_grub_dev.notify["selected"].connect(()=>{
			if (updating){ return; }
			save_grub_device_selection();
		});


		add_chk_update_initramfs();

		add_chk_update_grub();
	}

	private void add_chk_reinstall_grub(){
		
		var chk = new CheckButton.with_label(_("(Re)install GRUB2 on:"));
		chk.active = false;
		chk.set_tooltip_text(_("Re-installs the GRUB2 bootloader on the selected device."));
		option_box.append(chk);
		chk_reinstall_grub = chk;

		chk.toggled.connect(()=>{
			cmb_grub_dev.sensitive = chk_reinstall_grub.active;
			App.reinstall_grub2 = chk_reinstall_grub.active;
			save_grub_device_selection();
		});
	}

	private void add_chk_update_initramfs(){
		
		//chk_update_initramfs
		var chk = new CheckButton.with_label(_("Update initramfs"));
		chk.active = false;
		chk.set_tooltip_text(_("Re-generates initramfs for all installed kernels. This is generally not needed. Select this only if the restored system fails to boot."));
		option_box.append(chk);
		chk_update_initramfs = chk;

		chk.toggled.connect(()=>{
			App.update_initramfs = chk_update_initramfs.active;
		});
	}

	private void add_chk_update_grub(){
		
		//chk_update_grub
		var chk = new CheckButton.with_label(_("Update GRUB menu"));
		chk.active = false;
		chk.set_tooltip_text(_("Updates the GRUB menu entries (recommended). This is safe to run and should be left selected."));
		option_box.append(chk);
		chk_update_grub = chk;

		chk.toggled.connect(()=>{
			App.update_grub = chk_update_grub.active;
		});
	}

	private void save_grub_device_selection(){
		
		App.grub_device = "";
		
		if (App.reinstall_grub2){
			var entry = cmb_grub_dev.get_selected_item() as Device;
			if (entry == null) { return; } // not selected
			App.grub_device = entry.device; // "" for the sentinel row
		}

		log_debug("BootOptionsBox: grub_device: %s".printf(App.grub_device));
	}

	private void refresh_options(){

		refresh_cmb_grub_dev();
		
		chk_reinstall_grub.active = App.reinstall_grub2;
		cmb_grub_dev.sensitive = chk_reinstall_grub.active;
		chk_update_initramfs.active = App.update_initramfs;
		chk_update_grub.active = App.update_grub;
		
		chk_reinstall_grub.sensitive = true;
		chk_update_initramfs.sensitive = true;
		chk_update_grub.sensitive = true;
				
		if (App.mirror_system){
			// bootloader must be re-installed
			chk_reinstall_grub.sensitive = false;
			chk_update_initramfs.sensitive = false;
			chk_update_grub.sensitive = false;
		}
		else{
			if (App.snapshot_to_restore.distro.dist_id == "fedora"){
				// grub2-install should never be run on EFI fedora systems
				chk_reinstall_grub.sensitive = false;
			}
		}
	}
	
	private void refresh_cmb_grub_dev(){
		
		var store = new GLib.ListStore(typeof(Device));

		// index 0 represents "nothing selected"
		var none = new Device();
		none.device = "";
		store.append(none);

		/* App.partitions, which the daemon fills, rather than a second lsblk
		 * of this box's own. The bootloader target has to be a device from
		 * the SAME model the restore plan reasons about; two scans that can
		 * disagree is how GRUB ends up installed on a disk the plan was not
		 * describing. */
		foreach(Device dev in App.partitions) {
			
			// select disk and normal partitions, skip others (loop crypt rom lvm)
			if ((dev.type != "disk") && (dev.type != "part")){
				continue;
			}

			// skip luks and lvm2 partitions
			if ((dev.fstype == "luks")||(dev.fstype == "lvm2")){
				continue;
			}

			// skip extended partitions
			if (dev.size_bytes < 10 * KB){
				continue;
			}

			store.append(dev);
		}

		updating = true;
		cmb_grub_dev.model = store;
		updating = false;

		cmb_grub_dev_select_default();
	}

	private void cmb_grub_dev_select_default(){

		if ((cmb_grub_dev == null) || (cmb_grub_dev.model == null)){
			return;
		}
		
		log_debug("BootOptionsBox: cmb_grub_dev_select_default()");
		
		updating = true;

		if (App.grub_device.length == 0){
			cmb_grub_dev.selected = 0; // the sentinel row
			updating = false;
			return;
		}

		var store = (GLib.ListStore) cmb_grub_dev.model;
		uint active = 0; // fall back to the sentinel, never to a real disk

		for (uint i = 0; i < store.get_n_items(); i++) {

			var dev_iter = (Device) store.get_item(i);

			if (dev_iter.device == App.grub_device){
				active = i;
				break;
			}
		}

		cmb_grub_dev.selected = active;

		updating = false;

		log_debug("BootOptionsBox: cmb_grub_dev_select_default(): exit");
	}
}
