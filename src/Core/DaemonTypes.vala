/*
 * DaemonTypes.vala
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

/* What the daemon says, as objects rather than Json.Object.
 *
 * These are DATA. They do no work, own no connection and reach no global: a
 * DaemonSnapshot cannot delete itself the way Core/Snapshot.vala can, and a
 * DaemonDevice cannot mount itself the way Utility/Device.vala can. That is the
 * whole point -- the operations live in the daemon now, and what crosses the
 * socket is a description of the system rather than a handle on it.
 *
 * They are GObjects because the GTK4 list widgets hold their model objects
 * directly: Gtk.ListView over a GLib.ListStore needs a GObject, and the
 * migration ends with these going into the stores that Snapshot and Device sit
 * in today.
 *
 * Every field is filled through DaemonClient's wire_* readers, which default
 * rather than fail. A daemon one version ahead may send members these classes
 * do not know, and one version behind may omit members they do -- neither is an
 * error, and a client that refused to parse would be unable to report the
 * version mismatch it exists to detect.
 */

// ---------------------------------------------------------------------------

/* Timestamps.
 *
 * Go marshals time.Time as RFC 3339, and its ZERO value marshals as
 * "0001-01-01T00:00:00Z" rather than being omitted. Read naively that is a real
 * date in the year 1, which sorts before everything and reads in the UI as a
 * snapshot taken two thousand years ago. Every "never happened" field on this
 * wire -- schedule.status's last_run above all -- arrives that way, so the
 * check belongs here rather than in each caller.
 */
public class DaemonTime : GLib.Object {

	// The year Go's zero time falls in. Nothing real is dated from it.
	private const int GO_ZERO_YEAR = 1;

	/* Parse an RFC 3339 timestamp, or null for "never".
	 *
	 * Null rather than a sentinel date: a caller has to decide what to display
	 * for "never", and a date it must remember to compare against would be
	 * forgotten exactly once. */
	public static DateTime? parse(string text){

		if (text.length == 0){ return null; }

		var dt = new DateTime.from_iso8601(text, null);
		if (dt == null){
			log_debug("DaemonTime: cannot parse '%s'".printf(text));
			return null;
		}
		if (dt.get_year() <= GO_ZERO_YEAR){ return null; }
		return dt;
	}
}

// ---------------------------------------------------------------------------

// DaemonSystemInfo is the handshake: who the daemon is and what it will let us do.
public class DaemonSystemInfo : GLib.Object {

	public string version { get; set; default = ""; }
	public int protocol_version { get; set; default = 0; }
	public string engine { get; set; default = ""; }

	/* read_only is about THIS connection, not the daemon.
	 *
	 * Access is decided from the peer credentials on the socket: root gets
	 * everything, a member of the timeshift group gets the read-only subset. So
	 * the same daemon answers differently depending on who asked, and a client
	 * that hides its write actions must ask rather than assume. */
	public bool read_only { get; set; default = false; }

	// The job running now, or "". Empty is the ordinary case.
	public string active_job { get; set; default = ""; }

	/* live means the daemon is running on a booted-from-media session.
	 *
	 * A recovery environment carries the real config, so without this a
	 * scheduled backup would snapshot the ramdisk into the real repository and
	 * then run retention against it. */
	public bool live { get; set; default = false; }

	public static DaemonSystemInfo from_wire(Json.Object o){
		var info = new DaemonSystemInfo();
		info.version          = DaemonClient.wire_string(o, "version", "");
		info.protocol_version = (int) DaemonClient.wire_int(o, "protocol_version", 0);
		info.engine           = DaemonClient.wire_string(o, "engine", "");
		info.read_only        = DaemonClient.wire_bool(o, "read_only", false);
		info.active_job       = DaemonClient.wire_string(o, "active_job", "");
		info.live             = DaemonClient.wire_bool(o, "live", false);
		return info;
	}
}

// ---------------------------------------------------------------------------

/* DaemonDevice is one row of devices.list.
 *
 * Flat, with pkname naming the parent, because that is how the daemon sends it:
 * a Gtk.TreeListModel asks for a row's children lazily, so nested JSON would
 * only have to be taken apart again.
 */
public class DaemonDevice : GLib.Object {

	public string path { get; set; default = ""; }      // /dev/nvme0n1p2
	public string name { get; set; default = ""; }
	public string kname { get; set; default = ""; }
	public string pkname { get; set; default = ""; }    // "" for a top-level device
	public string uuid { get; set; default = ""; }
	public string label { get; set; default = ""; }
	public string partlabel { get; set; default = ""; }
	public string dev_type { get; set; default = ""; }  // disk, part, crypt, lvm, loop
	public string fstype { get; set; default = ""; }
	public string vendor { get; set; default = ""; }
	public string model { get; set; default = ""; }

