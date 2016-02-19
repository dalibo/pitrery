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
    exit 1
}

warn() {
    echo "$(now)WARNING: $*" 1>&2
}

# Script help
usage() {
    echo "usage: `basename $0` [options] xlogfile destination"
    echo "options:"
    echo "    -L             restore local archives"
    echo "    -C conf        configuration file"
    echo "    -u username    username for SSH login"
    echo "    -h hostname    hostname for SSH login"
    echo "    -d dir         directory containing WALs on host"
    echo "    -X             do not uncompress"
    echo "    -c command     uncompression command"
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

# Default configuration
CONFIG=pitr.conf
CONFIG_DIR=@SYSCONFDIR@
ARCHIVE_DIR=/var/lib/pgsql/archived_xlog
ARCHIVE_LOCAL="no"
SYSLOG="no"
ARCHIVE_COMPRESS="yes"
ARCHIVE_UNCOMPRESS_BIN=gunzip
ARCHIVE_COMPRESS_SUFFIX=gz

# CLI processing
while getopts "LC:u:h:d:Xc:s:Sf:t:?" opt; do
    case $opt in
	L) CLI_ARCHIVE_LOCAL="yes";;
	C) CONFIG=$OPTARG;;
	u) CLI_ARCHIVE_USER=$OPTARG;;
	h) CLI_ARCHIVE_HOST=$OPTARG;;
	d) CLI_ARCHIVE_DIR=$OPTARG;;
	X) CLI_ARCHIVE_COMPRESS="no";;
	c) CLI_ARCHIVE_UNCOMPRESS_BIN=$OPTARG;;
	s) CLI_ARCHIVE_COMPRESS_SUFFIX=$OPTARG;;
	S) CLI_SYSLOG="yes";;
	f) CLI_SYSLOG_FACILITY=$OPTARG;;
	t) CLI_SYSLOG_IDENT=$OPTARG;;
	T) CLI_LOG_TIMESTAMP="yes";;
	"?") usage 1;;
	*) error "Unknown error while processing options";;
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
    . "$CONFIG"

    # Check for renamed parameters between versions
    if [ -n "$UNCOMPRESS_BIN" ] && [ -z "$CLI_ARCHIVE_UNCOMPRESS_BIN" ]; then
	ARCHIVE_UNCOMPRESS_BIN=$UNCOMPRESS_BIN
	warn "restore_xlog: UNCOMPRESS_BIN is deprecated. please use ARCHIVE_UNCOMPRESS_BIN."
    fi
    if [ -n "$COMPRESS_SUFFIX" ] && [ -z "$CLI_ARCHIVE_COMPRESS_SUFFIX" ]; then
	ARCHIVE_COMPRESS_SUFFIX=$COMPRESS_SUFFIX
	warn "restore_xlog: COMPRESS_SUFFIX is deprecated. please use ARCHIVE_COMPRESS_SUFFIX."
    fi
fi

# Override configuration with cli options
if [ -n "$CLI_ARCHIVE_HOST" ]; then
    ARCHIVE_HOST=$CLI_ARCHIVE_HOST
    [ -n "$CLI_ARCHIVE_USER" ] && ARCHIVE_USER=$CLI_ARCHIVE_USER
    # When a host storing the archives is given for local to no, as it
    # can come from the configuration file
    ARCHIVE_LOCAL="no"
