/*
 * Main.vala
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

using GLib;
using Gtk;
using Gee;
using Json;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

public bool GTK_INITIALIZED = false;

public class Main : GLib.Object{
	
	public string app_path = "";
	public string share_folder = "";
	public string rsnapshot_conf_path = "";
	public string app_conf_path = "";
	public string app_conf_path_old = "";
	public string app_conf_path_default = "";
	public bool first_run = false;
	
	public string backup_uuid = "";
	public string backup_parent_uuid = "";

	/* Remote snapshot location. When backup_location_type is "ssh" the
	 * repository lives on another host and backup_uuid is unused. */
	public string backup_location_type = "local";
	public string backup_ssh_url = "";
	public string backup_ssh_key = "";
	public int backup_ssh_port = 0;
	public bool backup_ssh_fake_super = false;

	public bool btrfs_mode = true;
	public bool include_btrfs_home_for_backup = false;
	public bool include_btrfs_home_for_restore = false;
    public static bool btrfs_version__can_recursive_delete = false;
	
	public bool stop_cron_emails = true;

	/* The connection to timeshiftd, created on first use.
	 *
	 * Null when the daemon is not installed or not running, which is an
	 * ordinary state during the transition: this core still does all its own
	 * work, and the daemon is consulted only to find out whether something
	 * ELSE is already running. Nothing here depends on it being there. */
	public Gee.ArrayList<Device> partitions;

	public Gee.ArrayList<string> exclude_list_user;
	public Gee.ArrayList<string> exclude_list_default;
	public Gee.ArrayList<string> exclude_list_default_extra;
	public Gee.ArrayList<string> exclude_list_home;
	public Gee.ArrayList<string> exclude_list_restore;
	public Gee.ArrayList<AppExcludeEntry> exclude_list_apps;
	public Gee.ArrayList<MountEntry> mount_list;
	public Gee.ArrayList<string> exclude_app_names;
	
	public SnapshotRepo repo; 

	//temp
	//private Gee.ArrayList<Device> grub_device_list;

	public Device sys_root;
	public Device sys_boot;
	public Device sys_efi;
	public Device sys_home;
	public Gee.HashMap<string, Subvolume> sys_subvolumes;

	public string mount_point_restore = "";
	public string mount_point_app = "";

	public LinuxDistro current_distro;
	public bool mirror_system = false;

	public bool schedule_monthly = false;
	public bool schedule_weekly = false;
	public bool schedule_daily = false;
	public bool schedule_hourly = false;
	public bool schedule_boot = false;
	public int count_monthly = 2;
	public int count_weekly = 3;
	public int count_daily = 5;
	public int count_hourly = 6;
	public int count_boot = 5;

	// pause snapshots - use snapshots_paused to query this
	private string pause_snapshots_this_boot = ""; // if the string contains the current /proc/sys/kernel/random/boot_id: enabled; else: disabled
	private long pause_snapshots_until = 0; // unix time until snapshots are allowed again [s]

	// empty in "gui mode" contains mode in "cli mode"
	public string app_mode = "";

	public bool dry_run = false;

	//global vars for controlling threads
	public bool thr_success = false;
	
	public bool thread_restore_running = false;
	public bool thread_restore_success = false;

	public bool thread_delete_running = false;
	public bool thread_delete_success = false;

	public bool thread_subvol_info_running = false;
	public bool thread_subvol_info_success = false;

	public bool thread_snapshot_size_running = false;

	public int thr_retval = -1;
	public string thr_arg1 = "";
	public bool thr_timeout_active = false;
	public string thr_timeout_cmd = "";

	public int startup_delay_interval_mins = 10;
	public int retain_snapshots_max_days = 200;

	public const uint64 MIN_FREE_SPACE = 1 * GB;
	public static uint64 first_snapshot_size = 0;
	public static int64 first_snapshot_count = 0;
	
	public string log_dir = "";
	public string log_file = "";
	/* Serialises repository writes against the other Timeshift -- the Go
	 * daemon, or a second GUI. Taken around create, delete and restore only;
	 * see RepoLock. */
	public RepoLock repo_lock;

	public string date_format = "%Y-%m-%d %H:%M:%S";
	public const string date_format_default = "%Y-%m-%d %H:%M:%S";

	// appearance (GUI only; "system" defers to the desktop)
	public string theme_mode = "system";     // system | light | dark
	public string theme_accent = "system";   // system | a ThemeStyle preset key
	public const string theme_mode_default = "system";
	public const string theme_accent_default = "system";

	public Gee.ArrayList<Snapshot> delete_list;
	
	public Snapshot snapshot_to_delete;
	public Snapshot snapshot_to_restore;
	//public Device restore_target;
	public bool reinstall_grub2 = true;
	public bool update_initramfs = false;
	public bool update_grub = true;
	public string grub_device = "";
	public bool use_option_raw = true;

	public bool cmd_skip_grub = false;
	public string cmd_grub_device = "";
	public string cmd_target_device = "";
	public string cmd_backup_device = "";
	public string cmd_snapshot = "";
	public bool cmd_confirm = false;
	public bool cmd_verbose = true;
	public bool cmd_scripted = false;
	public string cmd_comments = "";
	public string cmd_tags = "";
	public bool? cmd_btrfs_mode = null;
	public string cmd_ssh_url = "";
	public string cmd_ssh_key = "";
	public int cmd_ssh_port = 0;
	
	public string progress_text = "";

	public Gtk.Window? parent_window = null;
	
	public RsyncTask task;
	public DeleteFileTask delete_file_task;

	/* Restore progress, for the GUI to poll.
	 *
	/* restore_phases is the checklist: the steps this restore will actually
	 * take, in order. restore_phase is the key of the step running now.
	 *
	 * Both are filled by DaemonBridge from the job's phase events. They used
	 * to be filled by the generated restore script's own @@TS_PHASE markers,
	 * which is why the field naming their task has gone with it. */
	public Gee.ArrayList<RestorePhase> restore_phases = new Gee.ArrayList<RestorePhase>();
	public string restore_phase = "";

	/* The dry run that precedes every rsync restore itemises exactly the
	 * lines the real run will emit, which makes it a far better denominator
	 * for the progress bar than a guessed file count. */
	public int64 restore_line_count_estimate = 0;

	/* How the last restore actually ended.
	 *
	 * A bare bool collapsed every distinct cause into "Completed With Errors"
	 * with no way to say which, so a 13 GB restore that worked and a bootloader
	 * step that failed looked identical -- and both looked like a lost restore.
	 */
	public enum RestoreOutcome { OK, WARNINGS, FAILED }

	public RestoreOutcome restore_outcome = RestoreOutcome.OK;

	/* Human-readable lines explaining the outcome: which files rsync skipped,
	 * which finish step failed, what to do next.
	 *
	 * Not "restore_messages": get_restore_messages() is an unrelated function
	 * that builds the *pre*-restore confirmation text, and the two reading
	 * alike cost real time during the audit. */
	public Gee.ArrayList<string> restore_outcome_messages = new Gee.ArrayList<string>();

	/* Set when a step AFTER the transfer failed. The remedy is completely
	 * different from a failed transfer -- the files are restored and only this
	 * step needs redoing -- so the two are tracked apart. */
	public string restore_failed_step = "";
	public string restore_failed_step_rc = "";

	/* Mount entries folded away because they duplicated an ancestor's device.
	 * Kept apart from restore_outcome_messages because the fold happens when
	 * the devices are mounted, which is before the restore -- and therefore
	 * before restore_outcome_reset() runs. */
	public Gee.ArrayList<string> mount_fold_notes = new Gee.ArrayList<string>();

	/* Reset at the start of every restore. Without this a second attempt in the
	 * same session inherits the first one's verdict. */
	public void restore_outcome_reset(){
		restore_outcome = RestoreOutcome.OK;
		restore_outcome_messages.clear();
		restore_failed_step = "";
		restore_failed_step_rc = "";

		// what was folded is part of explaining the result
		foreach(string line in mount_fold_notes){
			restore_outcome_messages.add(line);
		}
	}

	public void restore_note(string line){
		if ((line.length > 0) && !restore_outcome_messages.contains(line)){
			restore_outcome_messages.add(line);
		}
	}

	/* A restore that finished but could not do everything. Never downgrades a
	 * verdict that is already FAILED. */
	public void restore_warn(string line){
		if (restore_outcome == RestoreOutcome.OK){
			restore_outcome = RestoreOutcome.WARNINGS;
		}
		restore_note(line);
	}

	public void restore_fail(string line){
		restore_outcome = RestoreOutcome.FAILED;
		restore_note(line);
	}

	public Gee.HashMap<string, SystemUser> current_system_users;
	public string users_with_encrypted_home = "";
	public string encrypted_home_dirs = "";
	public bool encrypted_home_warning_shown = false;

    private int _live_system = -1;

	public string encrypted_private_dirs = "";
	public bool encrypted_private_warning_shown = false;

    protected enum QGroupStatus {
        UNKNOWN = -1,
        DISABLED = 0,
        ENABLED = 1
    }

    private QGroupStatus _btrfs_qgroups_enabled_internal = QGroupStatus.UNKNOWN;
    public bool btrfs_qgroups_enabled
    {
        get { return _btrfs_qgroups_enabled_internal == QGroupStatus.ENABLED; }
    }

	public Main(string[] args, bool gui_mode){
		
		this.mount_point_app = "/run/timeshift/%d".printf(Posix.getpid());
		dir_create(this.mount_point_app);
		
		parse_some_arguments(args);
	
		if (gui_mode){
			app_mode = "";
			parent_window = new Gtk.Window(); // dummy
		}

		log_debug("Main()");

		if (LOG_DEBUG || gui_mode){
			log_debug("");
			log_debug(_("Running") + " %s v%s".printf(AppName, AppVersion));
			log_debug("");
		}

		check_and_remove_timeshift_btrfs();

		// init log ------------------

		try {
			string suffix = gui_mode ? "gui" : app_mode;
			
			DateTime now = new DateTime.now_local();
			log_dir = "/var/log/timeshift";
			log_file = path_combine(log_dir,
				"%s_%s.log".printf(now.format("%Y-%m-%d_%H-%M-%S"), suffix));

			var file = File.new_for_path (log_dir);
			if (!file.query_exists ()) {
				file.make_directory_with_parents();
			}

			file = File.new_for_path (log_file);
			if (file.query_exists ()) {
				file.delete ();
			}

			TeeJee.Logging.dos_log = new DataOutputStream (file.create(FileCreateFlags.REPLACE_DESTINATION));

			// Session logs record command lines and device details and are
			// kept for hundreds of runs; there is no reason for them to be
			// world-readable.
			Posix.chmod(log_file, 0600);

			if (LOG_DEBUG || gui_mode){
				log_debug(_("Session log file") + ": %s".printf(log_file));
			}
		}
		catch (Error e) {
			log_error (e.message);
		}
		
		// get Linux distribution info -----------------------
		
		this.current_distro = LinuxDistro.get_dist_info("/");

		if (LOG_DEBUG || gui_mode){
			log_debug(_("Distribution") + ": " + current_distro.full_name());
			log_debug("DIST_ID" + ": " + current_distro.dist_id);
		}

		// check dependencies ---------------------

		string message;
		if (!check_dependencies(out message)){
			if (gui_mode){
				string title = _("Missing Dependencies");
				gtk_messagebox(title, message, null, true);
			}
			exit_app(1);
		}

        check_btrfs_version_capabilities();

		/* No single-instance lock here any more.
		 *
		 * AppLock refused a second PROCESS, for every invocation including
		 * --list. That is why a snapshot started by apt-snapshot-guard could
		 * not be watched at all: opening the GUI while it ran was refused
		 * outright, which is the defect this whole port exists to remove.
		 *
		 * What actually needs serialising is a repository WRITE, and RepoLock
		 * does that around create, delete and restore -- shared with
		 * timeshiftd, which never took AppLock and so was never excluded by
		 * it. Reads are now free to run beside anything. */
		repo_lock = new RepoLock();

		// initialize variables -------------------------------

		this.app_path = (File.new_for_path (args[0])).get_parent().get_path ();
		this.share_folder = "/usr/share";
		this.app_conf_path = "/etc/timeshift/timeshift.json";
		this.app_conf_path_old = "/etc/timeshift.json";
		this.app_conf_path_default = GLib.Path.build_path (GLib.Path.DIR_SEPARATOR_S, Constants.SYSCONFDIR, "timeshift", "default.json");
		//sys_root and sys_home will be initialized by update_partition_list()
		
		// check if running locally ------------------------

		string local_exec = args[0];
		string local_conf = app_path + "/timeshift.json";
		string local_share = app_path + "/share";

		var f_local_exec = File.new_for_path(local_exec);
		if (f_local_exec.query_exists()){

			var f_local_conf = File.new_for_path(local_conf);
			if (f_local_conf.query_exists()){
				this.app_conf_path = local_conf;
			}

			var f_local_share = File.new_for_path(local_share);
			if (f_local_share.query_exists()){
				this.share_folder = local_share;
			}
		}
		else{
			//timeshift is running from system directory - update app_path
			this.app_path = Environment.find_program_in_path("timeshift");
		}

		// initialize lists -----------------

		repo = new SnapshotRepo();
		mount_list = new Gee.ArrayList<MountEntry>();
		delete_list = new Gee.ArrayList<Snapshot>();
		sys_subvolumes = new Gee.HashMap<string, Subvolume>();
		exclude_app_names = new Gee.ArrayList<string>();
		add_default_exclude_entries();
		//add_app_exclude_entries();
		task = new RsyncTask();
		delete_file_task = new DeleteFileTask();

		update_partitions();
		
		detect_system_devices();

		detect_encrypted_dirs();

		// set settings from config file ---------------------

		load_app_config();

		IconManager.init(args, AppShortName);
		
		log_debug("Main(): ok");
	}

	public void initialize(){
		
		// clear browse mounts a previous run left behind (crash, SIGKILL)
		reap_stale_browse_mounts();

		initialize_repo();
	}

	public bool check_dependencies(out string msg){
		log_debug("Main: check_dependencies()");
		
		/* "crontab" was here, and the app refused to start without it. The
		 * schedule belongs to timeshiftd now, and the only thing left that
		 * reaches for cron is the sweep that removes what older versions wrote
		 * -- which deletes files under /etc/cron.d directly and treats an
		 * absent crontab(1) as an empty crontab. Requiring the binary would
		 * mean depending on a cron daemon that nothing here uses. */
		string[] dependencies = { "rsync","/sbin/blkid","df","mount","umount","fuser","cp","rm","touch","ln","sync", "run-parts"}; //"shutdown","chroot",

		msg = "";
		foreach(string cmd_tool in dependencies){
			if(!cmd_exists(cmd_tool)) {
				msg += " * " + cmd_tool + "\n";
			}
		}

		if (msg.length > 0){
			msg = _("Commands listed below are not available on this system") + ":\n\n" + msg + "\n";
			msg += _("Please install required packages and try running TimeShift again");
			log_error(msg);
			return false;
		}
		else{
			return true;
		}
	}

	// copy env from the spawning parent to this
	public static void setup_env() {

		/* TIMESHIFT_KEEP_ENV=1 leaves the environment exactly as it was found.
		 *
		 * Normally this method scavenges DISPLAY, XAUTHORITY and the Wayland
		 * variables from the invoking user's session, because under pkexec the
		 * GUI runs as root with none of them. That is right in production and
		 * makes the GUI impossible to test: a run under Xvfb has its DISPLAY
		 * replaced by the real one, and the window opens on the tester's actual
		 * screen instead of the virtual display.
		 *
		 * It grants nothing. Anyone who can set an environment variable on a
		 * root process already has root; all this does is decline to overwrite
		 * what they set. Same family as TIMESHIFT_THEME_CSS and
		 * TIMESHIFT_RESTORE_TERMINAL. */
		if (GLib.Environment.get_variable("TIMESHIFT_KEEP_ENV") == "1"){
			return;
		}

		Pid user_pid = TeeJee.ProcessHelper.get_user_process();
		string[]? user_env = TeeJee.ProcessHelper.get_process_env(user_pid);
		if(user_env == null) {
			return;
		}

		// copy all required enviroment vars from the user to this process
		string[] targets = {"GTK_THEME", "DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"};
		foreach (string target in targets) {
			string user_var = TeeJee.ProcessHelper.get_env(user_env, target);
			if(user_var != null) {
				GLib.Environment.set_variable(target, user_var, true);
			}
		}

		string xdg_runtime_dir = TeeJee.ProcessHelper.get_env(user_env, "XDG_RUNTIME_DIR");
		string wayland_display = TeeJee.ProcessHelper.get_env(user_env, "WAYLAND_DISPLAY");

		if (wayland_display != null && xdg_runtime_dir != null) {
			string path = "%s/%s".printf(xdg_runtime_dir, wayland_display);
			GLib.Environment.set_variable("WAYLAND_DISPLAY", path, true);
			GLib.Environment.set_variable("XDG_RUNTIME_DIR", "/run/user/0", true);
		}
	}

    private int[]? get_btrfs_version_array () {
        string stdout;
        string stderr;
        int exit_status;

        try {
            GLib.Process.spawn_command_line_sync(
                "btrfs --version",
                out stdout,
                out stderr,
                out exit_status
            );
        } catch (GLib.Error e) {
            log_debug("Failed to run btrfs command. Is btrfs-progs installed?");
            return null;
        }

        log_debug("Checking btrfs-progs version and determining capabilities...");

        if (exit_status != 0) {
            log_error("btrfs command failed with exit code %d: %s".printf(exit_status, stderr));
            return null;
        }

        string[] lines = stdout.strip().split("\n");
        if (lines.length == 0) {
            log_error("No output from btrfs --version");
            return null;
        }

        string version_line = null;
        foreach (string line in lines) {
            if (line.contains("btrfs-progs")) {
                version_line = line;
                break;
            }
        }

        if (version_line == null) {
            log_error("Could not find btrfs-progs version line in output");
            return null;
        }

        string version_prefix = "btrfs-progs v";
        int prefix_index = version_line.index_of(version_prefix);
        if (prefix_index == -1) {
            log_error("Could not detect version");
            return null;
        }

        string version_string = version_line.substring(prefix_index + version_prefix.length);
        string[] version_parts = version_string.split(".");

        if (version_parts.length < 2) {
            log_error("No version components found in: %s".printf(version_string));
            return null;
        }

        int[] version = new int[5];

        // version = new int[version_parts.length];
        for (int i = 0; i < version_parts.length; i++) {
            version[i] = int.parse(version_parts[i].strip());
        }

        return version;
    }

    public void check_btrfs_version_capabilities() {
        var version = get_btrfs_version_array();

        if (version != null) {
            btrfs_version__can_recursive_delete = version[0] > 6 || (version[0] == 6 && version[1] >= 12);
            log_debug("-- btrfs-progs version %d.%d.x".printf(version[0], version[1]));
        }

        log_debug("-- btrfs subvolume recursive delete: %s".printf(btrfs_version__can_recursive_delete ? "supported" : "not supported"));
    }

	public void check_and_remove_timeshift_btrfs(){
		
		if (cmd_exists("timeshift-btrfs")){
			string std_out, std_err;
			exec_sync("timeshift-btrfs-uninstall", out std_out, out std_err);
			log_msg(_("** Uninstalled Timeshift BTRFS **"));
		}
	}
	
	public bool check_btrfs_layout_system(Gtk.Window? win = null){

		log_debug("check_btrfs_layout_system()");

		bool supported = sys_subvolumes.has_key("@");
		if (include_btrfs_home_for_backup){
			supported =  supported && sys_subvolumes.has_key("@home");
		}

		if (!supported){
			string msg = _("The system partition has an unsupported subvolume layout.") + " ";
			msg += _("Only ubuntu-type layouts with @ and @home subvolumes are currently supported.") + "\n\n";
			msg += _("Application will exit.") + "\n\n";
			string title = _("Not Supported");
			
			if (app_mode == ""){
				gtk_set_busy(false, win);
				gtk_messagebox(title, msg, win, true);
			}
			else{
				log_error(msg);
			}
		}

		return supported;
	}

	public bool check_btrfs_layout(Device? dev_root, Device? dev_home, bool unlock){
		
		bool supported = true; // keep true for non-btrfs systems

		if ((dev_root != null) && (dev_root.fstype == "btrfs")){
			
			if ((dev_home != null) && (dev_home.fstype == "btrfs")){

				if (dev_home != dev_root){
					
					supported = supported && check_btrfs_volume(dev_root, "@", unlock);

					if (include_btrfs_home_for_backup){
						supported = supported && check_btrfs_volume(dev_home, "@home", unlock);
					}
				}
				else{
					if (include_btrfs_home_for_backup){
						supported = supported && check_btrfs_volume(dev_root, "@,@home", unlock);
					}
					else{
						supported = supported && check_btrfs_volume(dev_root, "@", unlock);
					}
				}
			}
		}

		return supported;
	}

	/* Flags that must take effect before initialize() runs.
	 *
	 * This used to parse a subset of the CLI a SECOND time -- AppConsole
	 * parsed the same argv again afterwards -- so a new flag had to be added
	 * in two places or it worked only by accident. There is no Vala CLI any
	 * more (/usr/bin/timeshift is the Go binary), and AppGtk accepts exactly
	 * one option, so all that is left is the one flag whose effect is needed
	 * before the constructor finishes.
	 *
	 * The app_mode assignments that used to live here are gone with it. They
	 * could only ever be set by the console binary: app_mode == "" means GUI
	 * mode throughout the core, and the GUI is now the only caller.
	 */
	private void parse_some_arguments(string[] args){

		for (int k = 1; k < args.length; k++) // 0th arg is app path
		{
			if (args[k].down() == "--debug"){
				// AppGtk sets LOG_DEBUG again once it parses; LOG_COMMANDS is
				// only ever set here, and commands run during initialize().
				LOG_COMMANDS = true;
				LOG_DEBUG = true;
			}
		}
	}

	private void detect_encrypted_dirs(){
		
		current_system_users = SystemUser.read_users_from_file("/etc/passwd");

		string txt = "";
		users_with_encrypted_home = "";
		encrypted_home_dirs = "";
		encrypted_private_dirs = "";
		
		foreach(var user in current_system_users.values){
			
			if (user.is_system) { continue; }
			
			if (txt.length > 0) { txt += " "; }
			txt += "%s".printf(user.name);

			if (user.has_encrypted_home){
				
				users_with_encrypted_home += " %s".printf(user.name);

				encrypted_home_dirs += "%s\n".printf(user.home_path);
			}

			if (user.has_encrypted_private_dirs){

				foreach(string enc_path in user.encrypted_private_dirs){
					encrypted_private_dirs += "%s\n".printf(enc_path);
				}
			}
		}
		users_with_encrypted_home = users_with_encrypted_home.strip();
		
		log_debug("Users: %s".printf(txt));
		log_debug("Encrypted home users: %s".printf(users_with_encrypted_home));
		log_debug("Encrypted home dirs:\n%s".printf(encrypted_home_dirs));
		log_debug("Encrypted private dirs:\n%s".printf(encrypted_private_dirs));
	}
	
	// exclude lists
	
	/* Returns the file-backed swap areas currently in use, from /proc/swaps.
	 * Swap partitions are ignored - only files can end up inside a snapshot. */
	public Gee.ArrayList<string> get_swap_file_paths(){

		var list = new Gee.ArrayList<string>();

		string? text = file_read("/proc/swaps");
		if (text == null){ return list; }

		bool first = true;

		foreach(string line in text.split("\n")){

			if (first){ first = false; continue; } // header
			if (line.strip().length == 0){ continue; }

			string[] parts = Regex.split_simple("""[ \t]+""", line.strip());
			if (parts.length < 2){ continue; }
			if (parts[1] != "file"){ continue; } // skip swap partitions

			string path = parts[0].strip();
			if (path.has_prefix("/")){ list.add(path); }
		}

		return list;
	}

	public void add_default_exclude_entries(){

		log_debug("Main: add_default_exclude_entries()");
		
		exclude_list_user = new Gee.ArrayList<string>();
		exclude_list_default = new Gee.ArrayList<string>();
		exclude_list_default_extra = new Gee.ArrayList<string>();
		exclude_list_home = new Gee.ArrayList<string>();
		exclude_list_restore = new Gee.ArrayList<string>();
		exclude_list_apps = new Gee.ArrayList<AppExcludeEntry>();
		
		partitions = new Gee.ArrayList<Device>();

		// default exclude entries -------------------

		exclude_list_default.add("/dev/*");
		exclude_list_default.add("/proc/*");
		exclude_list_default.add("/sys/*");
		exclude_list_default.add("/media/*");
		exclude_list_default.add("/mnt/*");
		exclude_list_default.add("/tmp/*");
		exclude_list_default.add("/run/*");
		exclude_list_default.add("/var/run/*");
		exclude_list_default.add("/var/lock/*");
		//exclude_list_default.add("/var/spool/*");
		exclude_list_default.add("/var/lib/dhcpcd/*");
		exclude_list_default.add("/var/lib/docker/*");
		exclude_list_default.add("/var/lib/schroot/*");
		// The recovery environment's build cache and placed payload: a multi-
		// gigabyte squashfs plus a kernel and initramfs. Snapshotting them is
		// pointless - "timeshift-recovery build" reproduces the lot - and
		// actively harmful in two ways. Over a remote repository the transfer
		// can exceed apt-snapshot-guard's timeout, and because that guard is
		// fail-closed, a snapshot that times out blocks apt entirely. Restoring
		// them would also be wrong: the payload must match the Timeshift
		// installed now, not the one current when the snapshot was taken.
		exclude_list_default.add("/var/cache/timeshift-recovery/*");
		exclude_list_default.add("/var/lib/timeshift-recovery/*");
		exclude_list_default.add("/lost+found");
		exclude_list_default.add("/timeshift/*");
		exclude_list_default.add("/timeshift-btrfs/*");
		exclude_list_default.add("/data/*");
		exclude_list_default.add("/DATA/*");
		exclude_list_default.add("/cdrom/*");
		exclude_list_default.add("/sdcard/*");
		exclude_list_default.add("/system/*");
		exclude_list_default.add("/etc/timeshift.json"); // legacy config path
		// The live config lives in /etc/timeshift/, and so does the SSH private
		// key for a remote repository. Backing that directory up would place the
		// key inside the very repo it unlocks, readable by anyone with access to
		// the share. It would also mean a full restore reverts or deletes the key
		// and silently breaks scheduled backups.
		exclude_list_default.add("/etc/timeshift/*");
		exclude_list_default.add("/var/log/timeshift/*");
		exclude_list_default.add("/var/log/timeshift-btrfs/*");
		exclude_list_default.add("/swapfile");
		exclude_list_default.add("/swap.img"); // Ubuntu's default since 17.04
		/* Snaps: skip the mounted squashfs contents, keep the symlinks.
		 *
		 * "/snap/*" alone was a kilobyte too broad. Besides the read-only
		 * mountpoints it also swept up the only two things snapd keeps in
		 * /snap as REAL files: /snap/bin/* (every snap command is a symlink
		 * there to /usr/bin/snap) and /snap/<name>/current. Without them a
		 * restored system has all 2.6 GB of .snap payloads, working mount
		 * units and correct desktop files -- and still answers "requires the
		 * firefox snap to be installed", because /usr/bin/firefox is a shim
		 * that tests /snap/bin/firefox.
		 *
		 * The exclusion is still right about the mounted content: there is no
		 * --one-file-system anywhere, so rsync would otherwise walk the
		 * decompressed squashfs -- 153,354 entries here versus 78, and the 78
		 * total 1,124 bytes.
		 *
		 * Order matters and these are read first-match-wins, so the includes
		 * must precede the exclude. The exclude is one level deeper than the
		 * old rule on purpose: /snap/<name> must stay traversable for
		 * "current" to be reachable. */
		exclude_list_default.add("+ /snap/bin/***");
		exclude_list_default.add("+ /snap/*/current");
		exclude_list_default.add("- /snap/*/*");

		// The names above cover the common cases (/swapfile on Debian,
		// /swap.img on Ubuntu) and still apply when swap is switched off but
		// the file is left on disk - /proc/swaps is empty then, yet the file
		// would still be copied. This pass adds whatever is actually in use,
		// so a swap file at any other path is caught too. Copying swap is
		// pointless, and an 8 GB file dominates a remote transfer.
		foreach(string swap_path in get_swap_file_paths()){
			if (!exclude_list_default.contains(swap_path)){
				exclude_list_default.add(swap_path);
				log_debug("excluding active swap file: %s".printf(swap_path));
			}
		}

		foreach(var entry in FsTabEntry.read_file("/etc/fstab")){

			if (!entry.mount_point.has_prefix("/")){ continue; }

			// ignore standard system folders
			if (entry.mount_point == "/"){ continue; }
			if (entry.mount_point.has_prefix("/bin")){ continue; }
			if (entry.mount_point.has_prefix("/boot")){ continue; }
			if (entry.mount_point.has_prefix("/cdrom")){ continue; }
			if (entry.mount_point.has_prefix("/dev")){ continue; }
			if (entry.mount_point.has_prefix("/etc")){ continue; }
			if (entry.mount_point.has_prefix("/home")){ continue; }
			if (entry.mount_point.has_prefix("/lib")){ continue; }
			if (entry.mount_point.has_prefix("/lib64")){ continue; }
			if (entry.mount_point.has_prefix("/media")){ continue; }
			if (entry.mount_point.has_prefix("/mnt")){ continue; }
			if (entry.mount_point.has_prefix("/opt")){ continue; }
			if (entry.mount_point.has_prefix("/proc")){ continue; }
			if (entry.mount_point.has_prefix("/root")){ continue; }
			if (entry.mount_point.has_prefix("/run")){ continue; }
			if (entry.mount_point.has_prefix("/sbin")){ continue; }
			if (entry.mount_point.has_prefix("/snap")){ continue; }
			if (entry.mount_point.has_prefix("/srv")){ continue; }
			if (entry.mount_point.has_prefix("/sys")){ continue; }
			if (entry.mount_point.has_prefix("/system")){ continue; }
			if (entry.mount_point.has_prefix("/tmp")){ continue; }
			if (entry.mount_point.has_prefix("/usr")){ continue; }
			if (entry.mount_point.has_prefix("/var")){ continue; }

			// add exclude entry for devices mounted to non-standard locations

			exclude_list_default_extra.add(entry.mount_point + "/*");
		}

		exclude_list_default.add("/root/.thumbnails");
		exclude_list_default.add("/root/.cache");
		exclude_list_default.add("/root/.dbus");
		exclude_list_default.add("/root/.gvfs");
		exclude_list_default.add("/root/.local/share/[Tt]rash");

		exclude_list_default.add("/home/*/.thumbnails");
		exclude_list_default.add("/home/*/.cache");
		exclude_list_default.add("/home/*/.dbus");
		exclude_list_default.add("/home/*/.gvfs");
		exclude_list_default.add("/home/*/.local/share/[Tt]rash");

		// default extra ------------------

		exclude_list_default_extra.add("/root/.mozilla/firefox/*.default/Cache");
		exclude_list_default_extra.add("/root/.mozilla/firefox/*.default/OfflineCache");
		exclude_list_default_extra.add("/root/.opera/cache");
		exclude_list_default_extra.add("/root/.kde/share/apps/kio_http/cache");
		exclude_list_default_extra.add("/root/.kde/share/cache/http");

		exclude_list_default_extra.add("/home/*/.mozilla/firefox/*.default/Cache");
		exclude_list_default_extra.add("/home/*/.mozilla/firefox/*.default/OfflineCache");
		exclude_list_default_extra.add("/home/*/.opera/cache");
		exclude_list_default_extra.add("/home/*/.kde/share/apps/kio_http/cache");
		exclude_list_default_extra.add("/home/*/.kde/share/cache/http");

		exclude_list_default_extra.add("/var/cache/apt/archives/*");
		exclude_list_default_extra.add("/var/cache/pacman/pkg/*");
		exclude_list_default_extra.add("/var/cache/yum/*");
		exclude_list_default_extra.add("/var/cache/dnf/*");
		exclude_list_default_extra.add("/var/cache/eopkg/*");
		exclude_list_default_extra.add("/var/cache/xbps/*");
		exclude_list_default_extra.add("/var/cache/zypp/*");
		exclude_list_default_extra.add("/var/cache/edb/*");
		
		// default home ----------------

		//exclude_list_home.add("+ /root/.**");
		//exclude_list_home.add("+ /home/*/.**");
		exclude_list_home.add("/root/**");
		exclude_list_home.add("/home/*/**"); // Note: /home/** ignores include filters under /home

		/*
		Most web browsers store their cache under ~/.cache and /tmp
		These files will be excluded by the entries for ~/.cache and /tmp
		There is no need to add special entries.

		~/.cache/google-chrome			-- Google Chrome
		~/.cache/chromium				-- Chromium
		~/.cache/epiphany-browser		-- Epiphany
		~/.cache/midori/web				-- Midori
		/var/tmp/kdecache-$USER/http	-- Rekonq
		*/

		log_debug("Main: add_default_exclude_entries(): exit");
	}

	public void add_app_exclude_entries(){

		log_debug("Main: add_app_exclude_entries()");
		
		AppExcludeEntry.clear();
		
		if (snapshot_to_restore != null){
			add_app_exclude_entries_for_prefix(path_combine(snapshot_to_restore.path, "localhost"));
		}

		//if (!restore_current_system){
		//	add_app_exclude_entries_for_prefix(mount_point_restore);
		//}

		exclude_list_apps = AppExcludeEntry.get_apps_list(exclude_app_names);

		log_debug("Main: add_app_exclude_entries(): exit");
	}

	private void add_app_exclude_entries_for_prefix(string path_prefix){
		
		string path = "";

		path = path_combine(path_prefix, "root");
		AppExcludeEntry.add_app_exclude_entries_from_path(path);

		path = path_combine(path_prefix, "home");
		AppExcludeEntry.add_app_exclude_entries_from_home(path);
	}
	

	public Gee.ArrayList<string> create_exclude_list_for_backup(){

		log_debug("Main: create_exclude_list_for_backup()");
		
		var list = new Gee.ArrayList<string>();

		// add user entries from current setting
		// user entry is first since rsync prioritizes the first
		// inclusion/exclusion patterns seen
		//  -------------------------------------------------------
		
		foreach(string path in exclude_list_user){
			if (!list.contains(path)){
				list.add(path);
			}
		}

		// add default entries ---------------------------
		
		foreach(string path in exclude_list_default){
			if (!list.contains(path)){
				list.add(path);
			}
		}

		// add default extra entries ---------------------------
		
		foreach(string path in exclude_list_default_extra){
			if (!list.contains(path)){
				list.add(path);
			}
		}

		// add entries to exclude **decrypted** contents in $HOME
		// decrypted contents should never be backed-up or restored
		// this overrides all other user entries in exclude_list_user
		//  -------------------------------------------------------
		
		foreach(var user in current_system_users.values){
			
			if (user.is_system){ continue; }
			
			if (user.has_encrypted_home){
				
				// exclude decrypted contents in user's home ($HOME)
				string path = "%s/**".printf(user.home_path);
				list.add(path);
			}
			
			if (user.has_encrypted_private_dirs){

				foreach(string enc_path in user.encrypted_private_dirs){
					
					// exclude decrypted contents in private dirs ($HOME/Private)
					string path = "%s/**".printf(enc_path);
					list.add(path);
				}
			}
		}

		// exclude each user individually if not included in exclude_list_user

		foreach(var user in current_system_users.values){

			if (user.is_system){ continue; }

			string exc_pattern = "%s/**".printf(user.home_path);
			string inc_pattern = "+ %s/**".printf(user.home_path);
			string inc_hidden_pattern = "+ %s/.**".printf(user.home_path);

			if (user.has_encrypted_home){
				inc_pattern = "+ /home/.ecryptfs/%s/***".printf(user.name);
				exc_pattern = "/home/.ecryptfs/%s/***".printf(user.name);
			}
			
			bool include_hidden = exclude_list_user.contains(inc_hidden_pattern);
			bool include_all = exclude_list_user.contains(inc_pattern);
			bool exclude_all = !include_hidden && !include_all;

			if (exclude_all){
				if (!exclude_list_user.contains(exc_pattern)){
					exclude_list_user.add(exc_pattern);
				}
				if (exclude_list_user.contains(inc_pattern)){
					exclude_list_user.remove(inc_pattern);
				}
				if (exclude_list_user.contains(inc_hidden_pattern)){
					exclude_list_user.remove(inc_hidden_pattern);
				}
			}
		}

		// add common entries for excluding home folders for all users --------
		
		foreach(string path in exclude_list_home){
			if (!list.contains(path)){
				list.add(path);
			}
		}

		string timeshift_path = "/timeshift/*";
		if (!list.contains(timeshift_path)){
			list.add(timeshift_path);
		}

		log_debug("Main: create_exclude_list_for_backup(): exit");
		
		return list;
	}

	public Gee.ArrayList<string> create_exclude_list_for_restore(){

		log_debug("Main: create_exclude_list_for_restore()");
		
		exclude_list_restore.clear();
		
		//add user entries from current settings
		//user entry is first since rsync prioritizes the first
		//inclusion/exclusion patterns seen
		foreach(string path in exclude_list_user){

			// skip include filters for restore
			if (path.strip().has_prefix("+")){ continue; }
	
			if (!exclude_list_restore.contains(path) && !exclude_list_home.contains(path)){
				exclude_list_restore.add(path);
			}
		}

		//add user entries from snapshot exclude list
		if (snapshot_to_restore != null){
			// Use the list already parsed through the repository backend.
			// Reading <snapshot>/exclude.list with local file calls silently
			// found nothing for a remote repo, so the exclusions recorded at
			// backup time were not applied when restoring.
			foreach(string path in snapshot_to_restore.exclude_list){
				if (!exclude_list_restore.contains(path) && !exclude_list_home.contains(path)){
					exclude_list_restore.add(path);
				}
			}
		}

		//add default entries
		foreach(string path in exclude_list_default){
			if (!exclude_list_restore.contains(path)){
				exclude_list_restore.add(path);
			}
		}

		if (!mirror_system){
			//add default_extra entries
			foreach(string path in exclude_list_default_extra){
				if (!exclude_list_restore.contains(path)){
					exclude_list_restore.add(path);
				}
			}
		}

		//add app entries
		foreach(var entry in exclude_list_apps){
			if (entry.enabled){
				foreach(var pattern in entry.patterns){
					if (!exclude_list_restore.contains(pattern)){
						exclude_list_restore.add(pattern);
					}
				}
			}
		}

		//add home entries
		foreach(string path in exclude_list_home){
			if (!exclude_list_restore.contains(path)){
				exclude_list_restore.add(path);
			}
		}

		string timeshift_path = "/timeshift/*";
		if (!exclude_list_restore.contains(timeshift_path)){
			exclude_list_restore.add(timeshift_path);
		}

		log_debug("Main: create_exclude_list_for_restore(): exit");
		
		return exclude_list_restore;
	}


	/* Writes the filter rsync will use. The destination is restore_exclude_file
	 * and always was: the old output_path parameter was never read. */
	public bool save_exclude_list_for_restore(){

		log_debug("Main: save_exclude_list_for_restore()");
		
		var list = create_exclude_list_for_restore();

		log_debug("Exclude list -------------");
		
		var txt = "";
		foreach(var pattern in list){
			if (pattern.strip().length > 0){
				txt += "%s\n".printf(pattern);
				log_debug(pattern);
			}
		}
		
		return file_write(restore_exclude_file, txt);
	}

	public void save_exclude_list_selections(){

		log_debug("Main: save_exclude_list_selections()");
		
		// add new selected items
		foreach(var entry in exclude_list_apps){
			if (entry.enabled && !exclude_app_names.contains(entry.name)){
				exclude_app_names.add(entry.name);
				log_debug("add app name: %s".printf(entry.name));
			}
		}

		// remove item only if present in current list and un-selected
		foreach(var entry in exclude_list_apps){
			if (!entry.enabled && exclude_app_names.contains(entry.name)){
				exclude_app_names.remove(entry.name);
				log_debug("remove app name: %s".printf(entry.name));
			}
		}

		exclude_app_names.sort((a,b) => {
			return Posix.strcmp(a,b);
		});
	}

	// properties
	
	/* daemon returns the client, connecting once and remembering the answer.
	 *
	 * Retrying on every call would mean a stat and a connect attempt per GUI
	 * refresh on a machine with no daemon, which is most of them today. */
	/* The daemon connection, shared with everything else in the process.
	 *
	 * The lazy singleton lives in DaemonApi rather than here, because most of
	 * this class's start-up runs from its own CONSTRUCTOR and the global `App`
	 * is not assigned until that returns -- so a client reached through App is
	 * unreachable from update_partitions(), detect_system_devices() and
	 * load_app_config(), which are exactly the places that want it. */
	public unowned DaemonClient? daemon {
		get { return DaemonApi.get_shared_client(); }
	}

	/* The daemon's methods, typed. Null when there is no daemon.
	 *
	 * Shares the one connection `daemon` opened rather than making a second:
	 * every synchronous call goes down that single request/response socket, and
	 * a second one would only add a second thing to keep alive. The event
	 * stream is separate already, inside DaemonClient, for the reason given
	 * there -- a call must never come back with an event's answer.
	 */
	public unowned DaemonApi? daemon_api {
		get { return DaemonApi.get_shared(); }
	}

	public bool scheduled{
		get{
			return !live_system()
			&& (schedule_boot || schedule_hourly || schedule_daily ||
				schedule_weekly || schedule_monthly);
		}
	}

    public bool live_system(){
        /* Initialize once block */
        if (_live_system == -1) {
            var cmdline = file_read("/proc/cmdline");

            if (cmdline.contains("boot=casper") || cmdline.contains("boot=live")) {
                log_msg ("Live Session detected, backup is disabled.");
                _live_system = 1;
            } else {
                _live_system = 0;
            }
        }

        return (_live_system == 1);
    }

	// backup


	public void validate_cmd_tags(){
		foreach(string tag in cmd_tags.split(",")){
			switch(tag.strip().up()){
			case "O":
			case "B":
			case "H":
			case "D":
			case "W":
			case "M":
				break;
			default:
				log_error(_("Unknown value specified for option --tags") + " (%s).".printf(tag));
				log_error(_("Expected values: O, B, H, D, W, M"));
				exit_app(1);
				break;
			}
		}
	}
	
	// gui delete

	
	// restore  - properties

	public Device? dst_root{
		get {
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/"){
					return mnt.device;
				}
			}
			return null;
		}
		set{
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/"){
					mnt.device = value;
					break;
				}
			}
		}
	}

	public Device? dst_boot{
		get {
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/boot"){
					return mnt.device;
				}
			}
			return null;
		}
		set{
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/boot"){
					mnt.device = value;
					break;
				}
			}
		}
	}

	public Device? dst_efi{
		get {
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/boot/efi"){
					return mnt.device;
				}
			}
			return null;
		}
		set{
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/boot/efi"){
					mnt.device = value;
					break;
				}
			}
		}
	}

	public Device? dst_home{
		get {
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/home"){
					return mnt.device;
				}
			}
			return null;
		}
		set{
			foreach(var mnt in mount_list){
				if (mnt.mount_point == "/home"){
					mnt.device = value;
					break;
				}
			}
		}
	}
	
	public bool restore_current_system{
		get {
			if ((sys_root != null) &&
				((dst_root != null && dst_root.device == sys_root.device) || (dst_root != null && dst_root.uuid == sys_root.uuid))){
					
				return true;
			}
			else{
				return false;
			}
		}
	}

	public string restore_source_path{
		owned get {
			if (mirror_system){
				string source_path = "/tmp/timeshift";
				dir_create(source_path);
				return source_path;
			}
			else{
				return snapshot_to_restore.path;
			}
		}
	}
	
	public string restore_target_path{
		owned get {
			if (restore_current_system){
				return "/";
			}
			else{
				return mount_point_restore + "/";
			}
		}
	}

	/* rsync opens --log-file and --exclude-from on the client side, so for a
	 * remote repository these have to live locally rather than inside the
	 * snapshot. */
	private bool repo_is_remote(){
		return (repo != null) && repo.backend.is_remote;
	}

	public string restore_log_file{
		owned get {

			/* On the target itself whenever the target is not the running
			 * system.
			 *
			 * TEMP_DIR is tmpfs in a live recovery environment, and an -aiir
			 * log of a whole root filesystem is hundreds of megabytes of RAM.
			 * When that tmpfs fills, the .timeshift-restore-failed sentinel --
			 * which lives beside this file, and is the one signal that stops a
			 * failed restore from installing a boot loader -- cannot be written
			 * either. Fail-closed must not depend on free RAM.
			 *
			 * It is safe on the target: /var/log/timeshift/* is in the restore
			 * exclude list and --delete-excluded is off, so rsync leaves it
			 * alone. It also means the log survives the reboot, on the restored
			 * system, where the last restore's log was simply missing before. */
			if (!restore_current_system
				&& (mount_point_restore != null)
				&& (mount_point_restore.length > 0)){

				return path_combine(restore_target_path, "var/log/timeshift/rsync-log-restore");
			}

			if (repo_is_remote()){
				return path_combine(TEMP_DIR, "rsync-log-restore");
			}
			return restore_source_path + "/rsync-log-restore";
		}
	}

	/* Output of the post-transfer steps (bootloader, initramfs, hooks), beside
	 * the rsync log on the restored system. */
	public string restore_steps_log_file(){
		return path_combine(file_parent(restore_log_file), "restore-steps.log");
	}

	public string restore_exclude_file{
		owned get {
			if (repo_is_remote()){
				return path_combine(TEMP_DIR, "exclude-restore.list");
			}
			return restore_source_path + "/exclude-restore.list";
		}
	}

	// restore
	 
	/* Builds mount_list from restore.plan's default selection.
	 *
	 * False means the daemon could not answer, and the caller falls through to
	 * reading the snapshot's fstab itself -- which still works for a local
	 * repository this process happens to have mounted, and is what an older
	 * daemon leaves us with.
	 *
	 * The plan is asked for the NON-current-system case deliberately, even
	 * when the person is about to restore in place: current_system collapses
	 * the answer to a single "/ -> the running system" row, which is the right
	 * summary and the wrong thing to build a device page from.
	 */
	private bool init_mount_list_from_daemon(){

		if (snapshot_to_restore == null){ return false; }

		var api = DaemonApi.get_shared();
		if (api == null){ return false; }

		var plan = api.restore_plan(snapshot_to_restore.name,
			new Gee.HashMap<string,string>(), false);

		if (plan == null){
			log_debug("restore.plan: %s".printf(api.last_error));
			return false;
		}
		if (plan.mounts.size == 0){
			// An older daemon does not send them; say so rather than
			// presenting an empty page as the snapshot's layout.
			log_debug("restore.plan returned no mount selection");
			return false;
		}

		foreach (var m in plan.mounts){

			if (m.mount_point.length == 0){ continue; }

			/* Resolve to a Device so the page's drop-downs can preselect it.
			 * By uuid first: a device path can move between boots, and the
			 * uuid is what the snapshot actually recorded. */
			Device? dev = null;
			if (m.uuid.length > 0){ dev = Device.get_device_by_uuid(m.uuid); }
			if ((dev == null) && (m.device.length > 0)){
				dev = Device.get_device_by_name(m.device);
			}

			mount_list.add(new MountEntry(dev, m.mount_point, m.options));

			if (m.mount_point == "/"){ dst_root = dev; }
		}

		mount_list.sort((a,b) => {
			return strcmp(a.mount_point, b.mount_point);
		});

		return mount_list.size > 0;
	}

	public void init_mount_list(){

		log_debug("Main: init_mount_list()");

		mount_list.clear();

		/* The daemon, and nothing else.
		 *
		 * The fstab this page is derived from lives inside the SNAPSHOT, and
		 * this process does not mount the repository -- so the local parse that
		 * used to stand here could only work for a local repository that
		 * something else happened to have mounted, and produced three empty
		 * placeholder rows the rest of the time. Those placeholders were also
		 * what made the daemon refuse a restore, because they name mount points
		 * the snapshot does not have.
		 *
		 * restore.plan builds the selection from the snapshot's own fstab, on
		 * the side that can read it. */
		if (!init_mount_list_from_daemon()){
			log_error(_("The Timeshift service did not describe the snapshot's layout"));
		}

		init_boot_options();

		log_debug("Main: init_mount_list(): exit");
	}

	public void init_boot_options(){

		var grub_dev = dst_root;
		if(grub_dev != null){
			grub_device = grub_dev.device;
		}

		while ((grub_dev != null) && grub_dev.has_parent()){
			grub_dev = grub_dev.parent;
			grub_device = grub_dev.device;
		}

		if (mirror_system){
			// bootloader must be re-installed
			reinstall_grub2 = true;
			update_initramfs = true;
			update_grub = true;
		}
		else{
			if (snapshot_to_restore.dist_id == "fedora"){
				// grub2-install should never be run on EFI fedora systems
				reinstall_grub2 = false;
				update_initramfs = false;
				update_grub = true;
			}
			else{
				reinstall_grub2 = true;

				/* Restoring onto different devices means every UUID changes,
				 * and a hostonly initramfs built on the source machine waits
				 * forever for devices that are not there. Ubuntu's dracut
				 * bakes in "devexists-/dev/disk/by-uuid/<source ESP>" and
				 * drops to emergency mode when it never appears -- a restore
				 * that copied every byte correctly still would not boot.
				 *
				 * Restoring over the running system keeps its own UUIDs, so
				 * the existing initramfs stays valid. */
				update_initramfs = !restore_current_system;

				update_grub = true;
			}
		}
	}
	


	public void get_restore_messages(bool formatted,
		out string msg_devices, out string msg_reboot, out string msg_disclaimer){
			
		string msg = "";

		log_debug("Main: get_restore_messages()");

		// msg_devices -----------------------------------------
		
		if (!formatted){
			msg += "\n%s\n%s\n%s\n".printf(
				string.nfill(70,'='),
				_("Warning").up(),
				string.nfill(70,'=')
			);
		}
		
		msg += _("Data will be modified on following devices:") + "\n\n";

		int max_mount = _("Mount").length;
		int max_dev = _("Device").length;

		foreach(var entry in mount_list){
			
			if (entry.device == null){ continue; }

			if (btrfs_mode){
				
				if (entry.subvolume_name().length == 0){ continue; }
				
				if (!App.snapshot_to_restore.subvolumes.has_key(entry.subvolume_name())){ continue; }

				if ((entry.subvolume_name() == "@home") && !include_btrfs_home_for_restore){ continue; }
			}
			
			string dev_name = entry.device.full_name_with_parent;
			if (entry.subvolume_name().length > 0){
				dev_name = dev_name + "(%s)".printf(entry.subvolume_name());
			}
			else if (entry.lvm_name().length > 0){
				dev_name = dev_name + "(%s)".printf(entry.lvm_name());
			}
			
			if (dev_name.length > max_dev){
				max_dev = dev_name.length;
			}
			if (entry.mount_point.length > max_mount){
				max_mount = entry.mount_point.length;
			}
		}

		var txt = ("%%-%ds  %%-%ds".printf(max_dev, max_mount))
			.printf(_("Device"),_("Mount"));
		txt += "\n";

		txt += string.nfill(max_dev, '-') + "  " + string.nfill(max_mount, '-');
		txt += "\n";
		
		foreach(var entry in mount_list){
			
			if (entry.device == null){ continue; }

			if (btrfs_mode){

				if (entry.subvolume_name().length == 0){ continue; }
				
				if (!App.snapshot_to_restore.subvolumes.has_key(entry.subvolume_name())){ continue; }

				if ((entry.subvolume_name() == "@home") && !include_btrfs_home_for_restore){ continue; }
			}
			
			string dev_name = entry.device.full_name_with_parent;
			if (entry.subvolume_name().length > 0){
				dev_name = dev_name + "(%s)".printf(entry.subvolume_name());
			}
			else if (entry.lvm_name().length > 0){
				dev_name = dev_name + "(%s)".printf(entry.lvm_name());
			}
			
			txt += ("%%-%ds  %%-%ds".printf(max_dev, max_mount)).printf(dev_name, entry.mount_point);

			txt += "\n";
		}

		/* Say so when a selection was folded, on the page where the user can
		 * still change it. Silently mounting one device at two mount points is
		 * what wiped a restore target. */
		foreach(string note in mount_fold_notes){
			txt += "\n" + note + "\n";
		}

		/* The layout the snapshot came from, against what is about to be
		 * mounted. Without this, a missing EFI System Partition was invisible
		 * until grub-install failed at the very end with a bare exit code. */
		var layout = validate_restore_layout();

		if (layout.size > 0){

			/* Widths from this table's own contents, and the original device
			 * shortened first. A full "/dev/disk/by-uuid/<36 chars>" made the
			 * table wider than the panel, so the header wrapped onto two lines
			 * and every row broke in half. */
			int w_mnt = _("Mount").length;
			int w_org = _("Was on").length;
			int w_dev = _("Device").length;

			foreach(var row in layout){

				string org = short_device_ref(row.original);

				if (row.mount_point.length > w_mnt){ w_mnt = row.mount_point.length; }
				if (org.length > w_org){ w_org = org.length; }
				if (row.assigned.length > w_dev){ w_dev = row.assigned.length; }
			}

			txt += "\n" + _("Original layout of this snapshot") + "\n\n";

			string fmt = "%%-%ds  %%-%ds  %%-%ds  %%s".printf(w_mnt, w_org, w_dev);

			txt += fmt.printf(_("Mount"), _("Was on"), _("Device"), _("Status"));
			txt += "\n";

			txt += string.nfill(w_mnt, '-') + "  " + string.nfill(w_org, '-')
				+ "  " + string.nfill(w_dev, '-') + "  " + string.nfill(8, '-');
			txt += "\n";

			foreach(var row in layout){
				txt += fmt.printf(row.mount_point, short_device_ref(row.original),
					(row.assigned.length > 0) ? row.assigned : "-", row.status);
				txt += "\n";
			}
		}

		if (formatted){
			msg += "<span size=\"medium\"><tt>%s</tt></span>".printf(txt);
		}
		else{
			msg += "%s\n".printf(txt);
		}

		msg_devices = msg;

		//msg += _("Files will be overwritten on the target device!") + "\n";
		//msg += _("If restore fails and you are unable to boot the system, then boot from the Live CD, install Timeshift, and try to restore again.") + "\n";

		// msg_reboot -----------------------
		
		msg = "";
		if (restore_current_system){	
			msg += _("Please save your work and close all applications.") + "\n";
			msg += _("System will reboot after files are restored.");
		}

		msg_reboot = msg;

		// msg_disclaimer --------------------------------------

		msg = "";
		if (!formatted){
			msg += "\n%s\n%s\n%s\n".printf(
				string.nfill(70,'='),
				_("Disclaimer").up(),
				string.nfill(70,'=')
			);
		}
		
		msg += _("This software comes without absolutely NO warranty and the author takes no responsibility for any damage arising from the use of this program.");
		msg += " " + _("If these terms are not acceptable to you, please do not proceed beyond this point!");

		if (!formatted){
			msg += "\n";
		}
		
		msg_disclaimer = msg;

		// display messages in console mode
		
		if (app_mode.length > 0){
			log_msg(msg_devices);
			log_msg(msg_reboot);
			log_msg(msg_disclaimer);
		}

		log_debug("Main: get_restore_messages(): exit");
	}





	public string rsync_exit_meaning_public(string code){
		return rsync_exit_meaning(code);
	}

	private string rsync_exit_meaning(string code){

		switch(code){
		case "1":
			return _("rsync reported a syntax or usage error.");
		case "2":
			return _("rsync protocol mismatch with the snapshot location.");
		case "3":
			return _("rsync could not read the files it was asked to copy.");
		case "5":
			return _("rsync could not be started on the snapshot location.");
		case "11":
			return _("rsync could not write to the target. It may be full or read-only.");
		case "23":
			return _("Some files could not be transferred.");
		case "24":
			return _("Some files vanished while they were being copied.");
		case "10":
		case "12":
		case "30":
		case "35":
		case "255":
			return _("The connection to the snapshot location was lost.");
		default:
			return "";
		}
	}




	private const string SOURCE_OK_MARKER = "@@TS_SOURCE_OK";




	public bool restore_uses_terminal(){

		return LOG_DEBUG
			&& (GLib.Environment.get_variable("TIMESHIFT_RESTORE_TERMINAL") != null);
	}








	


	public void save_app_config(){

		log_debug("Main: save_app_config()");
		
		var config = new Json.Object();
		
		if ((repo != null) && repo.available() && (repo.device != null)){
			// save backup device uuid
			config.set_string_member("backup_device_uuid", repo.device.uuid);
			
			// save parent uuid if backup device has parent
			config.set_string_member("parent_device_uuid",
				(repo.device.has_parent()) ? repo.device.parent.uuid : "");
		}
		else{
			// retain values for next run
			config.set_string_member("backup_device_uuid", backup_uuid);
			config.set_string_member("parent_device_uuid", backup_parent_uuid);
		}

		config.set_string_member("backup_location_type", backup_location_type);
		config.set_string_member("backup_ssh_url", backup_ssh_url);
		config.set_string_member("backup_ssh_key", backup_ssh_key);
		config.set_string_member("backup_ssh_port", backup_ssh_port.to_string());
		config.set_string_member("backup_ssh_fake_super", backup_ssh_fake_super.to_string());

		config.set_string_member("do_first_run", false.to_string());
		config.set_string_member("btrfs_mode", btrfs_mode.to_string());
		config.set_string_member("include_btrfs_home_for_backup", include_btrfs_home_for_backup.to_string());
		config.set_string_member("include_btrfs_home_for_restore", include_btrfs_home_for_restore.to_string());
		config.set_string_member("stop_cron_emails", stop_cron_emails.to_string());

		config.set_string_member("schedule_monthly", schedule_monthly.to_string());
		config.set_string_member("schedule_weekly", schedule_weekly.to_string());
		config.set_string_member("schedule_daily", schedule_daily.to_string());
		config.set_string_member("schedule_hourly", schedule_hourly.to_string());
		config.set_string_member("schedule_boot", schedule_boot.to_string());

		config.set_string_member("count_monthly", count_monthly.to_string());
		config.set_string_member("count_weekly", count_weekly.to_string());
		config.set_string_member("count_daily", count_daily.to_string());
		config.set_string_member("count_hourly", count_hourly.to_string());
		config.set_string_member("count_boot", count_boot.to_string());

		// Persist the estimate only once there are snapshots to describe, but
		// do NOT discard the in-memory values: estimate_system_size() calls
		// this function immediately after computing them, so zeroing here
		// threw away the numbers that drive the progress bar for the whole of
		// the first backup.
		if (repo.available() && repo.has_snapshots())
		{
			config.set_string_member("snapshot_size", first_snapshot_size.to_string());
			config.set_string_member("snapshot_count", first_snapshot_count.to_string());
		}

		config.set_string_member("date_format", date_format);
		config.set_string_member("theme_mode", theme_mode);
		config.set_string_member("theme_accent", theme_accent);
		
		Json.Array arr = new Json.Array();
		foreach(string path in exclude_list_user){
			arr.add_string_element(path);
		}
		config.set_array_member("exclude",arr);

		arr = new Json.Array();
		foreach(var name in exclude_app_names){
			arr.add_string_element(name);
		}
		config.set_array_member("exclude-apps",arr);

		if(this.pause_snapshots_until > 0) {
			config.set_string_member("pause_snapshots", this.pause_snapshots_until.to_string());
		} else if(this.pause_snapshots_this_boot.length > 0) {
			config.set_string_member("pause_snapshots", this.pause_snapshots_this_boot);
		}

		if (save_app_config_to_daemon(config)){ return; }

		var json = new Json.Generator();
		json.pretty = true;
		json.indent = 2;
		var node = new Json.Node(NodeType.OBJECT);
		node.set_object(config);
		json.set_root(node);

		try{
			json.to_file(this.app_conf_path);
		} catch (Error e) {
	        log_error (e.message);
	    }

	    if ((app_mode == "")||(LOG_DEBUG)){
			log_msg(_("App config saved") + ": %s".printf(this.app_conf_path));
		}
	}

	/* Save through the daemon, which MERGES rather than truncating.
	 *
	 * Two things are wrong with writing the file directly, and both are
	 * silent.
	 *
	 * The first is that this build writes twenty-nine keys and the config
	 * format has more -- `engine` and `startup_delay_interval_mins` today, and
	 * whatever a newer daemon adds tomorrow. Generating the whole file from
	 * those twenty-nine DELETES the rest. Someone who sets
	 * startup_delay_interval_mins by hand loses it the next time anybody opens
	 * Settings and closes it. config.set is a partial update, so keys this
	 * build has never heard of survive.
	 *
	 * The second is that the daemon holds the config in memory. A file written
	 * behind its back leaves it working from a stale copy until something
	 * happens to reload it -- so the schedule the daemon acts on and the
	 * schedule the Settings window shows can disagree, with nothing anywhere
	 * saying so.
	 *
	 * Falling back to the file write when the daemon refuses is deliberate: it
	 * is exactly today's behaviour, so this is never worse than not trying,
	 * and refusing to save at all would lose the change outright. The reason
	 * is logged, because a refusal means the two key tables have diverged and
	 * that is worth finding.
	 */
	private bool save_app_config_to_daemon(Json.Object config){

		var api = DaemonApi.get_shared();
		if (api == null){ return false; }

		/* A merge cannot clear a key by leaving it out, and clearing by leaving
		 * it out is exactly how pausing is switched off: unpause sets both
		 * fields to nothing and relies on the whole-file write to drop the key.
		 * Sent as an empty string instead -- the daemon's writer omits an empty
		 * pause_snapshots from the file, so the result on disk is identical. */
		if (!config.has_member("pause_snapshots")){
			config.set_string_member("pause_snapshots", "");
		}

		if (!api.config_set(config)){
			log_error("%s: %s".printf(
				_("The Timeshift service would not save the settings"),
				api.last_error));
			return false;
		}

		if ((app_mode == "") || LOG_DEBUG){
			log_msg(_("App config saved") + ": %s".printf(_("through the Timeshift service")));
		}
		return true;
	}

	public void load_app_config(){

		log_debug("Main: load_app_config()");

		// check if first run -----------------------
		
		var f = File.new_for_path(this.app_conf_path);
		
		if (!f.query_exists()) {
			
			if (file_exists(app_conf_path_old)){
				// move old file
				file_move(app_conf_path_old, app_conf_path);
			}
			else if (file_exists(app_conf_path_default)){
				// /etc/timeshift might not pre-exist when sysconfdir is not /etc
				if (!dir_exists(file_parent(app_conf_path))){
					dir_create(file_parent(app_conf_path));
				}
				// copy default file
				file_copy(app_conf_path_default, app_conf_path);
			}
		}
		
		// load settings from config file --------------------------
		
		var parser = new Json.Parser();
        try{
			parser.load_from_file(this.app_conf_path);
		} catch (Error e) {
	        log_error (e.message);
	    }
		Json.Node? node = parser.get_root();

		// make sure object is always set
		Json.Object config = node?.get_object() ?? new Json.Object();

		bool do_first_run = json_get_bool(config, "do_first_run", false); // false as default

		btrfs_mode = json_get_bool(config, "btrfs_mode", false); // false as default
		
		if (do_first_run){
			set_first_run_flag();
		}

		if (config.has_member("include_btrfs_home")){
			include_btrfs_home_for_backup = json_get_bool(config, "include_btrfs_home", include_btrfs_home_for_backup);
		}
		else{
			include_btrfs_home_for_backup = json_get_bool(config, "include_btrfs_home_for_backup", include_btrfs_home_for_backup);
		}
		
		include_btrfs_home_for_restore = json_get_bool(config, "include_btrfs_home_for_restore", include_btrfs_home_for_restore);
		stop_cron_emails = json_get_bool(config, "stop_cron_emails", stop_cron_emails);

		if (cmd_btrfs_mode != null){
			btrfs_mode = cmd_btrfs_mode; //override
		}
		
		backup_uuid = json_get_string(config,"backup_device_uuid", backup_uuid);
		backup_parent_uuid = json_get_string(config,"parent_device_uuid", backup_parent_uuid);

		backup_location_type = json_get_string(config,"backup_location_type", backup_location_type);
		backup_ssh_url = json_get_string(config,"backup_ssh_url", backup_ssh_url);
		backup_ssh_key = json_get_string(config,"backup_ssh_key", backup_ssh_key);
		backup_ssh_port = json_get_int(config,"backup_ssh_port", backup_ssh_port);
		backup_ssh_fake_super = json_get_bool(config,"backup_ssh_fake_super", backup_ssh_fake_super);

		// btrfs snapshots require a local filesystem
		if (backup_location_type == "ssh"){ btrfs_mode = false; }

        this.schedule_monthly = json_get_bool(config,"schedule_monthly",schedule_monthly);
		this.schedule_weekly = json_get_bool(config,"schedule_weekly",schedule_weekly);
		this.schedule_daily = json_get_bool(config,"schedule_daily",schedule_daily);
		this.schedule_hourly = json_get_bool(config,"schedule_hourly",schedule_hourly);
		this.schedule_boot = json_get_bool(config,"schedule_boot",schedule_boot);

		this.count_monthly = json_get_int(config,"count_monthly",count_monthly);
		this.count_weekly = json_get_int(config,"count_weekly",count_weekly);
		this.count_daily = json_get_int(config,"count_daily",count_daily);
		this.count_hourly = json_get_int(config,"count_hourly",count_hourly);
		this.count_boot = json_get_int(config,"count_boot",count_boot);

		this.date_format = json_get_string(config, "date_format", date_format_default);
		this.theme_mode = json_get_string(config, "theme_mode", theme_mode_default);
		this.theme_accent = json_get_string(config, "theme_accent", theme_accent_default);

		Main.first_snapshot_size = json_get_uint64(config,"snapshot_size", Main.first_snapshot_size);
			
		Main.first_snapshot_count = (int64) json_get_uint64(config,"snapshot_count", Main.first_snapshot_count);
		
		exclude_list_user.clear();
		
		if (config.has_member ("exclude")){
			
			foreach (Json.Node jnode in config.get_array_member ("exclude").get_elements()) {
				
				string path = jnode.get_string();
				
				if (!exclude_list_user.contains(path)
					&& !exclude_list_default.contains(path)
					&& !exclude_list_home.contains(path)){
						
					exclude_list_user.add(path);
				}
			}
		}

		exclude_app_names.clear();

		if (config.has_member ("exclude-apps")){
			
			var apps = config.get_array_member("exclude-apps");
			
			foreach (Json.Node jnode in apps.get_elements()) {
				
				string name = jnode.get_string();
				
				if (!exclude_app_names.contains(name)){
					exclude_app_names.add(name);
				}
			}
		}

		string pause_snapshots = config.get_string_member_with_default("pause_snapshots", "");
		long pause_snapshots_long = 0;
		if(long.try_parse(pause_snapshots, out pause_snapshots_long)) {
			this.pause_snapshots_until = pause_snapshots_long;
			this.pause_snapshots_this_boot = "";
		} else {
			this.pause_snapshots_until = 0;

			// read current boot_id
			if(TeeJee.System.get_current_boot_id() == pause_snapshots) {
				this.pause_snapshots_this_boot = pause_snapshots;
			} else {
				this.pause_snapshots_this_boot = "";
			}
		}

		if ((app_mode == "")||(LOG_DEBUG)){
			log_msg(_("App config loaded") + ": %s".printf(this.app_conf_path));
		}
	}

	/**
		Are snapshots currently paused?
	 */
	public bool snapshots_paused {
		get {
			// paused until given time
			bool isTimePaused = this.pause_snapshots_until > (GLib.get_real_time() / 1000000);
			if(!isTimePaused) {
				this.pause_snapshots_until = 0;
			}

			// paused until reboot
			bool bootPaused = this.pause_snapshots_this_boot.length > 0;

			return isTimePaused || bootPaused;
		}
	}

	public void pause_snapshots_for(int time_in_s) {
		this.pause_snapshots_until = (long) (GLib.get_real_time() / 1000000) + time_in_s;
		this.pause_snapshots_this_boot = "";
		this.save_app_config();
	}

	public void pause_snapshots_for_this_boot() {
		this.pause_snapshots_until = 0;
		this.pause_snapshots_this_boot = TeeJee.System.get_current_boot_id();
		this.save_app_config();
	}

	public void unpause_snapshots() {
		this.pause_snapshots_until = 0;
		this.pause_snapshots_this_boot = "";
		this.save_app_config();
	}

	public void set_first_run_flag(){
		
		first_run = true;
		
		log_msg("First run mode (config file not found)");

		// load some defaults for first-run based on user's system type
		
		bool supported = sys_subvolumes.has_key("@") && cmd_exists("btrfs"); // && sys_subvolumes.has_key("@home")
		if (supported || (cmd_btrfs_mode == true)){
			log_msg(_("Selected default snapshot type") + ": %s".printf("BTRFS"));
			btrfs_mode = true;
		}
		else{
			log_msg(_("Selected default snapshot type") + ": %s".printf("RSYNC"));
			btrfs_mode = false;
		}
	}
	
	public void initialize_repo(){

		log_debug("Main: initialize_repo()");
		
		log_debug("backup_uuid=%s".printf(backup_uuid));
		log_debug("backup_parent_uuid=%s".printf(backup_parent_uuid));

		// Command line options are parsed after the config is loaded, so the
		// remote-location overrides are applied here rather than in
		// load_app_config().
		if (cmd_ssh_url.length > 0){
			backup_location_type = "ssh";
			backup_ssh_url = cmd_ssh_url;
		}
		if (cmd_ssh_key.length > 0){ backup_ssh_key = cmd_ssh_key; }
		if (cmd_ssh_port > 0){ backup_ssh_port = cmd_ssh_port; }

		// btrfs snapshots require a local filesystem
		if (backup_location_type == "ssh"){ btrfs_mode = false; }

		// a remote location takes priority over any local device
		if (backup_location_type == "ssh"){

			if (backup_ssh_url.length == 0){
				log_error(_("Remote snapshot location is not configured"));
				exit_app(1);
				return;
			}

			if (!cmd_exists("ssh")){
				log_error(_("Commands listed below are not available on this system") + ":\n\n * ssh\n");
				log_error(_("Please install required packages and try running TimeShift again"));
				exit_app(1);
				return;
			}

			// fall back to the key Timeshift manages itself
			if (backup_ssh_key.length == 0){
				backup_ssh_key = SshRepoBackend.default_key_file();
			}

			log_debug("Using remote snapshot location: %s".printf(backup_ssh_url));

			repo = new SnapshotRepo.from_ssh(backup_ssh_url, backup_ssh_key,
				backup_ssh_port, backup_ssh_fake_super, parent_window);
		}
		// use system disk as snapshot device in btrfs mode for backup
		else if (((app_mode == "backup")||((app_mode == "ondemand"))) && btrfs_mode){
			if (sys_root != null){
				log_msg("Using system disk as snapshot device for creating snapshots in BTRFS mode");
				if (cmd_backup_device.length > 0){
					log_msg(_("Option --snapshot-device should not be specified for creating snapshots in BTRFS mode"));
				}
				repo = new SnapshotRepo.from_device(sys_root, parent_window, btrfs_mode);
			}
			else{
				log_error("System disk not found!");
				exit_app(1);
			}
		}
		// initialize repo using command line parameter if specified
		else if (cmd_backup_device.length > 0){
			var cmd_dev = Device.get_device_by_name(cmd_backup_device);
			if (cmd_dev != null){
				log_debug("Using snapshot device specified as command argument: %s".printf(cmd_backup_device));
				repo = new SnapshotRepo.from_device(cmd_dev, parent_window, btrfs_mode);
				// TODO: move this code to main window
			}
			else{
				log_error(_("Device not found") + ": '%s'".printf(cmd_backup_device));
				exit_app(1);
			}
		}
		// select default device for first run mode
		else if (first_run && (backup_uuid.length == 0)){
			
			try_select_default_device_for_backup(parent_window);

			if ((repo != null) && (repo.device != null)){
				log_msg(_("Selected default snapshot device") + ": %s".printf(repo.device.device));
			}
		}
		else {
			log_debug("Setting snapshot device from config file");
			
			// find devices from uuid
			Device dev = null;
			Device dev_parent = null;
			if (backup_uuid != null && backup_uuid.length > 0){
				dev = Device.get_device_by_uuid(backup_uuid);
			}
			if (backup_parent_uuid != null && backup_parent_uuid.length > 0){
				dev_parent = Device.get_device_by_uuid(backup_parent_uuid);
			}

			// try unlocking encrypted parent
			if ((dev_parent != null) && dev_parent.is_encrypted_partition() && !dev_parent.has_children()){
				log_debug("Snapshot device is on an encrypted partition");
				repo = new SnapshotRepo.from_uuid(backup_parent_uuid, parent_window, btrfs_mode);
			}
			// try device	
			else if (dev != null){
				log_debug("repo: creating from uuid");
				repo = new SnapshotRepo.from_uuid(backup_uuid, parent_window, btrfs_mode);
			}
			// try system disk
			/*else {
				log_debug("Could not find device with UUID" + ": %s".printf(backup_uuid));
				if (sys_root != null){
					log_debug("Using system disk as snapshot device");
					repo = new SnapshotRepo.from_device(sys_root, parent_window, btrfs_mode);
				}
				else{
					log_debug("System disk not found");
					repo = new SnapshotRepo.from_null();
				}
			}*/
		}

		/* Note: In command-line mode, user will be prompted for backup device */

		/* The backup device specified in config file will be mounted at this point if:
		 * 1) app is running in GUI mode, OR
		 * 2) app is running command mode without backup device argument
		 * */

		 log_debug("Main: initialize_repo(): exit");
	}
	
	//core functions

	public void update_partitions(){

		log_debug("update_partitions()");
		
		partitions.clear();
		
		partitions = Device.get_filesystems();

		foreach(var pi in partitions){

			// sys_root and sys_home will be detected by detect_system_devices()
			if ((repo != null) && (repo.device != null) && (pi.uuid == repo.device.uuid)){
				repo.device = pi;
			}
		}
		
		if (partitions.size == 0){
			log_error("ts: " + _("Failed to get partition list."));
		}

		log_debug("partition list updated");
	}

	public void detect_system_devices(){

		log_debug("detect_system_devices()");

		sys_root = null;
		sys_boot = null;
		sys_efi = null;
		sys_home = null;

		foreach(var pi in partitions){
			
			foreach(var mp in pi.mount_points){
				
				// skip loop devices - Fedora Live uses loop devices containing ext4-formatted lvm volumes
				if ((pi.type == "loop") || (pi.has_parent() && (pi.parent.type == "loop"))){
					continue;
				}

				if (mp.mount_point == "/"){
					sys_root = pi;
					if ((app_mode == "")||(LOG_DEBUG)){
						string txt = _("/ is mapped to device") + ": %s, UUID=%s".printf(pi.device,pi.uuid);
						if (mp.subvolume_name().length > 0){
							txt += ", subvol=%s".printf(mp.subvolume_name());
						}
						log_debug(txt);
					}
				}

				if (mp.mount_point == "/home"){
					sys_home = pi;
					if ((app_mode == "")||(LOG_DEBUG)){
						string txt = _("/home is mapped to device") + ": %s, UUID=%s".printf(pi.device,pi.uuid);
						if (mp.subvolume_name().length > 0){
							txt += ", subvol=%s".printf(mp.subvolume_name());
						}
						log_debug(txt);
					}
				}

				if (mp.mount_point == "/boot"){
					sys_boot = pi;
					if ((app_mode == "")||(LOG_DEBUG)){
						string txt = _("/boot is mapped to device") + ": %s, UUID=%s".printf(pi.device,pi.uuid);
						if (mp.subvolume_name().length > 0){
							txt += ", subvol=%s".printf(mp.subvolume_name());
						}
						log_debug(txt);
					}
				}

				if (mp.mount_point == "/boot/efi"){
					sys_efi = pi;
					if ((app_mode == "")||(LOG_DEBUG)){
						string txt = _("/boot/efi is mapped to device") + ": %s, UUID=%s".printf(pi.device,pi.uuid);
						if (mp.subvolume_name().length > 0){
							txt += ", subvol=%s".printf(mp.subvolume_name());
						}
						log_debug(txt);
					}
				}

			}
		}

		sys_subvolumes = Subvolume.detect_subvolumes_for_system_by_path("/", null, parent_window);
	}

	/* The mount options mount_target_devices() will actually use for an entry.
	 *
	 * Shared with fold_aliased_mount_entries(), which has to compare the
	 * *effective* subvolume: on btrfs, / and /home legitimately live on one
	 * device as subvol=@ and subvol=@home, and folding those would be wrong. */
	private string restore_mount_options(MountEntry mnt){

		if ((mnt.device != null) && (mnt.device.fstype == "btrfs")){

			if (mnt.mount_point == "/"){
				return "subvol=@";
			}

			if (include_btrfs_home_for_restore && (mnt.mount_point == "/home")){
				return "subvol=@home";
			}
		}

		return "";
	}

	/* Did the system this snapshot came from boot via UEFI?
	 *
	 * The snapshot carries the original /etc/fstab (Snapshot.read_fstab_file),
	 * and a /boot/efi entry in it is that system saying so. This matters
	 * because an EFI System Partition is not optional: without one mounted,
	 * grub-install resolves --efi-directory to a plain directory, refuses to
	 * write anything, and the restored disk will not boot -- which is exactly
	 * how a complete, error-free 14 GB restore still produced an unbootable
	 * machine. */
	public bool snapshot_needs_esp(){

		if (mirror_system){
			return using_efi_boot(); // cloning: the running system decides
		}

		if (snapshot_to_restore == null){ return false; }

		foreach(var entry in snapshot_to_restore.fstab_list){
			if (entry.mount_point == "/boot/efi"){ return true; }
		}

		return false;
	}

	/* The device currently assigned to /boot/efi, if any. */
	public Device? assigned_esp(){

		foreach(var mnt in mount_list){
			if (mnt.mount_point == "/boot/efi"){ return mnt.device; }
		}

		return null;
	}

	public class LayoutRow : GLib.Object {
		public string mount_point;
		public string original;   // what the snapshot's fstab named
		public string assigned;   // what the restore will mount, or ""
		public string status;     // "ok" | "on root" | "missing"
		public bool blocking;

		public LayoutRow(string mount_point, string original, string assigned,
			string status, bool blocking){

			this.mount_point = mount_point;
			this.original = original;
			this.assigned = assigned;
			this.status = status;
			this.blocking = blocking;
		}
	}

	/* Compare the layout the snapshot was taken from against what the restore
	 * is actually going to mount.
	 *
	 * Only / and /boot/efi block: everything else genuinely does work living on
	 * the root filesystem, and saying otherwise would train people to click
	 * past the warning that matters. */
	public Gee.ArrayList<LayoutRow> validate_restore_layout(){

		var rows = new Gee.ArrayList<LayoutRow>();

		if (snapshot_to_restore == null){ return rows; }

		foreach(var entry in snapshot_to_restore.fstab_list){

			if (!entry.is_for_system_directory()){ continue; }
			if (entry.mount_point == "swap"){ continue; }

			var mnt = MountEntry.find_entry_by_mount_point(mount_list, entry.mount_point);

			string assigned = ((mnt != null) && (mnt.device != null))
				? mnt.device.device : "";

			string status;
			bool blocking = false;

			if (assigned.length > 0){
				status = _("ok");
			}
			else if (entry.mount_point == "/"){
				status = _("NOT SELECTED");
				blocking = true;
			}
			else if (entry.mount_point == "/boot/efi"){
				status = _("MISSING");
				blocking = true;
			}
			else {
				status = _("on root");
			}

			rows.add(new LayoutRow(entry.mount_point, entry.device_string,
				assigned, status, blocking));
		}

		return rows;
	}

	/* A device reference short enough for a table.
	 *
	 * fstab records these as "/dev/disk/by-uuid/<36-char uuid>" or "UUID=...",
	 * which is 50 characters of mostly-noise; the leading digits are enough to
	 * recognise which partition is meant. A plain /dev/sda1 is already short
	 * and is left alone. */
	private string short_device_ref(string reference){

		string txt = reference.strip();

		if (txt.has_prefix("/dev/disk/by-uuid/")){
			txt = txt.substring("/dev/disk/by-uuid/".length);
		}
		else if (txt.down().has_prefix("uuid=")){
			txt = txt.substring(5);
		}
		else if (txt.has_prefix("/dev/disk/by-label/")){
			txt = txt.substring("/dev/disk/by-label/".length);
		}
		else {
			return txt; // /dev/sda1 and friends are fine as they are
		}

		/* ASCII "..", not a single-character ellipsis: printf's %-14s pads by
		 * BYTES, and a 3-byte U+2026 counts as three, so the column after it
		 * lost two spaces and the table stopped lining up. */
		if (txt.length > 12){
			txt = txt.substring(0, 10) + "..";
		}

		return txt;
	}

	/* Make the /boot/efi selection sane, whichever front end filled it in.
	 *
	 * The GUI filters its dropdown to real ESPs, but the console's map_devices()
	 * defaults every unresolved mount point to the root device -- which for
	 * /boot/efi means mounting the ext4 root a second time underneath itself.
	 * The fold used to absorb that; it deliberately no longer does, so the
	 * correction belongs here where both paths pass through.
	 *
	 * Clears a selection that is not an EFI System Partition, then falls back
	 * to the ESP on the same disk as the root device. */
	public void normalize_esp_selection(){

		if (!snapshot_needs_esp()){ return; }

		MountEntry? esp_entry = null;

		foreach(var mnt in mount_list){
			if (mnt.mount_point == "/boot/efi"){ esp_entry = mnt; break; }
		}

		if (esp_entry == null){ return; }

		if (esp_entry.device != null){

			string reject = "";

			if (!esp_entry.device.is_efi_system_partition()){
				reject = _("%s is not an EFI System Partition and cannot hold /boot/efi.").printf(
					esp_entry.device.device);
			}
			/* And it must be on the disk being restored to.
			 *
			 * Both front ends default an unresolved /boot/efi to whatever
			 * matched the snapshot's fstab, which on the machine running the
			 * restore is THIS computer's own ESP. Writing the restored
			 * system's boot loader onto the live machine's EFI partition would
			 * damage the very system someone is using to perform the rescue. */
			else if ((dst_root != null) && dst_root.has_parent()
				&& esp_entry.device.has_parent()
				&& (esp_entry.device.parent.device != dst_root.parent.device)){

				reject = _("%s is on a different disk from the root device and will not be used for /boot/efi.").printf(
					esp_entry.device.device);
			}

			if (reject.length > 0){

				log_msg(reject);

				if (!mount_fold_notes.contains(reject)){
					mount_fold_notes.add(reject);
				}

				esp_entry.device = null;
			}
		}

		if (esp_entry.device != null){ return; }

		if ((dst_root == null) || !dst_root.has_parent()){ return; }

		foreach(var dev in partitions){

			if (!dev.has_parent()){ continue; }
			if (dev.parent.device != dst_root.parent.device){ continue; }
			if (!dev.is_efi_system_partition()){ continue; }

			esp_entry.device = dev;

			string msg = _("Using %s as the EFI System Partition for /boot/efi.").printf(dev.device);
			log_msg(msg);

			if (!mount_fold_notes.contains(msg)){
				mount_fold_notes.add(msg);
			}

			break;
		}
	}

	/* Drop any mount entry that names the same device+subvolume as one of its
	 * own ancestors.
	 *
	 * This is what destroyed a restore target: / and /home were both assigned
	 * the root device, so <target>/home *was* <target>, and /boot and /boot/efi
	 * were both the ESP. rsync's --delete then walked into the alias, found the
	 * source's (excluded, therefore empty) home/ and deleted every top-level
	 * directory of the target through it. The only survivors were the busy
	 * mountpoints themselves.
	 *
	 * Assigning the root device to /home is how a user says "keep it on the
	 * root device", so the entry is folded rather than refused -- the dropdown's
	 * own null option means exactly the same thing. verify_no_aliased_mounts()
	 * is the backstop for anything this does not anticipate. */
	public void fold_aliased_mount_entries(){

		mount_fold_notes.clear();

		// parents before children, so an ancestor is always seen first
		mount_list.sort((a,b) => {
			return strcmp(a.mount_point, b.mount_point);
		});

		foreach(var mnt in mount_list){

			if ((mnt.device == null) || (mnt.mount_point == "/")){ continue; }

			/* Never the ESP. Folding /boot/efi onto the root device is not a
			 * shorthand for anything -- it means no EFI System Partition gets
			 * mounted, the snapshot's ESP payload lands as ordinary files on
			 * ext4, and grub-install then fails with "cannot find EFI
			 * directory". validate_restore_layout() reports it as an error
			 * instead. */
			if (mnt.mount_point == "/boot/efi"){ continue; }

			foreach(var parent in mount_list){

				if (parent == mnt){ break; } // sorted: nothing after this is an ancestor

				if (parent.device == null){ continue; }

				// an ancestor of this mount point, not merely a name prefix
				if (!mount_point_is_under(mnt.mount_point, parent.mount_point)){ continue; }

				if (parent.device.uuid != mnt.device.uuid){ continue; }

				if (restore_mount_options(parent) != restore_mount_options(mnt)){ continue; }

				string msg = _("%s and %s were both set to %s. %s will stay on %s.").printf(
					parent.mount_point, mnt.mount_point, mnt.device.device,
					mnt.mount_point, parent.mount_point);

				log_msg(msg);

				if (!mount_fold_notes.contains(msg)){
					mount_fold_notes.add(msg);
				}

				/* null is exactly what the device dropdown's "Keep on Root
				 * Device" option stores, so the entry keeps its row in the UI
				 * and simply stops being mounted a second time. Removing it
				 * outright would make the dropdown disappear if the user
				 * stepped back to change it. */
				mnt.device = null;
				break;
			}
		}
	}

	/* True when child is at or below parent in the directory tree.
	 * A plain has_prefix() would call /boot-backup a child of /boot. */
	private bool mount_point_is_under(string child, string parent){

		if (parent == "/"){ return child != "/"; }

		if (child == parent){ return true; }

		return child.has_prefix(parent + "/");
	}

	/* The backstop for the aliasing bug, independent of how the mount list was
	 * built: after mounting and before anything is deleted, no nested mount
	 * point may BE one of its own ancestors.
	 *
	 * Compares (st_dev, st_ino) rather than the mount list, so it catches an
	 * alias arriving by any route -- a stale mount, a bind, a device that
	 * resolved to the same thing under two names. A subdirectory of the target
	 * shares st_dev with it but never st_ino, so an ordinary layout passes. */
	public bool verify_no_aliased_mounts(){

		if (restore_current_system){
			// nothing was mounted by us; / is the target by definition
			return true;
		}

		string root = remove_trailing_slash(restore_target_path);

		Posix.Stat st_root;
		if (Posix.stat(root, out st_root) != 0){
			restore_fail(_("The restore target could not be read: %s").printf(root));
			return false;
		}

		foreach(var mnt in mount_list){

			if (mnt.mount_point == "/"){ continue; }

			string path = root + mnt.mount_point;

			Posix.Stat st;
			if (Posix.stat(path, out st) != 0){ continue; }

			if ((st.st_dev == st_root.st_dev) && (st.st_ino == st_root.st_ino)){

				restore_fail(_("%s is the same directory as the root of the restore target.").printf(
					mnt.mount_point));
				restore_note(_("Restoring would delete the target's contents through it. Nothing was changed."));
				restore_note(_("Select 'Keep on Root Device' for %s, or choose a different device.").printf(
					mnt.mount_point));

				log_error(_("Aliased mount detected: %s resolves to the restore target itself").printf(path));
				return false;
			}
		}

		return true;
	}

	public bool mount_target_devices(Gtk.Window? parent_win = null){
		/* Note:
		 * Target device will be mounted explicitly to /run/timeshift/<pid>/restore
		 * Existing mount points are not used since we need to mount other devices in sub-directories
		 * */

		log_debug("mount_target_device()");
		
		if (dst_root == null){
			return false;
		}
	
		/* Two mount points sharing one device would alias one directory onto
		 * another, and rsync --delete would then wipe the target through the
		 * alias. Fold them before a single mount happens. */
		fold_aliased_mount_entries();
		normalize_esp_selection();

		//check and create restore mount point for restore
		mount_point_restore = mount_point_app + "/restore";
		dir_create(mount_point_restore);

		/*var already_mounted = false;
		var dev_mounted = Device.get_device_by_path(mount_point_restore);
		if ((dev_mounted != null)
			&& (dev_mounted.uuid == dst_root.uuid)){

			foreach(var mp in dev_mounted.mount_points){
				if ((mp.mount_point == mount_point_restore)
					&& (mp.mount_options == "subvol=@")){
						
					 = true;
					return; //already_mounted
				}
			}
		}*/
		
		// unmount
		unmount_target_device();

		// mount root device
		if (dst_root.fstype == "btrfs"){

			//check subvolume layout

			bool supported = check_btrfs_layout(dst_root, dst_home, false);
			
			if (!supported && snapshot_to_restore.has_subvolumes()){
				string msg = _("The target partition has an unsupported subvolume layout.") + "\n";
				msg += _("Only ubuntu-type layouts with @ and @home subvolumes are currently supported.");

				if (app_mode == ""){
					string title = _("Unsupported Subvolume Layout");
					gtk_messagebox(title, msg, null, true);
				}
				else{
					log_error("\n" + msg);
				}

				return false;
			}
		}

		// mount all devices
		foreach (var mnt in mount_list) {

			if (mnt.device == null){
				continue;
			}
			
			// unlock encrypted device
			if (mnt.device.is_encrypted_partition()){

				// check if unlocked
				if (mnt.device.has_children()){
					mnt.device = mnt.device.children[0];
				}
				else{
					// prompt user
					string msg_out, msg_err;
			
					var dev_unlocked = Device.luks_unlock(
						mnt.device, "", "", parent_win, out msg_out, out msg_err);

					//exit if not found
					if (dev_unlocked == null){
						return false;
					}
					else{
						mnt.device = dev_unlocked;
					}
				}
			}

			string mount_options = restore_mount_options(mnt);

			if (!Device.mount(mnt.device.uuid, mount_point_restore + mnt.mount_point, mount_options)){
				return false;
			}
		}

		return true;
	}

	/* Returns whether the target really is unmounted now.
	 *
	 * The result used to be discarded, and check_and_repair_filesystems() then
	 * ran "fsck -y" regardless -- on filesystems that could still be mounted. */
	public bool unmount_target_device(bool exit_on_error = true){
		
		if (mount_point_restore == null) { return true; }

		log_debug("unmount_target_device()");
		
		//unmount the target device only if it was mounted by application
		if (mount_point_restore.has_prefix(mount_point_app)){   //always true
			return unmount_device(mount_point_restore, exit_on_error);
		}
		else{
			//don't unmount
			return true;
		}
	}

	public bool unmount_device(string mount_point, bool exit_on_error = true){
		bool is_unmounted = Device.unmount(mount_point);
		if (!is_unmounted){
			if (exit_on_error){
				if (app_mode == ""){
					string title = _("Critical Error");
					string msg = _("Failed to unmount device!") + "\n" + _("Application will exit");
					gtk_messagebox(title, msg, null, true);
				}
				exit_app(1);
			}
		}
		return is_unmounted;
	}

	public SnapshotLocationStatus check_backup_location(out string message, out string details){
		repo.check_status();
		message = repo.status_message;
		details = repo.status_details;
		return repo.status_code;
	}

	public bool check_btrfs_volume(Device dev, string subvol_names, bool unlock){

		log_debug("check_btrfs_volume():%s".printf(subvol_names));
		
		string mnt_btrfs = mount_point_app + "/btrfs";
		dir_create(mnt_btrfs);

		if (!dev.is_mounted_at_path("", mnt_btrfs)){
			
			Device.unmount(mnt_btrfs);

			// unlock encrypted device
			if (dev.is_encrypted_partition()){

				if (unlock){
					
					string msg_out, msg_err;
					var dev_unlocked = Device.luks_unlock(
						dev, "", "", parent_window, out msg_out, out msg_err);
				
					if (dev_unlocked == null){
						log_debug("device is null");
						log_debug("SnapshotRepo: check_btrfs_volume(): exit");
						return false;
					}
					else{
						Device.mount(dev_unlocked.uuid, mnt_btrfs, "subvolid=0", true);
					}
				}
				else{
					return false;
				}
			}
			else{
				Device.mount(dev.uuid, mnt_btrfs, "subvolid=0", true);
			}
		}

		bool supported = true;

		foreach(string subvol_name in subvol_names.split(",")){
			supported = supported && dir_exists(path_combine(mnt_btrfs,subvol_name));
		}

		if (Device.unmount(mnt_btrfs)){
			if (dir_exists(mnt_btrfs) && dir_is_empty(mnt_btrfs)){
				dir_delete(mnt_btrfs);
				log_debug(_("Removed mount directory: '%s'").printf(mnt_btrfs));
			}
		}

		return supported;
	}

	public void try_select_default_device_for_backup(Gtk.Window? parent_win){

		log_debug("try_select_default_device_for_backup()");

		// A remote repository has no Device at all. Falling through would pass
		// null to check_device_for_backup(), which returns false on its null
		// precondition and would silently replace a working remote repo with
		// from_null().
		if ((repo != null) && repo.backend.is_remote){
			log_debug("repo is remote - keeping it");
			return;
		}

		// check if currently selected device can be used
		if (repo.available()){
			if (check_device_for_backup(repo.device, false)){
				if (repo.btrfs_mode != btrfs_mode){
					// reinitialize
					repo = new SnapshotRepo.from_device(repo.device, parent_win, btrfs_mode);
				}
				return;
			}
			else{
				repo = new SnapshotRepo.from_null();
			}
		}
		
		update_partitions();

		// In BTRFS mode, select the system disk if system disk is BTRFS
		if (btrfs_mode && sys_subvolumes.has_key("@")){
			var subvol_root = sys_subvolumes["@"];
			repo = new SnapshotRepo.from_device(subvol_root.get_device(), parent_win, btrfs_mode);
			return;
		}
			
		foreach(var dev in partitions){
			if (check_device_for_backup(dev, false)){
				repo = new SnapshotRepo.from_device(dev, parent_win, btrfs_mode);
				break;
			}
			else{
				continue;
			}
		}
	}

	public bool check_device_for_backup(Device dev, bool unlock){
		bool ok = false;

		if (dev.type == "disk") { return false; }
		if (dev.has_children()) { return false; }
		
		if (btrfs_mode && ((dev.fstype == "btrfs")||(dev.fstype == "luks"))){
			if (check_btrfs_volume(dev, "@", unlock)){
				return true;
			}
		}
		else if (!btrfs_mode && dev.has_linux_filesystem()){
			// TODO: check free space
			return true;
		}

		return ok;
	}

	public delegate void progressCallback();
	// btrfs

	public void query_subvolume_info(SnapshotRepo parent_repo){

		// SnapshotRepo constructor calls this code in load_snapshots()
		// save the new object reference to repo since repo still holds previous object
		repo = parent_repo;

		// TODO: move query_subvolume_info() and related methods to SnapshotRepo
		
		if ((repo == null) || !repo.btrfs_mode){
			return;
		}
		
		log_debug(_("Querying subvolume info..."));
		
		try {
			thread_subvol_info_running = true;
			thread_subvol_info_success = false;
			new Thread<void>.try ("query-subvolume-info", () => {query_subvolume_info_thread();});
		} catch (Error e) {
			thread_subvol_info_running = false;
			thread_subvol_info_success = false;
			log_error (e.message);
		}

		while (thread_subvol_info_running){
			gtk_do_events ();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 100);
		}

		log_debug(_("Query completed"));
	}

	public void query_subvolume_info_thread(){
		
		thread_subvol_info_running = true;

		//query IDs
		bool ok = query_subvolume_ids();
		
		if (!ok){
			thread_subvol_info_success = false;
			thread_subvol_info_running = false;
			return;
		}

        if (_btrfs_qgroups_enabled_internal != QGroupStatus.DISABLED) {
            bool success = query_subvolume_quotas();

            if (_btrfs_qgroups_enabled_internal == QGroupStatus.UNKNOWN) {
                _btrfs_qgroups_enabled_internal = success ? QGroupStatus.ENABLED : QGroupStatus.DISABLED;
            }
        }

		thread_subvol_info_success = true;
		thread_subvol_info_running = false;
		return;
	}

	// rsync size

	/* Computes and caches size for any rsync snapshot in parent_repo that
	 * does not already have one, mirroring query_subvolume_info()'s
	 * thread-plus-wait pattern. A no-op once every snapshot has been sized
	 * once, since the result is cached in info.json. */
	public void compute_rsync_snapshot_sizes(SnapshotRepo parent_repo){

		var pending = new Gee.ArrayList<Snapshot>();
		foreach(var bak in parent_repo.snapshots){
			if (!bak.btrfs_mode && (bak.size_bytes < 0)){
				pending.add(bak);
			}
		}

		if (pending.size == 0){ return; }

		log_debug(_("Computing snapshot sizes..."));

		try {
			thread_snapshot_size_running = true;
			new Thread<void>.try ("compute-snapshot-sizes", () => {
				foreach(var bak in pending){
					bak.compute_rsync_size();
				}
				thread_snapshot_size_running = false;
			});
		} catch (Error e) {
			thread_snapshot_size_running = false;
			log_error (e.message);
			return;
		}

		while (thread_snapshot_size_running){
			gtk_do_events ();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 100);
		}

		log_debug(_("Query completed"));
	}

	public bool query_subvolume_ids(){
		bool ok = query_subvolume_id("@");
		if ((repo.device_home != null) && (repo.device.uuid != repo.device_home.uuid)){
			ok = ok && query_subvolume_id("@home");
		}
		return ok;
	}
	
	public bool query_subvolume_id(string subvol_name){

		log_debug("query_subvolume_id():%s".printf(subvol_name));
		
		string cmd = "";
		string std_out;
		string std_err;
		int ret_val;

		cmd = "btrfs subvolume list '%s'".printf(repo.mount_paths[subvol_name]);
		log_debug(cmd);
		ret_val = exec_sync(cmd, out std_out, out std_err);
		if (ret_val != 0){
			log_error (std_err);
			log_error(_("btrfs returned an error") + ": %d".printf(ret_val));
			log_error(_("Failed to query subvolume list"));
			return false;
		}

		/* Sample Output:
		 *
		ID 257 gen 56 top level 5 path timeshift-btrfs/snapshots/2014-09-26_23-34-08/@
		ID 258 gen 52 top level 5 path timeshift-btrfs/snapshots/2014-09-26_23-34-08/@home
		* */

		foreach(string line in std_out.split("\n")){
			if (line == null) { continue; }

			string[] parts = line.split(" ");
			if (parts.length < 2) { continue; }

			Subvolume subvol = null;

			if ((sys_subvolumes.size > 0) && line.has_suffix(sys_subvolumes["@"].path.replace(repo.mount_paths["@"] + "/"," "))){
				subvol = sys_subvolumes["@"];
			}
			else if ((sys_subvolumes.size > 0)
				&& sys_subvolumes.has_key("@home")
				&& line.has_suffix(sys_subvolumes["@home"].path.replace(repo.mount_paths["@home"] + "/"," "))){
					
				subvol = sys_subvolumes["@home"];
			}
			else {
				foreach(var bak in repo.snapshots){
					foreach(var sub in bak.subvolumes.values){
						if (line.has_suffix(sub.path.replace(repo.mount_paths[sub.name] + "/",""))){
							subvol = sub;
							break;
						}
					}
				}
			}

			if (subvol != null){
				subvol.id = long.parse(parts[1]);
			}
		}

		return true;
	}

	public bool query_subvolume_quotas(){
		bool ok = query_subvolume_quota("@");
		if (repo.device.uuid != repo.device_home.uuid){
			ok = ok && query_subvolume_quota("@home");
		}
		return ok;
	}

	public bool query_subvolume_quota(string subvol_name){
		log_debug("query_subvolume_quota():%s".printf(subvol_name));

		string cmd = "";
		string std_out;
		string std_err;
		int ret_val;

		string options = use_option_raw ? "--raw" : "";

		cmd = "btrfs qgroup show %s '%s'".printf(options, repo.mount_paths[subvol_name]);
		log_debug(cmd);
		ret_val = exec_sync(cmd, out std_out, out std_err);

		if (ret_val != 0){
			if (use_option_raw){
				use_option_raw = false;

				// try again without --raw option
				cmd = "btrfs qgroup show '%s'".printf(repo.mount_paths[subvol_name]);
				log_debug(cmd);
				ret_val = exec_sync(cmd, out std_out, out std_err);
			}

			if (ret_val != 0){
				if (std_err.contains("not enabled")) {
					log_msg("btrfs: Quotas are not enabled");
					return false;
				}
				log_error (std_err);
				log_error(_("btrfs returned an error") + ": %d".printf(ret_val));
				log_error(_("Failed to query subvolume quota"));
				return false;
			}
		}

		/* Sample Output:
		 *
		qgroupid rfer       excl
		-------- ----       ----
		0/5      106496     106496
		0/257    3825262592 557056
		0/258    12689408   49152
		 * */

		foreach(string line in std_out.split("\n")){
			if (line == null) { continue; }

			string[] parts = line.split(" ");
			if (parts.length < 3) { continue; }
			if (parts[0].split("/").length < 2) { continue; }

			int subvol_id = int.parse(parts[0].split("/")[1]);

			Subvolume subvol = null;

			if ((sys_subvolumes.size > 0) && (sys_subvolumes["@"].id == subvol_id)){

				subvol = sys_subvolumes["@"];
			}
			else if ((sys_subvolumes.size > 0)
				&& sys_subvolumes.has_key("@home")
				&& (sys_subvolumes["@home"].id == subvol_id)){

				subvol = sys_subvolumes["@home"];
			}
			else {
				foreach(var bak in repo.snapshots){
					foreach(var sub in bak.subvolumes.values){
						if (sub.id == subvol_id){
							subvol = sub;
						}
					}
				}
			}

			if (subvol != null){
				int part_num = -1;
				foreach(string part in parts){
					if (part.strip().length > 0){
						part_num ++;
						switch (part_num){
							case 1:
								subvol.total_bytes = int64.parse(part);
								break;
							case 2:
								subvol.unshared_bytes = int64.parse(part);
								break;
							default:
								//ignore
								break;
						}
					}
				}
			}
		}

		foreach(var bak in repo.snapshots){
			bak.update_control_file();
		}

		return true;
	}

	// cron jobs

	
	// cleanup

	public void clean_logs(){

		log_debug("clean_logs()");
		
		Gee.ArrayList<string> list = new Gee.ArrayList<string>();

		try{
			var dir = File.new_for_path (log_dir);
			var enumerator = dir.enumerate_children ("*", 0);

			var info = enumerator.next_file ();
			string path;

			while (info != null) {
				if (info.get_file_type() == FileType.REGULAR) {
					path = log_dir + "/" + info.get_name();
					if (path != log_file) {
						list.add(path);
					}
				}
				info = enumerator.next_file ();
			}

			CompareDataFunc<string> compare_func = (a, b) => {
				return strcmp(a,b);
			};

			list.sort((owned) compare_func);

			if (list.size > 500){

				// delete oldest 100 files ---------------

				for(int k = 0; k < 100; k++){
					
					var file = File.new_for_path (list[k]);
					 
					if (file.query_exists()){ 
						file.delete();
						log_msg("%s: %s".printf(_("Removed"), list[k]));
					}
				}
            
				log_msg(_("Older log files removed"));
			}
		}
		catch(Error e){
			log_error (e.message);
		}
	}

	/* Unmounts every browse mount under a directory and removes the empties.
	 * Browsing makes one mount per snapshot, so this has to walk them. */
	public void unmount_browse_mounts(string browse_root){

		if (!dir_exists(browse_root)){ return; }

		var mount_points = browse_mount_points(browse_root);

		// deepest first, so a nested mount comes off before its parent
		mount_points.sort((a,b) => { return strcmp(b,a); });

		foreach(string mp in mount_points){

			string o, e;

			int ret_val = exec_script_sync(
				"fusermount3 -u '%s' 2>/dev/null || fusermount -u '%s' 2>/dev/null || umount '%s'\nexit $?\n".printf(
					escape_single_quote(mp), escape_single_quote(mp), escape_single_quote(mp)),
				out o, out e, true);

			if (ret_val != 0){
				log_error(_("Failed to unmount") + ": %s".printf(mp));
				if ((e != null) && (e.strip().length > 0)){ log_error(e.strip()); }
			}
		}

		/* Never delete recursively here. While a mount point is still mounted it
		 * resolves to the snapshot on the backup device, so a recursive delete
		 * would walk into the backup and try to erase it. Re-read /proc/mounts
		 * and bail out if anything is still mounted; otherwise the directories
		 * are empty and plain rmdir is enough. */
		if (browse_mount_points(browse_root).size > 0){
			log_error(_("Some snapshots are still mounted and were left in place") + ": %s".printf(browse_root));
			return;
		}

		exec_script_sync("rmdir '%s'/* 2>/dev/null; rmdir '%s' 2>/dev/null\nexit 0\n".printf(
			escape_single_quote(browse_root), escape_single_quote(browse_root)),
			null, null, true);
	}

	/* Mount points currently mounted at or under browse_root, per /proc/mounts. */
	private Gee.ArrayList<string> browse_mount_points(string browse_root){

		var list = new Gee.ArrayList<string>();

		string? mounts = file_read("/proc/mounts");
		if (mounts == null){ return list; }

		string prefix = browse_root.has_suffix("/") ? browse_root : browse_root + "/";

		foreach(string line in mounts.split("\n")){

			string[] parts = line.split(" ");
			if (parts.length < 2){ continue; }

			// /proc/mounts escapes spaces and tabs as octal
			string mp = parts[1].compress();

			if ((mp != browse_root) && !mp.has_prefix(prefix)){ continue; }

			list.add(mp);
		}

		return list;
	}

	/* Browse mounts live under /run/timeshift/<pid>. A crash or SIGKILL leaves
	 * them mounted with nothing to reap them, so clear out any left by a
	 * previous run whose process is gone. */
	public void reap_stale_browse_mounts(){

		string? mounts = file_read("/proc/mounts");
		if (mounts == null){ return; }

		var seen = new Gee.ArrayList<string>();

		foreach(string line in mounts.split("\n")){

			string[] parts = line.split(" ");
			if (parts.length < 2){ continue; }
			if (!parts[1].has_prefix("/run/timeshift/")){ continue; }
			if (!parts[1].contains("/browse/")){ continue; }

			// /run/timeshift/<pid>/browse/<hash>
			string[] bits = parts[1].split("/");
			if (bits.length < 4){ continue; }

			string pid_str = bits[3];
			if (dir_exists("/proc/%s".printf(pid_str))){ continue; } // still alive

			string root = "/run/timeshift/%s/browse".printf(pid_str);
			if (seen.contains(root)){ continue; }
			seen.add(root);

			log_debug("reaping stale browse mounts from pid %s".printf(pid_str));
			unmount_browse_mounts(root);
		}

		reap_stale_run_dirs();
	}

	/* A run that was killed leaves an empty /run/timeshift/<pid> behind, since
	 * exit_app() never got to remove it. Clear out the ones whose process is
	 * gone. rmdir only, so a directory that still holds anything is left alone. */
	private void reap_stale_run_dirs(){

		try{
			var dir = File.new_for_path("/run/timeshift");
			if (!dir.query_exists()){ return; }

			var iter = dir.enumerate_children(FileAttribute.STANDARD_NAME, 0);
			FileInfo info;

			while ((info = iter.next_file()) != null){

				string name = info.get_name();

				// only numeric names, and never our own
				int64 pid = 0;
				if (!int64.try_parse(name, out pid)){ continue; }
				if (pid == (int64) Posix.getpid()){ continue; }
				if (dir_exists("/proc/%s".printf(name))){ continue; }

				string stale = "/run/timeshift/%s".printf(name);

				/* The ssh control socket has to go first.
				 *
				 * rmdir cannot remove a socket, so a master that was killed
				 * rather than shut down left one behind -- and with it a
				 * directory that could never be reaped. Those accumulate for
				 * the life of the boot, and if the kernel later recycles that
				 * pid onto a new Timeshift, the new run's ControlPath points
				 * straight at the old socket.
				 *
				 * Deliberately narrow: only ssh-* directly inside a directory
				 * whose pid is gone. The mount points under it are handled by
				 * cleanup_unmount_devices(), and must not be rm -rf'd here. */
				exec_script_sync(
					("rm -f '%s'/ssh-* 2>/dev/null; " +
					 "rmdir '%s'/* 2>/dev/null; rmdir '%s' 2>/dev/null\nexit 0\n").printf(
						escape_single_quote(stale), escape_single_quote(stale),
						escape_single_quote(stale)),
					null, null, true);
			}
		}
		catch(Error e){
			log_debug(e.message);
		}
	}

	public void exit_app (int exit_code = 0){

		log_debug("exit_app()");
		
		if (app_mode == ""){
			//update app config only in GUI mode
			save_app_config();
		}


		unmount_target_device(false);

		// Unmount anything browsing mounted. cleanup_unmount_devices() will
		// not catch these: that sweep matches against the device list, which
		// filters out anything without a UUID - and a FUSE mount has none.
		unmount_browse_mounts(path_combine(mount_point_app, "browse"));

		// close the multiplexed SSH connection, if one was opened
		if (repo != null){
			repo.backend.cleanup();
		}

		clean_logs();

		/* Release the repository write lock if an operation was interrupted.
		 * The kernel would drop it when we exit anyway; doing it here means a
		 * waiter stops waiting a moment sooner. */
		if (repo_lock != null){ repo_lock.release(); }
		
		dir_delete(TEMP_DIR);
		
		cleanup_unmount_devices();
		
		exit(exit_code);

		//Gtk.main_quit ();
	}
	
	private void cleanup_unmount_devices(){
		
		log_debug("cleanup_unmount_devices()");
		
		if (!dir_exists("/run/timeshift")){ return; }
		
		var dirlist = dir_list_names("/run/timeshift");
		
		foreach(var dname in dirlist){
			
			/* Only numeric-pid entries are run directories.
			 *
			 * /run/timeshift also holds daemon.sock and repo.lock, and
			 * int.parse() returns 0 for both -- which sent this loop on to
			 * treat a socket as a directory and log "Error opening directory"
			 * on every exit. Same rule as reap_stale_run_dirs() and as the Go
			 * reaper: a name that is not a pid is not ours to sweep. */
			int64 parsed = 0;
			if (!int64.try_parse(dname, out parsed)){ continue; }
			if (parsed <= 0){ continue; }

			int pid = (int) parsed;

			if (pid != Posix.getpid()){ // if some other process
				
				// check if the process is still running
				
				string procdir = "/proc/%d".printf(pid);
				
				if (dir_exists(procdir)){ continue; }
			}
			
			// -----------------------------------------------
			
			string mdir = "/run/timeshift/%s".printf(dname);
			
			var dirlist2 = dir_list_names(mdir);
			
			foreach(var dname2 in dirlist2){
				
				string mdir2 = "/run/timeshift/%s/%s".printf(dname, dname2);
				
				// check if a device is mounted here
				
				foreach (var dev in Device.get_filesystems()){
					
					foreach (var mnt in dev.mount_points){
						
						if (mnt.mount_point == mdir2){
							
							log_debug("\nFound stale mount for device '%s' at path '%s'".printf(dev.device, mdir2));
			
							string cmd = "umount '%s'".printf(escape_single_quote(mdir2));
							int retval = exec_sync(cmd);

							if (retval != 0){
								log_debug("E: Failed to unmount");
								log_debug("Ret=%d".printf(retval));
								//ignore
							}
							else{
								log_debug("Unmounted successfully");
							}

							// delete directory
							if(!dir_empty_delete(mdir2)) {
								log_debug("E: Failed to delete %s".printf(mdir2));
							}
						}
					}
				}
			}
			
			if (dir_exists(mdir)){

				string cmd3 = "rmdir '%s'".printf(escape_single_quote(mdir));
				int retval3 = exec_sync(cmd3);
				
				if (retval3 != 0){
					log_error("Failed to remove directory");
					log_msg("Ret=%d".printf(retval3));
					//ignore
				}
			}
		}
	}
}