	public string serial { get; set; default = ""; }
	public string revision { get; set; default = ""; }

	public int64 size_bytes { get; set; default = 0; }
	public int64 free_bytes { get; set; default = 0; }

	/* used_bytes is sent because it cannot be derived.
	 *
	 * size is the partition; used and free come from statfs and do not add up
	 * to it, because of the reserved blocks in between. It is also how an
	 * UNMOUNTED device is told from a full one -- neither has free space, but
	 * only a mounted one has used space. */
	public int64 used_bytes { get; set; default = 0; }

	public bool mounted { get; set; default = false; }

	/* Whether the daemon sent used_bytes at all.
	 *
	 * Same rule as repo.status's free_bytes, and the same reason: the field was
	 * added additively, JSON drops what it does not know, and Device.free_bytes
	 * returns 0 whenever used_bytes is 0 -- so an older daemon would produce a
	 * device list where nothing has any free space, with no error anywhere. */
	public bool has_used_bytes { get; set; default = false; }

	public bool read_only { get; set; default = false; }
	public bool removable { get; set; default = false; }

	/* The rule the console listing filters on, reported rather than applied.
	 *
	 * A disk carries no filesystem, so filtering on this daemon-side removed
	 * every disk -- and a device tree with no disks has nothing for the
	 * partitions to hang from. Clients drawing a listing apply it; clients
	 * drawing a tree do not. */
	public bool has_linux_filesystem { get; set; default = false; }

	public Gee.ArrayList<string> mount_points { get; private set;
		default = new Gee.ArrayList<string>(); }

	public static DaemonDevice from_wire(Json.Object o){
		var d = new DaemonDevice();
		d.path       = DaemonClient.wire_string(o, "path", "");
		d.name       = DaemonClient.wire_string(o, "name", "");
		d.kname      = DaemonClient.wire_string(o, "kname", "");
		d.pkname     = DaemonClient.wire_string(o, "pkname", "");
		d.uuid       = DaemonClient.wire_string(o, "uuid", "");
		d.label      = DaemonClient.wire_string(o, "label", "");
		d.partlabel  = DaemonClient.wire_string(o, "partlabel", "");
		d.dev_type   = DaemonClient.wire_string(o, "type", "");
		d.fstype     = DaemonClient.wire_string(o, "fstype", "");
		d.vendor     = DaemonClient.wire_string(o, "vendor", "");
		d.model      = DaemonClient.wire_string(o, "model", "");
		d.serial     = DaemonClient.wire_string(o, "serial", "");
		d.revision   = DaemonClient.wire_string(o, "revision", "");
		d.size_bytes = DaemonClient.wire_int(o, "size_bytes", 0);
		d.free_bytes = DaemonClient.wire_int(o, "free_bytes", 0);
		d.used_bytes = DaemonClient.wire_int(o, "used_bytes", 0);
		d.has_used_bytes = o.has_member("used_bytes");
		d.mounted    = DaemonClient.wire_bool(o, "mounted", false);
		d.read_only  = DaemonClient.wire_bool(o, "read_only", false);
		d.removable  = DaemonClient.wire_bool(o, "removable", false);
		d.has_linux_filesystem = DaemonClient.wire_bool(o, "has_linux_filesystem", false);

		if (o.has_member("mount_points") &&
			(o.get_member("mount_points").get_node_type() == Json.NodeType.ARRAY)){
			foreach (var node in o.get_array_member("mount_points").get_elements()){
				if (node.get_node_type() == Json.NodeType.VALUE){
					var mp = node.get_string();
					if (mp != null){ d.mount_points.add(mp); }
				}
			}
		}
		return d;
	}

	// The description a disk row shows: "Samsung SSD 970 EVO Plus 500GB", or
	// the device name when the drive reported nothing useful.
	public string description(){
		var text = "%s %s".printf(vendor, model).strip();
		return (text.length > 0) ? text : name;
	}
}

// ---------------------------------------------------------------------------

/* DaemonRepoStatus is the repository's health AND how to describe it.
 *
 * The two travel together in one reply on purpose: `timeshift --list` renders
 * them as a single header block, and splitting them across two calls would let
 * the header be drawn from two repository states observed a moment apart.
 *
 * The `view` half is engine-shaped -- the daemon sends it as raw JSON that only
 * the engine's own type fully describes -- so what is read out here is the
 * subset every engine has answered with so far. An engine that adds fields does
 * not break this; one that renames these does, which is what the protocol
 * version is for.
 */
