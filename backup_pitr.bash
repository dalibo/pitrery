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
    echo "`basename $0` performs a PITR base backup"
    echo 
    echo "Usage:"
    echo "    `basename $0` [options] [hostname]"
    echo
    echo "Backup options:"
    echo "    -L              Perform a local backup"
    echo "    -b dir          Backup directory"
    echo "    -l label        Backup label, it will be suffixed with the date and time"
    echo "    -D dir          Path to \$PGDATA"
    echo
    echo "Connection options:"
    echo "    -P PSQL         path to the psql command"
    echo "    -h HOSTNAME     database server host or socket directory"
    echo "    -p PORT         database server port number"
    echo "    -U NAME         connect as specified database user"
    echo "    -d DATABASE     database to use for connection"
    echo
    echo "    -?              Print help"
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

# Hard coded configuration
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
pgdata=/var/lib/pgsql/data

# CLI options
args=`getopt "Lb:l:D:P:h:p:U:d:?" $*`
if [ $? -ne 0 ]
then
    usage 2
fi

set -- $args
for i in $*
do
    case "$i" in
        -L) local_backup="yes"; shift;;
	-b) backup_root=$2; shift 2;;
	-l) label_prefix=$2; shift 2;;
	-D) pgdata=$2; shift 2;;

	-P) psql_command=$2; shift 2;;
	-h) dbhost=$2; shift 2;;
	-p) dbport=$2; shift 2;;
	-U) dbuser=$2; shift 2;;
	-d) dbname=$2; shift 2;;

        -\?) usage 1;;
        --) shift; break;;
    esac
done

target=$1
# Destination host is mandatory unless the backup is local
if [ -z "$target" ] && [ $local_backup != "yes" ]; then
    echo -e "FATAL: missing target host\n" 1>&2
    usage 1
fi

# Get current date and time in a sortable format
current_time=`date +%Y.%m.%d-%H.%M.%S`

# Prepare psql command line
psql_command=${psql_command:-"psql"}
[ -n "$dbhost" ] && psql_command="$psql_command -h $dbhost"
[ -n "$dbport" ] && psql_command="$psql_command -p $dbport"
[ -n "$dbuser" ] && psql_command="$psql_command -U $dbuser"

psql_condb=${dbname:-postgres}

# Functions
stop_backup() {
    # This function is a signal handler, so block signals it handles
    trap '' INT TERM EXIT

    # Tell PostgreSQL the backup is done
    info "stopping the backup process"
    $psql_command -Atc "SELECT pg_stop_backup();" $psql_condb >/dev/null
    if [ $? != 0 ]; then
	error "could not stop backup process"
    fi

    # Reset the signal handler, this function should only be called once
    trap - INT TERM KILL EXIT
}

# Prepare target directoties
backup_dir=$backup_root/${label_prefix}/${current_time}
info "backup directory is $backup_dir"
info "preparing directories"

if [ $local_backup = "yes" ]; then
    mkdir -p $backup_dir
    if [ $? != 0 ]; then
	error "could not create $backup_dir"
    fi
	
    mkdir -p $backup_dir/tblspc
    if [ $? != 0 ]; then
	error "could not create $backup_dir/tblspc"
    fi

else
    ssh $target "mkdir -p $backup_dir"
    if [ $? != 0 ]; then
	error "could not create $backup_dir"
    fi

    ssh $target "mkdir -p $backup_dir/tblspc"
    if [ $? != 0 ]; then
	error "could not create $backup_dir/tblspc"
    fi

fi

# Start the backup
info "starting the backup process"
start_backup_xlog=`$psql_command -Atc "SELECT pg_xlogfile_name(pg_start_backup('${label_prefix}_${current_time}'));" $psql_condb`
if [ $? != 0 ]; then
    error "could not start backup process"
fi

# Add a signal handler to avoid leaving the cluster in backup mode when exiting on error
trap stop_backup INT TERM KILL EXIT

# Tar $PGDATA
info "archiving PGDATA: $pgdata"
was=`pwd`
cd $pgdata
if [ $? != 0 ]; then
    error "could not change current directory to $pgdata"
fi

if [ $local_backup = "yes" ]; then
    tar -cpf - --ignore-failed-read --exclude=pg_xlog --exclude='postmaster.*' * 2>/dev/null | gzip > $backup_dir/pgdata.tar.gz
    rc=(${PIPESTATUS[*]})
    tar_rc=${rc[0]}
    gzip_rc=${rc[1]}
    if [ $tar_rc = 2 ] || [ $gzip_rc != 0 ]; then
	error "could not tar PGDATA"
    fi
