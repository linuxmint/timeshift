/*
 * AppearanceBox.vala
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
 */

using Gtk;
using Gee;

using TeeJee.Logging;
using TeeJee.GtkHelper;

/* Settings > Appearance: Theme (System / Light / Dark) and Accent (System or a
 * preset). Changes preview immediately through AppTheme and are persisted by
 * SettingsWindow when it closes. */

class AppearanceBox : Gtk.Box {

	private Gtk.Window parent_window;

	private Gtk.DropDown dd_mode;
	private Gee.HashMap<string, Gtk.ToggleButton> swatches;
	private bool updating = false;

	private const string[] MODES = { "system", "light", "dark" };

	public AppearanceBox(Gtk.Window _parent_window){

		log_debug("AppearanceBox: AppearanceBox()");

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: ThemeStyle.SPACE_L);
		parent_window = _parent_window;

		swatches = new Gee.HashMap<string, Gtk.ToggleButton>();

		init_theme_option();

		init_accent_option();

		refresh();

		log_debug("AppearanceBox: AppearanceBox(): exit");
	}

	private void init_theme_option(){

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, ThemeStyle.SPACE_XS);
		append(box);

		Ui.add_heading(box, _("Theme"));

		Ui.add_dim_label(box, _("Follow the desktop's light or dark setting, or choose one for Timeshift."));

		var names = new Gtk.StringList({ _("System"), _("Light"), _("Dark") });

		dd_mode = new Gtk.DropDown(names, null);
		dd_mode.halign = Gtk.Align.START;
		dd_mode.margin_top = ThemeStyle.SPACE_XS;
		box.append(dd_mode);

		dd_mode.notify["selected"].connect(() => {
			if (updating){ return; }
			uint idx = dd_mode.selected;
			if (idx >= MODES.length){ idx = 0; }
			App.theme_mode = MODES[idx];
			AppTheme.set_preferences(App.theme_mode, App.theme_accent);
		});
	}

	private void init_accent_option(){

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, ThemeStyle.SPACE_XS);
		append(box);

		Ui.add_heading(box, _("Accent Colour"));

		Ui.add_dim_label(box, _("Used for status highlights and messages. System follows the desktop's accent where it reports one."));

		var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, ThemeStyle.SPACE_XS);
		row.margin_top = ThemeStyle.SPACE_XS;
		box.append(row);

		Gtk.ToggleButton? group = null;

		group = add_swatch(row, "system", _("System"), group);

		foreach (var preset in ThemeStyle.presets()){
			add_swatch(row, preset.key, ThemeStyle.preset_label(preset.key), group);
		}
	}

	private Gtk.ToggleButton add_swatch(Gtk.Box row, string key, string tooltip, Gtk.ToggleButton? group){

		var btn = new Gtk.ToggleButton();
		btn.add_css_class("ts-swatch");
		btn.add_css_class(key);
		btn.tooltip_text = tooltip;
		btn.valign = Gtk.Align.CENTER;

		var img = new Gtk.Image.from_icon_name("object-select-symbolic");
		btn.set_child(img);
		btn.notify["active"].connect(() => { img.visible = btn.active; });
		img.visible = false;

		if (group != null){ btn.set_group(group); }

		row.append(btn);
		swatches[key] = btn;

		btn.toggled.connect(() => {
			if (updating || !btn.active){ return; }
			App.theme_accent = key;
			AppTheme.set_preferences(App.theme_mode, App.theme_accent);
		});

		return btn;
	}

	/* Sync widgets from App.*; used on open. */
	public void refresh(){

		updating = true;

		uint idx = 0;
		for (uint i = 0; i < MODES.length; i++){
			if (MODES[i] == App.theme_mode){ idx = i; }
		}
		dd_mode.selected = idx;

		string accent = App.theme_accent;
		if (!swatches.has_key(accent)){ accent = "system"; }
		swatches[accent].active = true;

		updating = false;
	}
}
