/*
 * AppTheme.vala
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

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.ProcessHelper;

/* Vala marks the whole Gtk.StyleContext class deprecated, but in GTK4 only its
 * instance methods are -- gtk_style_context_add_provider_for_display() is still
 * the supported way to register a provider, so bind it directly. */
[CCode (cname = "gtk_style_context_add_provider_for_display")]
extern void style_context_add_provider_for_display(Gdk.Display display, Gtk.StyleProvider provider, uint priority);

/* The app's theme controller: owns the single CSS provider and keeps it in
 * step with the desktop, live.
 *
 * The GUI always runs as root through pkexec, which resets the environment and
 * points HOME at /root. Root's own gsettings are untouched defaults, so without
 * this the app renders the *root* account's light preference no matter what the
 * person at the keyboard has chosen. The desktop user's preference is read from
 * the settings portal (Main.setup_env() copies their session bus address), or
 * failing that from their dconf database. Live changes arrive either through
 * the portal's SettingChanged signal or -- because a session bus frequently
 * refuses a root connection, in which case the portal is never reachable --
 * through a file monitor on the user's dconf database, re-reading the keys
 * whenever it is rewritten. Either way a switch in the desktop's appearance
 * settings is reflected without a restart.
 *
 * Two stages, because the config that carries the user's in-app choice is only
 * loaded by the Main constructor:
 *
 *   apply()             right after Gtk.init(): system values, provider
 *                       installed, subscription live
 *   set_preferences()   after `new Main()`: the in-app Theme / Accent choice
 *                       layered on top; also called by the Appearance page
 *
 * The provider sits at STYLE_PROVIDER_PRIORITY_APPLICATION: above the GTK
 * theme, so the app's own .ts-* rules win, but below ~/.config/gtk-4.0/gtk.css,
 * so a person's personal overrides still beat ours. */

public class AppTheme : GLib.Object {

	public enum Mode {
		SYSTEM,
		LIGHT,
		DARK
	}

	// resolved state, read-only for the rest of the app --------------

	public static bool prefer_dark { get; private set; default = false; }
	public static string accent_key { get; private set; default = ThemeStyle.DEFAULT_ACCENT; }
	public static bool high_contrast { get; private set; default = false; }

	// system-reported --------------------------------------------------

	private static bool system_dark = false;
	private static string? system_accent = null;   // null: portal has no accent
	private static bool system_high_contrast = false;

	// user preferences (timeshift.json) --------------------------------

	private static Mode pref_mode = Mode.SYSTEM;
	private static string pref_accent = "system";

	// plumbing ---------------------------------------------------------

	private static Gtk.CssProvider? provider = null;
	private static Gtk.Settings? gtk_settings = null;
	private static GLib.DBusConnection? bus = null;   // held: the subscription dies with it
	private static uint bus_sub_id = 0;
	private static bool applying = false;
	private static bool css_loaded = false;
	private static bool last_dark = false;
	private static string last_accent = "";
	private static bool last_hc = false;

	private static string? user_gtk_theme = null;
	private static string? user_icon_theme = null;

	// gsettings fallback: what to re-read, and the watch that triggers it
	private static string gsettings_prefix = "";
	private static string? dconf_db_path = null;
	private static GLib.FileMonitor? dconf_monitor = null;
	private static uint dconf_timer = 0;

	/* Vala has no static signals; the default instance carries `changed` so
	 * widgets (the accent swatches, for one) can follow re-applies. */
	public signal void changed();

	private static AppTheme? _default = null;

	public static AppTheme get_default(){
		if (_default == null){ _default = new AppTheme(); }
		return _default;
	}

	// stage 1 ----------------------------------------------------------

