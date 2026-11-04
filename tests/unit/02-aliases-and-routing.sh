#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_target_alias_api_to_backend() {
	harness_mktemp
	install_mocks "image_inspect=1
has_alpine=1
gpu_attach=fail"
	write_minimal_rc
	capture_dssh alias api start -nobuild
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

test_unknown_target_usage() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh unk nosuchtarget start
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "Unknown target"
}

test_custom_global_action_via_dsshrc() {
	harness_mktemp
	install_mocks
	write_minimal_rc 'dssh_foo_local="echo FOO_GLOBAL"'
	capture_dssh foo foo
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "FOO_GLOBAL"
}

test_mode_local_forced() {
	harness_mktemp
	install_mocks "ps_names=
compose_ps=ok"
	write_minimal_rc
	# Even with live-looking names, dssh_mode=local in rc
	capture_dssh st status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mode: local"
}

test_mode_live_forced() {
	harness_mktemp
	install_mocks "compose_ps=LIVE_PS_OK
inspect_compose_service=api
inspect_running=1"
	write_live_rc
	capture_dssh st status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mode: live"
}

test_mode_env_override_local() {
	harness_mktemp
	install_mocks "compose_ps=x"
	write_live_rc  # rc says live
	DSSH_MODE=local capture_dssh st status
	# capture_dssh uses DSSH_MODE from env if exported
	export DSSH_MODE=local
	capture_dssh st2 status
	assert_file_contains "$CAPTURE_OUT" "mode: local"
	unset DSSH_MODE
}

test_auto_detects_live_via_compose_label() {
	harness_mktemp
	install_mocks "inspect_compose_service=api
inspect_running=1
compose_ps=AUTO_LIVE"
	# auto mode with detect targets + compose-owned container
	write_live_rc 'dssh_mode=auto'
	capture_dssh st status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mode: live"
}

test_auto_stays_local_without_compose() {
	harness_mktemp
	# inspect returns empty compose service → not live
	install_mocks "inspect_compose_service=
inspect_running=1
ps_names="
	write_live_rc 'dssh_mode=auto'
	capture_dssh st status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mode: local"
}

run_all_tests_in_file
