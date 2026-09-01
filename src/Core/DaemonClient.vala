/*
 * DaemonClient.vala
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
using TeeJee.FileSystem;
using TeeJee.Misc;

/* The client side of the timeshiftd socket.
 *
 * One JSON object per line in each direction over a unix socket. There is no
 * bus: the GUI runs as root under pkexec, where a session bus is usually
 * absent, and the recovery environment has none at all.
 *
 * TWO connections, deliberately.
 *
 * A response and an event look different on the wire -- a response carries the
 * request's "id", an event carries "event" and no id -- so one connection could
 * carry both. But then every synchronous call would have to read past any
 * events that happened to arrive first and queue them, and a bug in that
 * interleaving shows up as a call returning another call's answer. Two
 * connections make the question not arise: `conn` does request/response and
 * nothing else, `event_conn` issues one jobs.subscribe and then only ever
 * reads. The daemon supports as many connections as clients care to open.
 *
 * Nothing here throws. A daemon that is not installed, not running, or not
 * reachable is an ordinary situation during the transition -- the Vala core
 * still works on its own -- so every method reports failure by returning false
 * and the caller carries on without the daemon.
 */
public class DaemonClient : GLib.Object {

	public const string DEFAULT_SOCKET = "/run/timeshift/daemon.sock";

	// The wire format this client understands. system.info reports the
	// daemon's; a mismatch means refusing rather than misreading.
	public const int PROTOCOL_VERSION = 1;

	private string socket_path = "";

	private SocketConnection? conn = null;
	private DataInputStream? conn_in = null;
	private DataOutputStream? conn_out = null;

	private SocketConnection? event_conn = null;
	private DataInputStream? event_in = null;

	private int64 next_id = 0;

	public bool connected { get; private set; default = false; }
	public bool watching { get; private set; default = false; }

	public string daemon_version = "";

	/* Signals carrying what the event stream says.
	 *
	 * These are raised from an async read callback on the main context, so a
	 * handler may touch widgets directly. */
	public signal void job_started(string job_id, string kind);
	public signal void job_phase(string job_id, string phase);
	public signal void job_progress(string job_id, double percent, int64 count,
		int64 total, int64 eta_seconds, string status_line);
	public signal void job_log(string job_id, string line);
	public signal void job_finished(string job_id, string outcome, string error);

	// Raised when the event connection drops, so a window can stop pretending
	// it is showing live data.
	public signal void stream_closed();

	public DaemonClient(string path = DEFAULT_SOCKET){
		this.socket_path = path;
	}

	// open connects the request/response channel and checks the protocol.
	public bool open(){

		if (connected){ return true; }

		conn = connect_socket();
		if (conn == null){ return false; }

		conn_in = new DataInputStream(conn.input_stream);
		conn_out = new DataOutputStream(conn.output_stream);
		connected = true;

		Json.Object? info = call_object("system.info", null);
		if (info == null){
			log_debug("DaemonClient: system.info failed; treating the daemon as absent");
			close();
			return false;
		}

		int version = (int) wire_int(info, "protocol_version", 0);
		if (version != PROTOCOL_VERSION){
			log_error(_("The Timeshift daemon speaks a different protocol version") +
				": %d (expected %d)".printf(version, PROTOCOL_VERSION));
			close();
			return false;
		}

		daemon_version = wire_string(info, "version", "");
		log_debug("DaemonClient: connected to timeshiftd %s".printf(daemon_version));
		return true;
	}

	public void close(){
		stop_watching();

		try { if (conn != null){ conn.close(); } }
		catch (Error e) { log_debug("DaemonClient: %s".printf(e.message)); }

		conn = null;
		conn_in = null;
		conn_out = null;
		connected = false;
	}

	private SocketConnection? connect_socket(){

		// An absent socket is the normal case on a machine where the daemon is
		// not running. Checking first keeps the log free of a connection error
		// on every start.
		if (!file_exists(socket_path)){
			return null;
		}

		try {
			var client = new SocketClient();
			var address = new UnixSocketAddress(socket_path);
			return client.connect(address, null);
		}
		catch (Error e) {
			log_debug("DaemonClient: cannot connect to %s: %s".printf(socket_path, e.message));
			return null;
		}
	}

