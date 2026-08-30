/*
 * ContentClamp.vala
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

/* Caps a child's width and centres it, so form-style pages stop stretching
 * across a wide window. Lists should not be clamped; they want the width.
 * Pure GTK4: measure/size_allocate are overridden on the widget itself, no
 * layout manager involved. */

/* Named ContentClamp, not Clamp: Vala derives the C macro name from the class,
 * and a class called Clamp emits `#define CLAMP(obj)`, shadowing glib's
 * CLAMP(x, low, high) in every file that includes the header. */
public class ContentClamp : Gtk.Widget {

	public int maximum_size { get; set; default = Ui.MAX_CONTENT_WIDTH; }

	private Gtk.Widget? child = null;

	public ContentClamp(Gtk.Widget child){

		this.child = child;
		child.set_parent(this);

		hexpand = true;
		vexpand = true;
	}

	public override Gtk.SizeRequestMode get_request_mode(){

		return (child == null) ? Gtk.SizeRequestMode.CONSTANT_SIZE : child.get_request_mode();
	}

	public override void measure(Gtk.Orientation orientation, int for_size,
		out int minimum, out int natural, out int minimum_baseline, out int natural_baseline){

		minimum = natural = 0;
		minimum_baseline = natural_baseline = -1;

		if (child == null){ return; }

		if (!child.should_layout()){ return; }

		if (orientation == Gtk.Orientation.HORIZONTAL){
			child.measure(orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
			// never below the child's own minimum, or it would overflow us
			natural = int.max(minimum, int.min(natural, maximum_size));
		}
		else {
			// height for the width the child will actually get
			int w = (for_size < 0) ? -1 : int.min(for_size, maximum_size);
			child.measure(orientation, w, out minimum, out natural, out minimum_baseline, out natural_baseline);
		}
	}

	public override void size_allocate(int width, int height, int baseline){

		if ((child == null) || !child.should_layout()){ return; }

		int min_w, nat_w, mb, nb;
		child.measure(Gtk.Orientation.HORIZONTAL, -1, out min_w, out nat_w, out mb, out nb);

		int w = int.max(min_w, int.min(width, maximum_size));
		int x = int.max(0, (width - w) / 2);

		Gtk.Allocation alloc = { x, 0, w, height };
		child.allocate_size(alloc, baseline);
	}

	public override void dispose(){

		if (child != null){
			child.unparent();
			child = null;
		}

		base.dispose();
	}
}