public class DaemonRepoStatus : GLib.Object {

	public int code { get; set; default = 0; }
	public string message { get; set; default = ""; }
	public string details { get; set; default = ""; }
	public bool available { get; set; default = false; }
	public bool has_snapshots { get; set; default = false; }

	// The view.
	public bool remote { get; set; default = false; }
	public string display { get; set; default = ""; }   // "osouf@host" or a device name
	public string path { get; set; default = ""; }
	public string type_id { get; set; default = ""; }   // remote-ssh-rsync, local-rsync, ...
	public bool btrfs_mode { get; set; default = false; }
	public string device_name { get; set; default = ""; }
	public string device_uuid { get; set; default = ""; }

	/* The numbers behind `details`, as numbers.
	 *
	 * `details` is "29 snapshots, 29.9 TB free" -- the whole answer for a
	 * console header. A GUI has to compare free space against a snapshot's size
	 * and render its own units, and parsing that string back into a number is
	 * the sort of thing that works until a unit or a locale changes. */
	public int64 free_bytes { get; set; default = 0; }
	public int snapshot_count { get; set; default = 0; }

	/* Whether the daemon SENT free_bytes, as opposed to sending zero.
	 *
	 * The two are not the same answer and the difference matters. A daemon
	 * older than the field omits it, and a caller that read the default would
	 * report a healthy 30 TB repository as having no space -- confidently,
	 * because the status call itself succeeded. Protocol version cannot catch
	 * this: the field was added additively, and JSON drops what it does not
	 * know rather than complaining. So the client asks whether the answer was
	 * given, and falls back to measuring locally when it was not. */
	public bool has_free_bytes { get; set; default = false; }

	public static DaemonRepoStatus from_wire(Json.Object o){
		var st = new DaemonRepoStatus();
		st.code          = (int) DaemonClient.wire_int(o, "code", 0);
		st.message       = DaemonClient.wire_string(o, "message", "");
		st.details       = DaemonClient.wire_string(o, "details", "");
		st.available     = DaemonClient.wire_bool(o, "available", false);
		st.has_snapshots = DaemonClient.wire_bool(o, "has_snapshots", false);

		if (o.has_member("view") &&
			(o.get_member("view").get_node_type() == Json.NodeType.OBJECT)){
			var v = o.get_object_member("view");
			st.remote      = DaemonClient.wire_bool(v, "remote", false);
			st.display     = DaemonClient.wire_string(v, "display", "");
			st.path        = DaemonClient.wire_string(v, "path", "");
			st.type_id     = DaemonClient.wire_string(v, "type_id", "");
			st.btrfs_mode  = DaemonClient.wire_bool(v, "btrfs_mode", false);
			st.device_name = DaemonClient.wire_string(v, "device_name", "");
			st.device_uuid = DaemonClient.wire_string(v, "device_uuid", "");
			st.free_bytes  = DaemonClient.wire_int(v, "free_bytes", 0);
			st.has_free_bytes = v.has_member("free_bytes");
			st.snapshot_count = (int) DaemonClient.wire_int(v, "snapshot_count", 0);
		}
		return st;
	}
}

// ---------------------------------------------------------------------------

/* DaemonSnapshot is one snapshot as the daemon describes it.
 *
 * The member names are capitalised because the Go type carries no JSON tags and
 * marshals its field names verbatim. That is a wire fact, not a style choice --
 * reading "name" here returns nothing.
 */
public class DaemonSnapshot : GLib.Object {

	public string name { get; set; default = ""; }        // 2026-09-01_10-00-00
	public string path { get; set; default = ""; }
	public DateTime? created { get; set; default = null; }
	public string description { get; set; default = ""; }

	public string sys_uuid { get; set; default = ""; }
	public string sys_distro { get; set; default = ""; }
	public string app_version { get; set; default = ""; }

	public int64 file_count { get; set; default = 0; }
	public int64 size_bytes { get; set; default = 0; }
	public int64 unshared_bytes { get; set; default = 0; }

	/* live marks the system that a restore moved aside.
	 *
	 * A btrfs restore does not delete the subvolumes it replaces, it renames
	 * them into a snapshot marked this way -- so a restore that turns out to
	 * be the wrong choice can itself be undone. */
	public bool live { get; set; default = false; }

	/* An INVALID snapshot is one that could not be dated or read.
	 *
	 * It is never pruned without positive evidence that it is incomplete, and
	 * it does not count towards a retention level's limit -- counting one
	 * inflates the total and can delete a good snapshot to make room for a
	 * broken one. */
	public bool valid { get; set; default = true; }
	public bool marked_for_deletion { get; set; default = false; }

