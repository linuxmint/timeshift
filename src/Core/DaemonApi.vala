/*
 * DaemonApi.vala
 *
 * Copyright 2025 Timeshift contributors
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
 */

using TeeJee.Logging;

/* The daemon's methods, typed.
 *
 * DaemonClient is the transport: one JSON object per line, a generic call(),
 * and the event stream. This is everything the daemon can be ASKED, with the
 * decoding done once here instead of at each call site.
 *
 * Why a separate class rather than more methods on DaemonClient: the transport
 * has one job and about five reasons to change, all of them to do with sockets.
 * The method surface has thirty-odd reasons to change, all of them to do with
 * the protocol. Keeping them apart is also what stops DaemonClient turning into
 * the second god object of this codebase, which is the specific thing the port
 * exists to undo.
 *
 * FAILURE IS ORDINARY HERE. A daemon that is absent, refusing, or one protocol
 * version away is a normal state during the migration -- the Vala core still
 * does its own work -- so nothing throws. A reader returns null and a verb
 * returns false, and `last_error` says why in a form fit to show a person.
 *
 * READ-ONLY IS DECIDED BY THE DAEMON, not here. Access comes from the peer
 * credentials on the socket: root gets everything, a member of the timeshift
 * group gets the read subset, anyone else is refused before a method runs. So a
 * mutating call from an unprivileged client fails with a message rather than
 * being screened out client-side -- one place decides, and it is the one that
 * can enforce it.
 */
public class DaemonApi : GLib.Object {

	private DaemonClient client;

	/* Why the last call failed, ready to show. Cleared by every call, so it is
	 * only meaningful immediately after one returned null or false. */
	public string last_error { get; private set; default = ""; }

	public DaemonApi(DaemonClient client){
		this.client = client;
	}

	// -----------------------------------------------------------------------
	// The process-wide client
	//
	// Deliberately NOT hung off Main. Most of the core's start-up runs from
	// Main's own constructor -- update_partitions(), detect_system_devices(),
	// load_app_config() -- and the global `App` is not assigned until that
	// constructor RETURNS. So anything reaching the daemon through App.daemon
	// is unreachable from exactly the code that sets the system up, and would
	// silently fall back to shelling out. That is not a detail of this class,
	// it is a property of the object being dismantled, so the connection is
	// kept somewhere that does not depend on it.
	//
	// One connection for the whole process, opened once. A caller that wants
	// its own -- DaemonBridge does, because it also runs an event stream and
	// closes both together -- constructs a DaemonClient directly.

	private static DaemonClient? shared_client;
	private static DaemonApi? shared_api;
	private static bool shared_tried;

	/* The shared API, or null when there is no daemon.
	 *
	 * Tried once. A daemon that was not running when this process started is
	 * not retried on every call: the fallbacks each cost a subprocess or an SSH
	 * round trip, and retrying a connection that just failed in front of every
	 * one of them would be slower than the fallback it is trying to avoid.
	 */
	public static unowned DaemonApi? get_shared(){
		if (!shared_tried){
			shared_tried = true;
			var client = new DaemonClient();
			if (client.open()){
				shared_client = client;
				shared_api = new DaemonApi(client);
			}
		}
		return shared_api;
	}

	public static unowned DaemonClient? get_shared_client(){
		get_shared();
		return shared_client;
	}

	// -----------------------------------------------------------------------
	// Plumbing

	private Json.Object? ask(string method, Json.Object? params = null){
		last_error = "";
		string error;
		var node = client.call(method, params, out error);
		if (node == null){
			last_error = (error.length > 0) ? error
				: _("The Timeshift daemon did not answer");
			log_debug("DaemonApi: %s: %s".printf(method, last_error));
			return null;
		}
		if (node.get_node_type() != Json.NodeType.OBJECT){
			last_error = _("Unexpected reply from the Timeshift daemon");
			return null;
		}
		return node.get_object();
	}

