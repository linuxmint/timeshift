/*
 * DaemonBridge.vala
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

/* Runs an operation in the daemon and mirrors it into the fields the GUI
 * already polls.
 *
 * This is the shim the port needs in order to stop being two programs.
 *
 * The GTK boxes do not observe anything; they POLL. BackupBox reads
 * App.task.status_line, App.task.progress and the ten App.task.count_* fields
 * a hundred times a second from a loop on the main thread, and RestoreBox and
 * DeleteBox do the same with their own tasks. Rewriting all of that to be
 * event-driven is a large change to code that can only be judged by watching
 * it run.
 *
 * So the fields stay and the WRITER changes. App.task becomes an RsyncTask
 * that is never executed -- just a bag of numbers this class fills from the
 * daemon's event stream -- and every polling loop keeps working untouched.
 * The Vala core's implementation can then be removed method by method behind
 * the shim rather than in one step.
 *
 * Two details make it fit without any restructuring:
 *
 *   - Events arrive on the MAIN LOOP. DaemonClient.read_event_line is an async
 *     method, so its signals fire wherever the loop is pumped -- and the
 *     polling loops already call gtk_do_events() on every pass. The work
 *     happens elsewhere entirely, so there is no worker thread to spawn.
 *   - A job outlives its watcher. Closing the window does not stop the
 *     snapshot, which is the whole point of the daemon; this class detaches
 *     rather than cancelling.
 */
public class DaemonBridge : GLib.Object {

	/* Which set of fields to fill.
	 *
	 * The boxes do not share a task object: BackupBox polls App.task,
	 * DeleteBox polls App.delete_file_task and App.thread_delete_running, and
	 * EstimateBox only wants a pulsing bar. One bridge serves all of them by
	 * knowing which operation it is mirroring. */
	public enum Mode { CREATE, DELETE, ESTIMATE, RESTORE }

	private Mode mode = Mode.CREATE;
	private DaemonClient client;

	/* Its own connection pair, not App.daemon's.
	 *
	 * DaemonClient issues exactly one jobs.subscribe on its event connection,
	 * so sharing one with MainWindow's banner poll would mean the two fighting
	 * over which job is being watched. A second client is what the two-socket
	 * design is for. */
	public string job_id { get; private set; default = ""; }
	public bool running { get; private set; default = false; }

	/* The bridge currently mirroring a job, if any.
	 *
	 * A single slot rather than a list, because the daemon runs one mutating
	 * job at a time -- the same invariant that lets pausableRunner hold one
	 * process. It exists so the six places that cancel work do not each have
	 * to be handed a bridge: they ask here, and fall back to the local task
	 * when nothing is being mirrored.
	 *
	 * Without it those places call App.task.stop(), which after the migration
	 * stops a bag of numbers. The rsync it is meant to be cancelling belongs
	 * to the daemon and carries on. */
	private static unowned DaemonBridge? active_bridge = null;
	public bool success { get; private set; default = false; }
	public string message { get; private set; default = ""; }

	/* Raised when the job reaches a terminal state. A caller's polling loop
	 * usually just watches `running` instead. */
	public signal void finished(bool success, string message);

	public DaemonBridge(){
		client = new DaemonClient();
	}

	/* True when there is a daemon to hand the work to.
	 *
	 * Never required. A daemon that is absent, stopped, or speaking another
	 * protocol version is an ordinary state during the transition: the caller
	 * falls back to the Vala core and everything works as it did. */
	public bool available(){
		return (App.daemon != null);
	}