else
    tar -cpf - --ignore-failed-read --exclude=pg_xlog --exclude='postmaster.*' * 2>/dev/null | gzip | ssh $target "cat > $backup_dir/pgdata.tar.gz"
    rc=(${PIPESTATUS[*]})
    tar_rc=${rc[0]}
    gzip_rc=${rc[1]}
    ssh_rc=${rc[2]}
    if [ $tar_rc = 2 ] || [ $gzip_rc != 0 ] || [ $ssh_rc != 0 ]; then
	error "could not tar PGDATA"
    fi
fi
cd $was

# Tar the tablespaces.  The list comes from PostgreSQL to be sure to tar only
# defined tablespaces.
info "listing tablespaces"
tblspc_list=`mktemp -t backup_pitr.XXXXXX`
if [ $? != 0 ]; then
    error "could not create temporary file"
fi

$psql_command -Atc "SELECT spcname,spclocation,oid FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global') AND spclocation <> '';" $psql_condb | tr ' ' '_' > $tblspc_list
rc=(${PIPESTATUS[*]})
psql_rc=${rc[0]}
tr_rc=${rc[1]}

if [ $psql_rc != 0 ] || [ $tr_rc != 0 ]; then
    error "could not get the list of tablespaces from PostgreSQL"
fi

for line in `cat $tblspc_list`; do

    name=`echo $line | cut -d '|' -f 1`
    location=`echo $line | cut -d '|' -f 2`

    info "archiving tablespace \"$name\" ($location)"

    # Change directory to the parent directory or the tablespace to be
    # able to tar only the base directory
    was=`pwd`
    cd $location
    if [ $? != 0 ]; then
	error "could not change current directory to $location"
    fi

    # Tar the directory, directly to the remote location if needed.  The name
    # of the tar file is the tablespace name defined in the cluster, which is
    # unique.
    if [ $local_backup = "yes" ]; then
	tar -cpf - --ignore-failed-read * 2>/dev/null | gzip > $backup_dir/tblspc/${name}.tar.gz
	rc=(${PIPESTATUS[*]})
	tar_rc=${rc[0]}
	gzip_rc=${rc[1]}
	if [ $tar_rc = 2 ] || [ $gzip_rc != 0 ]; then
	    error "could not tar tablespace $name"
	fi
    else
	tar -cpf - --ignore-failed-read * 2>/dev/null | gzip | ssh $target "cat > $backup_dir/tblspc/${name}.tar.gz"
	rc=(${PIPESTATUS[*]})
	tar_rc=${rc[0]}
	gzip_rc=${rc[1]}
	ssh_rc=${rc[2]}
	if [ $tar_rc = 2 ] || [ $gzip_rc != 0 ] || [ $ssh_rc != 0 ]; then
	    error "could not tar tablespace $name"
	fi
    fi

    cd $was
done	

# Stop backup
stop_backup

if [ $local_backup = "yes" ]; then
    # Copy the backup history file
    info "copying the backup history file"
    cp $pgdata/pg_xlog/${start_backup_xlog}.*.backup $backup_dir/backup_label
    if [ $? != 0 ]; then
	error "could not copy backup history file to $backup_dir"
    fi

    # Add the name and location of the tablespace to an helper file for
    # the restoration script
    info "copying the tablespaces list"
    cp $tblspc_list $backup_dir/tblspc_list
    if [ $? != 0 ]; then
	error "could not copy the tablespace list to $backup_dir"
    fi
else
    echo $target | grep -q ':' && target="[${target}]"
    # Copy the backup history file
    info "copying the backup history file"
    scp $pgdata/pg_xlog/${start_backup_xlog}.*.backup ${target}:$backup_dir/backup_label > /dev/null
    if [ $? != 0 ]; then
	error "could not copy backup history file to ${target}:$backup_dir"
    fi

    # Add the name and location of the tablespace to an helper file for
    # the restoration script
    info "copying the tablespaces list"
    scp $tblspc_list ${target}:$backup_dir/tblspc_list >/dev/null
    if [ $? != 0 ]; then
	error "could not copy the tablespace list to ${target}:$backup_dir"
    fi
fi

# Cleanup
rm $tblspc_list

info "done"
