#!@BASH@
#
# Copyright 2011 Nicolas Thauvin. All rights reserved.
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

# Default configuration
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
pgdata=/var/lib/pgsql/data
owner=`id -un`
restore_prog=@BINDIR@/restore_xlog
archive_dir=/var/lib/pgsql/archived_xlog

usage() {
    echo "`basename $0` performs a PITR restore"
    echo 
    echo "Usage:"
    echo "    `basename $0` [options] [hostname]"
    echo
    echo "Restore options:"
    echo "    -L              Restore from local storage"
    echo "    -b dir          Backup storage directory"
    echo "    -l label        Label used when backup was performed"
    echo "    -D dir          Path to target \$PGDATA"
    echo "    -X dir          Path to the archived xlog directory"
    echo "    -d date         Restore until this date"
    echo "    -O user         If run by root, owner of the files"
    echo "    -r prog         Program to use in restore_command"
    echo
    echo "    -?              Print help"
    echo
    exit $1
}

error() {
    echo "ERROR: $*" 1>&2
    exit 1
}

info() {
    echo "INFO: $*"
}

check_and_fix_directory() {
    [ $# = 1 ] || return 1
    local dir=$1

    # Check if directory exists
    if [ ! -d "$dir" ]; then
	info "creating $dir"
	mkdir -p $dir
	if [ $? != 0 ]; then
	    error "could not create $dir"
	fi
	info "setting permissions of $dir"
	chmod 700 $dir

	# Change owner of directory only if run as root
	if [ `id -u` = 0 ]; then
	    info "setting owner of $dir"
	    chown ${owner}: $dir
	    if [ $? != 0 ]; then
		error "could not change owner of $dir to $owner"
	    fi
	fi
    fi

    # Check if directory is empty
    info "checking if $dir is empty"
    ls $dir >/dev/null 2>&1
    ls_rc=$?
    content=`ls $dir 2>/dev/null | wc -l`
    wc_rc=$?
    if [ $ls_rc != 0 ] || [ $wc_rc != 0 ]; then
	error "could not check if $dir is empty"
    fi

    if [ $content != 0 ]; then
	# XXX add a switch to force
	error "$dir is not empty. Contents won't be overridden"
    fi
    
    # Check owner
    downer=`stat -c %U $dir 2>/dev/null`
    if [ $? != 0 ]; then
	error "Unable to get owner of $dir"
	exit 1
    fi

    if [ $downer != $owner ]; then
	if [ `id -u` = 0 ]; then
	    info "setting owner of $dir"
	    chown ${owner}: $dir
	    if [ $? != 0 ]; then
		error "could not change owner of $dir to $owner"
	    fi
	else
	    error "$dir must be owned by $owner"
	fi
    fi

    # Check permissions
    dperms=`stat -c %a $dir 2>/dev/null`
    if [ $? != 0 ]; then
	error "Unable to get permissions of $dir"
    fi

    if [ $dperms != "700" ]; then
	info "setting permissions of $dir"
	chmod 700 $dir
    fi

    return 0
}


# Process CLI Options
while getopts "Lb:l:D:X:d:O:r:?" opt; do
    case "$opt" in
	L) local_backup="yes";;
	b) backup_root=$OPTARG;;
	l) label_prefix=$OPTARG;;
	D) pgdata=$OPTARG;;
	X) archive_dir=$OPTARG;;
	d) target_date=$OPTARG;;
	O) owner=$OPTARG;;
	r) restore_prog=$OPTARG;;
	"?") usage 1;;
	*) error "Unknown error while processing options";;
    esac
done
#set -- "${@:$OPTIND}"

source=${@:$OPTIND:1}

# Storage host is mandatory unless stored locally
if [ -z "$source" ] && [ $local_backup != "yes" ]; then
    echo "FATAL: missing target host" 1>&2
    usage 1
fi

# XXX check input date

# find the backup according to given date: $backup_dir
info "searching backup directory"
if [ -n "$target_date" ]; then
    info "target date is: $target_date"

    # date format is numerically ordered
    tdate=`echo $target_date | sed -e 's/[^0-9]//g'`

    # search the store
    if [ $local_backup = "yes" ]; then
	list=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/"
	fi
    else
	list=`ssh $source "ls -d $backup_root/$label_prefix/[0-9]*" 2>/dev/null`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/ on $source"
	fi
    fi

    # find the latest backup
    for d in $list; do
	d=`basename $d`
	bdate=`echo $d | sed -e 's/[\.-]//g'`
	if [ $bdate -gt $tdate ]; then
	    break
	else
	    backup_date=$d
	fi
    done

    if [ -z "$backup_date" ]; then
	error "Could not find a backup at given date $target_date"
    fi
