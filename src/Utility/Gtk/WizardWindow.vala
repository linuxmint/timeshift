/*
 * WizardWindow.vala
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
using TeeJee.GtkHelper;

/* Base for the step-by-step windows (setup wizard, backup, restore, delete).
 *
 * The chrome is a HeaderBar: Cancel and Back at the start, Next and Finish at
 * the end, and a title with a "Step n of m" line under it. Pages live in a
 * tabless notebook, exactly as before, so the subclasses keep their Tabs enums
 * and go_next()/initialize_tab() logic; they only describe the current route
 * (step_titles / current_step) and which actions apply (set_actions).
 *
 * While a page must not be abandoned (a backup in flight), set_closable(false)
 * hides the close button and routes the window-manager close (Alt+F4) to
 * on_cancel(), so it behaves like the Cancel button. */

public abstract class WizardWindow : AppWindow {

	protected Gtk.Notebook notebook;
	protected Gtk.HeaderBar header;

	protected Gtk.Label lbl_title;
	protected Gtk.Label lbl_step;

	protected Gtk.Button btn_cancel;
	protected Gtk.Button btn_back;
	protected Gtk.Button btn_next;
	protected Gtk.Button btn_finish;

	private bool closable = true;

	/* Finish is the primary action only on a last page that has no Next; a
	 * Finish relabelled "Close" is never primary. */
	protected bool finish_is_primary = true;
	protected Gtk.Label lbl_next;

	protected WizardWindow(string window_title, int def_width, int def_height){

		this.title = window_title;
		this.modal = true;
		this.set_default_size(def_width, def_height);

		// header --------------------------------------------------------

		header = new Gtk.HeaderBar();
		set_titlebar(header);

		var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		title_box.valign = Gtk.Align.CENTER;

		lbl_title = new Gtk.Label(window_title);
		lbl_title.add_css_class("title");
		lbl_title.ellipsize = Pango.EllipsizeMode.END;
		title_box.append(lbl_title);

		lbl_step = new Gtk.Label("");
		lbl_step.add_css_class("subtitle");
		lbl_step.add_css_class("ts-dim");
		lbl_step.ellipsize = Pango.EllipsizeMode.END;
		lbl_step.visible = false;
		title_box.append(lbl_step);

		header.title_widget = title_box;

		btn_cancel = new Gtk.Button.with_label(_("Cancel"));
		btn_cancel.clicked.connect(() => { on_cancel(); });
		header.pack_start(btn_cancel);

		btn_back = new Gtk.Button();
		var back_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		back_box.append(new Gtk.Image.from_icon_name("go-previous-symbolic"));
		back_box.append(new Gtk.Label(_("Back")));
		btn_back.set_child(back_box);
		btn_back.clicked.connect(() => { go_prev(); });
		header.pack_start(btn_back);

		btn_finish = new Gtk.Button.with_label(_("Finish"));
		btn_finish.clicked.connect(() => { on_finish(); });
		header.pack_end(btn_finish);

		btn_next = new Gtk.Button();
		btn_next.add_css_class("suggested-action");
		var next_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);
		lbl_next = new Gtk.Label(_("Next"));
		next_box.append(lbl_next);
		next_box.append(new Gtk.Image.from_icon_name("go-next-symbolic"));
		btn_next.set_child(next_box);
		btn_next.clicked.connect(() => { go_next(); });
		header.pack_end(btn_next);

		// pages ---------------------------------------------------------

		notebook = new Gtk.Notebook();
		notebook.show_tabs = false;
		notebook.show_border = false;
		notebook.hexpand = true;
		notebook.vexpand = true;
		set_child(notebook);

		// GTK4 widgets start visible; initialize_tab() runs on a timeout, so
		// without this every wizard flashes all four buttons on open
		set_actions(false, false, false, false);

		this.close_request.connect(on_close_request);
	}

	// subclass contract ----------------------------------------------------

	protected abstract void go_next();
	protected virtual void go_prev(){}
	protected abstract void on_cancel();
	protected abstract void on_finish();

	/* Titles of the steps on the route currently being walked, in order. */
	protected abstract string[] step_titles();

	/* Index of the current page within step_titles(), or -1 to hide. */
	protected abstract int current_step();

	/* What the subclass used to do in its close_request handler. Return
	 * false to let the window close. */
	protected virtual bool handle_close(){
		notify_closed();
		return false;
	}

	// plumbing -------------------------------------------------------------

	/* Adds a page in notebook order. Form pages are clamped to a readable
	 * width; list pages pass clamp = false and take the whole width. */
	protected void add_page(Gtk.Widget page, bool clamp = true){

		page.add_css_class("ts-page");
		page.hexpand = true;
		page.vexpand = true;

		Gtk.Widget host = clamp ? new Clamp(page) : page;

		notebook.append_page(host, null);
	}

	/* Extra header buttons a subclass needs (Pause, Hide). */
	protected void add_header_action(Gtk.Button button, Gtk.PackType where){

		if (where == Gtk.PackType.START){
			header.pack_start(button);
		}
		else {
			header.pack_end(button);
		}
	}

	protected void set_actions(bool back, bool next, bool finish, bool cancel){

		btn_back.visible = back;
		btn_next.visible = next;
		btn_finish.visible = finish;
		btn_cancel.visible = cancel;

		if (finish && !next && finish_is_primary){
			btn_finish.add_css_class("suggested-action");
		}
		else {
			btn_finish.remove_css_class("suggested-action");
		}
	}

	protected void set_closable(bool value){

		closable = value;
		header.show_title_buttons = value;
	}

	protected void update_step_label(){

		string[] titles = step_titles();
		int idx = current_step();

		if ((idx < 0) || (idx >= titles.length)){
			lbl_step.visible = false;
			return;
		}

		lbl_step.label = _("Step %d of %d: %s").printf(idx + 1, titles.length, titles[idx]);
		lbl_step.visible = true;
	}

	private bool on_close_request(){

		if (!closable){
			on_cancel();
			return true; // keep the window; on_cancel() decides
		}

		return handle_close();
	}
}