	/* A verb: something that either happened or did not.
	 *
	 * A method with no result is a SUCCESS, not a failure. Several of these
	 * return nothing at all on the wire, and treating an absent result as an
	 * error would report every one of them as broken. */
	private bool tell(string method, Json.Object? params = null){
		last_error = "";
		string error;
		client.call(method, params, out error);
		if (error.length > 0){
			last_error = error;
			log_debug("DaemonApi: %s: %s".printf(method, error));
			return false;
		}
		return true;
	}

	private static Json.Object obj(){ return new Json.Object(); }

	// -----------------------------------------------------------------------
	// The system

	public DaemonSystemInfo? system_info(){
		var o = ask("system.info");
		return (o == null) ? null : DaemonSystemInfo.from_wire(o);
	}

	// -----------------------------------------------------------------------
	// Configuration
	//
	// config.get answers in the ON-DISK dialect: every scalar is a JSON string
	// ("true", "5") and the two exclude lists are arrays. That is deliberate --
	// it is the same shape timeshift.json holds -- so the object below can be
	// read with TeeJee.JsonHelper's json_get_*, which the rest of the codebase
	// already uses for exactly this. DaemonClient's wire_* readers also cope,
	// because they accept either representation.

	public Json.Object? config_get(){
		return ask("config.get");
	}

	/* config.set is a PARTIAL update, and that is the whole design.
	 *
	 * Send only the keys being changed. A whole-config write would mean a
	 * client one version behind silently reverting every key it did not know
	 * about -- which is the failure the Vala GUI already has against
	 * timeshift.json, where saving drops any key this build has never heard of.
	 *
	 * Three things are refused rather than ignored, each of which would
	 * otherwise be a silent loss: an unknown key (a typo that is quietly
	 * accepted looks exactly like a setting that does not work), a wrongly
	 * typed value (send a real `true` instead of `"true"` and the old value
	 * survives, so the change is accepted and dropped), and a value the daemon
	 * cannot parse. All three come back through last_error.
	 */
	public bool config_set(Json.Object partial){
		var p = obj();
		p.set_object_member("values", partial);
		return tell("config.set", p);
	}

	// -----------------------------------------------------------------------
	// Devices

	/* Every block device, not only the ones with a Linux filesystem.
	 *
	 * Filtering is the caller's: a listing applies has_linux_filesystem, a
	 * device TREE must not, because a disk carries no filesystem and is exactly
	 * what the partitions hang from.
	 */
	public Gee.ArrayList<DaemonDevice> devices_list(){
		last_error = "";
		var list = new Gee.ArrayList<DaemonDevice>();
		foreach (var o in client.call_array("devices.list", null)){
			list.add(DaemonDevice.from_wire(o));
		}
		return list;
	}

	/* Unlock a LUKS container. The passphrase reaches cryptsetup on STDIN.
	 *
	 * Never in argv: it would sit in /proc/<pid>/cmdline for anything on the
	 * machine to read. The daemon takes it from the request and writes it to
	 * the child, and it is never logged.
	 *
	 * An already-unlocked container is SUCCESS -- the caller wants it open, and
	 * it is. No passphrase is a refusal rather than a prompt, because a daemon
	 * has no terminal and cryptsetup would wait for one forever.
	 */
	public bool devices_unlock(string device, string passphrase,
		out string mapped_name, out string path, out bool already_open){

		mapped_name = "";
		path = "";
		already_open = false;

		var p = obj();
		p.set_string_member("device", device);
		p.set_string_member("passphrase", passphrase);

		var o = ask("devices.unlock", p);
		if (o == null){ return false; }

		/* The default mapper name is <kname>_crypt, chosen so a container
		 * opened by either core appears at the same path. */
		mapped_name  = DaemonClient.wire_string(o, "mapped_name", "");
		path         = DaemonClient.wire_string(o, "path", "");
		already_open = DaemonClient.wire_bool(o, "already_open", false);
		return true;
	}

