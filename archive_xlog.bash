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
error() {
    echo "ERROR: $1" 1>&2
}

warn() {
    echo "WARNING: $1" 1>&2
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
    echo "    -c command     compression command"
    echo "    -s suffix      compressed file suffix (ex: gz)"
    echo "    -S             send messages to syslog"
    echo "    -f facility    syslog facility"
    echo "    -t ident       syslog ident"
    echo
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

# Command line options
while getopts "LC:u:d:h:Xc:s:Sf:t:?"  opt; do
    case "$opt" in
	L) CLI_ARCHIVE_LOCAL="yes";;
	C) CONFIG=$OPTARG;;
	u) CLI_ARCHIVE_USER=$OPTARG;;
	h) CLI_ARCHIVE_HOST=$OPTARG;;
	d) CLI_ARCHIVE_DIR=$OPTARG;;
	X) CLI_ARCHIVE_COMPRESS="no";;
	c) CLI_ARCHIVE_COMPRESS_BIN="$OPTARG";;
	s) CLI_ARCHIVE_COMPRESS_SUFFIX=$OPTARG;;
	S) CLI_SYSLOG="yes";;
	f) CLI_SYSLOG_FACILITY=$OPTARG;;
	t) CLI_SYSLOG_IDENT=$OPTARG;;
        "?") usage 1;;
	*) error "Unknown error while processing options"; exit 1;;
    esac
done	

# Check if the config option is a path or just a name in the
# configuration directory.  Prepend the configuration directory and
# .conf when needed.
echo $CONFIG | grep -q '\/'
if [ $? != 0 ]; then
    CONFIG="$CONFIG_DIR/`basename $CONFIG .conf`.conf"
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
[ -n "$CLI_SYSLOG" ] && SYSLOG=$CLI_SYSLOG
[ -n "$CLI_SYSLOG_FACILITY" ] && SYSLOG_FACILITY=$CLI_SYSLOG_FACILITY
[ -n "$CLI_SYSLOG_IDENT" ] && SYSLOG_IDENT=$CLI_SYSLOG_IDENT

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

# Copy the wal locally
if [ $ARCHIVE_LOCAL = "yes" ]; then
    mkdir -p $ARCHIVE_DIR 1>&2
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to create target directory"
	exit $rc
    fi

    cp $xlog $ARCHIVE_DIR 1>&2
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to copy $xlog to $ARCHIVE_DIR"
	exit $rc
    fi

    if [ $ARCHIVE_COMPRESS = "yes" ]; then
	dest_path=$ARCHIVE_DIR/`basename $xlog`
	$ARCHIVE_COMPRESS_BIN $dest_path
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to compress $dest_path"
	    exit $rc
	fi
    fi

else
    # Compress and copy with scp
    echo $ARCHIVE_HOST | grep -q ':' && ARCHIVE_HOST="[${ARCHIVE_HOST}]" # Dummy test for IPv6

    ssh ${ARCHIVE_USER:+$ARCHIVE_USER@}${ARCHIVE_HOST} "mkdir -p $ARCHIVE_DIR"
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to create target directory"
	exit $rc
    fi

    if [ $ARCHIVE_COMPRESS = "yes" ]; then
	file=/tmp/`basename $xlog`.$ARCHIVE_COMPRESS_SUFFIX
	# We take no risk, pipe the content to the compression program
	# and save output elsewhere: the compression program never
	# touches the input file
	$ARCHIVE_COMPRESS_BIN -c < $xlog > $file
	rc=$?
	if [ $rc != 0 ]; then
	    error "Compression to $file failed"
	    exit $rc
	fi

	# Using a temporary file is mandatory for rsync. Rsync is the
	# safest way to archive, the file is transfered under a
	# another name then moved to the target name when complete,
	# partly copied files should not happen.
	rsync -a $file ${ARCHIVE_USER:+$ARCHIVE_USER@}${ARCHIVE_HOST}:${ARCHIVE_DIR:-'~'}/
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to rsync the compressed file to ${ARCHIVE_HOST}:${ARCHIVE_DIR}"
	    exit $rc
	fi

	rm $file
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to remove temporary compressed file"
	    exit $rc
	fi
    else
	rsync -a $xlog ${ARCHIVE_USER:+$ARCHIVE_USER@}${ARCHIVE_HOST}:${ARCHIVE_DIR:-'~'}/
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to rsync $xlog to ${ARCHIVE_HOST}:${ARCHIVE_DIR}"
	    exit $rc
	fi
    fi
fi

exit 0
