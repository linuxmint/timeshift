/*
 * RepoBackend.vala
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
using Gee;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.ProcessHelper;
using TeeJee.Misc;

/* Abstracts the file operations that a snapshot repository needs, so that a
 * repository can live either on a locally mounted filesystem or on a remote
 * host reached over SSH.
 *
 * Only the operations Timeshift performs on the *repository* belong here.
 * Operations on the system being backed up are always local. */

public abstract class RepoBackend : GLib.Object {

	public abstract bool is_remote { get; }

	// identity shown to the user and written to the config file
	public abstract string display_name { owned get; }

	public abstract bool dir_exists(string path);

	public abstract bool file_exists(string path);

	public abstract bool dir_create(string path);

	public abstract string? file_read(string path);

	public abstract bool file_write(string path, string contents);

	public abstract bool file_delete(string path);

	public abstract int64 file_line_count(string path);

	public abstract Gee.ArrayList<string> list_subdirs(string path);

	public abstract bool remove_dir_recursive(string path);

	public abstract bool create_symlink(string target, string link_path);

	public abstract bool rename(string src_path, string dst_path);

	/* Returns false if the space could not be determined. */
	public abstract bool query_space(string path,
		out uint64 size_bytes, out uint64 used_bytes, out uint64 available_bytes);

	/* Returns false if the size could not be determined. total_bytes is the
	 * full logical content size of the directory (as 'du -sb' reports it);
	 * unique_bytes is the subset of that which is not hardlinked anywhere
	 * else (nlink == 1) - i.e. what deleting just this directory would free. */
	public abstract bool query_dir_size(string path,
		out int64 total_bytes, out int64 unique_bytes);

	/* Copies a file from the local filesystem into the repository, and back.
	 * For a local repository these are plain copies. */
	public abstract bool upload_file(string local_path, string repo_path);

	public abstract bool download_file(string repo_path, string local_path);

	/* Prefix to put in front of a repository path when handing it to rsync.
	 * Empty for a local repository, "user@host:" for a remote one. */
	public virtual string rsync_prefix(){
		return "";
	}

	/* Value for rsync's -e option. Empty for a local repository. */
	public virtual string rsync_rsh(){
		return "";
	}

	/* Value for rsync's --rsync-path option. Empty unless --fake-super is needed. */
	public virtual string rsync_remote_path(){
		return "";
	}

	/* A location a file manager can open for the given repository path.
	 * Local: the path itself. Remote: an sftp:// URI. */
	public virtual string browse_uri(string path){
		return path;
	}

	/* Returns true when the repository can be written to. */
	public abstract bool probe_writable(string path);

	/* Returns true when the repository filesystem supports hardlinks.
	 * Without hardlinks every snapshot becomes a full copy. */
	public abstract bool probe_hardlinks(string path);

	/* Returns true when files written to the repository will keep their
	 * ownership. False means the backup would be silently useless for a
	 * system restore unless --fake-super is in play. */
	public abstract bool probe_preserves_ownership();

	/* Human readable reason for the last failure, if any. */
	public string last_error = "";

	/* Set by list_subdirs(): true when the listing genuinely completed, false
	 * when it could not be obtained. An empty list means different things in
	 * those two cases and callers must not conflate them. */
	public bool last_listing_ok = true;

	/* Runs a shell script and returns its real exit status.
	 *
	 * exec_script_sync() cannot be used directly for this: the script wrapper
	 * appends "exitCode=$?; echo ${exitCode} > status", so the script always
	 * ends with a successful echo and reports 0 no matter what the command
	 * did. Ending the script with an explicit exit stops the wrapper's lines
	 * from running and lets the status through. */
	protected static int run_script_checked(string script,
		out string? std_out, out string? std_err){

		return exec_script_sync("%s\nexit $?\n".printf(script),
			out std_out, out std_err, true);
	}

	public virtual bool test_connection(out string message){
		message = "";
		return true;
	}

	public virtual void cleanup(){
	}

	/* Shared df parser. Reads the numbers from the first data line of df -B1. */
	public static bool parse_df_output(string? std_out,
		out uint64 size_bytes, out uint64 used_bytes, out uint64 available_bytes){

		size_bytes = 0;
		used_bytes = 0;
		available_bytes = 0;

		if (std_out == null){ return false; }

		foreach(string line in std_out.split("\n")){

			if (line.strip().length == 0){ continue; }
			if (line.has_prefix("Filesystem")){ continue; }

			string[] parts = Regex.split_simple("""[ \t]+""", line.strip());

			// filesystem, size, used, available, use%, mount point
			if (parts.length < 5){ continue; }

			size_bytes = uint64.parse(parts[1]);
			used_bytes = uint64.parse(parts[2]);
			available_bytes = uint64.parse(parts[3]);
			return true;
		}

		return false;
	}
}

/* ------------------------------------------------------------------------ */

public class LocalRepoBackend : RepoBackend {

	public override bool is_remote {
		get { return false; }
	}

	public override string display_name {
		owned get { return _("Local"); }
	}

	public override bool dir_exists(string path){
		return TeeJee.FileSystem.dir_exists(path);
	}

	public override bool file_exists(string path){
		return TeeJee.FileSystem.file_exists(path);
	}

	public override bool dir_create(string path){
		return TeeJee.FileSystem.dir_create(path);
	}

	public override string? file_read(string path){
		if (!TeeJee.FileSystem.file_exists(path)){ return null; }
		return TeeJee.FileSystem.file_read(path);
	}

	public override bool file_write(string path, string contents){
		return TeeJee.FileSystem.file_write(path, contents);
	}

	public override bool file_delete(string path){
		return TeeJee.FileSystem.file_delete(path);
	}

	public override int64 file_line_count(string path){
		int64? count = TeeJee.FileSystem.file_line_count(path);
		return (count == null) ? 0 : count;
	}

