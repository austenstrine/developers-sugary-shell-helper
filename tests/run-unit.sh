#!/usr/bin/env bash
# Fast unit suite for dssh / rlog / install.sh.
# Usage: ./tests/run-unit.sh
# Reports (stable paths): tests/reports/{junit.xml,report.md,summary.json,latest.md,latest-junit.xml}
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${DSSH_TEST_REPORT_DIR:-$ROOT/tests/reports}"
mkdir -p "$REPORT_DIR"

RESULTS_FILE="$(mktemp)"
export UNIT_RESULTS_FILE="$RESULTS_FILE"
trap 'rm -f "$RESULTS_FILE"' EXIT

SUITE_START="$(date -Is)"
SUITE_EPOCH_START="$(date +%s)"

echo "dssh unit suite — $SUITE_START"
echo "repo: $ROOT"
echo

shopt -s nullglob
files=("$ROOT"/tests/unit/*.sh)
if [[ ${#files[@]} -eq 0 ]]; then
	echo "No unit tests under tests/unit/" >&2
	exit 1
fi

for f in "${files[@]}"; do
	echo "== $(basename "$f") =="
	# Each file sources harness, defines test_*, calls run_all_tests_in_file.
	bash "$f" || true
	echo
done

SUITE_EPOCH_END="$(date +%s)"
SUITE_MS=$(( (SUITE_EPOCH_END - SUITE_EPOCH_START) * 1000 ))

UNIT_PASS=0
UNIT_FAIL=0
UNIT_SKIP=0
mapfile -t UNIT_RESULTS <"$RESULTS_FILE" || true
for row in "${UNIT_RESULTS[@]+"${UNIT_RESULTS[@]}"}"; do
	[[ -n "$row" ]] || continue
	IFS='|' read -r _name status _ms _detail <<<"$row"
	case "$status" in
		PASS) UNIT_PASS=$((UNIT_PASS + 1)) ;;
		FAIL) UNIT_FAIL=$((UNIT_FAIL + 1)) ;;
		SKIP) UNIT_SKIP=$((UNIT_SKIP + 1)) ;;
	esac
done
TOTAL=$((UNIT_PASS + UNIT_FAIL + UNIT_SKIP))

md="$REPORT_DIR/report.md"
{
	echo "# dssh unit test report"
	echo
	echo "- Started: $SUITE_START"
	echo "- Finished: $(date -Is)"
	echo "- Duration: ${SUITE_MS}ms"
	echo "- Totals: pass=$UNIT_PASS fail=$UNIT_FAIL skip=$UNIT_SKIP total=$TOTAL"
	echo
	echo "| Test | Status | ms |"
	echo "|------|--------|----|"
	for row in "${UNIT_RESULTS[@]+"${UNIT_RESULTS[@]}"}"; do
		[[ -n "$row" ]] || continue
		IFS='|' read -r name status ms detail <<<"$row"
		echo "| \`$name\` | $status | $ms |"
	done
	echo
	if [[ "$UNIT_FAIL" -eq 0 ]]; then
		echo "Result: PASS"
	else
		echo "Result: FAIL ($UNIT_FAIL failed)"
		echo
		echo "## Failures"
		for row in "${UNIT_RESULTS[@]+"${UNIT_RESULTS[@]}"}"; do
			[[ -n "$row" ]] || continue
			IFS='|' read -r name status ms detail <<<"$row"
			[[ "$status" == FAIL ]] || continue
			echo "- \`$name\`: $detail"
		done
	fi
} >"$md"

junit="$REPORT_DIR/junit.xml"
{
	echo '<?xml version="1.0" encoding="UTF-8"?>'
	echo "<testsuite name=\"dssh-unit\" tests=\"$TOTAL\" failures=\"$UNIT_FAIL\" skipped=\"$UNIT_SKIP\" time=\"$(awk -v m="$SUITE_MS" 'BEGIN{printf "%.3f", m/1000}')\">"
	for row in "${UNIT_RESULTS[@]+"${UNIT_RESULTS[@]}"}"; do
		[[ -n "$row" ]] || continue
		IFS='|' read -r name status ms detail <<<"$row"
		sec="$(awk -v m="$ms" 'BEGIN{printf "%.3f", m/1000}')"
		# Escape XML specials in name/detail
		ename="$(printf '%s' "$name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/"/\&quot;/g')"
		edetail="$(printf '%s' "$detail" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/"/\&quot;/g')"
		echo "  <testcase classname=\"dssh.unit\" name=\"$ename\" time=\"$sec\">"
		if [[ "$status" == FAIL ]]; then
			echo "    <failure message=\"$edetail\"/>"
		elif [[ "$status" == SKIP ]]; then
			echo "    <skipped/>"
		fi
		echo "  </testcase>"
	done
	echo "</testsuite>"
} >"$junit"

json="$REPORT_DIR/summary.json"
cat >"$json" <<EOF
{
  "started": "$SUITE_START",
  "pass": $UNIT_PASS,
  "fail": $UNIT_FAIL,
  "skip": $UNIT_SKIP,
  "total": $TOTAL,
  "duration_ms": $SUITE_MS,
  "report_md": "$md",
  "junit": "$junit"
}
EOF

cp -f "$md" "$REPORT_DIR/latest.md"
cp -f "$junit" "$REPORT_DIR/latest-junit.xml"

echo "Reports:"
echo "  $md"
echo "  $junit"
echo "  $json"
echo
echo "Summary: pass=$UNIT_PASS fail=$UNIT_FAIL skip=$UNIT_SKIP total=$TOTAL (${SUITE_MS}ms)"

[[ "$UNIT_FAIL" -eq 0 ]]
