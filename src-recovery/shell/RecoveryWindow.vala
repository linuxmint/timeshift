/*
 * RecoveryWindow.vala
 *
 * The window, the page stack, and the services every page shares.
 *
 * Copyright 2026 makeafide <willsmit4433@gmail.com>
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
 */

/* The hub. Pages hold a reference to this and nothing else, so the only way
 * one page reaches another is through a method named here. */
public class RecoveryWindow : GLib.Object {

	public const string APP_TITLE = "Timeshift Recovery";

	public Gtk.Window window;

	private Gtk.Stack stack;
	private Modal modal;

	private HomePage home_page;
	private TerminalPage terminal_page;
	private DrivesPage drives_page;
	private NetworkPage network_page;
	private DiagnosticsPage diagnostics_page;

	private Gee.HashMap<string, Page> pages;

	// A launched app (timeshift-gtk) that owns the screen until it exits.
	private Pid child_pid = 0;
	private bool child_running = false;

	// --- construction -------------------------------------------------------

	public void build() {

		RecoveryTheme.install();

		window = new Gtk.Window();
		window.title = APP_TITLE;
		window.fullscreen();

		stack = new Gtk.Stack();
		stack.transition_type = Gtk.StackTransitionType.CROSSFADE;

		pages = new Gee.HashMap<string, Page>();

		home_page = new HomePage(this);
		terminal_page = new TerminalPage(this);
		drives_page = new DrivesPage(this);
		network_page = new NetworkPage(this);
		diagnostics_page = new DiagnosticsPage(this);

		add_page(home_page);
		add_page(terminal_page);
		add_page(drives_page);
		add_page(network_page);
		add_page(diagnostics_page);

		stack.visible_child_name = "home";

		// The modal lives above every page, so a dialog raised from the network
		// page does not vanish when the stack switches.
		var overlay = new Gtk.Overlay();
		overlay.set_child(stack);
		modal = new Modal(overlay);

		window.set_child(overlay);

		refresh_status();
	}

	private void add_page(Page page) {
		pages.set(page.key(), page);
		stack.add_named(page.build(), page.key());
	}

	// --- navigation ---------------------------------------------------------

	public void show_page(string key) {
		stack.visible_child_name = key;
		var page = pages.get(key);
		if (page != null) { page.on_shown(); }
	}

	public string current_page() {
		return stack.visible_child_name;
	}

	public void go_home() {
		stack.visible_child_name = "home";
		refresh_status();
	}

	public void refresh_status() {
		if (home_page != null) { home_page.refresh_status(); }
	}

	// --- dialogs ------------------------------------------------------------

	public void show_message(string title, string body) {
		modal.message(title, body);
	}

	public void show_confirm(string title, string body, string confirm_label,
	                         bool destructive, owned ConfirmFunc on_confirm) {
		modal.confirm(title, body, confirm_label, destructive, (owned) on_confirm);
	}

	public void show_password_prompt(string title, string body, owned PasswordFunc on_ok) {
		modal.password(title, body, (owned) on_ok);
	}

	public void show_password(string ssid, owned PasswordFunc on_ok) {
		modal.password("Connect to %s".printf(ssid),
			"Enter the network password.", (owned) on_ok);
	}

	// --- services -----------------------------------------------------------

	public void open_terminal(string title, string[] argv) {
		terminal_page.open(title, argv);
	}

	/* Fire-and-forget: reboot, poweroff. Nothing comes back from these. */
	public void launch(string command) {
		string error_message;
		if (!Sh.spawn_detached(command, out error_message)) {
			show_message("Could not start %s".printf(command), error_message);
		}
	}

	/* Hand the screen to another application until it exits.
	 *
	 * This launcher is fullscreen, so clicking it raises it over whatever it
	 * started and the other window looks like it vanished. Worse, the obvious
	 * response -- press Restore again -- starts a SECOND timeshift, which its
	 * own AppLock refuses with "Scheduled snapshot in progress", a message that
	 * has nothing to do with what happened.
	 *
	 * So hide this window while the child owns the screen, and bring it back
	 * when the child exits. Hiding also makes a second launch unreachable,
	 * which is the real cure for the lock collision. */
	public void launch_app(string command) {

		if (child_running) { return; }

		string error_message;
		Pid pid;
		if (!Sh.spawn_watched(command, out pid, out error_message)) {
			show_message("Could not start %s".printf(command), error_message);
			return;
		}

		child_pid = pid;
		child_running = true;
		home_page.set_restore_sensitive(false);

		/* The watch is what guarantees the launcher comes back. If the child
		 * dies immediately -- a stale lock, a missing dependency -- this fires
		 * at once and the user is never left staring at an empty compositor. */
		ChildWatch.add(child_pid, (watched_pid, status) => {
			GLib.Process.close_pid(watched_pid);
			child_pid = 0;
			child_running = false;
			home_page.set_restore_sensitive(true);
			refresh_status();
			window.present();

			/* status was bound and never read, so a child that died on
			 * startup -- a stale lock file, a missing dependency, an
			 * unreadable config -- put the user back on this menu with no
			 * indication that anything had gone wrong, and the obvious
			 * response was to press the same button again. */
			report_child_exit(command, status);
		});

		window.set_visible(false);
	}

	/* Turn a wait status into something worth reading. A clean exit says
	 * nothing; anything else is worth a word, because the alternative is a
	 * window that silently reappears. */
	private void report_child_exit(string command, int status) {

		if (Process.if_exited(status)) {

			int code = Process.exit_status(status);

			if (code == 0) { return; }

			show_message("%s exited with an error".printf(command),
				"Exit code %d. The session log is /tmp/timeshift-recovery-session.log.".printf(code));
			return;
		}

		if (Process.if_signaled(status)) {
			show_message("%s stopped unexpectedly".printf(command),
				"It was terminated by signal %d.".printf((int) Process.term_sig(status)));
		}
	}
}
