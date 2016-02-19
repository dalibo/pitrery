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

config_dir="@SYSCONFDIR@"
config=pitr.conf
scripts_dir="@LIBDIR@"
list_configs="no"

usage() {
    echo "usage: `basename $0` [options] action [args]"
    echo "options:"
    echo "    -c file      Path to the configuration file"
    echo "    -n           Show the command instead of executing it"
    echo "    -l           List configuration files in the default directory"
    echo "    -V           Display the version and exit"
    echo "    -?           Print help"
    echo
    echo "actions:"
    echo "    list"
    echo "    backup"
    echo "    restore"
    echo "    purge"
    echo "    check"
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

while getopts "c:nlV?" opt; do
    case $opt in
	c) config=$OPTARG;;
	n) dry_run="echo";;
	l) list_configs="yes";;
	V) echo "pitrery @VERSION@"; exit 0;;
	'?') usage 1;;
	*) error "error while processing options";;
    esac
done

# Ensure failed globs will be empty, not left containing the literal glob pattern
shopt -s nullglob

# List the configuration files and exit
if [ "$list_configs" = "yes" ]; then
    info "listing configuration files in $config_dir"
    for x in "$config_dir"/*.conf; do
	basename -- "$x" .conf
    done
    exit 0
fi

if (( $# < 1 )); then
    echo "ERROR: missing action" 1>&2
    usage 1
fi

action=${@:$OPTIND:1}
OPTIND=$(( $OPTIND + 1 ))

# Check if the config option is a path or just a name in the
# configuration directory.  Prepend the configuration directory and
# .conf when needed.
if [[ $config != */* ]]; then
    config="$config_dir/$(basename -- "$config" .conf).conf"
fi

# Load the configuration file
if [ -f "$config" ]; then
    . "$config"
else
    error "cannot access configuration file: $config"
fi


select_cmd() {
    # Find the command to run
    cmd=${scripts_dir:-.}/$1
    if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then
	error "command '$cmd' is unusable"
    fi
}

run_cmd() {
    # Append the remote hostname option if provided
    if [ "$BACKUP_IS_LOCAL" != "yes" ]; then
	if [ -n "$1" ]; then
	    opts+=( "$1" )
	elif [ -n "$BACKUP_HOST" ]; then
	    opts+=( "$BACKUP_HOST" )
	else
	    error "remote backup hostname not specified"
	fi
    fi

    # Run the command
    $dry_run "$cmd" "${opts[@]}"
    exit $?
}

