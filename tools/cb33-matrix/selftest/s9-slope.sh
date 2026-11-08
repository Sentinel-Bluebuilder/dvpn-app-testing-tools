#!/usr/bin/env bash
# ─── Selftest: S9's resource verdict catches a planted leak and passes a flat daemon (FAN 11-08) ───
# Offline: synthetic s9-resources.tsv series, no network, no daemon. Usage (from cb33-matrix/): bash selftest/s9-slope.sh
set -u
cd "$(dirname "$0")/.." || exit 2
. lib/common.sh; . suites/S9.sh
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
fails=0
series() { # $1 mem KiB/cycle, $2 handles/cycle ("-" = not sampled), $3 samples
  printf 'cycle\tmem_kib\thandles\n' > "$OUT/s9-resources.tsv"
  local i k
  for i in $(seq 0 $(( $3 - 1 ))); do
    k=$(( i * 10 ))
    printf '%s\t%s\t%s\n' "$k" "$([ "$1" = - ] && echo - || echo $(( 60000 + k * $1 + (i % 2) * 300 )))" \
      "$([ "$2" = - ] && echo - || echo $(( 40 + k * $2 + i % 2 )))" >> "$OUT/s9-resources.tsv"
  done
}
expect() { # $1 label, $2 expected rc, $3 row verdict expected for memory, $4 for handles
  : > "$OUT/results.tsv"; SCENARIO_FAILED=0
  s9_resources_verdict; local rc=$?
  local m h; m=$(awk -F'\t' '$5 == "s9-memory" {print $6}' "$OUT/results.tsv"); h=$(awk -F'\t' '$5 == "s9-handles" {print $6}' "$OUT/results.tsv")
  if [ "$rc" = "$2" ] && [ "$m" = "$3" ] && [ "$h" = "$4" ]; then echo "ok   $1: rc $rc memory $m handles $h"
  else echo "FAIL $1: rc $rc (want $2) memory $m (want $3) handles $h (want $4)"; fails=$((fails + 1)); fi
}
series 0 0 6;   expect "flat daemon" 0 PASS PASS
series 900 1 6; expect "planted leak (900 KiB + 1 handle per cycle)" 1 FAIL FAIL
series 900 0 6; expect "memory leak only" 1 FAIL PASS
series - - 6;   expect "adapter without hooks" 0 SKIP SKIP
series 0 0 3;   expect "too few samples after the warm-up" 0 SKIP SKIP
# The live Android cb33f series: a one-off warm-up jump, then flat memory and leaking handles.
printf 'cycle\tmem_kib\thandles\n0\t63488\t14\n10\t154880\t20\n20\t165376\t31\n30\t165760\t40\n40\t166912\t48\n50\t167040\t57\n' > "$OUT/s9-resources.tsv"
expect "warm-up jump is not a leak, handle growth is (cb33f)" 1 PASS FAIL
[ "$fails" = 0 ] && echo "s9-slope selftest: PASS" || { echo "s9-slope selftest: $fails FAILED"; exit 1; }