	public override Gee.ArrayList<string> list_subdirs(string path){

		var list = new Gee.ArrayList<string>();

		last_listing_ok = false;

		if (!TeeJee.FileSystem.dir_exists(path)){ return list; }

		try{
			var dir = File.new_for_path(path);
			var iter = dir.enumerate_children("%s,%s".printf(
				FileAttribute.STANDARD_NAME, FileAttribute.STANDARD_TYPE), 0);

			FileInfo info;
			while ((info = iter.next_file()) != null) {
				if (info.get_file_type() == FileType.DIRECTORY){
					list.add(info.get_name());
				}
			}
			last_listing_ok = true;
		}
		catch(Error e){
			// a partial list must not look like a complete one
			log_error(e.message);
		}

		return list;
	}

	public override bool remove_dir_recursive(string path){
		return TeeJee.FileSystem.dir_delete_recursive(path);
	}

	public override bool create_symlink(string target, string link_path){
		try{
			var f = File.new_for_path(link_path);
			f.make_symbolic_link(target);
			return true;
		}
		catch(Error e){
			log_error(e.message);
			last_error = e.message;
			return false;
		}
	}

	public override bool rename(string src_path, string dst_path){
		TeeJee.FileSystem.file_move(src_path, dst_path);
		return TeeJee.FileSystem.file_exists(dst_path) || TeeJee.FileSystem.dir_exists(dst_path);
	}

	public override bool query_space(string path,
		out uint64 size_bytes, out uint64 used_bytes, out uint64 available_bytes){

		size_bytes = 0;
		used_bytes = 0;
		available_bytes = 0;

		string std_out, std_err;
		int ret_val = run_script_checked("df -B1 '%s'".printf(escape_single_quote(path)),
			out std_out, out std_err);

		if (ret_val != 0){ return false; }

		return RepoBackend.parse_df_output(std_out,
			out size_bytes, out used_bytes, out available_bytes);
	}

	public override bool query_dir_size(string path,
		out int64 total_bytes, out int64 unique_bytes){

		total_bytes = 0;
		unique_bytes = 0;

		string std_out, std_err;

		int ret_val = run_script_checked("du -sb '%s'".printf(escape_single_quote(path)),
			out std_out, out std_err);

		if ((ret_val != 0) || (std_out == null)){ return false; }

		string[] parts = Regex.split_simple("""[ \t]+""", std_out.strip());
		if (parts.length < 1){ return false; }

		total_bytes = int64.parse(parts[0]);

		string find_cmd = "find '%s' -type f -links 1 -printf '%%s\\n' | awk '{s+=$1} END{print s+0}'".printf(
			escape_single_quote(path));

		ret_val = run_script_checked(find_cmd, out std_out, out std_err);

		if ((ret_val != 0) || (std_out == null)){ return false; }

		unique_bytes = int64.parse(std_out.strip());

		return true;
	}

	public override bool upload_file(string local_path, string repo_path){
		return TeeJee.FileSystem.file_copy(local_path, repo_path);
	}

	public override bool download_file(string repo_path, string local_path){
		return TeeJee.FileSystem.file_copy(repo_path, local_path);
	}

	public override bool probe_writable(string path){

		string probe = path_combine(path, ".timeshift-write-probe");
		if (!TeeJee.FileSystem.file_write(probe, "probe")){ return false; }
		TeeJee.FileSystem.file_delete(probe);
		return true;
	}

	public override bool probe_hardlinks(string path){

		string probe = path_combine(path, ".timeshift-link-probe");
		string probe_link = probe + "-2";

		TeeJee.FileSystem.file_delete(probe);
		TeeJee.FileSystem.file_delete(probe_link);

		if (!TeeJee.FileSystem.file_write(probe, "probe")){ return false; }

		string std_out, std_err;
		run_script_checked("ln '%s' '%s'".printf(
			escape_single_quote(probe), escape_single_quote(probe_link)),
			out std_out, out std_err);

		bool linked = false;

		int ret_val = run_script_checked("stat -c %%h '%s'".printf(escape_single_quote(probe)),
			out std_out, out std_err);

		if ((ret_val == 0) && (std_out != null)){
			linked = (int.parse(std_out.strip()) > 1);
		}

		TeeJee.FileSystem.file_delete(probe);
		TeeJee.FileSystem.file_delete(probe_link);

		return linked;
	}

	public override bool probe_preserves_ownership(){
		// a local repository is written by this process, which is already root
		return true;
	}
}

/* ------------------------------------------------------------------------ */

/* A snapshot repository on a remote host, reached over SSH.
 *
 * rsync talks to the remote directly (its --link-dest is resolved by the
 * receiving rsync, so hardlinked incrementals stay cheap). Everything that is
 * not a bulk transfer runs as a shell command over a multiplexed SSH
 * connection.
 *
 * Note that rsync's --log-file and --exclude-from are opened by the *client*,
 * so those files must live locally even when the repository is remote. */

public class SshRepoBackend : RepoBackend {

	public string user = "";
	public string host = "";
	public int port = 22;
	public string key_file = "";
	public bool fake_super = false;

	private string control_path = "";
	private bool master_started = false;

	public SshRepoBackend(string _user, string _host, int _port,
		string _key_file, bool _fake_super, string control_dir){

		user = _user;
		host = _host;
		port = (_port > 0) ? _port : 22;
		key_file = _key_file;
		fake_super = _fake_super;

		// The control socket path is capped at 108 bytes by sockaddr_un.
		// /run/timeshift/<pid> is short enough; anything longer silently
		// disables multiplexing, which costs a full handshake per operation.
		if ((control_dir.length > 0) && (control_dir.length < 60)){

			// ssh fails every operation if the directory is missing, so make
			// sure it exists rather than relying on the caller
			if (!TeeJee.FileSystem.dir_exists(control_dir)){
				TeeJee.FileSystem.dir_create(control_dir);
			}

			if (TeeJee.FileSystem.dir_exists(control_dir)){
				control_path = "%s/ssh-%%C".printf(control_dir);
			}
		}
	}

	public override bool is_remote {
		get { return true; }
	}

