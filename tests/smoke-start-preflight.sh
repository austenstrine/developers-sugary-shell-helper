#!/usr/bin/env bash
# Smoke: configurable start/restart preflight (detect/apply via .dsshrc).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dssh="$root/bin/dssh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -x "$dssh" ]] || fail "missing executable $dssh"

# Target resolution requires a Dockerfile even when only _start_local runs.
printf 'FROM scratch\n' >"$tmp/Dockerfile"

write_rc() {
  local detect="$1"
  local apply="$2"
  cat >"$tmp/.dsshrc" <<EOF
dssh_targets=backend
backend=./
backend_name=smoke-preflight-backend
backend_start_local='echo START_OK > "$tmp/started.txt"'
backend_start_preflight_detect=$detect
backend_start_preflight_apply=$apply
backend_start_preflight_prompt='Detected a pending step. Run it now? (y/N)'
backend_start_preflight_timeout=1
backend_start_preflight_default=N
dssh_mode=local
dssh_gpus=off
EOF
}

# --- Case 1: no detect/apply → start unchanged ---
cat >"$tmp/.dsshrc" <<EOF
dssh_targets=backend
backend=./
backend_name=smoke-preflight-backend
backend_start_local='echo START_OK > "$tmp/started.txt"'
dssh_mode=local
dssh_gpus=off
EOF
rm -f "$tmp/started.txt" "$tmp/applied.txt"
err1="$tmp/err1.txt"
if ! env DSSH_PROJECT_ROOT="$tmp" DSSH_MODE=local \
  "$dssh" backend start -nobuild </dev/null >"$tmp/out1.txt" 2>"$err1"; then
  fail "start without preflight exited non-zero"
fi
grep -q START_OK "$tmp/started.txt" || fail "start did not run without preflight"
! grep -qi 'pending step' "$err1" || fail "unexpected prompt without detect/apply"
pass "no detect/apply → start unchanged"

# --- Case 2: detect exit 0 → no prompt, start continues ---
write_rc "'true'" "'echo APPLIED > \"$tmp/applied.txt\"'"
rm -f "$tmp/started.txt" "$tmp/applied.txt"
err2="$tmp/err2.txt"
if ! env DSSH_PROJECT_ROOT="$tmp" DSSH_MODE=local \
  "$dssh" backend start -nobuild </dev/null >"$tmp/out2.txt" 2>"$err2"; then
  fail "start with detect-ok exited non-zero"
fi
grep -q START_OK "$tmp/started.txt" || fail "start did not run when detect ok"
[[ ! -f "$tmp/applied.txt" ]] || fail "apply ran when detect was ok"
! grep -qi 'pending step\|Skipping pending\|Running pending' "$err2" \
  || fail "unexpected prompt when detect ok"
pass "detect exit 0 → no prompt, start continues"

# --- Case 3: detect fails, timeout → default N, start continues, apply skipped ---
write_rc "'false'" "'echo APPLIED > \"$tmp/applied.txt\"'"
rm -f "$tmp/started.txt" "$tmp/applied.txt"
err3="$tmp/err3.txt"
if ! env DSSH_PROJECT_ROOT="$tmp" DSSH_MODE=local \
  "$dssh" backend start -nobuild </dev/null >"$tmp/out3.txt" 2>"$err3"; then
  fail "start with detect-fail+timeout exited non-zero"
fi
grep -qi 'pending step' "$err3" || fail "expected prompt on detect fail"
grep -qi 'timeout' "$err3" || fail "expected timeout note; got: $(cat "$err3")"
grep -qi 'Skipping pending' "$err3" || fail "expected skip message"
grep -q START_OK "$tmp/started.txt" || fail "start did not continue after N/timeout"
[[ ! -f "$tmp/applied.txt" ]] || fail "apply ran on default N"
pass "detect fail + timeout → N, start continues, no apply"

# --- Case 4: detect fails, answer y → apply runs, then start ---
write_rc "'false'" "'echo APPLIED > \"$tmp/applied.txt\"'"
rm -f "$tmp/started.txt" "$tmp/applied.txt"
err4="$tmp/err4.txt"
if ! env DSSH_PROJECT_ROOT="$tmp" DSSH_MODE=local \
  "$dssh" backend start -nobuild >"$tmp/out4.txt" 2>"$err4" <<<"y"; then
  fail "start with y confirmation exited non-zero"
fi
grep -qi 'Running pending' "$err4" || fail "expected apply message; got: $(cat "$err4")"
grep -q APPLIED "$tmp/applied.txt" || fail "apply did not run on y"
grep -q START_OK "$tmp/started.txt" || fail "start did not continue after apply"
pass "detect fail + y → apply then start"

echo "All start-preflight smokes passed."
