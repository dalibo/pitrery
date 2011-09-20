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

# Default configuration
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"

usage() {
    echo "usage: `basename $0` [options] [hostname]"
    echo "options:"
    echo "    -L              List from local storage"
    echo "    -u username     Username for SSH login"
    echo "    -b dir          Backup storage directory"
    echo "    -l label        Label used when backup was performed"
    echo
    echo "    -?              Print help"
    echo
    exit $1
}

error() {
    echo "ERROR: $*" 1>&2
    exit 1
}

# Process CLI Options
while getopts "Lu:b:l:?" opt; do
    case "$opt" in
	L) local_backup="yes";;
	u) ssh_user=$OPTARG;;
	b) backup_root=$OPTARG;;
	l) label_prefix=$OPTARG;;
	"?") usage 1;;
	*) error "error while processing options";;
    esac
done

host=${@:$OPTIND:1}

# Storage host is mandatory unless stored locally
if [ -z "$host" ] && [ $local_backup != "yes" ]; then
    echo "FATAL: missing target host" 1>&2
    usage 1
fi

# Search the store
if [ $local_backup = "yes" ]; then
    list=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/"
    fi

    # Print a header
    echo "List of local backups:"
else
    list=`ssh ${ssh_user:+$ssh_user@}$host "ls -d $backup_root/$label_prefix/[0-9]*" 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/ on $host"
    fi

    # Print a header
    echo "List of backups on $host:"
fi

# Print the directory and start time of each backup
for dir in $list; do
    # Print the details of the backup dir
    echo -en "$dir \t"

    st=0
    # Get the exact start date from the backup label
    if [ $local_backup = "yes" ]; then
	if [ -f $dir/backup_label ]; then
	    grep "START TIME:" $dir/backup_label
	    if [ $? != 0 ]; then
		echo -e "\nERROR: could find the start time" 1>&2
		st=1
	    fi
	else
	    echo -e "\nERROR: could find the backup_label file" 1>&2
	    st=1
	fi
    else
	ssh ${ssh_user:+$ssh_user@}$host "test -f $dir/backup_label" 2>/dev/null
	if [ $? = 0 ]; then
	    ssh ${ssh_user:+$ssh_user@}$host "cat $dir/backup_label" 2>/dev/null | grep "START TIME:"
	    rc=(${PIPESTATUS[*]})
	    ssh_rc=${rc[0]}
	    grep_rc=${rc[1]}
	    if [ $ssh_rc != 0 ] || [ $grep_rc != 0 ]; then
		echo -e "\nERROR: could find the start time in the backup_label file" 1>&2
		st=1
	    fi
	else
	    echo -e "\nERROR: could find the backup_label file" 1>&2
	    st=1
	fi
    fi

    if [ $st != 0 ]; then
	echo "!!! This backup may be imcomplete or corrupted !!!"
    fi

#    echo
done