	public bool devices_lock(string name){
		var p = obj();
		p.set_string_member("name", name);
		return tell("devices.lock", p);
	}

	// -----------------------------------------------------------------------
	// The repository

	public DaemonRepoStatus? repo_status(){
		var o = ask("repo.status");
		return (o == null) ? null : DaemonRepoStatus.from_wire(o);
	}

	public bool repo_reload(){
		return tell("repo.reload");
	}

	/* Choose a location, and hear WHY not.
	 *
	 * Main.check_device_for_backup() answered with a boolean, which is why the
	 * GUI could refuse a disk without ever explaining what was wrong with it.
	 * This validates before it saves and reports the reason.
	 *
	 * dry_run checks without writing the config, which is what lets a wizard
	 * page react as the selection changes.
	 */
	public bool repo_select(string device, string device_uuid, string ssh_url,
		bool dry_run, out string reason, out bool saved){

		reason = "";
		saved = false;

		var p = obj();
		if (device.length > 0){ p.set_string_member("device", device); }
		if (device_uuid.length > 0){ p.set_string_member("device_uuid", device_uuid); }
		if (ssh_url.length > 0){ p.set_string_member("url", ssh_url); }
		if (dry_run){ p.set_boolean_member("dry_run", true); }

		var o = ask("repo.select", p);
		if (o == null){
			reason = last_error;
			return false;
		}

		/* usable and saved are separate answers, and conflating them is a real
		 * mistake: a dry run of a perfectly good location is usable and NOT
		 * saved, so a caller that read only one of them would either report a
		 * valid disk as rejected or believe a probe had written the config. */
		bool usable = DaemonClient.wire_bool(o, "usable", false);
		saved = DaemonClient.wire_bool(o, "saved", false);
		if (!usable){
			reason = DaemonClient.wire_string(o, "reason",
				_("This location cannot be used"));
		}
		return usable;
	}

	/* Drop the multiplexed SSH master.
	 *
	 * The explicit lever for a wedged connection. Note the daemon does NOT run
	 * `ssh -O exit` when it closes a repository handle: every handle in one
	 * daemon shares one master, and a repo.status arriving during a backup
	 * would otherwise pull the connection out from under the running rsync.
	 */
	public bool repo_drop_master(){
		return tell("repo.drop_master");
	}

	// -----------------------------------------------------------------------
	// SSH setup
	//
	// Four steps, and the ORDER is the security argument: scan the host key so
	// a fingerprint can be shown BEFORE any password is sent, generate a key,
	// install it, then verify. The verify is required rather than polite --
	// ssh-copy-id exits 0 even when the password was wrong and nothing was
	// installed, so without it the flow reports success on a host it cannot
	// reach.

	/* Scan the host key. `line` is the known_hosts entry; `fingerprint` is what
	 * to SHOW someone before any password is sent, and the line is what to hand
	 * back to setup_key once they have accepted it. Keeping them separate is
	 * the point: accepting a fingerprint is a decision, and the decision has to
	 * be made on the same key that then gets trusted. */
	public bool repo_ssh_scan_host(string host, int port,
		out string fingerprint, out string host_key_line){

		fingerprint = "";
		host_key_line = "";

		var p = obj();
		p.set_string_member("host", host);
		if (port > 0){ p.set_int_member("port", port); }

		var o = ask("repo.ssh.scan_host", p);
		if (o == null){ return false; }

		fingerprint   = DaemonClient.wire_string(o, "fingerprint", "");
		host_key_line = DaemonClient.wire_string(o, "line", "");
		return true;
	}

