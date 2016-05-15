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

# Default configuration
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
pgdata=/var/lib/pgsql/data
owner=`id -un`
dry_run="no"
rsync_opts="-q" # Remote only
uncompress_bin="gunzip"
compress_suffix="gz"
overwrite="no"
log_timestamp="no"

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
    echo "    -t tblspc:dir        Change the target directory of tablespace \"tblspc\""
    echo "                           this switch can be used many times"
    echo "    -n                   Dry run: show restore information only"
    echo "    -R                   Overwrite destination directories"
    echo "    -c compress_bin      Uncompression command for tar method"
    echo "    -e compress_suffix   Suffix added by the compression program"
    echo
    echo "Archived WAL files options:"
    echo "    -r command           Command line to use in restore_command"
    echo "    -C config            Configuration file for restore_xlog in restore_command"
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
    [ $log_timestamp = "yes" ] && echo "$(date "+%F %T %Z ")"
}

error() {
    echo "$(now)ERROR: $*" 1>&2
    exit 1
}

warn() {
    echo "$(now)WARNING: $*" 1>&2
}

info() {
    echo "$(now)INFO: $*"
}

check_and_fix_directory() {
    [ $# = 1 ] || error "check_and_fix_directory called with $# arguments"
    local dir=$1

    [ -n "$dir" ] || error "check_and_fix_directory called with empty dir argument"

    # Check if directory exists
    if [ ! -d "$dir" ]; then
	info "creating $dir with permission 0700"
	# Note that if this creates any parent directories, their mode will be set
	# according to the current umask, only the final leaf dir will be set 0700.
	mkdir -p -m 700 -- "$dir" || error "could not create $dir"
    else
        # Check if directory is empty
	info "checking if $dir is empty"
	if [ -n "$(ls -A -- "$dir")" ]; then
	    [ "$overwrite" = "yes" ] || error "$dir is not empty. Contents won't be overwritten"

	    # Cancel in case there may be a postmaster running.
	    if [ -e "$dir/postmaster.pid" ]; then
		error "Found $dir/postmaster.pid. A postmaster may be running. Aborting."
	    fi

	    info "$dir is not empty, its contents will be overwritten"
	    # This is called after we know the storage
	    # method. When using "tar", we must clean the target
	    # directory. When using "rsync", we just let it do its
	    # diffs.
	    if [ "$storage" = "tar" ]; then
		info "Removing contents of $dir"
		rm -rf -- "$dir/"*
	    fi
	else
	    # make rsync copy the whole files because target
	    # directories are empty
	    rsync_opts="$rsync_opts --whole-file"
	fi

	# Check permissions
	dperms=`stat -c %a -- "$dir" 2>/dev/null` || error "Unable to get permissions of $dir"

	if [ "$dperms" != "700" ]; then
	    info "setting permissions of $dir"
	    chmod -- 700 "$dir" || error "$dir must have 0700 permission"
	fi
    fi
    
    # Check owner
    downer=`stat -c %U -- "$dir" 2>/dev/null` || error "Unable to get owner of $dir"

    if [ "$downer" != "$owner" ]; then
	if [ "`id -u`" = 0 ]; then
	    info "setting owner of $dir"
	    chown -- "$owner:" "$dir" || error "could not change owner of $dir to $owner"
	else
	    error "$dir must be owned by $owner"
	fi
    fi
}


# Process CLI Options
while getopts "Lu:b:l:D:x:d:O:t:nRc:e:r:C:T?" opt; do
    case "$opt" in
	L) local_backup="yes";;
	u) ssh_user=$OPTARG;;
	b) backup_root=$OPTARG;;
	l) label_prefix=$OPTARG;;
	D) pgdata=$OPTARG;;
	x) pgxlog=$OPTARG;;
	d) target_date=$OPTARG;;
	O) owner=$OPTARG;;
	t) tsmv_list+=( "$OPTARG" );;
	n) dry_run="yes";;
	R) overwrite="yes";;
	c) uncompress_bin=$OPTARG;;
	e) compress_suffix=$OPTARG;;
	r) restore_command=$OPTARG;;
	C) restore_xlog_config="$OPTARG";;
	T) log_timestamp="yes";;
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