	/* Submits a snapshot and starts mirroring it.
	 *
	 * attach_existing means "if a snapshot is already running, watch that one
	 * instead of queueing a second". That is what stops a person clicking
	 * Create while apt-snapshot-guard is mid-backup from taking two copies of
	 * the same moment. */
	public bool begin_create(string comments, string[] tags, bool attach_existing = true){

		if (running){ return false; }

		if (!client.open()){
			log_debug("DaemonBridge: no daemon; the caller should use the local core");
			return false;
		}

		var params = new Json.Object();

		if (comments.length > 0){
			params.set_string_member("comments", comments);
		}
		if (tags.length > 0){
			var arr = new Json.Array();
			foreach (string t in tags){ arr.add_string_element(t); }
			params.set_array_member("tags", arr);
		}
		if (attach_existing){
			params.set_boolean_member("attach_existing", true);
		}

		var result = client.call_object("snapshot.create", params);
		if (result == null){
			log_error(_("The Timeshift service refused the request"));
			client.close();
			return false;
		}

		job_id = wire_job_id(result);
		if (job_id.length == 0){
			client.close();
			return false;
		}

		return start_watching(_("Preparing..."));
	}

	/* Submits a RESTORE and starts mirroring it.
	 *
	 * Mode.RESTORE has existed here since the bridge was written -- on_finished
	 * and on_phase both branch on it -- but nothing could ever set it except
	 * watch(), which attaches to a restore SOMEBODY ELSE started. So the bridge
	 * could show a restore and not run one, which is the shape of a capability
	 * that is declared and not implemented: worse than absent, because the code
	 * around it reads as though the path works.
	 *
	 * Three things the caller must have settled before calling:
	 *
	 * `mounts` maps a mount point to a device path or "UUID=x". An entry mapped
	 * to the empty string is deliberately left on the root filesystem, which is
	 * not the same as being absent -- absent means the plan decides.
	 *
	 * `current_system` must be asked for EXPLICITLY. Defaulting to it would
	 * mean a caller that forgot to name a target overwrites the machine it is
	 * running on, and there is no undo for that.
	 *
	 * `dry_run` compares without writing and measures the denominator a real
	 * run's progress bar needs, so the wizard runs one before the real thing
	 * and passes the count back as estimated_lines.
	 *
	 * Plan the restore first (DaemonApi.restore_plan) and show what comes back.
	 * The failure that matters here is not a crash, it is a restore that works
	 * perfectly onto the wrong disk.
	 */
	public bool begin_restore(string snapshot, Gee.Map<string,string> mounts,
		bool current_system, bool dry_run, bool skip_grub, string grub_device,
		int64 estimated_lines){

		if (running){ return false; }
		if (snapshot.length == 0){ return false; }

		if (!client.open()){
			log_debug("DaemonBridge: no daemon; the caller should use the local core");
			return false;
		}

		var params = new Json.Object();
		params.set_string_member("snapshot", snapshot);

		if (mounts.size > 0){
			var m = new Json.Object();
			foreach (var key in mounts.keys){
				m.set_string_member(key, mounts.get(key));
			}
			params.set_object_member("mounts", m);
		}

		if (current_system){ params.set_boolean_member("current_system", true); }
		if (dry_run){ params.set_boolean_member("dry_run", true); }
		if (skip_grub){ params.set_boolean_member("skip_grub", true); }
		if (grub_device.length > 0){
			params.set_string_member("grub_device", grub_device);
		}
		if (estimated_lines > 0){
			params.set_int_member("estimated_lines", estimated_lines);
		}

		var result = client.call_object("snapshot.restore", params);
		if (result == null){
			log_error(_("The Timeshift service refused the request"));
			client.close();
			return false;
		}

		job_id = wire_job_id(result);
		if (job_id.length == 0){
			client.close();
			return false;
		}

		mode = Mode.RESTORE;
		return start_watching(_("Preparing..."));
	}

	/* Submits a deletion and starts mirroring it. */
	public bool begin_delete(string[] names){

		if (running){ return false; }
		if (names.length == 0){ return false; }
		if (!client.open()){ return false; }

		var arr = new Json.Array();
		foreach (string n in names){ arr.add_string_element(n); }

		var params = new Json.Object();
		params.set_array_member("names", arr);

		var result = client.call_object("snapshot.delete", params);
		if (result == null){
			client.close();
			return false;
		}

		job_id = wire_job_id(result);
		if (job_id.length == 0){
			client.close();
			return false;
		}

		mode = Mode.DELETE;
		return start_watching(_("Preparing..."));
	}

