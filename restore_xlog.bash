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

# Message functions
error() {
    echo "ERROR: $*" 1>&2
    exit 1
}

# Script help
usage() {
    echo "usage: `basename $0` [options] xlogfile destination"
    echo "options:"
    echo "    -L             restore local archives"
    echo "    -C conf        configuration file"
    echo "    -u username    username for SSH login"
    echo "    -h hostname    hostname for SSH login"
    echo "    -d dir         directory containaing WALs on host"
    echo "    -X             do not uncompress"
    echo "    -S             send messages to syslog"
    echo "    -f facility    syslog facility"
    echo "    -t ident       syslog ident"
    echo
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

# Internal configuration
UNCOMPRESS_BIN=gunzip
COMPRESS_SUFFIX=gz

# CLI processing
args=`getopt "LC:u:h:d:XSf:t:?" "$@"`
if [ $? -ne 0 ]; then
    usage 2
fi
set -- $args
for i in $*; do
    case "$i" in
	-L) CLI_ARCHIVE_LOCAL="yes"; shift;;
	-C) CONGIG=$2; shift 2;;
	-u) CLI_SSH_USER=$2; shift 2;;
	-h) CLI_SSH_HOST=$2; shift 2;;
	-d) CLI_ARCHIVE_DIR=$2; shift 2;;
	-X) CLI_ARCHIVE_COMPRESS="no"; shift;;
	-S) CLI_SYSLOG="yes"; shift;;
	-f) CLI_SYSLOG_FACILITY=$2; shift 2;;
	-t) CLI_SYSLOG_IDENT=$2; shift 2;;
	-\?) usage 1;;
	--) shift; break;;
    esac
done

# check if the config option is a path or in the current directory
# otherwise prepend the configuration directory and .conf
echo $CONFIG | grep -q '\/'
if [ $? != 0 ] && [ ! -f $CONFIG ]; then
    CONFIG="$CONFIG_DIR/`basename $CONFIG .conf`.conf"
fi

# Load configuration file
if [ -f "$CONFIG" ]; then
    . $CONFIG
fi

# Override configuration with cli options
if [ -n "$CLI_SSH_HOST" ]; then
    SSH_HOST=$CLI_SSH_HOST
    [ -n "$CLI_SSH_USER" ] && SSH_USER=$CLI_SSH_USER
    # When a host storing the archives is given for local to no, as it
    # can come from the configuration file
    ARCHIVE_LOCAL="no"
fi
[ -n "$CLI_ARCHIVE_LOCAL" ] && ARCHIVE_LOCAL=$CLI_ARCHIVE_LOCAL
[ -n "$CLI_ARCHIVE_DIR" ] && ARCHIVE_DIR=$CLI_ARCHIVE_DIR
[ -n "$CLI_ARCHIVE_COMPRESS" ] && ARCHIVE_COMPRESS=$CLI_ARCHIVE_COMPRESS
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

# Check input: the name of the xlog file (%f) is needed as well has the target path (%p)
# PostgreSQL gives those two when executing restore_command
[ $# != 2 ] && error "missing xlog filename and target path. Please use %f and %p in restore_command"
xlog=$1
target_path=$2

# Check if we have enough information on where to get the file
if [ $ARCHIVE_LOCAL != "yes" -a -z "$SSH_HOST" ]; then
    error "Could not find where to get the file from (local or ssh?)"
fi

# the filename to retrieve depends on compression
if [ $ARCHIVE_COMPRESS = "yes" ]; then
    xlog_file=${xlog}.$COMPRESS_SUFFIX
    target_file=${target_path}.$COMPRESS_SUFFIX
else
    xlog_file=$xlog
    target_file=$target_path
fi

# Get the file: use cp when the file is on localhost, scp otherwise
if [ $ARCHIVE_LOCAL = "yes" ]; then
    if [ -f $ARCHIVE_DIR/$xlog_file ]; then
	cp $ARCHIVE_DIR/$xlog_file $target_file
	if [ $? != 0 ]; then
	    error "could not copy $ARCHIVE_DIR/$xlog_file to $target_file"
	fi
    else
	error "could not find $ARCHIVE_DIR/$xlog_file"
    fi
else
    # check if we have a IPv6, and put brackets for scp
    echo $SSH_HOST | grep -q ':' && SSH_HOST="[${SSH_HOST}]"

    scp ${SSH_USER:+$SSH_USER@}${SSH_HOST}:$ARCHIVE_DIR/$xlog_file $target_file >/dev/null
    if [ $? != 0 ]; then
	error "could not copy ${SSH_HOST}:$ARCHIVE_DIR/$xlog_file to $target_file"
    fi
fi

# Uncompress the file if needed
if [ $ARCHIVE_COMPRESS = "yes" ]; then
    $UNCOMPRESS_BIN $target_file
    if [ $? != 0 ]; then
	error "could not uncompress $target_file"
    fi
fi

exit 0
