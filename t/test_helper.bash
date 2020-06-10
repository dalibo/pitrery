#!/bin/bash

BKPDIR_REGEX='[0-9]{4}.[0-9]{2}.[0-9]{2}_[0-9]{2}.[0-9]{2}.[0-9]{2}'

check_backup_content() {
	[[ -d $1 ]]
	[[ $1 =~ "$PITRERY_BACKUP_DIR/"${BKPDIR_REGEX} ]]
	[[ -f $1/backup_command ]]
	[[ -f $1/backup_label ]]
	[[ -f $1/backup_timestamp ]]
	[[ -f $1/pgdata.tar.gz ]]
	[[ -f $1/PG_VERSION ]]
	[[ $PGVERSION == $(cat $1/PG_VERSION) ]]
	[[ -f $1/pitrery.conf ]]
	[[ -d $1/tblspc ]]
	[[ -f $1/tblspc_list ]]
	if [ ${MAJOR_VERSION} -ge 11 ] ; then
		[[ -f $1/wal_segsize ]]
	fi
}
