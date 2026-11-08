#!/usr/bin/env bash
# ─── TLX: re-judge a finished run's LEAK rows offline with the CURRENT checks/leak.sh (recorder path) ───
# Reads each scenario's saved phys.pcap + active-windows.txt; nothing is captured, nothing runs on the network.
# Usage (on the VM, from ~/cb33-matrix): bash selftest/tlx-rejudge-leak.sh <run dir> [node ip]
# → prints one line per scenario + the edge/mid-window detail; results in <run dir>/rejudge-<ts>/results.tsv
set -u
RUN=${1:?run dir}; NODE_IP=${2:-192.0.2.3}
cd "$(dirname "$0")/.." || exit 2
. lib/common.sh; . checks/leak.sh
OUT=$RUN/rejudge-$(date -u +%H%M%S); mkdir -p "$OUT"; : > "$OUT/results.tsv"
PHYS_IF=$(ip -4 route show default | awk '{print $5; exit}')
GATEWAY_IP=$(ip -4 route show default | awk '{print $3; exit}')
CONTROL_IP=${CONTROL_IP:-$(echo "${SSH_CLIENT:-}" | awk '{print $1}')}
PHYS_ADDRS=$(ip -o addr show dev "$PHYS_IF" scope global | awk '{split($4, a, "/"); print a[1]}' | tr '\n' ' ')
RPC_HOST=$(grep -E '^HELIUS_RPC_URL=' ~/secrets/helius-lane-b.env 2>/dev/null | cut -d= -f2- | sed -E 's#^[a-z]+://([^/:?]+).*#\1#')
LEAK_RPC_HOSTS=${LEAK_RPC_HOSTS:-$( [ -n "$RPC_HOST" ] && getent ahostsv4 "$RPC_HOST" | awk '{print $1}' | sort -u | tr '\n' ' ')}
ks_of() { case $1 in core) echo off ;; core_ks|daemon_term|daemon_kill|protocol_kill) echo on ;; daemon_term_persist) echo persist ;; *) echo on ;; esac; }
for d in "$RUN"/S1/* "$RUN"/S2/*; do
  [ -s "$d/phys.pcap" ] || continue
  b=$(basename "$d"); scen=${b%-*}; proto=${b##*-}; ks=$(ks_of "$scen")
  SCEN_DIR=$d; LEAK_PCAP=$d/phys.pcap; SUITE=$(basename "$(dirname "$d")"); SCENARIO=$scen; PROTO=$proto
  SCENARIO_FAILED=0; LEAK_OFFLINE=1 leak_stop "$ks" >/dev/null 2>&1
done
echo "== re-judged $(grep -c . "$OUT/results.tsv") rows with leak.sh $(git log -1 --format=%h -- checks/leak.sh 2>/dev/null || echo '?')"
awk -F'\t' '{printf "%s %s %s %s %s: %s\n", $2, $3, $4, $5, $6, substr($7, 1, 150)}' "$OUT/results.tsv"
