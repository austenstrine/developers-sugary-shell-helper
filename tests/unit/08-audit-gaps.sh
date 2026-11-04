#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_mode_prod_alias_is_live() {
	harness_mktemp
	install_mocks "compose_ps=ok"
	write_live_rc 'dssh_mode=prod'
	capture_dssh st status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mode: live"
}

test_mode_dev_alias_is_local() {
	harness_mktemp
	install_mocks "ps_names="
	write_minimal_rc 'dssh_mode=dev'
	capture_dssh st status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mode: local"
}

test_gpu_host_without_runtime_message() {
	harness_mktemp
	# nvidia-smi ok, no runtime, attach fails → specific host/runtime message
	install_mocks "has_nvidia_runtime=0
has_alpine=1
gpu_attach=fail"
	plant_nvidia_smi 0
	write_minimal_rc 'dssh_gpus=auto'
	capture_dssh gp gpu-probe
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "cpu-only"
	assert_file_contains "$CAPTURE_ERR" "no working nvidia runtime"
}

test_preflight_default_y_on_timeout() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc "
backend_start_preflight_detect='false'
backend_start_preflight_apply='echo APPLIED > \"$HARNESS_PROJECT/applied.txt\"'
backend_start_preflight_timeout=1
backend_start_preflight_default=Y
"
	rm -f "$HARNESS_PROJECT/started.txt" "$HARNESS_PROJECT/applied.txt"
	capture_dssh s backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/applied.txt" "APPLIED"
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

test_preflight_apply_failure_aborts() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc "
backend_start_preflight_detect='false'
backend_start_preflight_apply='false'
backend_start_preflight_timeout=5
backend_start_preflight_default=N
"
	rm -f "$HARNESS_PROJECT/started.txt"
	capture_dssh s backend start -nobuild <<<"y"
	assert_exit "$CAPTURE_RC" 1
	[[ ! -f "$HARNESS_PROJECT/started.txt" ]] || fail "start continued after apply failure"
}

test_live_preflight_on_start() {
	harness_mktemp
	install_mocks
	write_live_rc "
backend_start_preflight_detect='false'
backend_start_preflight_apply='echo APPLIED > \"$HARNESS_PROJECT/applied.txt\"'
backend_start_preflight_timeout=1
backend_start_preflight_default=N
"
	rm -f "$HARNESS_PROJECT/applied.txt"
	capture_dssh s backend start -nobuild </dev/null
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_ERR" "Skipping pending"
	[[ ! -f "$HARNESS_PROJECT/applied.txt" ]] || fail "apply on live N"
}

test_stop_hard_synonym_all() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh st stop all
	assert_exit "$CAPTURE_RC" 0
	if ! grep -Fq 'DANGER: stopping entire live stack' "$CAPTURE_OUT" "$CAPTURE_ERR"; then
		fail "expected DANGER for stop all"
	fi
}

test_stop_hard_synonym_dash_hard() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh st stop -hard
	assert_exit "$CAPTURE_RC" 0
}

test_rlog_start_stop_synonyms() {
	harness_mktemp
	install_mocks
	_plant() {
		cat >"$HARNESS_PROJECT/fake-rlog.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "${DSSH_RLOG_DIR:-.}"
echo "$$" >"${DSSH_RLOG_DIR:-.}/rlog.pid"
echo fake >"${DSSH_RLOG_DIR:-.}/latest.txt"
sleep 8
EOF
		chmod +x "$HARNESS_PROJECT/fake-rlog.sh"
	}
	_plant
	write_minimal_rc "dssh_rlog_script=./fake-rlog.sh
dssh_rlog_dir=./.dssh/rlog"
	capture_dssh on rlog start
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog on"
	capture_dssh off rlog stop
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog off"
	if [[ -f "$HARNESS_PROJECT/.dssh/rlog/rlog.pid" ]]; then
		kill "$(tr -d '[:space:]' <"$HARNESS_PROJECT/.dssh/rlog/rlog.pid")" 2>/dev/null || true
	fi
	pkill -f "$HARNESS_PROJECT/fake-rlog.sh" 2>/dev/null || true
}

