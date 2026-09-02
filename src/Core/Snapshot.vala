/*
 * Snapshot.vala
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
using Json;

public class Snapshot : GLib.Object{
	
	public string path = "";
	public string name = "";
	public DateTime date;
	public string sys_uuid = "";
	public string sys_distro = "";
	public string app_version = "";
	public string description = "";
	public int64 file_count = 0;
	public Gee.ArrayList<string> tags;
	public Gee.ArrayList<string> exclude_list;
	public Gee.HashMap<string,Subvolume> subvolumes;
	public Gee.ArrayList<FsTabEntry> fstab_list;
	public Gee.ArrayList<CryptTabEntry> cryttab_list;
	public bool valid = true;
	public bool live = false;
	public bool marked_for_deletion = false;
	public LinuxDistro distro;
	public SnapshotRepo repo;
	
	//btrfs
	public bool btrfs_mode = false;
	public Gee.HashMap<string,string> paths; // for btrfs snapshots only
	public string mount_path_root = "";
	public string mount_path_home = "";

	//rsync size cache; -1 means "not yet computed". btrfs mode uses
	//subvolumes[].total_bytes/unshared_bytes instead - see size_bytes below.
	public int64 rsync_size_bytes = -1;
	public int64 rsync_size_unshared_bytes = -1;

	/* Sizes as the daemon reported them; -1 when they did not come from there.
	 *
	 * A separate pair rather than reusing the rsync cache above, because those
	 * two are a du(1) result THIS process computed and in btrfs mode are not
	 * consulted at all -- the property sums the Subvolume objects instead. A
	 * snapshot built from the wire has neither a du cache nor Subvolume
	 * objects, so it needs a slot the size properties will actually read. */
	public int64 daemon_size_bytes = -1;
	public int64 daemon_size_unshared_bytes = -1;

	/* Built from the daemon rather than from control files on disk.
	 *
	 * Worth knowing because such a snapshot has read no info.json, no
	 * exclude.list and no fstab: the lists below are empty because nothing has
	 * been read yet, NOT because the snapshot has none. Anything that needs
	 * them -- a restore, mainly -- must read them first. */
	public bool from_daemon = false;
	
	public DeleteFileTask delete_file_task;

	/* control files fetched up-front by the repository, keyed by file name.
	 * Null means read them individually through the backend. */
	private Gee.HashMap<string,string>? prefetched = null;

	public Snapshot(string dir_path, bool btrfs_snapshot, SnapshotRepo _repo,
		Gee.HashMap<string,string>? _prefetched = null){

		{
			path = dir_path;
			name = GLib.Path.get_basename(dir_path);
			description = "";
			btrfs_mode = btrfs_snapshot;
			repo = _repo;
			prefetched = _prefetched;
			
			date = new DateTime.from_unix_utc(0);
			tags = new Gee.ArrayList<string>();
			exclude_list = new Gee.ArrayList<string>();
			fstab_list = new Gee.ArrayList<FsTabEntry>();
			delete_file_task = new DeleteFileTask();
			subvolumes = new Gee.HashMap<string,Subvolume>();
			paths = new Gee.HashMap<string,string>();
			
			read_control_file();
			read_exclude_list();
			read_fstab_file();
			read_crypttab_file();
		}
	}

	/* A snapshot as the daemon described it. Reads NOTHING.
	 *
	 * The ordinary constructor above opens info.json, exclude.list, fstab and
	 * crypttab -- four files per snapshot, and over SSH four round trips per
	 * snapshot, which is what the repository's prefetch exists to avoid. The
	 * daemon has already read all of that, and has already computed the sizes:
	 * a du(1) walk of the whole repository for rsync mode, a qgroup query for
	 * btrfs. Doing any of it again here would be asking a second time for an
	 * answer we were just given.
	 *
	 * `live` is taken as sent and NOT re-derived. The old path recomputed it
	 * against the system's boot time and WROTE BACK a corrected control file
	 * while merely listing -- so listing a repository could modify it. The
	 * daemon owns that decision now, and a list stays a read.
	 */
	public Snapshot.from_wire(DaemonSnapshot src, bool btrfs_snapshot,
		SnapshotRepo _repo){

		path = src.path;
		name = src.name;
		description = src.description;
		btrfs_mode = btrfs_snapshot;
		repo = _repo;
		from_daemon = true;

		sys_uuid = src.sys_uuid;
		sys_distro = src.sys_distro;
		app_version = src.app_version;
		file_count = src.file_count;

		valid = src.valid;
		live = src.live;
		marked_for_deletion = src.marked_for_deletion;

		daemon_size_bytes = src.size_bytes;
		daemon_size_unshared_bytes = src.unshared_bytes;

		/* The directory name IS the timestamp, so a snapshot the daemon could
		 * not date is still placed correctly rather than falling to the epoch --
		 * which would sort it before everything and, in the old core, made
		 * retention read it as older than every other snapshot. */
		date = (src.created != null) ? src.created : date_from_name(name);

		tags = new Gee.ArrayList<string>();
		foreach (var tag in src.tags){ tags.add(tag); }

		exclude_list = new Gee.ArrayList<string>();
		fstab_list = new Gee.ArrayList<FsTabEntry>();
		delete_file_task = new DeleteFileTask();
		subvolumes = new Gee.HashMap<string,Subvolume>();
		paths = new Gee.HashMap<string,string>();
	}

	/* The date encoded in a snapshot's directory name: YYYY-MM-DD_HH-MM-SS.
	 *
	 * The fallback when a control file cannot be dated, and it matters more
	 * than it looks. read_control_file() below leaves `date` at the UNIX EPOCH
	 * when `created` will not parse, while still marking the snapshot valid --
	 * so retention reads it as older than everything else and deletes it. The
	 * name is the timestamp, so there is almost always a real answer available.
	 *
	 * Null-safe by construction: an unparseable name gives the epoch, which is
	 * what the caller would have had anyway.
	 */
	public static DateTime date_from_name(string dir_name){

		int year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0;

		if (dir_name.scanf("%4d-%2d-%2d_%2d-%2d-%2d",
			out year, out month, out day, out hour, out minute, out second) == 6){

			// Guard the ranges: scanf is happy with 2026-99-99, and DateTime
			// would return null for it, which the callers do not expect.
			if ((month >= 1) && (month <= 12) && (day >= 1) && (day <= 31)
				&& (hour < 24) && (minute < 60) && (second < 60)){

				var dt = new DateTime.local(year, month, day, hour, minute, second);
				if (dt != null){ return dt; }
			}
		}

		return new DateTime.from_unix_utc(0);
	}

	// properties
	
	public string date_formatted{
		owned get{
			return date.format(App.date_format);//.format("%Y-%m-%d %H:%M:%S");
		}
	}

	/* Total logical content size: btrfs sums the referenced size of its
	 * subvolumes; rsync uses the cached du result (-1 if not computed yet). */
	public int64 size_bytes{
		get{
			if (daemon_size_bytes >= 0){ return daemon_size_bytes; }
			if (btrfs_mode){
				int64 total = 0;
				foreach(var s in subvolumes.values){ total += s.total_bytes; }
				return total;
			}
			return rsync_size_bytes;
		}
	}

	/* Size unique to this snapshot: btrfs sums the exclusive size of its
	 * subvolumes; rsync sums files with no other hardlink (-1 if not computed). */
	public int64 size_unshared_bytes{
		get{
			if (daemon_size_unshared_bytes >= 0){ return daemon_size_unshared_bytes; }
			if (btrfs_mode){
				int64 total = 0;
				foreach(var s in subvolumes.values){ total += s.unshared_bytes; }
				return total;
			}
			return rsync_size_unshared_bytes;
		}
	}

	public string size_formatted{
		owned get{
			return (size_bytes >= 0) ? format_file_size(size_bytes) : "";
		}
	}

	public string size_unshared_formatted{
		owned get{
			return (size_unshared_bytes >= 0) ? format_file_size(size_unshared_bytes) : "";
		}
	}

	public string rsync_log_file{
		owned get {
			return path_combine(path, "rsync-log");
		}	
	}

	public string rsync_changes_log_file{
		owned get {
			return path_combine(path, "rsync-log-changes");
		}	
	}

	public string rsync_restore_log_file{
		owned get {
			return path_combine(path, "rsync-log-restore");
		}	
	}

	public string rsync_restore_changes_log_file{
		owned get {
			return path_combine(path, "rsync-log-restore-changes");
		}	
	}
	
	public string exclude_file_for_backup {
		owned get {
			return path_combine(path, "exclude.list");
		}	
	}

	public string exclude_file_for_restore {
		owned get {
			return path_combine(path, "exclude-restore.list");
		}	
	}
	
	// manage tags
	
	public string taglist{
		owned get{
			string str = "";
			foreach(string tag in tags){
				str += " " + tag;
			}
			return str.strip();
		}
		set{
			tags.clear();
			foreach(string tag in value.split(" ")){
				if (!tags.contains(tag.strip())){
					tags.add(tag.strip());
				}
			}
		}
	}

	public string taglist_short{
		owned get{
			string str = "";
			foreach(string tag in tags){
				str += " " + tag.replace("ondemand","O").replace("boot","B").replace("hourly","H").replace("daily","D").replace("weekly","W").replace("monthly","M");
			}
			return str.strip();
		}
	}

	public void add_tag(string tag){
		
		if (!tags.contains(tag.strip())){
			tags.add(tag.strip());
			update_control_file();
		}
	}

	public void remove_tag(string tag){
		
		if (tags.contains(tag.strip())){
			tags.remove(tag.strip());
			update_control_file();
		}
	}

	public bool has_tag(string tag){
		
		return tags.contains(tag.strip());
	}

	// control files

	/* Reads a file from inside the snapshot directory, through the repository
	 * backend so that it works for a remote repository too. */
	private string? read_repo_file(string file_path){

		// key used by the batched pre-fetch: path relative to the snapshot dir
		string short_name = file_path;
		if (short_name.has_prefix(path)){
			short_name = short_name[path.length : short_name.length];
		}
		while (short_name.has_prefix("/")){
			short_name = short_name[1 : short_name.length];
		}

		if (prefetched != null){
			// the pre-fetch is authoritative: a key that is absent means the
			// file does not exist, so there is nothing to go back for
			return prefetched.has_key(short_name) ? prefetched[short_name] : null;
		}

		if (repo == null){
			return file_exists(file_path) ? file_read(file_path) : null;
		}

		return repo.backend.file_read(file_path);
	}

	public void read_control_file(){
		
		//log_debug("read_control_file()");
		
		string ctl_file = path + "/info.json";

		string? ctl_text = read_repo_file(ctl_file);

		if (ctl_text != null) {
			
			var parser = new Json.Parser();
			
			try{
				parser.load_from_data(ctl_text);
			} catch (Error e) {
				log_error (e.message);
			}
			
			var node = parser.get_root();
			var config = node.get_object();

			if ((node == null)||(config == null)){
				valid = false;
				return;
			}

			string val = json_get_string(config,"created","");
			if (val.length > 0) {
				DateTime date_utc = new DateTime.from_unix_utc(int64.parse(val));
				date = date_utc.to_local();
			}

			sys_uuid = json_get_string(config,"sys-uuid","");
			sys_distro = json_get_string(config,"sys-distro","");
			taglist = json_get_string(config,"tags","");
			description = json_get_string(config,"comments","");
			app_version = json_get_string(config,"app-version","");
			file_count = (int64) json_get_uint64(config,"file_count",file_count);
			live = json_get_bool(config,"live",false);
			rsync_size_bytes = int64.parse(json_get_string(config,"size_bytes","-1"));
			rsync_size_unshared_bytes = int64.parse(json_get_string(config,"size_unshared_bytes","-1"));
			string type = config.get_string_member_with_default("type", "rsync");

			string extension = (type == "btrfs") ? "@" : "localhost";
			distro = LinuxDistro.get_dist_info(path_combine(path, extension));

			//log_debug("repo.mount_path: %s".printf(repo.mount_path));

			if (config.has_member("subvolumes")){

				var subvols = (Json.Object) config.get_object_member("subvolumes");

				foreach(string subvol_name in subvols.get_members()){
					
					if ((subvol_name != "@")&&(subvol_name != "@home")){ continue; }
					
					paths[subvol_name] = path.replace(repo.mount_path, repo.mount_paths[subvol_name]);
					
					var subvol_path = path_combine(paths[subvol_name], subvol_name);
					
					if (!dir_exists(subvol_path)){ continue; }

					//log_debug("subvol_path: %s".printf(subvol_path));
					
					var subvolume = new Subvolume(subvol_name, subvol_path, "", repo); //subvolumes.get(subvol_name);
					subvolumes.set(subvol_name, subvolume);
					
					int index = -1;
					
					foreach(Json.Node jnode in subvols.get_array_member(subvol_name).get_elements()) {
						
						string item = jnode.get_string();
						switch (++index){
							case 0:
								subvolume.name = item;
								break;
							case 1:
								subvolume.id = long.parse(item);
								break;
							case 2:
								subvolume.total_bytes = int64.parse(item);
								break;
							case 3:
								subvolume.unshared_bytes = int64.parse(item);
								break;
							case 4:
								subvolume.device_uuid = item.strip();
								break;
						}
					}
				}
			}
			
			string delete_trigger_file = path + "/delete";
			if ((repo == null) ? file_exists(delete_trigger_file)
			                   : repo.backend.file_exists(delete_trigger_file)){
				marked_for_deletion = true;
			}
		}
		else{
			valid = false;
		}
		
		//log_debug("read_control_file(): exit");
	}

	public void read_exclude_list(){
		
		string list_file = path + "/exclude.list";

		exclude_list.clear();

		string? list_text = read_repo_file(list_file);
		
		if (list_text != null) {
			
			foreach(string path in list_text.split("\n")){
				
				path = path.strip();
				
				if (!exclude_list.contains(path) && path.length > 0){
					exclude_list.add(path);
				}
			}
		}
		else{
			if (!btrfs_mode){
				valid = false;
			}
		}
	}

	public void read_fstab_file(){
		
		string fstab_path = path_combine(path, "/localhost/etc/fstab");
		
		if (btrfs_mode){
			fstab_path = path_combine(path, "/@/etc/fstab");
		}
		
		fstab_list = FsTabEntry.parse_text(read_repo_file(fstab_path));
	}

	public void read_crypttab_file(){
		
		string crypttab_path = path_combine(path, "/localhost/etc/crypttab");
		
		if (btrfs_mode){
			crypttab_path = path_combine(path, "/@/etc/crypttab");
		}
		
		cryttab_list = CryptTabEntry.parse_text(read_repo_file(crypttab_path));
	}

	public void update_control_file(){
		/* Updates tag and comments */

		{
			string ctl_file = path + "/info.json";

			string? ctl_text = read_repo_file(ctl_file);

			if (ctl_text != null) {

				var parser = new Json.Parser();
				try{
					parser.load_from_data(ctl_text);
				} catch (Error e) {
					log_error (e.message);
				}
				var node = parser.get_root();
				var config = node.get_object();

				config.set_string_member("tags", taglist);
				config.set_string_member("comments", description);
				config.set_string_member("live", live.to_string());

				if (!btrfs_mode){
					config.set_string_member("size_bytes", rsync_size_bytes.to_string());
					config.set_string_member("size_unshared_bytes", rsync_size_unshared_bytes.to_string());
				}

				if (btrfs_mode){
					var subvols = new Json.Object();
					config.set_object_member("subvolumes",subvols);
					foreach(var subvol in subvolumes.values){
						Json.Array arr = new Json.Array();
						arr.add_string_element(subvol.name);
						arr.add_string_element(subvol.id.to_string());
						arr.add_string_element(subvol.total_bytes.to_string());
						arr.add_string_element(subvol.unshared_bytes.to_string());
						arr.add_string_element(subvol.device_uuid);
						subvols.set_array_member(subvol.name,arr);
					}
				}
				
				var json = new Json.Generator();
				json.pretty = true;
				json.indent = 2;
				node.set_object(config);
				json.set_root(node);

				size_t len;
				string data = json.to_data(out len);

				if (repo != null){
					repo.backend.file_write(ctl_file, data);
				}
				else {
					file_write(ctl_file, data);
				}
			}
		}
	}

	public void remove_control_file(){
		
		string ctl_file = path + "/info.json";

		if (repo != null){
			repo.backend.file_delete(ctl_file);
		}
		else {
			file_delete(ctl_file);
		}
	}
	
	public static Snapshot write_control_file(
		string snapshot_path, DateTime dt_created, string root_uuid, string distro_full_name, 
		string tag, string comments, int64 item_count, bool is_btrfs, bool is_live, SnapshotRepo repo, bool silent = false){
			
		var ctl_path = snapshot_path + "/info.json";
		var config = new Json.Object();

		config.set_string_member("created", dt_created.to_utc().to_unix().to_string());
		config.set_string_member("sys-uuid", root_uuid);
		config.set_string_member("sys-distro", distro_full_name);
		config.set_string_member("app-version", AppVersion);
		config.set_string_member("file_count", item_count.to_string());
		config.set_string_member("tags", tag);
		config.set_string_member("comments", comments);
		config.set_string_member("live", is_live.to_string());
		config.set_string_member("type", (is_btrfs ? "btrfs" : "rsync"));

		var json = new Json.Generator();
		json.pretty = true;
		json.indent = 2;
		var node = new Json.Node(NodeType.OBJECT);
		node.set_object(config);
		json.set_root(node);

		size_t len;
		string data = json.to_data(out len);

		repo.backend.file_write(ctl_path, data);

		if (!silent){
			log_msg(_("Created control file") + ": %s".printf(ctl_path));
		}

	    return (new Snapshot(snapshot_path, is_btrfs, repo));
	}

	// check
	
	public bool has_subvolumes(){
		foreach(FsTabEntry en in fstab_list){
			if (en.options.contains("subvol=@")){
				return true;
			}
		}
		return false;
	}

	public Gee.ArrayList<Subvolume> subvolumes_sorted {
		owned get {
			var list = new Gee.ArrayList<Subvolume>();
			foreach(var subvol in subvolumes.values){
				list.add(subvol);
			}
			list.sort((a,b)=>{
				return strcmp(a.name, b.name);
			});
			return list;
		}
	}
	
	// actions

	
	
	/* Flips the mark - this is the menu action. The delete path must use
	 * set_marked_for_deletion(true) instead: it marks the same snapshot more
	 * than once, and a toggle would clear the trigger file it just wrote,
	 * leaving a half-deleted snapshot that nothing ever comes back to. */
	public void mark_for_deletion(){
		set_marked_for_deletion(!marked_for_deletion);
	}

	public void set_marked_for_deletion(bool marked){

		string delete_trigger_file = path + "/delete";

		if (repo == null){
			if (marked){
				if (!file_exists(delete_trigger_file)){
					file_write(delete_trigger_file, "");
				}
			}
			else if (file_exists(delete_trigger_file)){
				file_delete(delete_trigger_file);
			}
			marked_for_deletion = marked;
			return;
		}

		if (marked){
			if (!repo.backend.file_exists(delete_trigger_file)){
				repo.backend.file_write(delete_trigger_file, "");
			}
		}
		else if (repo.backend.file_exists(delete_trigger_file)){
			repo.backend.file_delete(delete_trigger_file);
		}

		marked_for_deletion = marked;
	}

	// size (rsync only; btrfs size comes from live qgroup queries, see Main.query_subvolume_quota)

	/* Runs the (expensive) du/find walk for an rsync snapshot and caches the
	 * result in info.json. No-op if already cached, btrfs, or repo-less. */
	public void compute_rsync_size(){

		if (btrfs_mode || (repo == null) || (rsync_size_bytes >= 0)){ return; }

		int64 total, unique;
		if (repo.backend.query_dir_size(path, out total, out unique)){
			rsync_size_bytes = total;
			rsync_size_unshared_bytes = unique;
			update_control_file();
		}
	}

	public void parse_log_file(){
		/* Parses and archives rsync-log file, creates rsync-log-changes */
		var task = new RsyncTask();
		task.parse_log(rsync_log_file);
	}
}
