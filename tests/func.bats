#!/usr/bin/env bats
setup()
{
	export PATH=/usr/local/bin/:$PATH

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

@test "Testing backup action with custom config" {
  run pitrery -f ./tests/pitrery.conf backup
  echo "output = ${output}"
  [[ "$output" == *"INFO: preparing directories"* ]]
  [[ "$output" == *"INFO: backing up PGDATA"* ]]
  [[ "$output" == *"INFO: done"* ]]
}

@test "Testing list action with custom config" {
  run pitrery -f ./tests/pitrery.conf list
  [ "${#output[@]}" -eq 2 ]
}
