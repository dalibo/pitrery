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

# Hard coded configuration 
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
local_xlog="no"
xlog_dir=/var/lib/pgsql/archived_xlog
log_timestamp="no"

usage() {
    echo "`basename $0` cleans old PITR backups"
    echo "usage: `basename $0` [options] [hostname]"
    echo "options:"
    echo "    -L           Purge a local store"
    echo "    -l label     Label to process"
    echo "    -b dir       Backup directory"
    echo "    -u username  Username for SSH login to the backup host"
    echo "    -n host      Host storing archived WALs"
    echo "    -U username  Username for SSH login to WAL storage host"
    echo "    -X dir       Archived WALs directory"
    echo
    echo "    -m count     Keep this number of backups"
    echo "    -d days      Purge backups older than this number of days"
    echo "    -N           Dry run: show what would be purged only"
    echo
    echo "    -T           Timestamp log messages"
    echo "    -?           Print help"
    echo
    exit $1
}

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

now() {
    [ $log_timestamp = "yes" ] && echo -e "$(date "+%F %T %Z ")"
}

info() {
    echo "$(now)INFO: $*"
}

error() {
    echo "$(now)ERROR: $*" 1>&2
    exit 1
}

warn() {
    echo "$(now)WARNING: $*" 1>&2
}

# CLI options
while getopts "Ll:b:u:n:U:X:m:d:NT?" opt; do
    case $opt in
	L) local_backup="yes";;
	l) label_prefix=$OPTARG;;
	b) backup_root=$OPTARG;;
	u) ssh_user=$OPTARG;;
	n) xlog_host=$OPTARG;;
	U) xlog_ssh_user=$OPTARG;;
	X) xlog_dir=$OPTARG;;
	m) max_count=$OPTARG;;
	d) max_days=$OPTARG;;
	N) dry_run="yes";;
	T) log_timestamp="yes";;

        "?") usage 1;;
	*) error "Unknown error while processing options";;
    esac
done

target=${@:$OPTIND:1}

# Destination host is mandatory unless the backup is local
if [ -z "$target" ] && [ $local_backup != "yes" ]; then
    echo "ERROR: missing target host" 1>&2
    usage 1
fi

# Either -m or -d must be specified
if [ -z "$max_count" -a -z "$max_days" ]; then
    echo "ERROR: missing purge condition. Use -m or -d." 1>&2
    usage 1
fi

# When the host storing the WAL files is not given, use the host of the backups
if [ -z "$xlog_host" ]; then
    local_xlog=$local_backup
    xlog_host=$target
fi
[ -z "$xlog_ssh_user" ] && xlog_ssh_user=$ssh_user

# Prepare the IPv6 address for use with SSH
[[ $target == *([^][]):*([^][]) ]] && target="[${target}]"
[[ $xlog_host == *([^][]):*([^][]) ]] && xlog_host="[${xlog_host}]"
ssh_target=${ssh_user:+$ssh_user@}$target
xlog_ssh_target=${xlog_ssh_user:+$xlog_ssh_user@}$xlog_host

# Ensure failed globs will be empty, not left containing the literal glob pattern
shopt -s nullglob

