#!/usr/bin/env bash
# Shared unit-test helpers for dssh / rlog.
# shellcheck disable=SC2034
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
DSSH_BIN="${DSSH_BIN:-$REPO_ROOT/bin/dssh}"
RLOG_BIN="${RLOG_BIN:-$REPO_ROOT/bin/rlog.sh}"
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/install.sh}"

HARNESS_TMP=""
HARNESS_BIN=""
HARNESS_PROJECT=""
HARNESS_DOCKER_LOG=""
HARNESS_SSH_LOG=""

# Optional shared results file (set by run-unit.sh): name|status|ms|detail
UNIT_RESULTS_FILE="${UNIT_RESULTS_FILE-}"

fail() {
	echo "FAIL: $*" >&2
	return 1
}

assert_eq() {
	local got="$1" want="$2" msg="${3:-assert_eq}"
	if [[ "$got" != "$want" ]]; then
		fail "$msg: got '$got' want '$want'"
		return 1
	fi
}

assert_contains() {
	local hay="$1" needle="$2" msg="${3:-assert_contains}"
	if ! grep -Fq -- "$needle" <<<"$hay"; then
		fail "$msg: missing '$needle' in: $hay"
		return 1
	fi
}

assert_file_contains() {
	local file="$1" needle="$2" msg="${3:-assert_file_contains}"
	[[ -f "$file" ]] || { fail "$msg: missing file $file"; return 1; }
	if ! grep -Fq -- "$needle" "$file"; then
		fail "$msg: missing '$needle' in $file ($(cat "$file"))"
		return 1
	fi
}

assert_not_file_contains() {
	local file="$1" needle="$2" msg="${3:-assert_not_file_contains}"
	[[ -f "$file" ]] || return 0
	if grep -Fq -- "$needle" "$file"; then
		fail "$msg: unexpected '$needle' in $file"
		return 1
	fi
}

harness_mktemp() {
	HARNESS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dssh-unit.XXXXXX")"
	HARNESS_BIN="$HARNESS_TMP/bin"
	HARNESS_PROJECT="$HARNESS_TMP/project"
	HARNESS_DOCKER_LOG="$HARNESS_TMP/docker.log"
	HARNESS_SSH_LOG="$HARNESS_TMP/ssh.log"
	mkdir -p "$HARNESS_BIN" "$HARNESS_PROJECT"
	: >"$HARNESS_DOCKER_LOG"
	: >"$HARNESS_SSH_LOG"
	# shellcheck disable=SC2064
	trap "rm -rf '$HARNESS_TMP'" EXIT
}

