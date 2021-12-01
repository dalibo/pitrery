#!/usr/bin/env bats

load test_helper

setup () {
	MAJOR_VERSION=${PGVERSION/\.[0-9]*/}
}

@test "First dummy check - trying to run help action" {
	run pitrery help
	[ "${lines[0]}" == 'pitrery 3.3 - PostgreSQL Point In Time Recovery made easy' ]
	echo "output = ${output}"
}

@test "Testing list configuration files" {
	run pitrery -l
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing configure action without parameter" {
	run pitrery configure
	[ "$status" -eq 1 ]
	echo "output = ${output}"
}

@test "Testing backup action without config" {
	run pitrery backup
	if [ -f /etc/debian_version ]; then
		[ "$status" -eq 1 ]
	else
		[ "$status" -eq 0 ]
	fi
	echo "output = ${output}"
}

@test "Testing configure action with local parameters" {
	run pitrery configure -f -o $PITRERY_LOCAL_CONF -m 2 $PITRERY_BACKUP_DIR
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing check action" {
	run pitrery check -C $PITRERY_LOCAL_CONF
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing list action with local config and no backups" {
	run pitrery -f $PITRERY_LOCAL_CONF list
	[ "$status" -eq 1 ]
	echo "output = ${output}"
}

@test "Testing backup action with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF backup
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: preparing directories"* ]]
	[[ "$output" == *"INFO: backing up PGDATA"* ]]
	[[ "$output" == *"INFO: done"* ]]

	BKPDIR=""
	for line in "${lines[@]}"; do
		if [[ $line =~ .*"INFO: backup directory is ".* ]] ; then
			BKPDIR=$(readlink -e ${line/*"INFO: backup directory is "/})
			break
		fi
	done
	check_backup_content ${BKPDIR}
}

@test "Testing list action with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF list
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	IFS=$'\n'
	output=(${output})
	unset IFS
	[ "${#output[@]}" -eq 3 ]
	[[ "${output[2]}" == "$PITRERY_BACKUP_DIR"* ]]

	for line in "${lines[@]:2}"; do
		BKPDIR=$(echo ${line}|cut -d" " -f1)
		check_backup_content ${BKPDIR}
	done
}

@test "Testing purge action with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF purge
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: searching backups"* ]]
	[[ "$output" == *"INFO: there are no backups to purge"* ]]
	[[ "$output" == *"INFO: done"* ]]
}

@test "Testing second backup action with local config" {
  ${PGBIN}/psql -Atc 'CREATE TABLE table_1 (i int)'
  ${PGBIN}/psql -Atc 'INSERT INTO table_1 (i) SELECT generate_series(1,100)'
	${PGBIN}/psql -c "SELECT pg_switch_${xlog_or_wal}()"
	run pitrery -f $PITRERY_LOCAL_CONF backup
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: preparing directories"* ]]
	[[ "$output" == *"INFO: backing up PGDATA"* ]]
	[[ "$output" == *"INFO: done"* ]]
	# TODO get backup path name to verify next list test
}

@test "Testing list after second backup with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF list
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	IFS=$'\n'
	output=(${output})
	unset IFS
	[ "${#output[@]}" -eq 4 ]
	[[ "${output[2]}" == "$PITRERY_BACKUP_DIR"* ]]
	[[ "${output[3]}" == "$PITRERY_BACKUP_DIR"* ]]
}

@test "Testing purge after second backup with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF purge
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: searching backups"* ]]
	[[ "$output" == *"INFO: there are no backups to purge"* ]]
	[[ "$output" == *"INFO: done"* ]]
}

@test "Testing third backup action with local config" {
  ${PGBIN}/psql -Atc 'CREATE TABLE table_2 (i int)'
  ${PGBIN}/psql -Atc 'INSERT INTO table_2 (i) SELECT generate_series(1,100)'
	${PGBIN}/psql -c "SELECT pg_switch_${xlog_or_wal}()"
	run pitrery -f $PITRERY_LOCAL_CONF backup
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: preparing directories"* ]]
	[[ "$output" == *"INFO: backing up PGDATA"* ]]
	[[ "$output" == *"INFO: done"* ]]
	# TODO get backup path name to verify next list test
}

@test "Testing list after third backup with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF list
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	IFS=$'\n'
	output=(${output})
	unset IFS
	[ "${#output[@]}" -eq 5 ]
	[[ "${output[2]}" == "$PITRERY_BACKUP_DIR"* ]]
	[[ "${output[3]}" == "$PITRERY_BACKUP_DIR"* ]]
}

@test "Testing purge after third backup with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF purge
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: searching backups"* ]]
	[[ "$output" == *"INFO: purging the following backups:"* ]]
	[[ "$output" == *"INFO: purging old WAL files"* ]]
	[[ "$output" == *"INFO: done"* ]]
}

@test "Testing list after purge with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF list
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	IFS=$'\n'
	output=(${output})
	unset IFS
	[ "${#output[@]}" -eq 4 ]
	[[ "${output[2]}" == "$PITRERY_BACKUP_DIR"* ]]
	[[ "${output[3]}" == "$PITRERY_BACKUP_DIR"* ]]
}

@test "Testing list in JSON format" {
	json_list=$(pitrery -f $PITRERY_LOCAL_CONF list -j)
	echo "${json_list}" | jq -e .
}

@test "Testing backup check with backup count" {
	run pitrery check -C $PITRERY_LOCAL_CONF -B -m 2
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: backups policy checks ok"* ]]
}

@test "Testing archive check" {
	run pitrery check -C $PITRERY_LOCAL_CONF -A
	[ "$status" -eq 0 ]
	echo "output = ${output}"
	[[ "$output" == *"INFO: all archived WAL files found"* ]]
}

@test "Testing restore dry mode" {
	run pitrery -f $PITRERY_LOCAL_CONF restore -R -D ${PGDATA}_2 -r "$(type -p restore_wal) -C $PITRERY_LOCAL_CONF %f %p" -n
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing restore in recovery mode" {
	run pitrery -f $PITRERY_LOCAL_CONF restore -R -D ${PGDATA}_2 -r "$(type -p restore_wal) -C $PITRERY_LOCAL_CONF %f %p"
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing restored instance can be started" {
	mkdir -p ${PITRERY_BACKUP_DIR}_2
	echo "port = 5433" >> ${PGDATA}_2/postgresql.auto.conf
	sed -i "s#${PITRERY_BACKUP_DIR}#${PITRERY_BACKUP_DIR}_2#g" ${PGDATA}_2/postgresql.auto.conf
	run ${PGBIN}/pg_ctl start -w -D ${PGDATA}_2 -l /tmp/logfile_2	3>&-
	[ "$status" -eq 0 ]
	sleep 3
	recovery_status=$(${PGBIN}/psql -p 5433 -Atc 'SELECT pg_is_in_recovery()')
	[[ "$recovery_status" == "f"* ]]
	# destroy restored instance
	${PGBIN}/pg_ctl stop -w -D ${PGDATA}_2 3>&-
	rm -rf ${PGDATA}_2
	rm -rf $PITRERY_BACKUP_DIR_2
}

@test "Testing restore in recovery mode with date" {
	backup_list=$(pitrery -f $PITRERY_LOCAL_CONF list)
	IFS=$'\n'
	backup_list=(${backup_list})
	unset IFS
	backup_timestamp=$(echo "${backup_list[2]}"|cut -d ' ' -f 3-)
	run pitrery -f $PITRERY_LOCAL_CONF restore -R -D ${PGDATA}_2 -r "$(type -p restore_wal) -C $PITRERY_LOCAL_CONF %f %p" -d "${backup_timestamp}"
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing restored instance with date can be started" {
  ${PGBIN}/psql -Atc 'CREATE TABLE table_3 (i int)'
  ${PGBIN}/psql -Atc 'INSERT INTO table_3 (i) SELECT generate_series(1,100)'
	${PGBIN}/psql -c "SELECT pg_switch_${xlog_or_wal}()"
	mkdir -p ${PITRERY_BACKUP_DIR}_2
	echo "port = 5433" >> ${PGDATA}_2/postgresql.auto.conf
	sed -i "s#${PITRERY_BACKUP_DIR}#${PITRERY_BACKUP_DIR}_2#g" ${PGDATA}_2/postgresql.auto.conf
	run ${PGBIN}/pg_ctl start -w -D ${PGDATA}_2 -l /tmp/logfile_2	3>&-
	[ "$status" -eq 0 ]
	sleep 10
	if [[ (( $first_digit_version -ge 10 )) ]]; then
		recovery_status=$(${PGBIN}/psql -p 5433 -Atc 'SELECT pg_is_in_recovery()')
		[[ "$recovery_status" == "t"* ]]
		${PGBIN}/psql -p 5433 -Atc "SELECT pg_${xlog_or_wal}_replay_resume()"
		sleep 5
	fi
	recovery_status=$(${PGBIN}/psql -p 5433 -Atc 'SELECT pg_is_in_recovery()')
	[[ "$recovery_status" == "f"* ]]
	# destroy restored instance
	${PGBIN}/pg_ctl stop -w -D ${PGDATA}_2 3>&-
	rm -rf ${PGDATA}_2
	rm -rf $PITRERY_BACKUP_DIR_2
}

@test "Testing restore in standby mode" {
	run pitrery -f $PITRERY_LOCAL_CONF restore -m standby -R -D ${PGDATA}_2 -r "$(type -p restore_wal) -C $PITRERY_LOCAL_CONF %f %p"
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing restored standby instance can be started" {
	mkdir -p ${PITRERY_BACKUP_DIR}_2
	echo "port = 5433" >> ${PGDATA}_2/postgresql.auto.conf
	sed -i "s#${PITRERY_BACKUP_DIR}#${PITRERY_BACKUP_DIR}_2#g" ${PGDATA}_2/postgresql.auto.conf
	if [[ (( $first_digit_version -ge 12 )) ]]; then
		echo "primary_conninfo = 'port=5432'" >> ${PGDATA}_2/postgresql.auto.conf
	else
		echo "primary_conninfo = 'port=5432'" >> ${PGDATA}_2/recovery.conf
		if [[ (( $first_digit_version -lt 10 )) ]]; then
			echo "hot_standby = on" >> ${PGDATA}_2/postgresql.auto.conf
      echo "local   replication     postgres          peer" >> ${PGDATA}/pg_hba.conf
      ${PGBIN}/psql -p 5432 -Atc "SELECT pg_reload_conf()"
		fi
	fi
	run ${PGBIN}/pg_ctl start -w -D ${PGDATA}_2 -l /tmp/logfile_2	3>&-
	[ "$status" -eq 0 ]
	sleep 5
	recovery_status=$(${PGBIN}/psql -p 5433 -Atc 'SELECT pg_is_in_recovery()')
	[[ "$recovery_status" == "t"* ]]
	repli_state=$(${PGBIN}/psql -p 5432 -Atc "SELECT state from pg_stat_replication")
	[[ "$repli_state" == "streaming"* ]]
	# destroy restored instance
	${PGBIN}/pg_ctl stop -w -D ${PGDATA}_2 3>&-
	rm -rf ${PGDATA}_2
	rm -rf $PITRERY_BACKUP_DIR_2
}