# Get the list of backups
info "searching backups"
if [ "$local_backup" = "yes" ]; then
    list=( "$backup_root/$label_prefix/"[0-9]*/ )
    (( ${#list[@]} > 0 )) || error "Could not find any backups in $backup_root/$label_prefix/"
else
    list=()
    while read -r -d '' d; do
	list+=("$d")
    done < <(
	ssh -n -- "$ssh_target" "find $(qw "$backup_root/$label_prefix") -maxdepth 1 -name '[0-9]*' -type d -print0"
    )

    (( ${#list[@]} > 0 )) || error "Could not find any backups in $backup_root/$label_prefix/ on $target"
fi

# Get the stop time timestamp of each backup, comparing timestamps is better
#
# We store them in a (sparse) indexed array, which for our purposes here is
# effectively an associative array, just with the keys automatically sorted
# so that the oldest (numerically smallest) timestamps come first.  Things
# would be a little bit simpler if they were sorted newest first, but not by
# so much that it is worth going to the effort of manually sorting them in
# the reverse order.
candidates=()
for dir in "${list[@]%/}"; do
    if [ "$local_backup" = "yes" ]; then
	ts=$(< "$dir/backup_timestamp")
    else
	ts=$(ssh -n -- "$ssh_target" "cat -- $(qw "$dir/backup_timestamp")")
    fi

    # The timestamp must be a string of (only) digits, we do arithmetic with it
    if [[ $ts =~ ^[[:digit:]]+$ ]]; then
	candidates[$ts]=$dir
    else
	# We shouldn't normally ever be here, but if we are it's probably one
	# of two main reasons:
	# - This is a dir that starts with a digit but isn't actually a backup.
	# - Is is a backup, but either we failed to put a valid backup_timestamp
	#   into it, or that somehow got removed or corrupted again.
	#
	# In the latter case we could try to reconstruct a timestamp here, but
	# it's probably safer to just let the admin figure out what went wrong
	# if this happens.  There are two consequences to that:
	# - We won't consider this directory for automatic purge.
	# - We can't rely on oldest_unpurged actually being the oldest remaining
	#   backup (for the purpose of purging WAL files), since this one could
	#   be older than that.
	#
	# We could do more trickery based on the dirname to try to guess if the
	# latter case is true, but again, Something Went Wrong Somewhere, so
	# just play safe until the admin figures out what that was.
	have_unknown_timestamp="yes"
	warn "Could not get backup_timestamp for '$dir', it will not be purged"
    fi
done

# If a minimum number of backup must be kept, remove the $max_count
# youngest backups from the list.
if [ -n "$max_count" ]; then
    [[ $max_count =~ ^[[:digit:]]+$ ]] || error "PURGE_KEEP_COUNT '$max_count' is not a number"

    if (( $max_count > 0 )); then
	if (( ${#candidates[@]} > $max_count )); then
	    keys=( "${!candidates[@]}" )
	    for k in "${keys[@]:$((-$max_count))}"; do
		# The list of purge candidates is sorted oldest first, so capture
		# the first one removed from it as the oldest backup that we'll keep.
		[ -n "$oldest_unpurged" ] || oldest_unpurged=${candidates[$k]}
		unset "candidates[$k]"
	    done
	else
	    oldest_unpurged=${candidates[@]::1}
	    candidates=()
	fi
    fi
fi

# If older backups must be removed, filter the list by timestamp
if [ -n "$max_days" ]; then
    [[ $max_days =~ ^[[:digit:]]+$ ]] || error "PURGE_OLDER_THAN '$max_days' is not a number"

    if (( $max_days > 0 )); then
	limit_ts=$(($(date +%s) - 86400 * $max_days))
	keys=( "${!candidates[@]}" )
	for k in "${keys[@]}"; do
	    if (( $k >= $limit_ts )); then
		[ -n "$oldest_unpurged_day" ] || oldest_unpurged_day=${candidates[$k]}
		unset "candidates[$k]"
	    fi
	done
    fi
fi

# If this is a dry run, we need to cache this information for checking the WAL expiry
[ -z "$oldest_unpurged_day" ] || oldest_unpurged=$oldest_unpurged_day


# Purge the backups
if (( ${#candidates[@]} > 0 )); then
    info "${dry_run:+Would be }purging the following backups:"
    for d in "${candidates[@]}"; do
	info " $d"
    done

    if [ "$dry_run" != "yes" ]; then
	if [ "$local_backup" = "yes" ]; then
	    rm -rf -- "${candidates[@]}" || error "Failed to remove all purge candidates"
	else
	    # We can't preserve the word splitting behaviour of a quoted array across the
	    # call to ssh, so ensure each argument is properly shell quoted instead.
	    ssh -n -- "$ssh_target" "rm -rf -- $(qw "${candidates[@]}")" ||
		error "Failed to remove all $target purge candidates"
	fi
    fi
else
    info "there are no backups to purge"
fi


# To be able to purge the archived xlogs, the backup_label of the oldest backup
# is needed to find the oldest xlog file to keep.

# The easy case, where every directory had a valid backup_timestamp when we scanned them.
# This is all we should ever need normally.
get_oldest_unpurged_label() {
    if [ "$local_backup" = "yes" ]; then
	backup_label=$(< "$oldest_unpurged/backup_label") ||
	    error "Unable to read '$oldest_unpurged/backup_label'"
    else
	backup_label=$(ssh -n -- "$ssh_target" "cat -- $(qw "$oldest_unpurged/backup_label")") ||
	    error "Unable to read '$target:$oldest_unpurged/backup_label'"
    fi
}

# The fallback case, where we have directories which matched the [0-9]* glob,
# that _might_ be backups and have a backup_label in them, but didn't have a
# valid backup_timestamp for some reason.
find_oldest_backup_label() {
    if [ "$local_backup" = "yes" ]; then
	blist=( "$backup_root/$label_prefix/"[0-9]*/backup_label )
	if (( ${#blist[@]} > 0 )); then
	    backup_label=$(< "${blist[0]}") || error "Unable to read ${blist[0]}"
	fi
    else
	# It would probably be better to do something more like the local version above,
	# but this should be portable regardless of the remote login shell, and gets it
	# done with a single ssh connection.
	backup_label=$(ssh -n -- "$ssh_target" "f=\$(find $(qw "$backup_root/$label_prefix") -path $(qw "$backup_root/$label_prefix/[0-9]*/backup_label") -type f -print0 | sort -z | cut -d '' -f1) && [ -n \"\$f\" ] && cat -- \"\$f\"")
    fi
}

if [ "$dry_run" = "yes" ]; then
    # For a dry run we want the backup_label from the oldest one that we wouldn't have removed.

    if [ -n "$oldest_unpurged" ]; then
	# We have timestamps for at least some directories, if not all of them,
	# and we aren't purging every directory with a backup_timestamp file.
	# Scanning for backup_label files would give the wrong answer (since we
	# didn't actually delete anything this time), so just use the best answer
	# we have, and warn if we can't be certain that it's 100% correct.
	[ "$have_unknown_timestamp" != "yes" ] ||
	    warn "Some directories are missing a backup_timestamp.  Dry run report may not be correct."

	get_oldest_unpurged_label

    elif (( ${#candidates[@]} == 0 )); then
	# We found no directories with a backup_timestamp file (and so there were
	# no candidates for purging).  If we do have some directories that did not
	# have a backup_timestamp, we can 'safely' still scan those for backup_label
	# files which we can use to expire old WAL segment files (and we should have
	# errored out already before getting here if we don't have some of those).
	if [ "$have_unknown_timestamp" = "yes" ]; then
	    warn "The backup_timestamp was missing from all directories.  Basing WAL expiry on the oldest backup_label found"
	    find_oldest_backup_label
	fi
    else
	# We would have purged all backups with a backup_timestamp file if this wasn't
	# a dry run.  If there are directories without one, then we can't simply scan
	# them here.  We could add even more logic to enumerate them based on whether
	# they contain a backup_label and the stop time recorded in it, but this really
	# shouldn't ever happen in normal use, so that seems like overkill if we aren't
	# going to just do that always and get rid of the backup_timestamp files.
	# If something is that messed up, best we just leave the admin to sort it out.
	[ "$have_unknown_timestamp" != "yes" ] ||
	    warn "All directories with a backup_timestamp would be purged, but some directories without one would remain."
    fi

else
    # If every directory had a backup_timestamp file, then we already know the oldest
    # one that we didn't purge (which we have to track to be able to do dry runs).
    # If there were some that didn't, then they may be older than it is, so scan the
    # remaining directories again looking for backup_label files, to ensure we don't
    # purge any WAL files which they would need.
    if [ "$have_unknown_timestamp" = "yes" ]; then
	warn "Some directories are missing a backup_timestamp.  They have not been purged and WAL files they depend on will not be expired."
	find_oldest_backup_label

    elif [ -n "$oldest_unpurged" ]; then
	get_oldest_unpurged_label

    #else
	# We have just purged all of the available backup directories, we have no
	# remaining backup_label to use for WAL expiry.  We could purge all the WAL
	# files up to what was needed for the most recent purged backup, or simply
	# nuke them all - but leave this as an Admin Problem for now, if they really
	# had intended to delete Everything, there's probably more afoot than simply
	# pruning old files to make space.
    fi
fi

if [ -z "$backup_label" ]; then
    info "no backup found after purge. Please remove old archives by hand."
    exit 0
fi


# Extract the name of the WAL file from the backup history file, and
# split it in timeline, log and segment
wal_file=$(awk '/^START WAL LOCATION/ { gsub(/[^0-9A-F]/,"",$6); print $6 }' <<< "$backup_label")

# This must be only (hex) digits, or the arithmetic operations below will not do what we hope
[[ $wal_file =~ ^[0-9A-F]{24}$ ]] || error "'$wal_file' does not appear to be a WAL segment file name"

max_tln=$(( 16#${wal_file:0:8} ))
max_log=$(( 16#${wal_file:8:8} ))
max_seg=$(( 16#${wal_file:16:8} ))

info "listing WAL files older than $(basename -- "$wal_file")"

# List the WAL files and remove the old ones based on their name which
# are ordered in time by their naming scheme. The filter is on the
# nine first chars so that history files are excluded.
wal_list=()
if [ "$local_xlog" = "yes" ]; then
    wal_list=( "$xlog_dir/"[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]* )
else
    while read -r -d '' f; do
	wal_list+=("$f")
    done < <(
	ssh -n -- "$xlog_ssh_target" "find $(qw "$xlog_dir") -maxdepth 1 -name '[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]*' -type f -print0 | sort -z"
    )
fi

# Compare and remove files from the list
wal_purge_list=()
for wal in "${wal_list[@]}"; do
    # the wal files come ordered, when the first to keep comes, our list is complete
    [[ $wal =~ $wal_file ]] && break

    wal_purge_list+=( "$wal" )
done

info "${#wal_purge_list[@]} old WAL file(s) to remove${target:+ from $target}"
if (( ${#wal_purge_list[@]} > 0 )); then
    if [ "$dry_run" = "yes" ]; then
	info "Would purge ${#wal_purge_list[@]} old WAL file(s):"
	info " First: $(basename -- ${wal_purge_list[1]})"
	info " Last: $(basename -- ${wal_purge_list[@]:(-1)})"
    else
	info "purging old WAL files"

	# This may look ugly, but it is very easy to create a rm
	# command without too many arguments.
	if [ "$local_xlog" = "yes" ]; then
	    for wal in "${wal_purge_list[@]}"; do
		echo "rm -- $wal"
	    done | @BASH@ || error "unable to remove wal files"
	else
	    for wal in "${wal_purge_list[@]}"; do
		echo "rm -- $wal"
	    done | ssh -- "$xlog_ssh_target" "cat | sh" || error "unable to remove wal files on $xlog_host"
	fi
    fi
fi

info "done"
