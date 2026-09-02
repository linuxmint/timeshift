/*
 * SnapshotRepo.vala
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

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

public class SnapshotRepo : GLib.Object{
	
	public Device device = null;
	public Device device_home = null; // used for btrfs mode only
	public string mount_path = "";
	public Gee.HashMap<string,string> mount_paths = new Gee.HashMap<string,string>();
	public bool btrfs_mode = false;

	/* Performs the repository's file operations. A local repository uses the
	 * ordinary filesystem calls; a remote one runs them over SSH. Never null.
	 * Initialized here so that every constructor - including the implicit one
	 * used in the Main ctor - gets a usable backend. */
	public RepoBackend backend = new LocalRepoBackend();

	/* Initialised here, not only in the named constructors: Main uses the
	 * implicit `new SnapshotRepo()` (Main.vala:341), which left these null and
	 * made every first run log a GLib CRITICAL from `repo.snapshots.size`. */
	public Gee.ArrayList<Snapshot?> snapshots = new Gee.ArrayList<Snapshot>();
	public Gee.ArrayList<Snapshot?> invalid_snapshots = new Gee.ArrayList<Snapshot>();

	public string status_message = "";
	public string status_details = "";
	public SnapshotLocationStatus status_code;
    public bool last_snapshot_failed_space = false;

	// private
	private Gtk.Window? parent_window = null;
	private bool thr_success = false;
	private bool thr_running = false;
	private string thr_args1 = "";

	public SnapshotRepo.from_path(string path, Gtk.Window? parent_win, bool _btrfs_mode){

		log_debug("SnapshotRepo: from_path()");
		
		this.mount_path = path;
		this.parent_window = parent_win;
		this.btrfs_mode = _btrfs_mode;
		
		snapshots = new Gee.ArrayList<Snapshot>();
		invalid_snapshots = new Gee.ArrayList<Snapshot>();
		mount_paths = new Gee.HashMap<string,string>();
		
		//log_debug("Selected snapshot repo path: %s".printf(path));
		
		var list = Device.get_disk_space_using_df(path);
		
		if (list.size > 0){
			
			device = list[0];
			
			log_debug(_("Device") + ": %s".printf(device.device));
			log_debug(_("Free space") + ": %s".printf(format_file_size(device.free_bytes)));
		}
		
		check_status();
	}

	public SnapshotRepo.from_device(Device dev, Gtk.Window? parent_win, bool btrfs_repo){

		log_debug("SnapshotRepo: from_device(): %s".printf(btrfs_repo ? "BTRFS" : "RSYNC"));
		
		this.device = dev;
		//this.use_snapshot_path_custom = false;
		this.parent_window = parent_win;
		this.btrfs_mode = btrfs_repo;
		
		snapshots = new Gee.ArrayList<Snapshot>();
		invalid_snapshots = new Gee.ArrayList<Snapshot>();
		mount_paths = new Gee.HashMap<string,string>();
		
		init_from_device();
	}

	public SnapshotRepo.from_uuid(string uuid, Gtk.Window? parent_win, bool btrfs_repo){

		log_debug("SnapshotRepo: from_uuid(): %s".printf(btrfs_repo ? "BTRFS" : "RSYNC"));
		log_debug("uuid=%s".printf(uuid));
		
		device = Device.get_device_by_uuid(uuid);
		if (device == null){
			device = new Device();
			device.uuid = uuid;
		}
			
		//this.use_snapshot_path_custom = false;
		this.parent_window = parent_win;
		this.btrfs_mode = btrfs_repo;
		
		snapshots = new Gee.ArrayList<Snapshot>();
		invalid_snapshots = new Gee.ArrayList<Snapshot>();
		mount_paths = new Gee.HashMap<string,string>();

		init_from_device();

		log_debug("SnapshotRepo: from_uuid(): exit");
	}

	/* A repository on a remote host, reached over SSH. Nothing is mounted:
	 * rsync talks to the remote directly and every other operation runs as a
	 * command over the SSH connection. */
	public SnapshotRepo.from_ssh(string url, string key_file, int port,
		bool fake_super, Gtk.Window? parent_win){

		log_debug("SnapshotRepo: from_ssh(): %s".printf(url));

		this.parent_window = parent_win;
		this.btrfs_mode = false; // btrfs snapshots require a local filesystem

		snapshots = new Gee.ArrayList<Snapshot>();
		invalid_snapshots = new Gee.ArrayList<Snapshot>();
		mount_paths = new Gee.HashMap<string,string>();

		string user, host, path;
		int parsed_port;

		if (!SshRepoBackend.parse_url(url, out user, out host, out parsed_port, out path)){
			status_code = SnapshotLocationStatus.NOT_AVAILABLE;
			status_message = _("Invalid remote location");
			status_details = _("Use one of these forms") + ":\n    user@host:/path\n    ssh://user@host:port/path";
			return;
		}

		// an explicit --ssh-port overrides a port given in the URL
		if (port > 0){ parsed_port = port; }

		this.mount_path = path;

		this.backend = new SshRepoBackend(user, host, parsed_port,
			key_file, fake_super, App.mount_point_app);

		// During key setup we must not connect yet: ssh_options() uses
		// StrictHostKeyChecking=accept-new, so probing here would silently
		// record the host key before the user has confirmed its fingerprint,
		// defeating the point of asking.
		if (App.app_mode == "setup-ssh-key"){
			return;
		}

		check_status();

		if (available()){
			load_snapshots();
		}
	}

	public SnapshotRepo.from_null(){

		log_debug("SnapshotRepo: from_null()");
		log_debug("device not set");
		
		snapshots = new Gee.ArrayList<Snapshot>();
		invalid_snapshots = new Gee.ArrayList<Snapshot>();
		mount_paths = new Gee.HashMap<string,string>();

		log_debug("SnapshotRepo: from_null(): exit");
	}

	private void init_from_device(){

		log_debug("SnapshotRepo: init_from_device()");
		
		if ((device != null) && (device.uuid.length > 0) && (Device.get_device_by_uuid(device.uuid) != null)){
			
			log_debug("");
			unlock_and_mount_devices();

			if ((device != null) && (device.device.length > 0)){
				
				log_debug(_("Selected snapshot device") + ": %s".printf(device.device));
				log_debug(_("Free space") + ": %s".printf(format_file_size(device.free_bytes)));
			}
		}

		if ((device != null) && (device.device.length > 0)){
			
			check_status();
		}

		log_debug("SnapshotRepo: init_from_device(): exit");
	}

	// properties
	
	public string timeshift_path {
		owned get{
			if (btrfs_mode){
				return path_combine(mount_path, "timeshift-btrfs");
			}
			else{
				return path_combine(mount_path, "timeshift");
			}
		}
	}
	
	public string snapshots_path {
		owned get{
			return path_combine(timeshift_path, "snapshots");
		}
	}

	/* Free space on the repository. A local repository reads it off the
	 * Device; a remote one caches what the last df over SSH reported. */
	private uint64 remote_free_bytes = 0;

	public uint64 free_bytes {
		get {
			if (backend.is_remote){ return remote_free_bytes; }
			return (device == null) ? 0 : device.free_bytes;
		}
	}
 
	// load ---------------------------------------

	public bool unlock_and_mount_devices(){

		log_debug("SnapshotRepo: unlock_and_mount_devices()");

		if (device == null){
			log_debug("device=null");
		}
		else{
			log_debug("device=%s".printf(device.device));
		}

		mount_path = unlock_and_mount_device(device, App.mount_point_app + "/backup");
		
		if (mount_path.length == 0){
			return false;
		}

		// rsync
		mount_paths["@"] = "";
		mount_paths["@home"] = "";
			
		if (btrfs_mode){
			
			mount_paths["@"] = mount_path;
			mount_paths["@home"] = mount_path; //default
			device_home = device; //default
			
			// mount @home if on different disk -------
		
			var repo_subvolumes = Subvolume.detect_subvolumes_for_system_by_path(path_combine(mount_path,"@"), this, parent_window);
			
			if (repo_subvolumes.has_key("@home")){
				
				var subvol = repo_subvolumes["@home"];
				
				if (subvol.device_uuid != device.uuid){
					
					// @home is on a separate device
					device_home = subvol.get_device();
					
					mount_paths["@home"] = unlock_and_mount_device(device_home, App.mount_point_app + "/backup-home");
					
					if (mount_paths["@home"].length == 0){
						return false;
					}
				}
			}
		}

		load_snapshots();

		log_debug("SnapshotRepo: unlock_and_mount_device(): exit");
				
		return true;
	}

	public string unlock_and_mount_device(Device device_to_mount, string path_to_mount){

		// mounts the device and returns mount path
		
		log_debug("SnapshotRepo: unlock_and_mount_device()");

		Device dev = device_to_mount;
		
		if (dev == null){
			log_debug("device=null");
		}
		else{
			log_debug("device=%s".printf(dev.device));
		}
		
		// unlock encrypted device
		if (dev.is_encrypted_partition()){

			dev = unlock_encrypted_device(dev);
			device = dev; // set repo device to unlocked child disk
			
			if (dev == null){
				log_debug("device is null");
				log_debug("SnapshotRepo: unlock_and_mount_device(): exit");
				return "";
			}
		}

		// mount
		var mount_options = "";
		if (btrfs_mode){
			mount_options = "subvolid=0";
		}
		bool ok = Device.mount(dev.uuid, path_to_mount, mount_options); // TODO: check if already mounted
		
		if (ok){
			return path_to_mount;
		}
		else{
			return "";
		}
	}

	public Device? unlock_encrypted_device(Device luks_device){

		log_debug("SnapshotRepo: unlock_encrypted_device()");
		
		if (luks_device == null){
			log_debug("luks_device=null");
			return null;
		}
		else{
			log_debug("luks_device=%s".printf(luks_device.device));
		}

		string msg_out, msg_err;
		var luks_unlocked = Device.luks_unlock(
			luks_device, "", "", parent_window, out msg_out, out msg_err);

		return luks_unlocked;
	}
	
	/* The snapshot list, from the daemon.
	 *
	 * This replaces four things the local walk does, not one. The daemon has
	 * already read every control file, already decided which snapshots are
	 * valid, already computed the sizes -- a du(1) walk of the whole repository
	 * in rsync mode, a qgroup query in btrfs mode -- and already settled the
	 * `live` flag. Over SSH the local path costs four round trips per snapshot
	 * plus a remote du; this costs one request.
	 *
	 * It also makes listing a READ. The local path re-derives `live` against
	 * the system's boot time and calls update_control_file() when it disagrees,
	 * so merely listing a repository could write to it -- on a remote one, over
	 * the network, while something else might be mid-backup.
	 *
	 * False means "no daemon answered", not "no snapshots": the caller falls
	 * through to the local walk. An EMPTY repository is a successful answer,
	 * which is why the result is not inferred from the list being empty.
	 */
	private bool load_snapshots_from_daemon(){

		var api = DaemonApi.get_shared();
		if (api == null){ return false; }

		var info = api.system_info();
		if (info == null){ return false; }

		var listed = api.snapshots_list();
		if (api.last_error.length > 0){
			/* A transport failure is NOT an empty repository. Replacing the
			 * list here would present a full repository as empty, and
			 * auto_remove() acting on that would be catastrophic -- the same
			 * reason the remote prefetch below refuses to continue on a failed
			 * read. */
			log_error(_("Could not read the snapshot list from the Timeshift service"));
			return false;
		}

		snapshots.clear();
		invalid_snapshots.clear();

		foreach (var src in listed){
			var bak = new Snapshot.from_wire(src, btrfs_mode, this);
			if (bak.valid){ snapshots.add(bak); }
			else { invalid_snapshots.add(bak); }
		}

		snapshots.sort((a,b) => {
			return ((Snapshot) a).date.compare(((Snapshot) b).date);
		});

		log_debug("SnapshotRepo: %d snapshots from the daemon".printf(snapshots.size));
		return true;
	}

	public bool load_snapshots(){

		log_debug("SnapshotRepo: load_snapshots()");

		/* The daemon is the only source now.
		 *
		 * The local walk that used to stand behind this read every snapshot's
		 * info.json itself -- four ssh round trips each for a remote
		 * repository, which is why it grew a prefetch -- and it was a second
		 * implementation of a listing the daemon already serves. Two listers
		 * that can disagree about what a repository contains is worse than
		 * one that can be absent, especially since auto_remove() acts on the
		 * answer.
		 */
		return load_snapshots_from_daemon();

	}

	// get tagged snapshots ----------------------------------
	
	public Gee.ArrayList<Snapshot?> get_snapshots_by_tag(string tag = ""){
		
		var list = new Gee.ArrayList<Snapshot?>();

		foreach(Snapshot bak in snapshots){
			if (bak.valid && (tag.length == 0) || bak.has_tag(tag)){
				list.add(bak);
			}
		}
		list.sort((a,b) => {
			Snapshot t1 = (Snapshot) a;
			Snapshot t2 = (Snapshot) b;
			return (t1.date.compare(t2.date));
		});

		return list;
	}

	public Snapshot? get_latest_snapshot(string tag, string sys_uuid){
		
		var list = get_snapshots_by_tag(tag);
		
		for(int i = list.size - 1; i >= 0; i--){
			var bak = list[i];
			if (bak.sys_uuid == sys_uuid){
				return bak;
			}
		}

		return null;
	}

	public Snapshot? get_oldest_snapshot(string tag, string sys_uuid){
		
		var list = get_snapshots_by_tag(tag);

		for(int i = 0; i < list.size; i++){
			var bak = list[i];
			if (bak.sys_uuid == sys_uuid){
				return bak;
			}
		}
		
		return null;
	}

	// status check ---------------------------

	/* The repository's status, from the daemon.
	 *
	 * Worth routing for the same reason as the listing, only more so: for a
	 * REMOTE location the local path is four SSH round trips -- does the
	 * directory exist, is it writable, does it support hardlinks, can the
	 * account preserve ownership -- plus a df and a directory walk. All of it
	 * is cached behind caps_checked precisely because it is expensive, and the
	 * cache is then something else to invalidate correctly.
	 *
	 * The status CODES are deliberately the same integers on both sides
	 * (engines.StatusCode in engine.go and SnapshotLocationStatus below), so
	 * the answer maps across directly. That shared numbering is a contract: it
	 * is what lets either core describe a location the same way, and renumbering
	 * one side would silently turn "read-only" into "no space".
	 *
	 * False means no daemon answered, and the caller probes locally.
	 */
	private bool check_status_from_daemon(){

		var api = DaemonApi.get_shared();
		if (api == null){ return false; }

		var st = api.repo_status();
		if (st == null){ return false; }

		/* A daemon too old to report free space cannot serve this call.
		 *
		 * Only for a REMOTE location, where the daemon is the sole source of
		 * the number -- a local one reads it from its Device, which the local
		 * scan filled. Taking the status anyway would leave a healthy 30 TB
		 * repository showing no space at all, and confidently, because the call
		 * itself succeeded. Falling through to the local probe is slower and
		 * right. */
		if (backend.is_remote && !st.has_free_bytes){
			log_debug("SnapshotRepo: the daemon does not report free space; probing locally");
			return false;
		}

		status_code = (SnapshotLocationStatus) st.code;
		status_message = st.message;
		status_details = st.details;

		/* free_bytes is computed: a local repository reads it from its Device,
		 * which the local scan already filled, and only the REMOTE case has a
		 * field to set. So this fills the half the daemon is the sole source
		 * for, and leaves the local half alone rather than writing a second
		 * answer over a good one. */
		if (backend.is_remote && (st.free_bytes > 0)){
			remote_free_bytes = (uint64) st.free_bytes;
		}

		/* last_snapshot_failed_space is this process's memory of a backup that
		 * ran out of room, and the daemon knows nothing about it. Clearing it
		 * here matches what the local path does on its way out, so the warning
		 * survives exactly one status check either way. */
		last_snapshot_failed_space = false;

		log_debug("SnapshotRepo: status %d from the daemon: %s".printf(
			st.code, st.message));
		return true;
	}

	public void check_status(){

		log_debug("SnapshotRepo: check_status()");

		/* The daemon decides whether this location can hold snapshots.
		 *
		 * The probes that used to live here -- writability, hard-link support,
		 * and whether the remote account can preserve ownership -- are the
		 * same ones the daemon runs, and running them twice against a remote
		 * repository doubled the round trips to reach the same verdict. */
		check_status_from_daemon();

	}

	/* The capability probes moved to the daemon with check_status().
	 *
	 * This survives as a no-op because two pages call it before re-testing a
	 * location, and their reason still holds -- it just no longer has a cache
	 * on this side to clear. The daemon re-probes on every repo.status, so
	 * "test again" already means what those callers want it to mean. */
	public void invalidate_capability_cache(){
	}

	public bool available(){

		log_debug("SnapshotRepo: available()");
		
		//log_debug("checking selected device");

		if (backend.is_remote){

			string message;
			if (!backend.test_connection(out message)){
				status_message = _("Remote location not available");
				status_details = message;
				status_code = SnapshotLocationStatus.NOT_AVAILABLE;
				log_debug("is_available: false (remote unreachable)");
				return false;
			}

			log_debug("is_available: ok (remote)");
			return true;
		}

		if (device == null){
			if (App.backup_uuid == null || App.backup_uuid.length == 0){
				log_debug("device is null");
				status_message = _("Snapshot device not selected");
				status_details = _("Select the snapshot device");
				status_code = SnapshotLocationStatus.NOT_SELECTED;
				log_debug("is_available: false");
				return false;
			}
			else{
				status_message = _("Snapshot device not available");
				status_details = _("Device not found") + ": UUID='%s'".printf(App.backup_uuid);
				status_code = SnapshotLocationStatus.NOT_AVAILABLE;
				log_debug("is_available: false");
				return false;
			}
		}
		else{
			if (btrfs_mode){
				bool ok = has_btrfs_system();
				if (ok){
					log_debug("is_available: ok");
				}
				return ok;
			}
			else{
				log_debug("is_available: ok");
				return true;
			}
		}
	}

	public bool has_btrfs_system(){
		
		log_debug("SnapshotRepo: has_btrfs_system()");

		var root_path = path_combine(mount_paths["@"],"@");
		log_debug("root_path=%s".printf(root_path));
		log_debug("btrfs_mode=%s".printf(btrfs_mode.to_string()));
		if (btrfs_mode){
			if (!dir_exists(root_path)){
				status_message = _("Selected snapshot device is not a system disk");
				status_details = _("Select BTRFS system disk with root subvolume (@)");
				status_code = SnapshotLocationStatus.NO_BTRFS_SYSTEM;
				log_debug(status_message);
				return false;
			}
		}

		return true;
	}
	
	public bool has_snapshots(){
		
		log_debug("SnapshotRepo: has_snapshots()");
		
		//load_snapshots();
		return (snapshots.size > 0);
	}

	public bool has_space(uint64 needed = 0) {
		log_debug("SnapshotRepo: has_space() - %llu required (%s)".printf(needed, format_file_size(needed)));
		
		if (backend.is_remote){

			uint64 size_bytes, used_bytes, avail_bytes;

			if (!backend.query_space(mount_path, out size_bytes, out used_bytes, out avail_bytes)){
				status_message = _("Failed to query disk space on remote location");
				status_details = backend.last_error;
				status_code = SnapshotLocationStatus.NOT_AVAILABLE;
				return false;
			}

			remote_free_bytes = avail_bytes;
		}
		else if ((device != null) && (device.device.length > 0)){
			device.query_disk_space();
		}
		else{
			log_debug("device is NULL");
			return false;
		}
		
		if (snapshots.size > 0){
			// has snapshots, check minimum space

            if (free_bytes < (needed > 0 ? needed : Main.MIN_FREE_SPACE)) {
				status_message = _("Not enough disk space");
				status_message += " (< %s)".printf(format_file_size((needed > 0 ? needed : Main.MIN_FREE_SPACE), false, "", true, 0));
					
				status_details = _("Select another device or free up some space");
				
				status_code = SnapshotLocationStatus.HAS_SNAPSHOTS_NO_SPACE;
                last_snapshot_failed_space = true;
				return false;
			}
			else{
				//ok
				status_message = _("OK");
				
				status_details = _("%d snapshots, %s free").printf(
					snapshots.size, format_file_size(free_bytes));
					
                last_snapshot_failed_space = false;
				status_code = SnapshotLocationStatus.HAS_SNAPSHOTS_HAS_SPACE;
				return true;
			}
		}
		else {

			// no snapshots, check estimated space
			log_debug("no snapshots");
			
			var required_space = Main.first_snapshot_size;

			if (free_bytes < required_space){
				status_message = _("Not enough disk space");
				status_message += " (< %s)".printf(format_file_size(required_space));
				
				status_details = _("Select another device or free up some space");
				
				status_code = SnapshotLocationStatus.NO_SNAPSHOTS_NO_SPACE;
				return false;
			}
			else{
				status_message = _("No snapshots on this device");
				
				status_details = _("First snapshot requires:");
				status_details += " %s".printf(format_file_size(required_space));
				
				status_code = SnapshotLocationStatus.NO_SNAPSHOTS_HAS_SPACE;
				return true;
			}
		}
	}

	public void print_status(){
		
		check_status();
		
		//log_msg("");
		
		if (backend.is_remote){
			log_msg("%-6s : %s".printf(_("Remote"), backend.display_name));
			log_msg("%-6s : %s".printf(_("Path"), mount_path));
			log_msg("%-6s : %s".printf(_("Type"), backend.type_id));
			log_msg("%-6s : %s".printf(_("Status"), status_message));
			log_msg(status_details);
		}
		else if (device == null){
			log_msg("%-6s : %s".printf(_("Device"), _("Not Selected")));
		}
		else{
			log_msg("%-6s : %s".printf(_("Device"), device.device_name_with_parent));
			log_msg("%-6s : %s".printf("UUID", device.uuid));
			log_msg("%-6s : %s".printf(_("Path"), mount_path));
			log_msg("%-6s : %s".printf(_("Mode"), btrfs_mode ? "BTRFS" : "RSYNC"));
			log_msg("%-6s : %s".printf(_("Status"), status_message));
			log_msg(status_details);
		}

		log_msg("");
	}
	
	// actions -------------------------------------

	
	public bool remove_sync_dir(){
		string sync_dir = mount_path + "/timeshift/snapshots/.sync";
		
		//delete .sync
		if (backend.dir_exists(sync_dir)){
			if (!delete_directory(sync_dir)){
				return false;
			}
		}
		
		return true;
	}

	public bool remove_timeshift_dir(){

		// delete /timeshift
		if (backend.dir_exists(timeshift_path)){
			if (!delete_directory(timeshift_path)){
				return false;
			}
		}
		
		return true;
	}

	// private -------------------------------------------
	
	private bool delete_directory(string dir_path){
		thr_args1 = dir_path;

		try {
			thr_running = true;
			thr_success = false;
			new Thread<void>.try ("delete-directory", () => {delete_directory_thread();});
		} catch (Error e) {
			thr_running = false;
			thr_success = false;
			log_error (e.message);
		}

		while (thr_running){
			gtk_do_events ();
			Thread.usleep((ulong) GLib.TimeSpan.MILLISECOND * 100);
		}

		thr_args1 = null;

		return thr_success;
	}

	private void delete_directory_thread(){
		thr_success = backend.remove_dir_recursive(thr_args1);

		if (thr_success) {
			log_msg(_("Removed") + ": '%s'".printf(thr_args1));
		} else{
			log_error(_("Failed to remove") + ": '%s'".printf(thr_args1));
		}

		thr_running = false;
	}

	// symlinks ----------------------------------------
	
	public void create_symlinks(){
		cleanup_symlink_dir("boot");
		cleanup_symlink_dir("hourly");
		cleanup_symlink_dir("daily");
		cleanup_symlink_dir("weekly");
		cleanup_symlink_dir("monthly");
		cleanup_symlink_dir("ondemand");


		foreach(Snapshot bak in snapshots){
			foreach(string tag in bak.tags) {
				string linkTarget = "%s-%s/%s".printf(snapshots_path, tag, bak.name);
				string linkValue = "../snapshots/" + bak.name;
				if (!backend.create_symlink(linkValue, linkTarget)) {
					log_error(_("Failed to create symlinks") + ": %s".printf(linkTarget));
				}
			}
		}

		log_debug (_("Symlinks updated"));
	}

	public void cleanup_symlink_dir(string tag){

		string path = "%s-%s".printf(snapshots_path, tag);

		if (!backend.remove_dir_recursive(path)) {
			log_error(_("Failed to delete symlinks") + ": '%s'".printf(path));
		}

		backend.dir_create(path);
	}

}

public enum SnapshotLocationStatus{
	/*
	-1 - device un-available, path does not exist
	 0 - first snapshot taken, disk space sufficient
	 1 - first snapshot taken, disk space not sufficient
	 2 - first snapshot not taken, disk space not sufficient
	 3 - first snapshot not taken, disk space sufficient
	 4 - path is readonly
     5 - hardlinks not supported
     6 - btrfs device does not have @ subvolume
	*/
	NOT_SELECTED = -2,
	NOT_AVAILABLE = -1,
	HAS_SNAPSHOTS_HAS_SPACE = 0,
	HAS_SNAPSHOTS_NO_SPACE = 1,
	NO_SNAPSHOTS_NO_SPACE = 2,
	NO_SNAPSHOTS_HAS_SPACE = 3,
	READ_ONLY_FS = 4,
	HARDLINKS_NOT_SUPPORTED = 5,
	NO_BTRFS_SYSTEM = 6
}
