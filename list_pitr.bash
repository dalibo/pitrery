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
    echo "    -v              Display details of the backup"
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
while getopts "Lu:b:l:v?" opt; do
    case "$opt" in
	L) local_backup="yes";;
	u) ssh_user=$OPTARG;;
	b) backup_root=$OPTARG;;
	l) label_prefix=$OPTARG;;
	v) verbose="yes";;
	"?") usage 1;;
	*) error "error while processing options";;
    esac
done

host=${@:$OPTIND:1}

# Storage host is mandatory unless stored locally
if [ -z "$host" ] && [ $local_backup != "yes" ]; then
    echo "ERROR: missing target host" 1>&2
    usage 1
fi

# Search the store
if [ $local_backup = "yes" ]; then
    list=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/"
    fi

    # Print a header
    echo "List of local backups"
else
    list=`ssh ${ssh_user:+$ssh_user@}$host "ls -d $backup_root/$label_prefix/[0-9]*" 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/ on $host"
    fi

    # Print a header
    echo "List of backups on $host"
fi

# Print the directory and stop time of each backup
for dir in $list; do
    # Print the details of the backup dir
    if [ -n "$verbose" ]; then
	echo "----------------------------------------------------------------------"
	echo -e "Directory:\n  $dir"
    else
	echo -ne "$dir\t"
    fi

    st=0
    # Get the exact stop date from the backup label
    if [ $local_backup = "yes" ]; then
	# Compute the size of full backup
	backup_size=`du -sh $dir | awk '{ print $1 }'`
	if [ -n "$verbose" ]; then
	    echo "  space used: $backup_size"
	else
	    echo -ne "$backup_size\t"
	fi

	# Print the minimum recovery target time with this backup
	if [ -f $dir/backup_label ]; then
	    [ -n "$verbose" ] && echo "Minimum recovery target time:"
	    grep "STOP TIME:" $dir/backup_label | sed -e 's/STOP TIME: /  /'
	    if [ $? != 0 ]; then
		echo "ERROR: could not find the \"stop time\" in the backup_label file" 1>&2
		st=1
	    fi
	else
	    echo "ERROR: could not find the backup_label file" 1>&2
	    st=1
	fi

	if [ -n "$verbose" ]; then
	    # Display name, path and sizes of PGDATA and tablespaces
	    if [ -f $dir/tblspc_list ]; then
		# Only show sizes of PGDATA if available
		if [ -n "`awk -F'|' '{ print $4 }' $dir/tblspc_list`" ]; then
		    echo "PGDATA:"
		    awk -F'|' '$2 == "" { print "  "$1" "$4 }' $dir/tblspc_list
		    if [ $? != 0 ]; then
			echo "ERROR: could not display the list of tablespaces" 1>&2
			st=1
		    fi
		fi
		echo "Tablespaces:"
		awk -F'|' '$2 != "" { print "  \""$1"\" "$2" ("$3") "$4 }' $dir/tblspc_list
		if [ $? != 0 ]; then
		    echo "ERROR: could not display the list of tablespaces" 1>&2
		    st=1
		fi
		echo
	    else
		echo "ERROR: could not find the list of tablespaces (tblspc_list)" 1>&2
		st=1
	    fi
	fi
    else
	# Backup size
	backup_size=`ssh ${ssh_user:+$ssh_user@}$host "du -sh $dir" 2>/dev/null | awk '{ print \$1 }'`
	if [ $? = 0 ]; then
	    if [ -n "$verbose" ]; then
		echo "  space used: $backup_size"
	    else
		echo -ne "$backup_size\t"
	    fi
	else
	    echo "ERROR: could not find size of $backup_dir" 1>&2
	    st=1
	fi

	# Minimum recovery target time
	ssh ${ssh_user:+$ssh_user@}$host "test -f $dir/backup_label" 2>/dev/null
	if [ $? = 0 ]; then
	    [ -n "$verbose" ] && echo "Minimum recovery target time:"
	    ssh ${ssh_user:+$ssh_user@}$host "cat $dir/backup_label" 2>/dev/null | grep "STOP TIME:" | sed -e 's/STOP TIME: /  /'
	    rc=(${PIPESTATUS[*]})
	    ssh_rc=${rc[0]}
	    grep_rc=${rc[1]}
	    if [ $ssh_rc != 0 ] || [ $grep_rc != 0 ]; then
		echo "ERROR: could find the \"stop time\" in the backup_label file" 1>&2
		st=1
	    fi
	else
	    echo "ERROR: could find the backup_label file" 1>&2
	    st=1
	fi

	# Name, path and space used at backup time of PGDATA and tablespaces
	if [ -n "$verbose" ]; then
	    ssh ${ssh_user:+$ssh_user@}$host "test -f $dir/tblspc_list" 2>/dev/null
	    if [ $? = 0 ]; then
		if [ -n "`ssh ${ssh_user:+$ssh_user@}$host "cat $dir/tblspc_list" 2>/dev/null | awk -F'|' '{ print $4 }'`" ]; then
		    echo "PGDATA:"
		    ssh ${ssh_user:+$ssh_user@}$host "cat $dir/tblspc_list" 2>/dev/null | awk -F'|' '$2 == "" { print "  "$1" "$4 }'
		    rc=(${PIPESTATUS[*]})
		    ssh_rc=${rc[0]}
		    if [ $ssh_rc != 0 ]; then
			echo "ERROR: could not display the list of tablespaces" 1>&2
			st=1
		    fi
		fi

		echo "Tablespaces:"
		ssh ${ssh_user:+$ssh_user@}$host "cat $dir/tblspc_list" 2>/dev/null | awk -F'|' '$2 != "" { print "  \""$1"\" "$2" ("$3") "$4 }'
		rc=(${PIPESTATUS[*]})
		ssh_rc=${rc[0]}
		if [ $ssh_rc != 0 ]; then
		    echo "ERROR: could not display the list of tablespaces" 1>&2
		    st=1
		fi
		echo
	    else
		echo "ERROR: could not find the list of tablespaces (tblspc_list)" 1>&2
		st=1
	    fi
	fi
    fi

    if [ $st != 0 ]; then
	echo "!!! This backup may be imcomplete or corrupted !!!"
    fi
done