else
    # get the latest
    if [ $local_backup = "yes" ]; then
	backup_date=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null | tail -1`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/"
	fi
    else
	backup_date=`ssh $source "ls -d $backup_root/$label_prefix/[0-9]*" 2>/dev/null | tail -1`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/ on $source"
	fi
    fi

    backup_date=`basename $backup_date`
    if [ -z "$backup_date" ]; then
	error "Could not find a backup"
    fi
fi

backup_dir=$backup_root/$label_prefix/$backup_date

info "backup directory is $backup_dir"

# Check target directories
# get the tablespace list and check the directories
if [ $local_backup = "yes" ]; then
    if [ -f $backup_dir/tblspc_list ]; then
	tblspc_list=$backup_dir/tblspc_list
    fi
else
    ssh $source "test -f $backup_dir/tblspc_list" 2>/dev/null
    if [ $? = 0 ]; then
	tmp_dir=`mktemp -d -t pg_pitr.XXXXXXXXXX`
	if [ $? != 0 ]; then
	    error "could not create temporary directory"
	fi
	scp $source:$backup_dir/tblspc_list $tmp_dir >/dev/null 2>&1
	if [ $? != 0 ]; then
	    error "could not copy the list of tablespaces from backup store"
	fi
	tblspc_list=$tmp_dir/tblspc_list
    fi
fi

# Check the tablespaces directory and create them if possible
[ -n "$tblspc_list" ] && cat $tblspc_list | while read l; do
    name=`echo $l | cut -d '|' -f 1`
    tbldir=`echo $l | cut -d '|' -f 2`

    check_and_fix_directory $tbldir
    if [ $? != 0 ]; then
	echo "ERROR: bad tablespace location path in list for $name. Check $tblspc_list" 1>&2
	continue
    fi
done

# Same goes for PGDATA
check_and_fix_directory $pgdata

# Extract everything
# pgdata
info "extracting PGDATA to $pgdata"
was=`pwd`
cd $pgdata
if [ $local_backup = "yes" ]; then
    tar xzf $backup_dir/pgdata.tar.gz
    if [ $? != 0 ]; then
	echo "ERROR: could extract $backup_dir/pgdata.tar.gz to $pgdata" 1>&2
	cd $was
	exit 1
    fi
else
    ssh $source "cat $backup_dir/pgdata.tar.gz" 2>/dev/null | tar xzf - 2>/dev/null
    rc=(${PIPESTATUS[*]})
    ssh_rc=${rc[0]}
    tar_rc=${rc[1]}
    if [ $ssh_rc != 0 ] || [ $tar_rc != 0 ]; then
	echo "ERROR: could extract $source:$backup_dir/pgdata.tar.gz to $pgdata" 1>&2
	cd $was
	exit 1
    fi
fi
cd $was

# tablespaces
[ -n "$tblspc_list" ] && for l in `cat $tblspc_list`; do
    name=`echo $l | cut -d '|' -f 1`
    tbldir=`echo $l | cut -d '|' -f 2`

    info "extracting tablespace \"${name}\" to $tbldir"
    was=`pwd`
    cd $tbldir
    if [ $local_backup = "yes" ]; then
	tar xzf $backup_dir/tblspc/${name}.tar.gz
	if [ $? != 0 ]; then
	    echo "ERROR: could not extract tablespace $name to $tbldir" 1>&2
	    cd $was
	    exit 1
	fi
    else
	ssh $source "cat $backup_dir/tblspc/${name}.tar.gz" 2>/dev/null | tar xzf - 2>/dev/null
	rc=(${PIPESTATUS[*]})
	ssh_rc=${rc[0]}
	tar_rc=${rc[1]}
	if [ $ssh_rc != 0 ] || [ $tar_rc != 0 ]; then
	    echo "ERROR: could not extract tablespace $name to $tbldir" 1>&2
	    cd $was
	    exit 1
	fi
    fi
    cd $was
done

# Create pg_xlog directory if needed
if [ ! -d $pgdata/pg_xlog/archive_status ]; then
    info "preparing pg_xlog directory"
    mkdir -p $pgdata/pg_xlog/archive_status
    if [ $? != 0 ]; then
	error "could not create $pgdata/pg_xlog"
    fi

    if [ `id -u` = 0 ]; then
	chown -R ${owner}: $pgdata/pg_xlog
	if [ $? != 0 ]; then
	    error "could not change owner of $dir to $owner"
	fi
    fi
fi

# Create a recovery.conf file in $PGDATA
info "preparing recovery.conf file"
prog=`basename $restore_prog`
if [ $prog = "restore_xlog" ]; then
    if [ $local_backup = "yes" ]; then
	restore_prog="$restore_prog -n 127.0.0.1 -d $archive_dir %f %p"
    else
	restore_prog="$restore_prog -n $source -d $archive_dir %f %p"
    fi
fi
echo "restore_command = '$restore_prog'" > $pgdata/recovery.conf
if [ -n "$target_date" ]; then
    echo "recovery_target_time = '$target_date'" >> $pgdata/recovery.conf
fi

# Cleanup
if [ -n "$tmpdir" ]; then
    rm -rf $tmpdir
fi

info "done"
info "please check directories and recovery.conf before starting the cluster"
