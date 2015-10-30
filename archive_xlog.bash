#!@BASH@
#
# Copyright 2011-2015 Nicolas Thauvin. All rights reserved.
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

# Message functions
now() {
    [ "$LOG_TIMESTAMP" = "yes" ] && echo "$(date "+%F %T %Z ")"
}

error() {
    echo "$(now)ERROR: $*" 1>&2
}

warn() {
    echo "$(now)WARNING: $*" 1>&2
}

# Script help
usage() {
    echo "usage: `basename $0` [options] XLOGFILE"
    echo "options:"
    echo "    -L             do local archiving"
    echo "    -C conf        configuration file"
    echo "    -u username    username for SSH login"
    echo "    -h hostname    hostname for SSH login"
    echo "    -d dir         target directory"
    echo "    -X             do not compress"
    echo "    -O             do not overwrite the destination file"
    echo "    -c command     compression command"
    echo "    -s suffix      compressed file suffix (ex: gz)"
    echo "    -S             send messages to syslog"
    echo "    -f facility    syslog facility"
    echo "    -t ident       syslog ident"
    echo
    echo "    -T             Timestamp log messages"
    echo "    -?             print help"
    echo
    exit $1
}

# Configuration defaults
CONFIG=pitr.conf
CONFIG_DIR=@SYSCONFDIR@
ARCHIVE_DIR=/var/lib/pgsql/archived_xlog
ARCHIVE_LOCAL="no"
SYSLOG="no"
ARCHIVE_COMPRESS="yes"
ARCHIVE_COMPRESS_BIN="gzip -f -4"
ARCHIVE_COMPRESS_SUFFIX="gz"
ARCHIVE_OVERWRITE="yes"

# Command line options
while getopts "LC:u:d:h:XOc:s:Sf:t:?"  opt; do
    case "$opt" in
	L) CLI_ARCHIVE_LOCAL="yes";;
	C) CONFIG=$OPTARG;;
	u) CLI_ARCHIVE_USER=$OPTARG;;
	h) CLI_ARCHIVE_HOST=$OPTARG;;
	d) CLI_ARCHIVE_DIR=$OPTARG;;
	X) CLI_ARCHIVE_COMPRESS="no";;
	O) CLI_ARCHIVE_OVERWRITE="no";;
	c) CLI_ARCHIVE_COMPRESS_BIN="$OPTARG";;
	s) CLI_ARCHIVE_COMPRESS_SUFFIX=$OPTARG;;
	S) CLI_SYSLOG="yes";;
	f) CLI_SYSLOG_FACILITY=$OPTARG;;
	t) CLI_SYSLOG_IDENT=$OPTARG;;
	T) CLI_LOG_TIMESTAMP="yes";;
        "?") usage 1;;
	*) error "Unknown error while processing options"; exit 1;;
    esac
done	