	/* Generate a key if needed, install it, and VERIFY.
	 *
	 * `host_key_line` is what scan_host returned and the person accepted; pass
	 * it so the host is trusted on the strength of the key they were shown.
	 *
	 * Success is `verified` or `already_working`, never `installed`.
	 * ssh-copy-id exits 0 even when the password was wrong and nothing was
	 * installed, so a flow that stopped at "installed" would report success on
	 * a host it cannot reach -- which is precisely the failure the verify step
	 * exists to catch.
	 */
	public bool repo_ssh_setup_key(string url, string key_file, int port,
		string host_key_line, string password, out string problem,
		out int stale_keys_removed){

		problem = "";
		stale_keys_removed = 0;

		var p = obj();
		p.set_string_member("url", url);
		if (key_file.length > 0){ p.set_string_member("key_file", key_file); }
		if (port > 0){ p.set_int_member("port", port); }
		if (host_key_line.length > 0){
			p.set_string_member("host_key_line", host_key_line);
		}
		if (password.length > 0){ p.set_string_member("password", password); }

		var o = ask("repo.ssh.setup_key", p);
		if (o == null){
			problem = last_error;
			return false;
		}

		/* Additive field: a daemon that predates it sends nothing and this
		 * reads zero, so the caller simply says nothing about old keys. */
		stale_keys_removed = (int) DaemonClient.wire_int(o, "stale_keys_removed", 0);

		if (DaemonClient.wire_bool(o, "verified", false) ||
			DaemonClient.wire_bool(o, "already_working", false)){
			return true;
		}

		problem = DaemonClient.wire_bool(o, "installed", false)
			? _("The key was installed but the host would not accept it")
			: _("The key could not be installed on the remote host");
		return false;
	}

	public bool repo_ssh_test(string url, string key_file, int port, out string problem){

		problem = "";

		var p = obj();
		p.set_string_member("url", url);
		if (key_file.length > 0){ p.set_string_member("key_file", key_file); }
		if (port > 0){ p.set_int_member("port", port); }

		var o = ask("repo.ssh.test", p);
		if (o == null){
			problem = last_error;
			return false;
		}
		if (!DaemonClient.wire_bool(o, "ok", false)){
			problem = DaemonClient.wire_string(o, "message",
				_("The host did not answer"));
			return false;
		}
		return true;
	}

	// -----------------------------------------------------------------------
	// Snapshots

	public Gee.ArrayList<DaemonSnapshot> snapshots_list(){
		last_error = "";
		var list = new Gee.ArrayList<DaemonSnapshot>();
		foreach (var o in client.call_array("snapshots.list", null)){
			list.add(DaemonSnapshot.from_wire(o));
		}
		return list;
	}

	/* Edit a snapshot's comment or its retention tags.
	 *
	 * Null means "leave alone", which is not the same as an empty value:
	 * passing "" clears the comment, and passing an empty array removes every
	 * tag -- and a snapshot left with no tags is what the retention pass then
	 * deletes. So the two have to be distinguishable.
	 */
	public bool snapshots_update(string name, string? comments, string[]? tags){

		var p = obj();
		p.set_string_member("name", name);

		if (comments != null){
			p.set_string_member("comments", comments);
		}
		if (tags != null){
			var arr = new Json.Array();
			foreach (var tag in tags){ arr.add_string_element(tag); }
			p.set_array_member("tags", arr);
		}
		return tell("snapshots.update", p);
	}

	// Mark or unmark a snapshot for deletion, without touching its tags.
	public bool snapshots_mark_for_deletion(string name, bool marked){
		var p = obj();
		p.set_string_member("name", name);
		p.set_boolean_member("marked_for_deletion", marked);
		return tell("snapshots.update", p);
	}

