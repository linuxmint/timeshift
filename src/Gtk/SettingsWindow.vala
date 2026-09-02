/*
 * SettingsWindow.vala
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

class SettingsWindow : AppWindow{
	
	private Gtk.StackSwitcher switcher;
	private Gtk.Stack stack;
	private Gtk.Widget page_filters;
	
	private SnapshotBackendBox backend_box;
	private BackupDeviceBox backup_dev_box;
	private ScheduleBox schedule_box;
	private ExcludeBox exclude_box;
	private UsersBox users_box;
	private MiscBox misc_box;
	private RecoveryBox recovery_box;
	private AppearanceBox appearance_box;
	
	private uint tmr_init;
	private int def_width = 680;
	private int def_height = 580;
	
	public SettingsWindow() {

		log_debug("SettingsWindow: SettingsWindow()");

		this.title = _("Settings");
        this.modal = true;
        this.set_default_size(def_width, def_height);

		this.close_request.connect(on_delete_event);

		/* The page switcher is the title; closing the window saves, so
		 * there is no OK button. */
		var header = new Gtk.HeaderBar();
		set_titlebar(header);

		switcher = new Gtk.StackSwitcher();
		header.title_widget = switcher;

		stack = new Gtk.Stack();
		stack.set_transition_duration(100);
        stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT);
		stack.hexpand = true;
		stack.vexpand = true;
		set_child(stack);

		switcher.set_stack(stack);
		
		backend_box = new SnapshotBackendBox(this);
		stack.add_titled (form_page(backend_box), "type", _("Type"));
		
		backup_dev_box = new BackupDeviceBox(this);
		stack.add_titled (list_page(backup_dev_box), "location", _("Location"));

		schedule_box = new ScheduleBox(this);
		stack.add_titled (form_page(schedule_box), "schedule", _("Schedule"));

		exclude_box = new ExcludeBox(this);
		users_box = new UsersBox(this, exclude_box, false);
		exclude_box.set_users_box(users_box);

		misc_box = new MiscBox(this, false);

		appearance_box = new AppearanceBox(this);
		
		stack.add_titled (list_page(users_box), "users", _("Users"));

		page_filters = list_page(exclude_box);
		stack.add_titled (page_filters, "filters", _("Filters"));

		stack.add_titled (form_page(appearance_box), "appearance", _("Appearance"));

		stack.add_titled (form_page(misc_box), "misc", _("Misc"));

		/* Managing the host's bootloader from inside the booted recovery
		 * environment makes no sense, so the page stays off a live system. */
		if (!App.live_system()){
			recovery_box = new RecoveryBox(this);
			stack.add_titled (form_page(recovery_box), "recovery", _("Recovery"));
		}

		backend_box.type_changed.connect(()=>{
			page_filters.visible = !App.btrfs_mode;
			backup_dev_box.refresh();
			users_box.refresh();
		});

		stack.set_visible_child_name("type");

		present();

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("SettingsWindow: SettingsWindow(): exit");
    }

	/* Form pages read best at a bounded width; list pages take it all. */
	private Gtk.Widget form_page(Gtk.Widget box){
		Ui.as_page(box);
		return new ContentClamp(box);
	}

	private Gtk.Widget list_page(Gtk.Widget box){
		Ui.as_page(box);
		return box;
	}

    private bool init_delayed(){

		if (tmr_init > 0){
			Source.remove(tmr_init);
			tmr_init = 0;
		}

		backend_box.refresh();
		stack.set_visible_child_name("type");
		
		//backup_dev_box.refresh(); //will be triggered indirectly
		
		return false;
	}
	
	private bool on_delete_event(){
		
		save_changes();

		notify_closed();

		return false; // close window
	}
	
	private void save_changes(){
		
		exclude_box.save_changes();

		// the Appearance page previews live; make the choice stick
		App.save_app_config();
		

		//App.check_encrypted_home(this);

		//App.check_encrypted_private_dirs(this);
	}

}



