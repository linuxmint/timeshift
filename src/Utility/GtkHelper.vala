

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.System;
using TeeJee.Misc;

namespace TeeJee.GtkHelper{

	using Gtk;

	// main loop -----------

	public void gtk_do_events (){

		/* Do pending events.
		 *
		 * GTK4 removes gtk_events_pending()/gtk_main_iteration(). The GLib main
		 * context underneath them is unchanged, so drive it directly. The core
		 * runs long operations on a worker thread and spins here to keep the UI
		 * alive, so this has to stay synchronous. */

		var context = GLib.MainContext.default();

		while (context.pending()){
			context.iteration(false);
		}
	}

	public void gtk_set_busy (bool busy, Gtk.Window win) {

		/* Show or hide busy cursor on window */

		win.set_cursor(new Gdk.Cursor.from_name(busy ? "wait" : "default", null));

		gtk_do_events ();
	}

	public void set_margin_all (Gtk.Widget widget, int margin){

		/* GTK4 has no "margin" shorthand; only the four edges. */

		widget.margin_start = margin;
		widget.margin_end = margin;
		widget.margin_top = margin;
		widget.margin_bottom = margin;
	}

	// messages -----------

	public static void gtk_messagebox(string title, string message, Gtk.Window? parent_win, bool is_error = false){

		/* Shows a simple message box */

		Gtk.MessageType type = is_error ? Gtk.MessageType.ERROR : Gtk.MessageType.INFO;

		var dlg = new CustomMessageDialog(title, message, type, parent_win, Gtk.ButtonsType.OK);
		dlg.run();
	}

	public string? gtk_inputbox(string title, string message, Gtk.Window? parent_win, bool mask_password = false){

		/* Shows a simple input prompt.
		 *
		 * Callers (the LUKS passphrase prompt in Device.vala, for one) are
		 * synchronous core code, so this blocks on a nested main loop rather
		 * than returning a value asynchronously. */

		var dlg = new Gtk.Window();
		dlg.title = title;
		dlg.set_default_size(420, -1);
		dlg.modal = true;
		dlg.resizable = false;
		if (parent_win != null){
			dlg.set_transient_for(parent_win);
		}

		// same chrome as CustomMessageDialog: flat header, title in the body
		var hb = new Gtk.HeaderBar();
		hb.add_css_class("flat");
		hb.title_widget = new Gtk.Label("");
		dlg.set_titlebar(hb);

		var vbox_main = new Gtk.Box(Orientation.VERTICAL, Ui.Spacing.SM);
		set_margin_all(vbox_main, Ui.Spacing.LG);
		vbox_main.margin_top = Ui.Spacing.SM;
		dlg.set_child(vbox_main);

		Ui.add_title(vbox_main, title, 2);

		var lbl_input = Ui.add_body(vbox_main, message);

		var txt_input = new Gtk.Entry();
		txt_input.hexpand = true;
		txt_input.set_visibility(!mask_password);
		txt_input.activates_default = true;
		vbox_main.append(txt_input);

		var bbox = Ui.add_button_row(vbox_main, Gtk.Align.END);
		bbox.margin_top = Ui.Spacing.XS;

		var btn_cancel = new Gtk.Button.with_label(_("Cancel"));
		bbox.append(btn_cancel);

		var btn_ok = new Gtk.Button.with_label(_("OK"));
		btn_ok.add_css_class("suggested-action");
		bbox.append(btn_ok);

		string? input_text = null;
		var loop = new GLib.MainLoop();

		/* Quit the nested loop explicitly at each exit. Hanging this off
		 * Gtk.Widget::destroy would never fire: GTK4 emits that from dispose,
		 * so a held reference keeps it from ever arriving and this prompt --
		 * the LUKS passphrase one, among others -- would block forever. */
		btn_ok.clicked.connect(() => {
			input_text = txt_input.text;
			dlg.destroy();
			if (loop.is_running()){ loop.quit(); }
		});

		btn_cancel.clicked.connect(() => {
			input_text = null;
			dlg.destroy();
			if (loop.is_running()){ loop.quit(); }
		});

		txt_input.activate.connect(() => {
			input_text = txt_input.text;
			dlg.destroy();
			if (loop.is_running()){ loop.quit(); }
		});

		dlg.close_request.connect(() => {
			input_text = null;
			if (loop.is_running()){ loop.quit(); }
			return false;
		});

		dlg.present();
		txt_input.grab_focus();

		loop.run();

		return input_text;
	}

