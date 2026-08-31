# Shared helpers for timeshift-recovery. Sourced, never executed.
# POSIX sh: this runs from a dpkg trigger and a systemd unit as well as a shell.

CONFIG=${TSR_CONFIG:-/etc/timeshift-recovery/config}
CACHE=${TSR_CACHE:-/var/cache/timeshift-recovery}
STATE=${TSR_STATE:-/var/lib/timeshift-recovery}
LIBDIR=${TSR_LIBDIR:-/usr/lib/timeshift-recovery}
LOGFILE=${TSR_LOG:-/var/log/timeshift-recovery.log}

GRUB_ENTRY=/etc/grub.d/42_timeshift_recovery
GRUB_DROPIN=/etc/default/grub.d/timeshift-recovery.cfg

# The boot-screen hint image, copied where GRUB can read it at parse time.
GRUB_SPLASH=/boot/grub/timeshift-recovery-splash.png

# Written by place-payload, read by status/upgrade/remove.
INSTALLED=$STATE/installed
STALE=$STATE/stale

# Existence means 'timeshift-recovery disable': the payload stays, the GRUB
# entry stays gone -- including across the dpkg trigger's automatic upgrade.
DISABLED=$STATE/disabled

SQUASHFS=$CACHE/filesystem.squashfs
CACHE_BOOT=$CACHE/boot
ROOTFS=$CACHE/rootfs

# Payload layout, identical for every target so upgrade never branches.
PAYLOAD_SQUASHFS_REL=casper/filesystem.squashfs
PAYLOAD_KERNEL_REL=boot/vmlinuz
PAYLOAD_INITRD_REL=boot/initrd.img

# --- output -----------------------------------------------------------------

# Diagnostics go to stderr so that machine-readable subcommand output on stdout
# stays clean.
log()  { printf '%s\n' "$*" >&2; [ -w "${LOGFILE%/*}" ] && printf '%s %s\n' "$(date -Is)" "$*" >> "$LOGFILE" 2>/dev/null || true; }
warn() { printf 'warning: %s\n' "$*" >&2; [ -w "${LOGFILE%/*}" ] && printf '%s WARN %s\n' "$(date -Is)" "$*" >> "$LOGFILE" 2>/dev/null || true; }
die()  { printf 'error: %s\n' "$*" >&2; [ -w "${LOGFILE%/*}" ] && printf '%s ERROR %s\n' "$(date -Is)" "$*" >> "$LOGFILE" 2>/dev/null || true; exit 1; }

step() { printf '\n==> %s\n' "$*" >&2; }

# Echo a command, and run it unless this is a dry run. Every destructive action
# goes through this, so --dry-run is a complete preview rather than a partial one.
run() {
	if [ "${DRY_RUN:-0}" = "1" ]; then
		printf '  [dry-run] %s\n' "$*" >&2
		return 0
	fi
	printf '  + %s\n' "$*" >&2
	"$@"
}

require_root() {
	[ "$(id -u)" = "0" ] || die "must be run as root (try: sudo timeshift-recovery${*:+ $*})"
}

# One mutating run at a time. Without this the GUI's button, the dpkg
# trigger's refresh unit and a shell could interleave two builds into the same
# cache directory, or write the GRUB entry twice. Held for the process
# lifetime; fd 9 is otherwise unused.
take_lock() {
	if ! command -v flock >/dev/null 2>&1; then
		# util-linux is a dependency, so this is a broken system; say so
		# rather than silently running unserialised.
		warn "flock not found; proceeding without the run lock"
		return 0
	fi
	exec 9> /run/timeshift-recovery.lock
	flock -n 9 || die "another timeshift-recovery run is already active"
}

# In a dry run a missing tool is information, not a failure: the whole point of
# --dry-run is to see the plan on a machine that is not set up yet.
require_tool() {
	for _t in "$@"; do
		command -v "$_t" >/dev/null 2>&1 && continue
		if [ "${DRY_RUN:-0}" = "1" ]; then
			warn "$_t is not installed; the real run needs it: apt install $(tool_package "$_t")"
		else
			die "$_t not found. Install it first: apt install $(tool_package "$_t")"
		fi
	done
}

