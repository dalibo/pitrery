#!@BASH@
#
# Copyright 2011-2013 Nicolas Thauvin. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

# Hard coded configuration 
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
local_xlog="no"
xlog_dir=/var/lib/pgsql/archived_xlog

usage() {
    echo "`basename $0` cleans old PITR backups"
    echo "usage: `basename $0` [options] [hostname]"
    echo "options:"
    echo "    -L           Purge a local store"
    echo "    -l label     Label to process"
    echo "    -b dir       Backup directory"
    echo "    -u username  Username for SSH login to the backup host"
    echo "    -n host      Host storing archived WALs"
    echo "    -U username  Username for SSH login to WAL storage host"
    echo "    -X dir       Archived WALs directory"
    echo
    echo "    -m count     Keep this number of backups"
    echo "    -d days      Purge backups older than this number of days"
    echo
    echo "    -?           Print help"
    echo
    exit $1
}

info() {
    echo "INFO: $*"
}

error() {
    echo "ERROR: $*" 1>&2
    if [ -n "$tmp_dir" ]; then
	[ -d "$tmp_dir" ] && rm -rf $tmp_dir
    fi
    exit 1
}

warn() {
    echo "WARNING: $*" 1>&2
}

# CLI options
args=`getopt "Ll:b:u:n:U:X:m:d:?" $*`
if [ $? -ne 0 ]
then
    usage 2
fi

set -- $args
for i in $*
do
    case "$i" in
        -L) local_backup="yes"; shift;;
	-l) label_prefix=$2; shift 2;;
	-b) backup_root=$2; shift 2;;
	-u) ssh_user=$2; shift 2;;
	-n) xlog_host=$2; shift 2;;
	-U) xlog_ssh_user=$2; shift 2;;
	-X) xlog_dir=$2; shift 2;;
	-m) max_count=$2; shift 2;;
	-d) max_days=$2; shift 2;;

        -\?) usage 1;;
        --) shift; break;;
    esac
done

target=$1
# Destination host is mandatory unless the backup is local
if [ -z "$target" ] && [ $local_backup != "yes" ]; then
    echo "ERROR: missing target host" 1>&2
    usage 1
fi

# Either -m or -d must be specified
if [ -z "$max_count" -a -z "$max_days" ]; then
    echo "ERROR: missing purge condition. Use -m or -d." 1>&2
    usage 1
fi

# When the host storing the WAL files is not given, use the host of the backups
if [ -z "$xlog_host" ]; then
    local_xlog="yes"
    xlog_host=$target
fi
[ -z "$xlog_ssh_user" ] && xlog_ssh_user=$ssh_user

# Prepare the IPv6 address for use with SSH
[ -z "$target" ] || echo $target | grep -q ':' && target="[${target}]"
[ -z "$xlog_host" ] || echo $xlog_host | grep -q ':' && xlog_host="[${xlog_host}]"

# We need a temporary directory
tmp_dir=`mktemp -d -t pg_pitr.XXXXXXXXXX`
if [ $? != 0 ]; then
    error "could not create temporary directory"
fi

# Get the list of backups
info "searching backups"
if [ $local_backup = "yes" ]; then
    list=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/"
    fi