	public override string display_name {
		owned get { return host_spec(); }
	}

	public string host_spec(){
		return (user.length > 0) ? "%s@%s".printf(user, host) : host;
	}

	/* Parses "user@host:/path" or "ssh://user@host:port/path". */
	public static bool parse_url(string url, out string user, out string host,
		out int port, out string path){

		user = "";
		host = "";
		port = 22;
		path = "";

		string rest = url.strip();

		if (rest.has_prefix("ssh://")){

			rest = rest["ssh://".length : rest.length];

			int slash = rest.index_of("/");
			if (slash < 0){ return false; }

			string authority = rest[0 : slash];
			path = rest[slash : rest.length];

			int at = authority.last_index_of("@");
			if (at >= 0){
				user = authority[0 : at];
				authority = authority[at + 1 : authority.length];
			}

			int colon = authority.last_index_of(":");
			if (colon >= 0){
				port = int.parse(authority[colon + 1 : authority.length]);
				authority = authority[0 : colon];
			}

			host = authority;
		}
		else {
			// user@host:/path
			int colon = rest.index_of(":");
			if (colon < 0){ return false; }

			string authority = rest[0 : colon];
			path = rest[colon + 1 : rest.length];

			int at = authority.last_index_of("@");
			if (at >= 0){
				user = authority[0 : at];
				authority = authority[at + 1 : authority.length];
			}

			host = authority;
		}

		if ((host.length == 0) || (path.length == 0)){ return false; }
		if (!path.has_prefix("/")){ return false; }

		// The host and user are passed to ssh as arguments. Single-quoting
		// stops the *shell* interpreting them, but not ssh: a value beginning
		// with "-" is parsed as an OPTION, so a URL like
		// ssh://-oProxyCommand=.../path would run an arbitrary command as
		// root. Verified behaviour, not theoretical. Accept only what a
		// hostname or username can legitimately contain.
		if (!is_safe_host_component(host)){ return false; }
		if ((user.length > 0) && !is_safe_host_component(user)){ return false; }

		return true;
	}

	/* Rejects anything that could be mistaken for an ssh option, and anything
	 * outside the characters a hostname or username may contain. IPv6 literals
	 * are rejected rather than mis-parsed: the bracket form confuses the
	 * host:port split above, and silently connecting to the wrong host is
	 * worse than refusing. */
	private static bool is_safe_host_component(string val){

		if (val.length == 0){ return false; }
		if (val.has_prefix("-")){ return false; }

		try {
			var re = new Regex("^[A-Za-z0-9._-]+$");
			return re.match(val);
		}
		catch (Error e){
			log_error(e.message);
			return false;
		}
	}

	/* Directory holding the key Timeshift manages, plus the known_hosts file
	 * of remotes the user has explicitly confirmed. Kept beside timeshift.json
	 * rather than in root's personal ~/.ssh so it is obviously app-owned.
	 * Matches the hard-coded config path in Main. */
	public static string key_dir(){
		return "/etc/timeshift/ssh";
	}

	public static string default_key_file(){
		return path_combine(key_dir(), "id_ed25519");
	}

	public static string known_hosts_file(){
		return path_combine(key_dir(), "known_hosts");
	}

	private string ssh_options(bool stdin_used = false){

		// Verify against the hosts the user confirmed during setup, and keep
		// root's personal known_hosts out of it. accept-new remains the
		// fallback for remotes configured by hand that never ran setup.
		string opts = "-o BatchMode=yes -o StrictHostKeyChecking=accept-new";

		// Without ConnectTimeout a firewalled host blocks for the kernel's SYN
		// retry budget (~130s), and without ServerAlive* a link that dies
		// mid-operation never returns at all. These run on the GTK main
		// thread, so either one is a hard UI freeze.
		opts += " -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3";

		// -n: never let ssh consume Timeshift's stdin (it would eat console
		//     input in --scripted runs). Omitted when the caller pipes data
		//     in - upload_file feeds the file through ssh's stdin, and -n
		//     there would silently write an empty remote file.
		// IdentitiesOnly: with keys in an agent, ssh may offer those first and
		//     hit MaxAuthTries before ever trying -i, so operations would fail
		//     while verify_key_auth (which already sets this) succeeded
		// -F /dev/null: root's ssh_config must not be able to rewrite the host,
		//     the ControlPath, or inject a ProxyCommand
		if (!stdin_used){ opts += " -n"; }
		opts += " -o IdentitiesOnly=yes -F /dev/null";

		opts += " -o UserKnownHostsFile='%s'".printf(escape_single_quote(known_hosts_file()));

		if (port != 22){
			opts += " -p %d".printf(port);
		}

		if (key_file.length > 0){
			opts += " -i '%s'".printf(escape_single_quote(key_file));
		}

		if (control_path.length > 0){
			opts += " -o ControlMaster=auto -o ControlPath='%s' -o ControlPersist=60".printf(
				escape_single_quote(control_path));
		}

		return opts;
	}

