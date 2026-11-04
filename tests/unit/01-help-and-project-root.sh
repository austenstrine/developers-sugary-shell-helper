#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../lib/harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_help_flag() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh help help
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "Usage:"
	assert_file_contains "$CAPTURE_OUT" "gpu-probe"
}

test_help_dash_h() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh dashh -h
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "Usage:"
}

test_help_double_dash() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh ddhelp --help
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "dssh_mode"
}

test_no_args_prints_usage_exit_1() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh noargs
	# run_dssh with no args — capture_dssh tag only; need empty argv
	local rc=0
	set +e
	env DSSH_PROJECT_ROOT="$HARNESS_PROJECT" "$DSSH_BIN" >"$HARNESS_TMP/no.out" 2>"$HARNESS_TMP/no.err"
	rc=$?
	set -e
	assert_exit "$rc" 1
	assert_file_contains "$HARNESS_TMP/no.out" "Usage:"
}

test_project_root_env() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	# Nested cwd without .dsshrc should still find project via DSSH_PROJECT_ROOT
	mkdir -p "$HARNESS_TMP/elsewhere"
	local out
	out="$(cd "$HARNESS_TMP/elsewhere" && env DSSH_PROJECT_ROOT="$HARNESS_PROJECT" "$DSSH_BIN" help)"
	assert_contains "$out" "Usage:"
}

test_project_root_walk_up() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	mkdir -p "$HARNESS_PROJECT/apps/backend/nested"
	local out
	out="$(cd "$HARNESS_PROJECT/apps/backend/nested" && env -u DSSH_PROJECT_ROOT -u DSSH_CONFIG_FILE "$DSSH_BIN" help)"
	assert_contains "$out" "Usage:"
}

test_project_root_config_file() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	mkdir -p "$HARNESS_TMP/elsewhere"
	local out
	out="$(cd "$HARNESS_TMP/elsewhere" && env -u DSSH_PROJECT_ROOT DSSH_CONFIG_FILE="$HARNESS_PROJECT/.dsshrc" "$DSSH_BIN" help)"
	assert_contains "$out" "Usage:"
}

test_dsshrc_local_override() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	echo 'dssh_status_local="echo STATUS_FROM_LOCAL"' >"$HARNESS_PROJECT/.dsshrc.local"
	capture_dssh st status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "STATUS_FROM_LOCAL"
}

run_all_tests_in_file
