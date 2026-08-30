/*
 * IconManager.vala
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

public class IconManager : GLib.Object {

	public static Gtk.IconTheme theme;

	public static Gee.ArrayList<string> search_paths = new Gee.ArrayList<string>();

    public const int SHIELD_ICON_SIZE = 64;

    public const string GENERIC_ICON_IMAGE = "image-x-generic";
    public const string GENERIC_ICON_IMAGE_MISSING = "image-missing";
    public const string GENERIC_ICON_VIDEO = "video-x-generic";
    public const string GENERIC_ICON_FILE = "text-x-preview";
    public const string GENERIC_ICON_ARCHIVE_FILE = "package-x-generic";
    public const string GENERIC_ICON_DIRECTORY = "folder";
    public const string GENERIC_ICON_ISO = "media-cdrom";
    public const string GENERIC_ICON_PDF = "application-pdf";

    public const string ICON_HARDDRIVE = "drive-harddisk-symbolic";

    public const string SHIELD_LIVE= "media-optical-symbolic";
    public const string SHIELD_LOW = "timeshift-shield-low";
    public const string SHIELD_MED = "timeshift-shield-med";
    public const string SHIELD_HIGH = "timeshift-shield-high";

	public static void init(string[] args, string app_name){

		log_debug("IconManager: init()");
		
		search_paths = new Gee.ArrayList<string>();

		// check absolute location
		string path = "/usr/share/%s/images".printf(app_name);
		if (dir_exists(path)){
			search_paths.add(path);
			log_debug("found images directory: %s".printf(path));
		}

		refresh_icon_theme();
	}

	public static void refresh_icon_theme(){

		if (!GTK_INITIALIZED) { return; }
		
		var display = Gdk.Display.get_default();
		if (display == null){ return; }

		theme = Gtk.IconTheme.get_for_display(display);

		/* Deliberately NOT theme.add_search_path(search_paths): our bundled
		 * directory is a flat pile of files, not an icon theme. Registering it
		 * makes has_icon() answer true for names no real theme provides, and
		 * GTK then treats a *-symbolic.svg found that way as recolourable --
		 * our hand-made ones do not follow the symbolic spec and render blank.
		 * lookup_path() scans search_paths directly, so nothing needs this. */
	}

	public static string? lookup_path(string icon_name, int icon_size, bool use_hardcoded = false, int scale = 1){

		/* Resolve an icon name to a file on disk.
		 *
		 * The icon theme is tried first; GTK4 hands back a GtkIconPaintable, so
		 * we take its backing file. Failing that, scan search_paths for the flat
		 * SVG/PNG files this app bundles -- the GUI runs as root under pkexec and
		 * so does not see the desktop user's icon theme. */

		if (icon_name.length == 0){ return null; }

		/* has_icon() first: GTK4's lookup_icon() never returns null -- for an
		 * unknown name it hands back the "image-missing" fallback, whose file
		 * path would then win and hide our bundled copy. */

		if (!use_hardcoded && (theme != null) && theme.has_icon(icon_name)){

			var icon_info = theme.lookup_icon(icon_name, null, icon_size, scale,
				Gtk.TextDirection.NONE, 0);

			if (icon_info != null){
				var file = icon_info.get_file();
				if ((file != null) && (file.get_path() != null)){
					return file.get_path();
				}
			}
		}

		foreach(string search_path in search_paths){

			foreach(string ext in new string[] { ".svg", ".png", ".jpg", ".gif"}){

				string img_file = path_combine(search_path, icon_name + ext);

				if (file_exists(img_file)){
					return img_file;
				}
			}
		}

		return null;
	}

	public static Gdk.Texture? lookup_texture_for_name(string icon_name, int icon_size, bool use_hardcoded = false, int scale = 1){

		/* Gdk.Texture.for_pixbuf() is deprecated; load the file directly. */

		string? path = lookup_path(icon_name, icon_size, use_hardcoded, scale);

		if (path == null){ return null; }

		try {
			return Gdk.Texture.from_filename(path);
		}
		catch (Error e) {
			log_debug("IconManager: %s".printf(e.message));
			return null;
		}
	}

	public static Gdk.Pixbuf? lookup(string icon_name, int icon_size, bool use_hardcoded = false, int scale = 1){

		string? path = lookup_path(icon_name, icon_size, use_hardcoded, scale);

		if (path == null){ return null; }

		return load_pixbuf_from_file(path, icon_size);
	}
	
	public static Gtk.Image? lookup_image(string icon_name, int icon_size, bool use_hardcoded = false){

		if (icon_name.length == 0){ return null; }

        Gtk.Image image = new Gtk.Image();

        set_image_icon(image, icon_name, icon_size);

        return image;
	}

    public static Gdk.Texture? lookup_texture(string icon_name, int icon_size, int scale = 1, bool use_hardcoded = false){

        /* GTK4 renders from GdkPaintable; Gtk.Image.surface is gone. */

        if (icon_name.length == 0){ return null; }

        var texture = lookup_texture_for_name(icon_name, icon_size, use_hardcoded, scale);

        if (texture == null){
            texture = lookup_texture_for_name(GENERIC_ICON_IMAGE_MISSING, icon_size, use_hardcoded, scale);
        }

        return texture;
    }

	public static void set_image_icon(Gtk.Image image, string icon_name, int icon_size){

		/* Point a Gtk.Image at an icon, preferring lookup() over
		 * Gtk.Image.from_icon_name().
		 *
		 * lookup() tries the icon theme first and then falls back to scanning
		 * search_paths for the flat SVG/PNG files this app bundles in
		 * /usr/share/timeshift/images. That fallback matters because the GUI
		 * runs as root under pkexec and so does not pick up the desktop user's
		 * icon theme: emblem-default-symbolic, for one, exists in Yaru but not
		 * in Adwaita, and would otherwise render as nothing.
		 *
		 * Deliberately not lookup_texture(): that substitutes image-missing on
		 * failure, which would hide a name the theme could still resolve. */

		if (icon_name.length == 0){ return; }

		image.pixel_size = icon_size;

		/* Prefer the icon theme. set_from_icon_name() goes through GTK's own
		 * lookup, which yields a Gtk.IconPaintable -- a Gtk.SymbolicPaintable
		 * that recolours to the current foreground. Loading the same file into
		 * a Gdk.Texture instead rasterises it as authored, so Adwaita's
		 * #2e3436 symbolics come out near-black and vanish on a dark theme. */

		if ((theme != null) && theme.has_icon(icon_name)){
			image.set_from_icon_name(icon_name);
			return;
		}

		/* Nothing in the theme provides this name -- fall back to the flat
		 * SVG/PNG files bundled under /usr/share/timeshift/images. These do not
		 * recolour, but they are mid-grey and stay legible either way.
		 *
		 * set_from_file() rather than a Gdk.Texture: Gdk.Texture.from_filename()
		 * rasterises an SVG at its natural size, so a 16px source came out
		 * blurred next to crisp themed icons once pixel_size scaled it up. */

		string? path = lookup_path(icon_name, icon_size, false, image.scale_factor);

		if (path != null){
			image.set_from_file(path);
		}
		else {
			image.set_from_icon_name(icon_name);
		}
	}

	public static Gdk.Pixbuf? lookup_gicon(GLib.Icon? gicon, int icon_size){

		Gdk.Pixbuf? pixbuf = null;

		if (gicon == null){ return null; }
		
		if (theme == null){ return null; }

		var icon_info = theme.lookup_by_gicon(gicon, icon_size, 1,
			Gtk.TextDirection.NONE, 0);

		if (icon_info != null){
			var file = icon_info.get_file();
			if ((file != null) && (file.get_path() != null)){
				pixbuf = load_pixbuf_from_file(file.get_path(), icon_size);
			}
		}

		return pixbuf;
	}

    public static Gdk.Pixbuf? add_overlay(Gdk.Pixbuf pixbuf_base, Gdk.Pixbuf pixbuf_overlay) {

        int offset_x = (pixbuf_base.width - pixbuf_overlay.width) / 2 ;

		var offset_y = (pixbuf_base.height - pixbuf_overlay.height) / 2 ;

        var emblemed = pixbuf_base.copy();
        
        pixbuf_overlay.composite(emblemed, 
			offset_x, offset_y, 
			pixbuf_overlay.width, pixbuf_overlay.height,
			offset_x, offset_y, 
			1.0, 1.0, 
			Gdk.InterpType.BILINEAR, 255);

        return emblemed;
    }
    
    public static Gdk.Pixbuf? resize_icon(Gdk.Pixbuf pixbuf_image, int icon_size) {
		
		//log_debug("resize_icon()");
		
		var pixbuf_empty = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, icon_size, icon_size);
		pixbuf_empty.fill(0x00000000);

		//log_debug("pixbuf_empty: %d, %d".printf(pixbuf_empty.width, pixbuf_empty.height));
		
		var pixbuf_resized = add_overlay(pixbuf_empty, pixbuf_image);
		
		//log_debug("pixbuf_resized: %d, %d".printf(pixbuf_resized.width, pixbuf_resized.height));

		//copy_pixbuf_options(pixbuf_image, pixbuf_resized);
		
        return pixbuf_resized;
    }
    
    public static Gdk.Pixbuf? add_transparency (Gdk.Pixbuf pixbuf, int opacity = 130) {

		var trans = pixbuf.copy();
		trans.fill((uint32) 0xFFFFFF00);

		//log_debug("add_transparency");

		int width = pixbuf.get_width();
		int height = pixbuf.get_height();
		pixbuf.composite(trans, 0, 0, width, height, 0, 0, 1.0, 1.0, Gdk.InterpType.BILINEAR, opacity);

        return trans;
    }
    
    public static Gdk.Pixbuf? load_pixbuf_from_file(string file_path, int icon_size){
		
		Gdk.Pixbuf? pixbuf = null;
		
		int width, height;
		Gdk.Pixbuf.get_file_info(file_path, out width, out height);
		
		if ((width <= icon_size) && (height <= icon_size)){
			try{
				// load without scaling
				pixbuf = new Gdk.Pixbuf.from_file(file_path);
				// pad to requested size
				pixbuf = resize_icon(pixbuf, icon_size);
				// return
				if (pixbuf != null){ return pixbuf; }
			}
			catch (Error e){
				// ignore
			}
		}
		else {
			try{
				// load with scaling - scale down to requested box
				pixbuf = new Gdk.Pixbuf.from_file_at_scale(file_path, icon_size, icon_size, true);
				// pad to requested size
				pixbuf = resize_icon(pixbuf, icon_size);
				// return
				if (pixbuf != null){ return pixbuf; }
			}
			catch (Error e){
				// ignore
			}
		}
		
		return null;
	}
}