# Check if the config option is a path or just a name in the
# configuration directory.  Prepend the configuration directory and
# .conf when needed.
if [[ $CONFIG != */* ]]; then
    CONFIG="$CONFIG_DIR/$(basename -- "$CONFIG" .conf).conf"
fi

# Load configuration file
if [ -f "$CONFIG" ]; then
    . $CONFIG

    # Check for renamed parameters between versions
    if [ -n "$COMPRESS_BIN" ] && [ -z "$CLI_ARCHIVE_COMPRESS_BIN" ]; then
	ARCHIVE_COMPRESS_BIN=$COMPRESS_BIN
	warn "archive_xlog: COMPRESS_BIN is deprecated. please use ARCHIVE_COMPRESS_BIN."
    fi
    if [ -n "$COMPRESS_SUFFIX" ] && [ -z "$CLI_ARCHIVE_COMPRESS_SUFFIX" ]; then
	ARCHIVE_COMPRESS_SUFFIX=$COMPRESS_SUFFIX
	warn "archive_xlog: COMPRESS_SUFFIX is deprecated. please use ARCHIVE_COMPRESS_SUFFIX."
    fi
fi

# Overwrite configuration with cli options
[ -n "$CLI_ARCHIVE_LOCAL" ] && ARCHIVE_LOCAL=$CLI_ARCHIVE_LOCAL
[ -n "$CLI_ARCHIVE_USER" ] && ARCHIVE_USER=$CLI_ARCHIVE_USER
[ -n "$CLI_ARCHIVE_HOST" ] && ARCHIVE_HOST=$CLI_ARCHIVE_HOST
[ -n "$CLI_ARCHIVE_DIR" ] && ARCHIVE_DIR=$CLI_ARCHIVE_DIR
[ -n "$CLI_ARCHIVE_COMPRESS" ] && ARCHIVE_COMPRESS=$CLI_ARCHIVE_COMPRESS
[ -n "$CLI_ARCHIVE_COMPRESS_BIN" ] && ARCHIVE_COMPRESS_BIN=$CLI_ARCHIVE_COMPRESS_BIN
[ -n "$CLI_ARCHIVE_COMPRESS_SUFFIX" ] && ARCHIVE_COMPRESS_SUFFIX=$CLI_ARCHIVE_COMPRESS_SUFFIX
[ -n "$CLI_ARCHIVE_OVERWRITE" ] && ARCHIVE_OVERWRITE=$CLI_ARCHIVE_OVERWRITE
[ -n "$CLI_SYSLOG" ] && SYSLOG=$CLI_SYSLOG
[ -n "$CLI_SYSLOG_FACILITY" ] && SYSLOG_FACILITY=$CLI_SYSLOG_FACILITY
[ -n "$CLI_SYSLOG_IDENT" ] && SYSLOG_IDENT=$CLI_SYSLOG_IDENT
[ -n "$CLI_LOG_TIMESTAMP" ] && LOG_TIMESTAMP=$CLI_LOG_TIMESTAMP

# Redirect output to syslog if configured
if [ "$SYSLOG" = "yes" ]; then
    SYSLOG_FACILITY=${SYSLOG_FACILITY:-local0}
    SYSLOG_IDENT=${SYSLOG_IDENT:-postgres}

    exec 1> >(logger -t ${SYSLOG_IDENT} -p ${SYSLOG_FACILITY}.info)
    exec 2> >(logger -t ${SYSLOG_IDENT} -p ${SYSLOG_FACILITY}.err)
fi

# The first argument must be a WAL file
xlog=${@:$OPTIND:1}
if [ -z "$xlog" ]; then
    error "missing xlog filename to archive. Please consider modifying archive_command, eg add %p"
    exit 1
fi

# Sanity check. We need at least to know if we want to perform a local
# copy or have a hostname for an SSH copy
if [ $ARCHIVE_LOCAL != "yes" -a -z "$ARCHIVE_HOST" ]; then
    error "Not enough information to archive the segment"
    exit 1
fi

# Check if the source file exists
if [ ! -r "$xlog" ]; then
    error "Input file '$xlog' does not exist or is not readable"
    exit 1
fi

check_local_dest_exists()
{
    [ $ARCHIVE_OVERWRITE = "yes" ] && return 0

    if [ -e "$1" ]; then
	error "$1 already exists, refusing to overwrite it."
	exit 1
    fi
}

check_remote_dest_exists()
{

    [ $ARCHIVE_OVERWRITE = "yes" ] && return 0

    local dest_host=$1
    local dest_file=$2
    local dest_exists

    # We need to check this here, since [ ! -e ] will not do what you might expect
    # and we can't safely single or double quote it for an arbitrary $dest_file.
    # It would be better if we could use [[ ! -e ]] instead, but that would depend
    # on the remote shell also being bash.
    [ -n "$dest_file" ] || error "check_remote_dest_exists: no dest_file passed"

    # Don't assign this in the local declaration, or $? will contain the exit status
    # of the 'local' command, not the ssh command.
    dest_exists=$(ssh -n -- "$dest_host" "[ ! -e $(qw "$dest_file") ] || echo 'oops'")
    local rc=$?
    if [ $rc != 0 ]; then
	error "Failed to check if '$dest_file' exists on $dest_host"
	return $rc
    fi

    if [ -n "$dest_exists" ]; then
	error "'$dest_file' already exists on $dest_host, refusing to overwrite it."
	return 1
    fi

    return 0;
}

# Copy the wal locally
if [ $ARCHIVE_LOCAL = "yes" ]; then
    mkdir -p $ARCHIVE_DIR 1>&2
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to create target directory '$ARCHIVE_DIR'"
	exit $rc
    fi

    if [ "$ARCHIVE_COMPRESS" = "yes" ]; then
	dest_path=$ARCHIVE_DIR/$(basename -- "$xlog").$ARCHIVE_COMPRESS_SUFFIX
	check_local_dest_exists "$dest_path"

	$ARCHIVE_COMPRESS_BIN -c < "$xlog" > "$dest_path"
	rc=$?
	if [ $rc != 0 ]; then
	    error "Compressing $xlog to $dest_path failed"
	    exit $rc
	fi
    else
	dest_path=$ARCHIVE_DIR/$(basename -- "$xlog")
	check_local_dest_exists "$dest_path"

	cp -- "$xlog" "$dest_path" 1>&2
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to copy $xlog to $ARCHIVE_DIR"
	    exit $rc
	fi
    fi
else
    # Compress and copy with rsync
    echo $ARCHIVE_HOST | grep -q ':' && ARCHIVE_HOST="[${ARCHIVE_HOST}]" # Dummy test for IPv6

    dest_host=${ARCHIVE_USER:+$ARCHIVE_USER@}${ARCHIVE_HOST}

    ssh -n -- "$dest_host" "mkdir -p -- $(qw "$ARCHIVE_DIR")"
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to create target directory"
	exit $rc
    fi

    if [ "$ARCHIVE_COMPRESS" = "yes" ]; then
	dest_file=$ARCHIVE_DIR/$(basename -- "$xlog").$ARCHIVE_COMPRESS_SUFFIX
	tmpfile=$(mktemp -t pitr_wal.XXXXXXXXXX)
	rc=$?
	if [ $rc != 0 ]; then
	    error "Failed to create temporary file for compressed WAL"
	    exit $rc
	fi

	# We take no risk, pipe the content to the compression program
	# and save output elsewhere: the compression program never
	# touches the input file
	$ARCHIVE_COMPRESS_BIN -c < "$xlog" > "$tmpfile"
	rc=$?
	if [ $rc != 0 ]; then
	    error "Compressing $xlog to $tmpfile failed"
	    rm -- "$tmpfile"
	    exit $rc
	fi

	# We delay this check until after compression is completed.
	# There is still a race where something else could create it between when
	# we test this and when rsync completes, but this at least keeps it as
	# small as we reasonably can.  There is no option for rsync to request
	# "fail if the destination file already exists".
	check_remote_dest_exists "$dest_host" "$dest_file"
	rc=$?
	if [ $rc != 0 ]; then
	    rm -- "$tmpfile"
	    exit $rc
	fi

	# Using a temporary file is mandatory for rsync. Rsync is the
	# safest way to archive, the file is transfered under a
	# another name then moved to the target name when complete,
	# partly copied files should not happen.
	rsync -a -- "$tmpfile" "$dest_host:$(qw "$dest_file")"
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to rsync the compressed file to ${ARCHIVE_HOST}:${ARCHIVE_DIR}"
	    rm -- "$tmpfile"
	    exit $rc
	fi

	rm -- "$tmpfile"
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to remove temporary compressed file '$tmpfile'"
	    exit $rc
	fi
    else
	dest_file=$ARCHIVE_DIR/$(basename -- "$xlog")
	check_remote_dest_exists "$dest_host" "$dest_file"
	rc=$?
	[ $rc = 0 ] || exit $rc

	rsync -a -- "$xlog" "$dest_host:$(qw "$dest_file")"
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to rsync $xlog to ${ARCHIVE_HOST}:${ARCHIVE_DIR}"
	    exit $rc
	fi
    fi
fi

exit 0
