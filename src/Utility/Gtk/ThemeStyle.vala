/*
 * ThemeStyle.vala
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

/* The app's design tokens and stylesheet.
 *
 * Pure data: the light and dark palettes, the accent presets, and a builder
 * that turns a resolved palette into the CSS text AppTheme loads into its
 * provider. Nothing here touches GTK objects, so it can be reasoned about (and
 * dumped under --debug) without a display.
 *
 * Colours are emitted as @define-color tokens rather than CSS custom
 * properties: var() only arrived in GTK 4.16 and the build sets no GTK minimum,
 * while @define-color still parses on every GTK4 release. Lengths cannot be
 * tokens, so radius and spacing are substituted into the rules by the builder.
 *
 * Every selector is scoped under a .ts-* class. Stock widgets keep whatever the
 * user's GTK theme gives them; this stylesheet only paints the surfaces this
 * app owns. */

public struct ThemePalette {
	public string window_bg;
	public string window_fg;
	public string view_bg;
	public string view_fg;
	public string card_bg;
	public string card_fg;
	public string fg;
	public string dim_fg;
	public string border;
	public string shade;
	public string accent_bg;
	public string accent_fg;
	public string accent;
	public string success_bg;
	public string success_fg;
	public string success;
	public string warning_bg;
	public string warning_fg;
	public string warning;
	public string error_bg;
	public string error_fg;
	public string error;
}

public struct AccentPreset {
	public string key;              // config value, never translated
	public string bg;               // accent_bg, same in both modes
	public string standalone_light; // accent used as text/icon colour on a light ground
	public string standalone_dark;  // ... on a dark ground
}

public class ThemeStyle : GLib.Object {

	// lengths (px); mirrored by Ui.Spacing for widget margins
	public const int RADIUS = 8;
	public const int RADIUS_SM = 6;
	public const int SPACE_XS = 6;
	public const int SPACE_S = 12;
	public const int SPACE_M = 18;
	public const int SPACE_L = 24;
	public const int SPACE_XL = 36;

	public const string DEFAULT_ACCENT = "blue";

	// accent presets ---------------------------------------------------

	private static AccentPreset[]? _presets = null;

	public static unowned AccentPreset[] presets(){

		if (_presets == null){
			_presets = {
				{ "blue",   "#3584e4", "#0461be", "#81d0ff" },
				{ "teal",   "#2190a4", "#007184", "#7bdff4" },
				{ "green",  "#3a944a", "#15793b", "#78e9ab" },
				{ "yellow", "#c88800", "#905400", "#ffc252" },
				{ "orange", "#ed5b00", "#b62200", "#ff9c5b" },
				{ "red",    "#e62d42", "#c00023", "#ff888c" },
				{ "pink",   "#d56199", "#a2326c", "#ffa0d8" },
				{ "purple", "#9141ac", "#8939a4", "#fba7ff" },
				{ "slate",  "#6f8396", "#526678", "#a2b7c9" }
			};
		}

		return _presets;
	}

	public static AccentPreset? preset_by_key(string key){

		foreach (var p in presets()){
			if (p.key == key){ return p; }
		}

		return null;
	}

	/* Translated name for the picker. Kept out of the struct so the table
	 * stays a plain constant. */
	public static string preset_label(string key){

		switch (key){
		case "blue":   return _("Blue");
		case "teal":   return _("Teal");
		case "green":  return _("Green");
		case "yellow": return _("Yellow");
		case "orange": return _("Orange");
		case "red":    return _("Red");
		case "pink":   return _("Pink");
		case "purple": return _("Purple");
		case "slate":  return _("Slate");
		default:       return key;
		}
	}

	/* Snap an arbitrary colour (portal accent-color, components 0..1) to the
	 * preset with the smallest squared RGB distance. GNOME sends exactly the
	 * preset values; other desktops get the closest tested pair. */
	public static string nearest_preset(double r, double g, double b){

		string best = DEFAULT_ACCENT;
		double best_dist = double.MAX;

		foreach (var p in presets()){
			double pr, pg, pb;
			parse_hex(p.bg, out pr, out pg, out pb);
			double d = (pr - r) * (pr - r) + (pg - g) * (pg - g) + (pb - b) * (pb - b);
			if (d < best_dist){
				best_dist = d;
				best = p.key;
			}
		}

		return best;
	}

	private static void parse_hex(string hex, out double r, out double g, out double b){

		r = g = b = 0;

		if ((hex.length != 7) || (hex[0] != '#')){ return; }

		r = (double) hex.substring(1, 2).to_long(null, 16) / 255.0;
		g = (double) hex.substring(3, 2).to_long(null, 16) / 255.0;
		b = (double) hex.substring(5, 2).to_long(null, 16) / 255.0;
	}

