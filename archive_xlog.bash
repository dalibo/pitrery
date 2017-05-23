#!@BASH@
#
# Copyright 2011-2017 Nicolas Thauvin. All rights reserved.
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
    echo "$(now)ERROR: $1" 1>&2
    [ -n "$tmpfile" ] && rm -f -- "$tmpfile"
    exit ${2:-1}
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
    echo "    -H             check the hash of the destination file (remote only)"
    echo "    -F             flush the destination file to disk"
    echo "    -c command     compression command"
    echo "    -s suffix      compressed file suffix (ex: gz)"
    echo "    -S             send messages to syslog"
    echo "    -f facility    syslog facility"
    echo "    -t ident       syslog ident"
    echo "    -m mode        destination file permission mode in octal (e.g. chmod)"
    echo
    echo "    -T             Timestamp log messages"
    echo "    -?             print help"
    echo
    exit $1
}

check_md5() {
    [ "$ARCHIVE_CHECK" != "yes" ] && return 0

    local ARCHIVE_MD5=$1

    LOCAL_MD5=$(md5sum "$xlog")

    if [ "${LOCAL_MD5%% *}" != "${ARCHIVE_MD5%% *}" ]; then
        error "md5 mismatch between local and remote file" 4
    fi

    return 0
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
ARCHIVE_CHECK="no"
ARCHIVE_FLUSH="no"
ARCHIVE_FILE_CHMOD=""

# Command line options
while getopts "LC:u:d:h:XOHFc:s:Sf:t:m:T?"  opt; do
    case $opt in
        L) CLI_ARCHIVE_LOCAL="yes";;
        C) CONFIG=$OPTARG;;
        u) CLI_ARCHIVE_USER=$OPTARG;;
        h) CLI_ARCHIVE_HOST=$OPTARG;;
        d) CLI_ARCHIVE_DIR=$OPTARG;;
        X) CLI_ARCHIVE_COMPRESS="no";;
        O) CLI_ARCHIVE_OVERWRITE="no";;
        H) CLI_ARCHIVE_CHECK="yes";;
        F) CLI_ARCHIVE_FLUSH="yes";;
        c) CLI_ARCHIVE_COMPRESS_BIN=$OPTARG;;
        s) CLI_ARCHIVE_COMPRESS_SUFFIX=$OPTARG;;
        S) CLI_SYSLOG="yes";;
        f) CLI_SYSLOG_FACILITY=$OPTARG;;
        t) CLI_SYSLOG_IDENT=$OPTARG;;
        m) CLI_ARCHIVE_FILE_CHMOD=$OPTARG;;
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
[ -n "$CLI_ARCHIVE_CHECK" ] && ARCHIVE_CHECK=$CLI_ARCHIVE_CHECK
[ -n "$CLI_ARCHIVE_FLUSH" ] && ARCHIVE_FLUSH=$CLI_ARCHIVE_FLUSH
[ -n "$CLI_SYSLOG" ] && SYSLOG=$CLI_SYSLOG
[ -n "$CLI_SYSLOG_FACILITY" ] && SYSLOG_FACILITY=$CLI_SYSLOG_FACILITY
[ -n "$CLI_SYSLOG_IDENT" ] && SYSLOG_IDENT=$CLI_SYSLOG_IDENT
[ -n "$CLI_ARCHIVE_FILE_CHMOD" ] && ARCHIVE_FILE_CHMOD=$CLI_ARCHIVE_FILE_CHMOD
[ -n "$CLI_LOG_TIMESTAMP" ] && LOG_TIMESTAMP=$CLI_LOG_TIMESTAMP

# Redirect output to syslog if configured
if [ "$SYSLOG" = "yes" ]; then
    SYSLOG_FACILITY=${SYSLOG_FACILITY:-local0}
    SYSLOG_IDENT=${SYSLOG_IDENT:-postgres}

    exec 1> >(logger -t "$SYSLOG_IDENT" -p "${SYSLOG_FACILITY}.info")
    exec 2> >(logger -t "$SYSLOG_IDENT" -p "${SYSLOG_FACILITY}.err")
