/*
 * UsersBox.vala
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

/* Row object for the users list. GTK4 list widgets bind to GObjects rather than
 * tree-model columns. */
public enum UserChoice {
	EXCLUDE_ALL,
	INCLUDE_HIDDEN,
	INCLUDE_ALL
}

public class UserRow : GLib.Object {

	public SystemUser user { get; set; }
	public bool include_hidden { get; set; }
	public bool include_all { get; set; }
	public bool exclude_all { get; set; }

	public UserRow(SystemUser _user, bool _include_hidden, bool _include_all, bool _exclude_all){
		user = _user;
		include_hidden = _include_hidden;
		include_all = _include_all;
		exclude_all = _exclude_all;
	}
}

class UsersBox : Gtk.Box{
	
	private Gtk.ColumnView treeview;
	private GLib.ListStore users_model;
	private Gtk.ScrolledWindow scrolled_treeview;
	private Gtk.Window parent_window;
	private ExcludeBox exclude_box;
	private Gtk.Box box_btrfs;
	private Gtk.Label lbl_message;
	private Gtk.CheckButton chk_include_btrfs_home;
	private bool restore_mode = false;
	
	public UsersBox (Gtk.Window _parent_window, ExcludeBox _exclude_box, bool _restore_mode) {

		log_debug("UsersBox: UsersBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;

		restore_mode = _restore_mode;

		exclude_box = _exclude_box;

		Ui.add_title(this, _("User Home Directories"));

		lbl_message = Ui.add_dim_label(this, _("User home directories are excluded by default unless you enable them here"));

		init_treeview();

		box_btrfs = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
		append(box_btrfs);

		init_btrfs_home_option(box_btrfs);
		
		refresh();

		log_debug("UsersBox: UsersBox(): exit");
    }

    private void init_treeview(){
		
		/* GTK4 deprecates Gtk.TreeView. SystemUser plus the three mutually
		 * exclusive choices live on a UserRow inside a GLib.ListStore. */

		users_model = new GLib.ListStore(typeof(UserRow));

		treeview = new Gtk.ColumnView(new Gtk.MultiSelection(users_model));
		treeview.set_tooltip_text(_("Click to change what is included for each user."));

		// scrolled
		scrolled_treeview = Ui.add_boxed_list(this, treeview);

		treeview.append_column(make_user_text_column(_("User"), true));
		treeview.append_column(make_user_text_column(_("Home"), false));
		treeview.append_column(make_user_toggle_column(_("Exclude All Files"), UserChoice.EXCLUDE_ALL));
		treeview.append_column(make_user_toggle_column(_("Include Only Hidden Files"), UserChoice.INCLUDE_HIDDEN));
		treeview.append_column(make_user_toggle_column(_("Include All Files"), UserChoice.INCLUDE_ALL));
	}

	private Gtk.ColumnViewColumn make_user_text_column(string title, bool show_name){

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
			var row = (UserRow) list_item.get_item();
			lbl.label = show_name ? row.user.name : row.user.home_path;
		});

