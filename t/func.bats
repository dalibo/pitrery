#!/usr/bin/env bats

load test_helper

setup () {
	MAJOR_VERSION=${PGVERSION/\.[0-9]*/}
}

@test "First dummy check - trying to run help action" {
	run pitrery help
	[ "${lines[0]}" == 'pitrery 3.2 - PostgreSQL Point In Time Recovery made easy' ]
	echo "output = ${output}"
}

@test "Testing configure action without parameter" {
	run pitrery configure
	[ "$status" -eq 1 ]
	echo "output = ${output}"
}

@test "Testing backup action without config" {
	run pitrery backup
	[ "$status" -eq 1 ]
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
	[ "${#output[@]}" -eq 2 ]
	[[ "${output[1]}" == "$PITRERY_BACKUP_DIR"* ]]

	for line in "${lines[@]:1}"; do
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
	[ "${#output[@]}" -eq 3 ]
	[[ "${output[1]}" == "$PITRERY_BACKUP_DIR"* ]]
	[[ "${output[2]}" == "$PITRERY_BACKUP_DIR"* ]]
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
	[ "${#output[@]}" -eq 4 ]
	[[ "${output[1]}" == "$PITRERY_BACKUP_DIR"* ]]
	[[ "${output[2]}" == "$PITRERY_BACKUP_DIR"* ]]
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
	[ "${#output[@]}" -eq 3 ]
	[[ "${output[1]}" == "$PITRERY_BACKUP_DIR"* ]]
	[[ "${output[2]}" == "$PITRERY_BACKUP_DIR"* ]]
}

@test "Testing backup check with backup count" {
	run pitrery check -C $PITRERY_LOCAL_CONF -B -m 2
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}

@test "Testing archive check" {
	run pitrery check -C $PITRERY_LOCAL_CONF -A
	[ "$status" -eq 0 ]
	echo "output = ${output}"
}