	/* Submits a system-size estimate and starts mirroring it.
	 *
	 * The daemon persists the result to timeshift.json, because it is the
	 * progress denominator for the first real backup and recomputing it costs
	 * a full filesystem walk. So on completion this re-reads it rather than
	 * carrying the number back over the wire. */
	public bool begin_estimate(){

		if (running){ return false; }
		if (!client.open()){ return false; }

		var result = client.call_object("estimate.run", new Json.Object());
		if (result == null){
			client.close();
			return false;
		}

		job_id = wire_job_id(result);
		if (job_id.length == 0){
			client.close();
			return false;
		}

		mode = Mode.ESTIMATE;
		return start_watching(_("Estimating system size..."));
	}

	/* Attaches to a job that is already running, without starting anything.
	 *
	 * kind decides which set of fields gets filled -- a delete does not write
	 * App.task and a create does not write App.delete_file_task -- and it is
	 * the daemon's own word for what the job is, straight from jobs.list. */
	public bool watch(string existing_job_id, string kind = "create"){

		if (running){ return false; }
		if (!client.open()){ return false; }

		mode = mode_for(kind);
		job_id = existing_job_id;
		return start_watching(_("Attaching to the running operation..."));
	}

	private Mode mode_for(string kind){
		switch (kind){
		case "delete":   return Mode.DELETE;
		case "estimate": return Mode.ESTIMATE;
		case "restore":  return Mode.RESTORE;
		default:         return Mode.CREATE;
		}
	}

	private bool start_watching(string initial_text){

		/* Fresh task objects, so the counters start at zero and nothing is
		 * inherited from whatever ran last. The boxes poll these; nobody
		 * executes them. */
		if (mode == Mode.DELETE){
			App.delete_file_task = new DeleteFileTask();
			App.delete_file_task.status = AppStatus.RUNNING;
			App.thread_delete_running = true;
			App.thread_delete_success = false;
		}
		else {
			App.task = new RsyncTask();
			App.task.status = AppStatus.RUNNING;
		}

		App.progress_text = initial_text;

		client.job_progress.connect(on_progress);
		client.job_counters.connect(on_counters);
		client.job_phase.connect(on_phase);
		client.job_phases.connect(on_phases);
		client.job_finished.connect(on_finished);
		client.stream_closed.connect(on_stream_closed);

		running = true;
		success = false;
		message = "";
		active_bridge = this;

		if (!client.watch_job(job_id)){
			running = false;
			active_bridge = null;
			client.close();
			return false;
		}

		log_debug("DaemonBridge: watching %s".printf(job_id));
		return true;
	}

	/* Stops mirroring. The job keeps running: it belongs to the daemon, and a
	 * window closing must not abandon a snapshot apt is waiting for. */
	public void detach(){
		if (!running){ return; }
		running = false;
		if (active_bridge == this){ active_bridge = null; }
		client.stop_watching();
		client.close();
	}

	// -----------------------------------------------------------------------
	// Controlling the job, as opposed to watching it.
	//
	// Each returns false when there is nothing being mirrored, which is the
	// caller's signal to act on the local task instead. During the migration
	// both are real: a restore still runs in this process.

	/* Pause SUSPENDS the work: the daemon sends SIGSTOP to the job's process
	 * group. App.task.pause() sets a flag on an object nobody executes, so on
	 * a daemon job it would leave rsync copying while the window said Paused.
	 *
	 * A paused job KEEPS the repository write lock -- the only correct answer
	 * mid-write, and worth a client saying out loud. */
	public static bool pause_active(){
		return act((api, id) => api.jobs_pause(id));
	}

	public static bool resume_active(){
		return act((api, id) => api.jobs_resume(id));
	}

