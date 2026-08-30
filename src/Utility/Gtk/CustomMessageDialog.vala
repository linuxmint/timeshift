/*
 * CustomMessageDialog.vala
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

public class CustomMessageDialog : Gtk.Window {

	private Gtk.Label lbl_msg;
	private Gtk.ScrolledWindow sw_msg;
	private Gtk.Box bbox;
	private Gtk.Button? btn_default = null;

	private string msg_title;
	private string msg_body;
	private Gtk.MessageType msg_type;
	private Gtk.ButtonsType buttons_type;

	private Gtk.ResponseType response = Gtk.ResponseType.DELETE_EVENT;
	private GLib.MainLoop? loop = null;

	public CustomMessageDialog(string _msg_title, string _msg_body, Gtk.MessageType _msg_type, Gtk.Window? parent, Gtk.ButtonsType _buttons_type) {

		set_transient_for(parent);
		set_modal(true);

		msg_title = _msg_title;
		msg_body = _msg_body;
		msg_type = _msg_type;
		buttons_type = _buttons_type;

		init_window();
	}

	public void init_window () {

		this.title = msg_title;
		this.resizable = false;

		/* Message-dialog chrome: a flat header carrying only the close button,
		 * with the title set large in the body rather than in the bar. */
		var hb = new Gtk.HeaderBar();
		hb.add_css_class("flat");
		hb.title_widget = new Gtk.Label("");
		set_titlebar(hb);

		var vbox_main = new Gtk.Box(Orientation.VERTICAL, Ui.Spacing.MD);
		set_margin_all(vbox_main, Ui.Spacing.LG);
		vbox_main.margin_top = Ui.Spacing.SM;
		this.set_child(vbox_main);

		var hbox_contents = new Gtk.Box(Orientation.HORIZONTAL, Ui.Spacing.MD);
		vbox_main.append(hbox_contents);

		string icon_name = "dialog-information-symbolic";
		string icon_class = "ts-accent";

		switch(msg_type){
		case Gtk.MessageType.WARNING:
			icon_name = "dialog-warning-symbolic";
			icon_class = "ts-warning";
			break;
		case Gtk.MessageType.QUESTION:
			icon_name = "dialog-question-symbolic";
			break;
		case Gtk.MessageType.ERROR:
			icon_name = "dialog-error-symbolic";
			icon_class = "ts-error";
			break;
		default:
			break;
		}

		// image ----------------

		var img = new Gtk.Image();
		IconManager.set_image_icon(img, icon_name, 32);
		img.pixel_size = 32;
		img.valign = Gtk.Align.START;
		img.add_css_class(icon_class);
		hbox_contents.append(img);

		// text -------------------

		var vbox_text = new Gtk.Box(Orientation.VERTICAL, Ui.Spacing.XS);
		vbox_text.hexpand = true;
		hbox_contents.append(vbox_text);

		var lbl_title = new Gtk.Label(msg_title);
		lbl_title.add_css_class("ts-title-2");
		lbl_title.xalign = 0.0f;
		lbl_title.wrap = true;
		lbl_title.wrap_mode = Pango.WrapMode.WORD_CHAR;
		lbl_title.max_width_chars = 50;
		vbox_text.append(lbl_title);

		/* Body stays markup: callers already escape what they pass. */
		lbl_msg = new Gtk.Label(msg_body);
		lbl_msg.add_css_class("ts-body");
		lbl_msg.xalign = 0.0f;
		lbl_msg.yalign = 0.0f;
		lbl_msg.max_width_chars = 60;
		lbl_msg.wrap = true;
		lbl_msg.wrap_mode = Pango.WrapMode.WORD_CHAR;
		lbl_msg.use_markup = true;
		lbl_msg.selectable = true;
		lbl_msg.hexpand = true;
		lbl_msg.vexpand = true;

		sw_msg = new Gtk.ScrolledWindow();
		sw_msg.set_child(lbl_msg);
		sw_msg.hscrollbar_policy = PolicyType.NEVER;
		sw_msg.vscrollbar_policy = PolicyType.AUTOMATIC;
		sw_msg.hexpand = true;
		sw_msg.vexpand = true;
		sw_msg.propagate_natural_height = true;
		sw_msg.propagate_natural_width = true;
		sw_msg.max_content_height = 400;
		sw_msg.min_content_width = 420;
		vbox_text.append(sw_msg);

		// actions -------------------------

		bbox = Ui.add_button_row(vbox_main, Gtk.Align.END);

		switch(buttons_type){
		case Gtk.ButtonsType.NONE:
			break;
		case Gtk.ButtonsType.OK:
			add_action_button(_("OK"), Gtk.ResponseType.OK, true);
			break;
		case Gtk.ButtonsType.CLOSE:
			add_action_button(_("Close"), Gtk.ResponseType.CLOSE, true);
			break;
		case Gtk.ButtonsType.CANCEL:
			add_action_button(_("Cancel"), Gtk.ResponseType.CANCEL, true);
			break;
		case Gtk.ButtonsType.OK_CANCEL:
			add_action_button(_("Cancel"), Gtk.ResponseType.CANCEL, false);
			add_action_button(_("OK"), Gtk.ResponseType.OK, true);
			break;
		case Gtk.ButtonsType.YES_NO:
			add_action_button(_("No"), Gtk.ResponseType.NO, false);
			add_action_button(_("Yes"), Gtk.ResponseType.YES, true);
			break;
		}

		this.close_request.connect(() => {
			response = Gtk.ResponseType.DELETE_EVENT;
			quit_loop();
			return false;
		});

		// GTK4 windows have no Escape binding of their own
		var keys = new Gtk.EventControllerKey();
		keys.key_pressed.connect((keyval, keycode, state) => {
			if (keyval == Gdk.Key.Escape){
				response = Gtk.ResponseType.DELETE_EVENT;
				quit_loop();
				this.destroy();
				return true;
			}
			return false;
		});
		((Gtk.Widget) this).add_controller(keys);
	}

	private void add_action_button(string label, Gtk.ResponseType response_id, bool is_default){

		var button = new Gtk.Button.with_label(label);

		if (is_default){
			button.add_css_class("suggested-action");
			btn_default = button;
		}

		button.clicked.connect(() => {
			response = response_id;
			quit_loop();
			this.destroy();
		});

		bbox.append(button);

		if (is_default){
			button.grab_focus();
		}
	}

	/* The default answer destroys something (delete, abandon a restore):
	 * style it as such instead of as the suggested action. */
	public void set_destructive(){

		if (btn_default == null){ return; }
		btn_default.remove_css_class("suggested-action");
		btn_default.add_css_class("destructive-action");
	}

	private void quit_loop(){
		if ((loop != null) && loop.is_running()){
			loop.quit();
		}
	}

	public Gtk.ResponseType run(){

		/* Replacement for Gtk.Dialog.run(), which GTK4 removes. Callers in the
		 * core are synchronous, so block on a nested main loop. */

		loop = new GLib.MainLoop();

		/* Gtk.Window.destroy() shadows the inherited Gtk.Widget::destroy signal. */
		ulong handler = ((Gtk.Widget) this).destroy.connect(() => { quit_loop(); });

		this.present();
		loop.run();

		((Gtk.Widget) this).disconnect(handler);
		loop = null;

		return response;
	}
}
