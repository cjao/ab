#! /bin/bash

# This script assumes that your root is mounted at vg0/wsroot[0,1].

subvol_base="snapshots/root"
blockdev="/dev/sda3" # Source this at runtime
current_subvol_full=$(findmnt -n -o SOURCE / | sed 's|.*\[\(.*\)\]|\1|')
current_subvol_full=${current_subvol_full#/}
current_subvol_short=${current_subvol_full#$subvol_base/}

# TODO: allow more than two rootfs
subvol_short0="root0"
subvol_short1="root1"


exec 3>/dev/null


# TODO: Allow more than 2 versions
case "$current_subvol_short" in
    "$subvol_short0")
	next_subvol_short="$subvol_short1"
	;;
    "$subvol_short1")
	next_subvol_short="$subvol_short0"
	;;
    *)
	"Error: could not recognize mounted subvolume $current_subvol_short."
	exit 1
esac

next_subvol_full=$subvol_base/$next_subvol_short


current_subvol_short_staging="${current_subvol_short}_staging"
next_subvol_short_staging="${next_subvol_short}_staging"

current_subvol_short_backup="${current_subvol_short}_backup"
next_subvol_short_backup="${next_subvol_short}_backup"

current_subvol_short_bootdir="/boot/snapshots/$current_subvol_short"
next_subvol_short_bootdir="/boot/snapshots/$next_subvol_short"

echo "Current subvol is $current_subvol_short, next subvol is $next_subvol_short." >&3
snapshot_mnt="/mnt/.snapshots"
next_subvol_short_staging_mnt="$snapshot_mnt/$next_subvol_short_staging"

print_usage()
{
    echo "Usage: ab [-v] COMMAND"
    echo "where COMMAND is one of mount|umount|next-subvol|backup|stage"
    echo "|dnf|finalize|compare|cleanup|backup-bootdir|kernels|initrds."
    echo "mount options:   -s"
    echo "cleanup options: -a"
    echo "compare options: --previous"
}
test_uid()
{
    if [ $UID -ne 0 ]; then
	echo "Error: must be run as root to continue." >&2
	exit 1
    fi
}

