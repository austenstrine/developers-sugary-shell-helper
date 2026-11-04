#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_local_start_nobuild() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	rm -f "$HARNESS_PROJECT/started.txt"
	capture_dssh s backend start -nobuild
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

test_local_start_double_dash_nobuild() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	rm -f "$HARNESS_PROJECT/started.txt"
	capture_dssh s backend start --nobuild
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

test_local_build() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh b backend build
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "build"
}

test_local_stop_target() {
	harness_mktemp
	install_mocks "inspect_running=1"
	write_minimal_rc
	capture_dssh st backend stop
	assert_exit "$CAPTURE_RC" 0
}

test_local_migrate_action() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	capture_dssh m backend migrate
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/migrated.txt" "BACKEND_MIGRATE_LOCAL"
}

test_local_missing_dockerfile() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	rm -f "$HARNESS_PROJECT/apps/backend/Dockerfile"
	capture_dssh s backend start -nobuild
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "Dockerfile not found"
}

test_live_start_nobuild() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh s backend start -nobuild
	assert_exit "$CAPTURE_RC" 0
	if ! grep -Eqi 'no rebuild|replacing' "$CAPTURE_OUT" "$CAPTURE_ERR"; then
		fail "expected live replace message; out=$(cat "$CAPTURE_OUT") err=$(cat "$CAPTURE_ERR")"
	fi
	assert_file_contains "$HARNESS_DOCKER_LOG" "compose"
}

test_live_restart_builds() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh s backend restart
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "up"
}

test_live_stop_service() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh s backend stop
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "stopping compose service"
}

test_live_build() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh b backend build
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "compose"
}

test_live_migrate_wrong_service() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh m frontend migrate
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "migrate is only for compose service"
}

test_live_migrate_on_api() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh m backend migrate
	assert_exit "$CAPTURE_RC" 0
}

test_live_logs_target() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh l backend logs
	assert_exit "$CAPTURE_RC" 0
}

test_live_custom_container_action() {
	harness_mktemp
	install_mocks "inspect_running=1"
	write_live_rc 'backend_seed="echo SEED"'
	capture_dssh seed backend seed
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "compose"
}

test_live_shell_no_container() {
	harness_mktemp
	# live_container_name needs both _name and service/prefix unset to return empty.
	install_mocks "inspect_running=0"
	write_live_rc 'backend_name=
dssh_live_container_prefix=
backend_service='
	capture_dssh sh backend
	assert_exit "$CAPTURE_RC" 1
	if ! grep -Eqi 'No live compose service|No live container|backend_service' "$CAPTURE_ERR"; then
		fail "expected missing live service/container; err=$(cat "$CAPTURE_ERR")"
	fi
}

run_all_tests_in_file
