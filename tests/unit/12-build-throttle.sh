#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_help_mentions_buildkit_throttle() {
	harness_mktemp
	install_mocks
	write_minimal_rc
	capture_dssh h -h
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "BUILDKIT_MAX_PARALLELISM"
	assert_file_contains "$CAPTURE_OUT" "COMPOSE_PARALLEL_LIMIT"
}

test_build_uses_classic_docker_without_throttle_builder() {
	harness_mktemp
	install_mocks "image_inspect=0
buildx_throttle=0"
	write_minimal_rc
	export DSSH_BUILDKIT_THROTTLE_BUILDER=1
	export DSSH_ENSURE_THROTTLE_BUILDER=0
	unset DSSH_BUILDKIT_BUILDER BUILDX_BUILDER || true
	capture_dssh b backend build
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "docker build "
	assert_not_file_contains "$HARNESS_DOCKER_LOG" "buildx build"
}

test_build_uses_buildx_when_throttle_builder_present() {
	harness_mktemp
	install_mocks "image_inspect=0
buildx_throttle=1"
	write_minimal_rc
	export DSSH_BUILDKIT_THROTTLE_BUILDER=1
	export DSSH_ENSURE_THROTTLE_BUILDER=0
	unset DSSH_BUILDKIT_BUILDER BUILDX_BUILDER || true
	capture_dssh b backend build
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$HARNESS_DOCKER_LOG" "buildx build"
}

test_live_start_nobuild_still_ok() {
	harness_mktemp
	install_mocks "inspect_compose_service=api
compose_ps=NAME"
	write_live_rc
	export DSSH_MODE=live
	unset DSSH_IGNORE_STALL || true
	capture_dssh s backend start -nobuild
	assert_exit "$CAPTURE_RC" 0
}

run_all_tests_in_file
