/*
 * JobMonitorWindow.vala
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
using TeeJee.GtkHelper;
using TeeJee.Misc;

/* A window onto work this process is not doing.
 *
 * Every other progress box in this app drives the operation it displays: it
 * mutates App.*, spawns a thread into the core and polls the fields that thread
 * writes. This one owns nothing. It attaches to a job inside timeshiftd -- most
 * often a snapshot apt-snapshot-guard started while apt waits for it -- and
 * draws what the event stream says.
 *
 * That inversion is the whole point of the daemon, and it shows up in two
 * places here:
 *
 *   - Closing this window does NOT stop the backup. There is no Cancel. The
 *     job belongs to the daemon and outlives every client watching it, so the
 *     button says Close and means it.
 *   - Opening it late is not a degraded experience. jobs.subscribe replies with
 *     the job's state as it stands and only then streams, so a window opened
 *     eight minutes into a transfer draws the same thing one opened at the
 *     start would be showing.
 */
public class JobMonitorWindow : AppWindow {

	private DaemonClient client;
	private string job_id;

	private TaskProgressBox progress;
	private Banner banner;
	private Gtk.Button btn_close;

	private bool finished = false;

	public signal void job_done(string outcome);

	public JobMonitorWindow(DaemonClient client, string job_id, string kind){

		this.client = client;
		this.job_id = job_id;

		this.title = title_for(kind);
		set_default_size(620, 360);
		this.modal = false;

		var header = new Gtk.HeaderBar();
		set_titlebar(header);

		btn_close = new Gtk.Button.with_label(_("Close"));
		btn_close.tooltip_text = _("Stop watching. The operation keeps running.");
		btn_close.clicked.connect(() => { close_self(); });
		header.pack_end(btn_close);

		var box = new Gtk.Box(Gtk.Orientation.VERTICAL, Ui.Spacing.MD);
		box.add_css_class("ts-page");
		set_child(box);

		banner = new Banner();
		box.append(banner);
		banner.set_message(
			_("This operation is running in the Timeshift service. Closing this window will not stop it."),
			Gtk.MessageType.INFO);

		progress = new TaskProgressBox(title_for(kind), true);
		box.append(progress);

		connect_signals();

		this.close_request.connect(on_close_request);

		if (!client.watch_job(job_id)){
			banner.set_message(
				_("Could not attach to the running operation."), Gtk.MessageType.ERROR);
			mark_finished();
		}
	}

	private string title_for(string kind){
		switch (kind){
		case "create":   return _("Creating Snapshot");
		case "delete":   return _("Deleting Snapshots");
		case "estimate": return _("Estimating System Size");
		case "restore":  return _("Restoring Snapshot");
		default:         return _("Operation In Progress");
		}
	}

	private void connect_signals(){

		client.job_phase.connect((id, phase) => {
			if (id != job_id){ return; }
			progress.lbl_msg.label = phase_title(phase);
		});

		client.job_progress.connect((id, percent, count, total, eta, status_line) => {

			if (id != job_id){ return; }

			if (total > 0){
				progress.progressbar.fraction = percent / 100.0;
			}
			else{
				// No denominator yet: pulse rather than sit at zero, which
				// reads as "stuck" instead of "counting".
				progress.progressbar.pulse();
			}

			if (status_line.length > 0){
				progress.lbl_status.label = status_line;
			}

			if (eta > 0){
				progress.lbl_remaining.label = _("%s remaining").printf(format_duration(eta));
			}
			else{
				progress.lbl_remaining.label = "";
			}
		});

		/* The counters arrive on their own signal, not on job_progress.
		 *
		 * They are ten numbers only a progress page wants, so widening
		 * job_progress would make every other subscriber carry them. Missing
		 * this connection is why the whole "File and directory counts" panel
		 * rendered as captions with nothing beside them: the daemon sent the
		 * counters on every progress tick and this window threw them away. */
		client.job_counters.connect((id, counters) => {
			if (id != job_id){ return; }
			show_counts(counters);
		});

		client.job_finished.connect((id, outcome, error) => {
			if (id != job_id){ return; }
			on_job_finished(outcome, error);
		});

		/* A dropped stream is not a finished job. Say so rather than leaving a
		 * spinner turning over stale numbers for ever. */
		client.stream_closed.connect(() => {
			if (finished){ return; }
			banner.set_message(
				_("Lost contact with the Timeshift service. The operation may still be running."),
				Gtk.MessageType.WARNING);
			mark_finished();
		});
	}

	private string phase_title(string phase){
		switch (phase){
		case "prepare":     return _("Preparing...");
		case "estimate":    return _("Estimating system size...");
		case "sync_files":  return _("Synching files...");
		case "finalize":    return _("Writing snapshot metadata...");
		case "delete":      return _("Removing files...");
		default:            return _("Working...");
		}
	}

	private void on_job_finished(string outcome, string error){

		switch (outcome){
		case "ok":
			banner.set_message(_("Finished."), Gtk.MessageType.INFO);
			progress.lbl_msg.label = _("Done.");
			progress.progressbar.fraction = 1.0;
			break;

		case "warnings":
			banner.set_message(
				_("Finished with warnings. Check the log for details."), Gtk.MessageType.WARNING);
			progress.lbl_msg.label = _("Done.");
			progress.progressbar.fraction = 1.0;
			break;

		default:
			banner.set_message(
				(error.length > 0) ? error : _("The operation failed."), Gtk.MessageType.ERROR);
			progress.lbl_msg.label = _("Failed.");
			break;
		}

		progress.lbl_remaining.label = "";
		mark_finished();
		job_done(outcome);
	}

	private void mark_finished(){
		finished = true;
		progress.spinner.spinning = false;
		client.stop_watching();
	}

	private bool on_close_request(){
		client.stop_watching();
		notify_closed();
		return false;
	}

	/* Writes the ten count labels.
	 *
	 * The keys are the daemon's, and they are the same ten the rsync itemise
	 * parser produces. A key that is absent reads as zero rather than blank:
	 * "0" is a fact about the transfer, an empty label is a fact about this
	 * window, and only the first is worth showing a person. */
	private void show_counts(Json.Object c){

		progress.lbl_unchanged.label   = count_text(c, "unchanged");
		progress.lbl_created.label     = count_text(c, "created");
		progress.lbl_deleted.label     = count_text(c, "deleted");
		progress.lbl_modified.label    = count_text(c, "modified");

		progress.lbl_checksum.label    = count_text(c, "checksum");
		progress.lbl_size.label        = count_text(c, "size");
		progress.lbl_timestamp.label   = count_text(c, "timestamp");
		progress.lbl_permissions.label = count_text(c, "permissions");
		progress.lbl_owner.label       = count_text(c, "owner");
		progress.lbl_group.label       = count_text(c, "group");
	}

	private string count_text(Json.Object c, string key){
		return "%'d".printf((int) DaemonClient.wire_int(c, key, 0));
	}

	// format_duration renders seconds the way the progress line reads best.
	private string format_duration(int64 seconds){

		if (seconds < 60){
			return _("%lld seconds").printf(seconds);
		}

		int64 mins = seconds / 60;
		if (mins < 60){
			return _("%lld minutes").printf(mins);
		}

		return _("%lld hours").printf(mins / 60);
	}
}
