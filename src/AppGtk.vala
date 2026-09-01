/*
 * AptikGtk.vala
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

using GLib;
using Gtk;
using Gee;
using Json;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

public Main App;
public const string AppName = "Timeshift-gtk";
public const string AppShortName = "timeshift";
public const string AppVersion = Constants.VERSION;
public const string AppAuthor = "Tony George";
public const string AppAuthorEmail = "teejeetech@gmail.com";

/* Must match meson's -DGETTEXT_PACKAGE and the installed .mo basename.
 * An empty string here silently overrode meson's define, so every _() call
 * became g_dgettext("", ...) and none of the 74 shipped translations were ever
 * loaded. */
const string GETTEXT_PACKAGE = "timeshift";
const string LOCALE_DIR = "/usr/share/locale";

extern void exit(int exit_code);

public class AppGtk : GLib.Object {

	public static int main (string[] args) {
		
		set_locale();
		
		if (args.length > 1) {
			switch (args[1].down()) {
				case "--help":
				case "--h":
				case "-h":
					stdout.printf (help_message ());
					return 0;

				case "--version":
					stdout.printf (version_message ());
					return 0;
			}
		}

		/* A diagnostic, before anything else needs to work.
		 *
		 * It talks to the daemon and returns; it opens no window, constructs no
		 * Main, and touches nothing. Placed here so it still answers on a
		 * machine where the GUI itself will not start -- which is when someone
		 * is most likely to want to know whether the socket is healthy.
		 *
		 * An environment variable rather than a flag: parse_arguments() rejects
		 * anything it does not know, and adding a flag would put a developer
		 * diagnostic in --help and so in the man page. */
		if (GLib.Environment.get_variable("TIMESHIFT_IPC_SELFTEST") == "1"){
			return DaemonApi.selftest();
		}

		Main.setup_env();

		Gtk.init();

		GTK_INITIALIZED = true;

		/* --debug is parsed properly further down, but AppTheme and IconManager
		 * both run before that, so pick the flag up early or their tracing is
		 * silently dropped. */
		foreach (string arg in args){
			if (arg.down() == "--debug"){ LOG_DEBUG = true; }
		}

		/* Adopt the desktop user's light/dark preference before anything is
		 * built -- notably before IconManager.init(), so icons resolve against
		 * the right theme first time. */
		AppTheme.apply();

		init_tmp();

		check_if_admin();

		App = new Main(args, true);
		parse_arguments(args);

		/* The config is loaded by the Main constructor, so the in-app Theme /
		 * Accent choice can be layered on before any window exists. */
		AppTheme.set_preferences(App.theme_mode, App.theme_accent);

		App.initialize();
		start_application();

		App.exit_app();

		return 0;
	}

	private static void set_locale() {
		
		log_debug("setting locale...");
		Intl.setlocale(GLib.LocaleCategory.ALL, ""); // adopt the environment's locale
		Intl.textdomain(GETTEXT_PACKAGE);
		Intl.bind_textdomain_codeset(GETTEXT_PACKAGE, "utf-8");
		Intl.bindtextdomain(GETTEXT_PACKAGE, LOCALE_DIR);
	}

	public static bool parse_arguments(string[] args) {
		
		//parse options
		for (int k = 1; k < args.length; k++) // Oth arg is app path
		{
			switch (args[k].down()) {
			case "--debug":
				LOG_DEBUG = true;
				break;
			default:
				//unknown option - show help and exit
				log_error(_("Unknown option") + ": %s".printf(args[k]));
				log_msg(help_message());
				App.exit_app(1);
				return false;
			}
		}

		return true;
	}

	private static string version_message (){
		string msg = "%s %s\n".printf( AppName, AppVersion);
		return msg;
	}

	public static string help_message() {
		
		string msg = "\n%s v%s by Tony George (%s)\n".printf(AppName, AppVersion, AppAuthorEmail);
		msg += "\n";
		msg += _("Syntax") + ": timeshift-gtk [options]\n";
		msg += "\n";
		msg += _("Options") + ":\n";
		msg += "\n";
		msg += "  --debug      " + _("Print debug information") + "\n";
		msg += "  --h[elp]     " + _("Show all options") + "\n";
		msg += "  --version    " + _("Print version number") + "\n";
		msg += "\n\n";
		msg += "\n%s\n".printf(_("Run 'timeshift' for the command-line version of this tool"));
		return msg;
	}

	public static void check_if_admin(){
		
		if (!user_is_admin()){
			
			var msg = _("Admin access is required to backup and restore system files.") + "\n";
			msg += _("Please re-run the application as admin (using 'sudo' or 'su')");

			log_error(msg);

			string title = _("Admin Access Required");
			gtk_messagebox(title, msg, null, true);

			exit(1);
		}
	}

	public static void start_application(){

		/* GTK4 removes gtk_main()/gtk_main_quit(). This app runs as root under
		 * pkexec where a session bus may be absent, so drive a plain GLib main
		 * loop rather than introducing GtkApplication.
		 *
		 * Note that single-instance is deliberately NOT enforced any more.
		 * AppLock used to refuse a second process, which is exactly why a
		 * backup started by apt-snapshot-guard could not be watched. Two
		 * windows are fine; RepoLock stops them writing the repository at the
		 * same time. */

		// window icons are looked up by name in GTK4
		Gtk.Window.set_default_icon_name("timeshift");

		var loop = new GLib.MainLoop();

		// show main window
		var window = new MainWindow ();
		window.closed.connect(() => {
			if (loop.is_running()){ loop.quit(); }
		});
		window.present();

		// start event loop
		loop.run();
	}
}

