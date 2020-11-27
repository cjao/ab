#! /bin/bash

# This script assumes that your root is mounted at vg0/wsroot[0,1].

source /etc/default/grub

releasever=$(grep VERSION_ID /etc/os-release | sed 's|VERSION_ID=||')
machineid=$(cat /etc/machine-id)
subvol_base="snapshots/root"
uuid=$(findmnt -n -o UUID /)
current_subvol_full=$(findmnt -n -o FSROOT /)
current_subvol_full=${current_subvol_full#/}
current_subvol_short=${current_subvol_full#$subvol_base/}

# TODO: allow more than two rootfs
num_revisions=2

exec 3>/dev/null


next_subvol_short=""

# TODO: allow more than 2 versions

init_vars()
{
    if [ -z "$next_subvol_short" ]; then

	case "$current_subvol_short" in
	    ''|*[!0-9]*)
		echo "Error: could not recognize mounted subvolume $current_subvol_short" >&2
		exit 1
		;;
	    *)
		next_subvol_number=current_subvol_short+1
		next_subvol_short=$((next_subvol_number%num_revisions))
		;;
	esac
    fi

    next_subvol_full=$subvol_base/$next_subvol_short

#    current_subvol_short_staging="${current_subvol_short}_staging"
#    next_subvol_short_staging="${next_subvol_short}_staging"

    current_subvol_short_backup="${current_subvol_short}_backup"
    next_subvol_short_backup="${next_subvol_short}_backup"

    current_subvol_short_bootdir="/boot/snapshots/$current_subvol_short"
    next_subvol_short_bootdir="/boot/snapshots/$next_subvol_short"

    echo "Current subvol is $current_subvol_short, next subvol is $next_subvol_short." >&3
    snapshot_mnt="/mnt/.snapshots"
    next_subvol_short_mnt="$snapshot_mnt/$next_subvol_short"

}
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
	# Prune defunct bootloader entries
	# rm /boot/loader/entries/*-rollback.conf 2> /dev/null
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

edit_kernelopts()
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

    # Fedora 33 writes /proc/cmdline directly to the grub configuration files instead of
    # reading $kernelopts from grubenv
    for f in $(ls /boot/loader/entries); do
	case $f in
	    *rollback*)
		continue
		;;
	    *)
		sed "s|$subvol|$subvol_new|" /boot/loader/entries/$f > /boot/loader/entries/${f}.new
		if [ -f /boot/loader/entries/${f}.new ]; then
		    mv /boot/loader/entries/${f}.new /boot/loader/entries/$f
		else
		    echo "Error: could not modify grub entry /boot/loader/entries/$f"
		    exit 1
		fi
		;;
	esac
    done
    
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
	if ! mount -U $uuid -o subvol=$subvol_base $snapshot_mnt; then
	    echo "Error: failed to mount subvolume $subvol_base to $snapshot_mnt." >Y&2
	    exit 1
	fi
    fi
    
}

prepare_staging_bind_mounts()
{
    test_uid
    for d in boot dev proc sys; do
	if ! mount --bind /$d $next_subvol_short_mnt/$d; then
	    echo "Error: failed to bind-mount /$d to $next_subvol_short_mnt/$d." >&2
	    exit 1
	fi
    done
}

cleanup_staging_bind_mounts()
{
    test_uid
    for d in boot dev proc sys; do
	if ! findmnt $next_subvol_short_mnt/$d > /dev/null; then
	    continue
	fi
	if ! umount -R $next_subvol_short_mnt/$d; then
	    echo "Error: failed to unmount $next_subvol_short_mnt/$d." >&2
	    exit 1
	fi
    done
}


