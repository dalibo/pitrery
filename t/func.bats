#!/usr/bin/env bats

load test_helper

setup () {
	MAJOR_VERSION=${PGVERSION/\.[0-9]*/}
}

@test "First dummy check - trying to run help action" {
	run pitrery help
	[ "${lines[0]}" == 'pitrery 3.1 - PostgreSQL Point In Time Recovery made easy' ]
	echo "output = ${output}"
}

@test "Testing configure action without parameter" {
	run pitrery configure
	[ "$status" -eq 1 ]
}

@test "Testing backup action without config" {
	run pitrery backup
	[ "$status" -eq 1 ]
}
@test "Testing configure action with local parameters" {
	run pitrery configure -f -o $PITRERY_LOCAL_CONF $PITRERY_BACKUP_DIR
	[ "$status" -eq 0 ]
}

@test "Testing list action with local config and no backups" {
	run pitrery -f $PITRERY_LOCAL_CONF list
	[ "$status" -eq 1 ]
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
