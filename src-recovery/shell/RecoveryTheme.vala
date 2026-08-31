/*
 * RecoveryTheme.vala
 *
 * Layout tokens and the stylesheet for the Timeshift recovery shell.
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

/* Vala marks the whole Gtk.StyleContext class deprecated, but in GTK4 only its
 * instance methods are -- gtk_style_context_add_provider_for_display() is still
 * the supported way to register a provider, so bind it directly. Same binding
 * as AppTheme uses, for the same reason. */
[CCode (cname = "gtk_style_context_add_provider_for_display")]
extern void style_context_add_provider_for_display(Gdk.Display display, Gtk.StyleProvider provider, uint priority);

/* Every colour is stated outright. The environment has no desktop settings
 * daemon, so whichever GTK theme happens to be present decides the defaults,
 * and a half-styled window is worse than an unstyled one. Buttons also need
 * background-image cleared: GTK themes paint a gradient there that sits on
 * top of any background-color.
 *
 * Same vocabulary as timeshift-gtk's ThemeStyle, but that file is not linkable
 * here (it reaches Main through the global App), so the values are restated.
 * Used from code and spliced into the CSS below. All values are logical px;
 * the compositor scale multiplies them. */
namespace RecoveryTheme {

	public const int SPACE_XS = 4;    // label-to-label inside a text stack
	public const int SPACE_S = 8;     // related controls, small gaps
	public const int SPACE_M = 12;    // siblings in a group: cards in a list, buttons in a bar
	public const int SPACE_L = 16;    // icon-to-text in a row, block-to-block
	public const int SPACE_XL = 24;   // page top/bottom margins, dialog padding
	public const int SPACE_PAGE = 48; // page side margins
	public const int RADIUS_S = 8;    // buttons, entries, list rows
	public const int RADIUS_M = 12;   // cards
	public const int RADIUS_L = 16;   // the modal dialog

	// The colours the VTE terminal must share with the stylesheet.
	public const string C_BG = "#14161d";
	public const string C_TEXT = "#e6eaf2";

	/* xterm's 16 slots, tuned to sit on C_BG: normal colours first, then
	 * bright. Slot 0 is the terminal's "black", kept a step above the
	 * background so reverse-video text stays visible. */
	public const string[] TERM_PALETTE = {
		"#1a1e26", "#d3696f", "#6cbf7f", "#e3b34c",
		"#5b8def", "#b98ad4", "#5fb8c2", "#c7cedb",
		"#3b4353", "#e08a8f", "#8ed49e", "#eec97e",
		"#82a8f2", "#cfa8e0", "#84cdd6", "#e6eaf2"
	};

