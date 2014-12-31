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

usage() {
    echo "`basename $0` performs a PITR base backup"
    echo 
    echo "Usage:"
    echo "    `basename $0` [options] [hostname]"
    echo
    echo "Backup options:"
    echo "    -L                   Perform a local backup"
    echo "    -b dir               Backup base directory"
    echo "    -l label             Backup label"
    echo "    -u username          Username for SSH login"
    echo "    -D dir               Path to \$PGDATA"
    echo "    -s mode              Storage method, tar or rsync"
    echo "    -c compress_bin      Compression command for tar method"
    echo "    -e compress_suffix   Suffix added by the compression program"
    echo
    echo "Connection options:"
    echo "    -P PSQL              path to the psql command"
    echo "    -h HOSTNAME          database server host or socket directory"
    echo "    -p PORT              database server port number"
    echo "    -U NAME              connect as specified database user"
    echo "    -d DATABASE          database to use for connection"
    echo
    echo "    -?                   Print help"
    echo
    exit $1
}

cleanup() {
    info "cleaning..."
    if [ $local_backup = "yes" ]; then
	if [ -d "$backup_dir" ]; then
	    rm -rf $backup_dir
	fi
    else
	ssh $target "test -d \"$backup_dir\"" 2>/dev/null
	if [ $? = 0 ]; then
	    ssh $target "rm -rf $backup_dir" 2>/dev/null
	fi
    fi
    [ -n "$tblspc_list" ] && rm $tblspc_list
}

error() {
    echo "ERROR: $*" 1>&2
    cleanup
    exit 1
}


warn() {
    echo "WARNING: $*" 1>&2
}

info() {
    echo "INFO: $*"
}

# Hard coded configuration
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
pgdata=/var/lib/pgsql/data
storage="tar"
rsync_opts="-q --whole-file" # Remote only
compress_bin="gzip -4"
compress_suffix="gz"


# CLI options
while getopts "Lb:l:u:D:s:c:e:P:h:p:U:d:?" opt; do
    case "$opt" in
        L) local_backup="yes";;
	b) backup_root=$OPTARG;;
	l) label_prefix=$OPTARG;;
	u) ssh_user=$OPTARG;;
	D) pgdata=$OPTARG;;
	s) storage=$OPTARG;;
	c) compress_bin="$OPTARG";;
	e) compress_suffix=$OPTARG;;

	P) psql_command=$OPTARG;;
	h) dbhost=$OPTARG;;
	p) dbport=$OPTARG;;
	U) dbuser=$OPTARG;;
	d) dbname=$OPTARG;;

        "?") usage 1;;
	*) error "Unknown error while processing options";;
    esac
done

target=${@:$OPTIND:1}

# Destination host is mandatory unless the backup is local
if [ -z "$target" ] && [ $local_backup != "yes" ]; then
    echo "ERROR: missing target host" 1>&2
    usage 1
fi

# Only tar or rsync are allowed as storage method
if [ "$storage" != "tar" -a "$storage" != "rsync" ]; then
    echo "ERROR: storage method must be 'tar' or 'rsync'" 1>&2
    usage 1
fi

# Get current date and time in a sortable format
current_time=`date +%Y.%m.%d-%H.%M.%S`

# scp needs IPv6 between brackets
echo $target | grep -q ':' && target="[${target}]"

# initialize the target path early, so that cleaning works best
backup_dir=$backup_root/${label_prefix}/current

# Prepare psql command line
psql_command=${psql_command:-"psql"}
[ -n "$dbhost" ] && psql_command="$psql_command -h $dbhost"
[ -n "$dbport" ] && psql_command="$psql_command -p $dbport"
[ -n "$dbuser" ] && psql_command="$psql_command -U $dbuser"

psql_condb=${dbname:-postgres}

