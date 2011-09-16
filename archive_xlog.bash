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
msg_error() {
    echo "ERROR: $1" 1>&2
}

# Script help
usage() {
    echo "usage: `basename $0` [options] XLOGFILE"
    echo "options:"
    echo "    -L          allow local archiving"
    echo "    -C conf     configuration file"
    echo "    -n file     node list"
    echo "    -d dir      target directory"
    echo
    echo "    -h          print help"
    echo
    exit $1
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

# Configuration defaults
CONFIG=@SYSCONFDIR@/archive_xlog.conf
NODE_LIST=@SYSCONFDIR@/archive_nodes.conf
DEST=/var/lib/pgsql/archived_xlog
ALLOW_LOCAL="no"
SYSLOG="no"

# Command line options
args=`getopt "LC:l:n:d:h" $*`
if [ $? -ne 0 ]
then
    usage 2
fi

set -- $args
for i in $*
do
    case "$i" in
        -L) CLI_ALLOW_LOCAL="yes"; shift;;
	-C) CONFIG=$2; shift 2;;
	-n) CLI_NODE_LIST=$2; shift 2;;
	-d) CLI_DEST=$2; shift 2;;

        -h) usage 1;;
        --) shift; break;;
    esac
done

# The first argument must be a WAL file
if [ $# != 1 ]; then
    msg_error "missing xlog filename to archive. Please consider modifying archive_command, eg add %p"
    exit 1
fi

xlog=$1

# Load configuration file
if [ -f "$CONFIG" ]; then
    . $CONFIG
fi

# Override configuration with cli options
[ -n "$CLI_ALLOW_LOCAL" ] && ALLOW_LOCAL=$CLI_ALLOW_LOCAL
[ -n "$CLI_NODE_LIST" ] && NODE_LIST=$CLI_NODE_LIST
[ -n "$CLI_DEST" ] && DEST=$CLI_DEST

# Redirect output to syslog if configured
if [ "$SYSLOG" = "yes" ]; then
    SYSLOG_FACILITY=${SYSLOG_FACILITY:-local0}
    SYSLOG_IDENT=${SYSLOG_IDENT:-postgres}

    exec 1> >(logger -t ${SYSLOG_IDENT} -p ${SYSLOG_FACILITY}.info)
    exec 2> >(logger -t ${SYSLOG_IDENT} -p ${SYSLOG_FACILITY}.err)
fi

# Do a basic check on the contents of the configuration file
if [ ! -f "$NODE_LIST" ]; then
    msg_error "target node list does not exists. aborting"
    exit 1
fi

# Initialize counters
error_count=0

# Send the WAL file to each node from the list
for line in `cat $NODE_LIST | grep -vE "^(#|	| |$)" | sed -re 's/[[:space:]]+#.*$//' | sed -re 's/[[:space:]]+/,/g'`; do
    # Split the line on : which can be followed by an optional target path
    node=`echo $line | awk -F, '{ print $1 }' | sed -re 's/(\[|\])//g'`
    destdir=`echo $line | awk -F, '{ print $2 }'`
    mode=`echo $line | awk -F, '{ print $3 }'`

    if [ -z "$destdir" ] || [ "$destdir" = "-" ]; then
	# the destination path was not given, fallback to default
	destdir=$DEST
    fi

    if [ -z "$mode" ] || [ "$mode" = "-" ]; then
	# the mode was not given, fallback to default
	mode="standby"
    fi

    # Check if the target node is the local machine
    # and use cp if local archiving is allowed
    local_copy="no"
    is_local $node && local_copy="yes"

    # check if we have a IPv6, and put brackets for scp
    echo $node | grep -q ':' && node="[${node}]"


    case $mode in
	standby)
	    if [ "$local_copy" = "yes" ]; then
		if [ "$ALLOW_LOCAL" = "yes" -a -n "$destdir" ]; then
		    [ -d $destdir ] || mkdir -p $destdir 1>&2
		    if [ $? != 0 ]; then
			msg_error "Unable to create $destdir"
			error_count=$(($error_count + 1))
		    else
			cp $xlog $destdir 1>&2
			if [ $? != 0 ]; then
			    msg_error "Unable to copy $xlog to $destdir"
			    error_count=$(($error_count + 1))
			fi
		    fi
		else
		    # do not update error count or node count
		    # when local archiving is not allowed
		    continue 
		fi
	    else
                # copy with ssh
		scp $xlog ${node}:${destdir} >/dev/null
		if [ $? != 0 ]; then
		    msg_error "Unable to copy $xlog to ${node}:${destdir}"
		    error_count=$(($error_count + 1))
		fi
	    fi
	    ;;
	pitr)
	    if [ "$local_copy" = "yes" ]; then
		# archiving for backup purposes bypasses ALLOW_LOCAL
		if [ -n "$destdir" ]; then
		    [ -d $destdir ] || mkdir -p $destdir 1>&2
		    if [ $? != 0 ]; then
			msg_error "Unable to create $destdir"
			error_count=$(($error_count + 1))
		    else
			# Copy the file then gzip it
			cp $xlog $destdir 1>&2
			if [ $? != 0 ]; then
			    msg_error "Unable to copy $xlog to $destdir"
			    error_count=$(($error_count + 1))
			else
			    gzip -f $destdir/`basename $xlog`
			    if [ $? != 0 ]; then
				msg_error "Unable to compress $destdir/`basename $xlog`"

				# count as an error. The file has been properly copied but the
				# restore_xlog script does not (yet) known about uncompress files
				error_count=$(($error_count + 1))
			    fi
			fi
		    fi
		fi
	    else
		gzip -c $xlog | ssh ${node} "cat > ${destdir:-'~'}/`basename $xlog`.gz"
		rc=(${PIPESTATUS[*]})
		gzip_rc=${rc[0]}
		ssh_rc=${rc[1]}
		if [ $gzip_rc != 0 ] || [ $ssh_rc != 0 ]; then
		    msg_error "Unable to send compressed $xlog to ${node}:${destdir}"
		    error_count=$(($error_count + 1))
		fi
	    fi
	    ;;
    esac
done

# Compute return code If the xlog file could be sent to one node at
# least, then the archive command is considered as failed.  This
# allows to keep WAL files on the master until the slave is back, and
# avoid "holes" in the WAL files chains when a slave temporarily
# unavailable.
if [ $error_count -ge 1 ]; then
    exit 1
else
    exit 0
fi
