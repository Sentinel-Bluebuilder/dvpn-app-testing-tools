#!/usr/bin/env bash
# ─── Android status latency triage (FAN 11-08, DIR): harness hop or daemon? ───
# Times three calls side by side, idle and during a 50 MB download through the tunnel:
#   adb   = `adb shell true` (the emulator's adb transport alone, no daemon)
#   relay = `dcli client sessions` (rig CLI → adb forward → phone nc relay → dvpnd), the call S1's status poll makes
#   ver   = `dcli daemon status` (same hop to dvpnd, a handler that never touches sessions/usage)
# Same rise in adb and relay = the transport (harness). relay/ver rise with adb flat = relay or daemon; relay rising
# with ver flat = the sessions handler itself (daemon). Writes ~/status-ab/<label>/{idle,load}.tsv + summary.txt.
# Usage: bash status-ab.sh <label> [protocol]
set -uo pipefail
LABEL=${1:?label}; PROTO=${2:-wireguard}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HOME/status-ab/$LABEL; mkdir -p "$OUT"; SCEN_DIR=$OUT
NODE=${AB_NODE:-node-4}
say() { echo "$*"; }
tx_gap() { sleep "${TX_GAP:-7}"; }
deadman_start() { :; }; deadman_stop() { :; }
. "$HERE/lib/nodes.sh"
. "$HERE/plat/android.sh"
for try in 1 2 3; do plat_init >/dev/null && break; [ "$try" = 3 ] && { echo "plat_init failed 3x"; exit 2; }; sleep 30; done
RUN_START_CHANNELS=$(sess_rows | awk '{print $3}' | sort -u | tr '\n' ' '); RUN_NEW_CHANNELS=''
OUT_SAVE=$OUT; node_resolve || { echo "could not resolve $NODE"; exit 2; }; OUT=$OUT_SAVE
declare -A E; while read -r p a _; do E[$p]=$a; done < "$OUT/node-entries.txt"
NODE_ID=${E[$PROTO]:-}; [ -n "$NODE_ID" ] || { echo "no $PROTO entry"; exit 2; }
ms() { date +%s%3N; }
sample() { # $1 file, $2 seconds
  local end=$(( $(date +%s) + $2 )) a b c d
  while [ "$(date +%s)" -lt "$end" ]; do
    a=$(ms); adb shell true >/dev/null 2>&1; b=$(ms)
    dcli client sessions --instance "$INSTANCE" >/dev/null 2>&1; c=$(ms)
    dcli daemon status >/dev/null 2>&1; d=$(ms)
    printf '%s\t%s\t%s\t%s\n' "$a" $((b - a)) $((c - b)) $((d - c)) >> "$1"
    sleep 0.5
  done
}
printf 'epoch_ms\tadb_ms\trelay_ms\tver_ms\n' | tee "$OUT/idle.tsv" "$OUT/connected.tsv" > "$OUT/load.tsv"
sample "$OUT/idle.tsv" 20
plat_connect "$PROTO" > "$OUT/connect.txt" 2>&1 || { echo "connect $PROTO failed"; cat "$OUT/connect.txt"; exit 1; }
sleep 5
sample "$OUT/connected.tsv" 20
( curl -s -m 120 -o /dev/null -w "%{size_download} %{time_total}" "${CBM_BIG_URL:-https://speed.cloudflare.com/__down?bytes=50000000}" > "$OUT/download.txt" 2>&1 ) &
dl=$!
sleep 1
while kill -0 "$dl" 2>/dev/null; do sample "$OUT/load.tsv" 2; done
plat_disconnect > "$OUT/disconnect.txt" 2>&1
for f in idle connected load; do
  awk -F'\t' -v n="$f" 'NR > 1 { k++; a[k] = $2; r[k] = $3; v[k] = $4; if ($3 >= 1000) slow++ }
    function med(x,   i, j, t, m) { for (i = 1; i <= k; i++) s[i] = x[i]
      for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) if (s[j] < s[i]) { t = s[i]; s[i] = s[j]; s[j] = t }
      m = s[int((k + 1) / 2)]; return m }
    function mx(x,   i, m) { m = 0; for (i = 1; i <= k; i++) if (x[i] > m) m = x[i]; return m }
    END { printf "%-9s n=%3d  adb med %5d max %5d | relay med %5d max %5d (>=1s %d) | version med %5d max %5d\n",
      n, k, med(a), mx(a), med(r), mx(r), slow + 0, med(v), mx(v) }' "$OUT/$f.tsv"
done | tee "$OUT/summary.txt"
echo "download: $(cat "$OUT/download.txt")" | tee -a "$OUT/summary.txt"
plat_close_run_channels