	public static bool cancel_active(){
		return act((api, id) => api.jobs_cancel(id));
	}

	// True when a daemon job is being mirrored, so a window can label its
	// buttons for work it does not own.
	public static bool has_active_job(){
		return (active_bridge != null) && active_bridge.running
			&& (active_bridge.job_id.length > 0);
	}

	private delegate bool JobAction(DaemonApi api, string job_id);

	private static bool act(JobAction action){

		if (!has_active_job()){ return false; }

		var api = DaemonApi.get_shared();
		if (api == null){ return false; }

		string id = active_bridge.job_id;
		if (!action(api, id)){
			log_debug("DaemonBridge: job control failed for %s: %s".printf(
				id, api.last_error));
			/* Still true: the job IS the daemon's, so falling back to
			 * stopping the local bag of numbers would be worse than
			 * reporting nothing happened. */
		}
		return true;
	}

	private void on_progress(string id, double percent, int64 count,
		int64 total, int64 eta_seconds, string status_line){

		if (id != job_id){ return; }

		/* An estimate has nothing to count -- it is a dry run whose whole
		 * output is one number at the end -- so its page pulses and there is
		 * no fraction worth writing. */
		if (mode == Mode.ESTIMATE){ return; }

		var task = (mode == Mode.DELETE)
			? (AsyncTask?) App.delete_file_task
			: (AsyncTask?) App.task;

		if (task == null){ return; }

		task.progress = percent;
		task.status_line = status_line;

		/* The counts, not just the fraction.
		 *
		 * DeleteBox picks its display from `prg_count_total > 0`: a fraction
		 * bar when it knows the denominator, a pulse when it does not. Leaving
		 * these at zero meant a daemon-driven delete always pulsed, even
		 * though the daemon had sent both numbers -- so the local path showed
		 * progress and the daemon path showed motion. */
		if (total > 0){
			task.prg_count_total = total;
			task.prg_count = count;
		}

		/* The daemon knows the remaining time; AsyncTask would otherwise
		 * compute one from its own elapsed timer, which never started because
		 * nothing here is executing. */
		if (eta_seconds >= 0){
			task.eta_override = TeeJee.Misc.format_duration((double) eta_seconds);
		}
	}

	private void on_counters(string id, Json.Object c){

		if (id != job_id){ return; }
		if (App.task == null){ return; }

		App.task.count_created     = wire_count(c, "created");
		App.task.count_deleted     = wire_count(c, "deleted");
		App.task.count_modified    = wire_count(c, "modified");
		App.task.count_unchanged   = wire_count(c, "unchanged");
		App.task.count_checksum    = wire_count(c, "checksum");
		App.task.count_size        = wire_count(c, "size");
		App.task.count_timestamp   = wire_count(c, "timestamp");
		App.task.count_permissions = wire_count(c, "permissions");
		App.task.count_owner       = wire_count(c, "owner");
		App.task.count_group       = wire_count(c, "group");
	}

	/* Builds the checklist a restore page draws.
	 *
	 * Assigned as a FRESH list, never mutated in place: RestoreBox rebuilds
	 * its checklist when App.restore_phases changes object identity, so
	 * appending to the existing one would leave the page showing the old
	 * steps forever. */
	private void on_phases(string id, Json.Array phases){

		if (id != job_id){ return; }

		var list = new Gee.ArrayList<RestorePhase>();

		foreach (var node in phases.get_elements()){
			if (node.get_node_type() != Json.NodeType.OBJECT){ continue; }
			var o = node.get_object();
			list.add(new RestorePhase(
				wire_member(o, "key"),
				wire_member(o, "title")));
		}

		if (list.size == 0){ return; }

		App.restore_phases = list;
	}

	private string wire_member(Json.Object o, string name){
		if (!o.has_member(name)){ return ""; }
		if (o.get_member(name).get_node_type() != Json.NodeType.VALUE){ return ""; }
		return o.get_string_member(name);
	}