	/* Make a snapshot readable, and get back a PATH.
	 *
	 * The daemon mounts; the client opens. Opening a file manager needs the
	 * desktop user's session, which the daemon may not have at all, so it stops
	 * at handing over a path.
	 *
	 * A LOCAL repository is not mounted -- the snapshot is already a directory
	 * on a mounted filesystem, and `mounted` comes back false so a release
	 * cannot unmount the repository itself. Only a remote one is sshfs-mounted,
	 * and the reason the daemon has to do it is credentials: the key lives in
	 * /etc/timeshift/ssh, root-only, so the person at the keyboard usually
	 * cannot reach the host at all.
	 *
	 * as_uid/as_gid are the DESKTOP user's, not ours. The daemon runs as root
	 * and the file manager does not, so a mount owned by root is a mount the
	 * person cannot read.
	 */
	public bool snapshots_browse(string name, int as_uid, int as_gid,
		out string path, out bool mounted){

		path = "";
		mounted = false;

		var p = obj();
		p.set_string_member("snapshot", name);
		p.set_int_member("uid", as_uid);
		p.set_int_member("gid", as_gid);

		var o = ask("snapshots.browse", p);
		if (o == null){ return false; }

		path    = DaemonClient.wire_string(o, "path", "");
		mounted = DaemonClient.wire_bool(o, "mounted", false);
		return true;
	}

	public bool snapshots_browse_release(string path){
		var p = obj();
		p.set_string_member("path", path);
		return tell("snapshots.browse_release", p);
	}

	// -----------------------------------------------------------------------
	// Jobs
	//
	// Starting one is DaemonBridge's business, because the caller then wants
	// the event stream. These are the controls that act on a job already
	// running, whoever started it.

	public bool jobs_cancel(string job_id){
		var p = obj();
		if (job_id.length > 0){ p.set_string_member("job", job_id); }
		return tell("jobs.cancel", p);
	}

	/* Pause SUSPENDS the work, it does not merely set a flag.
	 *
	 * The process group gets SIGSTOP. A flag alone changes nothing rsync can
	 * see, and rsync carries on -- so a "paused" backup would keep writing. The
	 * job keeps the repository write lock while paused, which is the only
	 * correct answer mid-write and worth saying out loud in the UI.
	 */
	public bool jobs_pause(string job_id){
		var p = obj();
		if (job_id.length > 0){ p.set_string_member("job", job_id); }
		return tell("jobs.pause", p);
	}

	public bool jobs_resume(string job_id){
		var p = obj();
		if (job_id.length > 0){ p.set_string_member("job", job_id); }
		return tell("jobs.resume", p);
	}

	public Json.Object? jobs_get(string job_id){
		var p = obj();
		p.set_string_member("job", job_id);
		return ask("jobs.get", p);
	}

	// -----------------------------------------------------------------------
	// The schedule

	/* When the scheduler last ran, what it decided, and whether it is alive.
	 *
	 * This exists because losing cron lost a real safety net. cron ran whether
	 * or not our code was healthy; a dead timeshiftd now means no snapshots
	 * with nothing to notice. Somewhere has to be able to say so.
	 */
	public DaemonScheduleStatus? schedule_status(){
		var o = ask("schedule.status");
		return (o == null) ? null : DaemonScheduleStatus.from_wire(o);
	}

	/* Ask the scheduler to run a check now.
	 *
	 * This REQUESTS a check; it does not perform one and does not return a job.
	 * Whether anything gets taken is the scheduler's decision -- almost always
	 * "nothing", because every test is an age comparison and only one check in
	 * an interval can find one due. Watch jobs.subscribe to see a snapshot if
	 * one does start.
	 */
	public bool schedule_check(){
		var o = ask("schedule.check");
		return (o != null) && DaemonClient.wire_bool(o, "requested", false);
	}

	// -----------------------------------------------------------------------
	// Logs
	//
	// log.parse is a JOB, not a call that returns the answer. A real snapshot
	// log here is 22 MB and 222,521 changes -- a download, not a response -- so
	// it is parsed once, cached by path, and served in pages by log.entries
	// with the kind filtering done daemon-side.

