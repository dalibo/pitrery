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
    echo "`basename $0` checks the configuration of pitrery"
    echo
    echo "Usage:"
    echo "    `basename $0` [options] [config_file]"
    echo
    echo "Options"
    echo "    -C conf              Configuration file"
    echo
    echo "    -?                   Print help"
    echo
    exit $1
}

error() {
    echo "ERROR: $*" 1>&2
    out_rc=1
}


warn() {
    echo "WARNING: $*" 1>&2
}

info() {
    echo "INFO: $*"
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


# Hard coded configuration. We do not set the PG* variables so that
# the environment is not overwritten by our defaults. The user can set
# the variable he/she wants in the configuration and set the rest in
# the environment.
config_dir="@SYSCONFDIR@"
config=pitr.conf
psql_command=( "psql" "-X" )
PGXLOG=
BACKUP_IS_LOCAL="no"
BACKUP_DIR="/var/lib/pgsql/backups"
BACKUP_LABEL="pitr"
BACKUP_HOST=
BACKUP_USER=
RESTORE_COMMAND=
PURGE_KEEP_COUNT=
PURGE_OLDER_THAN=
PRE_BACKUP_COMMAND=
POST_BACKUP_COMMAND=
STORAGE="tar"
LOG_TIMESTAMP="no"
ARCHIVE_LOCAL="no"
ARCHIVE_HOST=
ARCHIVE_USER=
ARCHIVE_DIR="$BACKUP_DIR/$BACKUP_LABEL/archived_xlog"
ARCHIVE_COMPRESS="yes"
ARCHIVE_OVERWRITE="yes"
SYSLOG="no"
SYSLOG_FACILITY="local0"
SYSLOG_IDENT="postgres"
ARCHIVE_COMPRESS_BIN="gzip -f -4"
ARCHIVE_COMPRESS_SUFFIX="gz"
ARCHIVE_UNCOMPRESS_BIN="gunzip"
BACKUP_COMPRESS_BIN="gzip -4"
BACKUP_COMPRESS_SUFFIX="gz"
BACKUP_UNCOMPRESS_BIN="gunzip"


# CLI options
while getopts "C:?" opt; do
    case $opt in
	C) config=$OPTARG;;

	"?") usage 1;;
	*) error "Unknown error while processing options";;
    esac
done

# search and load the configuration file

