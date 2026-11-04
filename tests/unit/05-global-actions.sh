#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_status_alias_ps() {
	harness_mktemp
	install_mocks "ps_names="
	write_minimal_rc
	capture_dssh ps ps
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mode: local"
}

test_health_local_shows_status() {
	harness_mktemp
	install_mocks "ps_names="
	write_minimal_rc
	capture_dssh h health
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "health probes are live-oriented"
}

test_health_live() {
	harness_mktemp
	install_mocks "inspect_running=1
inspect_compose_service=api
compose_ps=ok"
	write_live_rc
	capture_dssh h health
	assert_exit "$CAPTURE_RC" 0
}

test_publish_requires_config() {
	harness_mktemp
	install_mocks
	write_minimal_rc  # no dssh_publish_local
	# strip publish if any
	capture_dssh pub publish
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "dssh_publish_local"
}

test_publish_runs_and_starts_rlog() {
	harness_mktemp
	install_mocks
	write_live_rc
	# Use a stub rlog that exits immediately so we don't leave daemons
	cat >"$HARNESS_PROJECT/fake-rlog.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "${DSSH_RLOG_DIR:-.}"
echo "$$" >"${DSSH_RLOG_DIR:-.}/rlog.pid"
echo fake-rlog-ok >"${DSSH_RLOG_DIR:-.}/latest.txt"
# stay alive briefly so rlog_is_running sees us, then exit
sleep 30
EOF
	chmod +x "$HARNESS_PROJECT/fake-rlog.sh"
	# Point rlog at stub via override in rc
	write_live_rc "dssh_rlog_script=./fake-rlog.sh
dssh_rlog_dir=./.dssh/rlog
dssh_rlog_interval=60"
	capture_dssh pub publish
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/published.txt" "PUBLISH_OK"
	# cleanup fake rlog
	if [[ -f "$HARNESS_PROJECT/.dssh/rlog/rlog.pid" ]]; then
		kill "$(tr -d '[:space:]' <"$HARNESS_PROJECT/.dssh/rlog/rlog.pid")" 2>/dev/null || true
	fi
	pkill -f "$HARNESS_PROJECT/fake-rlog.sh" 2>/dev/null || true
}

test_stop_live_refused_without_hard() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh stop stop
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "refusing full stop"
}

test_stop_live_hard() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh stoph stop --hard
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "DANGER: stopping entire live stack" || assert_file_contains "$CAPTURE_ERR" "DANGER: stopping entire live stack"
	assert_file_contains "$HARNESS_DOCKER_LOG" "compose"
}

test_stop_local_removes_app_containers() {
	harness_mktemp
	install_mocks "ps_names=unit-backend-start"
	write_minimal_rc
	capture_dssh stop stop
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "Stopped dssh app containers"
}

test_migrate_local_delegates() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc 'dssh_migrate_target=backend'
	capture_dssh mig migrate
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_PROJECT/migrated.txt" "BACKEND_MIGRATE_LOCAL"
}

test_migrate_live() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh mig migrate
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "compose"
}

test_logs_no_containers() {
	harness_mktemp
	install_mocks "ps_names="
	write_minimal_rc
	capture_dssh logs logs
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "No dssh app containers"
}

test_logs_target_local() {
	harness_mktemp
	install_mocks "ps_names=unit-backend"
	write_minimal_rc
	capture_dssh logs logs backend
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "mock-docker-logs"
}

test_logs_rlog_missing() {
	harness_mktemp
	install_mocks
	write_minimal_rc 'dssh_rlog_dir=./.dssh/rlog'
	capture_dssh lr logs rlog
	# follow_rlog_logs fails if no latest.txt
	assert_exit "$CAPTURE_RC" 1
}

run_all_tests_in_file
