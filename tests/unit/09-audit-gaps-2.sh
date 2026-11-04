#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_stop_hard_synonym_hard() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh st stop hard
	assert_exit "$CAPTURE_RC" 0
	if ! grep -Fq 'DANGER: stopping entire live stack' "$CAPTURE_OUT" "$CAPTURE_ERR"; then
		fail "expected DANGER for stop hard"
	fi
}

test_stop_hard_synonym_double_dash_all() {
	harness_mktemp
	install_mocks
	write_live_rc
	capture_dssh st stop --all
	assert_exit "$CAPTURE_RC" 0
}

test_stop_hard_empty_services_fails() {
	harness_mktemp
	install_mocks
	write_live_rc 'dssh_live_app_services=
dssh_live_infra_services='
	capture_dssh st stop --hard
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "live stop --hard"
}

test_live_migrate_unset_config() {
	harness_mktemp
	install_mocks
	write_live_rc 'dssh_live_migrate_service=
dssh_live_migrate_cmd='
	capture_dssh mig migrate
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "dssh_live_migrate_service"
}

test_health_url_http_fallback() {
	harness_mktemp
	install_mocks "inspect_running=1"
	cat >"$HARNESS_BIN/curl" <<EOF
#!/bin/sh
echo "curl \$*" >>"$HARNESS_TMP/curl.log"
# First URL (https healthz) fails with 000; http fallback returns 200
case " \$* " in
  *"http://127.0.0.1/healthz-plain"*) printf '200'; exit 0 ;;
  *) printf '000'; exit 0 ;;
esac
EOF
	chmod +x "$HARNESS_BIN/curl"
	write_live_rc 'dssh_live_health_url=https://127.0.0.1/healthz
dssh_live_health_url_http=http://127.0.0.1/healthz-plain'
	capture_dssh h health
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_TMP/curl.log" "healthz-plain"
	assert_file_contains "$CAPTURE_OUT" "HTTP 200"
}

test_health_exec_container_fallback() {
	harness_mktemp
	install_mocks "inspect_running=1"
	# No curl on PATH beyond mocks — remove curl if present in harness bin
	rm -f "$HARNESS_BIN/curl"
	# Put a PATH without system curl if possible by using only harness+bin stubs
	# Keep /bin for shell; plant a curl that is "missing" by not creating it.
	# Use a wrapper env that hides curl: create empty dir ahead of /usr/bin without curl.
	local hide="$HARNESS_TMP/hidecurl"
	mkdir -p "$hide"
	# Copy essential cmds? Simpler: plant curl that always fails code 000 and no url_http,
	# forcing exec path when code empty.
	cat >"$HARNESS_BIN/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
	chmod +x "$HARNESS_BIN/curl"
	write_live_rc 'dssh_live_health_url=
dssh_live_health_exec_container=unit-api
dssh_live_health_exec_url=http://127.0.0.1/healthz'
	capture_dssh h health
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "exec"
	assert_file_contains "$CAPTURE_OUT" "via unit-api"
}

test_rlog_script_absolute_override() {
	harness_mktemp
	install_mocks
	cat >"$HARNESS_TMP/abs-rlog.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "${DSSH_RLOG_DIR:-.}"
echo "$$" >"${DSSH_RLOG_DIR:-.}/rlog.pid"
echo abs-ok >"${DSSH_RLOG_DIR:-.}/latest.txt"
sleep 8
EOF
	chmod +x "$HARNESS_TMP/abs-rlog.sh"
	write_minimal_rc "dssh_rlog_script=$HARNESS_TMP/abs-rlog.sh
dssh_rlog_dir=./.dssh/rlog"
	capture_dssh on rlog on
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog on"
	# nohup start is async — wait briefly for the stub to write latest.txt
	local i=0
	while [[ ! -f "$HARNESS_PROJECT/.dssh/rlog/latest.txt" && "$i" -lt 50 ]]; do
		sleep 0.05
		i=$((i + 1))
	done
	assert_file_contains "$HARNESS_PROJECT/.dssh/rlog/latest.txt" "abs-ok"
	if [[ -f "$HARNESS_PROJECT/.dssh/rlog/rlog.pid" ]]; then
		kill "$(tr -d '[:space:]' <"$HARNESS_PROJECT/.dssh/rlog/rlog.pid")" 2>/dev/null || true
	fi
	pkill -f "$HARNESS_TMP/abs-rlog.sh" 2>/dev/null || true
}

test_local_interactive_shell_invokes_docker() {
	harness_mktemp
	install_mocks "image_inspect=1"
	write_minimal_rc
	# No action → interactive path: detect_shell + run container
	capture_dssh sh backend </dev/null
	assert_exit "$CAPTURE_RC" 0
	# detect_shell does docker run; then run_container does docker run
	assert_file_contains "$HARNESS_DOCKER_LOG" "run"
}

run_all_tests_in_file
