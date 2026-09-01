# The Go core: the daemon and its command-line client.
#
# Stdlib only, deliberately -- no vendor tree, no network during the package
# build, and exactly one new Build-Depends.
#
# Both targets are build_always_stale: meson cannot see the Go dependency graph,
# and go's own build cache (pinned into the build directory by go-build.sh)
# makes an up-to-date rebuild cheap enough that always asking is the honest
# option. Getting this wrong the other way -- declaring the sources and missing
# one -- ships a stale binary.

# No version: kwarg -- meson would probe `go --version`, which the go tool does
# not accept (it spells it `go version`), and version_argument: needs meson 1.5
# while this project's floor is 0.54. The 1.22 requirement lives in
# debian/control's Build-Depends, where it is actually enforced.
go_prog = find_program('go', required: true)
go_build = find_program(meson.current_source_dir() / 'go-build.sh')

go_build_args = [
  meson.current_source_dir(),
  meson.current_build_dir(),
  '@OUTPUT@',
]

# The daemon. Installed to libexecdir rather than bindir: it is started by
# systemd and by the client library, never typed by a person.
timeshiftd = custom_target('timeshiftd',
  output: 'timeshiftd',
  command: [go_build, go_build_args, './cmd/timeshiftd', meson.project_version()],
  build_always_stale: true,
  install: true,
  install_dir: get_option('libexecdir') / 'timeshift',
)

# The CLI.
#
# Installed beside the daemon rather than as /usr/bin/timeshift: the Vala binary
# still owns that name and still implements flags this one does not (--restore
# above all), so claiming the public path would be a downgrade dressed as a
# cutover. help2man also builds the man page from whatever answers
# /usr/bin/timeshift --help, and that page has to keep describing the binary
# people actually run.
#
# What the private path buys is real, though: apt-snapshot-guard can prefer it,
# and an apt-driven snapshot then becomes a daemon job that the GUI can attach
# to -- which is the entire point of this port.
timeshift_go = custom_target('timeshift-go',
  output: 'timeshift',
  command: [go_build, go_build_args, './cmd/timeshift', meson.project_version()],
  build_always_stale: true,
  install: true,
  install_dir: get_option('libexecdir') / 'timeshift',
)

# The unit. dh_installsystemd finds units the upstream build system installed
# and generates the enable/start maintainer-script snippets from them, so there
# is nothing to add in debian/ for this.
install_data(
  'systemd/timeshiftd.service',
  'systemd/timeshiftd.socket',
  install_dir : get_option('prefix') / 'lib/systemd/system',
)
