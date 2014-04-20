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

# Default configuration
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
pgdata=/var/lib/pgsql/data
owner=`id -un`
archive_dir=/var/lib/pgsql/archived_xlog
dry_run="no"
rsync_opts="-q --whole-file" # Remote only
uncompress_bin="gunzip"
compress_suffix="gz"

usage() {
    echo "`basename $0` performs a PITR restore"
    echo 
    echo "Usage:"
    echo "    `basename $0` [options] [hostname]"
    echo
    echo "Restore options:"
    echo "    -L                   Restore from local storage"
    echo "    -u username          Username for SSH login to the backup host"
    echo "    -b dir               Backup storage directory"
    echo "    -l label             Label used when backup was performed"
    echo "    -D dir               Path to target \$PGDATA"
    echo "    -x dir               Path to the xlog directory (only if outside \$PGDATA)"
    echo "    -d date              Restore until this date"
    echo "    -O user              If run by root, owner of the files"
    echo "    -t tblspc:dir        Change the target directory of tablespace \"ts\""
    echo "                           this switch can be used many times"
    echo "    -n                   Dry run: show restore information only"
    echo "    -c compress_bin      Uncompression command for tar method"
    echo "    -e compress_suffix   Suffix added by the compression program"
    echo
    echo "Archived WAL files options:"
    echo "    -A                   Force the use of local archives"
    echo "    -h host              Host storing WAL files"
    echo "    -U username          Username for SSH login to WAL storage host"
    echo "    -X dir               Path to the archived xlog directory"
    echo "    -r cli               Command line to use in restore_command"
    echo "    -C                   Do not uncompress WAL files"
    echo "    -S                   Send messages to syslog"
    echo "    -f facility          Syslog facility"
    echo "    -i ident             Syslog ident"
    echo
    echo "    -?                   Print help"
    echo
    exit $1
}

error() {
    echo "ERROR: $*" 1>&2

    # Clean tmp dir
    if [ -n "$tmp_dir" ]; then
	rm -rf $tmp_dir
    fi
    exit 1
}

warn() {
    echo "WARNING: $*" 1>&2
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
    else
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
	    error "$dir is not empty. Contents won't be overridden"
	fi
    fi
    
    # Check owner
    downer=`stat -c %U $dir 2>/dev/null`
    if [ $? != 0 ]; then
	error "Unable to get owner of $dir"
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
while getopts "Lu:b:l:D:x:d:O:t:nc:e:Ah:U:X:r:CSf:i:?" opt; do
    case "$opt" in
	L) local_backup="yes";;
	u) ssh_user=$OPTARG;;
	b) backup_root=$OPTARG;;
	l) label_prefix=$OPTARG;;
	D) pgdata=$OPTARG;;
	x) pgxlog=$OPTARG;;
	d) target_date=$OPTARG;;
	O) owner=$OPTARG;;
	t) tsmv_list="$tsmv_list $OPTARG";;
	n) dry_run="yes";;
	c) uncompress_bin="$OPTARG";;
	e) compress_suffix=$OPTARG;;

	A) archive_local="yes";;
	h) archive_host=$OPTARG;;
	U) archive_ssh_user=$OPTARG;;
	X) archive_dir=$OPTARG;;
	r) restore_cli="$OPTARG";;
	C) archive_compress="no";;
	S) syslog="yes";;
	f) syslog_facility=$OPTARG;;
	i) syslog_ident=$OPTARG;;


	"?") usage 1;;
	*) error "Unknown error while processing options";;
    esac
done

source=${@:$OPTIND:1}

# Storage host is mandatory unless stored locally
if [ -z "$source" ] && [ $local_backup != "yes" ]; then
    echo "ERROR: missing target host" 1>&2
    usage 1
fi

if [ -n "$target_date" ]; then
    # Check input date. The format is 'YYYY-MM-DD HH:MM:SS [(+|-)XXXX]'
    # with XXXX the timezone offset on 4 digits Having the timezone on 4
    # digits let us use date to convert it to a timestamp for comparison
    echo $target_date | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}( *[+-][0-9]{4})?$'
    if [ $? != 0 ]; then
	error "bad target date format. Use 'YYYY-MM-DD HH:MM:SS [(+|-)TZTZ]' with an optional 4 digit (hours and minutes) timezone offset"
    fi

    target_timestamp=`date -d "$target_date" -u +%s`
