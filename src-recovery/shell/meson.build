# The launcher shown inside the recovery environment.
#
# Built from its own sources and its own dependency list, never from
# sources_core or sources_utility: it must keep working when Timeshift's own
# state does not load, which is the situation the environment exists for. If a
# file here ever needs something from src/, that is a signal the helper should
# be duplicated, not linked.
#
# No vala_args: `vala_opts` in src/meson.build points --vapidir at src/vapi and
# adds --pkg ioprio, neither of which exists or is used here.

recovery_shell_deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gtk4', version: '>= 4.12'), # Gtk.CssProvider.load_from_string
  dependency('gee-0.8'),
  dependency('vte-2.91-gtk4'),
  dependency('json-glib-1.0'),
]

timeshift_recovery_shell = executable('timeshift-recovery-shell',
  files([
    'RecoveryApp.vala',
    'RecoveryTheme.vala',
    'RecoveryWindow.vala',
    'Page.vala',
    'Modal.vala',
    'HomePage.vala',
    'NetworkPage.vala',
    'DrivesPage.vala',
    'TerminalPage.vala',
    'DiagnosticsPage.vala',
    'Sh.vala',
    'SysInfo.vala',
    'Tailscale.vala',
  ]),
  config_header,
  dependencies: recovery_shell_deps,
  install: true,
)
