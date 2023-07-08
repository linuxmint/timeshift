project(
  'timeshift', 'vala', 'c',
  version: '23.07.1',
  license : 'GPL-2.0-or-later',
  meson_version: '>= 0.54.0',
  default_options: ['c_std=c99', 'build.c_std=c99'])

dependencies = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gtk+-3.0'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('json-glib-1.0'),
  dependency('vte-2.91'),
  dependency('gee-0.8'),
  meson.get_compiler('vala').find_library('posix'),
  meson.get_compiler('c').find_library('m'),
]

enable_xapp = get_option('xapp')
if enable_xapp
  xapp_dep = dependency('xapp')
  add_project_arguments('-D', 'XAPP', language: 'vala')
  dependencies += xapp_dep
endif

# Include the translations module
i18n = import('i18n')

am_cflags = [
  '-fstack-protector',
  '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
]
add_project_arguments(am_cflags, language: 'c')
add_project_arguments('-D', 'GTK3_18', language: 'vala')

subdir('files')
subdir('src')
subdir('po')

enable_man = get_option('man')
if enable_man
  subdir('docs/man')
endif

install_data(
  sources: 'debian/timeshift.appdata.xml',
  install_dir: join_paths(get_option('datadir'), 'metainfo')
)
