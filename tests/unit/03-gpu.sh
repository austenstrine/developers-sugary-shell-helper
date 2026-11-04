#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

test_gpu_probe_no_nvidia_cpu_only() {
	harness_mktemp
	install_mocks "has_nvidia_runtime=0
has_alpine=1
gpu_attach=fail"
	write_minimal_rc 'dssh_gpus=auto'
	# Ensure no nvidia-smi in mock bin
	rm -f "$HARNESS_BIN/nvidia-smi"
	capture_dssh gp gpu-probe
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "dssh gpu-probe: cpu-only"
}

test_gpu_probe_off() {
	harness_mktemp
	install_mocks "has_nvidia_runtime=1
has_alpine=1
gpu_attach=ok"
	plant_nvidia_smi 0
	write_minimal_rc 'dssh_gpus=off'
	capture_dssh gp gpu-probe
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "dssh gpu-probe: cpu-only"
}

test_gpu_probe_attach_fail_warns() {
	harness_mktemp
	install_mocks "has_nvidia_runtime=1
has_alpine=1
gpu_attach=fail"
	plant_nvidia_smi 0
	write_minimal_rc 'dssh_gpus=auto'
	capture_dssh gp gpu-probe
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "dssh gpu-probe: cpu-only"
	assert_file_contains "$CAPTURE_ERR" "continuing cpu-only"
}

test_gpu_probe_attach_ok() {
	harness_mktemp
	install_mocks "has_nvidia_runtime=1
has_alpine=1
gpu_attach=ok"
	plant_nvidia_smi 0
	write_minimal_rc 'dssh_gpus=auto'
	capture_dssh gp gpu-probe
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "dssh gpu-probe: --gpus all"
}

test_gpu_probe_no_probe_image_warns() {
	harness_mktemp
	install_mocks "has_nvidia_runtime=1
has_alpine=0
has_hello=0
gpu_attach=fail"
	plant_nvidia_smi 0
	write_minimal_rc 'dssh_gpus=auto'
	capture_dssh gp gpu-probe
	assert_exit "$CAPTURE_RC" 0
	assert_file_contains "$CAPTURE_OUT" "cpu-only"
	assert_file_contains "$CAPTURE_ERR" "no local alpine/hello-world"
}

test_gpu_setup_fails_without_nvidia_smi() {
	harness_mktemp
	install_mocks
	# Shadow any host nvidia-smi with a failing stub (PATH prefers HARNESS_BIN).
	plant_nvidia_smi 1
	write_minimal_rc
	capture_dssh gs gpu-setup
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "nvidia-smi"
}

test_gpu_setup_fails_without_tty() {
	harness_mktemp
	install_mocks
	plant_nvidia_smi 0
	# sudo -n will fail; no TTY → soft message
	write_minimal_rc
	capture_dssh gs gpu-setup </dev/null
	assert_exit "$CAPTURE_RC" 1
	assert_file_contains "$CAPTURE_ERR" "gpu-setup needs sudo"
}

run_all_tests_in_file