	/* Builds the sshfs command for mounting a repository path read-only,
	 * using Timeshift's own key.
	 *
	 * The ssh settings deliberately mirror ssh_options() rather than being
	 * hand-rolled: this used to be a separate, much weaker option list that
	 * dropped -F /dev/null, IdentitiesOnly, BatchMode and the timeouts, which
	 * meant root's ssh_config could rewrite Host or inject a ProxyCommand for
	 * this one code path.
	 *
	 * Note sshfs splits -o on commas, so anything that could contain one gets
	 * its own -o rather than being joined into a list.
	 *
	 * Returns "" when no key is configured - mounting with IdentityFile=''
	 * would just produce a confusing auth failure.
	 * as_uid/as_gid own the mounted tree so the desktop user can read it. */
	public string sshfs_command(string repo_path, string mount_point, int as_uid, int as_gid){

		if (key_file.length == 0){
			last_error = _("No SSH key is configured for this location");
			return "";
		}

		string cmd = "sshfs";

		// read-only: browsing must never be able to alter a snapshot
		cmd += " -o ro";

		// allow_other is what lets the desktop user's file manager read a
		// mount made by root. It needs user_allow_other in /etc/fuse.conf only
		// for NON-root mounts - see fuse.conf's own comment - and Timeshift is
		// always root, so no change to that file is required.
		cmd += " -o allow_other,default_permissions";
		cmd += " -o uid=%d,gid=%d".printf(as_uid, as_gid);

		// same discipline as ssh_options()
		cmd += " -o BatchMode=yes";
		cmd += " -o StrictHostKeyChecking=accept-new";
		cmd += " -o ConnectTimeout=10";
		cmd += " -o ServerAliveInterval=15";
		cmd += " -o ServerAliveCountMax=3";
		cmd += " -o IdentitiesOnly=yes";
		cmd += " -o 'ssh_command=ssh -F /dev/null'";
		cmd += " -o IdentityFile='%s'".printf(escape_single_quote(key_file));
		cmd += " -o UserKnownHostsFile='%s'".printf(escape_single_quote(known_hosts_file()));

		if (port != 22){
			cmd += " -p %d".printf(port);
		}

		cmd += " '%s:%s' '%s'".printf(
			escape_single_quote(host_spec()),
			escape_single_quote(repo_path),
			escape_single_quote(mount_point));

		return cmd;
	}

	/* stdin_used: set when the caller pipes data into ssh (upload_file). */
	public string ssh_command(bool stdin_used = false){
		return "ssh %s".printf(ssh_options(stdin_used));
	}

	/* Runs a command on the remote host. The command is quoted once for the
	 * local shell; any paths inside it must already be quoted for the remote
	 * shell by the caller. */
	private int run_remote(string remote_cmd, out string std_out, out string std_err){

		string cmd = "%s %s '%s'".printf(
			ssh_command(),
			q(host_spec()),
			escape_single_quote(remote_cmd));

		int ret_val = run_script_checked(cmd, out std_out, out std_err);

		if (ret_val != 0){
			last_error = (std_err == null) ? "" : std_err.strip();
		}

		master_started = true;

		return ret_val;
	}

	private static string q(string path){
		return "'%s'".printf(escape_single_quote(path));
	}

	public override bool test_connection(out string message){

		message = "";

		string std_out, std_err;
		int ret_val = run_remote("echo TIMESHIFT_OK", out std_out, out std_err);

		if ((ret_val == 0) && (std_out != null) && (std_out.contains("TIMESHIFT_OK"))){
			return true;
		}

		message = (std_err == null) ? _("Failed to connect") : std_err.strip();
		return false;
	}

	public override bool dir_exists(string path){
		string std_out, std_err;
		return (run_remote("test -d %s".printf(q(path)), out std_out, out std_err) == 0);
	}

	public override bool file_exists(string path){
		string std_out, std_err;
		return (run_remote("test -f %s".printf(q(path)), out std_out, out std_err) == 0);
	}

	public override bool dir_create(string path){
		string std_out, std_err;
		return (run_remote("mkdir -p %s".printf(q(path)), out std_out, out std_err) == 0);
	}

	public override string? file_read(string path){
		string std_out, std_err;
		if (run_remote("cat %s".printf(q(path)), out std_out, out std_err) != 0){
			return null;
		}
		return std_out;
	}

	public override bool file_write(string path, string contents){

		// Push the content through a local temp file rather than embedding it
		// in the remote command, so arbitrary content stays safe.
		string tmp = get_temp_file_path();

		if (!TeeJee.FileSystem.file_write(tmp, contents)){ return false; }

		bool ok = upload_file(tmp, path);

		TeeJee.FileSystem.file_delete(tmp);

		return ok;
	}

	public override bool file_delete(string path){
		string std_out, std_err;
		return (run_remote("rm -f %s".printf(q(path)), out std_out, out std_err) == 0);
	}

	public override int64 file_line_count(string path){

		string std_out, std_err;
		if (run_remote("wc -l < %s".printf(q(path)), out std_out, out std_err) != 0){
			return 0;
		}

		if (std_out == null){ return 0; }

		return int64.parse(std_out.strip());
	}

	public override Gee.ArrayList<string> list_subdirs(string path){

		var list = new Gee.ArrayList<string>();

		string std_out, std_err;
		// The sentinel proves the command actually ran to completion, so a
		// truncated or failed transport is not mistaken for an empty listing.
		string cmd = "cd %s || exit 9; for d in */; do [ -e \"$d\" ] && printf '%%s\\n' \"${d%%/}\"; done; printf 'TSEND\\n'".printf(q(path));

		last_listing_ok = false;

		if (run_remote(cmd, out std_out, out std_err) != 0){ return list; }
		if ((std_out == null) || !std_out.contains("TSEND")){ return list; }

		last_listing_ok = true;

		foreach(string line in std_out.split("\n")){
			string name = line.strip();
			if (name.length == 0){ continue; }
			if (name == "TSEND"){ continue; }
			if (name == "*"){ continue; } // no matches, glob left unexpanded
			list.add(name);
		}

		return list;
	}

	public override bool remove_dir_recursive(string path){
		string std_out, std_err;
		return (run_remote("rm -rf %s".printf(q(path)), out std_out, out std_err) == 0);
	}

	public override bool create_symlink(string target, string link_path){
		string std_out, std_err;
		return (run_remote("ln -sfn %s %s".printf(q(target), q(link_path)),
			out std_out, out std_err) == 0);
	}

	public override bool rename(string src_path, string dst_path){
		string std_out, std_err;
		return (run_remote("mv -f %s %s".printf(q(src_path), q(dst_path)),
			out std_out, out std_err) == 0);
	}

	public override bool query_space(string path,
		out uint64 size_bytes, out uint64 used_bytes, out uint64 available_bytes){

		size_bytes = 0;
		used_bytes = 0;
		available_bytes = 0;

		string std_out, std_err;
		if (run_remote("df -B1 %s".printf(q(path)), out std_out, out std_err) != 0){
			return false;
		}

		return RepoBackend.parse_df_output(std_out,
			out size_bytes, out used_bytes, out available_bytes);
	}

