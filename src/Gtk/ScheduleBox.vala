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
	private Gtk.SizeGroup sg_count;

	
	private weak Gtk.Window parent_window; // back-reference: the window owns this box
	
	public ScheduleBox (Gtk.Window _parent_window) {

		log_debug("ScheduleBox: ScheduleBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: Ui.Spacing.SM); // work-around
		parent_window = _parent_window;
		
		Ui.add_title(this, _("Select Snapshot Levels"));

		Ui.add_dim_label(this, _("Snapshots are created automatically at the selected levels, and the oldest ones removed once the limit is reached."));

		levels_box = Ui.add_card(this, Gtk.Orientation.VERTICAL, Ui.Spacing.XS);

		Gtk.CheckButton chk_m, chk_w, chk_d, chk_h, chk_b = null;
		Gtk.SpinButton spin_m, spin_w, spin_d, spin_h, spin_b;

		// monthly
		
		add_schedule_option(levels_box, _("Monthly"), _("Create one per month"), out chk_m, out spin_m);

		chk_m.active = App.schedule_monthly;
		chk_m.toggled.connect(()=>{
			App.schedule_monthly = chk_m.active;
			update_statusbar();
		});

		spin_m.set_value(App.count_monthly);
		spin_m.value_changed.connect(()=>{
			App.count_monthly = (int) spin_m.get_value();
		});
		
		// weekly
		
		add_schedule_option(levels_box, _("Weekly"), _("Create one per week"), out chk_w, out spin_w);

		chk_w.active = App.schedule_weekly;
		chk_w.toggled.connect(()=>{
			App.schedule_weekly = chk_w.active;
			update_statusbar();
		});

		spin_w.set_value(App.count_weekly);
		spin_w.value_changed.connect(()=>{
			App.count_weekly = (int) spin_w.get_value();
		});

		// daily
		
		add_schedule_option(levels_box, _("Daily"), _("Create one per day"), out chk_d, out spin_d);

		chk_d.active = App.schedule_daily;
		chk_d.toggled.connect(()=>{
			App.schedule_daily = chk_d.active;
			update_statusbar();
		});

		spin_d.set_value(App.count_daily);
		spin_d.value_changed.connect(()=>{
			App.count_daily = (int) spin_d.get_value();
		});

		// hourly
		
		add_schedule_option(levels_box, _("Hourly"), _("Create one per hour"), out chk_h, out spin_h);

		chk_h.active = App.schedule_hourly;
		chk_h.toggled.connect(()=>{
			App.schedule_hourly = chk_h.active;
			update_statusbar();
		});

		spin_h.set_value(App.count_hourly);
		spin_h.value_changed.connect(()=>{
			App.count_hourly = (int) spin_h.get_value();
		});

		// boot
		
		add_schedule_option(levels_box, _("Boot"), _("Create one per boot"), out chk_b, out spin_b);

		chk_b.active = App.schedule_boot;
		chk_b.toggled.connect(()=>{
			App.schedule_boot = chk_b.active;
			update_statusbar();
		});

		spin_b.set_value(App.count_boot);
		spin_b.value_changed.connect(()=>{
			App.count_boot = (int) spin_b.get_value();
		});

		/* The "stop cron emails" checkbox used to live here.
		 *
		 * It set MAILTO="" in the /etc/cron.d drop-in Timeshift wrote. The
		 * schedule is the daemon's now and no drop-in is written, so the
		 * setting controls nothing -- and a control that does nothing is worse
		 * than a missing one, because it looks like the thing did not work.
		 *
		 * The stop_cron_emails config key is deliberately KEPT. timeshift.json
		 * is written by two programs during the transition and each drops keys
		 * it does not know, so removing it here would make it appear and vanish
		 * depending on which one saved last. It costs one line in a file and it
		 * preserves the byte-for-byte format contract. */

		// notes ----------------------------------------------------------------------

		Ui.add_bullets(this, {
			_("Snapshots are not scheduled at fixed times."),
			_("A maintenance task runs once every hour and creates snapshots as needed."),
			_("Boot snapshots are created with a delay of 10 minutes after system startup.") }, "ts-caption");

		Ui.add_spacer(this);

		// status area --------------------------------------------------------------------
		
		status_card = new StatusCard();
		append(status_card);

		update_statusbar();

		log_debug("ScheduleBox: ScheduleBox(): exit");
    }

	private void add_schedule_option(
		Gtk.Box box, string period, string period_desc,
		out Gtk.CheckButton chk, out Gtk.SpinButton spin){

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		box.append(hbox);

		if (sg_count == null){
			sg_count = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
		}
		
		chk = add_checkbox(hbox, period);
		((Gtk.Label) chk.child).add_css_class("ts-heading");
		chk.set_tooltip_text(period_desc);
		chk.hexpand = true;
		
		var tt = _("Number of snapshots to keep.\nOlder snapshots will be removed once this limit is exceeded.");
		var label = Ui.add_dim_label(hbox, _("Keep"));
		label.set_tooltip_text(tt);

		/* Deliberately always sensitive: a retention count can be set before
		 * its level is enabled. */
		var spin2 = add_spin(hbox, 1, 999, 10);
		spin2.set_tooltip_text(tt);
		sg_count.add_widget(spin2);

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

	}
}
