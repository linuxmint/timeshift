# Timeshift

Timeshift for Linux is an application that provides functionality similar to the _System Restore_ feature in Windows and the _Time Machine_ tool in Mac OS. Timeshift protects your system by taking incremental snapshots of the file system at regular intervals. These snapshots can be restored at a later date to undo all changes to the system. 

In RSYNC mode, snapshots are taken using [rsync](https://rsync.samba.org) and [hard-links](https://en.wikipedia.org/wiki/Hard_link). Common files are shared between snapshots which saves disk space. Each snapshot is a full system backup that can be browsed with a file manager.

In BTRFS mode, snapshots are taken using the in-built features of the BTRFS filesystem. BTRFS snapshots are supported only on BTRFS systems having an Ubuntu-type subvolume layout (with @ and @home subvolumes).

Timeshift is similar to applications like [rsnapshot](https://www.rsnapshot.org), [BackInTime](https://github.com/bit-team/backintime) and [TimeVault](https://wiki.ubuntu.com/TimeVault) but with different goals. It is designed to protect only system files and settings. User files such as documents, pictures and music are excluded. This ensures that your files remain unchanged when you restore your system to an earlier date. If you need a tool to back up your documents and files please take a look at the excellent [BackInTime](https://github.com/bit-team/backintime) application which is more configurable and provides options for saving user files.  

> **Note:** the screenshots below show the previous GTK3 interface; this fork
> now ships a GTK4 UI with header bars and a live light/dark theme.

![](images/main_window.png)

# History

Timeshift was originally developed and maintained by [Tony George](https://teejeetech.com/).

His original repository is still available on [Github](https://github.com/teejee2008/timeshift).

Timeshift originates in the Xapp project, a collection of cross-DE and cross-distribution applications maintained by [Linux Mint](https://www.linuxmint.com). This GTK4 build no longer depends on libxapp, which is GTK3-only.

## Features

### Minimal Setup

*   Timeshift requires very little setup. Just install it, run it for the first time and take the first snapshot. Scheduled snapshots are taken by the `timeshiftd` service, which checks every few minutes whether one is due; there is no cron job to enable. The backup levels can be selected from the _Settings_ window.

*   Snapshots are saved by default on the system (root) partition in path **/timeshift**. Other linux partitions can also be selected. For best results the snapshots should be saved to an external (non-system) partition.

![](images/settings_location.png)

### Multiple Snapshot Levels

*   Multiple levels of snapshots can be enabled - Hourly, Daily, Weekly, Monthly and Boot

*   Number of snapshots to retain can be specified for each level

*   Boot snapshots provide an additional level of backup and are created every time the system starts. Boot snapshots are created with a delay of 10 mins so that system startup is not affected.

*   Snapshots are tagged to indicate their time interval:
    - H: Hourly
    - D: Daily
    - W: Weekly
    - M: Monthly
    - B: Boot
    - O: On-demand (Manually created)

![](images/settings_schedule.png)

### Rsync & BTRFS Snapshots

* Supports rsync snapshots on all systems

* Supports BTRFS snapshots on BTRFS systems

It is strongly recommended to use BTRFS snapshots on systems that are installed on BTRFS partition. BTRFS snapshots are perfect byte-for-byte copies of the system. Nothing is excluded. BTRFS snapshots can be created and restored in seconds, and have very low overhead in terms of disk space.

  ![](images/settings_rsync.png)

  ![](images/settings_btrfs.png)

### User Data is Excluded by Default
Timeshift is designed to protect system files and settings. It is NOT a backup tool and is not meant to protect user data. Entire contents of users' home directories are excluded by default. This has two advantages:

*   You don't need to worry about your documents getting overwritten when you restore a previous snapshot to recover the system.
*   Your music and video collection in your home directory will not waste space on the backup device.

You can selectively include items for backup from the ***Settings*** window. Selecting the option "*Include hidden items*" from the ***Users*** tab will back up and restore the .hidden files and directories in your home folder. These folders contain user-specific config files and can be included in snapshots if required.

*Note*: It is not recommended to include user data in backups as it will be overwritten when you restore the snapshot.

![](images/settings_users_rsync.png)

![](images/settings_filters.png)

*   Unlike similar tools that are scheduled to take backups at a fixed time of the day, Timeshift is designed to run once every hour and take snapshots only when a snapshot is due. This is more suitable for desktop users who keep their laptops and desktops switched on for few hours daily. Scheduling snapshots at a fixed time on such users will result in missed backups since the system may not be running when the snapshot is scheduled to run. By running once every hour and creating snapshots when due, Timeshift ensures that backups are not missed.
*   Applications like rsnapshot rotate a snapshot to the next level by creating a hard-linked copy. Creating a hard-linked copy may seem like a good idea but it is still a waste of disk space, since only files can be hard-linked and not directories. The duplicated directory structure can take up as much as 100 MB of space. Timeshift avoids this wastage by using tags for maintaining backup levels. Each snapshot will have only one copy on disk and is tagged as "daily", "monthly", etc. The snapshot location will have a set of folders for each backup level ("Monthly", "Daily", etc) with symbolic links pointing to the actual snapshots tagged with the level.

### System Restore
* Snapshots can be restored by selecting a snapshot from the main window and clicking the *Restore* button in the header bar. 

* Snapshots can be restored either from the running system (online restore) or from another system that has Timeshift installed on it (offline restore). 

* If the main system is not bootable, then it is possible to boot from an Ubuntu Live CD, install Timeshift on the live system, and restore a snapshot on the main system.

* Restoring backups from the running system requires a reboot to complete the restore process.

  ![](images/restore_summary.png)

### Cross-Distribution Restore

- You can also Timeshift across distributions. Let's say you are currently using Xubuntu and decide to try out Linux Mint. You install Linux Mint on your system and try it out for a week before deciding to go back to Xubuntu. Using Timeshift you can simply restore the last week's snapshot to get your Xubuntu system back. Timeshift will take care of things like reinstalling the bootloader and other details. 
- Since installing a new linux distribution also formats your root partition you need to save your snapshots on a separate linux partition for this to work.
- It is recommended to include hidden items in home directory by selecting the option "*Include  Hidden Items*" from *Settings* > *Users*.

### Post Restore Hooks

- Scripts can be run at the end of a restore job for anything that may need to be done prior to rebooting. The location for these scripts is `/etc/timeshift/restore-hooks.d`.  Note: the script(s) will be run from the restored filesystem.

### Recovery Environment

Snapshots kept on a remote host over SSH survive the disk, but they cannot be
restored from a system that will not boot: the restore tool, the network stack
and the wireless driver all live on the broken root filesystem.

The `timeshift-recovery` package closes that gap. It builds a small Ubuntu
recovery environment on the machine, places it where GRUB can reach it, and adds
a boot entry behind a hotkey:

```sh
sudo apt install ./timeshift-recovery_*.deb
sudo timeshift-recovery install
```

Press **R** at startup to boot straight into it. During GRUB's short wait the
screen shows a splash with the Timeshift logo and a "Press R for System
Recovery" label, rendered at the panel's native resolution at install time
(`HINT=splash` in the config; `text` and `none` are the alternatives, and
ImageMagick on the host is what enables the native render). Inside is a small
launcher with four things: connect wifi or ethernet, mount a drive, restore a
snapshot, and a root terminal. `SCALE` (or `--scale`) overrides the GUI scale
the environment picks for HiDPI panels.

The environment is built with `mmdebstrap` against the host's own apt sources,
so it always matches the installed release and architecture, and it mirrors the
host's `linux-firmware` packages so the hardware it has to rescue is the hardware
it supports. The snapshot location, and by default the SSH key, are carried in,
so a restore needs nothing but the machine itself.

A dpkg trigger rebuilds it whenever a new Timeshift is installed, so the rescue
environment never lags behind the system it is meant to rescue.

```sh
timeshift-recovery status     # what is installed, and is it current
timeshift-recovery upgrade    # rebuild against the current Timeshift
timeshift-recovery disable    # remove the boot entry, keep the payload
timeshift-recovery enable     # put the boot entry back (instant)
timeshift-recovery reboot     # boot into it once, without changing boot
timeshift-recovery remove     # remove the payload, entry and cached image
```

`status --machine` prints `KEY=value` lines for scripts. The same management
is available from Timeshift itself: `timeshift --recovery-status`,
`--recovery-enable` and `--recovery-disable` on the CLI, and a **Recovery**
page in the GUI's Settings that can also install the environment with live
build output. A disabled entry stays disabled across package upgrades and the
automatic refresh.

Where it lands depends on the disk. Given unallocated space it creates a
dedicated partition, which survives even the loss of the root filesystem.
Otherwise -- the usual case, since a stock Ubuntu install fills its disk -- it
falls back to an image on the root filesystem, which survives a bad update, a
bad kernel or a bad config, but not the loss of that filesystem. `--target`
overrides the choice; `--target /dev/sdX` writes a USB stick.

**The embedded SSH key is a real trade-off.** It is what makes an unattended
restore possible on a machine that is already broken, and it is readable by
anyone who can boot that machine. Restrict it on the backup host so a leaked
recovery key can read snapshots but not write or delete them:

```
# ~/.ssh/authorized_keys on the backup host
restrict,command="rrsync -ro /path/to/snapshots" ssh-ed25519 AAAA...
```

Or install with `--no-ssh-key` and supply credentials at recovery time.
`--no-wifi-creds` and `--no-tailscale-state` opt out of the other embedded
credentials the same way, and `timeshift-recovery status` reports what the
built image actually carries. On disk the image is readable by root only.

### Snapshot Guard for apt

The `apt-snapshot-guard` package (shipped alongside, from
`os-plugins/apt-snapshot-guard/`) installs a `DPkg::Pre-Invoke` hook that
takes a Timeshift snapshot automatically before apt applies **any** package
change - install, remove, upgrade, autoremove - from every frontend that
drives dpkg: apt on the command line, the GUI Software Updater, PackageKit
and unattended-upgrades.

It is fail-closed: no snapshot, no package change. On a terminal a failed
snapshot prompts (default No); GUI updates raise a zenity dialog; unattended
runs abort outright. For a deliberate exception, either
`sudo touch /run/apt-snapshot-guard.bypass` (one-shot) or run the command
with `APT_SNAPSHOT_GUARD=off`. Configuration lives in
`/etc/apt-snapshot-guard/config`.

### Status tray

The `timeshift-tray` package (from `os-plugins/timeshift-tray/`) puts a status
icon in the desktop's tray: when the last snapshot was taken, whether scheduled
snapshots are actually running, whether the location is reachable, and live
progress for whatever snapshot the machine is taking - including the one
`apt-snapshot-guard` takes while apt waits for it, which is otherwise
invisible. One action, "Create snapshot now", is offered.

It runs as your own desktop user, never as root, and reads the daemon's
**read-only** interface over `/run/timeshift/daemon.sock` - which cannot
create, delete or restore anything. Taking a snapshot is a separate
authenticated action: `pkexec` runs a wrapper that takes no arguments, under a
policy that authorises exactly that one command rather than the Timeshift CLI.

Reading that status needs membership of the `timeshift` group, which nothing
grants automatically - it also exposes the disk layout and every snapshot path.
Until it is granted the tray says so and offers to arrange it, and the menu
offers to take it away again. By hand, either way, effective at the next login:

```bash
sudo gpasswd -a "$USER" timeshift     # grant
sudo gpasswd -d "$USER" timeshift     # revoke
```

A tray icon needs a StatusNotifierItem host. KDE Plasma, Xfce, MATE and
Cinnamon have one built in; GNOME Shell needs an appindicator extension, which
is what the package recommends.

The icon is Timeshift's own shield with the state cut out of it - a tick, a
ring while a snapshot runs, a badge for warning or error, an outline when the
status cannot be read. By default it is monochrome like the desktop's own
indicators and turns amber or red only when something needs attention;
`TIMESHIFT_TRAY_ICONS=colour` keeps the brand colours on all the time and
`=symbolic` never shows them. The menu leads with a verdict ("Protected - last
snapshot 12 minutes ago"), then the schedule and the location in the daemon's
own words, and a progress meter while a snapshot runs.

It autostarts at login. After using the menu's Quit, start it again from the
app grid ("Timeshift Tray") or by running `timeshift-tray`; `man timeshift-tray`
covers the rest, and `--debug` (or `TIMESHIFT_TRAY_DEBUG=1`) explains itself to
the session journal when the icon does not appear.

### Building the packages

`./build-all.sh "changelog line"` builds all four debs (`timeshift-ssh`,
`apt-snapshot-guard`, `timeshift-recovery`, `timeshift-tray`), verifies each
with its `check-deb.sh`, and collects them in `dist/`. `TS_MSG` / `GUARD_MSG` /
`RECOVERY_MSG` / `TRAY_MSG` override the shared changelog bullets per package,
and `NO_BUMP=1` rebuilds the current versions without a new changelog entry.

Note that installing a deb resets any apt hold, so after every install of the
fork re-run: `sudo apt-mark hold timeshift-ssh`.

## Supported System Configurations

- **Normal** - OS installed on non-encrypted partitions

- **LUKS Encrypted** - OS installed on LUKS-encrypted partitions

- **LVM2** - OS installed on LVM2 volumes (with or without LUKS)

- **BTRFS** - OS installed on BTRFS volumes (with or without LUKS)

  - Only Ubuntu-type layouts with **@** and **@home** subvolumes are supported
  - **@** and **@home** subvolumes may be on same or different BTRFS volumes
  - **@** may be on BTRFS volume and **/home** may be mounted on non-BTRFS partition
  - If swap files are used they should not be located in **@** or **@home** and could instead be stored in their own subvolume, eg **@swap**
  - Separate partitions (e.g. `/boot`) can be handled via custom created hooks (placed in `/etc/timeshift/backup-hooks.d/` and `/etc/timeshift/restore-hooks.d/`). Script naming must match `run-parts` [requirements](https://manpages.ubuntu.com/manpages/noble/man8/run-parts.8.html). Current snapshot path is exported as `TS_SNAPSHOT_PATH`.
  - Other layouts are not supported
  - Make sure, that you have selected subvolume *@* or */@* for root. You can check that executing script below, and if output is *OK*, then everything is alright.

    ```shell
    grep -E '^[^#].+/\s+btrfs' /etc/fstab | \
    grep -oE 'subvol=[^,]+' | \
    cut -d= -f2 | \
    grep -qE '^/?@$' && \
    echo 'OK' || \
    echo 'Not OK'
    ```

  - Default BTRFS subvolume must be /. You can make it using script below.

    ```shell
    MP="$(mktemp -d)"
    mount | awk '/on \/ type btrfs/{print $1}' | sudo xargs -I{} mount {} "$MP" && \
    sudo btrfs subvolume set-default 5 "$MP"; \
    sudo umount "$MP"
    ```

- **GRUB2** - Bootloader must be GRUB2. GRUB legacy and other bootloaders are not supported.

- **EFI** - EFI systems are supported. Make sure that ```/boot/efi``` partition is selected for mounting before restoring snapshots (application will do it automatically).


- **Encrypted Home** - For users with encrypted home, files in ```/home/.ecryptfs/$USER``` will be backed-up and restored. The decrypted contents in ```$HOME``` will be excluded. This avoids the security risk of decrypted contents becoming available outside the user's home directory.
- **Encrypted Private Directory** - For users with encrypted *Private* directory, the encrypted files in ```$HOME/.Private```, as well as the decrypted files in ```$HOME/Private```, will be excluded (as it contains user data). Filters added by user to include files from ```$HOME/.Private``` or ```$HOME/Private``` will be ignored.
- **Docker & Containers** - Docker and containerized systems are not supported. Running Timeshift on such systems will have unpredictable results.

## Installation

### Building and Installing from Source Code

You can find the exact instructions in the [development](/docs/development.md) docs.

### Debian-based Distributions

Debian, Ubuntu, Linux Mint, Elementary OS, etc.

Install Timeshift from the repositories:  

```sh
sudo apt-get update
sudo apt-get install ./timeshift-ssh_*.deb
```

### Fedora

Fedora is not fully supported. BTRFS snapshots only support Ubuntu-specific layouts. 

```sh
sudo dnf update
sudo dnf install timeshift
```

### Arch

```sh
cd archlinux && makepkg -si
```

### ALT

```sh
su -
apt-get update
apt-get install ./timeshift-ssh_*.deb
```

## Removal

Run the following command in a terminal window:  

    sudo apt-get remove timeshift

or

    sudo dnf remove timeshift

or

    sudo pacman -R timeshift

or

    su - -c "apt-get remove timeshift"

depending on your package management system.

Remember to delete all snapshots before un-installing. Otherwise the snapshots continue to occupy space on your system.  To delete all snapshots, run the application, select all snapshots from the list (CTRL+A) and click the _Delete_ button on the toolbar. This will delete all snapshots and remove the _/timeshift_ folder in the root directory.     

## Known Issues & Limitations

#### BTRFS volumes
BTRFS volumes must have an Ubuntu-type layout with **@** and **@home** subvolumes. Other layouts are not supported. Systems having the **@** subvolume and having **/home** on a non-BTRFS partition are also supported.

`Text file busy / btrfs returned an error: 256 / Failed to create snapshot` can occur if you have a Linux swapfile mounted within the **@** or **@home** subvolumes which prevents snapshot from succeeding. Relocate the swapfile out of **@** or **@home*, for example into it's own subvolume like **@swap**.

#### Disk Space

Timeshift requires a lot of disk space to keep snapshot data. The device selected as snapshot device must have sufficient free space to store the snapshots that will be created. 

If the backup device is running out of space, try the following steps:

*   Reduce the number of backup levels - Uncheck the backup levels and keep only one selected
*   Reduce the number of snapshots that are kept - In the _Schedule_ tab set the number of snapshots to 5 or less.
*   You can also disable scheduled snapshots completely and create snapshots manually when required

#### Bootloader & EFI

* Only those systems are supported which use GRUB2 bootloader. Trying to create and restore snapshots on a system using older versions of GRUB will result in a non-bootable system.
* EFI systems are fully supported. Ensure that the ***/boot/efi*** partition is mapped while restoring a snapshot. It will be mapped automatically if detected.
* If you are restoring from Live CD/USB, and your installed system uses EFI mode, then you must boot from Live CD/USB in EFI mode.

## Contribute

You can contribute to this project in various ways:

- Submitting ideas, and reporting issues in the [tracker](https://github.com/linuxmint/timeshift/issues)
- Translating this application to other languages in [Launchpad](https://translations.launchpad.net/linuxmint/latest/+translations)
- Contributing code changes by fixing issues and submitting a pull request (do not modify translations, this is done in Launchpad)
- To get started with coding, see the [development](/docs/development.md) docs
