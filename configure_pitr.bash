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
    echo "`basename $0` configures pitrery"
    echo
    echo "Usage:"
    echo "    `basename $0` [options] [[user@]host:]/path/to/backups"
    echo
    echo "Options:"
    echo "    -o config_file         Output configuration file"
    echo "    -f                     Overwrite the destination file"
    echo "    -C                     Do not connect to PostgreSQL"
    echo
    echo "Configuration options:"
    echo "    -l label               Backup label"
    echo "    -s mode                Storage method, tar or rsync"
    echo "    -m count               Number of backups to keep"
    echo "    -g days                Remove backup older then this number of days"
    echo "    -D dir                 Path to \$PGDATA"
    echo "    -a [[user@]host:]/dir  Place to store WAL archives"
    echo
    echo "Connection options:"
    echo "    -P psql                Path to the psql command"
    echo "    -h hostname            Database server host or socket directory"
    echo "    -p port                Database server port number"
    echo "    -U name                Connect as specified database user"
    echo "    -d database            Database to use for connection"
    echo
    echo "    -?                     Print help"
    echo
    exit $1
}


error() {
    echo "ERROR: $*" 1>&2
    [ -n "$conffile" ] && rm -- $conffile 
    exit 1
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


# Hard coded configuration
config_dir="@SYSCONFDIR@"
psql_command=( "psql" "-X" )
label_prefix=$(hostname)
storage="tar"
connect="yes"
overwrite_config="no"

# CLI options
while getopts "o:fCl:s:m:g:D:a:P:h:p:U:d:?" opt; do
    case $opt in
	o) output=$OPTARG;;
	f) overwrite_config="yes";;
	C) connect="no";;
	l) label_prefix=$OPTARG;;
	s) storage=$OPTARG;;
	m) max_count=$OPTARG;;
	g) max_days=$OPTARG;;
	D) pgdata=$OPTARG;;
	a) archive_target=$OPTARG;;

	P) psql=$OPTARG; psql_command=( "$OPTARG" );;
        h) dbhost=$OPTARG;;
        p) dbport=$OPTARG;;
        U) dbuser=$OPTARG;;
        d) dbname=$OPTARG;;
	
	 "?") usage 1;;
        *) error "Unknown error while processing options";;
    esac
done

target=${@:$OPTIND:1}

# Consistency checks

# target directory for backups must be provided
if [ -z "$target" ]; then
    echo "ERROR: missing target backup directory" 1>&2
    usage 1
fi

# Only tar and rsync are allowed as storage methode
if [ "$storage" != "tar" ] && [ "$storage" != "rsync" ]; then
    error "storage method must be 'tar' or 'rsync'"
fi

# Parse the target into user, host and path, deduce if backup is local
backup_user="$(echo $target | grep '@' | cut -d'@' -f1 )"
backup_host="$(echo $target | grep ':' | sed -Ee 's/(.*):(.*)/\1/' | cut -d'@' -f2 )"
backup_dir="$(echo $target | sed -Ee 's/(.*):(.*)/\2/')"
if [ -z "$backup_host" ]; then
    backup_local="yes"
else
    backup_local="no"
fi

[ -n "$backup_dir" ] || error "missing backup directory"

# Parse archive target the same way
if [ -n "$archive_target" ]; then
    archive_user="$(echo $archive_target | grep '@' | cut -d'@' -f1 )"
    archive_host="$(echo $archive_target | grep ':' | sed -Ee 's/(.*):(.*)/\1/' | cut -d'@' -f2 )"
    archive_dir="$(echo $archive_target | sed -Ee 's/(.*):(.*)/\2/')"
    if [ -z "$archive_host" ]; then
	archive_local="yes"
    else
	archive_local="no"
    fi

    [ -n "$archive_dir" ] || error "missing archive directory"
else
    archive_user="$backup_user"
    archive_host="$backup_host"
    archive_dir="\$BACKUP_DIR/\$BACKUP_LABEL/archived_xlog"
    archive_local=$backup_local
fi