install_mocks() {
	local scenario="${1-}"
	local scenario_file="$HARNESS_TMP/docker.scenario"
	if [[ -n "$scenario" ]]; then
		printf '%s\n' "$scenario" >"$scenario_file"
	else
		: >"$scenario_file"
	fi
	export MOCK_DOCKER_LOG="$HARNESS_DOCKER_LOG"
	export MOCK_DOCKER_SCENARIO="$scenario_file"
	export MOCK_SSH_LOG="$HARNESS_SSH_LOG"
	cp "$TESTS_ROOT/lib/mock-docker.sh" "$HARNESS_BIN/docker"
	chmod +x "$HARNESS_BIN/docker"
	cat >"$HARNESS_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "ssh $*" >>"${MOCK_SSH_LOG:?}"
exit 0
EOF
	chmod +x "$HARNESS_BIN/ssh"
	# Prefer mocks; keep core utils.
	export PATH="$HARNESS_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

set_docker_scenario() {
	printf '%s\n' "$1" >"$MOCK_DOCKER_SCENARIO"
}

plant_nvidia_smi() {
	local rc="${1:-0}"
	cat >"$HARNESS_BIN/nvidia-smi" <<EOF
#!/bin/sh
exit $rc
EOF
	chmod +x "$HARNESS_BIN/nvidia-smi"
}

write_dockerfile() {
	local dest="${1:-$HARNESS_PROJECT/Dockerfile}"
	mkdir -p "$(dirname "$dest")"
	printf 'FROM scratch\nWORKDIR /app\n' >"$dest"
}

write_minimal_rc() {
	local extra="${1-}"
	cat >"$HARNESS_PROJECT/.dsshrc" <<EOF
dssh_targets=backend,frontend
dssh_mode=local
dssh_gpus=off
backend=./apps/backend
backend_name=unit-backend
backend_aliases=api
backend_start='echo BACKEND_START'
backend_start_local='echo BACKEND_START_LOCAL > "$HARNESS_PROJECT/started.txt"'
backend_migrate='echo BACKEND_MIGRATE'
backend_migrate_local='echo BACKEND_MIGRATE_LOCAL > "$HARNESS_PROJECT/migrated.txt"'
frontend=./apps/frontend
frontend_name=unit-frontend
frontend_aliases=web
frontend_start='echo FRONTEND_START'
frontend_start_local='echo FRONTEND_START_LOCAL'
$extra
EOF
	mkdir -p "$HARNESS_PROJECT/apps/backend" "$HARNESS_PROJECT/apps/frontend"
	write_dockerfile "$HARNESS_PROJECT/apps/backend/Dockerfile"
	write_dockerfile "$HARNESS_PROJECT/apps/frontend/Dockerfile"
	printf 'FROM scratch\n' >"$HARNESS_PROJECT/Dockerfile"
}

write_live_rc() {
	local extra="${1-}"
	cat >"$HARNESS_PROJECT/.dsshrc" <<EOF
dssh_targets=backend,frontend,proxy
dssh_mode=live
dssh_gpus=off
dssh_live_compose_file=docker-compose.yml
dssh_live_compose_prod_file=docker-compose.prod.yml
dssh_live_detect_targets=backend,frontend,proxy
dssh_live_app_services=api,web,nginx
dssh_live_infra_services=postgres,redis
dssh_live_container_prefix=unit-
dssh_live_migrate_service=api
dssh_live_migrate_cmd='echo LIVE_MIGRATE'
dssh_live_health_containers=unit-api,unit-web
dssh_live_health_url=
dssh_publish_local='echo PUBLISH_OK > "$HARNESS_PROJECT/published.txt"'
backend=./apps/backend
backend_service=api
backend_name=unit-api
backend_aliases=api
backend_start='echo BACKEND_START'
frontend=./apps/frontend
frontend_service=web
frontend_name=unit-web
frontend_aliases=web
proxy=./ops/proxy
proxy_service=nginx
proxy_name=unit-nginx
proxy_aliases=nginx
$extra
EOF
	mkdir -p "$HARNESS_PROJECT/apps/backend" "$HARNESS_PROJECT/apps/frontend" "$HARNESS_PROJECT/ops/proxy"
	write_dockerfile "$HARNESS_PROJECT/apps/backend/Dockerfile"
	write_dockerfile "$HARNESS_PROJECT/apps/frontend/Dockerfile"
	write_dockerfile "$HARNESS_PROJECT/ops/proxy/Dockerfile"
	printf 'services: {}\n' >"$HARNESS_PROJECT/docker-compose.yml"
	printf 'services: {}\n' >"$HARNESS_PROJECT/docker-compose.prod.yml"
}

run_dssh() {
	env DSSH_PROJECT_ROOT="$HARNESS_PROJECT" \
		"${DSSH_MODE:+DSSH_MODE=$DSSH_MODE}" \
		"$DSSH_BIN" "$@"
}

capture_dssh() {
	local tag="$1"
	shift
	local out="$HARNESS_TMP/${tag}.out"
	local err="$HARNESS_TMP/${tag}.err"
	local rc=0
	set +e
	# Preserve DSSH_MODE if set by caller.
	env DSSH_PROJECT_ROOT="$HARNESS_PROJECT" \
		${DSSH_MODE:+DSSH_MODE="$DSSH_MODE"} \
		"$DSSH_BIN" "$@" >"$out" 2>"$err"
	rc=$?
	set -e
	printf '%s' "$rc" >"$HARNESS_TMP/${tag}.rc"
	export CAPTURE_OUT="$out" CAPTURE_ERR="$err" CAPTURE_RC="$rc"
	return 0
}

record_result() {
	local name="$1" status="$2" ms="$3" detail="${4-}"
	if [[ -n "$UNIT_RESULTS_FILE" ]]; then
		printf '%s|%s|%s|%s\n' "$name" "$status" "$ms" "$detail" >>"$UNIT_RESULTS_FILE"
	fi
}

run_named_test() {
	local name="$1"
	local fn="$2"
	local start end ms rc=0
	# Prefer epoch ms; fall back to seconds*1000.
	if start="$(date +%s%3N 2>/dev/null)"; then
		:
	else
		start="$(date +%s)000"
	fi
	set +e
	("$fn")
	rc=$?
	set -e
	if end="$(date +%s%3N 2>/dev/null)"; then
		:
	else
		end="$(date +%s)000"
	fi
	ms=$((10#${end} - 10#${start}))
	[[ "$ms" -ge 0 ]] || ms=0
	if [[ "$rc" -eq 0 ]]; then
		record_result "$name" PASS "$ms" ""
		echo "  ✓ $name (${ms}ms)"
	else
		record_result "$name" FAIL "$ms" "exit $rc"
		echo "  ✗ $name (${ms}ms)"
	fi
	return 0
}

# Discover and run every test_* function defined in the current shell.
run_all_tests_in_file() {
	local fn
	while IFS= read -r fn; do
		[[ "$fn" == test_* ]] || continue
		run_named_test "$fn" "$fn"
	done < <(compgen -A function | grep '^test_' | sort)
}