	/* Start parsing a log. Returns the job to watch AND the path to page by.
	 *
	 * The path matters because log.entries is keyed by it, not by the job id --
	 * the parse caches its result by path so a log opened twice is parsed once,
	 * and the job id is not available inside the job's own run function.
	 *
	 * Reading a file as root on request is the risky part, so the daemon
	 * confines it: only /var/log/timeshift may be named by `path`, symlinks
	 * resolved first, and a snapshot's log is addressed by snapshot NAME plus a
	 * bare file name that must equal its own basename.
	 */
	public bool log_parse(string snapshot, string name, string path,
		out string job_id, out string log_path){

		job_id = "";
		log_path = "";

		var p = obj();
		if (path.length > 0){ p.set_string_member("path", path); }
		if (snapshot.length > 0){ p.set_string_member("snapshot", snapshot); }
		if (name.length > 0){ p.set_string_member("name", name); }

		var o = ask("log.parse", p);
		if (o == null){ return false; }

		job_id   = DaemonClient.wire_string(o, "job", "");
		log_path = DaemonClient.wire_string(o, "path", "");
		return true;
	}

	/* One page of a parsed log.
	 *
	 * `kinds` filters daemon-side, which is the point: a real snapshot log here
	 * is 22 MB and 222,521 changes, so filtering after transfer would mean
	 * moving all of it to show a few hundred rows. An empty list means every
	 * kind.
	 */
	public Json.Object? log_entries(string path, int64 offset, int64 limit,
		string[] kinds){

		var p = obj();
		p.set_string_member("path", path);
		if (offset > 0){ p.set_int_member("offset", offset); }
		if (limit > 0){ p.set_int_member("limit", limit); }
		if (kinds.length > 0){
			var arr = new Json.Array();
			foreach (var k in kinds){ arr.add_string_element(k); }
			p.set_array_member("kinds", arr);
		}
		return ask("log.entries", p);
	}

	// -----------------------------------------------------------------------
	// Restore

	/* Plan a restore: decide everything, touch nothing.
	 *
	 * Always call this before restore_run and show what comes back. The failure
	 * that matters here is not a crash, it is a restore that works perfectly
	 * onto the wrong disk -- and a person recognising the disk in the list is
	 * the only thing that catches it.
	 */
	public DaemonRestorePlan? restore_plan(string snapshot,
		Gee.Map<string,string> mounts, bool current_system){

		var p = obj();
		p.set_string_member("snapshot", snapshot);
		p.set_boolean_member("current_system", current_system);

		if (mounts.size > 0){
			var m = obj();
			foreach (var key in mounts.keys){
				m.set_string_member(key, mounts.get(key));
			}
			p.set_object_member("mounts", m);
		}

		var o = ask("restore.plan", p);
		return (o == null) ? null : DaemonRestorePlan.from_wire(o);
	}

	// -----------------------------------------------------------------------
	// Recovery

	public DaemonRecoveryStatus? recovery_status(){
		var o = ask("recovery.status");
		return (o == null) ? null : DaemonRecoveryStatus.from_wire(o);
	}

	/* The verbs answer {verb, ok} rather than nothing, so `ok` is read.
	 *
	 * Enabling can fail for a reason the call itself succeeds through -- most
	 * often GRUB_TIMEOUT being 0, which means GRUB reads no keyboard at all and
	 * the hotkey that reaches the environment can never be pressed. Treating
	 * "the method ran" as "the environment is reachable" would hide exactly
	 * that. */
	public bool recovery_enable(){
		var o = ask("recovery.enable");
		return (o != null) && DaemonClient.wire_bool(o, "ok", false);
	}

	public bool recovery_disable(){
		var o = ask("recovery.disable");
		return (o != null) && DaemonClient.wire_bool(o, "ok", false);
	}

	// Building an environment runs mmdebstrap for minutes, so it is a job.
	// It does NOT take the repository write lock: it writes GRUB and
	// /var/lib, not snapshots.
	public bool recovery_install(string target, string size, out string job_id){
		job_id = "";

		var p = obj();
		if (target.length > 0){ p.set_string_member("target", target); }
		if (size.length > 0){ p.set_string_member("size", size); }

		var o = ask("recovery.install", p);
		if (o == null){ return false; }
		job_id = DaemonClient.wire_string(o, "job", "");
		return true;
	}

