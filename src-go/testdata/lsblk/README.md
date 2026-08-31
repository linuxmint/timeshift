# lsblk corpus

`laptop-nvme-ext4.pairs` is **real** output from this machine:

    lsblk --bytes --pairs --output NAME,KNAME,LABEL,UUID,TYPE,FSTYPE,SIZE,\
      MOUNTPOINT,MODEL,RO,HOTPLUG,MAJ:MIN,PARTLABEL,PARTUUID,PKNAME,VENDOR,SERIAL,REV

which is the exact column list `Device.get_block_devices_using_lsblk()` asks for
on a modern lsblk. It is a plain NVMe disk with an ESP and one ext4 root, plus
18 squashfs loop devices from snaps -- which is itself worth keeping, because
the loop devices are what `detect_system_devices()` has to skip when picking
`sys_root`.

`synthetic-luks-lvm.pairs` is **hand-written**: a stock Ubuntu
LUKS-on-LVM install, which this machine does not have. It is the layout that
exercises the parts of the device model with no other coverage --
`crypto_LUKS` part -> `crypt` mapper -> `LVM2_member` -> two `lvm` volumes,
linked by PKNAME, with `KNAME` diverging from `NAME` for every device-mapper
node. `is_encrypted_partition()`, `is_on_encrypted_partition()` and
`is_lvm_partition()` all key off exactly these fields.

Ancient-lsblk output (the reduced column set behind `lsblk_is_ancient`) is not
captured: this fork requires a modern util-linux.
