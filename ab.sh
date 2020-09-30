#! /bin/bash

# This script assumes that your root is mounted at vg0/wsroot[0,1].

vg="vg0"
lv0="wsroot0"
lv1="wsroot1"
vg_dm_prefix="/dev/mapper/$vg-"
root_mnt=$(findmnt -n -o SOURCE /)

exec 3>/dev/null

current_lv=${root_mnt#$vg_dm_prefix}
next_lv=""


case "$current_lv" in
    "$lv0")
	next_lv="$lv1"
	;;
    "$lv1")
	next_lv="$lv0"
	;;
    *)
	"Error: could not recognize mounted lv $current_lv"
	exit 1
esac

current_lv_staging="${current_lv}_staging"
next_lv_staging="${next_lv}_staging"

echo "Current LV is $current_lv, next LV is $next_lv." >&3
next_lv_mnt="/mnt/${next_lv}"

print_usage()
{
    echo "Usage: ab [-v] COMMAND"
    echo "where COMMAND is one of mount|umount|next-lv|snapshot|dnf|finalize|compare|cleanup."
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
    lv=$1
    lv_snap=$2
    
    if [ "$lv" = "$lv_snap" ]; then
	echo "Error: $lv and $lv_snap are the same logical volume. Exiting." >&2
	exit
    fi
    if [ -L "/dev/$vg/$lv_snap" ]; then
	echo "Overwriting existing LV $vg/$lv_snap." >&3
	exec 3>&-
	lvremove -y $vg/$lv_snap
    fi

    exec 3>&-
    if ! lvcreate -s -n $lv_snap $vg/$lv; then
	echo "Error: failed to make snapshot $lv_snap of LV $vg/$lv." >&2
	exit 1
    fi
    lvchange -kn $vg/$lv_snap
    lvchange -ay $vg/$lv_snap
    
    exec 3>/dev/null
    echo "Created snapshot $vg/$lv_snap of logical volume $vg/$lv" >&3

}

edit_grubenv()
{
    test_uid
    lv=$1
    lv_new=$2
    grubenv="/boot/efi/EFI/fedora/grubenv"
    grubenv_new=${grubenv}_new
    
    
    sed "s/$lv/$lv_new/" $grubenv > $grubenv_new
    if [ -f $grubenv_new ]; then
	mv $grubenv_new $grubenv
    else
	echo "Error: could not write new grub configuration to $grubenv_new." >&2
	exit 1
    fi
}


prepare_mount_point()
{
    test_uid
    if ! [ -d "$next_lv_mnt" ]; then
	mkdir -p "$next_lv_mnt"
    fi

    if findmnt $next_lv_mnt > /dev/null; then
	echo "LV $next_lv already mounted at $next_lv_mnt. Unmounting." >&3
	if ! umount -R $next_lv_mnt; then
	    echo "Error: failed to unmount $next_lv_mnt." >&2
	    exit 1
	fi    
    fi
}


mount_next_lv()
{
    test_uid
    if [ "$1" = "-s" ]; then
	if ! mount /dev/$vg/$next_lv_staging $next_lv_mnt; then
	    echo "Error: could not mount LV $next_lv_staging at $next_lv_mnt" >&2
	    exit 1
	fi
	echo "Mounted /dev/$vg/$next_lv_staging at $next_lv_mnt." >&3
    elif [ $# -ge 1 ]; then
	echo "Error: unrecognized option $1." >&2
	exit 1
    else
	echo "Mounting /dev/$vg/next_lv read-only at $next_lv_mnt." >&3
	if ! mount -o,ro /dev/$vg/$next_lv $next_lv_mnt; then
	    echo "Error: could not mount LV $next_lv at $next_lv_mnt" >&2
	    exit 1
	fi
    fi
    
    for d in boot dev proc sys; do
	if ! mount --bind /$d $next_lv_mnt/$d; then
	    echo "Error: failed to bind-mount /$d to $next_lv_mnt/$d." >&2
	    exit 1
	fi
    done
}   


run_dnf_transaction()
{
    test_uid
    prepare_mount_point
    mount_next_lv -s
    echo "Running \"dnf $@\" in root $next_lv_mnt." >&3
    if dnf --installroot=$next_lv_mnt --releasever=32 $@; then
	echo "dnf operation succeeded." >&3
    else
	dnf_retval=$?
	echo "dnf operation failed." >&3
	exit $dnf_retval
    fi
}

prepare_next_boot()
{
    test_uid
    echo "Editing fstab." >&3
    if ! sed -i.bak "s/$current_lv/$next_lv/" $next_lv_mnt/etc/fstab; then
       echo "Error: could not edit fstab of $next_lv_staging." >&2
       exit 1
    fi
    prepare_mount_point
    snapshot $next_lv_staging $next_lv
    echo "Editing kernel boot parameters." >&3
    edit_grubenv $current_lv $next_lv
}

compare_rpmdb()
{
    test_uid
    prepare_mount_point
    mount_next_lv
    rpm -qa | sort > /tmp/rpmdb_current
    if [ "$1" = "--previous" ]; then
	rpm --dbpath $next_lv_mnt/var/lib/rpm -qa | sort > /tmp/rpmdb_previous
	diff -u /tmp/rpmdb_previous /tmp/rpmdb_current
    else
	rpm --dbpath $next_lv_mnt/var/lib/rpm -qa | sort > /tmp/rpmdb_next	
	diff -u /tmp/rpmdb_current /tmp/rpmdb_next
    fi
}

cleanup()
{
    test_uid
    prepare_mount_point
    edit_grubenv $next_lv $current_lv
    exec 3>&-
    if [ -L "/dev/$vg/$next_lv_staging" ]; then
	lvremove -y $vg/$next_lv_staging
    fi

    if [ -L "/dev/$vg/$current_lv_staging" ]; then
	lvremove -y $vg/$current_lv_staging
    fi
    
    if [ "$1" = "-a" ]; then
	if [ -L "/dev/$vg/$next_lv" ]; then
	    lvremove -y $vg/$next_lv
	fi
    fi

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
	prepare_mount_point
	mount_next_lv $@
	;;
    umount)
	prepare_mount_point
	;;
    next-lv)
	echo $next_lv
	;;
    snapshot)
	shift
	prepare_mount_point
	snapshot $current_lv $next_lv_staging
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
    cleanup)
	shift
	cleanup $@
	;;
    *)
	print_usage
	;;
esac
