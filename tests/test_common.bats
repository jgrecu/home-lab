setup() {
    load '../scripts/lib/common.sh'
}

@test "log debug outputs to stdout" {
    run log debug "test message"
    [ "$status" -eq 0 ]
}

@test "log info outputs to stdout" {
    run log info "test message"
    [ "$status" -eq 0 ]
}

@test "log error exits with 1" {
    run log error "fatal error"
    [ "$status" -eq 1 ]
}

@test "log error respects LOG_LEVEL" {
    LOG_LEVEL=error run log info "should not appear"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "check_cli passes for built-in commands" {
    run check_cli "echo" "printf"
    [ "$status" -eq 0 ]
}

@test "check_cli fails for missing command" {
    run check_cli "this_command_does_not_exist_xyz"
    [ "$status" -eq 1 ]
}

@test "check_env passes for set variables" {
    FOO=bar run check_env "FOO"
    [ "$status" -eq 0 ]
}

@test "check_env fails for unset variables" {
    run check_env "SOME_UNSET_VAR_XYZ"
    [ "$status" -eq 1 ]
}
