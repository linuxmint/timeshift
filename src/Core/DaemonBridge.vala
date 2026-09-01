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

	private DaemonClient client;

	/* Its own connection pair, not App.daemon's.
	 *
	 * DaemonClient issues exactly one jobs.subscribe on its event connection,
	 * so sharing one with MainWindow's banner poll would mean the two fighting
	 * over which job is being watched. A second client is what the two-socket
	 * design is for. */
	public string job_id { get; private set; default = ""; }
	public bool running { get; private set; default = false; }
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

	/* Attaches to a job that is already running, without starting anything. */
	public bool watch(string existing_job_id){

		if (running){ return false; }
		if (!client.open()){ return false; }

		job_id = existing_job_id;
		return start_watching(_("Attaching to the running operation..."));
	}

	private bool start_watching(string initial_text){

		/* A fresh task object, so the counters start at zero and nothing is
		 * inherited from whatever ran last. The boxes poll this; nobody
		 * executes it. */
		App.task = new RsyncTask();
		App.task.status = AppStatus.RUNNING;
		App.progress_text = initial_text;

		client.job_progress.connect(on_progress);
		client.job_counters.connect(on_counters);
		client.job_phase.connect(on_phase);
		client.job_finished.connect(on_finished);
		client.stream_closed.connect(on_stream_closed);

		running = true;
		success = false;
		message = "";

		if (!client.watch_job(job_id)){
			running = false;
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
		client.stop_watching();
		client.close();
	}

	private void on_progress(string id, double percent, int64 count,
		int64 total, int64 eta_seconds, string status_line){

		if (id != job_id){ return; }
		if (App.task == null){ return; }

		App.task.progress = percent;
		App.task.status_line = status_line;

		/* The daemon knows the remaining time; AsyncTask would otherwise
		 * compute one from its own elapsed timer, which never started because
		 * nothing here is executing. */
		if (eta_seconds >= 0){
			App.task.eta_override = TeeJee.Misc.format_duration((double) eta_seconds);
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

	private void on_phase(string id, string phase){
		if (id != job_id){ return; }
		App.restore_phase = phase;
	}

	private void on_finished(string id, string outcome, string error){

		if (id != job_id){ return; }

		// "warnings" is a real outcome and not a failure: rsync's exit 23 on a
		// running system is sockets and vanishing temp files.
		success = (outcome != "failed");
		message = error;

		if (App.task != null){
			App.task.status = success ? AppStatus.FINISHED : AppStatus.CANCELLED;
			App.task.progress = 1.0;
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

		log_error(message);
		finished(false, message);
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
