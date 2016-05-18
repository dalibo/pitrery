#!@BASH@
#
# Copyright 2011-2016 Nicolas Thauvin. All rights reserved.
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
    echo "    -t                   Use ISO 8601 format to name backups"
    echo
    echo "Connection options:"
    echo "    -P PSQL              path to the psql command"
    echo "    -h HOSTNAME          database server host or socket directory"
    echo "    -p PORT              database server port number"
    echo "    -U NAME              connect as specified database user"
    echo "    -d DATABASE          database to use for connection"
    echo
    echo "    -T                   Timestamp log messages"
    echo "    -?                   Print help"
    echo
    exit $1
}

# Apply an extra level of shell quoting to each of the arguments passed.
# This is necessary for remote-side arguments of ssh (including commands that
# are executed by the remote shell and remote paths for scp and rsync via ssh)
# since they will strip an extra level of quoting off on the remote side.
# This makes it safe for them to include spaces or other special characters
# which should not be interpreted or cause word-splitting on the remote side.
qw() {
    while (( $# > 1 )); do
	printf "%q " "$1"
	shift
    done
    (( $# == 1 )) && printf "%q" "$1"
}

now() {
    [ "$log_timestamp" = "yes" ] && echo "$(date "+%F %T %Z ")"
}

cleanup() {
    info "cleaning..."
    if [ "$local_backup" = "yes" ]; then
	if [ -d "$backup_dir" ]; then
	    rm -rf -- "$backup_dir"
	fi
    elif [ -n "$ssh_target" ] && [ -n "$backup_dir" ]; then
	bd=$(qw "$backup_dir")
	ssh -n -- "$ssh_target" "test -d $bd && rm -rf -- $bd" 2>/dev/null
    fi
    [ -n "$tblspc_list" ] && rm -f -- "$tblspc_list"
    [ -n "$replslot_list" ] && rm -f -- "$replslot_list"
}

error() {
    echo "$(now)ERROR: $*" 1>&2
    cleanup
    exit 1
}


warn() {
    echo "$(now)WARNING: $*" 1>&2
}

info() {
    echo "$(now)INFO: $*"
}

# Hard coded configuration
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
pgdata=/var/lib/pgsql/data
storage="tar"
compress_bin="gzip -4"
compress_suffix="gz"
psql_command=( "psql" "-X" )
log_timestamp="no"
use_iso8601_timestamps="no"


# CLI options
while getopts "Lb:l:u:D:s:c:e:tP:h:p:U:d:T?" opt; do
    case $opt in
        L) local_backup="yes";;
	b) backup_root=$OPTARG;;
	l) label_prefix=$OPTARG;;
	u) ssh_user=$OPTARG;;
	D) pgdata=$OPTARG;;
	s) storage=$OPTARG;;
	c) compress_bin=$OPTARG;;
	e) compress_suffix=$OPTARG;;
        t) use_iso8601_timestamps="yes";;

	P) psql_command=( "$OPTARG" );;
	h) dbhost=$OPTARG;;
	p) dbport=$OPTARG;;
	U) dbuser=$OPTARG;;
	d) dbname=$OPTARG;;

	T) log_timestamp="yes";;
        "?") usage 1;;
	*) error "Unknown error while processing options";;
    esac
done

target=${@:$OPTIND:1}

# Destination host is mandatory unless the backup is local
if [ -z "$target" ] && [ "$local_backup" != "yes" ]; then
    echo "ERROR: missing target host" 1>&2
    usage 1
fi

# This shouldn't ever happen, but if we check it here we don't have to worry
# about what might get confused in the logic below if it does.
if [ -n "$target" ] && [ "$local_backup" = "yes" ]; then
    echo "ERROR: BACKUP_HOST is set and BACKUP_IS_LOCAL=\"yes\", it can't be both" 1>&2
    exit 1
fi

# Only tar or rsync are allowed as storage method
if [ "$storage" != "tar" ] && [ "$storage" != "rsync" ]; then
    echo "ERROR: storage method must be 'tar' or 'rsync'" 1>&2
    usage 1
fi

# Get current date and time in a sortable format
current_time=`date +%Y.%m.%d-%H.%M.%S`

# scp needs IPv6 between brackets
echo $target | grep -qi '^[0123456789abcdef:]*:[0123456789abcdef:]*$' && target="[${target}]"
ssh_target=${ssh_user:+$ssh_user@}$target

