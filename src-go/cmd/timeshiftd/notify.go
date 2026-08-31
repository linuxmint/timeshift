package main

import (
	"net"
	"os"
)

/* sd_notify, without libsystemd.
 *
 * The protocol is a single datagram of "KEY=value" lines to the unix socket
 * named by $NOTIFY_SOCKET, so a dependency for it would be absurd. What it buys
 * is worth having: with Type=notify systemd knows the daemon is ready when the
 * socket is actually listening rather than when the process has been forked, so
 * anything ordered After= this unit -- and `systemctl start` itself -- does not
 * race the listener.
 *
 * Every failure here is ignored on purpose. Not running under systemd is a
 * perfectly ordinary way to run this: from a terminal while debugging, from the
 * Arch package's path where the client library spawns the daemon itself. A
 * missing NOTIFY_SOCKET means nobody is listening, which is not an error.
 */
func sdNotify(state string) {
	addr := os.Getenv("NOTIFY_SOCKET")
	if addr == "" {
		return
	}

	// A leading '@' denotes an abstract socket, whose name starts with NUL.
	if addr[0] == '@' {
		addr = "\x00" + addr[1:]
	}

	conn, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: addr, Net: "unixgram"})
	if err != nil {
		return
	}
	defer conn.Close()

	conn.Write([]byte(state))
}