# Functions
post_backup_hook() {
    if [ -n "$POST_BACKUP_COMMAND" ]; then
	info "running post backup command"
	export PITRERY_HOOK="post_backup"
	export PITRERY_BACKUP_DIR=$backup_dir
	# Do not overwrite the return code which can be set by
	# error_and_hook to inform to hook command that the backup
	# failed
	export PITRERY_EXIT_CODE=${PITRERY_EXIT_CODE:-0}
	$POST_BACKUP_COMMAND
	if [ $? != 0 ]; then
	    error "post_backup command exited with a non-zero code"
	fi
    fi
}

# This special error function permit to run the post hook when the
# backup fails. This is because the post hook must run after the pre
# hook, while it is possible to have failure before (which need
# error())
error_and_hook() {
    echo "ERROR: $*" 1>&2
    PITRERY_EXIT_CODE=1
    post_backup_hook
    cleanup
    exit 1
}

stop_backup() {
    # This function is a signal handler, so block signals it handles
    trap '' INT TERM EXIT

    # Tell PostgreSQL the backup is done
    info "stopping the backup process"
    $psql_command -Atc "SELECT pg_stop_backup();" $psql_condb >/dev/null
    if [ $? != 0 ]; then
	error_and_hook "could not stop backup process"
    fi

    # Reset the signal handler, this function should only be called once
    trap - INT TERM KILL EXIT
}

# Get the version of the server
pg_version=`$psql_command -Atc "SELECT setting FROM pg_settings WHERE name = 'server_version_num';" $psql_condb`
if [ $? != 0 ]; then
    error "could not get the version of the server"
fi

# Check if the server is in hot standby, it can happen from 9.0
# otherwise we would have already exited on error.
if [ $pg_version -ge 90000 ]; then
    standby=`$psql_command -Atc "SELECT pg_is_in_recovery();" $psql_condb`
    if [ $? != 0 ]; then
	error "could not check if the server is in recovery"
    fi

    # When the server is in recovery, exit without any error and print
    # a warning. This way, the backup cronjobs can be active on
    # standby servers
    if [ "$standby" = "t" ]; then
	# Output a warning message only when run interactively
	[ -t 0 ] && warn "unable to perform a base backup on a server in recovery mode. Aborting"
	exit 0
    fi
fi

# Prepare target directoties
info "preparing directories in ${target:+$target:}$backup_root/${label_prefix}"

if [ $local_backup = "yes" ]; then
    # Ensure the destination is clean from failed backups and that no
    # concurrent backup is running, the "current" temporary directory
    # acts as a lock.
    if [ -e $backup_dir ]; then
	error "$backup_dir already exists, another backup may be in progress"
    fi

    mkdir -p $backup_dir
    if [ $? != 0 ]; then
	error "could not create $backup_dir"
    fi
	
    mkdir -p $backup_dir/tblspc
    if [ $? != 0 ]; then
	error "could not create $backup_dir/tblspc"
    fi

else
    ssh ${ssh_user:+$ssh_user@}$target "test -e $backup_dir" 2>/dev/null
    if [ $? = 0 ]; then
	error "$backup_dir already exists, another backup may be in progress"
    fi

    ssh ${ssh_user:+$ssh_user@}$target "mkdir -p $backup_dir" 2>/dev/null
    if [ $? != 0 ]; then
	error "could not create $backup_dir"
    fi

    ssh ${ssh_user:+$ssh_user@}$target "mkdir -p $backup_dir/tblspc" 2>/dev/null
    if [ $? != 0 ]; then
	error "could not create $backup_dir/tblspc"
    fi

fi

# Execute the pre-backup command
if [ -n "$PRE_BACKUP_COMMAND" ]; then
    info "running pre backup hook"
    export PITRERY_HOOK="pre_backup"
    export PITRERY_BACKUP_DIR=$backup_dir
    export PITRERY_PSQL=$psql_command
    export PITRERY_DATABASE=$psql_condb
    export PITRERY_BACKUP_LOCAL=$local_backup
    export PITRERY_SSH_TARGET=${ssh_user:+$ssh_user@}$target
    $PRE_BACKUP_COMMAND
    if [ $? != 0 ]; then
	error "pre_backup command exited with a non-zero code"
    fi
fi

