#!/usr/bin/env bash
# ─── Selftest: the status poller's sample rate and egress freshness (FLX 11-08, tlx-u22) ───
# Stub adapter: a fast status call and an egress probe that is blocked (6 s, then "none"). The poller must still
# sample ~1/s, and a sample with no probe that ended within 2.5 s reads "unknown". ~12 s. Exits 1 on any miss.
# Usage (from ~/cb33-matrix): bash selftest/status-poller.sh
set -u
cd "$(dirname "$0")/.." || exit 2
. lib/common.sh; . checks/status.sh

OUT=$(mktemp -d); : > "$OUT/results.tsv"; SCEN_DIR=$OUT/poll; mkdir -p "$SCEN_DIR"
fails=0
ok_() { if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "MISS $1: got $2, wanted $3"; fails=$((fails + 1)); fi; }

# ─── status_fresh_egress (unit) ───
f=$OUT/eg.tsv
printf '1000\t1200\t203.0.113.10\n2300\t8300\tnone\n' > "$f"
ok_ fresh-after-end "$(status_fresh_egress "$f" 9000)" none
ok_ stale-during-hang "$(status_fresh_egress "$f" 5000)" unknown
ok_ fresh-before-hang "$(status_fresh_egress "$f" 2000)" 203.0.113.10
ok_ empty-file "$(status_fresh_egress /dev/null 2000)" unknown

# ─── live poller with a blocked egress probe ───
plat_status_line() { echo "state=active ks=on id=B text="; }
plat_egress() { sleep 6; echo none; }
status_start; sleep 10; kill "$STATUS_PID" 2>/dev/null; wait "$STATUS_PID" 2>/dev/null
kill "$EGRESS_PID" 2>/dev/null; wait "$EGRESS_PID" 2>/dev/null
n=$(grep -c . "$SCEN_DIR/status.tsv" || true)
if [ "$n" -ge 7 ]; then echo "ok   rate: $n samples in 10 s with a 6 s egress probe"
else echo "MISS rate: $n samples in 10 s (wanted >= 7)"; fails=$((fails + 1)); fi
u=$(awk -F'\t' '$3 == "unknown"' "$SCEN_DIR/status.tsv" | grep -c . || true)
nn=$(awk -F'\t' '$3 == "none"' "$SCEN_DIR/status.tsv" | grep -c . || true)
if [ "$u" -ge 1 ] && [ "$nn" -ge 1 ]; then echo "ok   egress: $u unknown (probe running), $nn none (probe just ended)"
else echo "MISS egress: unknown=$u none=$nn (wanted both >= 1)"; fails=$((fails + 1)); fi

# ─── a status call that hangs (FLX 11-08: after a hy2 kill) must not stop the poller ───
SCEN_DIR=$OUT/hang; mkdir -p "$SCEN_DIR"; : > "$SCEN_DIR/calls"
plat_egress() { echo 203.0.113.10; }
plat_status_line() { echo x >> "$SCEN_DIR/calls"; [ "$(grep -c . "$SCEN_DIR/calls")" = 3 ] && sleep 30; echo "state=active ks=on id=B text="; }
STATUS_CALL_CAP_S=2 status_start; sleep 12; kill "$STATUS_PID" 2>/dev/null; wait "$STATUS_PID" 2>/dev/null
kill "$EGRESS_PID" 2>/dev/null; wait "$EGRESS_PID" 2>/dev/null
n=$(grep -c . "$SCEN_DIR/status.tsv" || true)
un=$(grep -c 'state=unknown' "$SCEN_DIR/status.tsv" || true)
if [ "$n" -ge 7 ] && [ "$un" = 1 ]; then echo "ok   hang: $n samples in 12 s, the hung call recorded as unknown"
else echo "MISS hang: $n samples, $un unknown (wanted >= 7 and 1)"; fails=$((fails + 1)); fi
w=$(grep -c . "$SCEN_DIR/active-windows.txt" || true)
if [ "$w" = 1 ]; then echo "ok   hang-window: one active window (the unknown sample did not close it)"
else echo "MISS hang-window: $w windows (wanted 1)"; fails=$((fails + 1)); fi

rm -rf "$OUT"
[ "$fails" = 0 ] && echo "status-poller selftest: all cases as expected" || { echo "status-poller selftest: $fails miss(es)"; exit 1; }
