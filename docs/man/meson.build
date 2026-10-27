help2man = find_program('help2man')

mans = [
  ['timeshift', [help2man, '-N', '--output=@OUTPUT@', timeshift]],
]

if enable_gtk
  mans += [
    ['timeshift-gtk', [help2man, '-N', '--output=@OUTPUT@', timeshift_gtk]],
  ]
endif

foreach man: mans
  custom_target(
    man[0],
    output: man[0] + '.1',
    command: man[1],
    install: true,
    install_dir: join_paths(get_option('mandir'), 'man1'),
  )
endforeach