	public override bool query_dir_size(string path,
		out int64 total_bytes, out int64 unique_bytes){

		total_bytes = 0;
		unique_bytes = 0;

		string std_out, std_err;

		if (run_remote("du -sb %s".printf(q(path)), out std_out, out std_err) != 0){
			return false;
		}

		if (std_out == null){ return false; }

		string[] parts = Regex.split_simple("""[ \t]+""", std_out.strip());
		if (parts.length < 1){ return false; }

		total_bytes = int64.parse(parts[0]);

		string find_cmd = "find %s -type f -links 1 -printf '%%s\\n' | awk '{s+=$1} END{print s+0}'".printf(
			q(path));

		if (run_remote(find_cmd, out std_out, out std_err) != 0){ return false; }
		if (std_out == null){ return false; }

		unique_bytes = int64.parse(std_out.strip());

		return true;
	}

	public override bool upload_file(string local_path, string repo_path){

		string cmd = "set -o pipefail; cat '%s' | %s %s 'cat > %s'".printf(
			escape_single_quote(local_path),
			ssh_command(true),
			q(host_spec()),
			escape_single_quote(q(repo_path)));

		string std_out, std_err;
		int ret_val = run_script_checked(cmd, out std_out, out std_err);

		if (ret_val != 0){
			last_error = (std_err == null) ? "" : std_err.strip();
		}

		return (ret_val == 0);
	}

	public override bool download_file(string repo_path, string local_path){

		string cmd = "%s %s 'cat %s' > '%s'".printf(
			ssh_command(),
			q(host_spec()),
			escape_single_quote(q(repo_path)),
			escape_single_quote(local_path));

		string std_out, std_err;
		int ret_val = run_script_checked(cmd, out std_out, out std_err);

		if (ret_val != 0){
			last_error = (std_err == null) ? "" : std_err.strip();
		}

		return (ret_val == 0);
	}

	public override string rsync_prefix(){
		return "%s:".printf(host_spec());
	}

	/* sftp:// URI for a file manager.
	 *
	 * This is opened by the *desktop user*, so it authenticates with their
	 * credentials via GVFS, not with Timeshift's root-only key - which is
	 * unavoidable: a uid-1000 process cannot read /etc/timeshift/ssh. */
	public override string browse_uri(string path){

		string authority = Uri.escape_string(host, "", false);

		if (user.length > 0){
			authority = "%s@%s".printf(Uri.escape_string(user, "", false), authority);
		}

		if (port != 22){
			authority = "%s:%d".printf(authority, port);
		}

		return "sftp://%s%s".printf(authority, Uri.escape_string(path, "/", false));
	}

	public override string rsync_rsh(){
		// rsync drives its own protocol over the ssh channel's stdin/stdout,
		// so -n (stdin from /dev/null) would break every transfer.
		return ssh_command(true);
	}

	public override string rsync_remote_path(){
		return fake_super ? "rsync --fake-super" : "";
	}

	public override bool probe_writable(string path){

		string probe = path_combine(path, ".timeshift-write-probe");

		string std_out, std_err;
		int ret_val = run_remote("touch %s && rm -f %s".printf(q(probe), q(probe)),
			out std_out, out std_err);

		return (ret_val == 0);
	}

	public override bool probe_hardlinks(string path){

		string probe = path_combine(path, ".timeshift-link-probe");
		string probe_link = probe + "-2";

		// Report through a sentinel rather than a bare number. int.parse()
		// yields 0 for any non-numeric text, so a login banner or a stat that
		// is absent (BSD/macOS use -f, not -c) previously read as "no
		// hardlinks" - indistinguishable from a real answer.
		// stat -c is GNU; fall back to ls for other remotes.
		string cmd = "rm -f %s %s; touch %s || exit 1;"
			+ " ln %s %s 2>/dev/null || { rm -f %s; exit 2; };"
			+ " n=$(stat -c %%h %s 2>/dev/null || ls -ld %s | awk '{print $2}');"
			+ " rm -f %s %s; printf 'TSLINKS=%%s\\n' \"$n\"";

		cmd = cmd.printf(
			q(probe), q(probe_link),
			q(probe),
			q(probe), q(probe_link), q(probe),
			q(probe), q(probe),
			q(probe), q(probe_link));

		string std_out, std_err;
		if (run_remote(cmd, out std_out, out std_err) != 0){
			// touch or ln failed: not writable, or genuinely no hardlinks
			return false;
		}

		if ((std_out == null) || !std_out.contains("TSLINKS=")){
			last_error = _("Unexpected response from the remote host");
			return false;
		}

		foreach(string line in std_out.split("\n")){
			string t = line.strip();
			if (t.has_prefix("TSLINKS=")){
				return (int.parse(t.replace("TSLINKS=", "")) > 1);
			}
		}

		return false;
	}

	public override bool probe_preserves_ownership(){

		// --fake-super records ownership in an xattr instead of applying it,
		// so an unprivileged remote account is fine in that mode - but only if
		// the remote filesystem actually supports user xattrs. Without them
		// rsync errors per file and exits 23, and the snapshot ends up with no
		// ownership metadata at all, undetectable until a restore. Verify
		// rather than assume.
		if (fake_super){ return probe_xattr_support(); }

		// Sentinel again: int.parse("some banner text") is 0, which would read
		// as "the remote is root" and silently disable the guard that stops
		// ownership-stripped backups.
		string std_out, std_err;
		if (run_remote("printf 'TSUID=%s\\n' \"$(id -u)\"", out std_out, out std_err) != 0){
			return false;
		}

		if (std_out == null){ return false; }

		foreach(string line in std_out.split("\n")){
			string t = line.strip();
			if (t.has_prefix("TSUID=")){
				return (t.replace("TSUID=", "") == "0");
			}
		}

		last_error = _("Unexpected response from the remote host");
		return false;
	}

