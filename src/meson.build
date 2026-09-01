conf_data = configuration_data()
conf_data.set('GETTEXT_PACKAGE', meson.project_name())
conf_data.set('VERSION', meson.project_version())

fs = import('fs')
if (fs.is_absolute(get_option('sysconfdir')))
  conf_data.set('SYSCONFDIR', get_option('sysconfdir'))
else
  conf_data.set('SYSCONFDIR', get_option('prefix') / get_option('sysconfdir'))
endif

config_header = configure_file(
  input: 'config.vala.in',
  output: 'config.vala',
  configuration: conf_data
)

sources_core = files([
  'Core/AppExcludeEntry.vala',
  'Core/DaemonClient.vala',
  'Core/DaemonBridge.vala',
  'Core/Main.vala',
  'Core/RepoBackend.vala',
  'Core/Snapshot.vala',
  'Core/SnapshotRepo.vala',
  'Core/Subvolume.vala',
])

sources_utility = files([
  'Utility/RepoLock.vala',
  'Utility/AsyncTask.vala',
  'Utility/CronTab.vala',
  'Utility/CryptTabEntry.vala',
  'Utility/DeleteFileTask.vala',
  'Utility/Device.vala',
  'Utility/FileItem.vala',
  'Utility/FsTabEntry.vala',
  'Utility/GtkHelper.vala',
  'Utility/IconManager.vala',
  'Utility/LauncherEntry.vala',
  'Utility/LicenseText.vala',
  'Utility/LinuxDistro.vala',
  'Utility/MountEntry.vala',
  'Utility/OSDNotify.vala',
  'Utility/RestoreScriptTask.vala',
  'Utility/RsyncSpaceCheckTask.vala',
  'Utility/RecoveryToolTask.vala',
  'Utility/RsyncTask.vala',
  'Utility/SystemUser.vala',
  'Utility/TimeoutCounter.vala',
  'Utility/TeeJee.FileSystem.vala',
  'Utility/TeeJee.Json.vala',
  'Utility/TeeJee.Logging.vala',
  'Utility/TeeJee.Misc.vala',
  'Utility/TeeJee.Process.vala',
  'Utility/TeeJee.System.vala',

  'Utility/Gtk/AppWindow.vala',
  'Utility/Gtk/AppTheme.vala',
  'Utility/Gtk/Banner.vala',
  'Utility/Gtk/ThemeStyle.vala',
  'Utility/Gtk/Ui.vala',
  'Utility/Gtk/ContentClamp.vala',
  'Utility/Gtk/StatusPage.vala',
  'Utility/Gtk/StatTile.vala',
  'Utility/Gtk/StatusCard.vala',
  'Utility/Gtk/PhaseList.vala',
  'Utility/Gtk/LogPane.vala',
  'Utility/Gtk/TaskProgressBox.vala',
  'Utility/Gtk/SummaryBox.vala',
  'Utility/Gtk/WizardWindow.vala',
  'Utility/Gtk/CustomMessageDialog.vala',
  'Utility/Gtk/TerminalWindow.vala',
])

sources_gtk = files([
  'Gtk/AppearanceBox.vala',
  'Gtk/BackupBox.vala',
  'Gtk/BackupDeviceBox.vala',
  'Gtk/BackupWindow.vala',
  'Gtk/BootOptionsBox.vala',
  'Gtk/BootOptionsWindow.vala',
  'Gtk/DeleteBox.vala',
  'Gtk/DeleteWindow.vala',
  'Gtk/EstimateBox.vala',
  'Gtk/ExcludeBox.vala',
  'Gtk/ExcludeListSummaryWindow.vala',
  'Gtk/JobMonitorWindow.vala',
  'Gtk/MainWindow.vala',
  'Gtk/MiscBox.vala',
  'Gtk/RecoveryBox.vala',
  'Gtk/RestoreBox.vala',
  'Gtk/RestoreDeviceBox.vala',
  'Gtk/RestoreProgressBox.vala',
  'Gtk/RestoreProgressWindow.vala',
  'Gtk/RestoreSummaryBox.vala',
  'Gtk/RestoreWindow.vala',
  'Gtk/RsyncLogBox.vala',
  'Gtk/RsyncLogWindow.vala',
  'Gtk/ScheduleBox.vala',
  'Gtk/SettingsWindow.vala',
  'Gtk/SetupWizardWindow.vala',
  'Gtk/SnapshotBackendBox.vala',
  'Gtk/SnapshotListBox.vala',
  'Gtk/UsersBox.vala',
])

sources_app_console = files([
  'AppConsole.vala',
])

sources_app_gtk = files([
  'AppGtk.vala',
])

vala_opts = [
  '--vapidir=' + meson.current_source_dir() / 'vapi',
  '--pkg', 'ioprio'
]

timeshift = executable('timeshift',
  sources_app_console + sources_core + sources_utility,
  config_header,
  dependencies: dependencies,
  install: true,
  vala_args: vala_opts
)

timeshift_gtk = executable('timeshift-gtk',
  sources_app_gtk + sources_core + sources_utility + sources_gtk,
  config_header,
  dependencies: dependencies,
  install: true,
  vala_args: vala_opts
)

install_data(
  sources : 'timeshift-launcher',
  install_dir : get_option('bindir')
)
install_data(
  sources : 'timeshift-gtk.desktop',
  install_dir : join_paths(get_option('datadir'), 'applications')
)

install_subdir('share', install_dir : '')
