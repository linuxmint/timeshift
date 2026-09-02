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

	/* Stable, untranslated identifier for the kind of repository this backend
	 * provides. It is logged and printed verbatim as a diagnostic token, so it
	 * must never be localised. Not persisted - the config keeps
	 * backup_location_type; this only collapses location and mode into one
	 * string for human consumption. */
	public virtual string type_id {
		owned get { return "local"; }
	}

	public abstract bool dir_exists(string path);

	public abstract bool file_exists(string path);

	public abstract bool dir_create(string path);

	public abstract string? file_read(string path);

	public abstract bool file_write(string path, string contents);

	public abstract bool file_delete(string path);

	public abstract int64 file_line_count(string path);

	public abstract Gee.ArrayList<string> list_subdirs(string path);

	public abstract bool remove_dir_recursive(string path);

	/* The same removal as remove_dir_recursive(), expressed as a shell command
	 * that prints one line per entry removed. A DeleteFileTask runs this and
	 * counts the lines, which is the only way the delete page can show progress
	 * for a repository it does not own the filesystem of. */
	public virtual string remove_dir_recursive_command(string path){
		return "rm -rfv '%s'".printf(escape_single_quote(path));
	}

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

	/* A shell command that succeeds when the repository is reachable, for a
	 * restore script to poll while it waits out a network outage. Empty for a
	 * local repository, which cannot go away mid-transfer. */
	public virtual string reachability_command(){
		return "";
	}

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

	/* Drop any shared connection so the next operation starts a new one.
	 * Only the SSH backend has one; for everything else this is a no-op. */
	public virtual void drop_master(){
	}

	/* The same thing as a shell fragment, for scripts that outlive the call.
	 * Empty when the backend has no shared connection to drop. */
	public virtual string drop_master_command(){
		return "";
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

	/* A remote repository is always rsync: btrfs mode needs local subvolumes
	 * and is forced off for SSH. */
	public override string type_id {
		owned get { return "remote-ssh-rsync"; }
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

	/* no_mux: force a fresh connection instead of attaching to the shared
	 * ControlMaster socket.
	 *
	 * This matters more than it looks. When a link dies mid-transfer the
	 * master process stays resident holding a dead TCP session, and a client
	 * attaching to it over the unix socket never performs a connect(2) -- so
	 * ConnectTimeout does not apply and the client simply blocks. Every ssh
	 * here runs through spawn_sync, which has no timeout of its own, so a
	 * wedged master turns the restore's "is the host back yet?" probe into an
	 * indefinite wait that can never dial afresh. That is exactly how a
	 * recovered network still looked unreachable. */
	private string ssh_options(bool stdin_used = false, bool no_mux = false){

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

		if (no_mux){
			// never reuse, never create a master
			opts += " -o ControlMaster=no -o ControlPath=none";
		}
		else if (control_path.length > 0){
			opts += " -o ControlMaster=auto -o ControlPath='%s' -o ControlPersist=60".printf(
				escape_single_quote(control_path));
		}

		return opts;
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

	/* Quoted twice, the same way run_remote() does it: q() for the remote
	 * shell, then escape_single_quote() for the local shell that runs the
	 * task script. ssh_command() carries -n, so ssh cannot eat the task's
	 * stdin, and the ControlMaster options make this ride the connection the
	 * repository already opened. */
	public override string remove_dir_recursive_command(string path){

		string remote_cmd = "rm -rfv %s".printf(q(path));

		return "%s %s '%s'".printf(
			ssh_command(),
			q(host_spec()),
			escape_single_quote(remote_cmd));
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

	public override string rsync_prefix(){
		return "%s:".printf(host_spec());
	}

	public override string rsync_rsh(){
		// rsync drives its own protocol over the ssh channel's stdin/stdout,
		// so -n (stdin from /dev/null) would break every transfer.
		return ssh_command(true);
	}

	public override string rsync_remote_path(){
		return fake_super ? "rsync --fake-super" : "";
	}

	/* -n here (unlike rsync_rsh): this probe must not touch the script's stdin.
	 *
	 * Deliberately unmultiplexed. The whole point of this command is to answer
	 * "can a NEW connection be made?", and a client that attaches to the
	 * existing ControlMaster socket answers a different question -- and hangs
	 * instead of honouring ConnectTimeout when that master is wedged. With
	 * ControlPath=none the probe always dials, and always returns within
	 * ConnectTimeout. */
	public override string reachability_command(){
		return "ssh %s %s true".printf(ssh_options(false, true), host_spec());
	}

	/* Tear down the shared connection so the next operation dials afresh.
	 *
	 * Called when something has already gone wrong with the link: the master
	 * may be holding a dead session that every subsequent client would attach
	 * to and block on. "ssh -O exit" is itself a mux client, so it is bounded
	 * by timeout(1) rather than trusted to return, and the socket is removed
	 * afterwards in case the master was gone but its socket file was not --
	 * a leftover socket also stops the directory from ever being reaped. */
	public override string drop_master_command(){

		if (control_path.length == 0){ return ""; }

		string cmd = "timeout 5 ssh %s -O exit %s >/dev/null 2>&1; ".printf(
			ssh_options(false, false), q(host_spec()));

		/* And remove the socket. A master that died without cleaning up leaves
		 * one behind, which also stops /run/timeshift/<pid> from ever being
		 * reaped (the reaper only calls rmdir). %C is expanded by ssh, so the
		 * exact name is not known here -- the glob must sit OUTSIDE the quotes
		 * or the shell never expands it. */
		cmd += "rm -f '%s'* 2>/dev/null; true".printf(escape_single_quote(
			control_path.replace("%C", "")));

		return cmd;
	}

	public override void drop_master(){

		string cmd = drop_master_command();

		if (cmd.length == 0){ return; }

		string std_out, std_err;
		exec_script_sync(cmd, out std_out, out std_err, true);

		master_started = false;
	}

	/* Directory the capability probes run in; set by the repository. */
	public string base_path_for_probe = "/tmp";

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

	public override void cleanup(){

		if (!master_started){ return; }
		if (control_path.length == 0){ return; }

		string cmd = "%s -O exit %s".printf(ssh_command(), q(host_spec()));

		string std_out, std_err;
		run_script_checked(cmd, out std_out, out std_err);

		master_started = false;
	}
}
