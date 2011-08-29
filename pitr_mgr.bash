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

config_dir=@SYSCONFDIR@
config=pitr.conf
scripts_dir=@LIBDIR@

usage() {
    echo "usage: `basename $0` [options] action [args]"
    echo "options:"
    echo "    -c file      Path to the configuration file"
    echo "    -n           Show the command instead of executing it"
    echo "    -h           Print help"
    echo
    echo "actions:"
    echo "    list"
    echo "    backup"
    echo "    restore"
    echo "    purge"
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

while getopts "c:nh" opt; do
    case "$opt" in
	c) config=$OPTARG;;
	n) dry_run="echo";;
	h) usage 1;;
	*) error "error while processing options";;
    esac
done


if [ $# -lt 1 ]; then
    echo "ERROR: missing action" 1>&2
    usage 1
fi

action=${@:$OPTIND:1}
OPTIND=$(( $OPTIND + 1 ))

# check if the config option is a path or in the current directory
# otherwise prepend the configuration deirectory and .conf
echo $config | grep -q '\/' 
if [ $? != 0 ] && [ ! -f $config ]; then
    config="$config_dir/`basename $config .conf`.conf"
fi

# Load the configuration file
if [ -f $config ]; then
    . $config
else
    error "cannot access configuration file: $config"
fi

case $action in
    list)
	# Find the command to run
	cmd=${scripts_dir:-.}/list_pitr
	if [ ! -f $cmd -o ! -x $cmd ]; then
	    error "command \"$cmd\" is unusable"
	fi

	# Parse args after action: they should take precedence over the configuration
	while getopts "Lb:l:?" arg 2>/dev/null; do
	    case "$arg" in
		L) BACKUP_IS_LOCAL="yes";;
		b) BACKUP_DIR=$OPTARG;;
		l) BACKUP_LABEL=$OPTARG;;
		'?') $cmd -?; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ] && opts="-L"
	[ -n "$BACKUP_DIR" ] && opts="$opts -b $BACKUP_DIR"
	[ -n "$BACKUP_LABEL" ] && opts="$opts -l $BACKUP_LABEL"

	# Take care of the destination host
	if [ "$BACKUP_IS_LOCAL" != "yes" ]; then
	    host=${@:$OPTIND:1}
	    if [ -n "$host" ]; then
		opts="$opts $host"
	    elif [ -n "$BACKUP_HOST" ]; then
		opts="$opts $BACKUP_HOST"
	    else
		error "missing target host"
	    fi
	fi

	# Run the command
	$dry_run $cmd $opts
	exit $?
	;;

    backup)
	# Find the command to run
	cmd=${scripts_dir:-.}/backup_pitr
	if [ ! -f $cmd -o ! -x $cmd ]; then
	    error "command \"$cmd\" is unusable"
	fi

	# Parse args after action: they should take precedence over the configuration
	while getopts "Lb:l:D:P:h:p:U:d:?" arg 2>/dev/null; do
	    case "$arg" in
		L) BACKUP_IS_LOCAL="yes";;
		b) BACKUP_DIR=$OPTARG;;
		l) BACKUP_LABEL=$OPTARG;;
		D) PGDATA=$OPTARG;;
		P) PGPSQL=$OPTARG;;
		h) PGHOST=$OPTARG;;
		p) PGPORT=$OPTARG;;
		U) PGUSER=$OPTARG;;
		d) PGDATABASE=$OPTARG;;
		'?') $cmd -?; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ] && opts="-L"
	[ -n "$BACKUP_DIR" ] && opts="$opts -b $BACKUP_DIR"
	[ -n "$BACKUP_LABEL" ] && opts="$opts -l $BACKUP_LABEL"
	[ -n "$PGDATA" ] && opts="$opts -D $PGDATA"
	[ -n "$PGPSQL" ] && opts="$opts -P $PGPSQL"
	[ -n "$PGHOST" ] && opts="$opts -h $PGHOST"
	[ -n "$PGPORT" ] && opts="$opts -p $PGPORT"
	[ -n "$PGUSER" ] && opts="$opts -U $PGUSER"
	[ -n "$PGDATABASE" ] && opts="$opts -d $PGDATABASE"

	# Take care of the destination host
	if [ "$BACKUP_IS_LOCAL" != "yes" ]; then
	    host=${@:$OPTIND:1}
	    if [ -n "$host" ]; then
		opts="$opts $host"
	    elif [ -n "$BACKUP_HOST" ]; then
		opts="$opts $BACKUP_HOST"
	    else
		error "missing target host"
	    fi
	fi

	# Run the command
	$dry_run $cmd $opts
	exit $?
	;;

    restore)
	# Find the command to run
	cmd=${scripts_dir:-.}/restore_pitr
	if [ ! -f $cmd -o ! -x $cmd ]; then
	    error "command \"$cmd\" is unusable"
	fi

	# Parse args after action: they should take precedence over the configuration
	while getopts "Lb:l:D:h:X:d:O:r:?" arg 2>/dev/null; do
	    case "$arg" in
		L) BACKUP_IS_LOCAL="yes";;
		b) BACKUP_DIR=$OPTARG;;
		l) BACKUP_LABEL=$OPTARG;;
		D) PGDATA=$OPTARG;;
		h) ARCHIVE_HOST=$OPTARG;;
		X) ARCHIVE_DIR=$OPTARG;;
		d) TARGET_DATE=$OPTARG;;
		O) PGOWNER=$OPTARG;;
		r) RESTORE_COMMAND=$OPTARG;;
		"?") $cmd -?; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ] && opts="$opts -L"
	[ -n "$BACKUP_DIR" ] && opts="$opts -b $BACKUP_DIR"
	[ -n "$BACKUP_LABEL" ] && opts="$opts -l $BACKUP_LABEL"
	[ -n "$PGDATA" ] && opts="$opts -D $PGDATA"
	[ -n "$ARCHIVE_HOST" ] && opts="$opts -h $ARCHIVE_HOST"
	[ -n "$ARCHIVE_DIR" ] && opts="$opts -X $ARCHIVE_DIR"
	[ -n "$PGOWNER" ] && opts="$opts -O $PGOWNER"
	[ -n "$RESTORE_COMMAND" ] && opts="$opts -r $RESTORE_COMMAND"

	# Take care of the source host
	if [ "$BACKUP_IS_LOCAL" != "yes" ]; then
	    a=${@:$OPTIND:1}
	    if [ -n "$a" ]; then
		host=$a
	    elif [ -n "$BACKUP_HOST" ]; then
		host=$BACKUP_HOST
	    else
		error "missing target host"
	    fi
	fi

	# The target date has spaces in it making this difficult for bash
	# to get the arguments passed properly
	if [ -n "$TARGET_DATE" ]; then
	    $dry_run $cmd $opts -d "$TARGET_DATE" $host
	else
	    $dry_run $cmd $opts $host
	fi
	exit $?
	;;

    purge)
	# Find the command to run
	cmd=${scripts_dir:-.}/purge_pitr
	if [ ! -f $cmd -o ! -x $cmd ]; then
	    error "command \"$cmd\" is unusable"
	fi

	# Parse args after action: they should take precedence over the configuration
	while getopts "Ll:b:n:X:m:d:?" arg 2>/dev/null; do
	    case "$arg" in
		L) BACKUP_IS_LOCAL="yes";;
		l) BACKUP_LABEL=$OPTARG;;
		b) BACKUP_DIR=$OPTARG;;
		n) opts="-n $OPTARG";;
		X) ARCHIVE_DIR=$OPTARG;;
		m) PURGE_KEEP_COUNT=$OPTARG;;
		d) PURGE_OLDER_THAN=$OPTARG;;
		"?") $cmd -?; exit $?;;
	    esac
	done

	# Add relevant options coming from the configuration
	[ "$BACKUP_IS_LOCAL" = "yes" ] && opts="$opts -L"
	[ -n "$BACKUP_DIR" ] && opts="$opts -b $BACKUP_DIR"
	[ -n "$BACKUP_LABEL" ] && opts="$opts -l $BACKUP_LABEL"
	[ -n "$ARCHIVE_DIR" ] && opts="$opts -X $ARCHIVE_DIR"
	[ -n "$PURGE_KEEP_COUNT" ] && opts="$opts -m $PURGE_KEEP_COUNT"
	[ -n "$PURGE_OLDER_THAN" ] && opts="$opts -d $PURGE_OLDER_THAN"

	# Take care of the destination host
	if [ "$BACKUP_IS_LOCAL" != "yes" ]; then
	    host=${@:$OPTIND:1}
	    if [ -n "$host" ]; then
		opts="$opts $host"
	    elif [ -n "$BACKUP_HOST" ]; then
		opts="$opts $BACKUP_HOST"
	    else
		error "missing target host"
	    fi
	fi

	# Run the command
	$dry_run $cmd $opts
	exit $?
	;;

    *)
	error "unknown action"
	;;
esac