	private void on_phase(string id, string phase){

		if (id != job_id){ return; }

		if (mode == Mode.RESTORE){
			App.restore_phase = phase;
			return;
		}

		/* A delete job's phase key IS the snapshot being removed, which is
		 * what DeleteBox's message line has always shown. */
		if (mode == Mode.DELETE){
			App.progress_text = _("Deleting snapshot") + ": %s".printf(phase);
		}
	}

	private void on_finished(string id, string outcome, string error){

		if (id != job_id){ return; }

		// "warnings" is a real outcome and not a failure: rsync's exit 23 on a
		// running system is sockets and vanishing temp files.
		success = (outcome != "failed");
		message = error;

		if (mode == Mode.DELETE){
			if (App.delete_file_task != null){
				App.delete_file_task.status = success ? AppStatus.FINISHED : AppStatus.CANCELLED;
				App.delete_file_task.progress = 1.0;
			}
			App.thread_delete_success = success;
			App.thread_delete_running = false;
		}
		else if (App.task != null){
			App.task.status = success ? AppStatus.FINISHED : AppStatus.CANCELLED;
			App.task.progress = 1.0;
		}

		/* The daemon wrote the estimate into timeshift.json, because it is the
		 * denominator for the first real backup. Read it back rather than
		 * carrying the number over the wire a second time. */
		if (success && (mode == Mode.ESTIMATE)){
			reload_estimate();
		}

		/* "warnings" is a real outcome and not a failure -- rsync's exit 23 on
		 * a running system is sockets and files that vanished mid-copy -- and
		 * the restore summary distinguishes the three. */
		if (mode == Mode.RESTORE){
			switch (outcome){
			case "ok":       App.restore_outcome = Main.RestoreOutcome.OK;       break;
			case "warnings": App.restore_outcome = Main.RestoreOutcome.WARNINGS; break;
			default:         App.restore_outcome = Main.RestoreOutcome.FAILED;   break;
			}
			if (message.length > 0){
				App.restore_outcome_messages.add(message);
			}
		}

		App.progress_text = "";

		running = false;
		client.stop_watching();
		client.close();

		log_debug("DaemonBridge: %s finished (%s)".printf(job_id, outcome));
		finished(success, message);
	}

	private void on_stream_closed(){

		if (!running){ return; }

		/* The connection dropped while the job was still going. The job is
		 * almost certainly fine -- it belongs to the daemon -- but this class
		 * can no longer say so, and reporting success on no evidence is worse
		 * than reporting that we lost sight of it. */
		success = false;
		message = _("Lost contact with the Timeshift service");
		running = false;

		// A delete page waits on this flag; leaving it set would hang the page
		// on a job it can no longer see.
		if (mode == Mode.DELETE){
			App.thread_delete_success = false;
			App.thread_delete_running = false;
		}

		log_error(message);
		finished(false, message);
	}

	/* Re-reads the estimate the daemon just saved. */
	private void reload_estimate(){

		var cfg = client.call_object("config.get", new Json.Object());
		if (cfg == null){ return; }

		if (cfg.has_member("snapshot_size")){
			Main.first_snapshot_size = (uint64) int64.parse(
				cfg.get_string_member("snapshot_size"));
		}
		if (cfg.has_member("snapshot_count")){
			Main.first_snapshot_count = int64.parse(
				cfg.get_string_member("snapshot_count"));
		}

		log_debug("DaemonBridge: estimate %lld bytes".printf(
			(int64) Main.first_snapshot_size));
	}

	private string wire_job_id(Json.Object result){
		if (result.has_member("job") &&
			(result.get_member("job").get_node_type() == Json.NodeType.VALUE)){
			return result.get_string_member("job");
		}
		return "";
	}

	private int64 wire_count(Json.Object c, string name){
		if (!c.has_member(name)){ return 0; }
		if (c.get_member(name).get_node_type() != Json.NodeType.VALUE){ return 0; }
		return c.get_int_member(name);
	}
}