else
    list=`ssh ${ssh_user:+$ssh_user@}$target "ls -d $backup_root/$label_prefix/[0-9]*" 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/ on $target"
    fi
fi

# Get the stop time timestamp of each backup, comparing timestamps is better
backup_list=$tmp_dir/backup_list
cat /dev/null > $backup_list
for dir in $list; do
    if [ $local_backup = "yes" ]; then
	ts=`cat $dir/backup_timestamp 2>/dev/null`
    else
	ts=`ssh ${ssh_user:+$ssh_user@}$target "cat $dir/backup_timestamp" 2>/dev/null`
    fi
    echo "$dir|$ts"
done | sort -n -t '|' -k 1 > $backup_list

# If a minimum number of backup must be kept, remove the $max_count
# youngest backups from the list.
remove_list=$tmp_dir/remove_list
cat /dev/null > $remove_list
if [ -n "$max_count" ] && [ "$max_count" -ge 0 ]; then
    head -n -$max_count $backup_list > $remove_list
else
    cp $backup_list $remove_list
fi

# If older backups must be removed, filter matching backups in the
# list
purge_list=$tmp_dir/purge_list
cat /dev/null > $purge_list
if [ -n "$max_days" ] && [ "$max_days" -ge 0 ]; then
    limit_ts=$(($(date +%s) - 86400 * $max_days))
    for line in `cat $remove_list`; do
	backup_ts=`echo $line | cut -d '|' -f 2`
	[ -z "$backup_ts" ] && continue
	if [ $backup_ts -lt $limit_ts ]; then
	    echo $line >> $purge_list
	fi
    done
else
    cp $remove_list $purge_list
fi

if [ `cat $purge_list | wc -l` = 0 ]; then
    info "there are no backups to purge"
fi

# Purge the backups
for line in `cat $purge_list`; do
    dir=`echo $line | cut -d '|' -f 1`
    if [ $local_backup = "yes" ]; then
	info "purging $dir"
	rm -rf $dir
	if [ $? != 0 ]; then
	    warn "Unable to remove $dir"
	fi
    else
	info "purging $dir"
	ssh ${ssh_user:+$ssh_user@}$target "rm -rf $dir" 2>/dev/null
	if [ $? != 0 ]; then
	    warn "Unable to remove $target:$dir"
	fi
    fi
done

# To be able to purge the archived xlogs, the backup_label of the oldest backup
# is needed to find the oldest xlog file to keep.

# First get the backup_label, it contains the name of the oldest WAL file to keep
if [ $local_backup = "yes" ]; then
    backup_label=`ls $backup_root/$label_prefix/[0-9]*/backup_label 2>/dev/null | head -1`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/"
    fi
else
    remote_backup_label=`ssh ${ssh_user:+$ssh_user@}$target "ls -d $backup_root/$label_prefix/[0-9]*/backup_label" 2>/dev/null | head -1`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/ on $source"
    fi
    
    if [ -n "$remote_backup_label" ]; then
	scp ${ssh_user:+$ssh_user@}$target:$remote_backup_label $tmp_dir >/dev/null 2>&1
	if [ $? != 0 ]; then
	    error "could not copy backup label from $target"
	fi
	backup_label=$tmp_dir/backup_label
    else
	warn "could not find the backup label of the oldest backup, WAL won't be purged"
    fi
fi

if [ -z "$backup_label" ]; then
    info "no backup found after purge. Please remove old archives by hand."
    # Clean temporary directory
    if [ -d "$tmp_dir" ]; then
	rm -rf $tmp_dir
    fi
    exit
fi

# Extract the name of the WAL file from the backup history file, and
# split it in timeline, log and segment
wal_file=`grep '^START WAL LOCATION' $backup_label | cut -d' ' -f 6 | sed -e 's/[^0-9A-F]//g'`
max_tln=$((16#`echo $wal_file | cut -b 1-8`))
max_log=$((16#`echo $wal_file | cut -b 9-16`))
max_seg=$((16#`echo $wal_file | cut -b 17-24`))

info "purging WAL files older than `basename $wal_file`"

# List the WAL files and remove the old ones based on their name
# which are ordered in time by their naming scheme
if [ $local_xlog = "yes" ]; then
    wal_list=`ls $xlog_dir 2>/dev/null | grep '^[0-9AF]'`
    if [ $? != 0 ]; then
	error "could not list the content of $xlog_dir"
    fi
else
    wal_list=`ssh ${xlog_ssh_user:+$xlog_ssh_user@}$xlog_host "ls $xlog_dir | grep '^[0-9AF]'" 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $xlog_dir on $xlog_host"
    fi
fi

# Compare and remove files from the list
i=0
for wal in $wal_list; do
    # filename with compression suffix
    file=`basename $wal`
    # filename without compression suffix
    echo $file | grep -qE '\.(backup|history)$'
    if [ $? != 0 ]; then
	w=`echo $file | sed -r -e 's/\.[^\.]+$//'`
    else
	w=$file
    fi

    # only work on wal files and backup_labels
    echo $w | grep -qE '^[0-9A-F]+$'
    is_wal=$?

    echo $w | grep -qE '^[0-9A-F]+\.[0-9A-F]+.backup$'
    is_bl=$?

    if [ $is_wal != 0 -a $is_bl != 0 ]; then
	continue
    fi

    # split the wal filename in timeline, log and segment for comparison
    tln=$((16#`echo $w | cut -b 1-8`))
    log=$((16#`echo $w | cut -b 9-16`))
    seg=$((16#`echo $w | cut -b 17-24`))

    # when the wal file name is "lower", it is older. remove it.
    if [ $tln -le $max_tln ] && [ $log -eq $max_log -a $seg -lt $max_seg -o $log -lt $max_log ]; then
	if [ $local_xlog = "yes" ]; then
	    rm $xlog_dir/$file
	    if [ $? != 0 ]; then
		warn "unable to remove $wal"
	    else
		i=$(($i + 1))
	    fi
	else
	    ssh ${xlog_ssh_user:+$xlog_ssh_user@}$xlog_host "rm $xlog_dir/$file" 2>/dev/null
	    if [ $? != 0 ]; then
		warn "unable to remove $file on $xlog_host"
	    else
		i=$(($i + 1))
	    fi
	fi
    fi
done

info "$i old WAL file(s) removed"

# Clean temporary directory
if [ -d "$tmp_dir" ]; then
    rm -rf $tmp_dir
fi

info "done"
