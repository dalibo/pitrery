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

# Message functions
error() {
    echo "ERROR: $1" 1>&2
}

# Script help
usage() {
    echo "usage: `basename $0` [options] XLOGFILE"
    echo "options:"
    echo "    -L             allow local archiving"
    echo "    -C conf        configuration file"
    echo "    -u username    username for SSH login"
    echo "    -h hostname    hostname for SSH login"
    echo "    -d dir         target directory"
    echo "    -x prog        compression program"
    echo "    -X             do not compress"
    echo "    -S             send messages to syslog"
    echo "    -f facility    syslog facility"
    echo "    -t ident       syslog ident"
    echo
    echo "    -?             print help"
    echo
    exit $1
}

# Configuration defaults
CONFIG=@SYSCONFDIR@/archive_xlog.conf
DEST=/var/lib/pgsql/archived_xlog
LOCAL="no"
SYSLOG="no"
COMPRESS="yes"
COMPRESS_BIN=gzip

# Command line options
args=`getopt "LC:u:d:h:x:XSf:t:?" "$@"`
if [ $? -ne 0 ]
then
    usage 2
fi

set -- $args
for i in $*
do
    case "$i" in
        -L) CLI_LOCAL="yes"; shift;;
	-C) CONFIG=$2; shift 2;;
	-u) CLI_SSH_USER=$2; shift 2;;
	-h) CLI_SSH_HOST=$2; shift 2;;
	-d) CLI_DEST=$2; shift 2;;
	-x) CLI_COMPRESS_BIN=$2; shift 2;;
	-X) CLI_COMPRESS="no"; shift;;
	-S) CLI_SYSLOG="yes"; shift;;
	-f) CLI_SYSLOG_FACILITY=$2; shift 2;;
	-t) CLI_SYSLOG_IDENT=$2; shift 2;;
        -\?) usage 1;;
        --) shift; break;;
    esac
done

# The first argument must be a WAL file
if [ $# != 1 ]; then
    error "missing xlog filename to archive. Please consider modifying archive_command, eg add %p"
    exit 1
fi

xlog=$1

# Load configuration file
if [ -f "$CONFIG" ]; then
    . $CONFIG
fi

# Override configuration with cli options
[ -n "$CLI_LOCAL" ] && LOCAL=$CLI_LOCAL
[ -n "$CLI_SSH_USER" ] && SSH_USER=$CLI_SSH_USER
[ -n "$CLI_SSH_HOST" ] && SSH_HOST=$CLI_SSH_HOST
[ -n "$CLI_DEST" ] && DEST=$CLI_DEST
[ -n "$CLI_COMPRESS_BIN" ] && COMPRESS_BIN=$CLI_COMPRESS_BIN
[ -n "$CLI_COMPRESS" ] && COMPRESS=$CLI_COMPRESS
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

# Sanity check. We need at least to know if we want to perform a local
# copy or have a hostname for an SSH copy
if [ $LOCAL != "yes" -a -z "$SSH_HOST" ]; then
    error "Not enough information to archive the segment"
    exit 1
fi

# Copy the wal locally
if [ $LOCAL = "yes" ]; then
    cp $xlog $DEST 1>&2
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to copy $xlog to $destdir"
	exit $rc
    fi

    if [ $COMPRESS = "yes" ]; then
	dest_path=$DEST/`basename $xlog`
	$COMPRESS_BIN $dest_path
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to compress $dest_path"
	    exit $rc
	fi
    fi

else
    # compress and copy with scp
    echo $SSH_HOST | grep -q ':' && SSH_HOST="[${SSH_HOST}]"

    if [ $COMPRESS = "yes" ]; then
	$COMPRESS_BIN -c $xlog | ssh ${SSH_USER:+$SSH_USER@}${SSH_HOST} "cat > ${DEST:-'~'}/`basename $xlog`.gz" 2>/dev/null
	rc=(${PIPESTATUS[*]})
	compress_rc=${rc[0]}
	ssh_rc=${rc[1]}
	if [ $compress_rc != 0 ] || [ $ssh_rc != 0 ]; then
	    error "Unable to send compressed $xlog to ${SSH_HOST}:${DEST}"
	    exit 1
	fi
    else
	scp $xlog ${SSH_USER:+$SSH_USER@}${SSH_HOST}:$DEST
	if [ $? != 0 ]; then
	    error "Unable to send $xlog to ${SSH_HOST}:${DEST}"
	    exit 1
	fi
    fi
fi

exit 0
