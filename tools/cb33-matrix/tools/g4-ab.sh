#!/usr/bin/env bash
# ─── G4 A/B (FAN 11-08): how long a session reads live after the user's disconnect ───
# Runs on the Android rig. Per protocol: connect to node-3, wait, `app disconnect`, then poll the stored
# session (the CLI's sessions read, what the app and the status check see) every ~0.3 s until it reads
# ended. Prints one TSV row per disconnect: proto, session, cli_s (disconnect command), ended_s.
# Usage: bash g4-ab.sh <label> [rounds]   → ~/g4-ab/<label>.tsv
set -uo pipefail
LABEL=${1:?label}; ROUNDS=${2:-2}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HOME/g4-ab; mkdir -p "$OUT"; SCEN_DIR=$OUT/$LABEL.cli; mkdir -p "$SCEN_DIR"
# G4_NODE (node-3 default, or node-4) and G4_PROTOS pick the node and protocols; entries come from chain.
NODE=${G4_NODE:-node-3}
say() { echo "$*"; }
tx_gap() { sleep "${TX_GAP:-7}"; }
deadman_start() { :; }; deadman_stop() { :; }
. "$HERE/lib/nodes.sh"
. "$HERE/plat/android.sh"
plat_init >/dev/null
RUN_START_CHANNELS=$(sess_rows | awk '{print $3}' | sort -u | tr '\n' ' '); RUN_NEW_CHANNELS=''
OUT_SAVE=$OUT; OUT=$SCEN_DIR; node_resolve || { echo "could not resolve $NODE's entries from chain"; exit 2; }
declare -A E; while read -r p a _; do E[$p]=$a; done < "$SCEN_DIR/node-entries.txt"; OUT=$OUT_SAVE
read -r -a PROTOS <<<"${G4_PROTOS:-wireguard amneziawg v2ray xray openvpn hysteria2}"
echo "node $NODE: $(for p in "${PROTOS[@]}"; do printf '%s=%s ' "$p" "${E[$p]:-none}"; done)"
TSV=$OUT/$LABEL.tsv; printf 'proto\tsession\tcli_s\tended_s\tegress_in\tegress_after\n' > "$TSV"
echo "build: $(plat_build)" | tee "$OUT/$LABEL.build"
for r in $(seq 1 "$ROUNDS"); do
  for p in "${PROTOS[@]}"; do
    [ -n "${E[$p]:-}" ] || { printf '%s\t-\tno-entry\t-\n' "$p" | tee -a "$TSV"; continue; }
    NODE_ID=${E[$p]}
    plat_connect "$p" >/dev/null || { printf '%s\t-\tconnect-failed\t-\n' "$p" | tee -a "$TSV"; continue; }
    sid=$SID; sleep 8; ein=$(plat_egress)
    t0=$(date +%s.%N)
    ( app disconnect >/dev/null; date +%s.%N > "$OUT/.cli-done" ) & bg=$!
    ended=''
    for i in $(seq 1 120); do
      [ "$(sess_field "$sid" status)" = ended ] && { ended=$(date +%s.%N); break; }
      sleep 0.2
    done
    eout=$(plat_egress)
    wait $bg; cli=$(cat "$OUT/.cli-done")
    printf '%s\t%s\t%.1f\t%s\t%s\t%s\n' "$p" "$sid" "$(echo "$cli - $t0" | bc)" "$([ -n "$ended" ] && printf '%.1f' "$(echo "$ended - $t0" | bc)" || echo '>30')" "$ein" "$eout" | tee -a "$TSV"
  done
done
echo "settling the channels this run opened: ${RUN_NEW_CHANNELS:-none}"
plat_close_run_channels
column -t "$TSV"