# Get the list of tablespaces. It comes from PostgreSQL to be sure to
# process only defined tablespaces.
info "listing tablespaces"
tblspc_list=`mktemp -t backup_pitr.XXXXXX`
if [ $? != 0 ]; then
    error_and_hook "could not create temporary file"
fi

# Starting from 9.2, the location of tablespaces is no longer stored
# in pg_tablespace. This allows to change locations of tablespaces by
# modifying the symbolic links in pg_tblspc. As a result, the query to
# get list of tablespaces is different.

# Ask PostgreSQL the list of tablespaces
if [ $pg_version -ge 90200 ]; then
    $psql_command -Atc "SELECT spcname, pg_tablespace_location(oid), oid, pg_size_pretty(pg_tablespace_size(oid)) FROM pg_tablespace;" $psql_condb > $tblspc_list
    rc=$?
else
    $psql_command -Atc "SELECT spcname, spclocation, oid, pg_size_pretty(pg_tablespace_size(oid)) FROM pg_tablespace;" $psql_condb > $tblspc_list
    rc=$?
fi

if [ $rc != 0 ]; then
    error_and_hook "could not get the list of tablespaces from PostgreSQL"
fi

# Start the backup
info "starting the backup process"

# Force a checkpoint for version >= 8.4
if [ $pg_version -ge 80400 ]; then
    start_backup_xlog=`$psql_command -Atc "SELECT pg_xlogfile_name(pg_start_backup('${label_prefix}_${current_time}', true));" $psql_condb`
    rc=$?
else
    start_backup_xlog=`$psql_command -Atc "SELECT pg_xlogfile_name(pg_start_backup('${label_prefix}_${current_time}'));" $psql_condb`
    rc=$?
fi

if [ $rc != 0 ]; then
    error_and_hook "could not start backup process"
fi

# Add a signal handler to avoid leaving the cluster in backup mode when exiting on error
trap stop_backup INT TERM KILL EXIT

