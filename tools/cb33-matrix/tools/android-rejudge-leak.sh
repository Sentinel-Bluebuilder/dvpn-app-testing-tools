#!/usr/bin/env bash
# ─── FAN: re-judge a finished Android run's LEAK rows offline with the CURRENT checks/leak.sh ───
# Reads each scenario's saved phys.pcap (already DNS/mcast-filtered by plat_capture_stop) and
# active-windows.txt. The phone's addresses and allow lists come from plat_init (same phone, same node).
# Usage (on the rig, from ~/cb33-matrix): bash tools/android-rejudge-leak.sh <run dir>
#   → <run dir>/rejudge-<ts>/results.tsv and one line per row
set -u
RUN=${1:?run dir}
cd "$(dirname "$0")/.." || exit 2
NODE=node-3
say() { :; }; deadman_start() { :; }; deadman_stop() { :; }
. lib/common.sh; . checks/leak.sh; . plat/android.sh
plat_init >/dev/null 2>&1
OUT=$RUN/rejudge-$(date -u +%H%M%S); mkdir -p "$OUT"; : > "$OUT/results.tsv"
SHIFT_NOW=$(plat_clock_offset); echo "phone clock offset now: $SHIFT_NOW s"
ks_of() { # suite scenario -> the kill switch the scenario ran with (suites/*.sh SCENARIOS)
  case $1/$2 in
    S1/core_ks|S2/daemon_term|S2/daemon_kill|S2/protocol_kill|S4/switch_ks_on) echo on ;;
    S2/daemon_term_persist) echo persist ;;
    *) echo off ;;
  esac
}
for d in "$RUN"/S1/* "$RUN"/S2/* "$RUN"/S4/*; do
  [ -s "$d/phys.pcap" ] || continue
  b=$(basename "$d"); scen=${b%-*}; SUITE=$(basename "$(dirname "$d")"); ks=$(ks_of "$SUITE" "$scen")
  # Re-filter from the raw capture with today's rules (ARP dropped, phone clock shifted onto the rig's). Runs
  # captured before the shift existed get today's offset (the emulator's offset was steady at -1.42 s on 11-08).
  LEAK_PCAP=$d/phys.pcap
  if [ -s "$d/phys.pcap.raw" ]; then
    sh=$(cat "$d/phys.pcap.shift" 2>/dev/null || echo "$SHIFT_NOW")
    python3 -I tools/pcap-dns-drop.py "$d/phys.pcap.raw" "$d/phys.pcap.rejudge" --drop-link-mcast --drop-arp "--shift=$sh" $APP_HOSTS > "$d/phys.pcap.rejudge.txt" &&
      LEAK_PCAP=$d/phys.pcap.rejudge
  fi
  SCEN_DIR=$d; SCENARIO=$scen; PROTO=${b##*-}; SCENARIO_FAILED=0
  LEAK_OFFLINE=1 leak_stop "$ks" >/dev/null 2>&1
done
echo "== re-judged $(grep -c . "$OUT/results.tsv") rows with leak.sh $(git -C "$HOME/memory" log -1 --format=%h -- cb33-matrix/checks/leak.sh 2>/dev/null || echo synced)"
awk -F'\t' '{printf "%s %s %s %s %s: %s\n", $2, $3, $4, $5, $6, substr($7, 1, 160)}' "$OUT/results.tsv"