	/* Confirms the remote filesystem can store the user xattrs that
	 * --fake-super needs to record ownership. */
	public bool probe_xattr_support(){

		string probe = path_combine(base_path_for_probe, ".timeshift-xattr-probe");

		string cmd = "rm -f %s; touch %s || exit 1;"
			+ " if setfattr -n user.timeshift -v 1 %s 2>/dev/null"
			+ " || attr -s timeshift -V 1 %s >/dev/null 2>&1;"
			+ " then printf 'TSXATTR=yes\\n'; else printf 'TSXATTR=no\\n'; fi;"
			+ " rm -f %s";

		cmd = cmd.printf(q(probe), q(probe), q(probe), q(probe), q(probe));

		string std_out, std_err;
		if (run_remote(cmd, out std_out, out std_err) != 0){
			last_error = _("Could not test extended attribute support on the remote host");
			return false;
		}

		if ((std_out != null) && std_out.contains("TSXATTR=yes")){ return true; }

		last_error = _("The remote filesystem does not support extended attributes, which the fake-super option needs to record file ownership");
		return false;
	}

	/* Directory the capability probes run in; set by the repository. */
	public string base_path_for_probe = "/tmp";

	/* Fetches several control files from every snapshot directory in one round
	 * trip. Loading 20 snapshots naively costs 80 round trips; this costs one.
	 *
	 * Returns snapshot name -> (file name -> contents). */
	public Gee.HashMap<string, Gee.HashMap<string, string>>? read_control_files(
		string snapshots_path, string[] file_names){

		var result = new Gee.HashMap<string, Gee.HashMap<string, string>>();

		// A missing control file is normal, so the remote script ends with an
		// explicit exit 0 - otherwise a failing final `cat` would make the
		// whole batch look like a failure. A genuine SSH failure still shows
		// up, because ssh itself returns 255 without ever running this.
		//
		// A random marker keeps file content from being mistaken for a delimiter.
		string marker = "TSFILE-%s".printf(random_string(16));

		string files = "";
		foreach(string fname in file_names){
			files += " %s".printf(q(fname));
		}

		// The marker is emitted only for files that exist, so the caller can
		// tell a missing control file from an empty one.
		string cmd = "cd %s 2>/dev/null || exit 0; for d in */; do d=\"${d%%/}\"; for f in%s; do if [ -f \"$d/$f\" ]; then printf '\\n%s %%s %%s\\n' \"$d\" \"$f\"; cat \"$d/$f\"; fi; done; done; exit 0".printf(
			q(snapshots_path), files, marker);

		string std_out, std_err;

		// Fail closed. Returning an empty map here would be indistinguishable
		// from "this repository has no control files", and the caller treats
		// the pre-fetch as authoritative - so a dropped connection would mark
		// every snapshot invalid and the next auto_remove() would delete them.
		if (run_remote(cmd, out std_out, out std_err) != 0){ return null; }
		if (std_out == null){ return null; }

		string current_snapshot = "";
		string current_file = "";
		var buffer = new StringBuilder();

		foreach(string line in std_out.split("\n")){

			if (line.has_prefix(marker + " ")){

				// flush the previous section
				if ((current_snapshot.length > 0) && (current_file.length > 0)){
					if (!result.has_key(current_snapshot)){
						result[current_snapshot] = new Gee.HashMap<string, string>();
					}
					result[current_snapshot][current_file] = buffer.str;
				}

				buffer = new StringBuilder();

				string[] parts = line.split(" ");
				current_snapshot = (parts.length > 1) ? parts[1] : "";
				current_file = (parts.length > 2) ? parts[2] : "";
				continue;
			}

			if (buffer.len > 0){ buffer.append("\n"); }
			buffer.append(line);
		}

		if ((current_snapshot.length > 0) && (current_file.length > 0)){
			if (!result.has_key(current_snapshot)){
				result[current_snapshot] = new Gee.HashMap<string, string>();
			}
			result[current_snapshot][current_file] = buffer.str;
		}

		return result;
	}

	// ---------------------------------------------------------------
	// key-based auth setup
	//
	// The password supplied by the user is transient: it is never written to
	// the config, never placed on a command line (so never in ps), and never
	// put into any string handed to the logging functions. Note that
	// log_debug() writes to the log file whether or not LOG_DEBUG is set, and
	// those logs are world-readable, so "just don't log it" is a hard rule
	// rather than a nicety.
	// ---------------------------------------------------------------

	/* Creates the directory that holds Timeshift's key material. */
	private bool ensure_key_dir(){

		if (!TeeJee.FileSystem.dir_exists(key_dir())){
			if (!TeeJee.FileSystem.dir_create(key_dir())){
				last_error = _("Could not create") + ": %s".printf(key_dir());
				return false;
			}
		}

		Posix.chmod(key_dir(), 0700);
		return true;
	}

	/* Generates the keypair if it is not already there. Re-running setup for a
	 * second remote reuses the same key. */
	public bool ensure_keypair(string path, out string message){

		message = "";

		if (!ensure_key_dir()){
			message = last_error;
			return false;
		}

		if (TeeJee.FileSystem.file_exists(path)){
			return true;
		}

		string std_out, std_err;
		string cmd = "ssh-keygen -t ed25519 -N '' -f '%s' -C '%s'".printf(
			escape_single_quote(path), escape_single_quote(key_marker()));

		if (run_script_checked(cmd, out std_out, out std_err) != 0){
			message = _("Failed to generate SSH key") + "\n" + ((std_err == null) ? "" : std_err.strip());
			return false;
		}

		Posix.chmod(path, 0600);
		Posix.chmod(path + ".pub", 0644);

		return true;
	}