if [ "$connect" = "yes" ]; then
    # Check if PostgreSQL is available and check its configuration. The
    # purpose is to output what should be changed to configure WAL
    # archiving.
    info "==> checking access to PostgreSQL"
    [ -n "$dbhost" ] && psql_command+=( "-h" "$dbhost" )
    [ -n "$dbport" ] && psql_command+=( "-p" "$dbport" )
    [ -n "$dbuser" ] && psql_command+=( "-U" "$dbuser" )
    [ -n "$dbname" ] && psql_condb="$dbname"

    # Get the complete version from PostgreSQL
    pg_dotted_version=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'server_version';" -- "$psql_condb" 2>/dev/null)
    rc=$?
    if [ $rc = 127 ]; then
	warn "psql invocation error: command not found"
    elif [ $rc = 2 ]; then
	warn "could not connect to PostgreSQL"
    elif [ $rc != 0 ]; then
	warn "could not get the version of the server"
    else
	info "PostgreSQL version is: $pg_dotted_version"

	# Now get the numerical version of PostgreSQL so that we can compare
	# it
	if ! pg_version=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'server_version_num';" -- "$psql_condb"); then
	    warn "could not get the numerical version of the server"
	fi

	# Check configuration of PostgreSQL
	info "current configuration:"
	if (($pg_version >= 90000 )); then
	    if ! wal_level=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'wal_level';" -- "$psql_condb"); then
		warn "could not get the get the value of wal_level"
	    fi
	    info "  wal_level = $wal_level"
	fi

	if (($pg_version >= 80300 )); then
	    if ! archive_mode=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'archive_mode';" -- "$psql_condb"); then
		warn "could not get the get the value of archive_mode"
	    fi
	    info "  archive_mode = $archive_mode"
	fi

	if ! archive_command=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'archive_command';" -- "$psql_condb"); then
	    warn "could not get the get the value of archive_command"
	fi
	info "  archive_command = '$archive_command'"

	if ! syslog=$("${psql_command[@]}" -Atc "SELECT setting ~ 'syslog' FROM pg_settings WHERE name = 'log_destination';" -- "$psql_condb"); then
	    warn "could not get get the value of log_destination"
	fi

	if [ "$syslog" = "t" ]; then
	    if ! syslog_facility=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'syslog_facility';" -- "$psql_condb"); then
		warn "could not get get the value of syslog_facility"
	    fi

	    if ! syslog_ident=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'syslog_ident';" -- "$psql_condb"); then
		warn "could not get get the value of syslog_ident"
	    fi
	fi
	
	# wal_level must be different than minimal
	if [ -n "$wal_level" ] && [ $wal_level = "minimal" ]; then
	    info "wal_level must be set to a value higher than minimal"
	fi

	if [ -n "$archive_mode" ] && [ $archive_mode = "off" ]; then
	    info "archive_mode must be set to on"
	fi

	if [ -n "$output" ]; then
	    info "please ensure archive_command includes 'archive_xlog -C $output %p'"
	else
	    info "please ensure archive_command includes a call to archive_xlog"
	fi

	# Get the data directory from PostgreSQL, later we can compare it
	# to PGDATA variable and see if the configuration is correct.
	if ! data_directory=$("${psql_command[@]}" -Atc "SELECT setting FROM pg_settings WHERE name = 'data_directory';" -- "$psql_condb"); then
	    warn "could not get the get the value of data_directory"
	fi
    fi
fi

# When check of PostgreSQL is disabled, only output what should be
# changed in postgresql.conf
if [ -z "$data_directory" ]; then
    info "==> PostgreSQL configuration to change in 'postgresql.conf':"
    info "  wal_level = archive # or higher (>= 9.0)"
    info "  archive_mode = on # (>= 8.3)"
    if [ -n "$output" ]; then
	info "  archive_command = 'archive_xlog -C $output %p'"
    else
	info "  archive_command = 'archive_xlog -C {your_conf} %p'"
    fi
fi

# Check PGDATA, if it consistent with the data_directory parameter of
# PostgreSQL. It has it flows but it is a simple consitency test.
info "==> checking \$PGDATA"
if [ -n "$pgdata" ]; then
    if [ -n "$data_directory" ]; then
	test "$pgdata" -ef "$data_directory"
	if [ $? != 0 ]; then
	    info "data_directory setting is: $data_directory"
	    info "PGDATA is: $pgdata"
	    error "configured PGDATA is different than the data directory reported by PostgreSQL"
	fi
    fi
else
    pgdata="$data_directory"
fi

# When PGDATA is not provided on the command line and PostgreSQL is
# unreachable, fallback on the PGDATA environment variable.
if [ -z "$pgdata" ] && [ -z "$data_directory" ]; then
    if [ -n "$PGDATA" ]; then
	pgdata="$PGDATA"
    else
	error "could not find what PGDATA is. Use -D or -? for help."
    fi
fi

# This test may be stupid but in case we do not have access to
# PostgreSQL, we only have the configuration which may be
# incorrect
if [ ! -e "$pgdata" ]; then
    error "$pgdata does not exist"
    exit 1
fi

if [ ! -d "$pgdata" ]; then
    error "$pgdata is not a directory"
    exit 1
fi

downer=$(stat -c %U -- "$pgdata" 2>/dev/null) || error "Unable to get owner of $pgdata"

# Do not run the owner test if run as root, superuser won't have
# problems accessing the files
if [ "$(id -u)" != 0 ]; then
    owner=$(id -un)
    if [[ "$owner" != "$downer" ]]; then
	warn "owner of PGDATA is not the current user: $downer"
	pgowner=$downer
    fi

    # To see if we can backup, just check if we can read the version
    # file
    if [[ -r "$pgdata/PG_VERSION" ]]; then
	info "access to the contents of PGDATA ok"
    else
	warn "cannot read $pgdata/PG_VERSION, access to PGDATA may not be possible"
    fi
fi

