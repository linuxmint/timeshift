/*
 * PhaseList.vala
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

using TeeJee.GtkHelper;

/* A checklist of the steps a long operation will run through: done ones
 * ticked, the current one spinning, the rest waiting.
 *
 * The list is built up front from the steps that will actually run, so a
 * skipped step never appears. Advancing is monotonic - set_active() ticks off
 * everything above the named step - because a step that produced no output
 * still has to stop looking pending once the next one announces itself. */

public class PhaseList : Gtk.Box {

	private class PhaseRow : GLib.Object {

		public string key;
		public Gtk.Box row;
		public Gtk.Image image;
		public Gtk.Spinner spinner;
		public Gtk.Label label;

		public PhaseRow(string _key, string title){

			key = _key;

			row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, Ui.Spacing.XS);

			image = new Gtk.Image();
			image.valign = Gtk.Align.CENTER;
			row.append(image);

			spinner = new Gtk.Spinner();
			spinner.valign = Gtk.Align.CENTER;
			spinner.add_css_class("ts-accent");
			spinner.visible = false;
			row.append(spinner);

			label = new Gtk.Label(title);
			label.xalign = (float) 0.0;
			label.hexpand = true;
			label.ellipsize = Pango.EllipsizeMode.END;
			row.append(label);
		}

		public void set_state(int state){ // 0 pending, 1 active, 2 done

			label.remove_css_class("ts-body");
			label.remove_css_class("ts-dim");
			image.remove_css_class("ts-phase-pending");
			image.remove_css_class("ts-phase-done");

			switch (state){
			case 1:
				image.visible = false;
				spinner.visible = true;
				spinner.spinning = true;
				label.add_css_class("ts-body");
				break;

			case 2:
				spinner.spinning = false;
				spinner.visible = false;
				image.visible = true;
				IconManager.set_image_icon(image, "object-select-symbolic", 16);
				image.add_css_class("ts-phase-done");
				label.add_css_class("ts-body");
				break;

			default:
				spinner.spinning = false;
				spinner.visible = false;
				image.visible = true;
				IconManager.set_image_icon(image, "media-record-symbolic", 16);
				image.add_css_class("ts-phase-pending");
				label.add_css_class("ts-dim");
				break;
			}
		}
	}

	private Gee.ArrayList<PhaseRow> rows;
	private Gtk.Box list_box;

	public PhaseList(){

		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);

		rows = new Gee.ArrayList<PhaseRow>();

		list_box = Ui.add_card(this, Gtk.Orientation.VERTICAL, Ui.Spacing.XS);

		this.visible = false; // nothing to show until phases are added
	}

	public int count {
		get { return rows.size; }
	}

	public void clear(){

		foreach(var r in rows){
			list_box.remove(r.row);
		}

		rows.clear();
		this.visible = false;
	}

	public void add_phase(string key, string title){

		var r = new PhaseRow(key, title);
		r.set_state(0);
		rows.add(r);
		list_box.append(r.row);

		this.visible = true;
	}

	public bool has_phase(string key){

		foreach(var r in rows){
			if (r.key == key){ return true; }
		}

		return false;
	}

	/* Marks the named step as running and every step above it as finished.
	 * An unknown key leaves the list untouched. */
	public void set_active(string key){

		int index = -1;

		for(int i = 0; i < rows.size; i++){
			if (rows[i].key == key){ index = i; break; }
		}

		if (index < 0){ return; }

		for(int i = 0; i < rows.size; i++){
			rows[i].set_state((i < index) ? 2 : ((i == index) ? 1 : 0));
		}
	}

	/* Every step finished - used when the task exits without announcing a
	 * final phase. */
	public void complete_all(){

		foreach(var r in rows){
			r.set_state(2);
		}
	}
}
