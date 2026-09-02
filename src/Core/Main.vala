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
	 * restore_phases is the checklist: the steps this restore will actually
	 * take, in order, filled by create_restore_scripts(). restore_phase is
	 * the key of the step running now - set by the script through its
	 * @@TS_PHASE markers, and directly by the steps that happen in Vala
	 * rather than in the script. restore_script_task is whichever script is
	 * running, so the log pane knows where to read raw output from. */
	public Gee.ArrayList<RestorePhase> restore_phases = new Gee.ArrayList<RestorePhase>();
	public string restore_phase = "";
	public RestoreScriptTask? restore_script_task = null;

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

	/* Take the repository write lock, or wait for whoever has it.
	 *
	 * Waits rather than refuses. A person who asked for a backup while a
	 * restore is running wants it queued, not rejected -- and refusing is what
	 * AppLock did. The GUI does an advisory check before it ever gets here
	 * (MainWindow consults the daemon and offers to watch instead), so an
	 * actual wait means two operations genuinely overlapped. */
	private bool acquire_repo_lock(string what){

		if (repo_lock == null){ repo_lock = new RepoLock(); }

		if (repo_lock.try_acquire(what)){ return true; }

		string who = repo_lock.describe_holder();
		log_msg("%s: %s".printf(_("Waiting for another Timeshift operation to finish"), who));
		progress_text = _("Waiting for another Timeshift operation to finish...");

		return repo_lock.acquire(what);
	}

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
	 
	public void init_mount_list(){

		log_debug("Main: init_mount_list()");
		
		mount_list.clear();

		Gee.ArrayList<FsTabEntry> fstab_list = null;
		Gee.ArrayList<CryptTabEntry> crypttab_list = null;
		
		if (mirror_system){
			string fstab_path = "/etc/fstab";
			fstab_list = FsTabEntry.read_file(fstab_path);
			string cryttab_path = "/etc/crypttab";
			crypttab_list = CryptTabEntry.read_file(cryttab_path);
		}
		else{
			fstab_list = snapshot_to_restore.fstab_list;
			crypttab_list = snapshot_to_restore.cryttab_list;
		}

		bool root_found = false;
		bool boot_found = false;
		bool home_found = false;
		dst_root = null;
		
		foreach(var fs_entry in fstab_list){

			// skip mounting for non-system devices ----------
			
			if (!fs_entry.is_for_system_directory()){
				continue;
			}

			// skip mounting excluded devices -----------------------
			
			string p1 = "%s/*".printf(fs_entry.mount_point);
			string p2 = "%s/**".printf(fs_entry.mount_point);
			string p3 = "%s/***".printf(fs_entry.mount_point);
			
			if (exclude_list_default.contains(p1) || exclude_list_user.contains(p1)){
				continue;
			}
			else if (exclude_list_default.contains(p2) || exclude_list_user.contains(p2)){
				continue;
			}
			else if (exclude_list_default.contains(p3) || exclude_list_user.contains(p3)){
				continue;
			}

			// find device by name or uuid --------------------------
			
			Device dev_fstab = null;
			if (fs_entry.device_uuid.length > 0){
				dev_fstab = Device.get_device_by_uuid(fs_entry.device_uuid);
			}
			else{
				dev_fstab = Device.get_device_by_name(fs_entry.device_string);
			}

			if (dev_fstab == null){

				/*
				Check if the device mentioned in fstab entry is a mapped device.
				If it is, then try finding the parent device which may be available on the current system.
				Prompt user to unlock it if found.
				
				Note:
				Mapped name may be different on running system, or it may be same.
				Since it is not reliable, we will try to identify the parent instead of the mapped device.
				*/
				
				if (fs_entry.device_string.has_prefix("/dev/mapper/")){
					
					string mapped_name = fs_entry.device_string.replace("/dev/mapper/","");
					
					foreach(var crypt_entry in crypttab_list){
						
						if (crypt_entry.mapped_name == mapped_name){

							// we found the entry for the mapped device
							fs_entry.device_string = crypt_entry.device_string;

							if (fs_entry.device_uuid.length > 0){
								
								// we have the parent's uuid. get the luks device and prompt user to unlock it.
								var dev_luks = Device.get_device_by_uuid(fs_entry.device_uuid);
								
								if (dev_luks != null){
									
									string msg_out, msg_err;
									var dev_unlocked = Device.luks_unlock(
										dev_luks, "", "", parent_window, out msg_out, out msg_err);

									if (dev_unlocked != null){
										dev_fstab = dev_unlocked;
										update_partitions();
									}
									else{
										dev_fstab = dev_luks; // map to parent
									}
								}
							}
							else{
								// nothing to do: we don't have the parent's uuid
							}

							break;
						}
					}
				}
			}

			if (dev_fstab != null){
				
				log_debug("added: dev: %s, path: %s, options: %s".printf(
					dev_fstab.device, fs_entry.mount_point, fs_entry.options));
					
				mount_list.add(new MountEntry(dev_fstab, fs_entry.mount_point, fs_entry.options));
				
				if (fs_entry.mount_point == "/"){
					dst_root = dev_fstab;
				}
			}
			else{
				log_debug("missing: dev: %s, path: %s, options: %s".printf(
					fs_entry.device_string, fs_entry.mount_point, fs_entry.options));

				mount_list.add(new MountEntry(null, fs_entry.mount_point, fs_entry.options));
			}

			if (fs_entry.mount_point == "/"){
				root_found = true;
			}
			if (fs_entry.mount_point == "/boot"){
				boot_found = true;
			}
			if (fs_entry.mount_point == "/home"){
				home_found = true;
			}
		}

		if (!root_found){
			log_debug("added null entry: /");
			mount_list.add(new MountEntry(null, "/", "")); // add root entry
		}

		if (!boot_found){
			log_debug("added null entry: /boot");
			mount_list.add(new MountEntry(null, "/boot", "")); // add boot entry
		}

		if (!home_found){
			log_debug("added null entry: /home");
			mount_list.add(new MountEntry(null, "/home", "")); // add home entry
		}

		/*
		While cloning the system, /boot is the only mount point that
		we will leave unchanged (to avoid encrypted systems from breaking).
		All other mounts like /home will be defaulted to target device
		(to prevent the "cloned" system from using the original device)
		*/
		
		if (mirror_system){
			dst_root = null;
			foreach (var entry in mount_list){
				// user should select another device
				entry.device = null; 
			}
		}

		foreach(var mnt in mount_list){
			if (mnt.device != null){
				log_debug("Entry: %s -> %s".printf(mnt.device.device, mnt.mount_point));
			}
			else{
				log_debug("Entry: null -> %s".printf(mnt.mount_point));
			}
		}

		// sort - parent mountpoints will be placed above children
		mount_list.sort((a,b) => {
			return strcmp(a.mount_point, b.mount_point);
		});

		init_boot_options(); // boot options depend on the mount list
		
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
	
	public bool restore_snapshot(Gtk.Window? parent_win){

		if (!acquire_repo_lock("restore")){
			log_error(_("Could not take the repository lock"));
			return false;
		}

		try {
			return restore_snapshot_locked(parent_win);
		}
		finally {
			repo_lock.release();
		}
	}

	private bool restore_snapshot_locked(Gtk.Window? parent_win){

		log_debug("Main: restore_snapshot()");
		
		parent_window = parent_win;

		// remove mount points which will remain on root fs
		
		for(int i = mount_list.size-1; i >= 0; i--){
			var entry = mount_list[i];
			if (entry.device == null){
				mount_list.remove(entry);
			}
		}
			
		// check if we have all required inputs and abort on error
		
		if (!mirror_system){
			
			// a remote repository has no Device; the location is the URL
			if ((repo.device == null) && !repo.backend.is_remote){
				log_error(_("Backup device not specified!"));
				return false;
			}
			else{
				log_msg(string.nfill(78, '*'));
				log_msg(_("Backup Device") + ": %s".printf(
					(repo.device == null) ? repo.backend.display_name : repo.device.device));
				log_msg(string.nfill(78, '*'));
			}
			
			if (snapshot_to_restore == null){
				log_error(_("Snapshot to restore not specified!"));
				return false;
			}
			else if ((snapshot_to_restore != null) && (snapshot_to_restore.marked_for_deletion)){
				log_error(_("Invalid Snapshot"));
				log_error(_("Selected snapshot is marked for deletion"));
				return false;
			}
			else {
				log_msg(string.nfill(78, '*'));
				log_msg("%s: %s ~ %s".printf(_("Snapshot"), snapshot_to_restore.name, snapshot_to_restore.description));
				log_msg(string.nfill(78, '*'));
			}
		}
		
		// final check - check if target root device is mounted

		if (btrfs_mode){
			if (repo.mount_paths["@"].length == 0){
				log_error(_("BTRFS device is not mounted") + ": @");
				return false;
			}
			if (include_btrfs_home_for_restore && (repo.mount_paths["@home"].length == 0)){
				log_error(_("BTRFS device is not mounted") + ": @home");
				return false;
			}
		}
		else{
			if (dst_root == null){
				log_error(_("Target device not specified!"));
				return false;
			}

			if (!restore_current_system){
				if (mount_point_restore.strip().length == 0){
					log_error(_("Target device is not mounted"));
					return false;
				}
			}
		}

		try {
			thread_restore_running = true;
			thr_success = false;
			
			if (btrfs_mode){
				new Thread<bool>.try ("restore-execute-btrfs", () => {restore_execute_btrfs(); return true;});
			}
			else{
				new Thread<bool>.try ("restore-execute-rsync", () => {restore_execute_rsync(); return true;});
			}
		}
		catch (Error e) {
			thread_restore_running = false;
			thr_success = false;
			log_error (e.message);
		}

		while (thread_restore_running){
			gtk_do_events ();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 100);
		}

		if (!dry_run){
			snapshot_to_restore = null;
		}

		log_debug("Main: restore_snapshot(): exit");
		
		return thr_success;
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

	/* The checklist under construction. It is published to restore_phases in
	 * one reference assignment once complete, because the GUI polls that
	 * field from the main thread while this runs on a worker. */
	private Gee.ArrayList<RestorePhase> phases_building = new Gee.ArrayList<RestorePhase>();

	/* Records a step in the restore checklist and returns the line that makes
	 * the script announce it. Nothing is echoed in console mode: there the
	 * script's own output is the interface, and a marker would just be noise. */
	/* The marker on its own, without registering another checklist step.
	 *
	 * Needed because the retry loop re-runs rsync INSIDE the already-announced
	 * sync_files phase: no new phase marker was ever emitted, so the "Connection
	 * lost - reconnecting" banner stayed up for the rest of a transfer that had
	 * long since resumed. */
	private string phase_marker_echo(string key){

		if (app_mode != ""){ return ""; }

		return "echo '%s%s' \n".printf(RestoreScriptTask.PHASE_MARKER, key);
	}

	private string phase_marker(string key, string title){

		add_restore_phase(key, title);

		if (app_mode != ""){ return ""; }

		return "echo '%s%s' \n".printf(RestoreScriptTask.PHASE_MARKER, key);
	}

	/* A step that happens in Vala rather than in the script, so it has a row
	 * in the checklist but no marker. */
	private void add_restore_phase(string key, string title){
		phases_building.add(new RestorePhase(key, title));
	}

	private void publish_restore_phases(){
		restore_phases = phases_building;
	}

	/* The title shown in the checklist for a phase key, so the finish screen
	 * can name the failing step the way the user just saw it. */
	private string restore_phase_title(string key){

		if (restore_phases != null){
			foreach(var phase in restore_phases){
				if (phase.key == key){ return phase.title; }
			}
		}

		return key;
	}

	/* The progress page needs this too, to say what the drop actually was. */
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

	/* Turn the transfer's own account of itself into the outcome.
	 *
	 * sh_sync ends with "sync" on both the clean and the warning paths, so its
	 * exit code alone cannot tell them apart -- the WARNINGS marker and the
	 * sentinel are what carry that, which is why they are read here. */
	private void collect_transfer_result(RestoreScriptTask t){

		foreach(string line in t.error_lines){
			restore_note(line);
		}

		if (t.error_line_count > t.error_lines.size){
			restore_note(_("... and %d more").printf(t.error_line_count - t.error_lines.size));
		}

		bool aborted = file_exists(restore_failed_flag()) || (t.failure_code.length > 0);

		if (aborted || (t.exit_code != 0)){

			string code = (t.failure_code.length > 0)
				? t.failure_code
				: t.exit_code.to_string();

			restore_fail(_("The snapshot could not be copied to the target (rsync exit code %s).").printf(code));
			restore_note(rsync_exit_meaning(code));
			restore_note(_("The target is incomplete and must not be booted. Re-run the restore."));
			return;
		}

		if (t.had_warnings){
			restore_warn(_("Some files could not be copied. Everything else was restored."));
		}
	}

	/* A step after the transfer failed.
	 *
	 * Deliberately a warning and not a failure: the files are on the disk. The
	 * remedy -- reinstall the bootloader -- has nothing in common with re-running
	 * a lost restore, and reporting both as "Completed With Errors" is what made
	 * the original failure impossible to act on. */
	private void collect_finish_result(RestoreScriptTask t){

		if (t.failed_step.length == 0){

			if (t.exit_code != 0){
				restore_warn(_("A step after the restore did not finish cleanly."));
			}

			return;
		}

		restore_failed_step = t.failed_step;
		restore_failed_step_rc = t.failed_step_rc;

		restore_warn(_("Your files were restored, but the step \"%s\" failed (exit code %s).").printf(
			restore_phase_title(t.failed_step), t.failed_step_rc));

		if ((t.failed_step == "grub_install") || (t.failed_step == "grub_menu")){
			restore_note(_("The boot loader was not installed, so the restored system will not start on its own."));
			restore_note(_("Boot from a live USB, mount the restored system and re-install GRUB."));
		}
		else if (t.failed_step == "initramfs"){
			restore_note(_("The initramfs was not rebuilt. The restored system may fail to boot."));
		}
	}

	/* Warn when a restored system has snaps but no way to launch them.
	 *
	 * Snapshots taken before /snap/bin was preserved contain every .snap
	 * payload, working mount units and the right desktop files -- and no
	 * /snap/bin, so every snap command fails with a message that wrongly says
	 * the snap is not installed. Nothing here reconstructs the links:
	 * /snap/<name>/current could be derived from the mount units, but the
	 * /snap/bin entries come from each snap's own metadata, which is snapd's
	 * business and would drift from it. */
	private void check_snap_links_restored(){

		if (restore_current_system){ return; } // its own /snap is untouched
		if (dry_run){ return; }

		string snaps_dir = path_combine(restore_target_path, "var/lib/snapd/snaps");

		if (!dir_exists(snaps_dir)){ return; } // no snapd on this system

		// an empty snaps dir means nothing to launch in the first place
		if (dir_list_names(snaps_dir).size == 0){ return; }

		if (!dir_exists(path_combine(restore_target_path, "snap/bin"))){

			restore_warn(_("Snap applications will not start: this snapshot was taken before /snap/bin was included in backups."));
			restore_note(_("Run 'sudo snap refresh' on the restored system to rebuild them."));
		}

		check_snap_confine_capabilities();
	}

	/* snap-confine without its file capabilities breaks every snap.
	 *
	 * The capabilities live in a security.capability xattr, and snapshots taken
	 * before rsync was given -X never captured one -- so the binary restores
	 * intact, setuid, and still refuses to run with "snap-confine is packaged
	 * without necessary permissions". Nothing here re-applies them: the correct
	 * values belong to the snapd package and hard-coding a table would go stale
	 * the first time upstream changed it. */
	private void check_snap_confine_capabilities(){

		string binary = path_combine(restore_target_path, "usr/lib/snapd/snap-confine");

		if (!file_exists(binary)){ return; }

		// no getcap: cannot tell, so say nothing rather than warn wrongly
		if (!cmd_exists("getcap")){
			log_debug("getcap not available; skipping the snap-confine capability check");
			return;
		}

		string std_out, std_err;
		exec_script_sync("getcap '%s'".printf(escape_single_quote(binary)),
			out std_out, out std_err, true);

		if ((std_out != null) && std_out.contains("cap_")){ return; } // intact

		restore_warn(_("Snap applications will not start: this snapshot predates extended-attribute support, so snap-confine lost its file capabilities."));
		restore_note(_("Fix on the restored system with: sudo apt install --reinstall snapd"));
	}

	/* Put the rsync log somewhere that outlives the session.
	 *
	 * For a remote repository restore_log_file lives in TEMP_DIR, which in a
	 * live recovery environment is tmpfs. The restore that most needs
	 * explaining is exactly the one after which the machine is rebooted, and
	 * the log went with it -- the target's own /var/log/timeshift was empty. */
	private void save_restore_log_to_target(){

		if (restore_current_system){ return; } // the target is /; nothing to copy to
		if (dry_run){ return; }
		if (!file_exists(restore_log_file)){ return; }

		string dir = path_combine(restore_target_path, "var/log/timeshift");

		// already written there directly; nothing to copy
		if (file_parent(restore_log_file) == remove_trailing_slash(dir)){
			restore_note(_("Log on the restored system: %s").printf(
				"/var/log/timeshift/" + file_basename(restore_log_file)));
			return;
		}

		if (!dir_exists(dir) && !dir_create(dir)){ return; }

		string name = "%s_restore_rsync_log".printf(
			new DateTime.now_local().format("%Y-%m-%d_%H-%M-%S"));

		string dest = path_combine(dir, name);

		if (file_copy(restore_log_file, dest)){
			log_msg(_("Restore log saved to %s").printf(dest));
			restore_note(_("Log on the restored system: %s").printf(
				"/var/log/timeshift/" + name));
		}
	}

	/* Printed by the source probe's shell when rsync succeeded. */
	private const string SOURCE_OK_MARKER = "@@TS_SOURCE_OK";

	/* A file the script touches before it aborts.
	 *
	 * The console restore paths run through exec_script_sync(), which always
	 * reports success -- its wrapper's trailing echo is the last command -- and
	 * in verbose mode there is no captured output to scan either. A sentinel on
	 * disk is the one signal that survives both. */
	private string restore_failed_flag(){
		return path_combine(file_parent(restore_log_file), ".timeshift-restore-failed");
	}

	/* Can the snapshot actually be read, and does it contain anything?
	 *
	 * rsync reports a missing source directory, an unreadable one and a handful
	 * of skipped files all as exit 23, and 23 is the "carry on to the finish
	 * steps" path. By then --delete has already run against the target. So the
	 * source is listed first, and a source that is missing OR empty stops the
	 * restore while the target is still intact.
	 *
	 * --list-only without -r lists one level, so this costs a single round trip
	 * rather than a walk of the whole snapshot. */
	private bool restore_source_is_readable(out string error_message){

		error_message = "";

		if (mirror_system){
			return true; // cloning the running system; the source is /
		}

		string src = "%s%s".printf(
			repo_is_remote() ? repo.backend.rsync_prefix() : "",
			restore_source_path + "/localhost/");

		string cmd = "rsync --list-only";

		if (repo_is_remote()){

			cmd += " --numeric-ids";
			cmd += " -e '%s'".printf(escape_single_quote(repo.backend.rsync_rsh()));

			string remote_rsync = repo.backend.rsync_remote_path();
			if (remote_rsync.length > 0){
				cmd += " --rsync-path='%s'".printf(escape_single_quote(remote_rsync));
			}
		}

		cmd += " '%s'".printf(escape_single_quote(src));

		/* exec_script_sync() always returns 0 -- its wrapper's trailing echo is
		 * the last command -- so the shell reports success in the output
		 * instead of in the status. */
		cmd += " && echo '%s'".printf(SOURCE_OK_MARKER);

		log_debug("probing restore source: %s".printf(cmd));

		string std_out, std_err;
		exec_script_sync(cmd, out std_out, out std_err);

		if ((std_out == null) || !std_out.contains(SOURCE_OK_MARKER)){

			error_message = _("The snapshot location could not be listed.");

			string detail = ((std_err == null) ? "" : std_err.strip());
			if (detail.length > 0){
				error_message += " " + detail.split("\n")[0];
			}

			return false;
		}

		int entries = 0;
		foreach(string line in std_out.split("\n")){
			if (line.strip().length == 0){ continue; }
			if (line.contains(SOURCE_OK_MARKER)){ continue; }
			entries++;
		}

		/* One entry is the directory itself. A snapshot with nothing in it
		 * would restore as "delete everything on the target". */
		if (entries < 2){
			error_message = _("The snapshot appears to be empty. Restoring it would erase the target.");
			return false;
		}

		return true;
	}

	/* The retry loop around the restore's rsync, plus the guard that stops the
	 * script dead if it ultimately fails.
	 *
	 * Both halves matter, and the second one more. Before this, rsync's exit
	 * status was never looked at: a dropped wifi link mid-transfer fell through
	 * to the finish script, which bind-mounts /dev and /proc into the target,
	 * runs grub-install --force, regenerates the initramfs and reboots -- all
	 * over a half-copied root filesystem, while reporting success. A two-second
	 * blip could hand back an unbootable machine.
	 *
	 * rsync is idempotent and resumable, so retrying simply continues. The exit
	 * codes are split by whether retrying can plausibly help:
	 *
	 *   0, 24    done (24 = source files vanished; harmless)
	 *   10 12 30 35 255   socket/protocol/timeout/ssh -- the network. Retry for
	 *                     as long as the user is willing to wait: a partially
	 *                     restored system has no good ending, so a timer must
	 *                     not be the thing that gives up on it.
	 *   23       partial transfer, usually permissions rather than the link.
	 *            Not retried at all: a retry re-scans the whole tree only to
	 *            fail on the same files, so it becomes a warning instead.
	 *   *        usage error, disk full: retrying cannot help. Fail now.
	 */
	private string restore_rsync_retry_block(){

		string probe = repo_is_remote() ? repo.backend.reachability_command() : "";

		/* Emitted into the script rather than called from Vala: the retry loop
		 * runs inside the generated shell, long after this function returned. */
		string drop = repo_is_remote() ? repo.backend.drop_master_command() : "";

		string sh = "";

		sh += "ts_attempt=0\n";
		sh += "while :; do\n";
		sh += "  ts_attempt=$((ts_attempt + 1))\n";
		sh += "  ts_run_rsync\n";
		sh += "  ts_rc=$?\n";
		sh += "  case $ts_rc in\n";
		sh += "    0|24) break ;;\n";
		/* 23 = "some files could not be transferred", the rest succeeded.
		 * Almost always a permission or special-file problem, which retrying
		 * cannot fix -- and each retry would re-scan the entire tree. So it is
		 * a warning: carry on to the finish steps, and let the summary name the
		 * files that were skipped. */
		sh += "    23)\n";
		sh += "      echo '%s'\n".printf(RestoreScriptTask.WARNINGS_MARKER);
		sh += "      break\n";
		sh += "      ;;\n";
		sh += "    10|12|30|35|255)\n";
		// "<attempt>:<rsync exit code>", so the banner can say what happened
		sh += "      echo '%s'\"$ts_attempt:$ts_rc\"\n".printf(RestoreScriptTask.RECONNECT_MARKER);
		sh += "      echo \"Connection lost (rsync exit $ts_rc). Waiting for the snapshot location...\"\n";
		sh += "      echo 'The transfer resumes where it stopped; nothing already copied is lost.'\n";

		/* Drop the shared ssh connection before probing.
		 *
		 * The master that carried the dead transfer is still resident, and
		 * every later ssh -- including the probe below -- would attach to it
		 * over its unix socket, where ConnectTimeout does not apply. That is
		 * an indefinite block, not a retry. */
		if (drop.length > 0){
			sh += "      %s\n".printf(drop);
		}

		if (probe.length > 0){
			// Wait for the host to answer again rather than burning attempts
			// against a link that is still down. Capped per round so a
			// permanently dead host still cycles and keeps the UI informed.
			sh += "      ts_wait=0\n";
			sh += "      while [ $ts_wait -lt 60 ]; do\n";
			sh += "        if %s >/dev/null 2>&1; then break; fi\n".printf(probe);
			sh += "        ts_wait=$((ts_wait + 1))\n";
			sh += "        sleep 5\n";
			sh += "      done\n";
		}
		else {
			sh += "      sleep 5\n";
		}

		sh += "      echo 'Retrying...'\n";
		// re-announce the phase so the reconnect banner clears
		sh += "      %s".printf(phase_marker_echo("sync_files"));
		sh += "      ;;\n";
		sh += "    *)\n";
		sh += "      echo '%s'$ts_rc\n".printf(RestoreScriptTask.FAILED_MARKER);
		sh += "      echo 'The target is INCOMPLETE and must not be booted. Re-run the restore.'\n";
		sh += "      touch '%s'\n".printf(escape_single_quote(restore_failed_flag()));
		sh += "      exit 1\n";
		sh += "      ;;\n";
		sh += "  esac\n";
		sh += "done\n";

		return sh;
	}

	private void create_restore_scripts(out string sh_sync, out string sh_finish){

		log_debug("Main: create_restore_scripts()");
		
		string sh = "export LC_ALL=C.UTF-8\n";

		// create scripts --------------------------------------

		phases_building = new Gee.ArrayList<RestorePhase>();
		restore_phases = new Gee.ArrayList<RestorePhase>();
		restore_phase = "";

		if (dry_run){
			// measured by this very run; anything left over is from last time
			restore_line_count_estimate = 0;
		}

		sh = "";
		sh += "echo ''\n";
		if (restore_current_system){
			log_debug("restoring current system");
			
			sh += "echo '" + escape_single_quote(_("Please do not interrupt the restore process!")) + "'\n";
			sh += "echo '" + escape_single_quote(_("System will reboot after files are restored")) + "'\n";
		}
		sh += "echo ''\n";
		sh += phase_marker("prepare", _("Preparing"));
		sh += "sleep 3s\n";

		// run rsync ---------------------------------------

		sh += phase_marker("sync_files",
			dry_run ? _("Comparing files") : _("Restoring files"));

		/* -aii, not -avi: the second -i itemises unchanged files too. That is
		 * what RsyncTask.build_script() uses, and it is what makes the line
		 * count track the file count, so the progress bar means something. */
		/* Wrapped in a function, not a variable: the command embeds
		 * single-quoted paths and an -e '...' option, and re-expanding that
		 * from a string would need eval and would mangle any path with a
		 * space. A function preserves the quoting exactly. */
		sh += "ts_run_rsync() {\n";
		/* -X: extended attributes.
		 *
		 * rsync's archive mode is "-rlptgoD (no -A,-X,-U,-N,-H)", so without
		 * this every security.capability xattr is silently dropped. That is not
		 * cosmetic: /usr/lib/snapd/snap-confine carries ten file capabilities,
		 * and a restored copy without them fails with "snap-confine is packaged
		 * without necessary permissions", which breaks EVERY snap on the
		 * system. ping and mtr-packet lose cap_net_raw the same way.
		 *
		 * --fake-super only stores non-user xattrs when --xattrs is given, so
		 * for a remote repository the two work together: the capability is
		 * kept as user.rsync.security.capability on the far side and expanded
		 * back to a real security.capability on restore, which succeeds
		 * because the restore runs as root locally. */
		/* -H: preserve hard links.
		 *
		 * Also omitted by archive mode. Without it every hardlinked path is
		 * copied as an independent file -- 138 files in /usr/bin and /usr/lib
		 * alone on a stock Ubuntu -- so a restored system silently stops
		 * sharing inodes it used to share, and the snapshot is larger than the
		 * source it came from.
		 *
		 * Links are detected by (device, inode) within the transferred tree
		 * only, so --link-dest's cross-snapshot sharing cannot leak in and
		 * link two paths that were never linked on the source. */
		sh += "rsync -aiirXH --force --delete --delete-before";

		if (dry_run){
			sh += " --dry-run";
		}

		/* --partial-dir, not bare --partial: --partial leaves a TRUNCATED file
		 * at its real path, which on a system restore is precisely the
		 * corruption this is meant to prevent. A partial dir keeps the
		 * incomplete copy aside until it is whole, and rsync excludes it from
		 * --delete automatically.
		 *
		 * --timeout catches a connection that has hung rather than dropped;
		 * ssh's ServerAlive* (see RepoBackend.ssh_options) only catches a link
		 * that is actually dead. */
		if (!dry_run){
			sh += " --partial-dir=.timeshift-partial";
		}
		sh += " --timeout=120";

		// Pulling from a remote repository: the target stays local, only the
		// source is remote. Numeric ids are required across the SSH boundary,
		// and --fake-super has to be repeated on the source side so the stored
		// ownership is expanded again.
		if (repo_is_remote()){

			sh += " --numeric-ids";
			sh += " -e '%s'".printf(escape_single_quote(repo.backend.rsync_rsh()));

			string remote_rsync = repo.backend.rsync_remote_path();
			if (remote_rsync.length > 0){
				sh += " --rsync-path='%s'".printf(escape_single_quote(remote_rsync));
			}
		}

		// single-quoted: this string is assembled into a local bash script, so
		// double quotes would let $, backticks and \ in a path be expanded
		sh += " --log-file='%s'".printf(escape_single_quote(restore_log_file));
		sh += " --exclude-from='%s'".printf(escape_single_quote(restore_exclude_file));

		if (mirror_system){
			sh += " '%s' '%s'\n}\n".printf("/", escape_single_quote(restore_target_path));
		}
		else{
			sh += " '%s%s' '%s'\n}\n".printf(
				repo_is_remote() ? repo.backend.rsync_prefix() : "",
				escape_single_quote(restore_source_path + "/localhost/"),
				escape_single_quote(restore_target_path));
		}

		sh += restore_rsync_retry_block();

		if (dry_run){
			sh_sync = sh;
			sh_finish = "";
			publish_restore_phases();
			return; // no need to continue
		}

		sh += phase_marker("flush", _("Flushing writes to disk"));
		sh += "sync \n"; // sync file system

		log_debug("rsync script:");
		log_debug(sh);

		sh_sync = sh;

		/* Between the two scripts the other-device path fixes up the target's
		 * fstab and parses the rsync log, in Vala. They are steps the user
		 * waits through, so they belong in the checklist. */
		if (!restore_current_system){
			add_restore_phase("fix_fstab", _("Updating fstab and crypttab"));
			add_restore_phase("parse_log", _("Parsing log file"));
		}
		
		// chroot and re-install grub2 ---------------------

		log_debug("reinstall_grub2=%s".printf(reinstall_grub2.to_string()));
		log_debug("grub_device=%s".printf((grub_device == null) ? "null" : grub_device));

		/* No LinuxDistro.get_dist_info(restore_target_path) here.
		 *
		 * This function runs BEFORE rsync, so on a freshly formatted target
		 * there is no /etc/lsb-release to read and every distro test below
		 * silently took the generic branch. The steps now ask the restored
		 * system at run time which tools it actually has, which is both correct
		 * whenever this is built and distro-agnostic. */

		sh = "";

		string chroot = "";
		if (!restore_current_system){
			chroot += "chroot \"%s\"".printf(restore_target_path);
		}

		/* Announce a failed step instead of ignoring it.
		 *
		 * Every step here used to run unguarded, and the script's status was
		 * whatever the last command happened to return -- so a grub-install
		 * that failed on a half-restored target was completely invisible and
		 * the user was told the restore had merely "Completed With Errors". */
		/* Where each step's own output goes.
		 *
		 * ts_step used to record nothing but the exit code, so when
		 * grub-install failed the one line that said WHY -- "cannot find EFI
		 * directory" -- was never written anywhere, and the diagnosis needed a
		 * disk-image autopsy. Next to the rsync log, on the restored system,
		 * so it survives the reboot. */
		sh += "TS_STEP_LOG='%s'\n".printf(escape_single_quote(restore_steps_log_file()));
		sh += "mkdir -p \"$(dirname \"$TS_STEP_LOG\")\" 2>/dev/null\n";

		sh += "ts_step() {\n";
		sh += "  ts_key=$1; shift\n";
		// tee, so the output still reaches the progress pane as well as the log
		sh += "  \"$@\" 2>&1 | tee -a \"$TS_STEP_LOG\"\n";
		sh += "  ts_rc=${PIPESTATUS[0]}\n";
		sh += "  if [ $ts_rc -ne 0 ]; then\n";
		sh += "    echo \"$ts_key failed with exit code $ts_rc\" >> \"$TS_STEP_LOG\"\n";
		sh += "    echo '%s'\"$ts_key:$ts_rc\"\n".printf(RestoreScriptTask.STEP_FAILED_MARKER);
		sh += "  fi\n";
		sh += "  return $ts_rc\n";
		sh += "}\n";

		// does the restored system have this command?
		sh += "ts_has() {\n";
		sh += "  %s sh -c \"command -v $1 >/dev/null 2>&1\"\n".printf(chroot);
		sh += "}\n";

		if (!restore_current_system){

			sh += phase_marker("chroot_bind", _("Preparing target system"));

			/* --rbind, not --bind: /sys/firmware/efi/efivars is a mount of its
			 * own beneath /sys, and without it grub-install inside the chroot
			 * reports "EFI variables are not supported on this system" and
			 * quietly skips the UEFI boot entry -- leaving a restored disk the
			 * firmware will not boot. */
			sh += "for i in dev dev/pts proc run sys; do mount --rbind \"/$i\" \"%s$i\" 2>/dev/null || mount --bind \"/$i\" \"%s$i\"; done \n".printf(
				restore_target_path, restore_target_path);

			/* Without a shell in the target every chroot below fails one by
			 * one with a confusing error each. Say it once, plainly. */
			sh += "if [ ! -e \"%sbin/sh\" ] && [ ! -e \"%susr/bin/sh\" ]; then \n".printf(
				restore_target_path, restore_target_path);
			sh += "  echo '%s'\"chroot_bind:1\"\n".printf(RestoreScriptTask.STEP_FAILED_MARKER);
			sh += "  echo '" + escape_single_quote(_("The restored system has no shell; the boot loader steps cannot run.")) + "' \n";
			sh += "fi \n";
		}

		if (reinstall_grub2 && (grub_device != null) && (grub_device.length > 0)){

			sh += "sync \n";
			sh += "echo '' \n";
			sh += phase_marker("grub_install", _("Re-installing GRUB2 bootloader"));
			sh += "echo '" + escape_single_quote(_("Re-installing GRUB2 bootloader...")) + "' \n";

			/* Check the ESP is really mounted before calling grub-install.
			 *
			 * grub-install resolves --efi-directory to <target>/boot/efi and
			 * requires it to be a mount point on a FAT filesystem. When it is
			 * merely a directory -- which is what a restore with no ESP
			 * assigned produces -- it aborts with "cannot find EFI directory"
			 * and returns a bare 1, with no hint of which of its many failure
			 * modes was hit. Say it plainly instead. */
			if (snapshot_needs_esp() && !restore_current_system){

				string esp_path = restore_target_path + "boot/efi";

				sh += "if ! mountpoint -q '%s'; then \n".printf(escape_single_quote(esp_path));
				sh += "  echo '%s'\"grub_install:1\"\n".printf(RestoreScriptTask.STEP_FAILED_MARKER);
				sh += "  echo '" + escape_single_quote(_("No EFI System Partition is mounted at /boot/efi; the boot loader cannot be installed.")) + "' \n";
				sh += "else \n";
			}

			sh += "if ts_has grub-install; then \n";
			sh += "  ts_step grub_install %s grub-install --recheck --force %s \n".printf(chroot, grub_device);
			sh += "elif ts_has grub2-install; then \n";
			sh += "  ts_step grub_install %s grub2-install --recheck --force %s \n".printf(chroot, grub_device);
			sh += "else \n";
			sh += "  echo '%s'\"grub_install:127\"\n".printf(RestoreScriptTask.STEP_FAILED_MARKER);
			sh += "  echo '" + escape_single_quote(_("grub-install was not found in the restored system.")) + "' \n";
			sh += "fi \n";

			if (snapshot_needs_esp() && !restore_current_system){
				sh += "fi \n"; // closes the mountpoint test
			}
		}
		else{
			log_debug("skipping sh_grub: reinstall_grub2=%s, grub_device=%s".printf(
				reinstall_grub2.to_string(), (grub_device == null) ? "null" : grub_device));
		}

		// update initramfs --------------

		if (update_initramfs){

			sh += "echo '' \n";
			sh += phase_marker("initramfs", _("Rebuilding initramfs"));
			sh += "echo '" + escape_single_quote(_("Generating initramfs...")) + "' \n";

			/* dracut first, and explicitly generic.
			 *
			 * On Ubuntu 26.04 update-initramfs is only a shim over dracut and
			 * gives no way to ask for a non-hostonly image -- and a hostonly
			 * rebuild here would be doubly wrong, because dracut would read
			 * the bind-mounted /proc, /sys and /dev of the RECOVERY
			 * environment and bake those devices in instead of the target's.
			 * --no-hostonly produces an image that boots on whatever hardware
			 * the restore actually landed on, which is the whole point. */
			sh += "if ts_has dracut; then \n";
			sh += "  ts_step initramfs %s dracut --force --no-hostonly --regenerate-all \n".printf(chroot);
			sh += "elif ts_has update-initramfs; then \n";
			sh += "  ts_step initramfs %s update-initramfs -u -k all \n".printf(chroot);
			sh += "elif ts_has mkinitcpio; then \n";
			// the glob has to expand inside the target, not out here
			sh += "  ts_step initramfs %s sh -c 'mkinitcpio -p /etc/mkinitcpio.d/*.preset' \n".printf(chroot);
			sh += "else \n";
			sh += "  echo '%s'\"initramfs:127\"\n".printf(RestoreScriptTask.STEP_FAILED_MARKER);
			sh += "  echo '" + escape_single_quote(_("No initramfs tool was found in the restored system.")) + "' \n";
			sh += "fi \n";
		}

		// update grub menu --------------

		if (update_grub){

			sh += "echo '' \n";
			sh += phase_marker("grub_menu", _("Updating GRUB menu"));
			sh += "echo '" + escape_single_quote(_("Updating GRUB menu...")) + "' \n";

			/* Was "if (redhat) ... if (arch) ... else ...", where the else bound
			 * to the arch test -- so a redhat target ran grub2-mkconfig AND
			 * update-grub. */
			sh += "if ts_has update-grub; then \n";
			sh += "  ts_step grub_menu %s update-grub \n".printf(chroot);
			sh += "elif ts_has grub2-mkconfig; then \n";
			sh += "  ts_step grub_menu %s grub2-mkconfig -o /boot/grub2/grub.cfg \n".printf(chroot);
			sh += "elif ts_has grub-mkconfig; then \n";
			sh += "  ts_step grub_menu %s grub-mkconfig -o /boot/grub/grub.cfg \n".printf(chroot);
			sh += "else \n";
			sh += "  echo '%s'\"grub_menu:127\"\n".printf(RestoreScriptTask.STEP_FAILED_MARKER);
			sh += "  echo '" + escape_single_quote(_("No GRUB configuration tool was found in the restored system.")) + "' \n";
			sh += "fi \n";

			sh += "sync \n";
			sh += "echo '' \n";
		}

		// sync file systems
		sh += phase_marker("fs_sync", _("Syncing file systems"));
		sh += "echo '" + escape_single_quote(_("Syncing file systems...")) + "' \n";
		sh += "sync ; sleep 10s; \n";
		sh += "echo '' \n";

		if (!restore_current_system){
			// unmount chrooted system
			sh += phase_marker("cleanup", _("Cleaning up"));
			sh += "echo '" + escape_single_quote(_("Cleaning up...")) + "' \n";
			// -R to match the --rbind above; a leftover submount would keep the
			// target busy and make the unmount-then-fsck step refuse to run
			sh += "for i in dev/pts dev proc run sys; do umount -R \"%s$i\" 2>/dev/null || umount -f \"%s$i\"; done \n".printf(
				restore_target_path, restore_target_path);
			sh += "sync \n";
		}

		log_debug("GRUB2 install script:");
		log_debug(sh);

		// Perform any post-restore actions
		log_debug("Running post-restore tasks...");

		sh += phase_marker("hooks", _("Running post-restore scripts"));
		sh += "if [ -d \"/etc/timeshift/restore-hooks.d\" ]; then \n";
		sh += "  ts_step hooks run-parts --verbose /etc/timeshift/restore-hooks.d \n";
		sh += "fi \n";

		// reboot if required -----------------------------------

		if (restore_current_system){
			sh += "echo '' \n";
			sh += phase_marker("reboot", _("Restarting"));
			sh += "echo '" + escape_single_quote(_("Rebooting system...")) + "' \n";
			sh += "sleep 5s \n";
			sh += "reboot -f \n";
		}

		sh_finish = sh;

		publish_restore_phases();
	}

	private bool restore_current_console(string sh_sync, string sh_finish){

		log_debug("Main: restore_current_console()");
		
		string script = sh_sync + sh_finish;
		int ret_val = -1;
		
		if (cmd_verbose){
			//current/other system, console, verbose
			ret_val = exec_script_sync(script, null, null, false, false, false, true);
			log_msg("");
		}
		else{
			//current/other system, console, quiet
			string std_out, std_err;
			ret_val = exec_script_sync(script, out std_out, out std_err);
			log_to_file(std_out);
			log_to_file(std_err);
		}

		// exec_script_sync() cannot report the script's real status, so the
		// sentinel is what actually decides this.
		bool ok_script = (ret_val == 0) && !file_exists(restore_failed_flag());

		if (!ok_script){
			restore_fail(_("The snapshot could not be copied to the target."));
			restore_note(_("The target is incomplete and must not be booted. Re-run the restore."));
		}

		return ok_script;
	}

	/* The full-screen VTE terminal is kept for debugging:
	 * TIMESHIFT_RESTORE_TERMINAL=1 under --debug brings back the raw script
	 * exactly as it used to be. The GUI asks too, so it knows not to put its
	 * own progress window up underneath. */
	public bool restore_uses_terminal(){

		return LOG_DEBUG
			&& (GLib.Environment.get_variable("TIMESHIFT_RESTORE_TERMINAL") != null);
	}

	/* Restoring over the running system.
	 *
	 * The whole script - sync, bootloader, hooks, reboot - runs as one unit,
	 * because after rsync has overwritten / there is nothing left to make
	 * further decisions with. What changed is that its output now drives
	 * RestoreProgressWindow instead of scrolling past in a terminal.
	 *
	 * The task is assigned to App.task so the progress page reads this run's
	 * counters and this run's exit code, rather than the finished dry run's. */
	private bool restore_current_gui(string sh_sync, string sh_finish){

		log_debug("Main: restore_current_gui()");

		string script = sh_sync + sh_finish;

		if (restore_uses_terminal()){

			log_debug("Main: restore_current_gui(): using the terminal window");

			string temp_script = save_bash_script_temp(script);

			var dlg = new TerminalWindow.with_parent(parent_window);
			dlg.execute_script(temp_script, true);

			return true;
		}

		var script_task = new RestoreScriptTask();
		script_task.script_text = script;
		script_task.rsync_log_file = restore_log_file;
		script_task.prg_count_total = restore_progress_total();

		task = script_task;
		restore_script_task = script_task;

		script_task.execute();

		while (script_task.status == AppStatus.RUNNING){

			restore_phase = script_task.current_phase;

			sleep(200);
			gtk_do_events();
		}

		restore_script_task = null;

		/* One task ran both halves here, so both verdicts come from it. The
		 * transfer is read first: if it failed the script aborted before the
		 * finish steps, and there is no step failure to report. */
		collect_transfer_result(script_task);

		if (restore_outcome != RestoreOutcome.FAILED){
			collect_finish_result(script_task);
		}

		return (restore_outcome != RestoreOutcome.FAILED);
	}

	/* How many itemised lines the restore is expected to print. The dry run
	 * that precedes every rsync restore counted them exactly; the snapshot's
	 * own file count is the fallback for the paths that skip it. */
	private int64 restore_progress_total(){

		if (restore_line_count_estimate > 0){
			return restore_line_count_estimate;
		}

		if ((snapshot_to_restore != null) && (snapshot_to_restore.file_count > 0)){
			return snapshot_to_restore.file_count;
		}

		if (Main.first_snapshot_count > 0){
			return Main.first_snapshot_count;
		}

		return 500000;
	}

	private bool restore_other_console(string sh_sync, string sh_finish){

		log_debug("Main: restore_other_console()");
		
		// execute sh_sync --------------------
		
		string script = sh_sync;
		int ret_val = -1;
		
		if (cmd_verbose){
			ret_val = exec_script_sync(script, null, null, false, false, false, true);
			log_msg("");
		}
		else{
			string std_out, std_err;
			ret_val = exec_script_sync(script, out std_out, out std_err);
			log_to_file(std_out);
			log_to_file(std_err);
		}

		// update files -------------------
		
		fix_fstab_file(restore_target_path);
		fix_crypttab_file(restore_target_path);

		progress_text = _("Parsing log file...");
		log_msg(progress_text);
		var task = new RsyncTask();
		task.parse_log(restore_log_file);

		// execute sh_finish --------------------

		log_debug("executing sh_finish: ");
		log_debug(sh_finish);
		
		script = sh_finish;

		if (cmd_verbose){
			ret_val = exec_script_sync(script, null, null, false, false, false, true);
			log_msg("");
		}
		else{
			string std_out, std_err;
			ret_val = exec_script_sync(script, out std_out, out std_err);
			log_to_file(std_out);
			log_to_file(std_err);
		}

		// exec_script_sync() cannot report the script's real status, so the
		// sentinel is what actually decides this.
		bool ok_script = (ret_val == 0) && !file_exists(restore_failed_flag());

		if (!ok_script){
			restore_fail(_("The snapshot could not be copied to the target."));
			restore_note(_("The target is incomplete and must not be booted. Re-run the restore."));
		}

		return ok_script;
	}

	private bool restore_other_gui(string sh_sync, string sh_finish){

		log_debug("Main: restore_other_gui()");
		
		progress_text = _("Building file list...");

		/* sh_sync, not a second transfer built here.
		 *
		 * This function used to accept sh_sync and ignore it, constructing its
		 * own RsyncTask instead -- so the retry loop, the exit-code
		 * classification and the .timeshift-restore-failed sentinel that
		 * create_restore_scripts() builds were all dead code on the one path a
		 * recovery environment ever uses, and the sentinel check at the bottom
		 * of this function could never fire. The two transfers had drifted
		 * apart as well (--delete-before here, --delete-after there).
		 *
		 * RestoreScriptTask extends RsyncTask, so the counters, the progress
		 * bar, status_line and the "-changes" sidecar all keep working. */
		var sync_task = new RestoreScriptTask();
		sync_task.script_text = sh_sync;
		sync_task.rsync_log_file = restore_log_file;
		sync_task.prg_count_total = restore_progress_total();

		task = sync_task;
		restore_script_task = sync_task;

		restore_phase = "sync_files";

		sync_task.execute();

		while (sync_task.status == AppStatus.RUNNING){

			/* current_phase is "" until the script emits its first marker;
			 * overwriting the seeded value with that would blank the
			 * checklist for the first moments of every restore. */
			if (sync_task.current_phase.length > 0){
				restore_phase = sync_task.current_phase;
			}

			if (sync_task.status_line.length > 0){

				if (dry_run){
					progress_text = _("Comparing files with rsync...");
				}
				else{
					progress_text = _("Syncing files with rsync...");
				}
			}

			sleep(200);
			gtk_do_events();
		}

		restore_script_task = null;

		collect_transfer_result(sync_task);

		if (dry_run){
			return (sync_task.exit_code == 0); // no need to continue
		}

		/* The gate that was missing. A failed transfer used to fall straight
		 * through into the fstab rewrite, grub-install, update-initramfs and
		 * finally fsck -- all on a half-copied filesystem. */
		if (restore_outcome == RestoreOutcome.FAILED){

			log_error(_("Skipping the bootloader steps: the files were not restored"));
			restore_note(_("The bootloader steps were skipped."));
			return false;
		}

		// update files after sync --------------------

		restore_phase = "fix_fstab";

		fix_fstab_file(restore_target_path);
		fix_crypttab_file(restore_target_path);

		restore_phase = "parse_log";

		progress_text = _("Parsing log file...");
		log_msg(progress_text);
		var log_task = new RsyncTask();
		log_task.parse_log(restore_log_file);

		// execute sh_finish ------------

		if (reinstall_grub2 || update_initramfs || update_grub){
			progress_text = _("Updating bootloader configuration...");
		}

		log_debug("executing sh_finish: ");
		log_debug(sh_finish);

		/* Run through the same task as the current-system restore so the
		 * bootloader and hook steps reach the checklist and the output pane.
		 * exec_script_sync() used to print them to the app's own stdout,
		 * where a GUI user never saw them.
		 *
		 * App.task deliberately keeps pointing at the sync task: the counts
		 * on screen belong to the files that were restored. No log file
		 * either, or the inherited finish_task() would overwrite the sync's
		 * "-changes" sidecar with this script's empty one. */
		var script_task = new RestoreScriptTask();
		script_task.script_text = sh_finish;
		script_task.prg_count_total = 0; // must not disturb the progress bar

		restore_script_task = script_task;

		script_task.execute();

		while (script_task.status == AppStatus.RUNNING){

			restore_phase = script_task.current_phase;

			sleep(200);
			gtk_do_events();
		}

		restore_script_task = null;

		log_debug("script exit code: %d".printf(script_task.exit_code));

		collect_finish_result(script_task);

		return (restore_outcome != RestoreOutcome.FAILED);
	}

	private void fix_fstab_file(string target_path){

		log_debug("Main: fix_fstab_file()");
		
		string fstab_path = path_combine(target_path, "etc/fstab");

		if (!file_exists(fstab_path)){
			log_debug("File not found: %s".printf(fstab_path));
			return;
		}
		
		var fstab_list = FsTabEntry.read_file(fstab_path);

		log_debug("updating entries (1/2)...");
		
		foreach(var mnt in mount_list){

			// a folded or unassigned entry stays on the root filesystem
			if (mnt.device == null){ continue; }

			// find existing
			var entry = FsTabEntry.find_entry_by_mount_point(fstab_list, mnt.mount_point);

			// add if missing
			if (entry == null){
				entry = new FsTabEntry();
				entry.mount_point = mnt.mount_point;
				fstab_list.add(entry);
			}

			//update fstab entry
			entry.device_string = "UUID=%s".printf(mnt.device.uuid);
			entry.type = mnt.device.fstype;

			// fix mount options for non-btrfs device
			if (mnt.device.fstype != "btrfs"){
				// remove subvol option
				entry.remove_option("subvol=%s".printf(entry.subvolume_name()));
			}
		}

		/*
		 * Remove fstab entries for any system directories that
		 * the user has not explicitly mapped before restore/clone
		 * This ensures that the cloned/restored system does not mount
		 * any devices to system paths that the user has not explicitly specified
		 * */

		log_debug("updating entries(2/2)...");
		
		for(int i = fstab_list.size - 1; i >= 0; i--){
			var entry = fstab_list[i];
			
			if (!entry.is_for_system_directory()){ continue; }
			
			var mnt = MountEntry.find_entry_by_mount_point(mount_list, entry.mount_point);
			if (mnt == null){
				fstab_list.remove(entry);
			}
		}
		
		// write the updated file

		log_debug("writing updated file...");

		FsTabEntry.write_file(fstab_list, fstab_path, false);

		log_msg(_("Updated /etc/fstab on target device") + ": %s".printf(fstab_path));

		// create directories on disk for mount points in /etc/fstab

		foreach(var entry in fstab_list){
			if (entry.mount_point.length == 0){ continue; }
			if (!entry.mount_point.has_prefix("/")){ continue; }
			
			string mount_path = path_combine(
				target_path, entry.mount_point);
				
			if (entry.is_comment
				|| entry.is_empty_line
				|| (mount_path.length == 0)){
				
				continue;
			}

			if (!dir_exists(mount_path)){
				
				log_msg("Created mount point on target device: %s".printf(
					entry.mount_point));
					
				dir_create(mount_path);
			}
		}

		log_debug("Main: fix_fstab_file(): exit");
	}

	private void fix_crypttab_file(string target_path){

		log_debug("Main: fix_crypttab_file()");
		
		string crypttab_path = path_combine(target_path, "etc/crypttab");

		if (!file_exists(crypttab_path)){
			log_debug("File not found: %s".printf(crypttab_path));
			return;
		}

		var crypttab_list = CryptTabEntry.read_file(crypttab_path);
		
		// add option "nofail" to existing entries

		log_debug("checking for 'nofail' option...");
		
		foreach(var entry in crypttab_list){
			entry.append_option("nofail");
		}

		log_debug("updating entries...");

		// check and add entries for mapped devices which are encrypted
		
		foreach(var mnt in mount_list){
			if ((mnt.device != null) && (mnt.device.parent != null)
				&& ((mnt.device.is_on_encrypted_partition())
					|| ((mnt.device.parent.parent != null) &&
						(mnt.device.parent.is_on_encrypted_partition())))){

				// We could be either directly on LUKS or on LVM-on-LUKS,
				// so be sure to get the top-level LUKS UUID.
				var crypt_parent = (mnt.device.is_on_encrypted_partition()) ?
					mnt.device.parent.uuid : mnt.device.parent.parent.uuid;

				// find existing
				var entry = CryptTabEntry.find_entry_by_uuid(
					crypttab_list, crypt_parent);

				// add if missing
				if (entry == null){
					entry = new CryptTabEntry();
					crypttab_list.add(entry);
				}
				
				// set custom values
				entry.device_uuid = crypt_parent;
				entry.mapped_name = "luks-%s".printf(crypt_parent);
				entry.keyfile = "none";
				entry.options = "luks,nofail";
			}
		}

		log_debug("writing updated file...");

		CryptTabEntry.write_file(crypttab_list, crypttab_path, false);

		log_msg(_("Updated /etc/crypttab on target device") + ": %s".printf(crypttab_path));

		log_debug("Main: fix_crypttab_file(): exit");
	}

	/* Is this block device mounted anywhere right now?
	 *
	 * Read from /proc/mounts rather than from our own bookkeeping: the point is
	 * to catch a mount we did not make or did not manage to remove. */
	private bool device_is_mounted(string device_path){

		string mounts = file_read("/proc/mounts");

		foreach(string line in mounts.split("\n")){

			var parts = line.split(" ");

			if (parts.length < 2){ continue; }

			if (parts[0] == device_path){ return true; }
		}

		return false;
	}

	private void check_and_repair_filesystems(){
		
		if (!restore_current_system){
			string sh_fsck = "echo '" + escape_single_quote(_("Checking file systems for errors...")) + "' \n";

			int checked = 0;

			foreach(var mnt in mount_list){

				if (mnt.device == null) { continue; }

				/* Never on a mounted filesystem. "fsck -y" answers yes to
				 * e2fsck's "The filesystem is mounted. If you continue you
				 * WILL cause SEVERE damage" prompt, so a stale bind mount left
				 * under the target would turn this repair into the thing it is
				 * meant to prevent. */
				if (device_is_mounted(mnt.device.device)){
					log_error(_("Not checking %s: it is still mounted").printf(mnt.device.device));
					continue;
				}

				sh_fsck += "fsck -y %s \n".printf(mnt.device.device);
				checked++;
			}

			sh_fsck += "echo '' \n";

			if (checked > 0){
				exec_script_sync(sh_fsck, null, null, false, false, false, true);
			}
		}
	}

	public bool restore_execute_rsync(){
		
		log_debug("Main: restore_execute_rsync()");

		// set explicitly: the only path that used to clear it was an
		// exception handler that is no longer reachable
		thr_success = false;

		restore_outcome_reset();

		/* Before a single byte is written or deleted. An aliased mount turns
		 * rsync --delete into "erase the target", so this runs ahead of
		 * everything, including the dry run. */
		if (!verify_no_aliased_mounts()){
			thread_restore_running = false;
			return false;
		}

		{
			log_debug("source_path=%s".printf(restore_source_path));
			log_debug("target_path=%s".printf(restore_target_path));
			
			string sh_sync, sh_finish;
			create_restore_scripts(out sh_sync, out sh_finish);

			/* rsync answers 23 both for "a few files were skipped" and for
			 * "I could not open the exclude file" -- and 23 is the warning
			 * path, which continues to the finish steps. Checking the write
			 * here is what keeps those two apart. */
			if (!save_exclude_list_for_restore()){
				restore_fail(_("The list of files to exclude could not be written to %s.").printf(
					restore_exclude_file));
				restore_note(_("Nothing was changed on the target."));
				log_error(_("Failed to write the restore exclude list"));
				thread_restore_running = false;
				return false;
			}

			/* Same reasoning: a source that cannot be listed also yields 23,
			 * having deleted the target on the way. Ask first. */
			string probe_error;
			if (!restore_source_is_readable(out probe_error)){
				restore_fail(_("The snapshot could not be read from %s.").printf(restore_source_path));
				restore_note(probe_error);
				restore_note(_("Nothing was changed on the target."));
				log_error(probe_error);
				thread_restore_running = false;
				return false;
			}

			// rsync will not create the directory its --log-file lives in
			dir_create(file_parent(restore_log_file));

			// Stale from a previous failed attempt would fail this run before
			// it starts.
			file_delete(restore_failed_flag());
			file_delete(restore_log_file);
			file_delete(restore_log_file + "-changes");
			file_delete(restore_log_file + ".gz");
			
			if (restore_current_system){
				// Written where the readers look: create_snapshot_with_rsync()
				// and get_space_needed_for_rsync_snapshot() both read
				// <snapshots_path>/.sync-restore. Writing it inside the
				// snapshot meant the post-restore link-dest optimisation never
				// fired, and the marker accumulated in every restored snapshot.
				string control_file_path = path_combine(repo.snapshots_path, ".sync-restore");

				// written through the backend: for a remote repository this
				// path is not reachable with the local file API
				repo.backend.file_delete(control_file_path);
				repo.backend.file_write(control_file_path, snapshot_to_restore.path);
			}

			// run the scripts --------------------
		
			if (snapshot_to_restore != null){
				if (dry_run){
					log_msg(_("Comparing Files (Dry Run)..."));
				}
				else{
					log_msg(_("Restoring snapshot..."));
				}
			}
			else{
				log_msg(_("Cloning system..."));
			}

			progress_text = _("Syncing files with rsync...");
			log_msg(progress_text);

			bool ok = true;
			
			if (app_mode == ""){ // GUI
				if (!restore_current_system || dry_run){
					ok = restore_other_gui(sh_sync, sh_finish);
				}
				else{
					ok = restore_current_gui(sh_sync, sh_finish);
				}
			}
			else{
				if (restore_current_system){
					ok = restore_current_console(sh_sync, sh_finish);
				}
				else{
					ok = restore_other_console(sh_sync, sh_finish);
				}
			}

			if (!dry_run){

				check_snap_links_restored();

				/* The log first: everything below can fail, and this is the
				 * only record of what the transfer actually did. */
				save_restore_log_to_target();

				switch(restore_outcome){
				case RestoreOutcome.FAILED:
					log_error(_("Restore failed"));
					break;
				case RestoreOutcome.WARNINGS:
					log_msg(_("Restore completed with warnings"));
					break;
				default:
					log_msg(_("Restore completed"));
					break;
				}

				foreach(string line in restore_outcome_messages){
					log_msg("  " + line);
				}

				/* Was "thr_success = true" unconditionally, with ok assigned
				 * and never read -- which is why "timeshift --restore" exited
				 * 0 even when nothing had been restored. */
				thr_success = ok && (restore_outcome != RestoreOutcome.FAILED);

				log_msg(string.nfill(78, '-'));

				bool unmounted = unmount_target_device(false);

				/* fsck only when the restore worked AND the target is really
				 * unmounted. "fsck -y" on a mounted filesystem answers yes to
				 * "you WILL cause SEVERE damage", and this used to run on
				 * every restore including a failed one. */
				if (thr_success && unmounted){
					check_and_repair_filesystems();
				}
				else if (!unmounted){
					log_error(_("Skipping the file system check: the target is still mounted"));
				}
				else {
					log_msg(_("Skipping the file system check: the restore did not complete"));
				}
			}
			else {
				thr_success = ok;
			}
		}

		thread_restore_running = false;
		return thr_success;
	}
	
	public bool restore_execute_btrfs(){

		log_debug("Main: restore_execute_btrfs()");
		
		bool ok = create_pre_restore_snapshot_btrfs();

		log_msg(string.nfill(78, '-'));
		
		if (!ok){
			thread_restore_running = false;
			thr_success = false;
			return thr_success;
		}
		
		// restore snapshot subvolumes by creating new subvolume snapshots

		foreach(var subvol in snapshot_to_restore.subvolumes.values){

			if ((subvol.name == "@home") && !include_btrfs_home_for_restore){ continue; }
			
			subvol.restore();
		}

		log_msg(_("Restore completed"));
		thr_success = true;

		// Perform any post-restore actions
		log_debug("Running post-restore tasks...");

		string sh = "test -d \"/etc/timeshift/restore-hooks.d\" &&" +
		" export TS_SNAPSHOT_PATH=\"" + snapshot_to_restore.path + "\" &&" + 
		" run-parts --verbose /etc/timeshift/restore-hooks.d";

		exec_script_sync(sh, null, null, false, false, false, true);

		log_debug("Finished running post-restore tasks...");
		
		if (restore_current_system){
			log_msg(_("Snapshot will become active after system is rebooted."));
		}

		log_msg(string.nfill(78, '-'));

		thread_restore_running = false;
		return thr_success;
	}

	public bool create_pre_restore_snapshot_btrfs(){

		log_debug("Main: create_pre_restore_snapshot_btrfs()");
		
		string cmd, std_out, std_err;
		DateTime dt_created = new DateTime.now_local();
		string time_stamp = dt_created.format("%Y-%m-%d_%H-%M-%S");
		string snapshot_name = time_stamp;
		string snapshot_path = "";
		
		/* Note:
		 * The @ and @home subvolumes need to be backed-up only if they are in use by the system.
		 * If user restores a snapshot and then tries to restore another snapshot before the next reboot
		 * then the @ and @home subvolumes are the ones that were previously restored and need to be deleted.
		 * */

		bool create_pre_restore_backup = false;

		if (restore_current_system){
			
			// check for an existing pre-restore backup

			Snapshot snap_prev = null;
			bool found = false;
			foreach(var bak in repo.snapshots){
				if (bak.live){
					found = true;
					snap_prev = bak;
					log_msg(_("Found existing pre-restore snapshot") + ": %s".printf(bak.name));
					break;
				}
			}

			if (found){
				//delete system subvolumes
				if (sys_subvolumes.has_key("@") && snapshot_to_restore.subvolumes.has_key("@")){
					sys_subvolumes["@"].remove();
					log_msg(_("Deleted subvolume") + ": @");
				}
				if (include_btrfs_home_for_restore && sys_subvolumes.has_key("@home") && snapshot_to_restore.subvolumes.has_key("@home")){
					sys_subvolumes["@home"].remove();
					log_msg(_("Deleted subvolume") + ": @home");
				}

				//update description for pre-restore backup
				snap_prev.description = "Before restoring '%s'".printf(snapshot_to_restore.date_formatted);
				snap_prev.update_control_file();
			}
			else{
				create_pre_restore_backup = true;
			}
		}
		else{
			create_pre_restore_backup = true;
		}

		if (create_pre_restore_backup){

			log_msg(_("Creating pre-restore snapshot from system subvolumes..."));
			
			dir_create(snapshot_path);

			// move subvolumes ----------------
			
			bool no_subvolumes_found = true;

			var subvol_list = new Gee.ArrayList<Subvolume>();

			var subvol_names = new string[] { "@" };
			if (include_btrfs_home_for_restore){
				subvol_names = new string[] { "@","@home" };
			}
			
			foreach(string subvol_name in subvol_names){

				snapshot_path = path_combine(repo.mount_paths[subvol_name], "timeshift-btrfs/snapshots/%s".printf(snapshot_name));
				dir_create(snapshot_path, true);
			
				string src_path = path_combine(repo.mount_paths[subvol_name], subvol_name);
				if (!dir_exists(src_path)){
					log_error(_("Could not find system subvolume") + ": %s".printf(subvol_name));
					dir_delete(snapshot_path);
					continue;
				}
				
				no_subvolumes_found = false;

				string dst_path = path_combine(snapshot_path, subvol_name);
				cmd = "mv '%s' '%s'".printf(src_path, dst_path);
				log_debug(cmd);
				
				int status = exec_sync(cmd, out std_out, out std_err);
				
				if (status != 0){
					log_error (std_err);
					log_error(_("Failed to move system subvolume to snapshot directory") + ": %s".printf(subvol_name));
					return false;
				}
				else{
					var subvol_dev = (subvol_name == "@") ? repo.device : repo.device_home;
					subvol_list.add(new Subvolume(subvol_name, dst_path, subvol_dev.uuid, repo));
					
					log_msg(_("Moved system subvolume to snapshot directory") + ": %s".printf(subvol_name));
				}
			}

			if (no_subvolumes_found){
				//could not find system subvolumes for backing up(!)
				log_error(_("Could not find system subvolumes for creating pre-restore snapshot"));
			}
			else{
				// write control file -----------

				snapshot_path = path_combine(repo.mount_paths["@"], "timeshift-btrfs/snapshots/%s".printf(snapshot_name));
				
				var snap = Snapshot.write_control_file(
					snapshot_path, dt_created, repo.device.uuid,
					LinuxDistro.get_dist_info(path_combine(snapshot_path,"@")).full_name(),
					"ondemand", "", 0, true, false, repo);

				snap.description = "Before restoring '%s'".printf(snapshot_to_restore.date_formatted);
				snap.live = true;
				
				// write subvolume info
				foreach(var subvol in subvol_list){
					snap.subvolumes.set(subvol.name, subvol);
				}
				
				snap.update_control_file(); // save subvolume info

				log_msg(_("Created pre-restore snapshot") + ": %s".printf(snap.name));
				
				repo.load_snapshots();
			}
		}

		return true;
	}
	
	//app config

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




