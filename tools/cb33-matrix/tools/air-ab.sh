#!/usr/bin/env bash
# ─── Airplane A/B (FAN 11-08): does a session survive airplane mode? ───
# Runs on the Android rig. Per row: connect (protocol rotates), check egress = node, airplane mode on for
# AIR_S (default 20) s, off, then wait up to AIR_RECOVER_S (default 120) s for the session to read active with
# egress = node again. One TSV row per drop: proto, session_before, result (RESUMED / ENDED / LEAK), seconds
# from airplane-off to back through the node, session_after, state at the end.
# Usage: bash air-ab.sh <label> [rows]   → ~/air-ab/<label>.tsv
set -uo pipefail
LABEL=${1:?label}; ROWS=${2:-5}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HOME/air-ab; mkdir -p "$OUT"; SCEN_DIR=$OUT/$LABEL.cli; mkdir -p "$SCEN_DIR"
NODE=${AIR_NODE:-node-3}
say() { echo "$*"; }
tx_gap() { sleep "${TX_GAP:-7}"; }
deadman_start() { :; }; deadman_stop() { :; }
if [ "${CBM_PLAT:-android}" = linux ]; then
  # The box's own watchdog stops dvpnd after 3 failed network checks: a long drop row needs it held (TLX 11-08),
  # the same way lib/common.sh's deadman_start holds it for the suites.
  deadman_start() { ( me=$$; while kill -0 "$me" 2>/dev/null; do sudo touch /run/ddv-deadman.hold 2>/dev/null; sleep 30; done ) & DEADMAN_PID=$!; }
  deadman_stop() { [ -n "${DEADMAN_PID:-}" ] && kill "$DEADMAN_PID" 2>/dev/null; sudo rm -f /run/ddv-deadman.hold 2>/dev/null; return 0; }
fi
. "$HERE/lib/nodes.sh"
. "$HERE/plat/${CBM_PLAT:-android}.sh"  # linux: run detached (setsid nohup), plat_airplane drops ssh
plat_init >/dev/null
declare -F sess_rows >/dev/null && RUN_START_CHANNELS=$(sess_rows | awk '{print $3}' | sort -u | tr '\n' ' '); RUN_NEW_CHANNELS=''
OUT_SAVE=$OUT; OUT=$SCEN_DIR; node_resolve || { echo "could not resolve $NODE's entries from chain"; exit 2; }
declare -A E; while read -r p a _; do E[$p]=$a; done < "$SCEN_DIR/node-entries.txt"; OUT=$OUT_SAVE
read -r -a PROTOS <<<"${AIR_PROTOS:-wireguard v2ray openvpn amneziawg hysteria2}"
TSV=$OUT/$LABEL.tsv; printf 'proto\tsession_before\tresult\tback_s\tsession_after\tend_state\toff_at\n' > "$TSV"
echo "build: $(plat_build)" | tee "$OUT/$LABEL.build"
deadman_start
trap 'plat_airplane disable; deadman_stop' EXIT
for k in $(seq 1 "$ROWS"); do
  p=${PROTOS[$(( (k - 1) % ${#PROTOS[@]} ))]}
  [ -n "${E[$p]:-}" ] || { printf '%s\t-\tno-entry\t-\t-\t-\n' "$p" | tee -a "$TSV"; continue; }
  NODE_ID=${E[$p]}
  plat_connect "$p" >/dev/null || { printf '%s\t-\tconnect-failed\t-\t-\t-\n' "$p" | tee -a "$TSV"; continue; }
  before=$SID; sleep 3
  [ "$(plat_egress)" = "$NODE_EGRESS" ] || { printf '%s\t%s\tnot-through-node\t-\t-\t-\n' "$p" "$before" | tee -a "$TSV"; plat_disconnect >/dev/null 2>&1; continue; }
  plat_airplane enable; sleep "${AIR_S:-20}"; plat_airplane disable
  t1=$(date +%s); off_at=$(date -u +%FT%T.%3NZ); res=ENDED; back=-
  while [ $(( $(date +%s) - t1 )) -lt "${AIR_RECOVER_S:-120}" ]; do
    eg=$(plat_egress); st=$(plat_status_line)
    if [ "$eg" = "$NODE_EGRESS" ] && grep -q 'state=active' <<<"$st"; then res=RESUMED; back=$(( $(date +%s) - t1 )); break; fi
    # ks off: once the session gives up, egress is direct; that alone is the end, not a leak.
    grep -q 'state=none' <<<"$st" && [ "$eg" = "$DIRECT_IP" ] && break
    sleep 2
  done
  after=$(plat_live_sessions | head -1); st=$(plat_status_line | tr '\t' ' ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$before" "$res" "$back" "${after:--}" "$st" "$off_at" | tee -a "$TSV"
  plat_disconnect >/dev/null 2>&1; sleep 3
done
plat_close_run_channels