	public Gee.ArrayList<string> tags { get; private set;
		default = new Gee.ArrayList<string>(); }

	public static DaemonSnapshot from_wire(Json.Object o){
		var s = new DaemonSnapshot();
		s.name           = DaemonClient.wire_string(o, "Name", "");
		s.path           = DaemonClient.wire_string(o, "Path", "");
		s.created        = DaemonTime.parse(DaemonClient.wire_string(o, "Created", ""));
		s.description    = DaemonClient.wire_string(o, "Description", "");
		s.sys_uuid       = DaemonClient.wire_string(o, "SysUUID", "");
		s.sys_distro     = DaemonClient.wire_string(o, "SysDistro", "");
		s.app_version    = DaemonClient.wire_string(o, "AppVersion", "");
		s.file_count     = DaemonClient.wire_int(o, "FileCount", 0);
		s.size_bytes     = DaemonClient.wire_int(o, "SizeBytes", 0);
		s.unshared_bytes = DaemonClient.wire_int(o, "UnsharedBytes", 0);
		s.live           = DaemonClient.wire_bool(o, "Live", false);
		s.valid          = DaemonClient.wire_bool(o, "Valid", true);
		s.marked_for_deletion = DaemonClient.wire_bool(o, "MarkedForDeletion", false);

		if (o.has_member("Tags") &&
			(o.get_member("Tags").get_node_type() == Json.NodeType.ARRAY)){
			foreach (var node in o.get_array_member("Tags").get_elements()){
				if (node.get_node_type() == Json.NodeType.VALUE){
					var tag = node.get_string();
					if (tag != null){ s.tags.add(tag); }
				}
			}
		}
		return s;
	}

	/* The O/B/H/D/W/M letters the list column shows.
	 *
	 * Built from the level names the daemon sends rather than stored, because
	 * tags and retention are Timeshift policy and the daemon reports the levels
	 * a snapshot holds, not their presentation. */
	public string tag_letters(){
		var text = "";
		foreach (var tag in tags){
			switch (tag){
				case "ondemand": text += "O"; break;
				case "boot":     text += "B"; break;
				case "hourly":   text += "H"; break;
				case "daily":    text += "D"; break;
				case "weekly":   text += "W"; break;
				case "monthly":  text += "M"; break;
			}
		}
		return text;
	}
}

// ---------------------------------------------------------------------------

/* DaemonScheduleStatus is what replaced being able to look in /etc/cron.d.
 *
 * Losing cron lost a real safety net: it ran whether or not our code was
 * healthy, and a dead timeshiftd now means no snapshots with nothing to notice.
 * This is the replacement -- it reports whether the loop is alive at all, when
 * it last ran and what it decided.
 */
public class DaemonScheduleStatus : GLib.Object {

	public bool enabled { get; set; default = false; }
	public bool running { get; set; default = false; }
	public DateTime? last_run { get; set; default = null; }   // null = never
	public DateTime? next_run { get; set; default = null; }
	public int64 interval_seconds { get; set; default = 0; }

	public static DaemonScheduleStatus from_wire(Json.Object o){
		var st = new DaemonScheduleStatus();
		st.enabled          = DaemonClient.wire_bool(o, "enabled", false);
		st.running          = DaemonClient.wire_bool(o, "running", false);
		st.last_run         = DaemonTime.parse(DaemonClient.wire_string(o, "last_run", ""));
		st.next_run         = DaemonTime.parse(DaemonClient.wire_string(o, "next_run", ""));
		st.interval_seconds = DaemonClient.wire_int(o, "interval_seconds", 0);
		return st;
	}
}

// ---------------------------------------------------------------------------

// DaemonRecoveryStatus mirrors `timeshift-recovery status --machine`.
public class DaemonRecoveryStatus : GLib.Object {

	public bool available { get; set; default = false; }  // the tool is installed
	public bool installed { get; set; default = false; }  // an environment exists
	public bool disabled { get; set; default = false; }
	public bool stale { get; set; default = false; }      // built from an older Timeshift

	public string host_version { get; set; default = ""; }
	public string env_version { get; set; default = ""; }
	public string target { get; set; default = ""; }

	// The tool's own key=value output, for the fields no property names.
	public Gee.HashMap<string,string> fields { get; private set;
		default = new Gee.HashMap<string,string>(); }

