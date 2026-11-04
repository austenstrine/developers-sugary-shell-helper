#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_preflight_absent_unchanged() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	rm -f "$HARNESS_PROJECT/started.txt"
	capture_dssh s backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
	assert_not_file_contains "$CAPTURE_ERR" "pending step"
}

test_preflight_detect_ok_skips() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc "
backend_start_preflight_detect='true'
backend_start_preflight_apply='echo APPLIED > \"$HARNESS_PROJECT/applied.txt\"'
backend_start_preflight_timeout=1
backend_start_preflight_default=N
"
	rm -f "$HARNESS_PROJECT/started.txt" "$HARNESS_PROJECT/applied.txt"
	capture_dssh s backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	[[ ! -f "$HARNESS_PROJECT/applied.txt" ]] || fail "apply ran when detect ok"
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

test_preflight_timeout_default_n() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc "
backend_start_preflight_detect='false'
backend_start_preflight_apply='echo APPLIED > \"$HARNESS_PROJECT/applied.txt\"'
backend_start_preflight_prompt='Detected a pending step. Run it now? (y/N)'
backend_start_preflight_timeout=1
backend_start_preflight_default=N
"
	rm -f "$HARNESS_PROJECT/started.txt" "$HARNESS_PROJECT/applied.txt"
	capture_dssh s backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_ERR" "Skipping pending"
	[[ ! -f "$HARNESS_PROJECT/applied.txt" ]] || fail "apply on N"
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

test_preflight_yes_runs_apply() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc "
backend_start_preflight_detect='false'
backend_start_preflight_apply='echo APPLIED > \"$HARNESS_PROJECT/applied.txt\"'
backend_start_preflight_prompt='Detected a pending step. Run it now? (y/N)'
backend_start_preflight_timeout=5
backend_start_preflight_default=N
"
	rm -f "$HARNESS_PROJECT/started.txt" "$HARNESS_PROJECT/applied.txt"
	capture_dssh s backend start -nobuild <<<"y"
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/applied.txt" "APPLIED"
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
	assert_file_contains "$CAPTURE_ERR" "Running pending"
}

test_preflight_only_detect_ignored() {
	harness_mktemp
	install_mocks "image_inspect=1"
	# apply unset → preflight disabled
	write_minimal_rc "
backend_start_preflight_detect='false'
backend_start_preflight_timeout=1
"
	rm -f "$HARNESS_PROJECT/started.txt"
	capture_dssh s backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	assert_not_file_contains "$CAPTURE_ERR" "pending"
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

test_preflight_on_restart() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc "
backend_start_preflight_detect='false'
backend_start_preflight_apply='echo APPLIED > \"$HARNESS_PROJECT/applied.txt\"'
backend_start_preflight_timeout=1
backend_start_preflight_default=N
"
	rm -f "$HARNESS_PROJECT/started.txt" "$HARNESS_PROJECT/applied.txt"
	# restart exec's start — should still hit preflight
	capture_dssh s backend restart -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_ERR" "Skipping pending"
}

run_all_tests_in_file