fi

if [ $? != 0 ]; then
    error "could not get timestamp from target date. Check your date command"
fi

# An unprivileged target owner is mandatory as PostgreSQL cannot run
# as root.
if [ `id -u $owner` = 0 ]; then
    error "the target owner cannot not be root. Use -O when restoring as root"
fi

# When no restore_command is given, build it using restore_xlog
if [ -z "$restore_cli" ]; then
    restore_command="@BINDIR@/restore_xlog"
    if [ "$archive_local" = "yes" ]; then
	restore_command="$restore_command -L"
    else
	if [ -n "$archive_host" ]; then
	    restore_command="$restore_command -h $archive_host"
	    [ -n "$archive_ssh_user" ] && restore_command="$restore_command -u $archive_ssh_user"
	else
	    # Prevent restore_xlog from failing afterwards when restore is
	    # remote and no host is proveided
	    echo "ERROR: not enough information for restoring archived WAL, use -A or -h host."
	    usage 1
	fi
    fi
    [ -n "$archive_dir" ] && restore_command="$restore_command -d $archive_dir"
    [ "$archive_compress" = "no" ] && restore_command="$restore_command -X"
    if [ "$syslog" = "yes" ]; then
	restore_command="$restore_command -S"
	[ -n "$syslog_facility" ] && restore_command="$restore_command -f $syslog_facility"
	[ -n "$syslog_ident" ] && restore_command="$restore_command -t $syslog_ident"
    fi

    restore_command="$restore_command %f %p"
else
    restore_command="$restore_cli"
fi



# Find the backup according to given date.  The target date converted
# to a timestamp is compared to the timestamp of the stop time of the
# backup. Only after the stop time a backup is sure to be consistent.
info "searching backup directory"
if [ -n "$target_date" ]; then

    # search the store
    if [ $local_backup = "yes" ]; then
	list=`ls $backup_root/$label_prefix/*/backup_timestamp 2>/dev/null`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/"
	fi
    else
	list=`ssh ${ssh_user:+$ssh_user@}$source "ls -d $backup_root/$label_prefix/*/backup_timestamp" 2>/dev/null`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/ on $source"
	fi
    fi

    # find the latest backup
    for t in $list; do
	d=`dirname $t`
	
	# get the timestamp of the end of the backup
	if [ $local_backup = "yes" ]; then
	    backup_timestamp=`cat $t`
	    if [ $? != 0 ]; then
		warn "could not get the ending timestamp of $t"
		continue
	    fi
	else
	    backup_timestamp=`ssh ${ssh_user:+$ssh_user@}$source cat $t 2>/dev/null`
	    if [ $? != 0 ]; then
		warn "could not get the ending timestamp of $t"
		continue
	    fi
	fi

	if [ $backup_timestamp -ge $target_timestamp ]; then
	    break;
	else
	    backup_date=`basename $d`
	fi
    done

    if [ -z "$backup_date" ]; then
	error "Could not find a backup at given date $target_date"
    fi