	/* Fetches the remote host key so the user can confirm its fingerprint
	 * before any password is sent. Returns the raw known_hosts line and a
	 * human-readable fingerprint. */
	public bool scan_host_key(out string key_line, out string fingerprint){

		key_line = "";
		fingerprint = "";

		string std_out, std_err;
		string cmd = "ssh-keyscan -T 5 -p %d '%s' 2>/dev/null".printf(port, escape_single_quote(host));

		if (run_script_checked(cmd, out std_out, out std_err) != 0){ return false; }
		if ((std_out == null) || (std_out.strip().length == 0)){
			last_error = _("No response from host");
			return false;
		}

		// prefer an ed25519 key when the host offers several
		foreach(string line in std_out.split("\n")){
			if (line.strip().length == 0){ continue; }
			if (line.has_prefix("#")){ continue; }
			if (key_line.length == 0){ key_line = line.strip(); }
			if (line.contains("ssh-ed25519")){ key_line = line.strip(); break; }
		}

		if (key_line.length == 0){ return false; }

		// render the fingerprint for display
		string tmp = get_temp_file_path();
		if (!TeeJee.FileSystem.file_write(tmp, key_line + "\n")){ return false; }

		string fp_out, fp_err;
		run_script_checked("ssh-keygen -lf '%s'".printf(escape_single_quote(tmp)),
			out fp_out, out fp_err);

		TeeJee.FileSystem.file_delete(tmp);

		fingerprint = (fp_out == null) ? "" : fp_out.strip();

		return (fingerprint.length > 0);
	}

	/* Records a host key the user has confirmed. */
	public bool trust_host_key(string key_line){

		if (!ensure_key_dir()){ return false; }

		string existing = "";
		if (TeeJee.FileSystem.file_exists(known_hosts_file())){
			string? text = TeeJee.FileSystem.file_read(known_hosts_file());
			if (text != null){ existing = text; }
		}

		if (existing.contains(key_line)){ return true; } // already trusted

		if (!existing.has_suffix("\n") && (existing.length > 0)){ existing += "\n"; }

		return TeeJee.FileSystem.file_write(known_hosts_file(), existing + key_line + "\n");
	}

	/* Installs the public key into the remote account's authorized_keys.
	 *
	 * ssh-copy-id is used rather than a hand-rolled append because it already
	 * handles umask, creating ~/.ssh, the newline guard before appending,
	 * SELinux restorecon, and skipping keys that are already present.
	 *
	 * password == null means "let ssh prompt on the terminal itself", which is
	 * what the console path does - the password then never enters this
	 * process at all. */
	public bool install_public_key(string? password, out string message){

		message = "";

		string pub_key = key_file + ".pub";

		if (!TeeJee.FileSystem.file_exists(pub_key)){
			message = _("Public key not found") + ": %s".printf(pub_key);
			return false;
		}

		string opts = "-o UserKnownHostsFile='%s' -o StrictHostKeyChecking=yes".printf(
			escape_single_quote(known_hosts_file()));
		opts += " -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3";

		// Note: BatchMode is deliberately absent here - it would disable the
		// password prompt this whole flow depends on. Do not add
		// PubkeyAuthentication=no either: ssh-copy-id probes with
		// PreferredAuthentications=publickey to find already-installed keys.
		string cmd = "ssh-copy-id -i '%s' -p %d %s '%s'".printf(
			escape_single_quote(pub_key), port, opts, escape_single_quote(host_spec()));

		int ret_val;
		string std_out, std_err;

		if (password == null){
			// console: hand the child our terminal so ssh can prompt directly
			ret_val = exec_script_sync("%s\nexit $?\n".printf(cmd),
				null, null, false, false, true, true);
		}
		else {
			// GUI: no terminal, so drive ssh's own askpass mechanism. The
			// helper carries no secret; the password reaches it through the
			// environment, which never touches a filesystem.
			string helper = path_combine(TEMP_DIR, "ssh-askpass");

			if (!TeeJee.FileSystem.file_write(helper,
				"#!/bin/sh\nprintf '%s\\n' \"$TIMESHIFT_ASKPASS\"\n")){
				message = _("Failed to prepare authentication helper");
				return false;
			}

			Posix.chmod(helper, 0700);

			GLib.Environment.set_variable("TIMESHIFT_ASKPASS", password, true);
			GLib.Environment.set_variable("SSH_ASKPASS", helper, true);
			GLib.Environment.set_variable("SSH_ASKPASS_REQUIRE", "force", true);

			ret_val = run_script_checked(cmd, out std_out, out std_err);

			// drop the secret from our environment straight away, on every path
			GLib.Environment.unset_variable("TIMESHIFT_ASKPASS");
			GLib.Environment.unset_variable("SSH_ASKPASS");
			GLib.Environment.unset_variable("SSH_ASKPASS_REQUIRE");

			TeeJee.FileSystem.file_delete(helper);

			if (ret_val != 0){
				message = _("Failed to install the key on the remote host");
				if ((std_err != null) && (std_err.strip().length > 0)){
					message += "\n" + std_err.strip();
				}
				return false;
			}
		}

		if (ret_val != 0){
			message = _("Failed to install the key on the remote host");
			return false;
		}

		return true;
	}

