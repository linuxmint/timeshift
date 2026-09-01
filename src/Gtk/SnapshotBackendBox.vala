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
	
	private Gtk.CheckButton opt_rsync;
	private Gtk.CheckButton opt_btrfs;
	private Gtk.Label lbl_description;
	private Gtk.Box bullets_description;
	private Gtk.Box description_box;
	private weak Gtk.Window parent_window; // back-reference: the window owns this box
	
	public signal void type_changed();

	public SnapshotBackendBox (Gtk.Window _parent_window) {

		log_debug("SnapshotBackendBox: SnapshotBackendBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		build_ui();

		refresh();

		log_debug("SnapshotBackendBox: SnapshotBackendBox(): exit");
    }

	private void build_ui(){

		Ui.add_title(this, _("Select Snapshot Type"));

		Ui.add_dim_label(this, _("How snapshots are created and where they can be stored."));

		var vbox = Ui.add_card(this, Gtk.Orientation.VERTICAL, Ui.Spacing.XS);
		
		add_opt_rsync(vbox);

		add_opt_btrfs(vbox);

		add_description();

		update_description();
	}

	private void add_opt_rsync(Gtk.Box hbox){

		var opt = Ui.add_radio(hbox, _("RSYNC"), null);
		opt.set_tooltip_text(_("Create snapshots using RSYNC tool and hard-links"));
		opt_rsync = opt;

		opt_rsync.toggled.connect(()=>{
			if (loading){ return; }
			if (opt_rsync.active){
				App.btrfs_mode = false;
				Main.first_snapshot_size = 0;
				init_backend();
				type_changed();
				update_description();
			}
		});
	}

	private void add_opt_btrfs(Gtk.Box hbox){

		var opt = Ui.add_radio(hbox, _("BTRFS"), opt_rsync);
		opt.set_tooltip_text(_("Create snapshots using BTRFS"));
		opt_btrfs = opt;

        if (!check_for_btrfs_tools()) {
            opt.sensitive = false;
            opt_rsync.active = true;
        }

		opt_btrfs.toggled.connect(()=>{
			if (loading){ return; }
			if (opt_btrfs.active){
				App.btrfs_mode = true;
				init_backend();
				type_changed();
				update_description();
			}
		});
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

		/* Help text, always visible; scrolls when the window is short. */

		var scrolled = new ScrolledWindow();
		scrolled.has_frame = false;
		scrolled.margin_top = Ui.Spacing.XS;
		scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scrolled.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
		scrolled.vexpand = true;
		this.append(scrolled);

		description_box = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.XS);
		scrolled.set_child(description_box);

		lbl_description = Ui.add_heading(description_box, "");

		bullets_description = Ui.add_bullets(description_box, {}, "ts-dim");
	}

	private void update_description(){

		/* The option buttons emit "toggled" while build_ui() is still running,
		 * before add_description() has created the label. */
		if (lbl_description == null){ return; }

		description_box.remove(bullets_description);

		if (opt_btrfs.active){
			lbl_description.label = _("BTRFS Snapshots");

			bullets_description = Ui.add_bullets(description_box, {
				_("Snapshots are created using the built-in features of the BTRFS file system."),
				_("Snapshots are created and restored instantly. Snapshot creation is an atomic transaction at the file system level."),
				_("Snapshots are restored by replacing system subvolumes. Since files are never copied, deleted or overwritten, there is no risk of data loss. The existing system is preserved as a new snapshot after restore."),
				_("Snapshots are perfect, byte-for-byte copies of the system. Nothing is excluded."),
				_("Snapshots are saved on the same disk from which they are created (system disk). Storage on other disks is not supported. If system disk fails then snapshots stored on it will be lost along with the system."),
				_("Size of BTRFS snapshots are initially zero. As system files gradually change with time, data gets written to new data blocks which take up disk space (copy-on-write). Files in the snapshot continue to point to original data blocks."),
				_("OS must be installed on a BTRFS partition with Ubuntu-type subvolume layout (@ and @home subvolumes). Other layouts are not supported.")
			}, "ts-dim");
		}
		else{
			lbl_description.label = _("RSYNC Snapshots");

			bullets_description = Ui.add_bullets(description_box, {
				_("Snapshots are created by creating copies of system files using rsync, and hard-linking unchanged files from previous snapshot."),
				_("All files are copied when first snapshot is created. Subsequent snapshots are incremental. Unchanged files will be hard-linked from the previous snapshot if available."),
				_("Snapshots can be saved to any disk formatted with a Linux file system. Saving snapshots to non-system or external disk allows the system to be restored even if system disk is damaged or re-formatted."),
				_("Files and directories can be excluded to save disk space.")
			}, "ts-dim");
		}
	}
	
	public void init_backend(){
		
		App.try_select_default_device_for_backup(parent_window);
	}

	/* True while refresh() is putting the widgets into the state the config
	 * already describes, as opposed to a person choosing something.
	 *
	 * Setting a Gtk.CheckButton's `active` fires `toggled`, and the handlers
	 * below treat that as a CHANGE: they zero Main.first_snapshot_size so the
	 * system size gets measured again against the new mode. Which is right when
	 * someone picks a different backend, and wrong when the page is merely
	 * being drawn -- and the page is drawn every time the Settings window
	 * opens.
	 *
	 * The consequence was not cosmetic. Opening Settings and closing it again
	 * persisted a zero estimate, and that estimate is the space check: 
	 * SnapshotRepo reads it as the room a first backup needs, and
	 * Main.create_snapshot only compares free space `if (first_snapshot_size >
	 * 0)`. So looking at the settings quietly switched the check off, and made
	 * the next backup wizard re-measure the whole filesystem to get it back.
	 *
	 * It starts TRUE, not false. Building the page toggles the radios too --
	 * add_opt_btrfs() sets opt_rsync.active when btrfs tools are missing, and
	 * grouping two CheckButtons settles which of them is on -- and all of that
	 * happens before refresh() is ever called. A flag that only covered
	 * refresh() would still let construction zero the estimate, which is
	 * exactly what it did.
	 */
	private bool loading = true;

	public void refresh(){

		loading = true;

		// BTRFS snapshots need a local filesystem, so the option is not
		// available while snapshots are sent to a remote host
		if (App.backup_location_type == "ssh"){
			opt_btrfs.sensitive = false;
			opt_btrfs.set_tooltip_text(_("Not available for remote locations"));
			opt_rsync.active = true;
		}
		else if (check_for_btrfs_tools()){
			opt_btrfs.sensitive = true;
			opt_btrfs.set_tooltip_text(_("Create snapshots using BTRFS"));
		}
		
		opt_btrfs.active = App.btrfs_mode;

		loading = false;

		// Called explicitly, because the handlers deliberately did not.
		type_changed();
		update_description();
	}
}
