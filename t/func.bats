#!/usr/bin/env bats

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
	run pitrery configure -f -o $PITRERY_LOCAL_CONF -m 2 $PITRERY_BACKUP_DIR
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
	# TODO get backup path name to verify next list test
}

@test "Testing list action with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF list
	[ "$status" -eq 0 ]
	IFS=$'\n'
	output=(${output})
	unset IFS
	[ "${#output[@]}" -eq 2 ]
	[[ "${output[1]}" == "$PITRERY_BACKUP_DIR"* ]]
}

@test "Testing purge action with local config" {
	run pitrery -f $PITRERY_LOCAL_CONF purge
	[ "$status" -eq 0 ]
}
