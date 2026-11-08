#!/usr/bin/env bash
# ─── Selftest: S1 download helper + throttle grading (Q0473, TLX2 11-08) ───
# s1_dl retries once on a short/failed body and logs a visible DL-RETRY row (never silent, DIR). s1_throughput
# grades an upstream throttle (http 429 / 4xx / 5xx) as SKIP "not measured", never PASS and never the slow-link
# FAIL. Usage (from ~/cb33-matrix): bash selftest/s1.sh
#
# Default CBM_DL_URL liveness check (DIR 11-09 - speed.hetzner.de was retired; verify the host from ctl-1 AND a test
# VM before relying on it, want 206 + 52428800 bytes):
#   curl -s -o /dev/null -r 0-52428799 -w '%{http_code} %{size_download} %{speed_download}\n' <url>
# Known good (11-09): https://ash-speed.hetzner.com/100MB.bin, fsn1-speed.hetzner.com/100MB.bin,
# nbg1-speed.hetzner.com/100MB.bin, https://proof.ovh.net/files/100Mb.dat. Dead: speed.hetzner.de (NXDOMAIN).
set -u
cd "$(dirname "$0")/.." || exit 2
. lib/common.sh; . suites/S1.sh

OUT=$(mktemp -d); : > "$OUT/results.tsv"
SUITE=selftest; SCENARIO=s1; PROTO=hysteria2; CBM_WG_RATIO=0; CBM_MIN_MBPS=''; CBM_A_THROUGHPUT=''
fails=0
want() { local name=$1 exp=$2 got=$3; if [ "$got" = "$exp" ]; then echo "ok   $name: $got"; else echo "MISSED $name: got $got, wanted $exp"; fails=$((fails + 1)); fi; }

# ── s1_throughput http grading ──
verdict() { awk -F'\t' -v s="$1" '$3 == s && $5 == "throughput" { v = $6 } END { print v }' "$OUT/results.tsv"; }
SCENARIO=thr-429  SCENARIO_FAILED=0 s1_throughput hysteria2 "1 0.6" 429 >/dev/null 2>&1
want "throttle 429 => throughput SKIP" SKIP "$(verdict thr-429)"
SCENARIO=thr-200  SCENARIO_FAILED=0 s1_throughput hysteria2 "50000000 30" 200 >/dev/null 2>&1
want "http 200 full body => throughput PASS" PASS "$(verdict thr-200)"
# a byte-range download (the default public file is ranged) returns 206 Partial Content, not 200: must be PASS.
SCENARIO=thr-206  SCENARIO_FAILED=0 s1_throughput hysteria2 "52428800 30" 206 >/dev/null 2>&1
want "http 206 ranged body => throughput PASS" PASS "$(verdict thr-206)"
SCENARIO=thr-503  SCENARIO_FAILED=0 s1_throughput hysteria2 "1 0.5" 503 >/dev/null 2>&1
want "upstream 503 => throughput SKIP" SKIP "$(verdict thr-503)"

# ── s1_dl retry + DL-RETRY visibility (stub cbm_download: 1st call short, 2nd full) ──
DL_LOG=$(mktemp "${TMPDIR:-/tmp}/cbm-s1dl.XXXXXX")
DL_CNT=$(mktemp "${TMPDIR:-/tmp}/cbm-s1cnt.XXXXXX")
reset_dl() { echo 0 > "$DL_CNT"; : > "$DL_LOG"; }
# a short-then-full stub. s1_dl calls cbm_download inside $(...) each iteration, so the attempt counter must live in
# a file (a shell var would reset in every command-substitution subshell): attempt 1 -> 1-byte 429, attempt 2 -> full.
cbm_download() {
  local n; n=$(( $(cat "$DL_CNT") + 1 )); echo "$n" > "$DL_CNT"
  if [ "$n" = 1 ] && [ "${CBM_DL_FULL_FIRST:-0}" != 1 ]; then printf '1 0.6 429'; else printf '50000000 30 200'; fi
}

reset_dl; out=$(s1_dl 120 "" http://x/y 2>"$DL_LOG")
want "s1_dl retries => returns the full body" "50000000 30 200" "$out"
want "s1_dl logs a DL-RETRY row (not silent)" 1 "$(grep -c '^DL-RETRY ' "$DL_LOG")"

reset_dl; CBM_DL_FULL_FIRST=1 out=$(s1_dl 120 "" http://x/y 2>"$DL_LOG"); unset CBM_DL_FULL_FIRST
want "s1_dl first-full => no retry"            "50000000 30 200" "$out"
want "s1_dl first-full => no DL-RETRY row"     0 "$(grep -c '^DL-RETRY ' "$DL_LOG")"

rm -rf "$OUT" "$DL_LOG" "$DL_CNT"
[ "$fails" = 0 ] && echo "s1 selftest: all cases as expected" || { echo "s1 selftest: $fails miss(es)"; exit 1; }
