#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

_cleanup_fake_rlog() {
	local proj="$1"
	if [[ -f "$proj/.dssh/rlog/rlog.pid" ]]; then
		kill "$(tr -d '[:space:]' <"$proj/.dssh/rlog/rlog.pid")" 2>/dev/null || true
	fi
	pkill -f "$proj/fake-rlog.sh" 2>/dev/null || true
	rm -rf "$proj/.dssh/rlog" 2>/dev/null || true
}

_plant_fake_rlog() {
	cat >"$HARNESS_PROJECT/fake-rlog.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "${DSSH_RLOG_DIR:-.}"
echo "$$" >"${DSSH_RLOG_DIR:-.}/rlog.pid"
echo "fake $(date -Is)" >"${DSSH_RLOG_DIR:-.}/latest.txt"
sleep 60
EOF
	chmod +x "$HARNESS_PROJECT/fake-rlog.sh"
}

test_rlog_status_off() {
	harness_mktemp
	install_mocks
	write_minimal_rc 'dssh_rlog_dir=./.dssh/rlog'
	capture_dssh rs rlog status
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog off"
}

test_rlog_on_off_toggle() {
	harness_mktemp
	install_mocks
	_plant_fake_rlog
	write_minimal_rc "dssh_rlog_script=./fake-rlog.sh
dssh_rlog_dir=./.dssh/rlog
dssh_rlog_interval=60
dssh_rlog_containers=backend"
	capture_dssh on rlog on
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog on"
	capture_dssh st rlog status
	assert_file_contains "$CAPTURE_OUT" "rlog on"
	capture_dssh off rlog off
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog off"
	_cleanup_fake_rlog "$HARNESS_PROJECT"
}

test_rlog_toggle_empty() {
	harness_mktemp
	install_mocks
	_plant_fake_rlog
	write_minimal_rc "dssh_rlog_script=./fake-rlog.sh
dssh_rlog_dir=./.dssh/rlog"
	capture_dssh tog rlog
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog on"
	capture_dssh tog2 rlog
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "rlog off"
	_cleanup_fake_rlog "$HARNESS_PROJECT"
}

test_rlog_bad_arg() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh bad rlog nonsense
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "Usage: dssh rlog"
}

test_rlog_script_writes_latest() {
	harness_mktemp
	install_mocks "stats_line=c1|1.0%|10MiB / 100MiB|10.00%|0B / 0B|0B / 0B|1"
	local dir="$HARNESS_TMP/rlogdir"
	mkdir -p "$dir"
	# Run real rlog briefly then kill
	DSSH_RLOG_DIR="$dir" DSSH_RLOG_INTERVAL=0.2 DSSH_RLOG_TARGETS="backend=c1" \
		bash "$RLOG_BIN" >/dev/null 2>&1 &
	local pid=$!
	sleep 0.6
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[[ -f "$dir/latest.txt" ]] || fail "rlog did not write latest.txt"
	assert_file_contains "$dir/latest.txt" "pid="
	[[ -f "$dir/history.log" ]] || fail "rlog did not write history.log"
}

test_rnano_usage() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh rn rnano
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "Usage: dssh rnano"
}

test_rnano_missing_host() {
	harness_mktemp
	install_mocks
	write_minimal_rc 'prod_env_path=/tmp/x'
	capture_dssh rn rnano prod_env
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "prod_env_host"
}

test_rnano_missing_key() {
	harness_mktemp
	install_mocks
	write_minimal_rc 'prod_env_host=user@host
prod_env_path=/etc/app/.env
prod_env_key=/no/such/key'
	capture_dssh rn rnano prod_env
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "SSH key not found"
}

test_rnano_invokes_ssh() {
	harness_mktemp
	install_mocks
	local key="$HARNESS_TMP/id_test"
	ssh-keygen -t ed25519 -N '' -f "$key" >/dev/null 2>&1
	write_minimal_rc "prod_env_host=user@example
prod_env_path=/etc/app/.env
prod_env_key=$key"
	capture_dssh rn rnano prod_env
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_SSH_LOG" "ssh"
	assert_file_contains "$HARNESS_SSH_LOG" "nano"
}

test_rnano_soft_backup_after_edit() {
	harness_mktemp
	install_mocks
	local key="$HARNESS_TMP/id_test"
	ssh-keygen -t ed25519 -N '' -f "$key" >/dev/null 2>&1
	write_minimal_rc "prod_env_host=user@example
prod_env_path=/etc/app/.env
prod_env_key=$key
prod_env_repo=/opt/app
dssh_env_backup_relpath=ops/tooling/env-backup.sh"
	capture_dssh rn rnano prod_env
	assert_exit "$CAPTURE_RC" 0
	# Second ssh for backup
	local lines
	lines="$(wc -l <"$HARNESS_SSH_LOG")"
	[[ "$lines" -ge 2 ]] || fail "expected backup ssh call; log=$(cat "$HARNESS_SSH_LOG")"
}

test_install_links_dssh_and_rlog() {
	harness_mktemp
	install_mocks
	local dest="$HARNESS_TMP/destbin"
	mkdir -p "$dest"
	DEST_DIR="$dest" "$INSTALL_SH" >"$HARNESS_TMP/install.out"
	[[ -L "$dest/dssh" ]] || fail "dssh symlink missing"
	[[ -L "$dest/rlog.sh" ]] || fail "rlog.sh symlink missing"
	assert_eq "$(readlink -f "$dest/dssh")" "$(readlink -f "$DSSH_BIN")"
	assert_eq "$(readlink -f "$dest/rlog.sh")" "$(readlink -f "$RLOG_BIN")"
	assert_file_contains "$HARNESS_TMP/install.out" "installed:"
}

test_tool_dir_resolves_through_symlink() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	local dest="$HARNESS_TMP/destbin"
	mkdir -p "$dest"
	ln -sfn "$DSSH_BIN" "$dest/dssh"
	# gpu-probe via symlink must still find sibling rlog path logic / run
	capture via symlink:
	local out rc=0
	set +e
	out="$(env DSSH_PROJECT_ROOT="$HARNESS_PROJECT" PATH="$HARNESS_BIN:/usr/bin:/bin" "$dest/dssh" gpu-probe 2>/dev/null)"
	rc=$?
	set -e
	assert_exit "$rc" 0
	assert_contains "$out" "gpu-probe"
}

run_all_tests_in_file
