project(
  'timeshift',
  'vala',
  'c',
  version : '25.12.4',
  license : 'GPL-2.0-or-later',
  meson_version : '>= 0.54.0',
  default_options : ['c_std=c99', 'build.c_std=c99']
)

dependencies = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gtk4'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('json-glib-1.0'),
  dependency('vte-2.91-gtk4'),
  dependency('gee-0.8'),
  meson.get_compiler('vala').find_library('posix'),
  meson.get_compiler('c').find_library('m'),
]


# Include the translations module
i18n = import('i18n')

am_cflags = [
  '-fstack-protector',
  '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
]
add_project_arguments(am_cflags, language: 'c')

subdir('files')
subdir('src')
subdir('po')

enable_man = get_option('man')
if enable_man
  subdir('docs/man')
endif

install_data(
  sources: 'debian/com.linuxmint.timeshift.metainfo.xml',
  install_dir: join_paths(get_option('datadir'), 'metainfo')
)