fi
[ -n "$CLI_ARCHIVE_LOCAL" ] && ARCHIVE_LOCAL=$CLI_ARCHIVE_LOCAL
[ -n "$CLI_ARCHIVE_DIR" ] && ARCHIVE_DIR=$CLI_ARCHIVE_DIR
[ -n "$CLI_ARCHIVE_COMPRESS" ] && ARCHIVE_COMPRESS=$CLI_ARCHIVE_COMPRESS
[ -n "$CLI_ARCHIVE_UNCOMPRESS_BIN" ] && ARCHIVE_UNCOMPRESS_BIN=$CLI_ARCHIVE_UNCOMPRESS_BIN
[ -n "$CLI_ARCHIVE_COMPRESS_SUFFIX" ] && ARCHIVE_COMPRESS_SUFFIX=$CLI_ARCHIVE_COMPRESS_SUFFIX
[ -n "$CLI_SYSLOG" ] && SYSLOG=$CLI_SYSLOG
[ -n "$CLI_SYSLOG_FACILITY" ] && SYSLOG_FACILITY=$CLI_SYSLOG_FACILITY
[ -n "$CLI_SYSLOG_IDENT" ] && SYSLOG_IDENT=$CLI_SYSLOG_IDENT
[ -n "$CLI_LOG_TIMESTAMP" ] && LOG_TIMESTAMP=$CLI_LOG_TIMESTAMP

# Redirect output to syslog if configured
if [ "$SYSLOG" = "yes" ]; then
    SYSLOG_FACILITY=${SYSLOG_FACILITY:-local0}
    SYSLOG_IDENT=${SYSLOG_IDENT:-postgres}

    exec 1> >(logger -t "$SYSLOG_IDENT" -p "${SYSLOG_FACILITY}.info")
    exec 2> >(logger -t "$SYSLOG_IDENT" -p "${SYSLOG_FACILITY}.err")
fi

# Check input: the name of the xlog file (%f) is needed as well has the target path (%p)
# PostgreSQL gives those two when executing restore_command
xlog=${@:$OPTIND:1}
target_path=${@:$(($OPTIND+1)):1}

if [ -z "$xlog" ] || [ -z "$target_path" ]; then
    error "missing xlog filename and/or target path. Please use %f and %p in restore_command"
fi

# Check if we have enough information on where to get the file
if [ "$ARCHIVE_LOCAL" != "yes" ] && [ -z "$ARCHIVE_HOST" ]; then
    error "Could not find where to get the file from (local or ssh?)"
fi

if [ "$ARCHIVE_LOCAL" = "yes" ] && [ -n "$ARCHIVE_HOST" ]; then
    error "ARCHIVE_LOCAL and ARCHIVE_HOST are set, it can't be both"
fi

# the filename to retrieve depends on compression
if [ "$ARCHIVE_COMPRESS" = "yes" ]; then
    xlog_file=${xlog}.$ARCHIVE_COMPRESS_SUFFIX
    target_file=${target_path}.$ARCHIVE_COMPRESS_SUFFIX
else
    xlog_file=$xlog
    target_file=$target_path
fi

# Get the file: use cp when the file is on localhost, scp otherwise
if [ "$ARCHIVE_LOCAL" = "yes" ]; then
    if [ -f "$ARCHIVE_DIR/$xlog_file" ]; then
	if ! cp -- "$ARCHIVE_DIR/$xlog_file" "$target_file"; then
	    error "could not copy $ARCHIVE_DIR/$xlog_file to $target_file"
	fi
    else
	error "could not find $ARCHIVE_DIR/$xlog_file"
    fi
else
    # check if we have a IPv6, and put brackets for scp
    [[ $ARCHIVE_HOST == *([^][]):*([^][]) ]] && ARCHIVE_HOST="[${ARCHIVE_HOST}]"

    if ! scp -- "${ARCHIVE_USER:+$ARCHIVE_USER@}$ARCHIVE_HOST:$(qw "$ARCHIVE_DIR/$xlog_file")" "$target_file" >/dev/null; then
	error "could not copy $ARCHIVE_HOST:$ARCHIVE_DIR/$xlog_file to $target_file"
    fi
fi

# Uncompress the file if needed
if [ "$ARCHIVE_COMPRESS" = "yes" ]; then
    if ! $ARCHIVE_UNCOMPRESS_BIN "$target_file"; then
	error "could not uncompress $target_file"
    fi
fi

exit 0
