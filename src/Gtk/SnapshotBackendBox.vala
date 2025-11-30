/*
 * SnapshotBackendBox.vala
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

class SnapshotBackendBox : Gtk.Box{
	
	private Gtk.RadioButton opt_rsync;
	private Gtk.RadioButton opt_btrfs;
	private Gtk.Label lbl_description;
	private Gtk.ComboBox combo_subvol_layout;
	private Gtk.Window parent_window;
	private Gtk.Box vbox_subvolume_custom;
	
	public signal void type_changed();

	public SnapshotBackendBox (Gtk.Window _parent_window) {

		log_debug("SnapshotBackendBox: SnapshotBackendBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;

		build_ui();

		refresh();

		log_debug("SnapshotBackendBox: SnapshotBackendBox(): exit");
    }

	private void build_ui(){

		add_label_header(this, _("Select Snapshot Type"), true);

		var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
		//hbox.homogeneous = true;
		add(vbox);
		
		add_opt_rsync(vbox);

		add_opt_btrfs(vbox);

		add_description();
	}

	private void add_opt_rsync(Gtk.Box hbox){

		var opt = new RadioButton.with_label_from_widget(null, _("RSYNC"));
		opt.set_tooltip_markup(_("Create snapshots using RSYNC tool and hard-links"));
		hbox.add (opt);
		opt_rsync = opt;

		opt_rsync.toggled.connect(()=>{
			if (opt_rsync.active){
				App.btrfs_mode = false;
				combo_subvol_layout.sensitive = false;
				Main.first_snapshot_size = 0;
				init_backend();
				type_changed();
				update_description();
			}
		});
	}

	private void add_opt_btrfs(Gtk.Box hbox){

		var opt = new RadioButton.with_label_from_widget(opt_rsync, _("BTRFS"));
		opt.set_tooltip_markup(_("Create snapshots using BTRFS"));
		hbox.add (opt);
		opt_btrfs = opt;

		create_btrfs_subvolume_selection(hbox);

        if (!check_for_btrfs_tools()) {
            opt.sensitive = false;
            opt_rsync.active = true;
        }

		opt_btrfs.toggled.connect(()=>{
			if (opt_btrfs.active){
				App.btrfs_mode = true;
				combo_subvol_layout.sensitive = true;
				init_backend();
				type_changed();
				update_description();
			}
		});
	}

	private void create_btrfs_subvolume_selection(Gtk.Box vbox) {

		// subvolume layout
		var hbox_subvolume = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		vbox.add(hbox_subvolume);

		var sg_label = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
		var sg_edit = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);

		var lbl_subvol_name = new Gtk.Label(_("Subvolume layout:"));
		lbl_subvol_name.xalign = (float) 0.0;
		hbox_subvolume.add(lbl_subvol_name);
		sg_label.add_widget(lbl_subvol_name);

		// Combobox
		var layout = new string[]{
			App.root_subvolume_name,
			App.home_subvolume_name
		};
		
		var possible_layouts = new string[,]{
			{"", "", "Custom"},
			{"@", "@home", "Ubuntu (@, @home)"},
			{"@rootfs", "", "Debian (@rootfs)"},
			{"root", "home", "Fedora (root, home)"}
		};

		Gtk.ListStore list_store = new Gtk.ListStore (3,
			typeof (string),
			typeof (string),
			typeof (string));
		Gtk.TreeIter strore_iter;
		int active = -1;
		for (int idx = 0; idx < possible_layouts.length[0]; idx++) {
			list_store.append(out strore_iter);
			list_store.set(strore_iter,
				0, possible_layouts[idx, 0],
				1, possible_layouts[idx, 1],
				2, possible_layouts[idx, 2]);

			// Find our layout in the options
			if (possible_layouts[idx, 0] == layout[0] &&
				possible_layouts[idx, 1] == layout[1]) active = idx;
		}

		if (active < 0){
			active = 0; 
		}

		combo_subvol_layout = new Gtk.ComboBox.with_model (list_store);
		hbox_subvolume.add (combo_subvol_layout);
		sg_edit.add_widget(combo_subvol_layout);

		Gtk.CellRendererText renderer = new Gtk.CellRendererText ();
		combo_subvol_layout.pack_start (renderer, true);
		combo_subvol_layout.add_attribute (renderer, "text", 2);

		// Set active index
		combo_subvol_layout.active = active;

		// Create custom inputs
		vbox_subvolume_custom = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
		vbox.add(vbox_subvolume_custom);

		var custom_root_subvol_entry = add_opt_btrfs_subvolume_name_entry(vbox_subvolume_custom, sg_label, sg_edit,
			"Root", App.root_subvolume_name);

		var custom_home_subvol_entry = add_opt_btrfs_subvolume_name_entry(vbox_subvolume_custom, sg_label, sg_edit,
			"Home", App.home_subvolume_name);

		combo_subvol_layout.changed.connect (() => {
			Gtk.TreeIter iter;
			combo_subvol_layout.get_active_iter (out iter);

			// Handle custom names
			if (combo_subvol_layout.active == 0) {
				custom_root_subvol_entry.text = App.root_subvolume_name;
				custom_home_subvol_entry.text = App.home_subvolume_name;
			}
			// Handle selection from combobox
			else {
				Value val1;
				list_store.get_value (iter, 0, out val1);
				App.root_subvolume_name = (string) val1;

				Value val2;
				list_store.get_value (iter, 1, out val2);
				App.home_subvolume_name = (string) val2;

				// If home subolume name is empty, do not backup home.
				if (App.home_subvolume_name == "")
					App.include_btrfs_home_for_backup = false;
			}

			init_backend();
			type_changed();
			update_custom_subvol_name_visibility();
		});

		custom_root_subvol_entry.focus_out_event.connect((entry1, event1) => {
			App.root_subvolume_name = custom_root_subvol_entry.text;

			init_backend();
			type_changed();

			return false;
		});

		custom_home_subvol_entry.focus_out_event.connect((entry1, event1) => {
			App.home_subvolume_name = custom_home_subvol_entry.text;

			// If home subolume name is empty, do not backup home.
			if (App.home_subvolume_name == "")
				App.include_btrfs_home_for_backup = false;

			init_backend();
			type_changed();

			return false;
		});

		// Add custom subvolume names
	}

	private Gtk.Entry add_opt_btrfs_subvolume_name_entry(Gtk.Box vbox, Gtk.SizeGroup sg_title,
		Gtk.SizeGroup sg_edit, string name, string value) {
		// root subvolume name layout
		var hbox_subvolume_edit = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		vbox.add(hbox_subvolume_edit);

		var lbl_subvol_name = new Gtk.Label(_(@"$name subvolume:"));
		lbl_subvol_name.xalign = (float) 0.0;
		hbox_subvolume_edit.add(lbl_subvol_name);
		sg_title.add_widget(lbl_subvol_name);

		var entry_subvol = new Gtk.Entry();
		entry_subvol.text = value;
		hbox_subvolume_edit.add(entry_subvol);
		sg_edit.add_widget(entry_subvol);

		return entry_subvol;
	}

	public void update_custom_subvol_name_visibility() {
		if(combo_subvol_layout.active == 0)
			vbox_subvolume_custom.visible = true;
		else vbox_subvolume_custom.visible = false;
	}

	private bool check_for_btrfs_tools() {
        try {
            const string args[] = {"lsblk", "-o", "FSTYPE", null};
            var proc = new Subprocess.newv(
                args,
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE
            );

            Bytes stdout;
            if (proc.communicate(null, null, out stdout, null)) {
                string output = (string) Bytes.unref_to_data(stdout);

                if (output.contains("btrfs")) {
                    return true;
                }
            }
        }
        catch (Error e) {
            log_error (e.message);
        }

        return false;
	}

	private void add_description(){

		Gtk.Expander expander = new Gtk.Expander(_("Help"));
		expander.use_markup = true;
		expander.margin_top = 12;
		this.add(expander);
		
		// scrolled
		var scrolled = new ScrolledWindow(null, null);
		scrolled.set_shadow_type (ShadowType.ETCHED_IN);
		scrolled.margin_top = 6;
		//scrolled.expand = true;
		scrolled.set_size_request(-1,200);
		scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scrolled.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
		expander.add(scrolled);

		var lbl = new Gtk.Label("");
		lbl.set_use_markup(true);
		lbl.xalign = (float) 0.0;
		lbl.yalign = (float) 0.0;
		lbl.wrap = true;
		lbl.wrap_mode = Pango.WrapMode.WORD;
		lbl.margin = 12;
		lbl.vexpand = true;
		scrolled.add(lbl);

		lbl_description = lbl;
	}

	private void update_description(){

		string bullet = "• ";
		
		if (opt_btrfs.active){
			string txt = "<b>" + _("BTRFS Snapshots") + "</b>\n\n";

			txt += bullet + _("Snapshots are created using the built-in features of the BTRFS file system.") + "\n\n";
			
			txt += bullet + _("Snapshots are created and restored instantly. Snapshot creation is an atomic transaction at the file system level.") + "\n\n";

			txt += bullet + _("Snapshots are restored by replacing system subvolumes. Since files are never copied, deleted or overwritten, there is no risk of data loss. The existing system is preserved as a new snapshot after restore.") + "\n\n";
			
			txt += bullet + _("Snapshots are perfect, byte-for-byte copies of the system. Nothing is excluded.") + "\n\n";

			txt += bullet + _("Snapshots are saved on the same disk from which they are created (system disk). Storage on other disks is not supported. If system disk fails then snapshots stored on it will be lost along with the system.") + "\n\n";

			txt += bullet + _("Size of BTRFS snapshots are initially zero. As system files gradually change with time, data gets written to new data blocks which take up disk space (copy-on-write). Files in the snapshot continue to point to original data blocks.") + "\n\n";

			txt += bullet + _("OS must be installed on a BTRFS partition with Ubuntu-type subvolume layout (@ and @home subvolumes). Other layouts are not supported.") + "\n\n";
			
			lbl_description.label = txt;
		}
		else{
			string txt = "<b>" + _("RSYNC Snapshots") + "</b>\n\n";

			txt += bullet + _("Snapshots are created by creating copies of system files using rsync, and hard-linking unchanged files from previous snapshot.") + "\n\n";
			
			txt += bullet + _("All files are copied when first snapshot is created. Subsequent snapshots are incremental. Unchanged files will be hard-linked from the previous snapshot if available.") + "\n\n";

			txt += bullet + _("Snapshots can be saved to any disk formatted with a Linux file system. Saving snapshots to non-system or external disk allows the system to be restored even if system disk is damaged or re-formatted.") + "\n\n";

			txt += bullet + _("Files and directories can be excluded to save disk space.") + "\n\n";

			lbl_description.label = txt;
		}
	}
	
	public void init_backend(){
		
		App.try_select_default_device_for_backup(parent_window);
	}

	public void refresh(){
		
		opt_btrfs.active = App.btrfs_mode;
		type_changed();
		update_description();
		update_custom_subvol_name_visibility();
	}
}