# Ensure failed globs will be empty, not left containing the literal glob pattern
shopt -s nullglob

# initialize the target path early, so that cleaning works best
backup_dir=$backup_root/${label_prefix}/current

# Prepare psql command line. Starting from 9.6 .psqlrc is sourced with
# psql -c or -f, so we force -X
psql_command+=( "-X" )
[ -n "$dbhost" ] && psql_command+=( "-h" "$dbhost" )
[ -n "$dbport" ] && psql_command+=( "-p" "$dbport" )
[ -n "$dbuser" ] && psql_command+=( "-U" "$dbuser" )

psql_condb=${dbname:-postgres}

# Exports for both the pre and post backup hooks.
export PITRERY_HOOK="pre_backup"
export PITRERY_BACKUP_DIR=$backup_dir
export PITRERY_PSQL="${psql_command[@]}"
export PITRERY_DATABASE=$psql_condb
export PITRERY_BACKUP_LOCAL=$local_backup
export PITRERY_SSH_TARGET=$ssh_target

# Functions
post_backup_hook() {
    if [ -n "$POST_BACKUP_COMMAND" ]; then
	# We need to set PITRERY_BACKUP_DIR again here, because it will have
	# changed since the PRE_BACKUP_COMMAND was run, unless something failed
	# and we're bailing out early via error_and_hook().
	info "running post backup command"
	PITRERY_HOOK="post_backup"
	PITRERY_BACKUP_DIR=$backup_dir
	export PITRERY_EXIT_CODE
	if ! $POST_BACKUP_COMMAND; then
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
    if ! "${psql_command[@]}" -Atc "SELECT pg_stop_backup();" -- "$psql_condb" >/dev/null; then
	error_and_hook "could not stop backup process"
    fi

    # Reset the signal handler, this function should only be called once
    trap - INT TERM KILL EXIT
}

# Get the version of the server
if ! pg_version=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'server_version_num';" \
				-- "$psql_condb"); then
    echo "ERROR: could not get the version of the server" 1>&2
    exit 1
fi

