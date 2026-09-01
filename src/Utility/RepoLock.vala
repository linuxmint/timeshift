/*
 * RepoLock.vala
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

/* flock(2). Declared here rather than pulled in with --pkg gnu, because
 * gnu.vapi's FlockOperation enum has no LOCK_NB, and this must not block
 * inside the kernel while a GUI is waiting on it. */
[CCode (cname = "flock", cheader_filename = "sys/file.h")]
private extern int ts_flock(int fd, int operation);

/* The repository write lock.
 *
 * Taken around the operations that WRITE the repository -- create, delete,
 * restore -- and around nothing else.
 *
 * This is not AppLock and does not replace it in kind. AppLock refused a second
 * *process*, which is why a cron-driven backup made the GUI impossible to open,
 * and it did not protect against the Go daemon at all, since timeshiftd never
 * took it. A daemon backup and a GUI backup could therefore run into the same
 * repository at the same time, each with --delete and each running its own
 * retention pass.
 *
 * What has to be serialised is a write, not a process. So reads -- the snapshot
 * list, the status card, a window watching someone else's job -- never come
 * here, and a second window opens perfectly well while a backup runs.
 *
 * flock(2), so the kernel releases it if we are killed. That is the point:
 * AppLock's check-then-write left a file behind that could only be cleared by
 * guessing whether a recorded pid was still alive -- on a pid the kernel may
 * since have handed to something else.
 *
 * The Go side takes the same flock on the same path, in
 * src-go/internal/replock. flock(2) and fcntl(2) record locks do not see each
 * other, so both must stay on flock.
 */
public class RepoLock : GLib.Object {

	public const string LOCK_PATH = "/run/timeshift/repo.lock";

	private const int LOCK_EX = 2;
	private const int LOCK_NB = 4;
	private const int LOCK_UN = 8;

	private int fd = -1;

	/* Who held it when we last failed to take it, for a message a person can
	 * act on. Best effort: a holder killed between taking the lock and
	 * describing itself leaves this empty. */
	public string holder { get; private set; default = ""; }

	/* Take the lock, or return false immediately. */
	public bool try_acquire(string what){

		if (fd >= 0){ return true; }

		dir_create(file_parent(LOCK_PATH));

		int f = Posix.open(LOCK_PATH, Posix.O_CREAT | Posix.O_RDWR, 0644);
		if (f < 0){
			log_error("Could not open the repository lock: %s".printf(LOCK_PATH));
			return false;
		}

		if (ts_flock(f, LOCK_EX | LOCK_NB) != 0){
			// Read the holder BEFORE closing: the refusal is the proof that
			// someone holds it, so the file's contents are current rather than
			// the leftovers of a run that died.
			holder = read_holder(f);
			Posix.close(f);
			return false;
		}

		fd = f;
		holder = "";
		write_holder(what);
		return true;
	}

	/* Take the lock, waiting for it, calling on_wait once per distinct holder.
	 *
	 * timeout_seconds of 0 waits indefinitely, which is the right default for
	 * a person who asked for a backup: a queue is better than a refusal. */
	public bool acquire(string what, int timeout_seconds = 0, WaitNotify? on_wait = null){

		string announced = "";
		int64 deadline = (timeout_seconds > 0)
			? (GLib.get_monotonic_time() + ((int64) timeout_seconds * 1000000))
			: 0;

		while (true){

			if (try_acquire(what)){ return true; }

			if ((on_wait != null) && (holder != announced)){
				announced = holder;
				on_wait(describe_holder());
			}

			if ((deadline > 0) && (GLib.get_monotonic_time() >= deadline)){
				return false;
			}

			GLib.Thread.usleep(500000);
		}
	}

	public delegate void WaitNotify(string holder);

	/* A sentence naming the holder, or a neutral one when it did not say. */
	public string describe_holder(){

		if (holder.strip().length == 0){
			return _("another Timeshift operation");
		}
		return holder;
	}

	/* Drop the lock.
	 *
	 * The file is truncated but never deleted. Unlinking it would let a waiter
	 * create and lock a fresh inode while an older holder still held the
	 * original, so both would believe they held the lock. */
	public void release(){

		if (fd < 0){ return; }

		Posix.ftruncate(fd, 0);
		ts_flock(fd, LOCK_UN);
		Posix.close(fd);
		fd = -1;
	}

	private void write_holder(string what){

		// The same shape AppLock used -- "<pid>;<what>" -- so anyone catting
		// the file, and the Go reader, see what they have always seen.
		string line = "%ld;%s".printf((long) Posix.getpid(), what);
		Posix.write(fd, (char*) line, line.length);
	}

	private string read_holder(int f){

		uint8 buf[256];
		ssize_t n = Posix.read(f, buf, 255);
		if (n <= 0){ return ""; }
		buf[n] = 0;

		string txt = ((string) buf).strip();

		// Deliberately tolerant. AppLock did split(";")[1] with no length
		// check, which walks off the end of the array for a file holding
		// anything without a semicolon. No shape of a diagnostic line is worth
		// failing over.
		int sep = txt.index_of(";");
		if (sep < 0){ return ""; }

		string pid = txt.substring(0, sep).strip();
		string what = txt.substring(sep + 1).strip();
		if (what.length == 0){ return ""; }

		if (pid.length > 0){
			return "%s (PID=%s)".printf(what, pid);
		}
		return what;
	}
}