# Map a missing binary back to the package that provides it, so the error tells
# the user what to do rather than just what is wrong.
tool_package() {
	case "$1" in
		mmdebstrap)          echo mmdebstrap ;;
		mksquashfs|unsquashfs) echo squashfs-tools ;;
		dpkg-repack)         echo dpkg-repack ;;
		sgdisk)              echo gdisk ;;
		parted|partprobe)    echo parted ;;
		mkfs.ext4|resize2fs) echo e2fsprogs ;;
		grub-reboot|update-grub|grub-mkrelpath) echo grub2-common ;;
		*)                   echo "$1" ;;
	esac
}

# --- config -----------------------------------------------------------------

load_config() {
	# The helpers source this file too, and the CLI has already resolved
	# defaults -> config file -> command line and exported the result. Loading
	# again there would reset every one of those back to the defaults below,
	# which silently discarded --target, --size, --hotkey, --timeout,
	# --firmware and the embed flags: they were parsed, exported, and then
	# overwritten before anything read them.
	if [ "${TSR_OPTS_APPLIED:-0}" = "1" ]; then
		return 0
	fi

	# Defaults first, so a config file predating a new option still works.
	TARGET=auto
	SIZE=6G
	HOTKEY=r
	HOTKEY_STYLE=hidden
	TIMEOUT=3
	SCALE=auto
	EMBED_SSH_KEY=1
	EMBED_WIFI_CREDS=1
	EMBED_TAILSCALE_STATE=1
	FIRMWARE=full
	TORAM=auto
	EXTRA_PACKAGES=""
	HINT=splash

	if [ -r "$CONFIG" ]; then
		# shellcheck disable=SC1090
		. "$CONFIG"
	fi
}

validate_config() {
	# ${VAR:-} throughout: this can run in a helper process where the CLI
	# exported the config (TSR_OPTS_APPLIED=1) -- under set -u a missing
	# export must read as invalid, not abort as an unbound variable.
	case "${HOTKEY_STYLE:-}" in
		hidden|countdown|menu|none) ;;
		*) die "invalid HOTKEY_STYLE '${HOTKEY_STYLE:-}' (want: hidden, countdown, menu, none)" ;;
	esac

	case "${HINT:-splash}" in
		splash|text|none) ;;
		*) die "HINT must be splash, text, or none (got '$HINT')" ;;
	esac

	# GRUB accepts a single letter or one of three aliases; anything else is
	# silently ignored at boot, which would look like the hotkey just not working.
	case "${HOTKEY:-}" in
		backspace|tab|delete) ;;
		[a-zA-Z]) ;;
		*) die "invalid HOTKEY '${HOTKEY:-}' (want: a single letter, or backspace/tab/delete)" ;;
	esac

	case "${TIMEOUT:-}" in
		''|*[!0-9]*) die "invalid TIMEOUT '${TIMEOUT:-}' (want: a whole number of seconds)" ;;
	esac

	if [ "$HOTKEY_STYLE" != "none" ] && [ "$TIMEOUT" -lt 1 ]; then
		die "TIMEOUT must be at least 1: GRUB reads no keys at all when the timeout is 0, so the hotkey would never fire"
	fi
}

# --- sizes ------------------------------------------------------------------

# "6G" -> bytes. Accepts K/M/G/T suffixes, decimal or bare bytes.
to_bytes() {
	_v=$1
	_n=$(printf '%s' "$_v" | sed 's/[KkMmGgTt]$//')
	_s=$(printf '%s' "$_v" | sed 's/^[0-9.]*//')
	case "$_n" in
		''|*[!0-9.]*) die "cannot parse size '$_v'" ;;
	esac
	case "$_s" in
		K|k) _m=1024 ;;
		M|m) _m=1048576 ;;
		G|g) _m=1073741824 ;;
		T|t) _m=1099511627776 ;;
		'')  _m=1 ;;
		*)   die "unknown size suffix in '$_v'" ;;
	esac
	# awk keeps decimal inputs like 6.5G working; printf %d truncates.
	awk -v n="$_n" -v m="$_m" 'BEGIN{ printf "%d", n * m }'
}