	// call sends a request and returns the "result" node, or null on failure.
	public Json.Node? call(string method, Json.Object? params, out string error){

		error = "";

		if (!connected){
			error = _("Not connected to the Timeshift daemon");
			return null;
		}

		var request = new Json.Object();
		request.set_int_member("id", ++next_id);
		request.set_string_member("method", method);
		if (params != null){
			request.set_object_member("params", params);
		}

		try {
			conn_out.put_string(object_to_line(request));
			conn_out.flush();
		}
		catch (Error e) {
			error = e.message;
			close();
			return null;
		}

		string? line = null;
		try {
			line = conn_in.read_line_utf8(null);
		}
		catch (Error e) {
			error = e.message;
			close();
			return null;
		}

		if (line == null){
			error = _("The Timeshift daemon closed the connection");
			close();
			return null;
		}

		var parser = new Json.Parser();
		try { parser.load_from_data(line, -1); }
		catch (Error e) {
			error = e.message;
			return null;
		}

		var root = parser.get_root();
		if ((root == null) || (root.get_node_type() != Json.NodeType.OBJECT)){
			error = _("Unexpected reply from the Timeshift daemon");
			return null;
		}

		var obj = root.get_object();

		if (obj.has_member("error") &&
			(obj.get_member("error").get_node_type() == Json.NodeType.OBJECT)){

			var err = obj.get_object_member("error");
			error = wire_string(err, "message", _("The Timeshift daemon reported an error"));
			return null;
		}

		if (!obj.has_member("result")){
			return null;
		}
		return obj.get_member("result");
	}

	// call_object is call() for the common case of an object result.
	public Json.Object? call_object(string method, Json.Object? params){
		string error;
		var node = call(method, params, out error);
		if ((node == null) || (node.get_node_type() != Json.NodeType.OBJECT)){
			if (error.length > 0){
				log_debug("DaemonClient: %s: %s".printf(method, error));
			}
			return null;
		}
		return node.get_object();
	}

	/* The job the daemon is running now, if any.
	 *
	 * This is what makes "open the GUI while apt is taking a snapshot" work:
	 * before the Vala core decides it is the only Timeshift on the machine, ask
	 * the daemon whether something is already under way. */
	public bool running_job(out string job_id, out string kind){

		job_id = "";
		kind = "";

		string error;
		var node = call("jobs.list", null, out error);
		if ((node == null) || (node.get_node_type() != Json.NodeType.ARRAY)){
			return false;
		}

		foreach (var item in node.get_array().get_elements()){
			if (item.get_node_type() != Json.NodeType.OBJECT){ continue; }
			var job = item.get_object();

			string state = wire_string(job, "state", "");
			if ((state != "running") && (state != "paused") && (state != "queued")){
				continue;
			}

			job_id = wire_string(job, "id", "");
			kind = wire_string(job, "kind", "");
			return (job_id.length > 0);
		}

		return false;
	}

	/* Attach to a job and follow it.
	 *
	 * The daemon answers jobs.subscribe with the job's state as it is right
	 * now -- phases, counters, the tail of the log -- and only then starts
	 * streaming, with the subscription registered before that snapshot is
	 * taken. So there is no gap, and joining halfway looks exactly like having
	 * been there from the start. */
	public bool watch_job(string job_id, bool with_log = false){

		if (watching){ stop_watching(); }

		event_conn = connect_socket();
		if (event_conn == null){ return false; }

		event_in = new DataInputStream(event_conn.input_stream);
		var event_out = new DataOutputStream(event_conn.output_stream);

		var params = new Json.Object();
		if (job_id.length > 0){
			params.set_string_member("job", job_id);
		}
		if (with_log){
			params.set_boolean_member("with_log", true);
		}

		var request = new Json.Object();
		request.set_int_member("id", 1);
		request.set_string_member("method", "jobs.subscribe");
		request.set_object_member("params", params);

		try {
			event_out.put_string(object_to_line(request));
			event_out.flush();
		}
		catch (Error e) {
			log_error("DaemonClient: jobs.subscribe: %s".printf(e.message));
			stop_watching();
			return false;
		}

		watching = true;
		read_event_line.begin();
		return true;
	}

	public void stop_watching(){

		watching = false;

		try { if (event_conn != null){ event_conn.close(); } }
		catch (Error e) { log_debug("DaemonClient: %s".printf(e.message)); }

		event_conn = null;
		event_in = null;
	}

	/* The event reader.
	 *
	 * One async read at a time, re-armed from its own callback. That keeps the
	 * whole stream on the main context: a handler can touch widgets without
	 * any locking, which is the same threading model every other Box in this
	 * app already assumes. */
	private async void read_event_line(){

		while (watching && (event_in != null)){

			string? line = null;

			try {
				line = yield event_in.read_line_utf8_async(Priority.DEFAULT, null, null);
			}
			catch (Error e) {
				if (watching){
					log_debug("DaemonClient: event stream: %s".printf(e.message));
				}
				break;
			}

			if (line == null){ break; }
			if (line.strip().length == 0){ continue; }

			dispatch_event(line);
		}

		if (watching){
			watching = false;
			stream_closed();
		}
	}