# Check if the config option is a path or just a name in the
# configuration directory.  Prepend the configuration directory and
# .conf when needed.
if [[ $config != */* ]]; then
    config="$config_dir/$(basename -- "$config" .conf).conf"
fi

info "Configuration file is: $config"

# Load the configuration file
if [ -f "$config" ]; then
    info "loading configuration"
    . "$config"
else
    error "cannot access configuration file: $config"
fi

# Dump configuration file
info "the configuration file contains:"
grep -- '=' "$config" | grep -E '^[^[:space:]#]+'
echo

info "==> checking the configuration for inconsistencies"

conf_ok=1
# Sanity checks on the configuration
if [ -z "$BACKUP_HOST" ] && [ "$BACKUP_IS_LOCAL" != "yes" ]; then
    error 'BACKUP_HOST must be configured when BACKUP_IS_LOCAL="no"'
    conf_ok=0
fi

if [ -n "$BACKUP_HOST" ] && [ "$BACKUP_IS_LOCAL" = "yes" ]; then
    error "BACKUP_HOST is set and BACKUP_IS_LOCAL=\"yes\" are set, it can't be both"
    conf_ok=0
fi

# Only tar or rsync are allowed as storage method
if [ "$STORAGE" != "tar" ] && [ "$STORAGE" != "rsync" ]; then
    error "storage method (STORAGE) must be 'tar' or 'rsync'"
    conf_ok=0
fi

# At least one of PURGE_KEEP_COUNT and PURGE_OLDER_THAN must be
# configured, otherwise purge won't work
if [ -z "$PURGE_KEEP_COUNT" ] && [ -z "$PURGE_OLDER_THAN" ]; then
    error "purge not configured, either PURGE_KEEP_COUNT or PURGE_OLDER_THAN must be set"
    conf_ok=0
fi

if [[ $conf_ok == 1 ]]; then
    info "configuration seems correct"
else
    warn "errors found in the configuration. The following tests may not be accurate"
fi

# Prepare psql command, it must be an array.
if [ -n "$PGPSQL" ]; then
    psql_command=( "$PGPSQL" )
fi

# Check ssh access
check_ssh() {
    local ssh_target=$1

    if ssh -n -- "$ssh_target" "test -d /" 2>/dev/null; then
	info "ssh connection to $ssh_target ok"
	return 0
    else
	error "cannot connect to $ssh_target with ssh"
	return 1
    fi
}

check_local_rsync() {
    if ! which rsync >/dev/null 2>&1; then
	error "could not find rsync in the PATH of the local host"
	return 1
    else
	info "rsync found on the local host"
	return 0
    fi
}



check_remote_directory() {
    local ssh_target=$1
    local dest_dir=$2
    local dest_exists
    local dest_isdir
    local dest_writable

    dest_exists=$(ssh -n -- "$ssh_target" "[ -e $(qw "$dest_dir") ] || echo 'ko'")
    if [ $? = 0 ]; then
	if [ ! -n "$dest_exists" ]; then
	    dest_isdir=$(ssh -n -- "$ssh_target" "[ -d $(qw "$dest_dir") ] || echo 'ko'")
	    if [ $? = 0 ]; then
		if [ ! -n "$dest_isdir" ]; then
		    info "target directory '$dest_dir' exists"
		    dest_writable=$(ssh -n -- "$ssh_target" "[ -w $(qw "$dest_dir") ] || echo 'ko'")
		    if [ $? = 0 ]; then
			if [ ! -n "$dest_writable" ]; then
			    info "target directory '$dest_dir' is writable"
			else
			    error "target directory '$dest_dir' is NOT writable"
			fi
		    else
			error "could not check directory ${ssh_target}:$dest_dir"
		    fi
		else
		    error "target '$dest_dir' exists but is NOT a directory"
		fi
	    else
		error "could not check directory ${ssh_target}:$dest_dir"
	    fi
	else
	    error "target directory '$dest_dir' does NOT exist or is NOT reachable"
	fi
    else
	error "could not check directory ${ssh_target}:$dest_dir"
    fi
}

check_local_directory() {
    local dest_dir=$1

    if [ -e "$dest_dir" ]; then
	if [ -d "$dest_dir" ]; then
	    info "target directory '$dest_dir' exists"
	    if [ -w "$dest_dir" ]; then
		info "target directory '$dest_dir' is writable"
	    else
		error "target directory '$dest_dir' is NOT writable"
	    fi
	else
	    error "target '$dest_dir' exists but is NOT a directory"
	fi
    else
	error "target directory '$dest_dir' does NOT exist or is NOT reachable"
    fi
}

info "==> checking backup configuration"
    
if [ "$BACKUP_IS_LOCAL" = "no" ]; then
    info "checking SSH connection for backups"

    # Ensure the target host and is user are usable by SSH, quote IPv6
    # numeric address with brackets
    target="$BACKUP_HOST"
    [[ $target == *([^][]):*([^][]) ]] && target="[${target}]"
    backup_ssh_target=${BACKUP_USER:+$BACKUP_USER@}$target
    
    if ! check_ssh "$backup_ssh_target"; then
	error "the backup host must be reachable. Aborting"
	exit 1
    fi

    info "checking backup directory: $BACKUP_DIR"
    # check if the target directory exist, or can be created. It means a
    # parent must exist and be writable. At this point we cannot see
    # if it is a proper mount point that would have enough space
    check_remote_directory "$backup_ssh_target" "$BACKUP_DIR"

    # Check if rsync is available on the remote host, it is only
    # needed by the rsync storage method
    if [[ $STORAGE == "rsync" ]]; then
	info "checking rsync on the remote host: $archive_ssh_target"
	if ! ssh -n -- "$backup_ssh_target" "which rsync" >/dev/null 2>&1; then
	    error "could not find rsync in the PATH on $backup_ssh_target"
	else
	    info "rsync found on the remote host"
	fi
    fi

else
    info "backups are local, not checking SSH"

    check_local_directory "$BACKUP_DIR"
fi

# Check the local rsync
if [[ $STORAGE == "rsync" ]]; then
    info "checking rsync on the local host"
    if ! which rsync >/dev/null 2>&1; then
	error "could not find rsync in the PATH of the local host"
    else
	info "rsync found on the local host"
    fi
fi

info "==> checking WAL files archiving configuration"

arch_ok="yes"
if [[ "$ARCHIVE_LOCAL" == "no" ]]; then
    info "checking SSH connection for WAL archiving"

    target="$ARCHIVE_HOST"
    [[ $target == *([^][]):*([^][]) ]] && target="[${target}]"
    archive_ssh_target=${ARCHIVE_USER:+$ARCHIVE_USER@}$target
    
    check_ssh "$archive_ssh_target" || arch_ok="no"

    info "checking WAL archiving directory: $ARCHIVE_DIR"
    check_remote_directory "$archive_ssh_target" "$ARCHIVE_DIR" || arch_ok="no"

    # Check if rsync is installed on the remote host
    info "checking rsync on the remote host: $archive_ssh_target"
    if ! ssh -n -- "$archive_ssh_target" "which rsync" >/dev/null 2>&1; then
	error "could not find rsync in the PATH on $archive_ssh_target"
	arch_ok="no"
    else
	info "rsync found on the remote host"
    fi
    
else
    info "WAL archiving is local, not checking SSH"
    info "checking WAL archiving directory: $ARCHIVE_DIR"
    check_local_directory "$ARCHIVE_DIR" || arch_ok="no"
fi

# Check the local rsync for WAL archiving
if [[ $STORAGE == "rsync" ]] || [[ $ARCHIVE_LOCAL == "no" ]]; then
    info "checking rsync on the local host"
    if ! which rsync >/dev/null 2>&1; then
	error "could not find rsync in the PATH of the local host"
	arch_ok="no"
    else
	info "rsync found on the local host"
    fi
fi

# Archiving with archive_xlog is not mandatory, so tell the user that
# it may be unusable
if [[ $arch_ok == "no" ]]; then
    error "archiving may not work with archive_xlog and the current configuration"
    error "please consider another way to archive WAL files"
fi

# Check access to postgres
info "==> checking access to PostgreSQL"

# Prepare psql command line
[ -n "$PGHOST" ] && psql_command+=( "-h" "$PGHOST" )
[ -n "$PGPORT" ] && psql_command+=( "-p" "$PGPORT" )
[ -n "$PGUSER" ] && psql_command+=( "-U" "$PGUSER" )

psql_condb=${PGDATABASE:-postgres}

# Show the command line of psql and the contents of the environnement
# variables starting with PG, they may affect the behaviour of psql.
info "psql command and connection options are: ${psql_command[@]}"
info "connection database is: $psql_condb"
info "environment variables (maybe overwritten by the configuration file):"
while read -r -d '' v; do
    echo $v | grep -q "^PG" || continue
    info "  $v"
done < <(env -0 2>/dev/null || warn "could not read the environment: env -0 failed")

# Get the complete version from PostgreSQL
pg_dotted_version=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'server_version';" -- "$psql_condb" 2>/dev/null)
rc=$?
if [ $rc = 127 ]; then
    error "psql invocation error: command not found"
elif [ $rc = 2 ]; then
    error "could not connect to PostgreSQL"
elif [ $rc != 0 ]; then
    error "could not get the version of the server"
else
    info "PostgreSQL version is: $pg_dotted_version"

    # Now get the numerical version of PostgreSQL so that we can compare
    # it
    if ! pg_version=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'server_version_num';" -- "$psql_condb"); then
	error "could not get the numerical version of the server"
    fi

    # Check if the server is in hot standby. If so, basebackup
    # functions won't work. It is only necessary as of 9.0, before it
    # was not possible to a warm standby anyway.
    if (( 10#$pg_version >= 90000 )); then
	if ! hot_standy=$("${psql_command[@]}" -Atc "SELECT pg_is_in_recovery();" -- "$psql_condb"); then
	    error "could not check if the server is in hot standby"
	else
	    if [[ $hot_standby == "t" ]]; then
		error "server is in hot standby, backup won't work"
	    fi
	fi
    fi

    # Check the attributes of the connection role, it must be
    # superuser or have the replication attribute (>= 9.1)
    if (( 10#$pg_version >= 90100 )); then
	if ! role=$("${psql_command[@]}" -Atc "SELECT rolname FROM pg_roles WHERE rolname = current_user AND (rolsuper OR rolreplication);" -- "$psql_condb"); then
	    error "could not check if connection role has privileges to run backup functions"
	else
	    if [ -n "$role" ]; then
		info "connection role can run backup functions"
	    else
		error "connection role cannot run backup functions"
	    fi
	fi
    else
	if ! role=$("${psql_command[@]}" -Atc "SELECT rolname FROM pg_roles WHERE rolname = current_user AND rolsuper;" -- "$psql_condb"); then
	    error "could not check if connection role has privileges to run backup functions"
	else
	    if [ -n "$role" ]; then
		info "connection role can run backup functions"
	    else
		error "connection role cannot run backup functions"
	    fi
	fi
    fi

    # Check configuration of PostgreSQL
    info "current configuration:"
    if (( $pg_version >= 90000 )); then
	if ! wal_level=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'wal_level';" -- "$psql_condb"); then
	    error "could not get the get the value of wal_level"
	fi
	info "  wal_level = $wal_level"
    fi

    if (( $pg_version >= 80300 )); then
	if ! archive_mode=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'archive_mode';" -- "$psql_condb"); then
	    error "could not get the get the value of archive_mode"
	fi
	info "  archive_mode = $archive_mode"
    fi

    if ! archive_command=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'archive_command';" -- "$psql_condb"); then
	error "could not get the get the value of archive_command"
    fi
    info "  archive_command = '$archive_command'"

    # wal_level must be different than minimal
    if [ -n "$wal_level" ] && [ $wal_level = "minimal" ]; then
        if (( $pg_version >= 90000 )); then
            if (( $pg_version < 90600 )); then
	        error "wal_level must be set at least to archive"
            else
                # archive and hot_standby levels have been merged into
                # replica starting from 9.6
                error "wal_level must be set at least to replica"
            fi
        fi
    fi

    if [ -n "$archive_mode" ] && [ $archive_mode = "off" ]; then
	error "archive_mode must be set to on"
    fi

    if [ -z "$archive_command" ]; then
	error "archive_command is empty"
    fi

    # Get the data directory from PostgreSQL, later we can compare it
    # to PGDATA variable and see if the configuration is correct.
    if ! data_directory=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'data_directory';" -- "$psql_condb"); then
	error "could not get the get the value of data_directory"
    fi

fi

info "==> checking access to PGDATA"

# Access to PGDATA
if [ -n "$data_directory" ]; then
    test "$PGDATA" -ef "$data_directory"
    if [ $? != 0 ]; then
	info "data_directory setting is: $data_directory"
	info "PGDATA is: $PGDATA"
	error "configured PGDATA is different than the data directory reported by PostgreSQL"
    else
	info "PostgreSQL and the configuration reports the same PGDATA"
    fi
fi

# This test may be stupid but in case we do not have access to
# PostgreSQL, we only have the configuration which may be
# incorrect
if [ ! -e "$PGDATA" ]; then
    error "$PGDATA does not exist"
    exit 1
fi

if [ ! -d "$PGDATA" ]; then
    error "$PGDATA is not a directory"
    exit 1
fi

dperms=$(stat -c %a -- "$PGDATA" 2>/dev/null) || error "Unable to get permissions of $PGDATA"
downer=$(stat -c %U -- "$PGDATA" 2>/dev/null) || error "Unable to get owner of $PGDATA"

if [[ "$dperms" == "700" ]]; then
    info "permissions of PGDATA ok"
else
    warn "permissions of PGDATA are not 700: $dperms"
fi

# Do not run the owner test if run as root, superuser won't have
# problems accessing the files
if [ "$(id -u)" != 0 ]; then
    owner=${PGOWNER:-$(id -un)}
    if [[ "$owner" == "$downer" ]]; then
	info "owner of PGDATA is the current user"
    else
	warn "owner of PGDATA is not the current user: $downer"
    fi

    # To see if we can backup, just check if we can read the version
    # file
    if [[ -r "$PGDATA/PG_VERSION" ]]; then
	info "access to the contents of PGDATA ok"
    else
	error "cannot read $PGDATA/PG_VERSION, access to PGDATA may not be possible"
    fi
else
    info "running as root, not checking access to the contents of PGDATA"
fi
    
exit $out_rc
