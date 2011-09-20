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

usage() {
    echo "usage: `basename $0` [options] xlogfile destination"
    echo "options:"
    echo "   -n host       host storing WALs"
    echo "   -u username   username for SSH login"
    echo "   -d dir        directory containaing WALs on host"
    echo "   -C conf       configuration file"
    echo
    echo "   -s            send messages to syslog"
    echo "   -f facility   syslog facility"
    echo "   -t ident      syslog ident"
    echo
    echo "   -h            print help"
    echo
    exit $1
}

error() {
    echo "ERROR: $*" 1>&2
    exit 1
}

is_local() {

    # Check if the input is an IP address otherwise resolve to an IP address
    echo -e "$1\n" | grep -qE '^(([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:+){1,7}[0-9a-fA-F]{0,4})$'
    if [ $? != 0 ]; then
        # use ping to resolve the ip
	ip=`ping -c 1 -w 1 -q $1 2>/dev/null | sed -nE 's/.*\((([0-9]{1,3}\.?){4}).*/\1/p'`
	if [ -z "$ip" ]; then
	    # try ipv6
	    ip=`ping6 -c 1 -w 1 -q -n $1 | sed -nE 's/.*\((([0-9a-fA-F]{0,4}:?){1,8}).*/\1/p'`
	fi
    else
	ip=$1
    fi

    # Check if the IP address is local
    LC_ALL=C /sbin/ifconfig | grep -qE "(addr:${ip}[[:space:]]|inet6 addr: ${ip}/)"
    if [ $? = 0 ]; then
	return 0
    else
	return 1
    fi

}

# Default configuration
CONFIG=@SYSCONFDIR@/archive_xlog.conf
NODE=127.0.0.1
SRCDIR=/var/lib/pgsql/archived_xlog
SYSLOG="no"

# CLI processing
args=`getopt "n:u:d:C:sf:t:h" "$@"`
if [ $? -ne 0 ]; then
    usage 2
fi
set -- $args
for i in $*; do
    case "$i" in
	-n) NODE=$2; shift 2;;
	-u) CLI_SSH_USER=$2; shift 2;;
	-d) SRCDIR=$2; shift 2;;
	-C) CONGIG=$2; shift 2;;
	-s) CLI_SYSLOG="yes"; shift;;
	-f) CLI_SYSLOG_FACILITY=$2; shift 2;;
	-t) CLI_SYSLOG_IDENT=$2; shift 2;;

	-h) usage 1;;
	--) shift; break;;
    esac
done

# Check input: the name of the xlog file (%f) is needed as well has the target path (%p)
# PostgreSQL gives those two when executing restore_command
[ $# != 2 ] && error "missing xlog filename and target path. Please use %f and %p in restore_command"
xlog=$1
target_path=$2

# Load configuration file
if [ -f "$CONFIG" ]; then
    . $CONFIG
fi

# Override configuration with cli options
[ -n "$CLI_SSH_USER" ] && SSH_USER=$CLI_SSH_USER
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

# Get the file: use cp when the file is on localhost, scp otherwise
is_local $NODE
if [ $? = 0 ]; then
    # Local storage
    if [ -f $SRCDIR/${xlog}.gz ]; then
	cp $SRCDIR/${xlog}.gz ${target_path}.gz
	if [ $? != 0 ]; then
	    error "could not copy $SRCDIR/$xlog.gz to $target_path"
	fi
    else
	error "could not find $SRCDIR/$xlog.gz"
    fi
else
    # check if we have a IPv6, and put brackets for scp
    echo $NODE | grep -q ':' && NODE="[${NODE}]"

    scp ${SSH_USER:+$SSH_USER@}${NODE}:$SRCDIR/${xlog}.gz ${target_path}.gz >/dev/null
    if [ $? != 0 ]; then
	error "could not copy ${NODE}:$SRCDIR/$xlog.gz to $target_path"
    fi
fi

# Uncompress the file
gunzip -f ${target_path}.gz
if [ $? != 0 ]; then
    error "could not copy gunzip file"
fi

exit 0