else
    # get the latest
    if [ $local_backup = "yes" ]; then
	backup_list_date=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null | tail -1`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/"
	fi
    else
	backup_list_date=`ssh ${ssh_user:+$ssh_user@}$source "ls -d $backup_root/$label_prefix/[0-9]*" 2>/dev/null`
	if [ $? != 0 ]; then
	    error "could not list the content of $backup_root/$label_prefix/ on $source"
	fi
	backup_list_date=`echo $backup_list_date | tr ' ' '\n' | tail -1`
	if [ $? != 0 ]; then
	    error "could not find a backup from $backup_root/$label_prefix/ on $source"
	fi
    fi

    if [ -z "$backup_list_date" ]; then
	error "Could not find a backup"
    else
	backup_date=`basename $backup_list_date`
	if [ -z "$backup_date" ]; then
	    error "Could not find a backup"
	fi
    fi
fi

backup_dir=$backup_root/$label_prefix/$backup_date

# we need a temporary directory for some files
tmp_dir=`mktemp -d -t pitrery.XXXXXXXXXX`
if [ $? != 0 ]; then
    error "could not create temporary directory"
fi

# get the tablespace list and check the directories
info "searching for tablespaces information"
if [ $local_backup = "yes" ]; then
    if [ -f $backup_dir/tblspc_list ]; then
	tblspc_list=$backup_dir/tblspc_list
    fi
else
    ssh ${ssh_user:+$ssh_user@}$source "test -f $backup_dir/tblspc_list" 2>/dev/null
    if [ $? = 0 ]; then
	scp ${ssh_user:+$ssh_user@}$source:$backup_dir/tblspc_list $tmp_dir >/dev/null 2>&1
	if [ $? != 0 ]; then
	    error "could not copy the list of tablespaces from backup store"
	fi
	tblspc_list=$tmp_dir/tblspc_list
    fi
fi

# Prepare a temporary file with the final list of tablespace directories
tblspc_reloc=$tmp_dir/tblspc_reloc
if [ -f "$tblspc_list" ]; then
    while read l; do
	name=`echo $l | cut -d '|' -f 1`
	tbldir=`echo $l | cut -d '|' -f 2`
	oid=`echo $l | cut -d '|' -f 3`
	reloc="no"

	# skip pg_default and pg_global, they are located inside PGDATA
	[ -z "$tbldir" ] && continue

	for t in $tsmv_list; do
	    tname="`echo $t | cut -d ':' -f 1`"
	    # relocation can be done using the name or the oid of the tablespace
	    if [ "$tname" = "$name" -o $tname = $oid ]; then
		[ "$tbldir" != "`echo $t | cut -d ':' -f 2`" ] && reloc="yes"
		tbldir="`echo $t | cut -d ':' -f 2`"
		break
	    fi
	done
	echo "${name}|$tbldir|$oid|$reloc" >> $tblspc_reloc
    done < $tblspc_list
fi


# Display some info on the restore
info
info "backup directory:"
info "  $backup_dir"
info
info "destinations directories:"
info "  PGDATA -> $pgdata"

[ -n "$pgxlog" ] && info "  PGDATA/pg_xlog -> $pgxlog"

if [ -f "$tblspc_reloc" ]; then
    while read l; do
	name=`echo $l | cut -d '|' -f 1`
	tbldir=`echo $l | cut -d '|' -f 2`
	oid=`echo $l | cut -d '|' -f 3`
	reloc=`echo $l | cut -d '|' -f 4`

	info "  tablespace \"$name\" ($oid) -> $tbldir (relocated: $reloc)"
    done < $tblspc_reloc
fi

info
info "recovery configuration:"
info "  target owner of the restored files: $owner"
info "  restore_command = '$restore_command'"
[ -n "$target_date" ] && info "  recovery_target_time = '$target_date'"
info 

# Check if tablespace relocation list have duplicates
if [ -f "$tblspc_reloc" ]; then
    tscount=`cat $tblspc_reloc | wc -l`
    tsucount=`cat $tblspc_reloc | awk -F'|' '{ print $2 }' | sort -u | wc -l`
    [ $tsucount -lt $tscount ] && error "found duplicates in tablespace relocations. Check options and the list of tablespaces of the backup"
fi

if [ "$dry_run" = "yes" ]; then
    # Cleanup and exit without error 
    if [ -n "$tmp_dir" ]; then
	rm -rf $tmp_dir
    fi
    exit 0
fi

# Real work starts here

# Check target directories
check_and_fix_directory $pgdata

if [ -n "$pgxlog" ]; then
    echo $pgxlog | grep -q '^/'
    if [ $? != 0 ]; then
	error "pg_xlog must be an absolute path"
    fi

    if [ "$pgxlog" = "$pgdata/pg_xlog" ]; then
	error "xlog path cannot be \$PGDATA/pg_xlog, this path is reserved. It seems you do not need -x"
    fi

    check_and_fix_directory $pgxlog
fi

# Check the tablespaces directory and create them if possible
if [ -f "$tblspc_reloc" ]; then
    while read l; do
	name=`echo $l | cut -d '|' -f 1`
	tbldir=`echo $l | cut -d '|' -f 2`

	check_and_fix_directory $tbldir
	if [ $? != 0 ]; then
	    warn "bad tablespace location path \"$tbldir\" for $name. Check $tblspc_list and -t switches"
	    continue
	fi
    done < $tblspc_reloc
fi

# Find out what storage method is used in the backup. If the PGDATA is
# stored as a gzip'ed tarball, the method is tar, if it is a
# directory, then backup_pitr used rsync to put files there.
if [ $local_backup = "yes" ]; then
    if [ -f "$backup_dir/pgdata.tar.$compress_suffix" ]; then
	storage="tar"
    elif [ -d "$backup_dir/pgdata" ]; then
	storage="rsync"
    else
	error "could not find out what storage method or compression is used in $backup_dir"
    fi
else
    ssh ${ssh_user:+$ssh_user@}$source "test -f $backup_dir/pgdata.tar.$compress_suffix" 2>/dev/null
    if [ $? = 0 ]; then
	storage="tar"
    else
	ssh ${ssh_user:+$ssh_user@}$source "test -d $backup_dir/pgdata" 2>/dev/null
	if [ $? = 0 ]; then
	    storage="rsync"
	else
	    error "could not find out what storage method or compression is used in $source:$backup_dir"
	fi
    fi
fi

# Extract everything
case $storage in
    "tar")
	# pgdata
	info "extracting PGDATA to $pgdata"
	was=`pwd`
	cd $pgdata
	if [ $local_backup = "yes" ]; then
	    $uncompress_bin -c $backup_dir/pgdata.tar.$compress_suffix | tar xf -
	    rc=(${PIPESTATUS[*]})
	    uncompress_rc=${rc[0]}
	    tar_rc=${rc[1]}
	    if [ $uncompress_rc != 0 ] || [ $tar_rc != 0 ]; then
		echo "ERROR: could extract $backup_dir/pgdata.tar.$compress_suffix to $pgdata" 1>&2
		cd $was
		exit 1
	    fi
	else
	    ssh ${ssh_user:+$ssh_user@}$source "cat $backup_dir/pgdata.tar.$compress_suffix" 2>/dev/null | $uncompress_bin | tar xf - 2>/dev/null
	    rc=(${PIPESTATUS[*]})
	    ssh_rc=${rc[0]}
	    uncompress_rc=${rc[1]}
	    tar_rc=${rc[2]}
	    if [ $ssh_rc != 0 ] || [ $uncompress_rc != 0 ] || [ $tar_rc != 0 ]; then
		echo "ERROR: could extract $source:$backup_dir/pgdata.tar.$compress_suffix to $pgdata" 1>&2
		cd $was
		exit 1
	    fi
	fi
	cd $was
	info "extraction of PGDATA successful"
	;;

    "rsync")
	info "transfering PGDATA to $pgdata with rsync"
	if [ $local_backup = "yes" ]; then
	    rsync -aq --delete-before $backup_dir/pgdata/ $pgdata/
	    rc=$?
	    if [ $rc != 0 -a $rc != 24 ]; then
		error "rsync of PGDATA failed with exit code $rc"
	    fi
	else
	    rsync $rsync_opts -e "ssh -c blowfish-cbc -o Compression=no" -a --delete-before ${ssh_user:+$ssh_user@}${source}:$backup_dir/pgdata/ $pgdata/
	    rc=$?
	    if [ $rc != 0 -a $rc != 24 ]; then
		error "rsync of PGDATA failed with exit code $rc"
	    fi
	fi
	info "transfer of PGDATA successful"
	;;

    *)
	error "do not know how to restore... I have a bug"
	;;
esac

# Restore the configuration file in a subdirectory of PGDATA
restored_conf=$pgdata/restored_config_files
if [ $local_backup = "yes" ]; then
    # Check the directory, when configuration files are
    # inside PGDATA it does not exist
    if [ -d $backup_dir/conf ]; then
	info "restoring configuration files to $restored_conf"
	cp -r $backup_dir/conf $restored_conf
	if [ $? != 0 ]; then
	    warn "could not copy $backup_dir/conf to $restored_conf"
	fi
    fi
else
    ssh ${ssh_user:+$ssh_user@}$source "test -d $backup_dir/conf" 2>/dev/null
    if [ $? = 0 ]; then
	info "restoring configuration files to $restored_conf"
	scp -r ${ssh_user:+$ssh_user@}$source:$backup_dir/conf $restored_conf >/dev/null
	if [ $? != 0 ]; then
	    warn "could not copy $source:$backup_dir/conf to $restored_conf"
	fi
    fi
fi

# change owner of PGDATA to the target owner
if [ `id -u` = 0 -a "`id -un`" != $owner ]; then
    info "setting owner of PGDATA ($pgdata)"
    chown -R ${owner}: $pgdata
    if [ $? != 0 ]; then
	error "could not change owner of PGDATA to $owner"
    fi
fi

# tablespaces
if [ -f "$tblspc_reloc" ]; then
    while read l; do
	name=`echo $l | cut -d '|' -f 1`
	_name=`echo $name | sed -re 's/\s+/_/g'` # No space version, we want paths without spaces
	tbldir=`echo $l | cut -d '|' -f 2`
	oid=`echo $l | cut -d '|' -f 3`
	reloc=`echo $l | cut -d '|' -f 4`

	# Change the symlink in pg_tblspc when the tablespace directory changes
	if [ "$reloc" = "yes" ]; then
	    was=`pwd`
	    cd $pgdata/pg_tblspc
	    rm $oid || error "could not remove symbolic link $pgdata/pg_tblspc/$oid"
	    ln -s $tbldir $oid || error "could not update the symbolic of tablespace $name ($oid) to $tbldir"

	    # Ensure the new link has the correct owner, the chown -R
	    # issued after extraction will not do it
	    if [ `id -u` = 0 -a "`id -un`" != $owner ]; then
		chown -h ${owner}: $oid
	    fi
	    cd $was
	fi

	# Get the data in place
	case $storage in
	    "tar")
		info "extracting tablespace \"${name}\" to $tbldir"
		was=`pwd`
		cd $tbldir
		if [ $local_backup = "yes" ]; then
		    $uncompress_bin -c $backup_dir/tblspc/${_name}.tar.$compress_suffix | tar xf -
		    rc=(${PIPESTATUS[*]})
		    uncompress_rc=${rc[0]}
		    tar_rc=${rc[1]}
		    if [ $uncompress_rc != 0 ] || [ $tar_rc != 0 ]; then
			echo "ERROR: could not extract tablespace $name to $tbldir" 1>&2
			cd $was
			exit 1
		    fi
		else
		    ssh -n ${ssh_user:+$ssh_user@}$source "cat $backup_dir/tblspc/${_name}.tar.$compress_suffix" 2>/dev/null | $uncompress_bin | tar xf - 2>/dev/null
		    rc=(${PIPESTATUS[*]})
		    ssh_rc=${rc[0]}
		    uncompress_rc=${rc[1]}
		    tar_rc=${rc[2]}
		    if [ $ssh_rc != 0 ] || [ $uncompress_rc != 0 ] || [ $tar_rc != 0 ]; then
			echo "ERROR: could not extract tablespace $name to $tbldir" 1>&2
			cd $was
			exit 1
		    fi
		fi
		cd $was
		info "extraction of tablespace \"${name}\" successful"
		;;

	    "rsync")
		info "transfering PGDATA to $pgdata with rsync"
		if [ $local_backup = "yes" ]; then
		    rsync -aq --delete-before $backup_dir/tblspc/${_name}/ $tbldir/
		    rc=$?
		    if [ $rc != 0 -a $rc != 24 ]; then
			error "rsync of tablespace \"${name}\" failed with exit code $rc"
		    fi
		else
		    rsync $rsync_opts -e "ssh -c blowfish-cbc -o Compression=no" -a --delete-before ${ssh_user:+$ssh_user@}${source}:$backup_dir/tblspc/${_name}/ $tbldir/
		    rc=$?
		    if [ $rc != 0 -a $rc != 24 ]; then
			error "rsync of tablespace \"${name}\" failed with exit code $rc"
		    fi
		fi
		info "transfer of tablespace \"${name}\" successful"
		;;

	    *)
		error "do not know how to restore... I have a bug"
		;;
	esac

	# change owner of the tablespace files to the target owner
	if [ `id -u` = 0 -a "`id -un`" != $owner ]; then
	    info "setting owner of tablespace \"$name\" ($tbldir)"
	    chown -R ${owner}: $tbldir
	    if [ $? != 0 ]; then
		error "could not change owner of tablespace \"$name\" to $owner"
	    fi
	fi
    done < $tblspc_reloc
fi

# Create or symlink pg_xlog directory if needed
if [ -d "$pgxlog" ]; then
    info "creating symbolic link pg_xlog to $pgxlog"
    was=`pwd`
    cd $pgdata
    ln -sf $pgxlog pg_xlog
    if [ $? != 0 ]; then
	error "could not create $pgdata/pg_xlog symbolic link"
    fi
    if [ `id -u` = 0 -a "`id -un`" != $owner ]; then
	chown -h ${owner}: pg_xlog
	if [ $? != 0 ]; then
	    error "could not change owner of pg_xlog symbolic link to $owner"
	fi
    fi
    cd $was
fi

if [ ! -d $pgdata/pg_xlog/archive_status ]; then
    info "preparing pg_xlog directory"
    mkdir -p $pgdata/pg_xlog/archive_status
    if [ $? != 0 ]; then
	error "could not create $pgdata/pg_xlog"
    fi

    chmod 700 $pgdata/pg_xlog $pgdata/pg_xlog/archive_status 2>/dev/null
    if [ $? != 0 ]; then
	error "could not set permissions of $pgdata/pg_xlog and $pgdata/pg_xlog/archive_status"
    fi

    if [ `id -u` = 0 -a "`id -un`" != $owner ]; then
	chown -R ${owner}: $pgdata/pg_xlog
	if [ $? != 0 ]; then
	    error "could not change owner of $dir to $owner"
	fi
    fi
fi

# Create a recovery.conf file in $PGDATA
info "preparing recovery.conf file"
echo "restore_command = '$restore_command'" > $pgdata/recovery.conf

# Put the given target date in recovery.conf
if [ -n "$target_date" ]; then
    echo "recovery_target_time = '$target_date'" >> $pgdata/recovery.conf
fi

# Ensure recovery.conf as the correct owner so that PostgreSQL can
# rename it at the end of the recovery
if [ `id -u` = 0 -a "`id -un`" != $owner ]; then
    chown -R ${owner}: $pgdata/recovery.conf
    if [ $? != 0 ]; then
	error "could not change owner of recovery.conf to $owner"
    fi
fi

# Generate a SQL file in PGDATA to update the catalog when tablespace
# locations have changed. It is only needed when using PostgreSQL <=9.1
updsql=$pgdata/update_catalog_tablespaces.sql
if [ -f "$tblspc_reloc" ]; then
    # Check PG_VERSION
    if [ -f $pgdata/PG_VERSION ]; then
	pgvers=`cat $pgdata/PG_VERSION | sed -e 's/\./0/'`
    else
	warn "PG_VERSION file is missing"
    fi

    # Generate script
    if [ "$pgvers" -le 901 ]; then
	cat  $tblspc_reloc | grep 'yes$' | while read l; do
	    name=`echo $l | cut -d '|' -f 1`
	    tbldir=`echo $l | cut -d '|' -f 2`
	    oid=`echo $l | cut -d '|' -f 3`

	    echo "-- update location of $name to $tbldir" >> $updsql
	    echo -e "UPDATE pg_catalog.pg_tablespace SET spclocation = '$tbldir' WHERE oid = $oid;\n" >> $updsql
	done
    fi

    if [ `id -u` = 0 -a "`id -un`" != $owner ]; then
	chown ${owner}: $updsql 2>/dev/null
    fi
fi



# Cleanup
if [ -n "$tmp_dir" ]; then
    rm -rf $tmp_dir
fi

info "done"
info
if [ -d $restored_conf ]; then
    info "saved configuration files have been restored to:"
    info "  $restored_conf"
    info
fi
info "please check directories and recovery.conf before starting the cluster"
info "and do not forget to update the configuration of pitrery if needed"
info


if [ -f $updsql ]; then
    warn "locations of tablespaces have changed, after recovery update the catalog with:"
    warn "  $updsql"
fi

