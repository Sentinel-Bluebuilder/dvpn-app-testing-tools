#!/usr/bin/env bash
# ─── G31 RPC blackhole A/B (FAN 11-08, DIR order): what does a connect do while the chain RPC doesn't answer? ───
# Runs on the Android rig. Per row: drop every packet to the RPC hosts' IPs on the phone (iptables, root), start a
# connect (wireguard, node-3), lift the drop after HOLE_S (default 0 = never during the connect), and record how long
# the connect took, what the CLI said, and what dvpnd logged in between (warn/error lines and their count).
# Usage: bash rpc-hole-ab.sh <label> [rows]   → ~/rpc-hole/<label>.tsv + <label>-<k>.dvpnd.log
set -uo pipefail
LABEL=${1:?label}; ROWS=${2:-2}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HOME/rpc-hole; mkdir -p "$OUT"; SCEN_DIR=$OUT/$LABEL.cli; mkdir -p "$SCEN_DIR"
NODE=${HOLE_NODE:-node-3}
say() { echo "$*"; }
tx_gap() { sleep "${TX_GAP:-7}"; }
deadman_start() { :; }; deadman_stop() { :; }
. "$HERE/lib/nodes.sh"
. "$HERE/plat/android.sh"
plat_init >/dev/null || { echo "plat_init failed"; exit 2; }
RUN_START_CHANNELS=$(sess_rows | awk '{print $3}' | sort -u | tr '\n' ' '); RUN_NEW_CHANNELS=''
OUT_SAVE=$OUT; OUT=$SCEN_DIR; node_resolve || { echo "could not resolve $NODE"; exit 2; }; OUT=$OUT_SAVE
NODE_ID=$(awk '$1 == "wireguard" {print $2; exit}' "$SCEN_DIR/node-entries.txt")
RPC_IPS=$(for h in $APP_HOSTS; do case $h in *solana*|*helius*|*duckdns*|*rpc*) getent ahostsv4 "$h" | awk '{print $1}' ;; esac; done | sort -u | tr '\n' ' ')
echo "build: $(plat_build)  rpc ips: $RPC_IPS" | tee "$OUT/$LABEL.build"
hole() { local a; for a in $RPC_IPS; do su0 "iptables -$1 OUTPUT -d $a -j DROP"; done; }
trap 'hole D 2>/dev/null' EXIT
DLOG_REL=files/logs/dvpnd.log
TSV=$OUT/$LABEL.tsv; printf 'row\tresult\tconnect_ms\tcli_said\twarn_lines\trpc_error_lines\n' > "$TSV"
for k in $(seq 1 "$ROWS"); do
  n0=$(asapp wc -l "$DLOG_REL" 2>/dev/null | awk '{print $1}')
  hole I
  [ "${HOLE_S:-0}" -gt 0 ] && (sleep "$HOLE_S"; hole D) &
  t0=$(date +%s%3N)
  said=$(app connect "$NODE_ID" --basis "$BASIS" --units 1 --yes | tail -2 | tr '\n\t' '  ')
  t1=$(date +%s%3N)
  hole D 2>/dev/null; wait
  asapp tail -n +"$(( ${n0:-0} + 1 ))" "$DLOG_REL" 2>/dev/null | grep -v grpc.component > "$OUT/$LABEL-$k.dvpnd.log"
  w=$(grep -c '"level":"\(warn\|error\)"' "$OUT/$LABEL-$k.dvpnd.log")
  r=$(grep -ciE 'rpc|getAccountInfo|chain' "$OUT/$LABEL-$k.dvpnd.log")
  res=FAILED; grep -qiE 'connected|session' <<<"$said" && ! grep -qi error <<<"$said" && res=CONNECTED
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$res" "$(( t1 - t0 ))" "${said:0:160}" "$w" "$r" | tee -a "$TSV"
  plat_disconnect >/dev/null 2>&1; sleep 10
done
plat_close_run_channels
