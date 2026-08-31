# config corpus

`default.json` is a copy of `files/timeshift.json`, the seed installed to
`$SYSCONFDIR/timeshift/default.json`.

`live-ssh.json` is the **real** `/etc/timeshift/timeshift.json` from this
machine -- a remote SSH repository with a daily schedule and three user exclude
patterns -- with the identifying values replaced: the backup host is now
`backup@backup.example:/srv/timeshift` and the home path is `/home/user`. Only
characters *inside* string values were changed, so every structural property the
round-trip test checks (key order, separator, indentation, the absent trailing
newline) is still exactly what json-glib wrote.

Both are written by json-glib with `pretty = true, indent = 2`, which is NOT
what `encoding/json`'s MarshalIndent produces:

  * the separator is `" : "`, not `": "`
  * array elements are indented 4, the closing bracket 2
  * an empty array is `[]` on one line
  * there is **no trailing newline** after the final `}`

Every value is a JSON *string*, including booleans and numbers. Both facts are
load-bearing: the Vala GUI reads these files, so a Go writer that "improves" the
format silently breaks it. `config.Marshal` reproduces json-glib byte for byte
and `TestGoldenRoundTrip` pins it.
