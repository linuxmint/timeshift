/*
 * ScheduleBox.vala
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

class ScheduleBox : Gtk.Box{
	
	private StatusCard status_card;
	private Gtk.Box levels_box;
	private Gtk.SizeGroup sg_title;
	private Gtk.SizeGroup sg_subtitle;
	private Gtk.SizeGroup sg_count;

	private Gtk.CheckButton chk_cron;
	
	private Gtk.Window parent_window;
	
	public ScheduleBox (Gtk.Window _parent_window) {

		log_debug("ScheduleBox: ScheduleBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;
		
		Ui.add_title(this, _("Select Snapshot Levels"));

		levels_box = Ui.add_card(this, Gtk.Orientation.VERTICAL, Ui.Spacing.XS);

		Gtk.CheckButton chk_m, chk_w, chk_d, chk_h, chk_b = null;
		Gtk.SpinButton spin_m, spin_w, spin_d, spin_h, spin_b;

		// monthly
		
		add_schedule_option(levels_box, _("Monthly"), _("Create one per month"), out chk_m, out spin_m);

		chk_m.active = App.schedule_monthly;
		chk_m.toggled.connect(()=>{
			App.schedule_monthly = chk_m.active;
			//spin_m.sensitive = chk_m.active;
			chk_cron.sensitive = App.scheduled;
			update_statusbar();
		});

		spin_m.set_value(App.count_monthly);
		//spin_m.sensitive = chk_m.active;
		spin_m.value_changed.connect(()=>{
			App.count_monthly = (int) spin_m.get_value();
		});
		
		// weekly
		
		add_schedule_option(levels_box, _("Weekly"), _("Create one per week"), out chk_w, out spin_w);

		chk_w.active = App.schedule_weekly;
		chk_w.toggled.connect(()=>{
			App.schedule_weekly = chk_w.active;
			//spin_w.sensitive = chk_w.active;
			chk_cron.sensitive = App.scheduled;
			update_statusbar();
		});

		spin_w.set_value(App.count_weekly);
		//spin_w.sensitive = chk_w.active;
		spin_w.value_changed.connect(()=>{
			App.count_weekly = (int) spin_w.get_value();
		});

		// daily
		
		add_schedule_option(levels_box, _("Daily"), _("Create one per day"), out chk_d, out spin_d);

		chk_d.active = App.schedule_daily;
		chk_d.toggled.connect(()=>{
			App.schedule_daily = chk_d.active;
			//spin_d.sensitive = chk_d.active;
			chk_cron.sensitive = App.scheduled;
			update_statusbar();
		});

		spin_d.set_value(App.count_daily);
		//spin_d.sensitive = chk_d.active;
		spin_d.value_changed.connect(()=>{
			App.count_daily = (int) spin_d.get_value();
		});

		// hourly
		
		add_schedule_option(levels_box, _("Hourly"), _("Create one per hour"), out chk_h, out spin_h);

		chk_h.active = App.schedule_hourly;
		chk_h.toggled.connect(()=>{
			App.schedule_hourly = chk_h.active;
			//spin_h.sensitive = chk_h.active;
			chk_cron.sensitive = App.scheduled;
			update_statusbar();
		});

		spin_h.set_value(App.count_hourly);
		//spin_h.sensitive = chk_h.active;
		spin_h.value_changed.connect(()=>{
			App.count_hourly = (int) spin_h.get_value();
		});

		// boot
		
		add_schedule_option(levels_box, _("Boot"), _("Create one per boot"), out chk_b, out spin_b);

		chk_b.active = App.schedule_boot;
		chk_b.toggled.connect(()=>{
			App.schedule_boot = chk_b.active;
			//spin_b.sensitive = chk_b.active;
			chk_cron.sensitive = App.scheduled;
			update_statusbar();
		});

		spin_b.set_value(App.count_boot);
		//spin_b.sensitive = chk_b.active;
		spin_b.value_changed.connect(()=>{
			App.count_boot = (int) spin_b.get_value();
		});

		// cron emails --------------------------------------------------------------------
		
		chk_cron = add_checkbox(this, _("Stop cron emails for scheduled tasks"));
		chk_cron.set_tooltip_text(_("The cron service sends the output of scheduled tasks as an email to the current user. Select this option to suppress the emails for cron tasks created by Timeshift."));
		chk_cron.margin_top = Ui.Spacing.XS;
		
		chk_cron.active = App.stop_cron_emails;
		chk_cron.toggled.connect(()=>{
			App.stop_cron_emails = chk_cron.active;
		});

		// notes ----------------------------------------------------------------------

		var notes = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.XS / 2);
		notes.margin_top = Ui.Spacing.XS;
		append(notes);

		foreach (string line in new string[]{
			_("Snapshots are not scheduled at fixed times."),
			_("A maintenance task runs once every hour and creates snapshots as needed."),
			_("Boot snapshots are created with a delay of 10 minutes after system startup.") }){
			Ui.add_caption(notes, "• " + line);
		}

		Ui.add_spacer(this);

		// status area --------------------------------------------------------------------
		
		status_card = new StatusCard();
		status_card.margin_top = Ui.Spacing.XS;
		append(status_card);

		update_statusbar();

		log_debug("ScheduleBox: ScheduleBox(): exit");
    }

	private void add_schedule_option(
		Gtk.Box box, string period, string period_desc,
		out Gtk.CheckButton chk, out Gtk.SpinButton spin){

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		box.append(hbox);

		if (sg_title == null){
			sg_title = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
			sg_subtitle = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
			sg_count = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
		}
		
		chk = add_checkbox(hbox, period);
		((Gtk.Label) chk.child).add_css_class("ts-heading");
		chk.set_tooltip_text(period_desc);
		chk.hexpand = true;
		sg_title.add_widget(chk);
		
		var tt = _("Number of snapshots to keep.\nOlder snapshots will be removed once this limit is exceeded.");
		var label = Ui.add_dim_label(hbox, _("Keep"));
		label.set_tooltip_text(tt);

		var spin2 = add_spin(hbox, 1, 999, 10);
		spin2.set_tooltip_text(tt);
		sg_count.add_widget(spin2);
		
		spin2.notify["sensitive"].connect(()=>{
			label.sensitive = spin2.sensitive;
		});

		spin = spin2;
	}

	public void update_statusbar(){
		
		if (App.schedule_monthly || App.schedule_weekly || App.schedule_daily
			|| App.schedule_hourly || App.schedule_boot){

			status_card.set_shield(IconManager.SHIELD_HIGH);
			status_card.set_title(_("Scheduled snapshots are enabled"));
			status_card.set_subtitle(_("Snapshots will be created at selected intervals if snapshot disk has enough space (> 1 GB)"));
		}
		else{
			status_card.set_shield(IconManager.SHIELD_LOW);
			status_card.set_title(_("Scheduled snapshots are disabled"));
			status_card.set_subtitle(_("Select the intervals for creating snapshots"));
		}

		chk_cron.sensitive = App.scheduled;
	}
}