run_dnf_transaction()
{
    test_uid
    mount_snapshots
    prepare_staging_bind_mounts
    echo "Running \"dnf $@\" in root $next_subvol_short_mnt." >&3
    if dnf --installroot=$next_subvol_short_mnt --releasever=$releasever $@; then
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
    if ! sed -i.bak "s|subvol=$current_subvol_full|subvol=$next_subvol_full|" $next_subvol_short_mnt/etc/fstab; then
       echo "Error: could not edit fstab of $next_subvol_short." >&2
       exit 1
    fi

#    cleanup
    unmark_staging $next_subvol_short
    edit_kernelopts $current_subvol_full $next_subvol_full
}

rollback_boot()
{
    test_uid
    echo "Error: unimplemented"


#    edit_kernelopts $current_subvol_full $next_subvol_full 
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

    for d in $(ls $snapshot_mnt); do
	if [ -f $snapshot_mnt/$d/.staging ]; then
	    echo "Deleting staging subvolume $d"
	    btrfs sub delete $snapshot_mnt/$d
	fi
    done

    if [ "$1" = "-a" ]; then
	# Reset grubenv.
	edit_kernelopts $next_subvol_full $current_subvol_full

	# Delete rollback bootloader entries
	rm /boot/loader/entries/*-rollback-*.conf 2> /dev/null

	for d in $(ls $snapshot_mnt); do
	    case $d in
		''|*[!0-9]*)
		    continue
		    ;;
		*)
		    if [ "$d" != "$current_subvol_short" ]; then
			btrfs sub delete $snapshot_mnt/$d
		    fi
		    ;;
	    esac
	done
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
    for k in $(ls $1/lib/modules); do
	echo "vmlinuz-$k"
    done
}

initrds()
{
    for k in $(ls $1/lib/modules); do
	echo "initramfs-$k.img"
    done
}

generate_bls_snippet()
{
    kversion=$1
    rel_bootdir=${current_subvol_short_bootdir#/boot}
    echo "title Fedora ($kversion) $releasever rollback-$current_subvol_short"
    echo "version $kversion"
    echo "linux $rel_bootdir/vmlinuz-$kversion"
    echo "initrd $rel_bootdir/initramfs-$kversion.img"
    echo "options root=UUID=$uuid ro rootflags=subvol=$current_subvol_full $GRUB_CMDLINE_LINUX"
    echo "grub_users \$grub_users"
    echo "grub_arg --unrestricted"
    echo "grub_class kernel"
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

    let "j=0"
    for kversion in $(ls /lib/modules); do
	k="vmlinuz-$kversion"
	i="initramfs-${kversion}.img"
	blsname="$machineid-rollback-$j.conf"

	if ! [ -f $current_subvol_short_bootdir/$k ]; then
	    if ! ln /boot/$k $current_subvol_short_bootdir/$k; then
		echo "Error: failed to hard-link /boot/$k to $current_subvol_short_bootdir/$k" >&2
		exit 1
	    fi
	    echo "Backed up /boot/$k to $current_subvol_short_bootdir/$k" >&3
	fi

	if ! [ -f $current_subvol_short_bootdir/$i ]; then
	    if ! ln /boot/$i $current_subvol_short_bootdir/$i; then
		echo "Error: failed to hard-link /boot/$i to $current_subvol_short_bootdir/$i" >&2
		exit 1
	    fi
	    echo "Backed up /boot/$i to $current_subvol_short_bootdir/$i" >&3
	fi

	if ! generate_bls_snippet $kversion > /boot/loader/entries/$blsname; then
	    echo "Error: failed to generate bootloader entry for kernel $kversion" >&2
	    exit 1
	else
	    echo "Generated boot loader entry /boot/loader/entries/$blsname" >&3
	fi
	let "j+=1"
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
    -n)
	shift
	next_subvol_short=$1
	shift
	;;
    *)
    ;;
esac

init_vars

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
	backup_bootdir
	mount_snapshots
	snapshot $current_subvol_short $next_subvol_short
	mark_staging $next_subvol_short
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
    generate-bls)
	shift
	generate_bls_snippet $@
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