human_bytes() {
	awk -v b="$1" 'BEGIN{
		split("B KiB MiB GiB TiB", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
	}'
}

# --- host facts -------------------------------------------------------------

# The installed Timeshift, whichever of the two package names provides it.
# Printed as "name version" so callers can show both.
host_timeshift_pkg() {
	for _p in timeshift-ssh timeshift; do
		_v=$(dpkg-query -W -f='${Version}' "$_p" 2>/dev/null) || continue
		[ -n "$_v" ] || continue
		# A package can be known to dpkg but not installed (e.g. removed but
		# not purged); only an installed one has a usable binary to repack.
		_s=$(dpkg-query -W -f='${db:Status-Status}' "$_p" 2>/dev/null || echo "")
		[ "$_s" = "installed" ] || continue
		printf '%s %s\n' "$_p" "$_v"
		return 0
	done
	return 1
}

host_codename() {
	# shellcheck disable=SC1091
	( . /etc/os-release 2>/dev/null && printf '%s\n' "${VERSION_CODENAME:-}" )
}

host_arch() { dpkg --print-architecture; }

# findmnt -T needs a path that exists. During a dry run the payload directory
# has deliberately not been created yet, so resolve from the nearest ancestor
# that does exist -- it is on the same filesystem either way.
existing_ancestor() {
	_p=$1
	while [ ! -e "$_p" ] && [ "$_p" != "/" ]; do
		_p=$(dirname "$_p")
	done
	printf '%s\n' "$_p"
}

# The device holding /, e.g. /dev/nvme0n1p2.
root_device() { findmnt -no SOURCE / ; }

root_uuid() { findmnt -no UUID / ; }