	public void gtk_wait(int milliseconds){

		/* Pump the main loop for a while so a finished page stays readable
		 * before its window closes. The caller closes the window itself --
		 * destroying it here would skip the AppWindow.closed notification. */

		gtk_do_events();

		int millis = 0;
		while(millis < milliseconds){
			sleep(200);
			millis += 200;
			gtk_do_events();
		}
	}

	// utility ------------------

	// add_label_scrolled
	public static Gtk.Label add_label_scrolled(Gtk.Box box, string text, bool show_border = false, bool wrap = false, int ellipsize_chars = 40){

		// ScrolledWindow
		var scroll = new Gtk.ScrolledWindow();
		scroll.hscrollbar_policy = PolicyType.NEVER;
		scroll.vscrollbar_policy = PolicyType.ALWAYS;
		scroll.hexpand = true;
		scroll.vexpand = true;
		scroll.has_frame = show_border;
		box.append(scroll);

		var label = new Gtk.Label(text);
		label.xalign = (float) 0.0;
		label.yalign = (float) 0.0;
		set_margin_all(label, 6);
		label.set_use_markup(true);
		scroll.set_child(label);

		if (wrap){
			label.wrap = true;
			label.wrap_mode = Pango.WrapMode.WORD;
		}
		else {
			label.wrap = false;
			label.ellipsize = Pango.EllipsizeMode.MIDDLE;
			label.max_width_chars = ellipsize_chars;
		}

		return label;
	}

	// add_label: plain text. Styling is a .ts-* class (see Ui), never markup.
	public static Gtk.Label add_label(Gtk.Box box, string text){

		var label = new Gtk.Label(text);
		label.xalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD;
		box.append(label);
		return label;
	}

	// add_label_markup: explicit opt-in for text that really is Pango markup
	public static Gtk.Label add_label_markup(Gtk.Box box, string markup){

		var label = new Gtk.Label(markup);
		label.set_use_markup(true);
		label.xalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD;
		box.append(label);
		return label;
	}

	// add_checkbox
	public static Gtk.CheckButton add_checkbox(Gtk.Box box, string text){

		/* GTK4's CheckButton is no longer a Gtk.Bin wrapping a Label, so the
		 * markup-capable label is attached explicitly as its child. */

		var chk = new Gtk.CheckButton();

		var label = new Gtk.Label(text);
		label.use_markup = true;
		label.xalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD;
		chk.set_child(label);

		box.append(chk);

		return chk;
	}

	// add_spin
	public static Gtk.SpinButton add_spin(Gtk.Box box, double min, double max, double val, int digits = 0, double step = 1, double step_page = 1){

		var adj = new Gtk.Adjustment(val, min, max, step, step_page, 0);
		var spin  = new Gtk.SpinButton(adj, step, digits);
		spin.xalign = (float) 0.5;
		box.append(spin);

		return spin;
	}

	// add_button
	public static Gtk.Button add_button(Gtk.Box box, string text, string tooltip, Gtk.SizeGroup? size_group, Gtk.Image? icon = null){

		var button = new Gtk.Button();
		box.append(button);

		button.set_tooltip_text(tooltip);

		if (icon != null){
			/* GTK4 drops Button.set_image(); compose an explicit child. */
			var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
			hbox.halign = Gtk.Align.CENTER;
			hbox.append(icon);
			hbox.append(new Gtk.Label(text));
			button.set_child(hbox);
		}
		else{
			button.set_label(text);
		}

		if (size_group != null){
			size_group.add_widget(button);
		}

		return button;
	}

}