	private void dispatch_event(string line){

		var parser = new Json.Parser();
		try { parser.load_from_data(line, -1); }
		catch (Error e) {
			log_debug("DaemonClient: unparseable event: %s".printf(e.message));
			return;
		}

		var root = parser.get_root();
		if ((root == null) || (root.get_node_type() != Json.NodeType.OBJECT)){ return; }

		var obj = root.get_object();

		// The reply to jobs.subscribe itself: the job's state as it stands.
		// It carries an id and no "event", and is what a late joiner draws
		// before the first live event arrives.
		if (!obj.has_member("event")){
			if (obj.has_member("result") &&
				(obj.get_member("result").get_node_type() == Json.NodeType.OBJECT)){
				dispatch_snapshot(obj.get_object_member("result"));
			}
			return;
		}

		string kind = wire_string(obj, "event", "");
		string job_id = wire_string(obj, "job", "");

		switch (kind){
		case "job.started":
			job_started(job_id, wire_string(obj, "state", ""));
			break;

		case "job.phase":
			job_phase(job_id, wire_string(obj, "phase", ""));
			break;

		case "job.progress":
			if (obj.has_member("progress") &&
				(obj.get_member("progress").get_node_type() == Json.NodeType.OBJECT)){
				emit_progress(job_id, obj.get_object_member("progress"));
			}
			break;

		case "job.log":
			job_log(job_id, wire_string(obj, "line", ""));
			break;

		case "job.finished":
			job_finished(job_id,
				wire_string(obj, "outcome", ""),
				wire_string(obj, "error", ""));
			break;
		}
	}

	// dispatch_snapshot replays a job's current state as though it had just
	// been streamed, so a joiner and a follower go through the same code.
	private void dispatch_snapshot(Json.Object job){

		string job_id = wire_string(job, "id", "");
		if (job_id.length == 0){ return; }

		job_started(job_id, wire_string(job, "kind", ""));

		string phase = wire_string(job, "phase", "");
		if (phase.length > 0){
			job_phase(job_id, phase);
		}

		if (job.has_member("progress") &&
			(job.get_member("progress").get_node_type() == Json.NodeType.OBJECT)){
			emit_progress(job_id, job.get_object_member("progress"));
		}

		if (job.has_member("log_tail") &&
			(job.get_member("log_tail").get_node_type() == Json.NodeType.ARRAY)){
			foreach (var item in job.get_array_member("log_tail").get_elements()){
				job_log(job_id, item.get_string());
			}
		}

		string state = wire_string(job, "state", "");
		if ((state == "finished") || (state == "failed") || (state == "cancelled")){
			job_finished(job_id,
				wire_string(job, "outcome", ""),
				wire_string(job, "error", ""));
		}
	}

	private void emit_progress(string job_id, Json.Object p){
		job_progress(
			job_id,
			wire_double(p, "percent", 0),
			wire_int(p, "count", 0),
			wire_int(p, "total", 0),
			wire_int(p, "eta_seconds", 0),
			wire_string(p, "status_line", ""));
	}

	/* Reading the wire, which is NOT the dialect the rest of this codebase
	 * reads.
	 *
	 * timeshift.json and info.json store every value as a JSON *string*
	 * ("true", "5"), and TeeJee.JsonHelper's json_get_* exist for exactly that:
	 * each one calls get_string_member and parses. The socket protocol uses
	 * real JSON types, so those helpers would read a number as a string and
	 * come back with nothing.
	 *
	 * Hence these. They also tolerate either representation, because being
	 * strict about it would buy nothing and a null member is an ordinary event
	 * on a wire where empty fields are omitted. */

	private string wire_string(Json.Object obj, string member, string def_value){
		if (!obj.has_member(member)){ return def_value; }
		var node = obj.get_member(member);
		if (node.get_node_type() != Json.NodeType.VALUE){ return def_value; }
		string? val = node.get_string();
		return (val == null) ? def_value : val;
	}

	private int64 wire_int(Json.Object obj, string member, int64 def_value){
		if (!obj.has_member(member)){ return def_value; }
		var node = obj.get_member(member);
		if (node.get_node_type() != Json.NodeType.VALUE){ return def_value; }
		if (node.get_value_type() == typeof(string)){
			return int64.parse(node.get_string());
		}
		return node.get_int();
	}

	private double wire_double(Json.Object obj, string member, double def_value){
		if (!obj.has_member(member)){ return def_value; }
		var node = obj.get_member(member);
		if (node.get_node_type() != Json.NodeType.VALUE){ return def_value; }
		if (node.get_value_type() == typeof(string)){
			return double.parse(node.get_string());
		}
		if (node.get_value_type() == typeof(int64)){
			return (double) node.get_int();
		}
		return node.get_double();
	}

	private string object_to_line(Json.Object obj){
		var node = new Json.Node(Json.NodeType.OBJECT);
		node.set_object(obj);

		var generator = new Json.Generator();
		generator.set_root(node);
		generator.pretty = false;

		return generator.to_data(null) + "\n";
	}
}