	// palettes ---------------------------------------------------------

	public static ThemePalette light_palette(){

		ThemePalette p = {};
		p.window_bg  = "#fafafa";
		p.window_fg  = "rgba(0,0,0,0.8)";
		p.view_bg    = "#ffffff";
		p.view_fg    = "rgba(0,0,0,0.8)";
		p.card_bg    = "#ffffff";
		p.card_fg    = "rgba(0,0,0,0.8)";
		p.fg         = "rgba(0,0,0,0.8)";
		p.dim_fg     = "rgba(0,0,0,0.55)";
		p.border     = "rgba(0,0,0,0.15)";
		p.shade      = "rgba(0,0,0,0.07)";
		p.accent_fg  = "#ffffff";
		p.success_bg = "#2ec27e";
		p.success_fg = "#ffffff";
		p.success    = "#1b8553";
		p.warning_bg = "#e5a50a";
		p.warning_fg = "rgba(0,0,0,0.8)";
		p.warning    = "#9c6e03";
		p.error_bg   = "#e01b24";
		p.error_fg   = "#ffffff";
		p.error      = "#c30000";
		return p;
	}

	public static ThemePalette dark_palette(){

		ThemePalette p = {};
		p.window_bg  = "#242424";
		p.window_fg  = "#ffffff";
		p.view_bg    = "#1e1e1e";
		p.view_fg    = "#ffffff";
		p.card_bg    = "rgba(255,255,255,0.08)";
		p.card_fg    = "#ffffff";
		p.fg         = "#ffffff";
		p.dim_fg     = "rgba(255,255,255,0.55)";
		p.border     = "rgba(255,255,255,0.15)";
		p.shade      = "rgba(0,0,0,0.36)";
		p.accent_fg  = "#ffffff";
		p.success_bg = "#26a269";
		p.success_fg = "#ffffff";
		p.success    = "#78e9ab";
		p.warning_bg = "#cd9309";
		p.warning_fg = "rgba(0,0,0,0.8)";
		p.warning    = "#ffc252";
		p.error_bg   = "#c01c28";
		p.error_fg   = "#ffffff";
		p.error      = "#ff938c";
		return p;
	}

	/* Base palette for the mode with the accent preset applied. An unknown key
	 * falls back to the default so a stale config value can never yield an
	 * empty colour. */
	public static ThemePalette resolve(bool dark, string accent_key){

		var p = dark ? dark_palette() : light_palette();

		var preset = preset_by_key(accent_key);
		if (preset == null){
			log_debug("ThemeStyle: unknown accent '%s', using %s".printf(accent_key, DEFAULT_ACCENT));
			preset = preset_by_key(DEFAULT_ACCENT);
		}

		p.accent_bg = preset.bg;
		p.accent = dark ? preset.standalone_dark : preset.standalone_light;

		return p;
	}

	// stylesheet -------------------------------------------------------

	public static string build_css(ThemePalette p){

		string rules = RULES;

		/* Developer escape hatch: iterate on the rules without a rebuild. Tokens
		 * are still generated, so the file can reference @ts_* names. */
		string? override_path = GLib.Environment.get_variable("TIMESHIFT_THEME_CSS");
		if (LOG_DEBUG && (override_path != null) && file_exists(override_path)){
			string? text = file_read(override_path);
			if ((text != null) && (text.length > 0)){
				log_debug("ThemeStyle: rules from %s".printf(override_path));
				rules = text;
			}
		}

		rules = rules
			.replace("$RADIUS_SM", RADIUS_SM.to_string())
			.replace("$RADIUS", RADIUS.to_string())
			.replace("$SPACE_XS", SPACE_XS.to_string())
			.replace("$SPACE_XL", SPACE_XL.to_string())
			.replace("$SPACE_S", SPACE_S.to_string())
			.replace("$SPACE_M", SPACE_M.to_string())
			.replace("$SPACE_L", SPACE_L.to_string());

		return define_colors(p) + swatch_rules() + rules;
	}