	public const string CSS = """
		window { background-color: $C_BG; color: $C_FG; }

		.rs-title      { font-size: 28px; font-weight: 700; color: $C_FG; }
		.rs-subtitle   { font-size: 14px; color: #9aa4b6; }
		.rs-page-title { font-size: 16px; font-weight: 600; color: $C_FG; }
		.rs-action      { font-size: 16px; font-weight: 600; color: $C_FG; }
		.rs-action-desc { font-size: 12px; color: #9aa4b6; }
		.rs-status { font-size: 12px; color: #9aa4b6; padding: $SPACE_S 2px; }
		.rs-warn   { font-size: 12px; color: #e3b34c; padding: $SPACE_S 2px; }

		/* The caps strings come from the call sites; spacing and a slightly
		 * brighter grey carry the hierarchy instead of pure dimness. */
		.rs-section {
			font-size: 11px; font-weight: 600; color: #8a94a8;
			letter-spacing: 1.5px;
			margin-top: $SPACE_S; padding: 2px;
		}

		separator { background-color: #262c37; min-height: 1px; margin: $SPACE_XS 0; }

		/* Padding lives on the card, not on .rs-action: label padding indented
		 * titles further than their own descriptions. */
		.rs-card {
			background-color: #1c2028;
			background-image: none;
			border: 1px solid #2a303c;
			border-radius: $RADIUS_M;
			padding: 14px $SPACE_L;
			box-shadow: none;
			color: $C_FG;
			transition: background-color 150ms ease, border-color 150ms ease;
		}
		.rs-card:hover  { background-color: #242a35; border-color: #3b4353; }
		.rs-card:active { background-color: #181c24; }
		.rs-card image  { color: #9aa4b6; }
		.rs-card:hover image { color: $C_FG; }

		/* Every button, not just the cards: page headers use plain Gtk.Button
		 * and were left rendering in the light theme. */
		button {
			background-image: none;
			background-color: #1f242e;
			border: 1px solid #2f3644;
			border-radius: $RADIUS_S;
			color: $C_FG;
			font-weight: 500;
			padding: $SPACE_S $SPACE_L;
			transition: background-color 120ms ease, border-color 120ms ease;
		}
		button:hover   { background-color: #262d3a; border-color: #3b4353; }
		button:active  { background-color: #1a1f28; }
		button:disabled {
			color: #5f6878; background-color: #191d25; border-color: #232834;
		}
		button.rs-primary { background-color: #4f80e8; border-color: #4f80e8; color: #ffffff; }
		button.rs-primary:hover  { background-color: #6191f0; border-color: #6191f0; }
		button.rs-primary:active { background-color: #3e6cd0; }
		button.rs-danger { background-color: #963c41; border-color: #963c41; color: #ffffff; }
		button.rs-danger:hover  { background-color: #a84850; border-color: #a84850; }
		button.rs-danger:active { background-color: #83343a; }

		/* Keyboard navigation is first-class: this UI may be driven on a
		 * machine whose pointer does not work. */
		button:focus-visible, .rs-card:focus-visible, row:focus-visible {
			outline: 2px solid rgba(79, 128, 232, 0.6);
			outline-offset: 2px;
		}

		.rs-badge {
			font-size: 11px; font-weight: 600; color: #9aa4b6;
			background-color: rgba(154, 164, 182, 0.10);
			border: 1px solid rgba(154, 164, 182, 0.18);
			border-radius: 999px;
			padding: 2px 10px;
		}
		.rs-badge-warn {
			color: #e3b34c;
			background-color: rgba(227, 179, 76, 0.10);
			border-color: rgba(227, 179, 76, 0.24);
		}
		.rs-badge-accent {
			color: #86abf4;
			background-color: rgba(79, 128, 232, 0.12);
			border-color: rgba(79, 128, 232, 0.28);
		}

		listbox.rs-card { padding: $SPACE_XS; }
		listbox.rs-card > row {
			background-color: transparent;
			border-radius: $RADIUS_S;
			padding: $SPACE_M;
			transition: background-color 120ms ease;
		}
		listbox.rs-card > row:hover { background-color: rgba(230, 234, 242, 0.03); }
		listbox.rs-card > row:not(:last-child) { border-bottom: 1px solid #232834; }

		scrollbar        { background-color: transparent; }
		scrollbar trough { background-color: transparent; }
		scrollbar slider {
			background-color: rgba(154, 164, 182, 0.25);
			border-radius: 999px;
			border: none;
			min-width: 6px; min-height: 6px;
		}
		scrollbar slider:hover { background-color: rgba(154, 164, 182, 0.45); }

		/* In-app modal. Gtk.AlertDialog spawns its own toplevel, which under a
		 * bare labwc session gets no decoration and none of this stylesheet --
		 * it rendered as a cramped box with an empty strip above the text. */
		.rs-modal-scrim { background-color: rgba(8, 10, 14, 0.65); }
		.rs-dialog {
			background-color: #1c2028;
			border: 1px solid #333a48;
			border-radius: $RADIUS_L;
			padding: $SPACE_XL;
			box-shadow: 0 20px 60px rgba(0, 0, 0, 0.55), 0 2px 8px rgba(0, 0, 0, 0.35);
		}
		.rs-dialog-title { font-size: 20px; font-weight: 700; color: $C_FG; }
		.rs-dialog-body  { font-size: 14px; color: #b7c0d0; }

		entry {
			background-color: $C_BG;
			background-image: none;
			color: $C_FG;
			caret-color: #4f80e8;
			border: 1px solid #333a48;
			border-radius: $RADIUS_S;
			padding: 10px $SPACE_M;
		}
		entry:focus-within { border-color: #4f80e8; }
		entry image        { color: #9aa4b6; }
		entry image:hover  { color: $C_FG; }

		/* GTK4 TextView paints content on an inner `text` node; styling only
		 * the widget leaves the text area on the theme's colours. */
		.rs-log      { font-family: monospace; font-size: 12px; background-color: $C_BG; }
		.rs-log text { background-color: $C_BG; color: #b7c0d0; }
	""";

	public string px(int v) { return "%dpx".printf(v); }

	/* replace() is plain substring substitution. No token name is a substring
	 * of another, which is what makes the order below irrelevant -- keep that
	 * property when adding tokens, or replace the longer name first. */
	public string themed_css() {
		return CSS
			.replace("$SPACE_XS", px(SPACE_XS))
			.replace("$SPACE_XL", px(SPACE_XL))
			.replace("$SPACE_S", px(SPACE_S))
			.replace("$SPACE_M", px(SPACE_M))
			.replace("$SPACE_L", px(SPACE_L))
			.replace("$RADIUS_S", px(RADIUS_S))
			.replace("$RADIUS_M", px(RADIUS_M))
			.replace("$RADIUS_L", px(RADIUS_L))
			.replace("$C_BG", C_BG)
			.replace("$C_FG", C_TEXT);
	}

	/* Install the stylesheet on the default display. Must run after Gtk.init()
	 * and before any window is built. */
	public void install() {
		var css = new Gtk.CssProvider();
		css.load_from_string(themed_css());
		style_context_add_provider_for_display(
			Gdk.Display.get_default(), css,
			Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
	}
}
