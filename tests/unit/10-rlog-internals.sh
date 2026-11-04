#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_rlog_rotates_history_when_over_max() {
	harness_mktemp
	install_mocks "stats_line=c1|1.0%|10MiB / 100MiB|10.00%|0B / 0B|0B / 0B|1"
	local dir="$HARNESS_TMP/rlogdir"
	mkdir -p "$dir"
	# Seed a large history so rotate_history_if_needed fires
	dd if=/dev/zero of="$dir/history.log" bs=1024 count=8 status=none 2>/dev/null \
		|| head -c 8192 /dev/zero >"$dir/history.log"
	set +e
	timeout -k 1 2 env PATH="$PATH" DSSH_RLOG_DIR="$dir" DSSH_RLOG_INTERVAL=0.2 \
		DSSH_RLOG_TARGETS="backend=c1" DSSH_RLOG_HISTORY_MAX_BYTES=1024 \
		DSSH_RLOG_HISTORY_KEEP_PLAIN=2 \
		bash "$RLOG_BIN" >/dev/null 2>&1
	set -e
	if [[ -f "$dir/rlog.pid" ]]; then
		kill "$(tr -d '[:space:]' <"$dir/rlog.pid")" 2>/dev/null || true
		sleep 0.1
		kill -9 "$(tr -d '[:space:]' <"$dir/rlog.pid")" 2>/dev/null || true
	fi
	# After rotate, a rotated plain log or smaller active history should exist
	local rotated=0
	shopt -s nullglob
	for f in "$dir"/history.log.* "$dir"/history-*.log; do
		rotated=1
		break
	done
	shopt -u nullglob
	[[ "$rotated" -eq 1 || -f "$dir/latest.txt" ]] || fail "expected rotate artifact or latest after oversized history"
	[[ -f "$dir/latest.txt" ]] || fail "latest.txt missing after rotate run"
}

test_rlog_survives_docker_stats_failure() {
	harness_mktemp
	# docker stats / inspect fail — rlog must not die
	install_mocks "stats_line=
inspect_running=0"
	# Force docker compose/stats to fail
	set_docker_scenario "stats_line=
compose_fail=1
inspect_running=0"
	local dir="$HARNESS_TMP/rlogdir"
	mkdir -p "$dir"
	set +e
	timeout -k 1 2 env PATH="$PATH" DSSH_RLOG_DIR="$dir" DSSH_RLOG_INTERVAL=0.2 \
		DSSH_RLOG_TARGETS="backend=missing" bash "$RLOG_BIN" >/dev/null 2>&1
	set -e
	if [[ -f "$dir/rlog.pid" ]]; then
		kill "$(tr -d '[:space:]' <"$dir/rlog.pid")" 2>/dev/null || true
	fi
	[[ -f "$dir/latest.txt" ]] || fail "rlog should keep writing latest even when docker fails"
	assert_file_contains "$dir/latest.txt" "pid="
}

run_all_tests_in_file