	/* Removes authorized_keys entries that this machine's Timeshift installed
	 * previously and can no longer use, i.e. whose private half is gone.
	 *
	 * Scope is deliberately narrow. Only lines whose comment is exactly this
	 * host's marker ("timeshift@<hostname>") are considered, and the key we
	 * currently hold is always kept. Keys belonging to the user, to other
	 * tools, or to a Timeshift install on a *different* machine backing up to
	 * the same remote are never touched - removing those would lock other
	 * machines out.
	 *
	 * Call this only after the new key has been verified to work, so a
	 * failure can never leave the account with no usable key. */
	public bool remove_stale_keys(out int removed, out string message){

		removed = 0;
		message = "";

		string marker = key_marker();

		string? pub = TeeJee.FileSystem.file_read(key_file + ".pub");
		if (pub == null){
			message = _("Public key not found");
			return false;
		}

		// the blob is the second field of "<type> <blob> <comment>"
		string[] parts = Regex.split_simple("""[ \t]+""", pub.strip());
		if (parts.length < 2){
			message = _("Could not read the public key");
			return false;
		}
		string keep_blob = parts[1];

		// Keep a line unless it is one of ours AND is not the key we hold.
		// The key type is located by prefix rather than by position, so lines
		// carrying options (command="...", no-pty, ...) parse correctly.
		// Locate the key type by prefix rather than by position, so lines
		// carrying options (command="...",no-pty ...) parse correctly. The
		// comment is everything after the blob, rebuilt and compared whole -
		// matching only the last field would delete any key whose comment
		// merely *ends* in our marker.
		string awk_prog = "{ t=0; b=\"\"; c=\"\";"
			+ " for(i=1;i<=NF;i++){ if($i ~ /^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-|sk-ssh-|sk-ecdsa-)/){ t=i; b=$(i+1); break } }"
			+ " if (t>0){ for(j=t+2;j<=NF;j++){ c = (c==\"\") ? $j : c \" \" $j } }"
			+ " if (t>0 && c==tag && b!=keep) next;"
			+ " print }";

		// Safety rules for this command, in order of importance:
		//  - never truncate the original: write a temp file and rename over it,
		//    so a full disk or dropped link cannot leave the account with an
		//    empty authorized_keys and no way back in
		//  - refuse to write an empty result when the input was not empty
		//  - mktemp, not $$: a predictable name in a writable ~/.ssh is a
		//    symlink-attack target, and a leftover authorized_keys.* file is
		//    itself live under "AuthorizedKeysFile .ssh/authorized_keys*"
		//  - clean the temp up on every exit path
		string remote = "set -e;"
			+ " f=\"$HOME/.ssh/authorized_keys\";"
			+ " [ -f \"$f\" ] || { printf 'TS_REMOVED=%%s\\n' 0; exit 0; };"
			+ " umask 077;"
			+ " tmp=$(mktemp \"$f.tsXXXXXX\") || exit 1;"
			+ " trap 'rm -f \"$tmp\"' EXIT;"
			+ " before=$(grep -c . \"$f\" || :);"
			+ " awk -v tag=%s -v keep=%s '%s' \"$f\" > \"$tmp\";"
			+ " after=$(grep -c . \"$tmp\" || :);"
			+ " if [ \"$before\" -gt 0 ] && [ \"$after\" -eq 0 ]; then exit 3; fi;"
			+ " chmod 600 \"$tmp\"; mv \"$tmp\" \"$f\"; trap - EXIT;"
			+ " printf 'TS_REMOVED=%%s\\n' \"$((before-after))\"";

		remote = remote.printf(
			shell_quote(marker), shell_quote(keep_blob), awk_prog);

		string std_out, std_err;
		if (run_remote(remote, out std_out, out std_err) != 0){
			message = (std_err == null) ? _("Failed to tidy the remote authorized_keys") : std_err.strip();
			return false;
		}

		// The sentinel proves the script ran to completion. Without it we
		// cannot claim success: a login banner, a non-POSIX remote shell or a
		// mid-command failure would otherwise be reported as "removed 0".
		bool saw_sentinel = false;

		if (std_out != null){
			foreach(string line in std_out.split("\n")){
				if (line.strip().has_prefix("TS_REMOVED=")){
					removed = int.parse(line.strip().replace("TS_REMOVED=", ""));
					saw_sentinel = true;
				}
			}
		}

		if (!saw_sentinel){
			message = _("Could not tidy old keys on the remote host");
			return false;
		}

		return true;
	}

	/* Identifies keys this machine installed.
	 *
	 * Hostnames are not unique - "raspberrypi", "ubuntu" and "localhost" are
	 * the default on very many machines - so keying on one would let two hosts
	 * sharing a name delete each other's keys from a shared repository. The
	 * machine-id is stable and unique; the hostname is kept only as a human
	 * readable hint. */
	public static string key_marker(){

		string id = "";
		string? text = TeeJee.FileSystem.file_read("/etc/machine-id");

		if (text != null){ id = text.strip(); }

		if (id.length == 0){
			// no machine-id: fall back to the hostname, and accept the
			// ambiguity rather than refusing to work
			return "timeshift@%s".printf(Environment.get_host_name());
		}

		return "timeshift-%s@%s".printf(id, Environment.get_host_name());
	}

	/* Wraps a value in single quotes for the *remote* shell. */
	private static string shell_quote(string val){
		return "'%s'".printf(escape_single_quote(val));
	}

	/* Confirms the installed key actually authenticates.
	 *
	 * This is not belt-and-braces: ssh-copy-id exits 0 even when the password
	 * was wrong and nothing was installed, so its status alone cannot be
	 * trusted to mean success. */
	public bool verify_key_auth(out string message){

		message = "";

		string cmd = "ssh -n -F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes";
		cmd += " -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3";
		cmd += " -o UserKnownHostsFile='%s' -o StrictHostKeyChecking=yes".printf(
			escape_single_quote(known_hosts_file()));
		cmd += " -o IdentitiesOnly=yes -i '%s'".printf(escape_single_quote(key_file));
		cmd += " -p %d '%s' 'echo TIMESHIFT_KEY_OK'".printf(port, escape_single_quote(host_spec()));

		string std_out, std_err;
		int ret_val = run_script_checked(cmd, out std_out, out std_err);

		if ((ret_val == 0) && (std_out != null) && std_out.contains("TIMESHIFT_KEY_OK")){
			return true;
		}

		// covers both "wrong password, nothing installed" and "installed but
		// the remote refuses it" - ssh-copy-id cannot distinguish them for us
		message = _("Key-based login is not working.");
		message += "\n" + _("The password may have been incorrect, or the remote may not permit key authentication.");
		if ((std_err != null) && (std_err.strip().length > 0)){
			message += "\n" + std_err.strip();
		}

		return false;
	}

	public override void cleanup(){

		if (!master_started){ return; }
		if (control_path.length == 0){ return; }

		string cmd = "%s -O exit %s".printf(ssh_command(), q(host_spec()));

		string std_out, std_err;
		run_script_checked(cmd, out std_out, out std_err);

		master_started = false;
	}
}