		var col = new Gtk.ColumnViewColumn(title, factory);
		col.expand = true;
		return col;
	}

	private Gtk.ColumnViewColumn make_user_toggle_column(string title, UserChoice choice){

		var factory = new Gtk.SignalListItemFactory();

		factory.setup.connect((object) => {
			var list_item = (Gtk.ListItem) object;

			var chk = new Gtk.CheckButton();
			chk.halign = Gtk.Align.CENTER;

			chk.toggled.connect(() => {
				if (!chk.active){ return; }

				var row = chk.get_data<UserRow>("row");
				if (row == null){ return; }

				apply_user_choice(row, choice);
			});

			list_item.set_child(chk);
		});

		factory.bind.connect((object) => {
			var list_item = (Gtk.ListItem) object;
			var chk = (Gtk.CheckButton) list_item.get_child();
			var row = (UserRow) list_item.get_item();

			chk.steal_data<UserRow>("row");

			switch (choice){
			case UserChoice.EXCLUDE_ALL:
				chk.active = row.exclude_all;
				break;
			case UserChoice.INCLUDE_HIDDEN:
				chk.active = row.include_hidden;
				break;
			case UserChoice.INCLUDE_ALL:
				chk.active = row.include_all;
				break;
			}

			chk.set_data<UserRow>("row", row);
		});

		return new Gtk.ColumnViewColumn(title, factory);
	}

	private void apply_user_choice(UserRow row, UserChoice choice){

		var user = row.user;

		string exc_pattern = "%s/**".printf(user.home_path);
		string inc_pattern = "+ %s/**".printf(user.home_path);
		string inc_hidden_pattern = "+ %s/.**".printf(user.home_path);

		if (user.has_encrypted_home){
			inc_pattern = "+ /home/.ecryptfs/%s/***".printf(user.name);
			exc_pattern = "/home/.ecryptfs/%s/***".printf(user.name);
		}

		switch (choice){

		case UserChoice.EXCLUDE_ALL:

			log_debug("cell_exclude.toggled()");

			if (!App.exclude_list_user.contains(exc_pattern)){
				App.exclude_list_user.add(exc_pattern);
			}
			if (App.exclude_list_user.contains(inc_pattern)){
				App.exclude_list_user.remove(inc_pattern);
			}
			if (App.exclude_list_user.contains(inc_hidden_pattern)){
				App.exclude_list_user.remove(inc_hidden_pattern);
			}
			break;

		case UserChoice.INCLUDE_HIDDEN:

			log_debug("cell_include.toggled()");

			if (user.has_encrypted_home){

				string txt = _("Encrypted Home Directory");
				string msg = _("Selected user has an encrypted home directory. It's not possible to include only hidden files.");

				gtk_messagebox(txt, msg, parent_window, true);

				this.refresh_treeview();
				return;
			}

			if (!App.exclude_list_user.contains(inc_hidden_pattern)){
				App.exclude_list_user.add(inc_hidden_pattern);
			}
			if (App.exclude_list_user.contains(inc_pattern)){
				App.exclude_list_user.remove(inc_pattern);
			}
			if (App.exclude_list_user.contains(exc_pattern)){
				App.exclude_list_user.remove(exc_pattern);
			}
			break;

		case UserChoice.INCLUDE_ALL:

			if (!App.exclude_list_user.contains(inc_pattern)){
				App.exclude_list_user.add(inc_pattern);
			}
			if (App.exclude_list_user.contains(exc_pattern)){
				App.exclude_list_user.remove(exc_pattern);
			}
			if (App.exclude_list_user.contains(inc_hidden_pattern)){
				App.exclude_list_user.remove(inc_hidden_pattern);
			}
			break;
		}

		this.refresh_treeview();
	}

	private void init_btrfs_home_option(Gtk.Box box){

		if (restore_mode){
			
			chk_include_btrfs_home = new Gtk.CheckButton.with_label(_("Restore @home subvolume"));

			box.append(chk_include_btrfs_home);

			chk_include_btrfs_home.toggled.connect(()=>{
				App.include_btrfs_home_for_restore = chk_include_btrfs_home.active; 
			});
		
		}
		else {

			chk_include_btrfs_home = new Gtk.CheckButton.with_label(_("Include @home subvolume in backups"));
			
			box.append(chk_include_btrfs_home);

			chk_include_btrfs_home.toggled.connect(()=>{
				App.include_btrfs_home_for_backup = chk_include_btrfs_home.active; 
			});
		}
	}

	// helpers

	public void refresh(){

		if (App.btrfs_mode){

			lbl_message.visible = false;

			scrolled_treeview.visible = false;
			box_btrfs.visible = true;
			
			if (restore_mode){
				chk_include_btrfs_home.active = App.include_btrfs_home_for_restore;
			}
			else{
				chk_include_btrfs_home.active = App.include_btrfs_home_for_backup;
			}
		}
		else{
			lbl_message.visible = true;

			scrolled_treeview.visible = true;

			refresh_treeview();
			
			box_btrfs.visible = false;
		}

		this.visible = true;
	}
	
	private void refresh_treeview(){
		
		users_model.remove_all();

		foreach(var user in App.current_system_users.values){

			if (user.is_system){ continue; }

			string exc_pattern = "%s/**".printf(user.home_path);
			string inc_pattern = "+ %s/**".printf(user.home_path);
			string inc_hidden_pattern = "+ %s/.**".printf(user.home_path);

			if (user.has_encrypted_home){
				inc_pattern = "+ /home/.ecryptfs/%s/***".printf(user.name);
				exc_pattern = "/home/.ecryptfs/%s/***".printf(user.name);
			}
			
			bool include_hidden = App.exclude_list_user.contains(inc_hidden_pattern);
			bool include_all = App.exclude_list_user.contains(inc_pattern);
			bool exclude_all = !include_hidden && !include_all; //App.exclude_list_user.contains(exc_pattern);

			if (exclude_all){
				
				if (!App.exclude_list_user.contains(exc_pattern)){
					App.exclude_list_user.add(exc_pattern);
				}
				if (App.exclude_list_user.contains(inc_pattern)){
					App.exclude_list_user.remove(inc_pattern);
				}
				if (App.exclude_list_user.contains(inc_hidden_pattern)){
					App.exclude_list_user.remove(inc_hidden_pattern);
				}
			}
			
			users_model.append(new UserRow(user, include_hidden, include_all, exclude_all));
		}

		exclude_box.refresh_treeview();
	}
}
