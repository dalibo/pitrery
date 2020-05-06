#!/usr/bin/env bats
setup()
{
	export PATH=/usr/local/bin/:$PATH
	export PITRERY_BACKUP_DIR=/tmp/backup
	export PITRERY_LOCAL_CONF=/tmp/pitrery_local.conf
	export PITRERY_REMOTE_CONF=/tmp/pitrery_remote.conf
	mkdir -p $PITRERY_BACKUP_DIR
}

#teardown()
#{
#	# teardown function
#}

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

@test "Testing backup action with local config" {
  run pitrery -f $PITRERY_LOCAL_CONF backup
  [ "$status" -eq 0 ]
  echo "output = ${output}"
  [[ "$output" == *"INFO: preparing directories"* ]]
  [[ "$output" == *"INFO: backing up PGDATA"* ]]
  [[ "$output" == *"INFO: done"* ]]
}

@test "Testing list action with local config" {
  run pitrery -f $PITRERY_LOCAL_CONF list
  [ "${#output[@]}" -eq 2 ]
}