	// -----------------------------------------------------------------------

	/* Exercise every read method against the running daemon.
	 *
	 * TIMESHIFT_IPC_SELFTEST=1 timeshift-gtk
	 *
	 * This exists because the failure mode of this file is silent. Every reader
	 * defaults rather than throws, so a member name that does not match the
	 * wire produces an empty string and a zero, not an error -- and the first
	 * symptom is a GUI that draws a repository as "Not Selected" over a
	 * perfectly good one. Six methods in this class had wrong parameter names
	 * when it was written, and json.Unmarshal ignores fields it does not know,
	 * so every one of them would have been ACCEPTED and dropped.
	 *
	 * Only read methods. Nothing here creates, deletes, restores, unlocks,
	 * mounts or writes the config -- a diagnostic that changed the machine
	 * would be a poor thing to reach for when the machine is already suspect.
	 */
	public static int selftest(){

		stdout.printf("timeshift: IPC selftest\n\n");

		/* TIMESHIFT_SOCKET points the selftest at a daemon built from the
		 * source tree, which is the only way to check a protocol change before
		 * installing it -- and installing an unproven daemon to find out
		 * whether it works is the wrong order. It is honoured HERE and nowhere
		 * else: a variable that silently moved the GUI to another socket would
		 * be a way to operate on the wrong repository without noticing. */
		var socket = GLib.Environment.get_variable("TIMESHIFT_SOCKET");
		if (socket == null){ socket = DaemonClient.DEFAULT_SOCKET; }

		stdout.printf("  socket: %s\n\n", socket);

		var client = new DaemonClient(socket);
		if (!client.open()){
			stdout.printf("  FAIL  cannot reach the daemon at %s\n", socket);
			stdout.printf("        is timeshiftd running, and are you root?\n");
			return 1;
		}

		var api = new DaemonApi(client);
		int bad = 0;

		var info = api.system_info();
		if (info == null){
			stdout.printf("  FAIL  system.info: %s\n", api.last_error); bad++;
		} else {
			stdout.printf("  ok    system.info      version=%s protocol=%d engine=%s read_only=%s live=%s\n",
				info.version, info.protocol_version, info.engine,
				info.read_only.to_string(), info.live.to_string());
			if (info.protocol_version != DaemonClient.PROTOCOL_VERSION){
				stdout.printf("  FAIL  protocol %d, this client speaks %d\n",
					info.protocol_version, DaemonClient.PROTOCOL_VERSION);
				bad++;
			}
		}

		var status = api.repo_status();
		if (status == null){
			stdout.printf("  FAIL  repo.status: %s\n", api.last_error); bad++;
		} else {
			stdout.printf("  ok    repo.status     %s '%s' available=%s type=%s btrfs=%s\n",
				status.remote ? "remote" : "local", status.display,
				status.available.to_string(), status.type_id,
				status.btrfs_mode.to_string());
			// A status that decoded nothing at all is the silent failure this
			// whole routine exists to catch, so it is called out.
			if (status.display.length == 0 && status.device_name.length == 0){
				stdout.printf("  WARN  the location decoded empty; check the view members\n");
			}
		}

		var snapshots = api.snapshots_list();
		stdout.printf("  ok    snapshots.list  %d snapshots\n", snapshots.size);
		if (snapshots.size > 0){
			var first = snapshots.get(0);
			stdout.printf("        first: %s  tags=%s  size=%'lld  created=%s\n",
				first.name, first.tag_letters(), first.size_bytes,
				(first.created == null) ? "unparsed"
					: first.created.format("%Y-%m-%d %H:%M:%S"));
			if (first.name.length == 0){
				stdout.printf("  FAIL  a snapshot decoded with no name; check the Capitalised members\n");
				bad++;
			}
			if (first.created == null){
				stdout.printf("  FAIL  a snapshot decoded with no date\n"); bad++;
			}
		}

		var devices = api.devices_list();
		int disks = 0;
		foreach (var d in devices){ if (d.dev_type == "disk"){ disks++; } }
		stdout.printf("  ok    devices.list    %d devices, %d disks\n", devices.size, disks);
		if (devices.size > 0 && disks == 0){
			// The defect this method was widened to fix.
			stdout.printf("  FAIL  no disks: devices.list is still filtering them out\n");
			bad++;
		}

		/* The device TREE, which is what the Location page draws.
		 *
		 * Checked here rather than in the GUI because reaching that page means
		 * selecting a location, and the Settings window saves on close -- so
		 * clicking through it to look at the tree can change where the next
		 * backup goes. A diagnostic must not be able to do that.
		 *
		 * This exercises Device.get_filesystems(), which is the same call the
		 * page makes, including the pkname linking that turns a flat wire list
		 * back into disks with partitions under them. */
		var tree = Device.get_filesystems();
		int roots = 0, linked = 0, with_free = 0;
		foreach (var d in tree){
			if (d.parent == null){ roots++; }
			if (d.children.size > 0){ linked++; }
			if (d.free_bytes > 0){ with_free++; }
		}
		stdout.printf("  ok    device tree     %d devices, %d top-level, %d with children, %d with free space\n",
			tree.size, roots, linked, with_free);

		if (tree.size > 0 && linked == 0){
			// pkname did not resolve: every partition is its own island, and
			// the Location page would show partitions with no disk above them.
			stdout.printf("  FAIL  nothing is linked to a parent; check pkname\n");
			bad++;
		}
		if (tree.size > 0 && with_free == 0){
			/* Device.free_bytes returns 0 unless used_bytes is set, so a daemon
			 * that does not send it produces a tree where nothing has any free
			 * space -- silently, which is why it is worth failing on. */
			stdout.printf("  FAIL  no device reports free space; check used_bytes\n");
			bad++;
		}

		var cfg = api.config_get();
		if (cfg == null){
			stdout.printf("  FAIL  config.get: %s\n", api.last_error); bad++;
		} else {
			stdout.printf("  ok    config.get      %u keys, btrfs_mode=%s\n",
				cfg.get_size(), DaemonClient.wire_bool(cfg, "btrfs_mode", false).to_string());
		}

		var sched = api.schedule_status();
		if (sched == null){
			stdout.printf("  FAIL  schedule.status: %s\n", api.last_error); bad++;
		} else {
			stdout.printf("  ok    schedule.status enabled=%s running=%s every=%llds last=%s\n",
				sched.enabled.to_string(), sched.running.to_string(),
				sched.interval_seconds,
				(sched.last_run == null) ? "never"
					: sched.last_run.format("%Y-%m-%d %H:%M:%S"));
		}

		var recovery = api.recovery_status();
		if (recovery == null){
			stdout.printf("  FAIL  recovery.status: %s\n", api.last_error); bad++;
		} else {
			stdout.printf("  ok    recovery.status available=%s installed=%s stale=%s env=%s\n",
				recovery.available.to_string(), recovery.installed.to_string(),
				recovery.stale.to_string(), recovery.env_version);
		}

		/* A plan is a READ -- it decides everything and touches nothing -- so it
		 * belongs here, and it is the one worth proving: its wire shape is the
		 * most intricate on the protocol. */
		if (snapshots.size > 0){
			var plan = api.restore_plan(snapshots.get(0).name,
				new Gee.HashMap<string,string>(), false);
			if (plan == null){
				stdout.printf("  ok    restore.plan    refused: %s\n", api.last_error);
			} else {
				stdout.printf("  ok    restore.plan    %d rows, %d phases, blocked=%s\n",
					plan.rows.size, plan.phases.size, plan.blocked.to_string());
			}
		}

		client.close();

		stdout.printf("\n%s\n", (bad == 0) ? "selftest: PASS"
			: "selftest: %d FAILED".printf(bad));
		return (bad == 0) ? 0 : 1;
	}

}
