# rsync itemise corpus

`create-first-pass`, `create-unchanged-pass` and `create-mixed-pass` are **real**
`rsync -aiiXH --recursive --verbose --delete --delete-after --force --stats
--sparse` output, captured on 2026-08-31 against `/usr/include/glib-2.0` with
rsync 3.x. The mixed pass was produced by deleting 40 files, back-dating 25,
chmod-ing 10 and adding an orphan directory in the destination first, so it
carries `>f..t......`, `.f...p.....` and `*deleting` lines alongside the
`>f+++++++++` of a fresh transfer.

`synthetic-all-flags.itemise` is **hand-written**. It covers the itemise columns
this machine cannot produce on demand -- checksum (`c`), size (`s`), owner (`o`),
group (`g`), acl (`a`), xattr (`x`), the hardlink prefix (`h`), the receive
prefix (`<`) and symlinks (`L`). Keep it in sync with the column meanings in
rsync(1) under `--itemize-changes`, not with any particular run.

The flags matter: the progress denominator is a **line count**, not a byte
count, so changing the rsync flags changes how many lines a transfer emits and
silently skews every progress bar. See `RsyncTask.build_script()`.