# This shouldn't ever happen, but if we check it here we don't have to worry
# about what might get confused in the logic below if it does.
if [ -n "$source" ] && [ "$local_backup" = "yes" ]; then
    error "BACKUP_HOST and BACKUP_IS_LOCAL are set, it can't be both"
fi

echo $source | grep -qi '^[0123456789abcdef:]*:[0123456789abcdef:]*$' && source="[${source}]"
ssh_target=${ssh_user:+$ssh_user@}$source

# Ensure failed globs will be empty, not left containing the literal glob pattern
shopt -s nullglob

# An unprivileged target owner is mandatory as PostgreSQL cannot run
# as root.
if [ "$(id -u -- "$owner")" = 0 ]; then
    error "the target owner cannot not be root. Use -O when restoring as root"
fi

# When no restore_command is given, build it using restore_xlog
if [ -z "$restore_command" ]; then
    [[ "$restore_xlog_config" == */* ]] && restore_xlog_config=$(readlink -m "$restore_xlog_config")
    restore_command="@BINDIR@/restore_xlog${restore_xlog_config:+ -C $(qw "$restore_xlog_config")} %f %p"
fi


# Find the backup according to given date.  The target date converted
# to a timestamp is compared to the timestamp of the stop time of the
# backup. Only after the stop time a backup is sure to be consistent.
info "searching backup directory"

# search the store
if [ "$local_backup" = "yes" ]; then
    list=( "$backup_root/$label_prefix/"[0-9]*/backup_timestamp )
    (( ${#list[@]} > 0 )) ||
	error "Could not find any backup_timestamp files in $backup_root/$label_prefix/*"
else
    list=()
    while read -r -d '' d; do
	list+=("$d")
    done < <(
	# We could 'optimise' this slightly for the case where we only want the latest,
	# by adding a `| cut -d '' -f1` after the sort, to only return the first one,
	# but the amount of extra data transferred here is tiny compared to the rest of
	# the backup, so it is probably better to just reuse this for both cases than to
	# duplicate the logic needed just for that.
	ssh -n -- "$ssh_target" "find $(qw "$backup_root/$label_prefix") -path $(qw "$backup_root/$label_prefix/[0-9]*/backup_timestamp") -type f -print0 | sort -z"
    )

    (( ${#list[@]} > 0 )) ||
	error "Could not find any backup_timestamp files in $backup_root/$label_prefix/* on $source"
fi

if [ -n "$target_date" ]; then
    # Target recovery time in seconds since the epoch, for easy archive searching.
    target_timestamp=$(date -d "$target_date" '+%s') || error "invalid target date '$target_date'"

    # Target recovery time in a format suitable for use in recovery.conf
    recovery_target_time=$(date -d "$target_date" '+%F %T %z') || error "invalid target date '$target_date'"

    # The timestamp must be a string of (only) digits, we do arithmetic with it below.
    # This shouldn't ever fail, but better to catch it here than let odd things happen later.
    [[ $target_timestamp =~ ^[[:digit:]]+$ ]] || error "invalid target_timestamp '$target_timestamp'"

    # find the latest backup
    for t in "${list[@]}"; do
	# get the timestamp of the end of the backup
	if [ "$local_backup" = "yes" ]; then
	    backup_timestamp=$(< "$t")
	else
	    backup_timestamp=$(ssh -n -- "$ssh_target" "cat -- $(qw "$t")")
	fi

	if [[ $backup_timestamp =~ ^[[:digit:]]+$ ]]; then
	    (( $backup_timestamp < $target_timestamp )) || break;
	    backup_dir=$(dirname -- "$t")
	else
	    warn "could not get the ending timestamp of $t"
	fi
    done
else
    # get the latest
    # The test for list being empty here is just belt and braces,
    # we should have already failed with an error above if it is.
    (( ${#list[@]} > 0 )) && backup_dir=$(dirname -- "${list[*]: -1}")
fi

[ -n "$backup_dir" ] || error "Could not find a backup${recovery_target_time:+ for $recovery_target_time}"


# get the tablespace list and check the directories
info "searching for tablespaces information"
if [ "$local_backup" = "yes" ]; then
    if [ -f "$backup_dir/tblspc_list" ]; then
	tblspc_list=$(< "$backup_dir/tblspc_list") || error "Failed to read $backup_dir/tblspc_list"
    fi
else
    tfile=$(qw "$backup_dir/tblspc_list")
    tblspc_list=$(ssh -n -- "$ssh_target" "[ ! -f $tfile ] || cat -- $tfile") ||
	error "Failed to read $source:$backup_dir/tblspc_list"
fi

# Prepare a temporary file with the final list of tablespace directories
if [ -n "$tblspc_list" ]; then
    while read -r l; do
	tdir=$(cut -d '|' -f 2 <<< "$l")

	# skip pg_default and pg_global, they are located inside PGDATA
	[ -z "$tdir" ] && continue

	i=${#tspc_name[@]}
	tspc_name[$i]=$(cut -d '|' -f 1 <<< "$l")
	tspc_dir[$i]=$tdir
	tspc_oid[$i]=$(cut -d '|' -f 3 <<< "$l")
	tspc_reloc[$i]="no"

	for t in "${tsmv_list[@]}"; do
	    tname=$(cut -d ':' -f 1 <<< "$t")
	    # relocation can be done using the name or the oid of the tablespace
	    if [ "$tname" = "${tspc_name[$i]}" ] || [ "$tname" = "${tspc_oid[$i]}" ]; then
		tdir=$(cut -d ':' -f 2 <<< "$t")
		if [ "${tspc_dir[$i]}" != "$tdir" ]; then
		    tspc_dir[$i]=$tdir
		    tspc_reloc[$i]="yes"
		fi
		break
	    fi
	done
    done <<< "$tblspc_list"
fi

tspc_count=${#tspc_name[@]}


# Display some info on the restore
info
info "backup directory:"
info "  $backup_dir"
info
info "destinations directories:"
info "  PGDATA -> $pgdata"

[ -n "$pgxlog" ] && info "  PGDATA/pg_xlog -> $pgxlog"

# Populate an array with tablespace directory to check we have duplicates
declare -a tspc_dedup

# Print the tablespace relocation information
for (( i=0; i<$tspc_count; ++i )); do
    info "  tablespace \"${tspc_name[$i]}\" (${tspc_oid[$i]}) -> ${tspc_dir[$i]} (relocated: ${tspc_reloc[$i]})"
    tspc_dedup+=( ${tspc_dir[$i]} )
done

info
info "recovery configuration:"
info "  target owner of the restored files: $owner"
info "  restore_command = '$restore_command'"
[ -n "$recovery_target_time" ] && info "  recovery_target_time = '$recovery_target_time'"
info 

# Check if tablespace relocation list have duplicates
if (( $(for o in "${tspc_dedup[@]}"; do echo $o; done | sort -u | wc -l) < $tspc_count )); then
    error "found duplicates in tablespace relocations. Check options and the list of tablespaces of the backup"
fi

if [ "$dry_run" = "yes" ]; then
    exit 0
fi

# Real work starts here

# Find out what storage method is used in the backup. If the PGDATA is
# stored as a gzip'ed tarball, the method is tar, if it is a
# directory, then backup_pitr used rsync to put files there.
if [ "$local_backup" = "yes" ]; then
    if [ -f "$backup_dir/pgdata.tar.$compress_suffix" ]; then
	storage="tar"
    elif [ -d "$backup_dir/pgdata" ]; then
	storage="rsync"
    else
	# Check if we have a tarball with different compression to what we are expecting.
	storage=$(find "$backup_dir" -maxdepth 1 -name 'pgdata.tar.*' -type f -printf '%f' -quit)
    fi
else
    storage=$(ssh -n -- "$ssh_target" "if [ -f $(qw "$backup_dir/pgdata.tar.$compress_suffix") ]; then echo 'tar'; elif [ -d $(qw "$backup_dir/pgdata") ]; then echo 'rsync'; else find $(qw "$backup_dir") -maxdepth 1 -name 'pgdata.tar.*' -type f -printf '%f' -quit; fi")
fi

[ -n "$storage" ] ||
    error "could not find what storage method is used in ${source:+$source:}$backup_dir"

[[ $storage =~ ^pgdata\.tar\. ]] &&
    error "expecting '$compress_suffix' compression, but found ${source:+$source:}$backup_dir/$storage"


# Check target directories
check_and_fix_directory "$pgdata"

if [ -n "$pgxlog" ]; then
    [[ $pgxlog == /* ]] || error "pg_xlog must be an absolute path"

    if [ "$pgxlog" = "$pgdata/pg_xlog" ]; then
	error "xlog path cannot be \$PGDATA/pg_xlog, this path is reserved. It seems you do not need -x"
    fi

    check_and_fix_directory "$pgxlog"
fi

# Check the tablespaces directory and create them if possible
for d in "${tspc_dir[@]}"; do
    check_and_fix_directory "$d"
done


# Extract everything
case $storage in
    "tar")
	# pgdata
	info "extracting PGDATA to $pgdata"
	was=`pwd`
	cd -- "$pgdata"
	if [ "$local_backup" = "yes" ]; then
	    $uncompress_bin -c -- "$backup_dir/pgdata.tar.$compress_suffix" | tar xf -
	    rc=(${PIPESTATUS[*]})
	    uncompress_rc=${rc[0]}
	    tar_rc=${rc[1]}
	    if [ "$uncompress_rc" != 0 ] || [ "$tar_rc" != 0 ]; then
		error "could not extract $backup_dir/pgdata.tar.$compress_suffix to $pgdata"
	    fi
	else
	    ssh -n -- "$ssh_target" "cat -- $(qw "$backup_dir/pgdata.tar.$compress_suffix")" 2>/dev/null | $uncompress_bin | tar xf - 2>/dev/null
	    rc=(${PIPESTATUS[*]})
	    ssh_rc=${rc[0]}
	    uncompress_rc=${rc[1]}
	    tar_rc=${rc[2]}
	    if [ "$ssh_rc" != 0 ] || [ "$uncompress_rc" != 0 ] || [ "$tar_rc" != 0 ]; then
		error "could not extract $source:$backup_dir/pgdata.tar.$compress_suffix to $pgdata"
	    fi
	fi
	cd -- "$was"
	info "extraction of PGDATA successful"
	;;

    "rsync")
	info "transferring PGDATA to $pgdata with rsync"
	if [ "$local_backup" = "yes" ]; then
	    rsync -aq --delete -- "$backup_dir/pgdata/" "$pgdata/"
	    rc=$?
	    if [ $rc != 0 ] && [ $rc != 24 ]; then
		error "rsync of PGDATA failed with exit code $rc"
	    fi
	else
	    rsync $rsync_opts -e "ssh -o Compression=no" -za --delete -- "$ssh_target:$(qw "$backup_dir/pgdata/")" "$pgdata/"
	    rc=$?
	    if [ $rc != 0 ] && [ $rc != 24 ]; then
		error "rsync of PGDATA failed with exit code $rc"
	    fi
	fi
	info "transfer of PGDATA successful"
	;;

    *)
	error "Unknown STORAGE method '$storage'"
	;;
esac

# Restore the configuration file in a subdirectory of PGDATA
restored_conf=$pgdata/restored_config_files

if [ "$local_backup" = "yes" ]; then
    # Check the directory, when configuration files are
    # inside PGDATA it does not exist
    if [ -d "$backup_dir/conf" ]; then
	info "restoring configuration files to $restored_conf"
	if ! cp -r -- "$backup_dir/conf" "$restored_conf"; then
	    warn "could not copy $backup_dir/conf to $restored_conf"
	fi
    fi

else
    confdir=$(qw "$backup_dir/conf")
    if ssh -n -- "$ssh_target" "test -d $confdir" 2>/dev/null; then
	info "restoring configuration files to $restored_conf"
	if ! scp -r -- "$ssh_target:$confdir" "$restored_conf" >/dev/null; then
	    warn "could not copy $source:$backup_dir/conf to $restored_conf"
	fi
    fi
fi

# change owner of PGDATA to the target owner
if [ "`id -u`" = 0 ] && [ "`id -un`" != "$owner" ]; then
    info "setting owner of PGDATA ($pgdata)"
    if ! chown -R -- "$owner:" "$pgdata"; then
	error "could not change owner of PGDATA to $owner"
    fi
fi

# Enable the extended pattern matching operators.
# We use them here for replacing whitespace in the tablespace tarball names.
shopt -s extglob

# tablespaces
for (( i=0; i<$tspc_count; ++i )); do
    name=${tspc_name[$i]}
    _name=${name//+([[:space:]])/_} # No space version, we want paths without spaces
    tbldir=${tspc_dir[$i]}
    oid=${tspc_oid[$i]}

    # Change the symlink in pg_tblspc when the tablespace directory changes
    if [ "${tspc_reloc[$i]}" = "yes" ]; then
	ln -sf "$tbldir" "$pgdata/pg_tblspc/$oid" || error "could not update the symbolic of tablespace $name ($oid) to $tbldir"

	# Ensure the new link has the correct owner, the chown -R
	# issued after extraction will not do it
	if [ "`id -u`" = 0 ] && [ "`id -un`" != "$owner" ]; then
	    chown -h -- "$owner:" "$pgdata/pg_tblspc/$oid"
	fi
    fi

    # Get the data in place
    case $storage in
	"tar")
	    info "extracting tablespace \"${name}\" to $tbldir"
	    was=`pwd`
	    cd -- "$tbldir"
	    if [ "$local_backup" = "yes" ]; then
		$uncompress_bin -c -- "$backup_dir/tblspc/${_name}.tar.$compress_suffix" | tar xf -
		rc=(${PIPESTATUS[*]})
		uncompress_rc=${rc[0]}
		tar_rc=${rc[1]}
		if [ "$uncompress_rc" != 0 ] || [ "$tar_rc" != 0 ]; then
		    error "Could not extract tablespace $name to $tbldir"
		fi
	    else
		ssh -n -- "$ssh_target" "cat -- $(qw "$backup_dir/tblspc/${_name}.tar.$compress_suffix")" 2>/dev/null | $uncompress_bin | tar xf - 2>/dev/null
		rc=(${PIPESTATUS[*]})
		ssh_rc=${rc[0]}
		uncompress_rc=${rc[1]}
		tar_rc=${rc[2]}
		if [ "$ssh_rc" != 0 ] || [ "$uncompress_rc" != 0 ] || [ "$tar_rc" != 0 ]; then
		    error "Could not extract tablespace $name to $tbldir"
		fi
	    fi
	    cd -- "$was"
	    info "extraction of tablespace \"${name}\" successful"
	    ;;

	"rsync")
	    info "transferring tablespace \"${name}\" to $tbldir with rsync"
	    if [ "$local_backup" = "yes" ]; then
		rsync -aq --delete -- "$backup_dir/tblspc/${_name}/" "$tbldir/"
		rc=$?
		if [ $rc != 0 ] && [ $rc != 24 ]; then
		    error "rsync of tablespace \"${name}\" failed with exit code $rc"
		fi
	    else
		rsync $rsync_opts -e "ssh -o Compression=no" -za --delete -- "$ssh_target:$(qw "$backup_dir/tblspc/${_name}/")" "$tbldir/"
		rc=$?
		if [ $rc != 0 ] && [ $rc != 24 ]; then
		    error "rsync of tablespace \"${name}\" failed with exit code $rc"
		fi
	    fi
	    info "transfer of tablespace \"${name}\" successful"
	    ;;

	*)
	    error "Unknown STORAGE method '$storage'"
	    ;;
    esac

    # change owner of the tablespace files to the target owner
    if [ "`id -u`" = 0 ] && [ "`id -un`" != "$owner" ]; then
	info "setting owner of tablespace \"$name\" ($tbldir)"
	if ! chown -R -- "$owner:" "$tbldir"; then
	    error "could not change owner of tablespace \"$name\" to $owner"
	fi
    fi
done

# Create or symlink pg_xlog directory if needed
if [ -d "$pgxlog" ]; then
    info "creating symbolic link pg_xlog to $pgxlog"
    if ! ln -sf -- "$pgxlog" "$pgdata/pg_xlog"; then
	error "could not create $pgdata/pg_xlog symbolic link"
    fi
    if [ "`id -u`" = 0 ] && [ "`id -un`" != "$owner" ]; then
	if ! chown -h -- "$owner:" "$pgdata/pg_xlog"; then
	    error "could not change owner of pg_xlog symbolic link to $owner"
	fi
    fi
fi

if [ ! -d "$pgdata/pg_xlog/archive_status" ]; then
    info "preparing pg_xlog directory"
    if ! mkdir -p -- "$pgdata/pg_xlog/archive_status"; then
	error "could not create $pgdata/pg_xlog"
    fi

    if ! chmod -- 700 "$pgdata/pg_xlog" "$pgdata/pg_xlog/archive_status" 2>/dev/null; then
	error "could not set permissions of $pgdata/pg_xlog and $pgdata/pg_xlog/archive_status"
    fi

    if [ "`id -u`" = 0 ] && [ "`id -un`" != "$owner" ]; then
	if ! chown -R -- "$owner:" "$pgdata/pg_xlog"; then
	    error "could not change owner of $dir to $owner"
	fi
    fi
fi

# Check PG_VERSION
if [ -f "$pgdata/PG_VERSION" ]; then
    pgvers=$(< "$pgdata/PG_VERSION")
    pgvers=${pgvers//./0}
else
    warn "PG_VERSION file is missing"
fi

# Create a recovery.conf file in $PGDATA
info "preparing recovery.conf file"
echo "restore_command = '$restore_command'" > "$pgdata/recovery.conf"

# Put the given target date in recovery.conf
if [ -n "$recovery_target_time" ]; then
    echo "recovery_target_time = '$recovery_target_time'" >> "$pgdata/recovery.conf"
else
    echo "#recovery_target_time = ''	# e.g. '2004-07-14 22:39:00 EST'" >> "$pgdata/recovery.conf"
fi

# Add all possible parameters for recovery, commented out.
case $pgvers in
    802|803)
	echo "#recovery_target_xid = ''		# 'number'"
	echo "#recovery_target_inclusive = 'true'		# 'true' or 'false'"
	echo "#recovery_target_timeline = ''		# number or 'latest'"
	;;
    804)
	echo "#recovery_end_command = ''"
	echo "#recovery_target_xid = ''		# 'number'"
	echo "#recovery_target_inclusive = 'true'		# 'true' or 'false'"
	echo "#recovery_target_timeline = ''		# number or 'latest'"
	;;
    901|902|903)
	echo "#recovery_end_command = ''"
	echo "#recovery_target_name = ''  # e.g. 'daily backup 2011-01-26'"
	echo "#recovery_target_xid = ''"
	echo "#recovery_target_inclusive = true"
	echo "#recovery_target_timeline = 'latest'"
	echo "#pause_at_recovery_target = true"
	;;
    904)
	echo "#recovery_end_command = ''"
	echo "#recovery_target_name = ''	# e.g. 'daily backup 2011-01-26'"
	echo "#recovery_target_xid = ''"
	echo "#recovery_target_inclusive = true"
	echo "#recovery_target = 'immediate'"
	echo "#recovery_target_timeline = 'latest'"
	echo "#pause_at_recovery_target = true"
	;;
    905|906)
	echo "#recovery_end_command = ''"
	echo "#recovery_target_name = ''	# e.g. 'daily backup 2011-01-26'"
	echo "#recovery_target_xid = ''"
	echo "#recovery_target_inclusive = true"
	echo "#recovery_target = 'immediate'"
	echo "#recovery_target_timeline = 'latest'"
	echo "#recovery_target_action = 'pause'"
	;;
esac >> "$pgdata/recovery.conf"


# Ensure recovery.conf as the correct owner so that PostgreSQL can
# rename it at the end of the recovery
if [ "`id -u`" = 0 ] && [ "`id -un`" != "$owner" ]; then
    if ! chown -R -- "$owner:" "$pgdata/recovery.conf"; then
	error "could not change owner of recovery.conf to $owner"
    fi
fi

# Generate a SQL file in PGDATA to update the catalog when tablespace
# locations have changed. It is only needed when using PostgreSQL <=9.1
updsql=$pgdata/update_catalog_tablespaces.sql
rm -f -- "$updsql"
if (( $tspc_count > 0 )) && [ -n "$pgvers" ] && (( 10#$pgvers <= 901 )); then
    for (( i=0; i<$tspc_count; ++i )); do
	if [ "${tspc_reloc[$i]}" = "yes" ]; then
	    echo "-- update location of ${tspc_name[$i]} to ${tspc_dir[$i]}" >> "$updsql"
	    printf "UPDATE pg_catalog.pg_tablespace SET spclocation = '%s' WHERE oid = %s;\n" "${tspc_dir[$i]}" "${tspc_oid[$i]}" >> "$updsql"
	fi
    done

    if [ "`id -u`" = 0 ] && [ "`id -un`" != "$owner" ]; then
	chown -- "$owner:" "$updsql" 2>/dev/null
    fi
fi

# Generate a SQL file in PGDATA to let the user recreate the
# replication slots existing at backup time
replslots_sql=$pgdata/restore_replication_slots.sql
rm -f -- "$replslots_sql"
if [ -n "$pgvers" ] && (( 10#$pgvers >= 904 )); then
    if [ "$local_backup" = "yes" ]; then
	if [ -f "$backup_dir/replslot_list" ]; then
	    replslot_list=$(< "$backup_dir/replslot_list") || error "Failed to read $backup_dir/replslot_list"
	fi
    else
	rfile=$(qw "$backup_dir/replslot_list")
	replslot_list=$(ssh -n -- "$ssh_target" "[ ! -f $rfile ] || cat -- $tfile") ||
            error "Failed to read $source:$backup_dir/replslot_list"
    fi

    while read -r l; do
	rs_name=$(cut -d '|' -f 1 <<< "$l")
	rs_plugin=$(cut -d '|' -f 2 <<< "$l")
	rs_type=$(cut -d '|' -f 3 <<< "$l")
	rs_db=$(cut -d '|' -f 4 <<< "$l")

	case $rs_type in
	    "physical")
		echo "SELECT pg_create_physical_replication_slot('$rs_name');"
		;;
	    "logical")
		echo "\connect $rs_db"
		echo "SELECT pg_create_logical_replication_slot('$rs_name', '$rs_plugin');"
		;;
	esac >> "$replslots_sql"
    done <<< "$replslot_list"
fi

info "done"
info
if [ -d "$restored_conf" ]; then
    info "saved configuration files have been restored to:"
    info "  $restored_conf"
    info
fi
info "please check directories and recovery.conf before starting the cluster"
info "and do not forget to update the configuration of pitrery if needed"
info

if [ -f "$replslots_sql" ]; then
    if [[ $(cat "$replslots_sql" | wc -l) > 0 ]]; then
        info "replication slots defined at the time of the backup can be restored"
        info "with the SQL commands from:"
        info "  $replslots_sql"
        info
    else
        rm -f -- "$replslots_sql"
    fi
fi

if [ -f "$updsql" ]; then
    warn "locations of tablespaces have changed, after recovery update the catalog with:"
    warn "  $updsql"
fi