test_publish_when_rlog_already_on() {
	harness_mktemp
	install_mocks
	cat >"$HARNESS_PROJECT/fake-rlog.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "${DSSH_RLOG_DIR:-.}"
echo "$$" >"${DSSH_RLOG_DIR:-.}/rlog.pid"
echo fake >"${DSSH_RLOG_DIR:-.}/latest.txt"
sleep 8
EOF
	chmod +x "$HARNESS_PROJECT/fake-rlog.sh"
	write_live_rc "dssh_rlog_script=./fake-rlog.sh
dssh_rlog_dir=./.dssh/rlog"
	# Start rlog first
	capture_dssh on rlog on
	capture_dssh pub publish
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/published.txt" "PUBLISH_OK"
	# status path taken when already running (rlog on in publish stdout/stderr)
	if [[ -f "$HARNESS_PROJECT/.dssh/rlog/rlog.pid" ]]; then
		kill "$(tr -d '[:space:]' <"$HARNESS_PROJECT/.dssh/rlog/rlog.pid")" 2>/dev/null || true
	fi
	pkill -f "$HARNESS_PROJECT/fake-rlog.sh" 2>/dev/null || true
}

test_rnano_invalid_alias() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh rn rnano 'bad-alias!'
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "invalid alias"
}

test_rnano_missing_path() {
	harness_mktemp
	install_mocks
	write_minimal_rc 'prod_env_host=user@host'
	capture_dssh rn rnano prod_env
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "prod_env_path"
}

test_live_custom_local_action() {
	harness_mktemp
	install_mocks
	write_live_rc "backend_seed_local='echo SEED_LOCAL > \"$HARNESS_PROJECT/seed.txt\"'"
	capture_dssh seed backend seed
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/seed.txt" "SEED_LOCAL"
}

test_live_raw_exec_fallback() {
	harness_mktemp
	install_mocks "inspect_running=1"
	write_live_rc
	# No backend_uname configured → falls through to docker exec
	capture_dssh raw backend uname
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mock-docker-exec"
	assert_file_contains "$HARNESS_DOCKER_LOG" "exec"
}

test_local_container_only_action() {
	harness_mktemp
	install_mocks "image_inspect=1"
	# container action without _local — exercises run_container_shell path
	write_minimal_rc "backend_seed='echo SEED_IN_CONTAINER'
backend_seed_attach=0
backend_seed_detached=1"
	capture_dssh seed backend seed -nobuild
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "run"
}

test_stop_local_override() {
	harness_mktemp
	install_mocks
	write_minimal_rc "dssh_stop_local='echo STOP_OVERRIDE > \"$HARNESS_PROJECT/stopped.txt\"'"
	capture_dssh st stop
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/stopped.txt" "STOP_OVERRIDE"
}

test_live_logs_all_services() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh logs logs
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "compose"
}

test_health_http_probe() {
	harness_mktemp
	install_mocks "inspect_running=1"
	# Plant curl that records the URL
	cat >"$HARNESS_BIN/curl" <<EOF
#!/bin/sh
echo "curl \$*" >>"$HARNESS_TMP/curl.log"
exit 0
EOF
	chmod +x "$HARNESS_BIN/curl"
	write_live_rc 'dssh_live_health_url=http://127.0.0.1/healthz'
	capture_dssh h health
	assert_exit "$CAPTURE_RC" 0
	[[ -f "$HARNESS_TMP/curl.log" ]] || fail "curl not invoked for health URL"
	assert_file_contains "$HARNESS_TMP/curl.log" "healthz"
}

test_local_restart_delegates_to_start() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	rm -f "$HARNESS_PROJECT/started.txt"
	capture_dssh r backend restart -nobuild
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/started.txt" "BACKEND_START_LOCAL"
}

run_all_tests_in_file