fi

# The first argument must be a WAL file
xlog=${@:$OPTIND:1}
if [ -z "$xlog" ]; then
    error "missing xlog filename to archive. Please consider modifying archive_command, eg add %p"
fi

# Sanity check. We need at least to know if we want to perform a local
# copy or have a hostname for an SSH copy
if [ "$ARCHIVE_LOCAL" != "yes" ] && [ -z "$ARCHIVE_HOST" ]; then
    error "Not enough information to archive the segment"
fi

if [ "$ARCHIVE_LOCAL" = "yes" ] && [ -n "$ARCHIVE_HOST" ]; then
    error "ARCHIVE_LOCAL and ARCHIVE_HOST are set, it can't be both"
fi

# Check if the source file exists
if [ ! -r "$xlog" ]; then
    error "Input file '$xlog' does not exist or is not readable"
fi

# Set dd flush mode if needed
if [ "$ARCHIVE_FLUSH" = "yes" ]; then
    ARCHIVE_FLUSH='conv=fsync'
else
    ARCHIVE_FLUSH=''
fi

check_local_dest_exists()
{
    [ $ARCHIVE_OVERWRITE = "yes" ] && return 0

    [ ! -e "$1" ] || error "$1 already exists, refusing to overwrite it."
}

# Copy the wal locally
if [ "$ARCHIVE_LOCAL" = "yes" ]; then
    dd_rc=0
    mkdir -p -- "$ARCHIVE_DIR" 1>&2 ||
        error "Unable to create target directory '$ARCHIVE_DIR'" $?

    if [ "$ARCHIVE_COMPRESS" = "yes" ]; then
        dest_path=$ARCHIVE_DIR/$(basename -- "$xlog").$ARCHIVE_COMPRESS_SUFFIX
        check_local_dest_exists "$dest_path"

        $ARCHIVE_COMPRESS_BIN -c < "$xlog" | dd $ARCHIVE_FLUSH of="$dest_path" 2>/dev/null
        rc=( ${PIPESTATUS[@]} )
        x_rc=${rc[0]}
        dd_rc=${rc[1]}
        if [ $x_rc != 0 ]; then
            rm -f -- "$dest_path"
            error "Compressing $xlog to $dest_path failed"
        fi
    else
        dest_path=$ARCHIVE_DIR/$(basename -- "$xlog")
        check_local_dest_exists "$dest_path"

        dd $ARCHIVE_FLUSH if="$xlog" of="$dest_path" 2>/dev/null
        dd_rc=$?
    fi

    if [ $dd_rc != 0 ] ; then
        rm -f -- "$dest_path"
        error "Copying $xlog to $dest_path failed"
    fi

    # Chmod if required
    if [ -n "$ARCHIVE_FILE_CHMOD" ]; then
        echo "$ARCHIVE_FILE_CHMOD" | grep -qE '^[0-7]{3,4}$'
        if [ $? = 0 ]; then
            if ! chmod $ARCHIVE_FILE_CHMOD "$dest_path"; then
                warn "Could not change mode of $dest_path to $ARCHIVE_FILE_CHMOD"
            fi
        else
            warn "ARCHIVE_FILE_CHMOD is not in octal form, mode not changed"
        fi
    fi