# Simple helper function to output a parameter and replace it in the
# given file. Since some OS do not support the -i option of sed, we
# have to use a temporary file. Since we are in the configuration
# stage, switching a lot between temp files is not a performance
# issue.
output_param() {
    local param=$1
    local value=$2
    local file=$3

    echo "${param}=\"${value}\""

    if [ -n "$file" ]; then
	local tmpfile=$(mktemp -t pitr_config_sed.XXXXXXXXXX) ||
            error "Failed to create temporary file"

	# Replace the parameter with sed, the value is quoted so that
	# commas in the value do not conflict with our sed sed
	# construct
	v=$(qw "$value")

	cat "$file" | sed -re "s,^#${param}=.*,${param}=\"${v//,/\\,}\"," > "$tmpfile" ||
	    error "Cannot change parameter in configuration file"

	mv "$tmpfile" "$file" || error "Cannot rename tmpfile to configuration file"
    fi
}

info "==> contents of the configuration file"
echo
if [ -n "$output" ]; then
    # We want to create a configuration file with all the comments and
    # possible options so that it can be easily tuned afterwards. We use a
    # template configuration file which is basically the default
    # configuration files stored in a different place.
    if [ -r "@SHAREDIR@/pitr.conf.template" ]; then
	conffile=$(mktemp -t pitr_config.XXXXXXXXXX) ||
            error "Failed to create temporary file for the new configuration file"

	# Ensure the configuration file has everything commented out, so
	# that we can uncomment only what is configured here
	cat "@SHAREDIR@/pitr.conf.template" | sed -re 's/^([^#])/#\1/' > "$conffile"
    fi
fi

# Write all configured parameters
output_param "PGDATA" "$pgdata" "$conffile"

if [ -n "$dbuser" ]; then
    output_param "PGUSER" "$dbuser" "$conffile"
elif [ -n "$PGUSER" ]; then
    output_param "PGUSER" "$PGUSER" "$conffile"
fi

if [ -n "$dbport" ]; then
    output_param "PGPORT" "$dbport" "$conffile"
elif [ -n "$PGPORT" ]; then
    output_param "PGPORT" "$PGPORT" "$conffile"
fi

if [ -n "$dbhost" ]; then
    output_param "PGHOST" "$dbhost" "$conffile"
elif [ -n "$PGHOST" ]; then
    output_param "PGHOST" "$PGHOST" "$conffile"
fi

if [ -n "$dbname" ]; then
    output_param "PGDATABASE" "$dbname" "$conffile"
elif [ -n "$PGDATABASE" ]; then
    output_param "PGDATABASE" "$PGDATABASE" "$conffile"
fi

[ -n "$psql" ] && output_param "PGPSQL" "$psql" "$conffile"
[ -n "$pgowner" ] && output_param "PGOWNER" "$pgowner" "$conffile"

output_param "BACKUP_IS_LOCAL" "$backup_local" "$conffile"
output_param "BACKUP_DIR" "$backup_dir" "$conffile"
output_param "BACKUP_LABEL" "$label_prefix" "$conffile"
[ -n "$backup_host" ] && output_param "BACKUP_HOST" "$backup_host" "$conffile"
[ -n "$backup_user" ] && output_param "BACKUP_USER" "$backup_user" "$conffile"

[ -n "$max_count" ] && output_param "PURGE_KEEP_COUNT" "$max_count" "$conffile"
[ -n "$max_days" ] && output_param "PURGE_OLDER_THAN" "$max_days" "$conffile"
# Fallback on a keep count of 2, so that our configuration passes
# the check action
if [ -z "$max_count" ] && [ -z "$max_days" ]; then
    output_param "PURGE_KEEP_COUNT" 2 "$conffile"
fi

output_param "STORAGE" "$storage" "$conffile"

output_param "ARCHIVE_LOCAL" "$archive_local" "$conffile"
[ -n "$archive_host" ] && output_param "ARCHIVE_HOST" "$archive_host" "$conffile"
[ -n "$archive_user" ] && output_param "ARCHIVE_USER" "$archive_user" "$conffile"
output_param "ARCHIVE_DIR" "$archive_dir" "$conffile"

if [ "$syslog" = "t" ]; then
    output_param "SYSLOG" "yes" "$conffile"
    [ "$syslog_facility" != "local0" ] && output_param "SYSLOG_FACILITY" "$syslog_facility" "$conffile"
    [ "$syslog_ident" != "postgres" ] && output_param "SYSLOG_IDENT" "$syslog_ident" "$conffile"
fi
echo

# Write the configuration file
if [ -n "$output" ]; then
    # Check if the output config option is a path or just a name in
    # the configuration directory.  Prepend the configuration
    # directory and .conf when needed.
    if [[ $output != */* ]]; then
	output="$config_dir/$(basename -- "$output" .conf).conf"
    fi

    info "writing configuration file: $output"
    
    # Do not overwrite an existing configuration file
    if [ -f "$output" ] && [ $overwrite_config = "no" ]; then
	error "target configuration file '$output' already exists"
    fi
    
    if [ -w "$(dirname -- "$output")" ]; then
	if [ -n "$conffile" ]; then
	    cp -- "$conffile" "$output" || error "Could not write $output"
	    rm -- $conffile
	fi
	   
    else
	error "Could not write $output: directory is not writable"
    fi
else
    [ -n "$conffile" ] && rm -- $conffile
fi