opts=()
case $action in
    list)
	select_cmd "list_pitr"

	# Parse args after action: they should take precedence over the configuration
	while getopts "Lu:b:l:v?" arg 2>/dev/null; do
	    case $arg in
		L) BACKUP_IS_LOCAL="yes";;
		u) BACKUP_USER=$OPTARG;;
		b) BACKUP_DIR=$OPTARG;;
		l) BACKUP_LABEL=$OPTARG;;
		v) VERBOSE="yes";;
		'?') "$cmd" '-?'; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ]	&& opts+=( "-L" )
	[ -n "$BACKUP_USER" ]		&& opts+=( "-u" "$BACKUP_USER" )
	[ -n "$BACKUP_DIR" ]		&& opts+=( "-b" "$BACKUP_DIR" )
	[ -n "$BACKUP_LABEL" ]		&& opts+=( "-l" "$BACKUP_LABEL" )
	[ "$VERBOSE" = "yes" ]		&& opts+=( "-v" )

	run_cmd "${@:$OPTIND:1}"
	;;

    backup)
	select_cmd "backup_pitr"

	# Parse args after action: they should take precedence over the configuration
	while getopts "Lb:l:u:D:s:P:h:p:U:d:c:e:T?" arg 2>/dev/null; do
	    case $arg in
		L) BACKUP_IS_LOCAL="yes";;
		b) BACKUP_DIR=$OPTARG;;
		l) BACKUP_LABEL=$OPTARG;;
		u) BACKUP_USER=$OPTARG;;
		D) PGDATA=$OPTARG;;
		s) STORAGE=$OPTARG;;
		P) PGPSQL=$OPTARG;;
		h) PGHOST=$OPTARG;;
		p) PGPORT=$OPTARG;;
		U) PGUSER=$OPTARG;;
		d) PGDATABASE=$OPTARG;;
		c) BACKUP_COMPRESS_BIN=$OPTARG;;
		e) BACKUP_COMPRESS_SUFFIX=$OPTARG;;
		T) LOG_TIMESTAMP="yes";;

		'?') "$cmd" '-?'; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ]	    && opts+=( "-L" )
	[ -n "$BACKUP_DIR" ]		    && opts+=( "-b" "$BACKUP_DIR" )
	[ -n "$BACKUP_LABEL" ]		    && opts+=( "-l" "$BACKUP_LABEL" )
	[ -n "$BACKUP_USER" ]		    && opts+=( "-u" "$BACKUP_USER" )
	[ -n "$PGDATA" ]		    && opts+=( "-D" "$PGDATA" )
	[ -n "$STORAGE" ]		    && opts+=( "-s" "$STORAGE" )
	[ -n "$PGPSQL" ]		    && opts+=( "-P" "$PGPSQL" )
	[ -n "$PGHOST" ]		    && opts+=( "-h" "$PGHOST" )
	[ -n "$PGPORT" ]		    && opts+=( "-p" "$PGPORT" )
	[ -n "$PGUSER" ]		    && opts+=( "-U" "$PGUSER" )
	[ -n "$PGDATABASE" ]		    && opts+=( "-d" "$PGDATABASE" )
	[ -n "$BACKUP_COMPRESS_BIN" ]	    && opts+=( "-c" "$BACKUP_COMPRESS_BIN" )
	[ -n "$BACKUP_COMPRESS_SUFFIX" ]    && opts+=( "-e" "$BACKUP_COMPRESS_SUFFIX" )
	[ "$LOG_TIMESTAMP" = "yes" ]	    && opts+=( "-T" )

	# If hooks are defined export them
	[ -n "$PRE_BACKUP_COMMAND" ] && export PRE_BACKUP_COMMAND
	[ -n "$POST_BACKUP_COMMAND" ] && export POST_BACKUP_COMMAND

	run_cmd "${@:$OPTIND:1}"
	;;

    restore)
	select_cmd "restore_pitr"

	# Parse args after action: they should take precedence over the configuration
	while getopts "Lu:b:l:D:x:d:O:t:nRc:e:r:C:T?" arg 2>/dev/null; do
	    case $arg in
		L) BACKUP_IS_LOCAL="yes";;
		u) BACKUP_USER=$OPTARG;;
		b) BACKUP_DIR=$OPTARG;;
		l) BACKUP_LABEL=$OPTARG;;
		D) PGDATA=$OPTARG;;
		x) PGXLOG=$OPTARG;;
		d) TARGET_DATE=$OPTARG;;
		O) PGOWNER=$OPTARG;;
		t) TBLSPC_RELOC+=( "-t" "$OPTARG" );;
		n) DRY_RUN="yes";;
		R) OVERWRITE="yes";;
		c) BACKUP_UNCOMPRESS_BIN=$OPTARG;;
		e) BACKUP_COMPRESS_SUFFIX=$OPTARG;;
		r) RESTORE_COMMAND=$OPTARG;;
		C) RESTORE_XLOG_CONFIG=$OPTARG;;
		T) LOG_TIMESTAMP="yes";;

		"?") "$cmd" '-?'; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ]	    && opts+=( "-L" )
	[ -n "$BACKUP_USER" ]		    && opts+=( "-u" "$BACKUP_USER" )
	[ -n "$BACKUP_DIR" ]		    && opts+=( "-b" "$BACKUP_DIR" )
	[ -n "$BACKUP_LABEL" ]		    && opts+=( "-l" "$BACKUP_LABEL" )
	[ -n "$PGDATA" ]		    && opts+=( "-D" "$PGDATA" )
	[ -n "$PGXLOG" ]		    && opts+=( "-x" "$PGXLOG" )
	[ -n "$TARGET_DATE" ]		    && opts+=( "-d" "$TARGET_DATE" )
	[ -n "$PGOWNER" ]		    && opts+=( "-O" "$PGOWNER" )
	(( ${#TBLSPC_RELOC[@]} > 0 ))	    && opts+=( "${TBLSPC_RELOC[@]}" )
	[ "$DRY_RUN" = "yes" ]		    && opts+=( "-n" )
	[ -n "$OVERWRITE" ]		    && opts+=( "-R" )
	[ -n "$BACKUP_UNCOMPRESS_BIN" ]	    && opts+=( "-c" "$BACKUP_UNCOMPRESS_BIN" )
	[ -n "$BACKUP_COMPRESS_SUFFIX" ]    && opts+=( "-e" "$BACKUP_COMPRESS_SUFFIX" )
	[ -n "$RESTORE_COMMAND" ]	    && opts+=( "-r" "$RESTORE_COMMAND" )
	[ "$LOG_TIMESTAMP" = "yes" ]	    && opts+=( "-T" )

	# Pass along the configuration file
	if [ -n "$RESTORE_XLOG_CONFIG" ]; then
	    opts+=( "-C" "$RESTORE_XLOG_CONFIG" )
	elif [ "$config" != "@SYSCONFDIR@/pitr.conf" ]; then
	    opts+=( "-C" "$config" )
	fi

	run_cmd "${@:$OPTIND:1}"
	;;

    purge)
	select_cmd "purge_pitr"

	# Parse args after action: they should take precedence over the configuration
	while getopts "Ll:b:u:n:U:X:m:d:NT?" arg 2>/dev/null; do
	    case $arg in
		L) BACKUP_IS_LOCAL="yes";;
		l) BACKUP_LABEL=$OPTARG;;
		b) BACKUP_DIR=$OPTARG;;
		u) BACKUP_USER=$OPTARG;;
		n) ARCHIVE_HOST=$OPTARG;;
		U) ARCHIVE_USER=$OPTARG;;
		X) ARCHIVE_DIR=$OPTARG;;
		m) PURGE_KEEP_COUNT=$OPTARG;;
		d) PURGE_OLDER_THAN=$OPTARG;;
		N) DRY_RUN="yes";;
		T) LOG_TIMESTAMP="yes";;

		"?") "$cmd" '-?'; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ]	&& opts+=( "-L" )
	[ -n "$BACKUP_DIR" ]		&& opts+=( "-b" "$BACKUP_DIR" )
	[ -n "$BACKUP_LABEL" ]		&& opts+=( "-l" "$BACKUP_LABEL" )
	[ -n "$BACKUP_USER" ]		&& opts+=( "-u" "$BACKUP_USER" )
	[ -n "$ARCHIVE_HOST" ]		&& opts+=( "-n" "$ARCHIVE_HOST" )
	[ -n "$ARCHIVE_USER" ]		&& opts+=( "-U" "$ARCHIVE_USER" )
	[ -n "$ARCHIVE_DIR" ]		&& opts+=( "-X" "$ARCHIVE_DIR" )
	[ -n "$PURGE_KEEP_COUNT" ]	&& opts+=( "-m" "$PURGE_KEEP_COUNT" )
	[ -n "$PURGE_OLDER_THAN" ]	&& opts+=( "-d" "$PURGE_OLDER_THAN" )
	[ "$DRY_RUN" = "yes" ]		&& opts+=( "-N" )
	[ "$LOG_TIMESTAMP" = "yes" ]	&& opts+=( "-T" )

	run_cmd "${@:$OPTIND:1}"
	;;

    check)
	select_cmd "check_pitr"

	while getopts "C:?" opt; do
	    case $opt in
		C) PITR_CONFIG=$OPTARG;;
		"?") "$cmd" '-?'; exit $?;;
	    esac
	done

	if [ -n "$PITR_CONFIG" ]; then
	    opts+=( "-C" "$PITR_CONFIG" )
	else
	    opts+=( "-C" "$config" )
	fi

        # Run the command
	$dry_run "$cmd" "${opts[@]}"
	exit $?
	;;

    *)
	error "unknown action"
	;;
esac