else
    # Compress and copy with rsync
    echo $ARCHIVE_HOST | grep -qi '^[0123456789abcdef:]*:[0123456789abcdef:]*$' && ARCHIVE_HOST="[${ARCHIVE_HOST}]" # Dummy test for IPv6

    dest_host=${ARCHIVE_USER:+$ARCHIVE_USER@}${ARCHIVE_HOST}

    dest_file="$ARCHIVE_DIR/$(basename -- "$xlog")"
    tmp_file=""
    src_file="$xlog"

    # Depending on the options, we may check different things on the
    # remote host. To avoid many connections, we build a command to be
    # run one time on the remote host.

    # Create remote folder if needed. Return 2 on error.
    REMOTE_CMD="mkdir -p -- $(qw "$ARCHIVE_DIR") || exit 2"

    # Compress the file to a temporary location
    if [ "$ARCHIVE_COMPRESS" = "yes" ]; then
        dest_file=$ARCHIVE_DIR/$(basename -- "$xlog").$ARCHIVE_COMPRESS_SUFFIX
        tmp_file=$(mktemp -t pitr_wal.XXXXXXXXXX) ||
            error "Failed to create temporary file for compressed WAL" $?

        src_file="$tmp_file"

        # We take no risk, pipe the content to the compression program
        # and save output elsewhere: the compression program never
        # touches the input file
        $ARCHIVE_COMPRESS_BIN -c < "$xlog" > "$tmp_file" ||
            error "Compressing $xlog to $tmp_file failed" $?
    fi

    # Check if the file exists on the remote host. If the file exists
    # on the remote host and we do not overwrite it, we just get its
    # md5 sum and exit. Later the check of the md5 will exit on error
    # if the sum a different
    if [ "$ARCHIVE_OVERWRITE" != "yes"  ] && [ "$ARCHIVE_CHECK" = "yes" ]; then
        REMOTE_CMD="$REMOTE_CMD; [ -e $(qw "$dest_file") ] && echo \$(md5sum -- $(qw "$dest_file")) && exit 0"
    elif [ "$ARCHIVE_OVERWRITE" != "yes" ]; then
        REMOTE_CMD="$REMOTE_CMD; [ ! -e $(qw "$dest_file") ] || exit 3"
    fi

    # Copy the file with dd
    REMOTE_CMD="$REMOTE_CMD; dd $ARCHIVE_FLUSH of=$(qw "$dest_file") 2>/dev/null || exit 1"

    if [ "$ARCHIVE_CHECK" = "yes" ]; then
        REMOTE_CMD="$REMOTE_CMD; md5sum -- $(qw "$dest_file")"
    fi

    # Chmod if required
    if [ -n "$ARCHIVE_FILE_CHMOD" ]; then
        echo "$ARCHIVE_FILE_CHMOD" | grep -qE '^[0-7]{3,4}$'
        if [ $? = 0 ]; then
            REMOTE_CMD="$REMOTE_CMD; chmod $ARCHIVE_FILE_CHMOD $(qw "$dest_file") || exit 4"
        else
            warn "ARCHIVE_FILE_CHMOD is not in octal form, mode not changed"
        fi
    fi

    # Actually execute the remote commands
    remote_md5=$(dd if="$src_file" 2>/dev/null|ssh -- "$dest_host" "$REMOTE_CMD")
    rc=$?

    case $rc in
        0) ;;
        1) error "Unable to copy $xlog to ${ARCHIVE_HOST}:${ARCHIVE_DIR}" $rc;;
        2) error "Unable to create target directory" $rc;;
        3) error "'$dest_file' already exists on $dest_host, refusing to overwrite it" $rc;;
        4) warn "Could not change mode of $dest_path to $ARCHIVE_FILE_CHMOD";;
        255) error "SSH error on ${ARCHIVE_HOST}" $rc;;
        *) error "Unexpected return code while copying the file" 100
    esac

    if [ "$ARCHIVE_CHECK" = "yes" ]; then
        local_md5=$(md5sum -- "$src_file")

        if [ "${local_md5%% *}" != "${remote_md5%% *}" ]; then
            error "md5 mismatch between local and remote file" 4
        fi
    fi

    # Remove temp file if exists
    if [ -n "$tmp_file" ] && [ -s "$tmp_file" ]; then
        rm -- "$tmp_file" ||
            warn "Unable to remove temporary compressed file '$tmp_file'"
    fi

fi

exit 0