	public static void apply(){

		/* Static field initializers only run in class_init, and nothing has
		 * instantiated this class yet -- force it, or every static string
		 * below is still NULL. */
		get_default();

		var display = Gdk.Display.get_default();
		if (display == null){ return; }

		/* The user's environment (dconf path, theme names) is needed on every
		 * path: the dconf watch is the live channel when the bus refuses root,
		 * and the icon theme matters whether or not the portal answered. */
		read_user_env();

		bool found = read_from_portal();

		if (!found){
			read_appearance_gsettings();
		}

		gtk_settings = Gtk.Settings.get_for_display(display);

		/* Theme-name writes below must stay BEFORE subscribe(): its
		 * notify::gtk-theme-name handler would otherwise see our own
		 * assignment. */
		if (gtk_settings != null){

			/* Adopting the user's icon theme matters beyond looks: Yaru carries
			 * symbolic names Adwaita does not, so icons resolve through the
			 * theme (and therefore recolour) instead of falling back to a
			 * bundled file. */
			if ((user_icon_theme != null) && dir_exists("/usr/share/icons/" + user_icon_theme)){
				gtk_settings.gtk_icon_theme_name = user_icon_theme;
				log_debug("AppTheme: icon theme: %s".printf(user_icon_theme));
			}

			if (user_gtk_theme != null){
				bool implies_dark;
				string name = normalise_theme_name(user_gtk_theme, out implies_dark);
				if (dir_exists("/usr/share/themes/" + name)){
					gtk_settings.gtk_theme_name = name;
					log_debug("AppTheme: gtk theme: %s".printf(name));
				}
				else if (dir_exists("/usr/share/themes/" + user_gtk_theme)){
					// no light variant exists; the widget theme stays dark
					// whatever the preference says, so say so once
					gtk_settings.gtk_theme_name = user_gtk_theme;
					log_msg("AppTheme: theme '%s' has no light variant, the Light setting affects only Timeshift's own surfaces".printf(user_gtk_theme));
				}
				if (implies_dark && !found){ system_dark = true; }
			}
		}

		string? env_theme = GLib.Environment.get_variable("GTK_THEME");
		if ((env_theme != null) && (env_theme.length > 0)){
			log_msg("AppTheme: GTK_THEME=%s overrides the widget theme; the Theme setting affects only Timeshift's own surfaces".printf(env_theme));
		}

		install_provider(display);

		subscribe(display);

		refresh();
	}

	// stage 2 ----------------------------------------------------------

	public static void set_preferences(string mode, string accent){

		get_default();

		pref_mode = parse_mode(mode);
		pref_accent = (accent == null) ? "system" : accent;

		refresh();
	}

	public static Mode parse_mode(string s){

		switch (s.down()){
		case "light": return Mode.LIGHT;
		case "dark":  return Mode.DARK;
		default:      return Mode.SYSTEM;
		}
	}

	public static string mode_to_string(Mode m){

		switch (m){
		case Mode.LIGHT: return "light";
		case Mode.DARK:  return "dark";
		default:         return "system";
		}
	}

	// core -------------------------------------------------------------