# Check if the server is in hot standby, it can happen from 9.0
# otherwise we would have already exited on error.
if (( 10#$pg_version >= 90000 )); then
    if ! standby=$("${psql_command[@]}" -Atc "SELECT pg_is_in_recovery();" -- "$psql_condb"); then
	echo "ERROR: could not check if the server is in recovery" 1>&2
        exit 1
    fi

    if [ "$standby" = "t" ]; then
	echo "ERROR: unable to perform a base backup on a server in recovery mode. Aborting" 1>&2
	exit 1
    fi
fi

# Prepare target directories
info "preparing directories in ${target:+$target:}$backup_root/${label_prefix}"

if [ "$local_backup" = "yes" ]; then
    # Ensure the destination is clean from failed backups and that no
    # concurrent backup is running, the "current" temporary directory
    # acts as a lock.
    if [ -e "$backup_dir" ]; then
	echo "ERROR: $backup_dir already exists, another backup may be in progress" 1>&2
        exit 1
    fi

    if ! mkdir -p -- "$backup_dir/tblspc"; then
	error "could not create $backup_dir/tblspc"
    fi
else
    if ssh -n -- "$ssh_target" "test -e $(qw "$backup_dir")" 2>/dev/null; then
	echo "ERROR: $backup_dir already exists, another backup may be in progress" 1>&2
        exit 1
    fi

    if ! ssh -n -- "$ssh_target" "mkdir -p -- $(qw "$backup_dir/tblspc")" 2>/dev/null; then
	error "could not create $backup_dir/tblspc"
    fi
fi

# Execute the pre-backup command
if [ -n "$PRE_BACKUP_COMMAND" ]; then
    info "running pre backup hook"
    if ! $PRE_BACKUP_COMMAND; then
	error "pre_backup command exited with a non-zero code"
    fi
fi

# Get the list of tablespaces. It comes from PostgreSQL to be sure to
# process only defined tablespaces.
info "listing tablespaces"
if ! tblspc_list=$(mktemp -t backup_pitr.XXXXXXXXXX); then
    error_and_hook "could not create temporary file"
fi

# Starting from 9.2, the location of tablespaces is no longer stored
# in pg_tablespace. This allows to change locations of tablespaces by
# modifying the symbolic links in pg_tblspc. As a result, the query to
# get list of tablespaces is different.

# Ask PostgreSQL the list of tablespaces
if (( $pg_version >= 90200 )); then
    "${psql_command[@]}" -Atc "SELECT spcname, pg_tablespace_location(oid), oid, pg_size_pretty(pg_tablespace_size(oid)) FROM pg_tablespace;" -- "$psql_condb" > "$tblspc_list"
    rc=$?
else
    "${psql_command[@]}" -Atc "SELECT spcname, spclocation, oid, pg_size_pretty(pg_tablespace_size(oid)) FROM pg_tablespace;" -- "$psql_condb" > "$tblspc_list"
    rc=$?
fi

if [ $rc != 0 ]; then
    error_and_hook "could not get the list of tablespaces from PostgreSQL"
fi

# Start the backup
info "starting the backup process"

# Force a checkpoint for version >= 8.4. We add some parsing of the
# result of pg_xlogfile_name_offset on the LSN returned by
# pg_start_backup, so that we have the name of the backup_label that
# will be archived after pg_stop_backup completes
if (( $pg_version >= 80400 )); then
    start_backup_label_file=`${psql_command[@]} -Atc "select i.file_name ||'.'|| lpad(upper(to_hex(i.file_offset)), 8, '0') || '.backup' from pg_xlogfile_name_offset(pg_start_backup('${label_prefix}_${current_time}', true)) as i;" $psql_condb`
    rc=$?
else
    start_backup_label_file=`${psql_command[@]} -Atc "select i.file_name ||'.'|| lpad(upper(to_hex(i.file_offset)), 8, '0') || '.backup' from pg_xlogfile_name_offset(pg_start_backup('${label_prefix}_${current_time}')) as i;" $psql_condb`
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
if [ "$storage" = "rsync" ]; then
    if [ "$local_backup" = "yes" ]; then
	list=( "$backup_root/$label_prefix/"[0-9]*/ )
	if (( ${#list[@]} > 0 )); then
	    _dir=${list[*]: -1}

	    # Since the previous backup can be in tar storage, check
	    # that a pgdata subdirectory exists
	    [ -d "${_dir%/}/pgdata" ] && prev_backup=${_dir%/}
	fi
    else
	_dir=$(ssh -n -- "$ssh_target" "f=\$(find $(qw "$backup_root/$label_prefix") -maxdepth 1 -name '[0-9]*' -type d -print0 | sort -rz | cut -d '' -f1) && printf '%s' \"\$f\"")
	if ssh -n -- "$ssh_target" "test -d $(qw "$_dir/pgdata")" 2>/dev/null; then
	    prev_backup="$_dir"
	fi
    fi
fi

# Enable the extended pattern matching operators.
# We use them here for replacing whitespace in the tablespace tarball names.
shopt -s extglob

# Copy the files
case $storage in
    "tar")
        # Tar $PGDATA
	info "backing up PGDATA with tar"
	was=`pwd`
	if ! cd -- "$pgdata"; then
	    error_and_hook "could not change current directory to $pgdata"
	fi

	info "archiving $pgdata"
	if [ "$local_backup" = "yes" ]; then
	    tar -cpf - --ignore-failed-read --exclude='pg_xlog' --exclude='pg_replslot/*' --exclude='postmaster.*' --exclude='pgsql_tmp' --exclude='restored_config_files' --exclude='backup_label.old' --exclude='*.sql' -- * 2>/dev/null | $compress_bin > "$backup_dir/pgdata.tar.$compress_suffix"
	    rc=(${PIPESTATUS[*]})
	    tar_rc=${rc[0]}
	    compress_rc=${rc[1]}
	    if [ "$tar_rc" = 2 ] || [ "$compress_rc" != 0 ]; then
		error_and_hook "could not tar PGDATA"
	    fi
	else
	    tar -cpf - --ignore-failed-read --exclude='pg_xlog' --exclude='pg_replslot/*' --exclude='postmaster.*' --exclude='pgsql_tmp' --exclude='restored_config_files' --exclude='backup_label.old' --exclude='*.sql' -- * 2>/dev/null | $compress_bin | ssh -- "$ssh_target" "cat > $(qw "$backup_dir/pgdata.tar.$compress_suffix")" 2>/dev/null
	    rc=(${PIPESTATUS[*]})
	    tar_rc=${rc[0]}
	    compress_rc=${rc[1]}
	    ssh_rc=${rc[2]}
	    if [ "$tar_rc" = 2 ] || [ "$compress_rc" != 0 ] || [ "$ssh_rc" != 0 ]; then
		error_and_hook "could not tar PGDATA"
	    fi
	fi
	cd -- "$was"

	# Tar the tablespaces
	while read line ; do
	    name=$(cut -d '|' -f 1 <<< "$line")
	    _name=${name//+([[:space:]])/_}	# No space version, we want paths without spaces
	    location=$(cut -d '|' -f 2 <<< "$line")

	    # Skip empty locations used for pg_default and pg_global, which are in PGDATA
	    [ -z "$location" ] && continue

	    info "backing up tablespace \"$name\" with tar"

            # Change directory to the parent directory or the tablespace to be
            # able to tar only the base directory
	    was=`pwd`
	    if ! cd -- "$location"; then
		error_and_hook "could not change current directory to $location"
	    fi

	    # Tar the directory, directly to the remote location if needed.  The name
            # of the tar file is the tablespace name defined in the cluster, which is
            # unique.
	    info "archiving $location"
	    if [ "$local_backup" = "yes" ]; then
		tar -cpf - --ignore-failed-read --exclude='pgsql_tmp' -- * 2>/dev/null | $compress_bin > "$backup_dir/tblspc/${_name}.tar.$compress_suffix"
		rc=(${PIPESTATUS[*]})
		tar_rc=${rc[0]}
		compress_rc=${rc[1]}
		if [ "$tar_rc" = 2 ] || [ "$compress_rc" != 0 ]; then
		    error_and_hook "could not tar tablespace \"$name\""
		fi
	    else
		tar -cpf - --ignore-failed-read --exclude='pgsql_tmp' -- * 2>/dev/null | $compress_bin | ssh -- "$ssh_target" "cat > $(qw "$backup_dir/tblspc/${_name}.tar.$compress_suffix")" 2>/dev/null
		rc=(${PIPESTATUS[*]})
		tar_rc=${rc[0]}
		compress_rc=${rc[1]}
		ssh_rc=${rc[2]}
		if [ "$tar_rc" = 2 ] || [ "$compress_rc" != 0 ] || [ "$ssh_rc" != 0 ]; then
		    error_and_hook "could not tar tablespace \"$name\""
		fi
	    fi

	    cd -- "$was"

	done < "$tblspc_list"
	;;



    "rsync")
	info "backing up PGDATA with rsync"
	rsync_link=()
	if [ -n "$prev_backup" ]; then
	    # Link previous backup of pgdata
	    info "backup with hardlinks from $prev_backup"
	    if [ "$local_backup" = "yes" ]; then
		rsync_link=( '--link-dest' "$prev_backup/pgdata" )
	    else
		rsync_link=( '--link-dest' "$(qw "$prev_backup/pgdata")" )
	    fi
	fi

	info "transferring data from $pgdata"
	if [ "$local_backup" = "yes" ]; then
	    rsync -aq --delete-excluded --exclude 'pgsql_tmp' --exclude 'pg_xlog' --exclude 'pg_replslot/*' --exclude 'postmaster.*' --exclude 'restored_config_files' --exclude 'backup_label.old' --exclude '*.sql' "${rsync_link[@]}" -- "$pgdata/" "$backup_dir/pgdata/"
	    rc=$?
	    if [ $rc != 0 ] && [ $rc != 24 ]; then
		error_and_hook "rsync of PGDATA failed with exit code $rc"
	    fi
	else
	    rsync -e "ssh -o Compression=no" -zaq --delete-excluded --exclude 'pgsql_tmp' --exclude 'pg_xlog' --exclude 'pg_replslot/*' --exclude 'postmaster.*' --exclude 'restored_config_files' --exclude 'backup_label.old' --exclude '*.sql' "${rsync_link[@]}" -- "$pgdata/" "$ssh_target:$(qw "$backup_dir/pgdata/")"
	    rc=$?
	    if [ $rc != 0 ] && [ $rc != 24 ]; then
		error_and_hook "rsync of PGDATA failed with exit code $rc"
	    fi
	fi


	# Tablespaces. We do the same as pgdata: hardlink the previous
	# backup directory if possible, then rsync.
	while read line; do
	    name=$(cut -d '|' -f 1 <<< "$line")
	    _name=${name//+([[:space:]])/_}	# No space version, we want paths without spaces
	    location=$(cut -d '|' -f 2 <<< "$line")

	    # Skip empty locations used for pg_default and pg_global, which are in PGDATA
	    [ -z "$location" ] && continue

	    info "backing up tablespace \"$name\" with rsync"

	    rsync_link=()
	    if [ -n "$prev_backup" ]; then
	    	# Link previous backup of the tablespace
		if [ "$local_backup" = "yes" ]; then
		    [ -d "$prev_backup/tblspc/$_name" ] && rsync_link=( '--link-dest' "$prev_backup/tblspc/$_name" )
		else
                    if ssh -n -- "$ssh_target" "test -d $(qw "$prev_backup/tblspc/$_name")" 2>/dev/null; then
		        rsync_link=( '--link-dest' "$(qw "$prev_backup/tblspc/$_name")" )
                    fi
		fi
	    fi

	    # rsync
	    info "transferring data from $location"
	    if [ "$local_backup" = "yes" ]; then
		rsync -aq --delete-excluded --exclude 'pgsql_tmp' "${rsync_link[@]}" -- "$location/" "$backup_dir/tblspc/$_name/"
		rc=$?
		if [ $rc != 0 ] && [ $rc != 24 ]; then
	    	    error_and_hook "rsync of tablespace \"$name\" failed with exit code $rc"
	    	fi
	    else
		rsync -e "ssh -o Compression=no" -zaq --delete-excluded --exclude 'pgsql_tmp' "${rsync_link[@]}" -- "$location/" "$ssh_target:$(qw "$backup_dir/tblspc/$_name/")"
		rc=$?
		if [ $rc != 0 ] && [ $rc != 24 ]; then
	    	    error_and_hook "rsync of tablespace \"$name\" failed with exit code $rc"
	    	fi
	    fi

	done < "$tblspc_list"
	;;



    *)
	error_and_hook "Unknown STORAGE method '$storage'"
	;;
esac


# Backup replication slots informations to a separate file. If we take
# their status files and restore them, they would be restored as stale
# slots. Instead we'll give the commands to recreate them after the
# restore.
if (( $pg_version >= 90400 )); then
    if ! replslot_list=$(mktemp -t backup_pitr.XXXXXXXXXX); then
	error_and_hook "could not create temporary file"
    fi

    "${psql_command[@]}" -Atc \
	"SELECT slot_name,plugin,slot_type,database FROM pg_replication_slots;" \
	-- "$psql_condb" 2>/dev/null > "$replslot_list" ||
	error_and_hook "could not get the list of replication slots from PostgreSQL"
fi

# Stop backup
stop_backup

# The complete backup_label is going to be archived. We put it in the
# backup, just in case and also use the stop time from the file to
# name the backup directory and have the minimum datetime required to
# select this backup on restore.
backup_file="$pgdata/pg_xlog/$start_backup_label_file"

# Get the stop date of the backup and convert it to UTC, this make
# it easier when searching for a proper backup when restoring
stop_time=$(sed -n 's/STOP TIME: //p' -- "$backup_file")
if [ -n "$stop_time" ]; then
    timestamp=$(${psql_command[@]} -Atc "SELECT EXTRACT(EPOCH FROM TIMESTAMP WITH TIME ZONE '${stop_time}');" $psql_condb) ||
        warn "could not get the stop time timestamp from PostgreSQL"
else
    error_and_hook "Failed to get STOP TIME from '$backup_file'"
fi

# Ask PostgreSQL where are its configuration file. When they are
# outside PGDATA, copy them in the backup
_pgdata=`readlink -f -- "$pgdata"`

while read -r -d '' f; do
    file=`readlink -f -- "$f"`
    if [[ ! $file =~ ^"$_pgdata" ]]; then
	# the file in not inside PGDATA, copy it
	destdir=$backup_dir/conf
	dest=$destdir/$(basename -- "$file")
	info "saving $f"

	if [ "$local_backup" = "yes" ]; then
	    mkdir -p -- "$destdir"
	    if ! cp -- "$file" "$dest"; then
		error_and_hook "could not copy $f to backup directory"
	    fi
	else
	    ssh -n -- "$ssh_target" "mkdir -p -- $(qw "$destdir")" 2>/dev/null
	    if ! scp -- "$file" "$ssh_target:$(qw "$dest")" >/dev/null; then
		error_and_hook "could not copy $f to backup directory on $target"
	    fi
	fi
    fi
done < <(
    # The values of the settings is dependant of the user, it means
    # those path can include characters such as newline, which can
    # conflict with the record separator. We could use psql -0 but it
    # is not available before 9.2, this is why we loop and build nul
    # separated output this way.
    for f in 'config_file' 'hba_file' 'ident_file'; do
	"${psql_command[@]}" -Atc \
            "SELECT setting FROM pg_settings WHERE name = '$f';" \
	    -- "$psql_condb" \
 	    || warn "could not get the list of configuration files from PostgreSQL"
	printf "\0"
    done
)

# Compute the name of the backup directory from the stop time, use
# date to format the stop time as ISO 8601 if required. When we can have
if [[ "$use_iso8601_timestamps" == "yes" ]]; then
    backup_name=$(date -d "$stop_time" +"%FT%T%z") ||
        error_and_hook "could not format stop time to a directory name"
else
    backup_name=$(echo $stop_time | awk '{ gsub(/[:-]/, "."); print $1"_"$2 }')
fi
new_backup_dir=$backup_root/$label_prefix/$backup_name

# Finish the backup by copying needed files and rename the backup
# directory to a useful name
if [ "$local_backup" = "yes" ]; then
    [ ! -e "$new_backup_dir" ] ||
	error_and_hook "backup directory '$new_backup_dir' already exists"

    # Rename the backup directory using the stop time
    if ! mv -- "$backup_dir" "$new_backup_dir"; then
	error_and_hook "could not rename the backup directory"
    fi
    backup_dir=$new_backup_dir
    
    # Copy the backup history file
    info "copying the backup history file"
    if ! cp -- "$backup_file" "$backup_dir/backup_label"; then
	error_and_hook "could not copy backup history file to $backup_dir"
    fi

    # Save the end of backup timestamp to a file
    if [ -n "$timestamp" ]; then
	echo "$timestamp" > "$backup_dir/backup_timestamp" || warn "could not save timestamp"
    fi

    # Add the name and location of the tablespace to an helper file for
    # the restoration script
    info "copying the tablespaces list"
    if ! cp -- "$tblspc_list" "$backup_dir/tblspc_list"; then
	error_and_hook "could not copy the tablespace list to $backup_dir"
    fi

    # Save the list of defined replication slots
    if [ -f "$replslot_list" ] && (( $(cat -- "$replslot_list" | wc -l) > 0 )); then
	info "copying the replication slots list"
	cp -- "$replslot_list" "$backup_dir/replslot_list" ||
	    error_and_hook "could not copy the replication slots list to $backup_dir"
    fi

else
    if ssh -n -- "$ssh_target" "test -e $(qw "$new_backup_dir")" 2>/dev/null; then
	error_and_hook "backup directory '$target:$new_backup_dir' already exists"
    fi

    # Rename the backup directory using the stop time
    if ! ssh -n -- "$ssh_target" "mv -- $(qw "$backup_dir" "$new_backup_dir")" 2>/dev/null; then
	error_and_hook "could not rename the backup directory"
    fi
    backup_dir=$new_backup_dir
    
    # Save the end of backup timestamp to a file
    if [ -n "$timestamp" ]; then
	ssh -n -- "$ssh_target" "echo '$timestamp' > $(qw "$backup_dir/backup_timestamp")" 2>/dev/null ||
	    warn "could not save timestamp"
    fi

    # Copy the backup history file
    info "copying the backup history file"
    if ! scp -- "$backup_file" "$ssh_target:$(qw "$backup_dir/backup_label")" > /dev/null; then
	error_and_hook "could not copy backup history file to $target:$backup_dir"
    fi

    # Add the name and location of the tablespace to an helper file for
    # the restoration script
    info "copying the tablespaces list"
    if ! scp -- "$tblspc_list" "$ssh_target:$(qw "$backup_dir/tblspc_list")" >/dev/null; then
	error_and_hook "could not copy the tablespace list to $target:$backup_dir"
    fi

    # Save the list of defined replication slots
    if [ -f "$replslot_list" ] && (( $(cat -- "$replslot_list" | wc -l) > 0 )); then
	info "copying the replication slots list"
	scp -- "$replslot_list" "$ssh_target:$(qw "$backup_dir/replslot_list")" >/dev/null ||
	    error_and_hook "could not copy the replication slots list to $backup_dir"
    fi
fi

# Give the name of the backup
info "backup directory is ${target:+$target:}$backup_dir"

# Execute the post-backup command. It does not return on failure.
PITRERY_EXIT_CODE=0
post_backup_hook

# Cleanup
rm -f -- "$tblspc_list"
[ -n "$replslot_list" ] && rm -f -- "$replslot_list"

info "done"
