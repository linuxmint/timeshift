# snapshot control-file corpus

Both files are **hand-written** to the exact schema `Snapshot.write_control_file()`
emits (`src/Core/Snapshot.vala:486-520`), because the repository on this machine
is remote and pulling a real `info.json` needs the backup host.

Every value is a JSON string, `created` is UTC unix seconds, and `subvolumes` is
an object of **positional five-element string arrays**:

    [ name, id, total_bytes, unshared_bytes, device_uuid ]

Only `@` and `@home` are accepted on read. `size_bytes` / `size_unshared_bytes`
are rsync-only and `-1` means "not computed yet"; `subvolumes` is btrfs-only.