snapshot()
{
    test_uid
    if [ $# -ne 2 ]; then
	echo "Error: snapshot expected 2 parameters, got $#." >&2
	exit 1
    fi
    subvol=$1
    subvol_snap=$2
    
    if [ "$subvol" = "$subvol_snap" ]; then
	echo "Error: $subvol and $subvol_snap are the same logical volume. Exiting." >&2
	exit
    fi

    if [ -d $snapshot_mnt/$subvol_snap ]; then
	if ! btrfs sub delete $snapshot_mnt/$subvol_snap; then
	    echo "Error: unable to delete existing snapshot $snapshot_mnt/$subvol_snap." >&2
	    exit 1
	fi
    fi

    btrfs subvol snapshot $snapshot_mnt/$subvol $snapshot_mnt/$subvol_snap
    
    exec 3>/dev/null
    echo "Created snapshot $subvol_snap of subvolume $subvol" >&3

}

mark_staging()
{
    test_uid
    if [ $# -ne 1 ]; then
	echo "Error: snapshot expected 1 parameter, got $#." >&2
	exit 1
    fi    
    subvol=$1

    if ! touch $snapshot_mnt/$subvol/.staging; then
	echo "Error: could not write to $snapshot_mnt/$subvol/.staging"
	exit 1
    fi
}

unmark_staging()
{
    test_uid
    if [ $# -ne 1 ]; then
	echo "Error: snapshot expected 1 parameters, got $#." >&2
	exit 1
    fi    
    subvol=$1

    if ! rm $snapshot_mnt/$subvol/.staging; then
	echo "Error: could not remove $snapshot_mnt/$subvol/.staging"
	exit 1
    fi
}

edit_grubenv()
{
    test_uid
    subvol=$1
    subvol_new=$2
    grubenv="/boot/efi/EFI/fedora/grubenv"
    grubenv_new=${grubenv}_new
    
    
    sed "s|$subvol|$subvol_new|" $grubenv > $grubenv_new
    if [ -f $grubenv_new ]; then
	mv $grubenv_new $grubenv
    else
	echo "Error: could not write new grub configuration to $grubenv_new." >&2
	exit 1
    fi
}


mount_snapshots()
{
    test_uid
    if ! [ -d "$snapshot_mnt" ]; then
	mkdir -p "$snapshot_mnt"
    fi

    if findmnt $snapshot_mnt > /dev/null; then
	if ! umount -R $snapshot_mnt; then
	    echo "Error: failed to unmount $snapshot_mnt." >&2
	    exit 1
	fi    
    fi

    if [ "$1" != "-u" ]; then
	if ! mount $blockdev -o subvol=$subvol_base $snapshot_mnt; then
	    echo "Error: failed to mount subvolume $subvol_base to $snapshot_mnt." >Y&2
	    exit 1
	fi
    fi
    
}

prepare_staging_bind_mounts()
{
    test_uid
    for d in boot dev proc sys; do
	if ! mount --bind /$d $next_subvol_short_staging_mnt/$d; then
	    echo "Error: failed to bind-mount /$d to $next_subvol_short_staging_mnt/$d." >&2
	    exit 1
	fi
    done
}

cleanup_staging_bind_mounts()
{
    test_uid
    for d in boot dev proc sys; do
	if ! umount -R $next_subvol_short_staging_mnt/$d; then
	    echo "Error: failed to unmount $next_subvol_short_staging_mnt/$d." >&2
	    exit 1
	fi
    done
}


run_dnf_transaction()
{
    test_uid
    mount_snapshots
    prepare_staging_bind_mounts
    echo "Running \"dnf $@\" in root $next_subvol_short_staging_mnt." >&3
    if dnf --installroot=$next_subvol_short_staging_mnt --releasever=32 $@; then
	echo "dnf operation succeeded." >&3
	cleanup_staging_bind_mounts
    else
	dnf_retval=$?
	echo "dnf operation failed." >&3
	cleanup_staging_bind_mounts
	exit $dnf_retval
    fi
}

prepare_next_boot()
{
    test_uid
    echo "Editing fstab." >&3
    if ! sed -i.bak "s|subvol=$current_subvol_full|subvol=$next_subvol_full|" $next_subvol_short_staging_mnt/etc/fstab; then
       echo "Error: could not edit fstab of $next_subvol_short_staging." >&2
       exit 1
    fi

    snapshot $next_subvol_short_staging $next_subvol_short
    cleanup
    edit_grubenv $current_subvol_full $next_subvol_full
    unmark_staging $next_subvol_short
    
}

rollback_boot()
{
    test_uid
    echo "WARNING: experimental."
    mount_snapshots
    if ! [ -d "$snapshot_mnt/$next_subvol_short" ]; then
	echo "Error: subvolume $next_subvol_full does not exist."
	exit 1
    fi
    echo "Switching root subvol for next boot to $next_subvol_full."
    edit_grubenv $current_subvol_full $next_subvol_full 
}

compare_rpmdb()
{
    test_uid

    echo "Error: unimplemented."

}

# TODO: improve output
cleanup()
{
    test_uid
    mount_snapshots
    btrfs sub delete $snapshot_mnt/*_staging

    if [ "$1" = "-a" ]; then
	edit_grubenv $next_subvol_full $current_subvol_full
	btrfs sub delete $snapshot_mnt/$next_subvol_short
	btrfs sub delete $snapshot_mnt/*_backup
    fi

    # if [ -d "$snapshot_mnt/$next_subvol_short_staging" ]; then
    # 	btrfs sub delete "$snapshot_mnt/$next_subvol_short_staging"
    # fi

    # if [ -d "$snapshot_mnt/$current_subvol_short_staging" ]; then
    # 	btrfs sub delete "$snapshot_mnt/$current_subvol_short_staging"
    # fi

    # if [ "$1" = "-a" ]; then
    # 	if [ -d "$snapshot_mnt/$next_subvol_short_backup" ]; then
    # 	    btrfs sub delete "$snapshot_mnt/$next_subvol_short_backup"
    # 	fi
	    
    # 	if [ -d "$snapshot_mnt/$current_subvol_short_backup" ]; then
    # 	btrfs sub delete "$snapshot_mnt/$current_subvol_short_backup"
    # 	fi
	
    # fi

}

kernels()
{
    root=$1
    for k in $(ls $1/lib/modules); do
	echo "vmlinuz-$k"
    done
}

initrds()
{
    root=$1
    for k in $(ls $1/lib/modules); do
	echo "initramfs-$k.img"
    done
}

# Preserves kernels and initrds tied to the current root.
# Run this before a kernel upgrade in the staging root.
# TODO: generate bootloader entries.

backup_bootdir()
{
    test_uid
    if ! [ -d $current_subvol_short_bootdir ]; then
	mkdir -p $current_subvol_short_bootdir
    fi
    #Remove defunct kernels and initrds
    for k in $(find $current_subvol_short_bootdir -iname "vmlinuz*"); do
	kernel=$(basename $k)
	kernel_version=${kernel#vmlinuz-}
	initrd="initramfs-$kernel_version.img"
	if ! [ -d "/lib/modules/$kernel_version" ]; then
	    rm $current_subvol_short_bootdir/$kernel;
	    rm $current_subvol_short_bootdir/$initrd
	    echo "Pruned obselete kernel $current_subvol_short_bootdir/$kernel" >&3
	    echo "Pruned obselete initrd $current_subvol_short_bootdir/$initrd" >&3
	fi
    done
    for k in $(kernels); do
	if ! [ -f $current_subvol_short_bootdir/$k ]; then
	    if ! ln /boot/$k $current_subvol_short_bootdir/$k; then
		echo "Error: failed to hard-link /boot/$k to $current_subvol_short_bootdir/$k" >&2
		exit 1
	    fi
	    echo "Backed up /boot/$k to $current_subvol_short_bootdir/$k" >&3
	fi
    done
    for k in $(initrds); do
	if ! [ -f $current_subvol_short_bootdir/$k ]; then
	    if ! ln /boot/$k $current_subvol_short_bootdir/$k; then
		echo "Error: failed to hard-link /boot/$k to $current_subvol_short_bootdir/$k" >&2
		exit 1
	    fi
	    echo "Backed up /boot/$k to $current_subvol_short_bootdir/$k" >&3
	fi
    done
}

case $1 in
    -v)
	exec 3>&2
	shift
	;;
    *)
	;;
esac

case $1 in
    mount)
	shift
	mount_snapshots
	;;
    umount)
	shift
	mount_snapshots -u
	;;
    next-subvol)
	echo "Current subvol: $current_subvol_full Next subvol: $next_subvol_full"
	;;
    stage)
	shift
	mount_snapshots
	snapshot $current_subvol_short $next_subvol_short_staging
	mark_staging $next_subvol_short_staging
	;;
    backup)
	shift
	mount_snapshots
	snapshot $current_subvol_short $current_subvol_short_backup
	;;
    dnf)
	shift
	run_dnf_transaction $@
	;;
    finalize)
	prepare_next_boot
	;;
    compare)
	shift
	compare_rpmdb $@
	;;
    kernels)
	shift
	kernels $@
	;;
    backup-bootdir)
	shift
	backup_bootdir $@
	;;
    initrds)
	shift
	initrds $@
	;;
    cleanup)
	shift
	cleanup $@
	;;
    rollback)
	rollback_boot
	;;
    *)
	print_usage
	;;
esac