	private static string define_colors(ThemePalette p){

		var sb = new StringBuilder();

		sb.append("@define-color ts_window_bg %s;\n".printf(p.window_bg));
		sb.append("@define-color ts_window_fg %s;\n".printf(p.window_fg));
		sb.append("@define-color ts_view_bg %s;\n".printf(p.view_bg));
		sb.append("@define-color ts_view_fg %s;\n".printf(p.view_fg));
		sb.append("@define-color ts_card_bg %s;\n".printf(p.card_bg));
		sb.append("@define-color ts_card_fg %s;\n".printf(p.card_fg));
		sb.append("@define-color ts_fg %s;\n".printf(p.fg));
		sb.append("@define-color ts_dim_fg %s;\n".printf(p.dim_fg));
		sb.append("@define-color ts_border %s;\n".printf(p.border));
		sb.append("@define-color ts_shade %s;\n".printf(p.shade));
		sb.append("@define-color ts_accent_bg %s;\n".printf(p.accent_bg));
		sb.append("@define-color ts_accent_fg %s;\n".printf(p.accent_fg));
		sb.append("@define-color ts_accent %s;\n".printf(p.accent));
		sb.append("@define-color ts_success_bg %s;\n".printf(p.success_bg));
		sb.append("@define-color ts_success_fg %s;\n".printf(p.success_fg));
		sb.append("@define-color ts_success %s;\n".printf(p.success));
		sb.append("@define-color ts_warning_bg %s;\n".printf(p.warning_bg));
		sb.append("@define-color ts_warning_fg %s;\n".printf(p.warning_fg));
		sb.append("@define-color ts_warning %s;\n".printf(p.warning));
		sb.append("@define-color ts_error_bg %s;\n".printf(p.error_bg));
		sb.append("@define-color ts_error_fg %s;\n".printf(p.error_fg));
		sb.append("@define-color ts_error %s;\n".printf(p.error));
		sb.append("\n");

		return sb.str;
	}

	/* One rule per preset so the picker's swatches show their own colour
	 * regardless of which accent is active. Literal hex, not tokens. */
	private static string swatch_rules(){

		var sb = new StringBuilder();

		foreach (var preset in presets()){
			sb.append(".ts-swatch.%s { background-color: %s; }\n".printf(preset.key, preset.bg));
		}
		sb.append("\n");

		return sb.str;
	}

	private const string RULES = """
/* text ------------------------------------------------------------ */

.ts-title-1 { font-size: 2em; font-weight: 800; }
.ts-title-2 { font-size: 1.5em; font-weight: 800; }
.ts-heading { font-size: 1.1em; font-weight: 700; }
.ts-body { font-size: 1em; }
.ts-caption { font-size: 0.85em; color: @ts_dim_fg; }
.ts-dim { color: @ts_dim_fg; }
.ts-hero-value { font-size: 2.4em; font-weight: 300; color: @ts_accent; }
.ts-success { color: @ts_success; }
.ts-warning { color: @ts_warning; }
.ts-error { color: @ts_error; }
.ts-accent { color: @ts_accent; }

/* surfaces -------------------------------------------------------- */

.ts-page { padding: $SPACE_Lpx; }

.ts-card {
	background-color: @ts_card_bg;
	color: @ts_card_fg;
	border: 1px solid @ts_border;
	border-radius: $RADIUSpx;
	padding: $SPACE_Mpx;
}

.ts-boxed-list {
	background-color: @ts_view_bg;
	border: 1px solid @ts_border;
	border-radius: $RADIUSpx;
}
.ts-boxed-list listview,
.ts-boxed-list columnview,
.ts-boxed-list textview,
.ts-boxed-list textview text {
	background-color: transparent;
}

.ts-status-page { padding: $SPACE_XLpx; }
.ts-status-page > image { -gtk-icon-size: 96px; color: @ts_dim_fg; }

/* chrome ---------------------------------------------------------- */

.ts-toolbar { padding: $SPACE_Spx; border-bottom: 1px solid @ts_border; }
.ts-wizard-actions { padding: $SPACE_Spx; border-top: 1px solid @ts_border; }

/* banners --------------------------------------------------------- */

.ts-banner {
	padding: $SPACE_XSpx $SPACE_Spx;
	border-radius: $RADIUS_SMpx;
}
.ts-banner.info { background-color: @ts_accent_bg; color: @ts_accent_fg; }
.ts-banner.success { background-color: @ts_success_bg; color: @ts_success_fg; }
.ts-banner.warning { background-color: @ts_warning_bg; color: @ts_warning_fg; }
.ts-banner.error { background-color: @ts_error_bg; color: @ts_error_fg; }
.ts-banner label, .ts-banner image { color: inherit; }

/* appearance picker ----------------------------------------------- */

button.ts-swatch {
	min-width: 28px;
	min-height: 28px;
	padding: 0;
	border-radius: 999px;
	border: 2px solid transparent;
	background-image: none;
	box-shadow: none;
	color: @ts_accent_fg;
}
button.ts-swatch.system {
	background-color: transparent;
	border-color: @ts_dim_fg;
	border-style: dashed;
	color: @ts_dim_fg;
}
button.ts-swatch:checked { border-color: @ts_fg; border-style: solid; }
button.ts-swatch image { -gtk-icon-size: 14px; }

/* log status dots ------------------------------------------------- */

.ts-status-created { color: @ts_success; }
.ts-status-changed { color: @ts_warning; }
.ts-status-deleted { color: @ts_error; }
""";
}