	private static void install_provider(Gdk.Display display){

		if (provider != null){ return; }

		provider = new Gtk.CssProvider();

		// CSS mistakes are otherwise silent
		provider.parsing_error.connect((section, error) => {
			log_error("AppTheme: css: %s (%s)".printf(error.message, section.to_string()));
		});

		style_context_add_provider_for_display(display, provider,
			Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
	}

	private static void refresh(){

		bool dark = (pref_mode == Mode.DARK)
			|| ((pref_mode == Mode.SYSTEM) && system_dark);

		string accent = (pref_accent == null) ? "system" : pref_accent;
		if ((accent == "system") || (accent.length == 0)){
			accent = (system_accent == null) ? ThemeStyle.DEFAULT_ACCENT : system_accent;
		}
		if (ThemeStyle.preset_by_key(accent) == null){
			accent = ThemeStyle.DEFAULT_ACCENT;
		}

		bool hc = system_high_contrast;

		// repeated portal signals must not trigger a full restyle
		if (css_loaded && (dark == last_dark) && (accent == last_accent) && (hc == last_hc)){ return; }

		if (provider != null){
			var palette = ThemeStyle.resolve(dark, accent, hc);
			provider.load_from_string(ThemeStyle.build_css(palette, hc, system_accent));
			css_loaded = true;
		}

		// recorded only once applied, so a display-less run cannot lie
		prefer_dark = dark;
		accent_key = accent;
		high_contrast = hc;
		last_dark = dark;
		last_accent = accent;
		last_hc = hc;

		if (gtk_settings != null){
			applying = true;
			gtk_settings.gtk_application_prefer_dark_theme = dark;
			applying = false;
		}

		log_debug("AppTheme: css reloaded dark=%s accent=%s hc=%s".printf(dark.to_string(), accent, hc.to_string()));

		get_default().changed();
	}

	// desktop preference: portal ---------------------------------------

	private static bool read_from_portal(){

		/* org.freedesktop.appearance:
		 *   color-scheme (u): 0 = no preference, 1 = prefer dark, 2 = prefer light
		 *   accent-color (ddd): GNOME 47+ / KDE 6, absent elsewhere
		 *
		 * setup_env() copies the user's DBUS_SESSION_BUS_ADDRESS, so root can
		 * reach their bus. Desktop-agnostic: GNOME, KDE and Cinnamon answer. */

		try {
			bus = GLib.Bus.get_sync(GLib.BusType.SESSION, null);

			var reply = bus.call_sync(
				"org.freedesktop.portal.Desktop",
				"/org/freedesktop/portal/desktop",
				"org.freedesktop.portal.Settings",
				"ReadAll",
				/* Built explicitly: g_variant_new("(as)", ...) wants a
				 * GVariantBuilder, not a string array, and handing it one
				 * aborts the process the moment a session bus answers. */
				new GLib.Variant.tuple({
					new GLib.Variant.strv({ "org.freedesktop.appearance" })
				}),
				new GLib.VariantType("(a{sa{sv}})"),
				GLib.DBusCallFlags.NONE,
				2000,
				null);

			bool found = false;

			var namespaces = reply.get_child_value(0);
			for (size_t i = 0; i < namespaces.n_children(); i++){
				var entry = namespaces.get_child_value(i);
				var keys = entry.get_child_value(1);
				for (size_t k = 0; k < keys.n_children(); k++){
					var kv = keys.get_child_value(k);
					string key = kv.get_child_value(0).get_string();
					var val = kv.get_child_value(1).get_variant();
					if (handle_setting(key, val)){ found = true; }
				}
			}

			if (!found){
				log_debug("AppTheme: portal answered but reported nothing under org.freedesktop.appearance");
			}

			return found;
		}
		catch (Error e) {
			log_debug("AppTheme: portal unavailable: %s".printf(e.message));
			return false;
		}
	}

	/* Applies one appearance key to the system_* state. Returns true if the key
	 * was one this app understands. */
	private static bool handle_setting(string key, GLib.Variant v){

		if (key == "color-scheme"){
			if (!v.is_of_type(GLib.VariantType.UINT32)){ return false; }
			uint32 scheme = v.get_uint32();
			system_dark = (scheme == 1);
			log_debug("AppTheme: portal color-scheme: %u".printf(scheme));
			return true;
		}

		if (key == "contrast"){
			if (!v.is_of_type(GLib.VariantType.UINT32)){ return false; }
			system_high_contrast = (v.get_uint32() == 1);
			log_debug("AppTheme: portal contrast: %u".printf(v.get_uint32()));
			return true;
		}

		if (key == "accent-color"){
			if (!v.is_of_type(new GLib.VariantType("(ddd)"))){ return false; }
			double r, g, b;
			v.get("(ddd)", out r, out g, out b);
			system_accent = ThemeStyle.nearest_preset(r, g, b);
			log_debug("AppTheme: portal accent-color: (%.2f,%.2f,%.2f) -> %s".printf(r, g, b, system_accent));
			return true;
		}

		return false;
	}

	private static void subscribe(Gdk.Display display){

		if (bus != null){
			{
				bus_sub_id = bus.signal_subscribe(
					"org.freedesktop.portal.Desktop",
					"org.freedesktop.portal.Settings",
					"SettingChanged",
					"/org/freedesktop/portal/desktop",
					"org.freedesktop.appearance",   // arg0 filter: namespace
					GLib.DBusSignalFlags.NONE,
					on_portal_signal);

				log_debug("AppTheme: subscribed to portal SettingChanged");
			}
		}
		else {
			log_debug("AppTheme: no session bus for the portal");
		}

		if (bus_sub_id == 0){
			watch_dconf();
		}

		/* Fallback for desktops without the portal: GTK's own settings still
		 * follow XSettings / the compositor, so watch those when the portal
		 * is not there to be authoritative. */
		if (gtk_settings != null){

			gtk_settings.notify["gtk-application-prefer-dark-theme"].connect(() => {
				if (applying || (bus_sub_id != 0)){ return; }
				system_dark = gtk_settings.gtk_application_prefer_dark_theme;
				refresh();
			});

			gtk_settings.notify["gtk-theme-name"].connect(() => {
				if (applying || (bus_sub_id != 0)){ return; }
				// a "-dark" name can only add darkness; a plain name says
				// nothing about the colour-scheme preference
				bool implies_dark;
				normalise_theme_name(gtk_settings.gtk_theme_name, out implies_dark);
				if (implies_dark && !system_dark){
					system_dark = true;
					refresh();
				}
			});
		}
	}

	private static void on_portal_signal(GLib.DBusConnection conn, string? sender,
		string path, string iface, string signame, GLib.Variant params){

		// signature (ssv): namespace, key, value
		if (!params.is_of_type(new GLib.VariantType("(ssv)"))){ return; }

		string ns, key;
		GLib.Variant v;
		params.get("(ssv)", out ns, out key, out v);

		if (ns != "org.freedesktop.appearance"){ return; }

		log_debug("AppTheme: SettingChanged %s".printf(key));

		// the callback already runs on the main context, so GTK is safe here
		if (handle_setting(key, v)){
			refresh();
		}
	}

	// desktop preference: gsettings fallback ---------------------------

	/* Locates the desktop user's dconf database and reads their theme names.
	 * Reads the database by pointing HOME and the session bus at theirs --
	 * deliberately NOT via exec_user_async(), which shells out through pkexec
	 * and would raise an auth prompt at startup. */
	private static void read_user_env(){

		int uid = TeeJee.System.get_user_id();
		if (uid <= 0){ return; }

		unowned Posix.Passwd? pw = Posix.getpwuid(uid);
		if (pw == null){ return; }

		string home = pw.pw_dir;
		string runtime = "/run/user/%d".printf(uid);

		string bus_addr = GLib.Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
		if ((bus_addr == null) || (bus_addr.length == 0)){
			bus_addr = "unix:path=%s/bus".printf(runtime);
		}

		string prefix = "env HOME='%s' XDG_RUNTIME_DIR='%s' DBUS_SESSION_BUS_ADDRESS='%s' ".printf(
			escape_single_quote(home),
			escape_single_quote(runtime),
			escape_single_quote(bus_addr));

		gsettings_prefix = prefix;
		dconf_db_path = home + "/.config/dconf/user";

		user_gtk_theme = read_gsetting(prefix, "gtk-theme");
		user_icon_theme = read_gsetting(prefix, "icon-theme");

		if (user_gtk_theme.length == 0){ user_gtk_theme = null; }
		if (user_icon_theme.length == 0){ user_icon_theme = null; }
	}

	/* The keys that change at runtime; also re-read by the dconf watch. */
	private static void read_appearance_gsettings(){

		if (gsettings_prefix.length == 0){ return; }

		string scheme = read_gsetting(gsettings_prefix, "color-scheme");
		system_dark = (scheme == "prefer-dark");

		string accent = read_gsetting(gsettings_prefix, "accent-color");
		if ((accent.length > 0) && (ThemeStyle.preset_by_key(accent) != null)){
			system_accent = accent;
		}

		string hc = read_gsetting(gsettings_prefix, "high-contrast", "org.gnome.desktop.a11y.interface");
		system_high_contrast = (hc == "true");

		log_debug("AppTheme: user gsettings color-scheme: %s accent-color: %s high-contrast: %s".printf(scheme, accent, hc));
	}

	/* Live channel that works as root: dconf rewrites its database file on
	 * every change (atomically, by rename), so a monitor on that path sees the
	 * desktop's appearance settings change even though the bus that would
	 * carry the notification refuses us. Debounced, since one change produces
	 * a burst of events. */
	private static void watch_dconf(){

		if ((dconf_db_path == null) || (dconf_monitor != null)){ return; }

		try {
			var file = GLib.File.new_for_path(dconf_db_path);
			dconf_monitor = file.monitor_file(GLib.FileMonitorFlags.NONE, null);

			dconf_monitor.changed.connect((src, dest, event) => {
				if ((event != GLib.FileMonitorEvent.CHANGED)
					&& (event != GLib.FileMonitorEvent.CREATED)
					&& (event != GLib.FileMonitorEvent.CHANGES_DONE_HINT)){ return; }

				if (dconf_timer != 0){ GLib.Source.remove(dconf_timer); }
				dconf_timer = GLib.Timeout.add(300, () => {

					/* read_appearance_gsettings() spawns gsettings and blocks.
					 * This timer fires from any main-context iteration --
					 * including the gtk_do_events() inside a backup/restore
					 * progress loop and inside a modal dialog's nested loop --
					 * so defer rather than stall the UI mid-operation. */
					if (busy()){ return true; } // check again on the next tick

					dconf_timer = 0;
					read_appearance_gsettings();
					refresh();
					return false;
				});
			});

			log_debug("AppTheme: watching %s for live changes".printf(dconf_db_path));
		}
		catch (Error e) {
			log_debug("AppTheme: cannot watch dconf: %s".printf(e.message));
		}
	}

	/* True while the app is doing work that pumps the main loop itself. */
	private static bool busy(){

		if (App == null){ return false; }

		return App.thread_delete_running
			|| ((App.task != null) && (App.task.status == AppStatus.RUNNING));
	}

	private static string read_gsetting(string prefix, string key, string schema = "org.gnome.desktop.interface"){

		string std_out, std_err;

		int status = exec_sync(
			prefix + "gsettings get " + schema + " " + key,
			out std_out, out std_err);

		if ((status != 0) || (std_out == null)){ return ""; }

		/* gsettings quotes its output: 'prefer-dark' */
		return std_out.strip().replace("'", "");
	}

	/* "Yaru-dark" -> "Yaru" (implies_dark = true). A theme whose name carries
	 * the variant is permanently dark under GTK4; stripping it lets
	 * gtk-application-prefer-dark-theme choose gtk.css vs gtk-dark.css. */
	private static string normalise_theme_name(string name, out bool implies_dark){

		implies_dark = false;

		foreach (string suffix in new string[]{ "-dark", "-Dark" }){
			if (name.has_suffix(suffix)){
				implies_dark = true;
				return name.substring(0, name.length - suffix.length);
			}
		}

		return name;
	}
}