	public static DaemonRecoveryStatus from_wire(Json.Object o){
		var st = new DaemonRecoveryStatus();
		st.available    = DaemonClient.wire_bool(o, "available", false);
		st.installed    = DaemonClient.wire_bool(o, "installed", false);
		st.disabled     = DaemonClient.wire_bool(o, "disabled", false);
		st.stale        = DaemonClient.wire_bool(o, "stale", false);
		st.host_version = DaemonClient.wire_string(o, "host_version", "");
		st.env_version  = DaemonClient.wire_string(o, "env_version", "");
		st.target       = DaemonClient.wire_string(o, "target", "");

		if (o.has_member("fields") &&
			(o.get_member("fields").get_node_type() == Json.NodeType.OBJECT)){
			var f = o.get_object_member("fields");
			foreach (var key in f.get_members()){
				st.fields.set(key, DaemonClient.wire_string(f, key, ""));
			}
		}
		return st;
	}
}

// ---------------------------------------------------------------------------

/* DaemonRestorePlanRow is one mount point in a restore plan.
 *
 * `blocking` is separate from `status` because a row can be worth showing and
 * still not be a reason to refuse: a plan lists what would happen at every
 * mount point, and only some of those findings stop the restore.
 */
public class DaemonRestorePlanRow : GLib.Object {

	public string mount_point { get; set; default = ""; }
	public string device { get; set; default = ""; }
	public string status { get; set; default = ""; }
	public bool blocking { get; set; default = false; }

	public static DaemonRestorePlanRow from_wire(Json.Object o){
		var r = new DaemonRestorePlanRow();
		r.mount_point = DaemonClient.wire_string(o, "mount_point", "");
		r.device      = DaemonClient.wire_string(o, "device", "");
		r.status      = DaemonClient.wire_string(o, "status", "");
		r.blocking    = DaemonClient.wire_bool(o, "blocking", false);
		return r;
	}
}

/* DaemonRestorePlan decides everything and touches nothing.
 *
 * That separation is not decoration. The failure that matters in a restore is
 * not a crash, it is a restore that works perfectly onto the wrong disk, and a
 * person recognising the disk in a list is the only thing that catches it. So
 * the plan can be shown before anything is written.
 *
 * `phases` is the checklist the progress UI will tick off, and it comes from
 * here rather than from a constant so that the steps listed are exactly the
 * steps that will run -- a btrfs restore runs neither grub nor initramfs, and
 * a list that promised them would be describing a different restore.
 */
public class DaemonRestorePlan : GLib.Object {

	public string snapshot { get; set; default = ""; }
	public string target { get; set; default = ""; }

	/* blocked is the daemon's answer, not a count of blocking rows.
	 *
	 * A plan can be refused for a reason no single mount point owns -- a
	 * snapshot that cannot be read, a repository that will not open -- so
	 * deriving this by scanning `rows` would let those through. */
	public bool blocked { get; set; default = false; }

	public Gee.ArrayList<DaemonRestorePlanRow> rows { get; private set;
		default = new Gee.ArrayList<DaemonRestorePlanRow>(); }
	public Gee.ArrayList<string> phases { get; private set;
		default = new Gee.ArrayList<string>(); }
	public Gee.ArrayList<string> notes { get; private set;
		default = new Gee.ArrayList<string>(); }
	public Gee.ArrayList<string> blockers { get; private set;
		default = new Gee.ArrayList<string>(); }

	public static DaemonRestorePlan from_wire(Json.Object o){
		var p = new DaemonRestorePlan();
		p.snapshot = DaemonClient.wire_string(o, "snapshot", "");
		p.target   = DaemonClient.wire_string(o, "target", "");
		p.blocked  = DaemonClient.wire_bool(o, "blocked", false);

		if (o.has_member("rows") &&
			(o.get_member("rows").get_node_type() == Json.NodeType.ARRAY)){
			foreach (var node in o.get_array_member("rows").get_elements()){
				if (node.get_node_type() == Json.NodeType.OBJECT){
					p.rows.add(DaemonRestorePlanRow.from_wire(node.get_object()));
				}
			}
		}

		read_strings(o, "phases", p.phases);
		read_strings(o, "notes", p.notes);
		read_strings(o, "blockers", p.blockers);
		return p;
	}

	private static void read_strings(Json.Object o, string member,
		Gee.ArrayList<string> into){

		if (!o.has_member(member)){ return; }
		if (o.get_member(member).get_node_type() != Json.NodeType.ARRAY){ return; }

		foreach (var node in o.get_array_member(member).get_elements()){
			if (node.get_node_type() == Json.NodeType.VALUE){
				var text = node.get_string();
				if (text != null){ into.add(text); }
			}
		}
	}
}
