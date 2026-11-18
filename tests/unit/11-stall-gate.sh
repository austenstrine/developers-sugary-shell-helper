#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_start_refuses_when_stall_elevated() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	local soft="$HARNESS_TMP/softlock"
	mkdir -p "$soft"
	touch "$soft/stall-elevated"
	export HOST_SOFTLOCK_STATE_DIR="$soft"
	unset DSSH_IGNORE_STALL || true
	capture_dssh start backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "host stall elevated"
}

test_start_ok_when_stall_ignored() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	local soft="$HARNESS_TMP/softlock"
	mkdir -p "$soft"
	touch "$soft/stall-elevated"
	export HOST_SOFTLOCK_STATE_DIR="$soft"
	export DSSH_IGNORE_STALL=1
	capture_dssh start backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	unset DSSH_IGNORE_STALL
}

test_start_ok_when_no_stall_flag() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	local soft="$HARNESS_TMP/softlock-empty"
	mkdir -p "$soft"
	export HOST_SOFTLOCK_STATE_DIR="$soft"
	unset DSSH_IGNORE_STALL || true
	capture_dssh start backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
}

run_all_tests_in_file
