#!/usr/bin/env bash
# ─── Soak: one connection held for N minutes, sampled every 10 s (FAN 11-08, final-bits pass) ───
# Per sample: status call latency + line, egress IP, dvpnd RSS and fd count. PASS when every sample is
# connected and egresses through the node, no status call takes >= 1 s more than 1 % of the time, and
# dvpnd memory/fds stay flat (last-quarter mean vs first-quarter mean: RSS < +20 %, fds < +5).
# Usage: bash soak.sh <label> [minutes] [protocol]
set -uo pipefail
LABEL=${1:?label}; MINUTES=${2:-30}; PROTO=${3:-wireguard}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HOME/soak/$LABEL; mkdir -p "$OUT"; SCEN_DIR=$OUT
NODE=${SOAK_NODE:-node-3}
say() { echo "$*"; }
tx_gap() { sleep "${TX_GAP:-7}"; }
deadman_start() { :; }; deadman_stop() { :; }
. "$HERE/lib/nodes.sh"
# SOAK_PLATFORM picks the adapter (default android, FAN's first user); linux = TLX final-bits soak on 0.1.15.
. "$HERE/plat/${SOAK_PLATFORM:-android}.sh"
for try in 1 2 3; do plat_init >/dev/null && { declare -F plat_daemon_running > /dev/null && ! plat_daemon_running && plat_daemon_start > /dev/null; true; } && break; [ "$try" = 3 ] && { echo "plat_init failed 3x"; exit 2; }; sleep 30; done
RUN_START_CHANNELS=$(declare -F sess_rows > /dev/null && sess_rows | awk '{print $3}' | sort -u | tr '\n' ' '); RUN_NEW_CHANNELS=''
OUT_SAVE=$OUT; node_resolve || { echo "could not resolve $NODE"; exit 2; }; OUT=$OUT_SAVE
declare -A E; while read -r p a _; do E[$p]=$a; done < "$OUT/node-entries.txt"
NODE_ID=${E[$PROTO]:-}; [ -n "$NODE_ID" ] || { echo "no $PROTO entry"; exit 2; }
plat_connect "$PROTO" > "$OUT/connect.txt" 2>&1 || { echo "connect $PROTO failed"; cat "$OUT/connect.txt"; exit 1; }
sleep 10
NODE_EG=$(plat_egress); echo "connected $PROTO, egress $NODE_EG"
printf 'epoch\tms\tegress\trss_kb\tfds\tline\n' > "$OUT/samples.tsv"
end=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  t0=$(date +%s%3N); line=$(plat_status_line 2>/dev/null | head -1); ms=$(( $(date +%s%3N) - t0 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ms" "$(plat_egress)" "$(plat_daemon_mem)" "$(plat_daemon_handles)" "$line" >> "$OUT/samples.tsv"
  sleep 10
done
plat_disconnect > "$OUT/disconnect.txt" 2>&1
awk -F'\t' -v node="$NODE_EG" 'NR > 1 { n++; ms[n] = $2; rss[n] = $4; fd[n] = $5
    if ($3 != node || $6 !~ /state=active/ || $6 ~ /reconnecting/) bad++
    if ($2 >= 1000) slow++ }
  END { q = int(n / 4); if (q < 1) q = 1
    for (i = 1; i <= q; i++) { r1 += rss[i]; f1 += fd[i] }
    for (i = n - q + 1; i <= n; i++) { r2 += rss[i]; f2 += fd[i] }
    r1 /= q; r2 /= q; f1 /= q; f2 /= q
    ok = (bad == 0 && slow <= n / 100 && r2 < r1 * 1.2 && f2 - f1 < 5)
    printf "%s soak %d samples: off-tunnel/not-active=%d slow(>=1s)=%d rss %.0f->%.0f KiB fds %.1f->%.1f\n",
      ok ? "PASS" : "FAIL", n, bad + 0, slow + 0, r1, r2, f1, f2 }' "$OUT/samples.tsv" | tee "$OUT/verdict.txt"
plat_close_run_channels