# Strip a partition off a device name to get its disk: nvme0n1p2 -> nvme0n1,
# sda2 -> sda. lsblk knows the real answer, so ask it rather than guessing.
disk_of_partition() {
	_p=${1#/dev/}
	_d=$(lsblk -no PKNAME "/dev/$_p" 2>/dev/null | head -n1)
	[ -n "$_d" ] || return 1
	printf '/dev/%s\n' "$_d"
}

# Largest run of unallocated space on a disk, in bytes.
# parted's free-space rows are the authoritative view of the partition table.
largest_free_space() {
	_disk=$1
	parted -sm "$_disk" unit B print free 2>/dev/null | awk -F: '
		$5 == "free" {
			gsub(/B$/, "", $4)
			if ($4 + 0 > max) max = $4 + 0
		}
		END { printf "%d", max + 0 }
	'
}

total_ram_bytes() {
	awk '/^MemTotal:/ { printf "%d", $2 * 1024 }' /proc/meminfo
}

# --- installed-state file ---------------------------------------------------

save_state() {
	mkdir -p "$STATE"
	# Written whole rather than appended, so a re-install never leaves two
	# generations of keys in the file.
	cat > "$INSTALLED" <<EOF
# Written by timeshift-recovery. Do not edit; re-run 'timeshift-recovery install'.
TARGET_KIND=$TARGET_KIND
TARGET_DEV=$TARGET_DEV
TARGET_UUID=$TARGET_UUID
PAYLOAD_PATH=$PAYLOAD_PATH
TORAM_EFFECTIVE=$TORAM_EFFECTIVE
TS_PACKAGE=$TS_PACKAGE
TS_VERSION=$TS_VERSION
INSTALLED_AT=$(date -Is)
EOF
}

load_state() {
	[ -r "$INSTALLED" ] || return 1
	# shellcheck disable=SC1090
	. "$INSTALLED"
	return 0
}

mark_stale()   { mkdir -p "$STATE"; date -Is > "$STALE" 2>/dev/null || : > "$STALE"; }
clear_stale()  { rm -f "$STALE"; }
is_stale()     { [ -f "$STALE" ]; }

# --- grub -------------------------------------------------------------------

# The timeout GRUB will actually use, by replaying grub-mkconfig's own logic:
# source /etc/default/grub, then every /etc/default/grub.d/*.cfg in glob order,
# last assignment wins. Anything else is a guess, and a guess here means telling
# the user the hotkey works when it does not.
effective_grub_setting() {
	_want=$1
	(
		GRUB_TIMEOUT=""
		GRUB_TIMEOUT_STYLE=""
		# shellcheck disable=SC1091
		[ -r /etc/default/grub ] && . /etc/default/grub
		for _x in /etc/default/grub.d/*.cfg; do
			# shellcheck disable=SC1090
			[ -e "$_x" ] && . "$_x"
		done
		case "$_want" in
			timeout) printf '%s\n' "${GRUB_TIMEOUT:-5}" ;;
			style)   printf '%s\n' "${GRUB_TIMEOUT_STYLE:-menu}" ;;
		esac
	)
}

# Write the boot entry and the timeout drop-in for the recorded target, then
# update-grub. Needs TARGET_KIND, TARGET_UUID, PAYLOAD_PATH, TORAM_EFFECTIVE
# (from placement or load_state) plus HOTKEY, HOTKEY_STYLE, TIMEOUT. Lives here
# rather than in place-payload so 'enable' can restore the entry without
# re-placing a payload that never moved.
build_cmdline() {
	case "$TARGET_KIND" in
		partition)
			# casper's LIVE_MEDIA_PATH is concatenated onto the medium's mount
			# point, so it carries no leading slash (its own default is "casper").
			CMDLINE="boot=casper live-media=/dev/disk/by-uuid/$TARGET_UUID live-media-path=casper"
			[ "$TORAM_EFFECTIVE" = "1" ] && CMDLINE="$CMDLINE toram"
			;;
		root)
			# iso-scan runs as a casper-premount hook, before find_livefs, and
			# sets LIVEMEDIA to the image with LIVEMEDIA_OFFSET=0 so casper loop-
			# mounts it. That makes the toram copy the size of the image rather
			# than the size of the installed system.
			CMDLINE="boot=casper iso-scan/filename=$PAYLOAD_PATH/recovery.img"
			[ "$TORAM_EFFECTIVE" = "1" ] && CMDLINE="$CMDLINE toram"
			;;
	esac
	CMDLINE="$CMDLINE quiet splash"
}

# The panel's preferred mode, largest connected output wins. GRUB stretches
# the background image to the whole screen with a crude scaler, so rendering
# at the native size is what keeps the label sharp; a fixed-size shipped image
# is both upscaled and aspect-distorted on any panel it does not match.
native_mode() {
	_best_w=0; _best=""
	for _drm in /sys/class/drm/card*-*; do
		[ -r "$_drm/status" ] || continue
		[ "$(cat "$_drm/status" 2>/dev/null)" = "connected" ] || continue
		_m=$(head -1 "$_drm/modes" 2>/dev/null)
		case "$_m" in
			*x*)
				_w=${_m%%x*}
				if [ "$_w" -gt "$_best_w" ] 2>/dev/null; then
					_best_w=$_w; _best=$_m
				fi
				;;
		esac
	done
	[ -n "$_best" ] && printf '%s\n' "$_best"
}

# Render the splash at $1x$2 into $3. Element sizes scale with the height so
# the label occupies the same share of the screen at any resolution. Needs
# ImageMagick (Suggests, not a dependency): callers fall back to the shipped
# image when this returns nonzero.
render_splash() { # width height outfile
	_mg=""
	command -v magick >/dev/null 2>&1 && _mg=magick
	[ -z "$_mg" ] && command -v convert >/dev/null 2>&1 && _mg=convert
	[ -n "$_mg" ] || return 1

	_logo="${TSR_LIBDIR:-$LIBDIR}/logo.png"
	[ -r "$_logo" ] || return 1

	set -- "$1" "$2" "$3" $(awk -v h="$2" 'BEGIN {
		s = h / 1080
		printf "%d %d %d %d %d %d", int(128*s), int(110*s), int(42*s), int(40*s), int(24*s), int(100*s)
	}')
	# $4 logo px, $5 logo rise, $6 label pt, $7 label drop, $8 sub pt, $9 sub drop

	"$_mg" -size "$1x$2" xc:black \
		\( "$_logo" -resize "$4x$4" \) -gravity center -geometry "+0-$5" -composite \
		-font DejaVu-Sans -fill '#9aa4b6' -pointsize "$6" -gravity center \
		-annotate "+0+$7" 'Press  R  for System Recovery' \
		-fill '#5f6878' -pointsize "$8" -annotate "+0+$9" 'Continuing normal startup...' \
		-depth 8 -define png:color-type=2 "$3" 2>/dev/null || return 1

	[ -s "$3" ]
}

# Build the boot-screen hint that fills the hidden-timeout window, into the
# file named by $1. Our entry file executes at config-parse time, after
# 00_header has switched to gfxterm (destroying the firmware logo) and before
# the wait begins -- exactly the window that is otherwise a black screen.
write_grub_hint() {
	_hf=$1
	_hint=${HINT:-splash}

	# Only the hidden style needs a hint: countdown and menu draw their own
	# UI, and with none the hotkey does not work, so a hint would promise a
	# key that does nothing.
	[ "$HOTKEY_STYLE" = "hidden" ] || _hint=none

	# The shipped image says "R"; a remapped hotkey would make it a lie. The
	# text hint prints whichever key is real.
	if [ "$_hint" = "splash" ]; then
		case "$HOTKEY" in
			r|R) ;;
			*)
				log "hotkey is '$HOTKEY', not r; using the text hint instead of the splash"
				_hint=text
				;;
		esac
	fi

	if [ "$_hint" = "splash" ]; then
		_src="${TSR_LIBDIR:-$LIBDIR}/splash.png"

		# Prefer a render at the panel's own resolution; the shipped image is
		# the fallback for machines without ImageMagick or a DRM mode to read.
		_tmp_png=""
		_mode=$(native_mode || true)
		if [ -n "$_mode" ] && [ "${DRY_RUN:-0}" != "1" ]; then
			_tmp_png=$(mktemp --suffix=.png)
			if render_splash "${_mode%%x*}" "${_mode#*x}" "$_tmp_png"; then
				log "splash rendered at $_mode"
				_src=$_tmp_png
			else
				log "using shipped splash (no ImageMagick, or the render failed)"
				rm -f "$_tmp_png"; _tmp_png=""
			fi
		fi

		_rel=""
		if [ -r "$_src" ] && command -v grub-mkrelpath >/dev/null 2>&1; then
			if [ "${DRY_RUN:-0}" = "1" ]; then
				_rel=$GRUB_SPLASH
			else
				run install -m 0644 "$_src" "$GRUB_SPLASH"
				_rel=$(grub-mkrelpath "$GRUB_SPLASH" 2>/dev/null || true)
			fi
		fi
		if [ -n "$_rel" ]; then
			# The clear is load-bearing: background_image only registers the
			# image, and gfxterm repaints on the next text output. Nothing
			# outputs during the hidden wait, so without a forced redraw the
			# splash stays invisible until it is too late (verified in OVMF).
			cat > "$_hf" <<EOF
insmod png
if background_image "$_rel"; then
	clear
else
	echo "Press $HOTKEY for Timeshift Recovery"
fi
EOF
			[ -n "$_tmp_png" ] && rm -f "$_tmp_png"
			return 0
		fi
		[ -n "$_tmp_png" ] && rm -f "$_tmp_png"
		warn "splash hint unavailable (missing image or grub-mkrelpath); using the text hint"
		_hint=text
	fi

	if [ "$_hint" = "text" ]; then
		printf 'echo "Press %s for Timeshift Recovery"\n' "$HOTKEY" > "$_hf"
	else
		: > "$_hf"
	fi
}

write_grub() {
	step "Writing GRUB entry"

	build_cmdline

	_tmp=$(mktemp)
	# The separator is | and every value is a path or a UUID, so no escaping of
	# the replacement text is needed.
	sed -e "s|@UUID@|$TARGET_UUID|g" \
	    -e "s|@KERNEL@|$PAYLOAD_PATH/$PAYLOAD_KERNEL_REL|g" \
	    -e "s|@INITRD@|$PAYLOAD_PATH/$PAYLOAD_INITRD_REL|g" \
	    -e "s|@CMDLINE@|$CMDLINE|g" \
	    -e "s|@HOTKEY@|$HOTKEY|g" \
	    "$LIBDIR/grub-entry.in" > "$_tmp"

	# Splice the hint in place of the marker. awk, because the hint is
	# multi-line and sed makes that miserable in POSIX.
	_hint_file=$(mktemp)
	write_grub_hint "$_hint_file"
	_tmp2=$(mktemp)
	awk -v hf="$_hint_file" '
		$0 == "# @HINT@" { while ((getline line < hf) > 0) print line; next }
		{ print }
	' "$_tmp" > "$_tmp2"
	mv -f "$_tmp2" "$_tmp"
	rm -f "$_hint_file"

	# Catch a malformed entry here rather than at boot, where the failure mode
	# is a machine that drops to a GRUB rescue prompt.
	if command -v grub-script-check >/dev/null 2>&1; then
		if ! sh "$_tmp" | grub-script-check; then
			rm -f "$_tmp"
			die "generated GRUB entry is not valid GRUB script"
		fi
	fi

	if [ "${DRY_RUN:-0}" = "1" ]; then
		printf '  [dry-run] would write %s, emitting:\n' "$GRUB_ENTRY" >&2
		sh "$_tmp" | sed 's/^/      /' >&2
	else
		install -m 0755 "$_tmp" "$GRUB_ENTRY"
	fi
	rm -f "$_tmp"

	if [ "$HOTKEY_STYLE" = "none" ]; then
		run rm -f "$GRUB_DROPIN"
		warn "HOTKEY_STYLE=none: boot was left untouched, so pressing '$HOTKEY' at startup will NOT work."
		warn "Ubuntu ships GRUB_TIMEOUT=0 and GRUB reads no keys at all with no timeout."
		warn "Reach the environment with 'timeshift-recovery reboot' instead."
	elif [ "${DRY_RUN:-0}" = "1" ]; then
		printf '  [dry-run] would write %s (style=%s timeout=%s)\n' \
			"$GRUB_DROPIN" "$HOTKEY_STYLE" "$TIMEOUT" >&2
	else
		mkdir -p /etc/default/grub.d
		cat > "$GRUB_DROPIN" <<EOF
# Written by timeshift-recovery. Removed by 'timeshift-recovery remove'.
#
# GRUB only reads the keyboard while a timeout is running, and Ubuntu ships
# GRUB_TIMEOUT=0, which reads none. The recovery hotkey needs this to exist.
#
# With style=hidden the boot screen looks unchanged; pressing '$HOTKEY' during
# this window boots the recovery environment immediately, and Esc opens the
# full GRUB menu.
GRUB_TIMEOUT_STYLE=$HOTKEY_STYLE
GRUB_TIMEOUT=$TIMEOUT
EOF
	fi

	require_tool update-grub
	run update-grub >/dev/null 2>&1 || die "update-grub failed; the recovery entry is not active"
}
