#!/usr/bin/env bash
# ─── Android dvpnd fd growth per connect/disconnect cycle (FAN 11-08; TLX2's Linux method, ~/g10/s6/fdleak.sh) ───
# Per cycle: connect (protocol rotates), disconnect, then snapshot every fd of the dvpnd process: its target
# (socket:[inode], pipe:[inode], anon_inode:…, /dev/tun, a file) plus, for sockets, the matching /proc/net row.
# Writes ~/fd-cycles/<label>/cycle-<k>.txt and counts.tsv (cycle, total, by kind). Diff first vs last to name the leak.
# Usage: bash fd-cycles.sh <label> [cycles] [protocols]
set -uo pipefail
LABEL=${1:?label}; CYCLES=${2:-8}; read -r -a PROTOS <<<"${3:-wireguard}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HOME/fd-cycles/$LABEL; mkdir -p "$OUT"; SCEN_DIR=$OUT
NODE=${FD_NODE:-node-3}
say() { echo "$*"; }
tx_gap() { sleep "${TX_GAP:-7}"; }
deadman_start() { :; }; deadman_stop() { :; }
. "$HERE/lib/nodes.sh"
. "$HERE/plat/android.sh"
# Right after an APK install the app needs a while before plat_init passes (b2 11-08: failed at +1 min, fine at +5).
for try in 1 2 3; do plat_init >/dev/null && break; [ "$try" = 3 ] && { echo "plat_init failed 3x"; exit 2; }; sleep 30; done
RUN_START_CHANNELS=$(sess_rows | awk '{print $3}' | sort -u | tr '\n' ' '); RUN_NEW_CHANNELS=''
OUT_SAVE=$OUT; node_resolve || { echo "could not resolve $NODE"; exit 2; }; OUT=$OUT_SAVE
declare -A E; while read -r p a _; do E[$p]=$a; done < "$OUT/node-entries.txt"
snap() { # $1 file
  local pid; pid=$(adb shell pidof sentinel-dvpnd | tr -d '\r' | awk '{print $1}')
  [ -n "$pid" ] || { echo "no dvpnd" > "$1"; return; }
  su0 "ls -l /proc/$pid/fd" | tr -d '\r' | awk 'NR > 1 {print $(NF-2), $NF}' | sort -n > "$1.raw"
  # Socket inodes → their /proc/net table row (tcp/udp/unix/netlink), so a leak names its peer.
  su0 "cat /proc/$pid/net/tcp /proc/$pid/net/tcp6 /proc/$pid/net/udp /proc/$pid/net/udp6" | tr -d '\r' > "$1.net"
  su0 "cat /proc/$pid/net/unix" | tr -d '\r' > "$1.unix"
  awk 'NR == FNR { if ($10 ~ /^[0-9]+$/) net[$10] = $2 " -> " $3 " st=" $4; next }
       { t = $2; n = ""; if (match(t, /socket:\[[0-9]+\]/)) { i = substr(t, 9, length(t) - 9); n = (i in net) ? net[i] : "(unix/netlink/other)" } print $1, t, n }' \
    "$1.net" "$1.raw" > "$1"
  echo "$pid"
}
kinds() { awk '{t = $2; sub(/\[.*/, "", t); sub(/^\/data\/.*/, "file", t); c[t]++} END {for (k in c) printf "%s=%d ", k, c[k]}' "$1"; }
printf 'cycle\tpid\ttotal\tkinds\n' > "$OUT/counts.tsv"
pid=$(snap "$OUT/cycle-0.txt"); printf '0\t%s\t%s\t%s\n' "$pid" "$(grep -c . "$OUT/cycle-0.txt")" "$(kinds "$OUT/cycle-0.txt")" | tee -a "$OUT/counts.tsv"
for k in $(seq 1 "$CYCLES"); do
  p=${PROTOS[$(( (k - 1) % ${#PROTOS[@]} ))]}; NODE_ID=${E[$p]:-}
  [ -n "$NODE_ID" ] || { echo "no $p entry"; continue; }
  plat_connect "$p" >/dev/null || echo "cycle $k: connect $p failed"
  sleep 5; plat_disconnect >/dev/null 2>&1; sleep 8
  pid=$(snap "$OUT/cycle-$k.txt")
  printf '%s\t%s\t%s\t%s\n' "$k" "$pid" "$(grep -c . "$OUT/cycle-$k.txt")" "$(kinds "$OUT/cycle-$k.txt")" | tee -a "$OUT/counts.tsv"
done
echo "== new in the last cycle vs cycle 1 (by target kind + peer):"
diff <(awk '{t = $2; sub(/[0-9]+/, "N", t); print t, $3, $4, $5, $6}' "$OUT/cycle-1.txt" | sort | uniq -c) \
     <(awk '{t = $2; sub(/[0-9]+/, "N", t); print t, $3, $4, $5, $6}' "$OUT/cycle-$CYCLES.txt" | sort | uniq -c) | tee "$OUT/diff.txt"
plat_close_run_channels