# When using rsync storage, search for the previous backup to prepare
# the target directories. We try to optimize the space usage by
# hardlinking the previous backup, so that files that have not changed
# between backups are not duplicated from a filesystem point of view
if [ $storage = "rsync" ]; then
    if [ $local_backup = "yes" ]; then
	prev_backup=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null | tail -1`
    else
	prev_backup=`ssh ${ssh_user:+$ssh_user@}$target "ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null" | tail -1`
    fi
fi

# Copy the files
case $storage in
    "tar")
        # Tar $PGDATA
	info "backing up PGDATA with tar"
	was=`pwd`
	cd $pgdata
	if [ $? != 0 ]; then
	    error_and_hook "could not change current directory to $pgdata"
	fi

	info "archiving $pgdata"
	if [ $local_backup = "yes" ]; then
	    tar -cpf - --ignore-failed-read --exclude=pg_xlog --exclude='postmaster.*' --exclude='pgsql_tmp' * 2>/dev/null | $compress_bin > $backup_dir/pgdata.tar.$compress_suffix
	    rc=(${PIPESTATUS[*]})
	    tar_rc=${rc[0]}
	    compress_rc=${rc[1]}
	    if [ $tar_rc = 2 ] || [ $compress_rc != 0 ]; then
		error_and_hook "could not tar PGDATA"
	    fi
	else
	    tar -cpf - --ignore-failed-read --exclude=pg_xlog --exclude='postmaster.*' --exclude='pgsql_tmp' * 2>/dev/null | $compress_bin | ssh ${ssh_user:+$ssh_user@}$target "cat > $backup_dir/pgdata.tar.$compress_suffix" 2>/dev/null
	    rc=(${PIPESTATUS[*]})
	    tar_rc=${rc[0]}
	    compress_rc=${rc[1]}
	    ssh_rc=${rc[2]}
	    if [ $tar_rc = 2 ] || [ $compress_rc != 0 ] || [ $ssh_rc != 0 ]; then
		error_and_hook "could not tar PGDATA"
	    fi
	fi
	cd $was

	# Tar the tablespaces
	while read line ; do
	    name=`echo $line | cut -d '|' -f 1`
	    _name=`echo $name | sed -re 's/\s+/_/g'` # No space version, we want paths without spaces
	    location=`echo $line | cut -d '|' -f 2`

	    # Skip empty locations used for pg_default and pg_global, which are in PGDATA
	    [ -z "$location" ] && continue

	    info "backing up tablespace \"$name\" with tar"

            # Change directory to the parent directory or the tablespace to be
            # able to tar only the base directory
	    was=`pwd`
	    cd $location
	    if [ $? != 0 ]; then
		error_and_hook "could not change current directory to $location"
	    fi

	    # Tar the directory, directly to the remote location if needed.  The name
            # of the tar file is the tablespace name defined in the cluster, which is
            # unique.
	    info "archiving $location"
	    if [ $local_backup = "yes" ]; then
		tar -cpf - --ignore-failed-read --exclude='pgsql_tmp' * 2>/dev/null | $compress_bin > $backup_dir/tblspc/${_name}.tar.$compress_suffix
		rc=(${PIPESTATUS[*]})
		tar_rc=${rc[0]}
		compress_rc=${rc[1]}
		if [ $tar_rc = 2 ] || [ $compress_rc != 0 ]; then
		    error_and_hook "could not tar tablespace \"$name\""
		fi
	    else
		tar -cpf - --ignore-failed-read --exclude='pgsql_tmp' * 2>/dev/null | $compress_bin | ssh ${ssh_user:+$ssh_user@}$target "cat > $backup_dir/tblspc/${_name}.tar.$compress_suffix" 2>/dev/null
		rc=(${PIPESTATUS[*]})
		tar_rc=${rc[0]}
		compress_rc=${rc[1]}
		ssh_rc=${rc[2]}
		if [ $tar_rc = 2 ] || [ $compress_rc != 0 ] || [ $ssh_rc != 0 ]; then
		    error_and_hook "could not tar tablespace \"$name\""
		fi
	    fi

	    cd $was

	done < $tblspc_list
	;;



    "rsync")
	info "backing up PGDATA with rsync"
	if [ -n "$prev_backup" ]; then
	    # Link previous backup of pgdata
	    if [ $local_backup = "yes" ]; then
		# Check if pgdata is a directory, this checks if the
		# storage method is rsync or tar.
		if [ -d $prev_backup/pgdata ]; then
		    # pax needs the target directory to exist
		    mkdir -p $backup_dir/pgdata

		    info "preparing hardlinks from previous backup"
		    (cd $prev_backup/pgdata && pax -rwl . $backup_dir/pgdata)
		    if [ $? != 0 ]; then
			error_and_hook "could not hardlink previous backup"
		    fi
		fi
	    else
		ssh ${ssh_user:+$ssh_user@}$target "test -d $prev_backup/pgdata" 2>/dev/null
		if [ $? = 0 ]; then
		    # pax needs the target directory to exist
		    ssh ${ssh_user:+$ssh_user@}$target "mkdir -p $backup_dir/pgdata" 2>/dev/null

		    info "preparing hardlinks from previous backup"
		    ssh ${ssh_user:+$ssh_user@}$target "cd $prev_backup/pgdata && pax -rwl . $backup_dir/pgdata" 2>/dev/null
		    if [ $? != 0 ]; then
			error_and_hook "could not hardlink previous backup. Missing pax?"
		    fi
		fi
	    fi
	fi

	info "transfering data from $pgdata"
	if [ $local_backup = "yes" ]; then
	    rsync -aq --delete-before --exclude pgsql_tmp --exclude pg_xlog --exclude 'postmaster.*' $pgdata/ $backup_dir/pgdata/
	    rc=$?
	    if [ $rc != 0 -a $rc != 24 ]; then
		error_and_hook "rsync of PGDATA failed with exit code $rc"
	    fi
	else
	    rsync $rsync_opts -e "ssh -c blowfish-cbc -o Compression=no" -a --delete-before --exclude pgsql_tmp --exclude pg_xlog --exclude 'postmaster.*' $pgdata/ ${ssh_user:+$ssh_user@}${target}:$backup_dir/pgdata/
	    rc=$?
	    if [ $rc != 0 -a $rc != 24 ]; then
		error_and_hook "rsync of PGDATA failed with exit code $rc"
	    fi
	fi


	# Tablespaces. We do the same as pgdata: hardlink the previous
	# backup directory if possible, then rsync.
	while read line; do
	    name=`echo "$line" | cut -d '|' -f 1`
	    _name=`echo "$name" | sed -re 's/\s+/_/g'` # No space version, we want paths without spaces
	    location=`echo "$line" | cut -d '|' -f 2`

	    # Skip empty locations used for pg_default and pg_global, which are in PGDATA
	    [ -z "$location" ] && continue

	    info "backing up tablespace \"$name\" with rsync"

	    if [ -n "$prev_backup" ]; then
	    	# Link previous backup of the tablespace
	    	if [ $local_backup = "yes" ]; then
	    	    if [ -d $prev_backup/tblspc/$_name ]; then
			# pax needs the target directory to exist
			mkdir -p $backup_dir/tblspc/$_name

	    		info "preparing hardlinks from previous backup"
	    		(cd $prev_backup/tblspc/$_name && pax -rwl . $backup_dir/tblspc/$_name)
	    		if [ $? != 0 ]; then
	    		    error_and_hook "could not hardlink previous backup"
	    		fi
	    	    fi
	    	else
	    	    ssh -n ${ssh_user:+$ssh_user@}$target "test -d $prev_backup/tblspc/$_name" 2>/dev/null
	    	    if [ $? = 0 ]; then
			# pax needs the target directory to exist
			ssh ${ssh_user:+$ssh_user@}$target "mkdir -p $backup_dir/tblspc/$_name" 2>/dev/null

	    		info "preparing hardlinks from previous backup"
	    		ssh -n ${ssh_user:+$ssh_user@}$target "cd $prev_backup/tblspc/$_name && pax -rwl . $backup_dir/tblspc/$_name" 2>/dev/null
	    		if [ $? != 0 ]; then
	    		    error_and_hook "could not hardlink previous backup. Missing pax?"
	    		fi
	    	    fi
	    	fi
	    fi

	    # rsync
	    info "transfering data from $location"
	    if [ $local_backup = "yes" ]; then
	    	rsync -aq --delete-before --exclude pgsql_tmp $location/ $backup_dir/tblspc/$_name/
	    	rc=$?
	    	if [ $rc != 0 -a $rc != 24 ]; then
	    	    error_and_hook "rsync of tablespace \"$name\" failed with exit code $rc"
	    	fi
	    else
	    	rsync $rsync_opts -e "ssh -c blowfish-cbc -o Compression=no" -a --delete-before --exclude pgsql_tmp $location/ ${ssh_user:+$ssh_user@}${target}:$backup_dir/tblspc/$_name/
	    	rc=$?
	    	if [ $rc != 0 -a $rc != 24 ]; then
	    	    error_and_hook "rsync of tablespace \"$name\" failed with exit code $rc"
	    	fi
	    fi

	done < $tblspc_list
	;;



    *)
	error_and_hook "do not know how to backup... I have a bug"
	;;
esac


# Stop backup
stop_backup

# Get the stop date of the backup and convert it to UTC, this make
# it easier when searching for a proper backup when restoring
stop_time=`grep "STOP TIME:" $pgdata/pg_xlog/${start_backup_xlog}.*.backup | sed -e 's/STOP TIME: //'`
if [ -n "$stop_time" ]; then
    timestamp=`$psql_command -Atc "SELECT EXTRACT(EPOCH FROM TIMESTAMP WITH TIME ZONE '${stop_time}');" $psql_condb`
    if [ $? != 0 ]; then
	warn "could not get the stop time timestamp from PostgreSQL"
    fi
fi

# Ask PostgreSQL where are its configuration file. When they are
# outside PGDATA, copy them in the backup
_pgdata=`readlink -f $pgdata`
file_list=`$psql_command -Atc "SELECT setting FROM pg_settings WHERE name IN ('config_file', 'hba_file', 'ident_file');" $psql_condb`
if [ $? != 0 ]; then
    warn "could not get the list of configuration files from PostgreSQL"
fi

for f in $file_list; do
    file=`readlink -f $f`
    echo $file | grep -q "^$_pgdata"
    if [ $? != 0 ]; then
	# the file in not inside PGDATA, copy it
	info "saving $f"
	if [ $local_backup = "yes" ]; then
	    mkdir -p $backup_dir/conf
	    cp $file $backup_dir/conf/`basename $file`
	    if [ $? != 0 ]; then
		error_and_hook "could not copy $f to backup directory"
	    fi
	else
	    ssh ${ssh_user:+$ssh_user@}${target} "mkdir -p $backup_dir/conf" 2>/dev/null
	    scp $file ${ssh_user:+$ssh_user@}${target}:$backup_dir/conf/`basename $file` >/dev/null
	    if [ $? != 0 ]; then
		error_and_hook "could not copy $f to backup directory on $target"
	    fi
	fi
    fi
done

# Compute the name of the backup directory from the stop time
backup_name=`echo $stop_time | awk '{ print $1"_"$2 }' | sed -e 's/[:-]/./g'`

# Finish the backup by copying needed files and rename the backup
# directory to a useful name
if [ $local_backup = "yes" ]; then
    # Rename the backup directory using the stop time
    mv $backup_dir $backup_root/${label_prefix}/$backup_name
    if [ $? != 0 ]; then
	error_and_hook "could not rename the backup directory"
    fi
    backup_dir=$backup_root/${label_prefix}/$backup_name
    
    # Copy the backup history file
    info "copying the backup history file"
    cp $pgdata/pg_xlog/${start_backup_xlog}.*.backup $backup_dir/backup_label
    if [ $? != 0 ]; then
	error_and_hook "could not copy backup history file to $backup_dir"
    fi

    # Save the end of backup timestamp to a file
    if [ -n "$timestamp" ]; then
	echo $timestamp > $backup_dir/backup_timestamp || warn "could not save timestamp"
    fi

    # Add the name and location of the tablespace to an helper file for
    # the restoration script
    info "copying the tablespaces list"
    cp $tblspc_list $backup_dir/tblspc_list
    if [ $? != 0 ]; then
	error_and_hook "could not copy the tablespace list to $backup_dir"
    fi
else
    # Rename the backup directory using the stop time
    ssh ${ssh_user:+$ssh_user@}${target} "mv $backup_dir $backup_root/${label_prefix}/$backup_name" 2>/dev/null
    if [ $? != 0 ]; then
	error_and_hook "could not rename the backup directory"
    fi
    backup_dir=$backup_root/${label_prefix}/$backup_name
    
    # Save the end of backup timestamp to a file
    if [ -n "$timestamp" ]; then
	ssh ${ssh_user:+$ssh_user@}${target} "echo $timestamp > $backup_dir/backup_timestamp" 2>/dev/null || warn "could not save timestamp"
    fi

    # Copy the backup history file
    info "copying the backup history file"
    scp $pgdata/pg_xlog/${start_backup_xlog}.*.backup ${ssh_user:+$ssh_user@}${target}:$backup_dir/backup_label > /dev/null 
    if [ $? != 0 ]; then
	error_and_hook "could not copy backup history file to ${target}:$backup_dir"
    fi

    # Add the name and location of the tablespace to an helper file for
    # the restoration script
    info "copying the tablespaces list"
    scp $tblspc_list ${ssh_user:+$ssh_user@}${target}:$backup_dir/tblspc_list >/dev/null
    if [ $? != 0 ]; then
	error_and_hook "could not copy the tablespace list to ${target}:$backup_dir"
    fi
fi

# Give the name of the backup
info "backup directory is ${target:+$target:}$backup_dir"

# Execute the post-backup command. It does not return on failure.
PITRERY_EXIT_CODE=0
post_backup_hook

# Cleanup
rm $tblspc_list

info "done"
