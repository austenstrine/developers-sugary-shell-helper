#!/usr/bin/env bash
# Smoke: GPU discovery failures must not abort dssh (cpu-only fallback).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dssh="$root/bin/dssh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -x "$dssh" ]] || fail "missing executable $dssh"

# Minimal consumer project so dssh finds a root.
cat >"$tmp/.dsshrc" <<'EOF'
dssh_targets=backend
backend=./
backend_name=smoke-backend
dssh_gpus=auto
EOF

bin="$tmp/bin"
mkdir -p "$bin"

# --- Case 1: no nvidia-smi on PATH → cpu-only, exit 0 ---
# Build a PATH that excludes any directory containing nvidia-smi.
path_no_smi=""
IFS=':' read -ra _path_parts <<<"${PATH:-/usr/bin:/bin}"
for _d in "${_path_parts[@]}"; do
  [[ -z "$_d" ]] && continue
  [[ -x "$_d/nvidia-smi" ]] && continue
  if [[ -z "$path_no_smi" ]]; then
    path_no_smi="$_d"
  else
    path_no_smi="$path_no_smi:$_d"
  fi
done
out1="$tmp/out1.txt"
err1="$tmp/err1.txt"
if ! env PATH="$path_no_smi" DSSH_PROJECT_ROOT="$tmp" \
  "$dssh" gpu-probe >"$out1" 2>"$err1"; then
  fail "gpu-probe exited non-zero without nvidia-smi"
fi
grep -qx 'dssh gpu-probe: cpu-only' "$out1" \
  || fail "expected cpu-only when nvidia-smi missing; got: $(cat "$out1")"
pass "no nvidia-smi → cpu-only (exit 0)"

# --- Case 2: nvidia-smi ok + nvidia runtime claimed, but --gpus attach fails ---
cat >"$bin/nvidia-smi" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$bin/nvidia-smi"

real_docker="$(command -v docker || true)"
[[ -n "$real_docker" ]] || fail "docker required for attach-failure smoke"

cat >"$bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Claim nvidia runtime is registered.
if [[ "\${1-}" == "info" ]]; then
  echo nvidia
  exit 0
fi
# Pretend a probe image exists.
if [[ "\${1-}" == "image" && "\${2-}" == "inspect" ]]; then
  exit 0
fi
# Fail any --gpus attach (vendor / device discovery breakage).
for a in "\$@"; do
  if [[ "\$a" == "--gpus" ]]; then
    echo 'Error response from daemon: could not select device driver "" with capabilities: [[gpu]]' >&2
    exit 125
  fi
done
exec $(printf '%q' "$real_docker") "\$@"
EOF
chmod +x "$bin/docker"

out2="$tmp/out2.txt"
err2="$tmp/err2.txt"
if ! env PATH="$bin:/usr/bin:/bin" DSSH_PROJECT_ROOT="$tmp" \
  "$dssh" gpu-probe >"$out2" 2>"$err2"; then
  fail "gpu-probe exited non-zero when --gpus attach fails"
fi
grep -qx 'dssh gpu-probe: cpu-only' "$out2" \
  || fail "expected cpu-only on attach failure; got: $(cat "$out2")"
grep -qi 'continuing cpu-only' "$err2" \
  || fail "expected cpu-only warning on stderr; got: $(cat "$err2")"
pass "nvidia runtime + broken --gpus → warn + cpu-only (exit 0)"

# --- Case 3: dssh_gpus=off forces cpu-only even if GPU would work ---
cat >"$tmp/.dsshrc" <<'EOF'
dssh_targets=backend
backend=./
dssh_gpus=off
EOF
out3="$tmp/out3.txt"
if ! env PATH="$bin:/usr/bin:/bin" DSSH_PROJECT_ROOT="$tmp" \
  "$dssh" gpu-probe >"$out3" 2>/dev/null; then
  fail "gpu-probe exited non-zero with dssh_gpus=off"
fi
grep -qx 'dssh gpu-probe: cpu-only' "$out3" \
  || fail "expected cpu-only with dssh_gpus=off"
pass "dssh_gpus=off → cpu-only (exit 0)"

echo "All GPU soft-fallback smokes passed."
