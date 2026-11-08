#!/usr/bin/env bash
# ─── Selftest: the honest-status judge in checks/status.sh (DIR 11-08, FWA Windows F1) ───
# Judges small planted status.tsv files offline. Every case must come out as expected; exits 1 on any miss.
# Usage (from ~/cb33-matrix): bash selftest/status.sh
set -u
cd "$(dirname "$0")/.." || exit 2
. lib/common.sh; . checks/status.sh

OUT=$(mktemp -d); : > "$OUT/results.tsv"
NODE_EGRESS=203.0.113.10; DIRECT_IP=198.51.100.50; SUITE=selftest; PROTO=none
N=$NODE_EGRESS D=$DIRECT_IP

# case_ <name> <expect PASS|FAIL> <row>... ; row = egress|status line (one per second)
fails=0
case_() {
  local name=$1 want=$2 i=0 r got; shift 2
  SCEN_DIR=$OUT/$name; mkdir -p "$SCEN_DIR"; : > "$SCEN_DIR/status.tsv"
  for r in "$@"; do i=$((i + 1)); printf '%s\t40\t%s\t%s\n' "$i" "${r%%|*}" "${r#*|}" >> "$SCEN_DIR/status.tsv"; done
  SCENARIO=$name SCENARIO_FAILED=0 STATUS_PID=0 status_stop >/dev/null 2>&1
  got=$(awk -F'\t' -v s="$name" '$3 == s && $5 == "status" { print $6 }' "$OUT/results.tsv" | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $name: status $got"
  else echo "MISS $name: status ${got:-none}, wanted $want ($(head -c 200 "$SCEN_DIR/status-lies.txt" 2>/dev/null))"; fails=$((fails + 1)); fi
}

OLD='state=ended ks=off id=A text="error": "stopped by user"'
OLDN='state=ended ks=off text="error": "stopped by user"'
case_ planted-active-direct FAIL "$D|state=active ks=off id=B text=" "$D|state=active ks=off id=B text="
case_ honest-session PASS "$D|state=none ks=off id=- text=" "$D|state=connecting ks=off id=B text=" \
  "$N|state=active ks=off id=B text=" "$N|state=active ks=off id=B text="
# Back to back: the previous cell's session A still reads "stopped by user" while the new session B's tunnel is
# already up (the list shows B a moment later). A's rows are A's, not a lie about B.
case_ back-to-back-ids PASS "$N|$OLD" "$N|$OLD" "$N|$OLD" "$N|state=connecting ks=off id=B text=" \
  "$N|state=active ks=off id=B text=" "$N|state=active ks=off id=B text="
case_ back-to-back-no-ids PASS "$N|$OLDN" "$N|$OLDN" "$N|$OLDN" "$N|state=connecting ks=off text=" \
  "$N|state=active ks=off text=" "$N|state=active ks=off text="
# The cell's OWN session ended while traffic still leaves through the node: a lie, still caught.
case_ own-ended-via-node FAIL "$N|state=active ks=off id=B text=" "$N|state=ended ks=off id=B text=\"error\": \"stopped by user\"" \
  "$N|state=ended ks=off id=B text=\"error\": \"stopped by user\""
# A stale-looking ended row AFTER the cell's own session went live is not skipped in the id-less fallback.
case_ no-ids-ended-after-live FAIL "$N|state=active ks=off text=" "$N|$OLDN" "$N|$OLDN"
# A CRLF recording (the Windows recorder): honest active samples must stay honest.
case_ crlf-recording PASS "$N"$'\r'"|state=active ks=on id=B text=" "$N"$'\r'"|state=active ks=on id=B text="
# The poller recorded nothing (FLX u22): a blind row, never a PASS.
case_ no-samples FAIL
# final2 reconnecting contract (FAN 11-08, Android S2 protocol_kill): "active" + "connection lost; reconnecting"
# says the tunnel is down, so a blocked (ks on) or direct (ks off) egress is honest. Plain "active" still isn't.
R='text="error": "connection lost; reconnecting"'
case_ reconnecting-blocked PASS "$N|state=active ks=on id=B text=" "none|state=active ks=on id=B $R" "none|state=active ks=on id=B $R"
case_ reconnecting-direct PASS "$N|state=active ks=off id=B text=" "$D|state=active ks=off id=B $R" "$D|state=active ks=off id=B $R"
case_ active-blocked-no-text FAIL "$N|state=active ks=on id=B text=" "none|state=active ks=on id=B text=" "none|state=active ks=on id=B text="
# No session at all, yet traffic leaves through the node: a lie (nothing is live in the cell, nothing skipped).
case_ none-via-node FAIL "$N|state=none ks=off id=- text=" "$N|state=none ks=off id=- text="

# ─── slow (>= 1 s) counts this cell's samples only (TWA 11-08) ───
# slow_ <name> <expect> <ms,egress|line>...
slow_() {
  local name=$1 want=$2 i=0 r got; shift 2
  SCEN_DIR=$OUT/$name; mkdir -p "$SCEN_DIR"; : > "$SCEN_DIR/status.tsv"
  for r in "$@"; do i=$((i + 1)); local m=${r%%,*} rest=${r#*,}; printf '%s\t%s\t%s\t%s\n' "$i" "$m" "${rest%%|*}" "${rest#*|}" >> "$SCEN_DIR/status.tsv"; done
  SCENARIO=$name SCENARIO_FAILED=0 STATUS_PID=0 status_stop >/dev/null 2>&1
  got=$(awk -F'\t' -v s="$name" '$3 == s && $5 == "status" { print $6 }' "$OUT/results.tsv" | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $name: status $got"
  else echo "MISS $name: status ${got:-none}, wanted $want"; fails=$((fails + 1)); fi
}
slow_ slow-stale-prior-session PASS "2100,$N|$OLD" "40,$N|state=connecting ks=off id=B text=" "40,$N|state=active ks=off id=B text="
slow_ slow-own-sample FAIL "40,$N|state=active ks=off id=B text=" "1300,$N|state=active ks=off id=B text="

# ─── transition grace (DIR fix (b) 11-08; CBM_TRANSITION_GRACE_S): a slow state=unknown cap-hit at a daemon
# restart/teardown edge is excluded from SLOW only with the knob on, and only when honest (never an active/edge-
# flanked slow). trans_ <name> <grace> <expect> <ms,egress|line>...  (same row shape as slow_)
U='state=unknown ks=- id=- text=status call did not answer in 5 s'
trans_() {
  local name=$1 grace=$2 want=$3 i=0 r got m rest; shift 3
  SCEN_DIR=$OUT/$name; mkdir -p "$SCEN_DIR"; : > "$SCEN_DIR/status.tsv"
  for r in "$@"; do i=$((i + 1)); m=${r%%,*}; rest=${r#*,}; printf '%s\t%s\t%s\t%s\n' "$i" "$m" "${rest%%|*}" "${rest#*|}" >> "$SCEN_DIR/status.tsv"; done
  SCENARIO=$name SCENARIO_FAILED=0 STATUS_PID=0 CBM_TRANSITION_GRACE_S=$grace status_stop >/dev/null 2>&1
  got=$(awk -F'\t' -v s="$name" '$3 == s && $5 == "status" { print $6 }' "$OUT/results.tsv" | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $name (grace=$grace): status $got"
  else echo "MISS $name (grace=$grace): status ${got:-none}, wanted $want ($(head -c 200 "$SCEN_DIR/status-lies.txt" 2>/dev/null))"; fails=$((fails + 1)); fi
}
# TWA x64 S1 core-wireguard: a leading slow-unknown (pre-connect), fast active run, a trailing slow-unknown (teardown).
# grace=0 (Linux/Mac default): the edges still count as SLOW -> FAIL (behaviour unchanged).
trans_ transition-off 0 FAIL "6310,$D|$U" "68,$N|state=active ks=off id=B text=" "80,$N|state=active ks=off id=B text=" "5270,$D|$U"
# grace>0 (Windows): both edge cap-hits are excluded as TRANSITION -> the rest is fast and honest -> PASS.
trans_ transition-edges 5 PASS "6310,$D|$U" "68,$N|state=active ks=off id=B text=" "80,$N|state=active ks=off id=B text=" "5270,$D|$U"
# Honesty 1: a slow sample that reads state=active is a real slow call, never excused, even with the knob on.
trans_ transition-active-slow 5 FAIL "68,$N|state=active ks=off id=B text=" "1300,$N|state=active ks=off id=B text=" "80,$N|state=active ks=off id=B text="
# Honesty 2: a slow-unknown flanked by live samples within grace on BOTH sides (a genuine mid-session wedge, not an
# edge/gap) is still SLOW.
trans_ transition-mid-wedge 5 FAIL "68,$N|state=active ks=off id=B text=" "6000,$D|$U" "80,$N|state=active ks=off id=B text="
# Mid-recording daemon restart (S2/S11/S12): a run of unknown between two active runs, the inner unknowns are >grace
# from any live sample -> excluded as TRANSITION. Active runs are fast; grace=2 so the 1..N second gap isolates them.
trans_ transition-restart-gap 2 PASS "68,$N|state=active ks=off id=B text=" "70,$N|state=active ks=off id=B text=" \
  "5000,$D|$U" "5000,$D|$U" "5000,$D|$U" "5000,$D|$U" "5000,$D|$U" "72,$N|state=active ks=off id=B text=" "74,$N|state=active ks=off id=B text="

# ─── status_from_recorder (the Windows recorder's files) ───
# conv_ <name> <expect> <egress rows "ms,value;..."> <status rows "ms,egress-col,line;...">
conv_() {
  local name=$1 want=$2 egr=$3 str=$4 got r
  SCEN_DIR=$OUT/$name; mkdir -p "$SCEN_DIR"; : > "$SCEN_DIR/status-recorder.tsv"
  if [ -n "$egr" ]; then tr ';' '\n' <<<"$egr" | awk -F, '{ printf "%s\t%s\r\n", $1, $2 }' > "$SCEN_DIR/egress.tsv"; fi
  tr ';' '\n' <<<"$str" | awk -F, '{ printf "%s\t40\t%s\t%s\r\n", $1, $3, $2 }' > "$SCEN_DIR/status-recorder.tsv"
  status_from_recorder "$SCEN_DIR"
  SCENARIO=$name SCENARIO_FAILED=0 STATUS_PID=0 status_stop >/dev/null 2>&1
  got=$(awk -F'\t' -v s="$name" '$3 == s && $5 == "status" { print $6 }' "$OUT/results.tsv" | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $name: status $got"
  else echo "MISS $name: status ${got:-none}, wanted $want ($(cut -f3,4 "$SCEN_DIR/status.tsv" | tr '\n' '/' | head -c 300))"; fails=$((fails + 1)); fi
}
A='state=active ks=on id=B text='
# TWA x64 core_ks-openvpn: the probe started at 7000 returns the node only ~12 s later; meanwhile the recorder copied
# the old "none" onto every active sample. Those samples have no fresh measurement: unknown, not a lie.
conv_ hung-probe PASS "4000,none;5000,none;6000,none;7000,$N;20000,$N;21000,$N" \
  "8000,none,$A;9000,none,$A;10000,none,$A;12000,none,$A;14000,none,$A;16000,none,$A;18000,none,$A;20500,$N,$A;21500,$N,$A"
# A fresh probe that really saw no egress while the status says active: still a lie.
conv_ fresh-none-while-active FAIL "7000,none;8000,none;9000,none" "7500,none,$A;8500,none,$A;9500,none,$A"
# No egress.tsv (older recording): the recorder's own column is used, CR stripped.
conv_ no-egress-file PASS "" "1000,$N,$A;2000,$N,$A"

# ─── status_windows_from_tsv (recorder mode wrote no active-windows.txt: TWA S1 11-08) ───
# win_ <name> <want windows, ";"-joined or empty> <rows "s|line">...
win_() {
  local name=$1 want=$2 r got; shift 2
  local f=$OUT/$name.tsv; : > "$f"
  for r in "$@"; do printf '%s\t40\tx\t%s\n' "${r%%|*}" "${r#*|}" >> "$f"; done
  got=$(status_windows_from_tsv "$f" | tr '\n' ';' | sed 's/;$//')
  if [ "$got" = "$want" ]; then echo "ok   $name: windows [$got]"
  else echo "MISS $name: windows [$got], wanted [$want]"; fails=$((fails + 1)); fi
}
win_ win-open-close "11 14" "10|state=connecting ks=on id=B text=" "11|state=active ks=on id=B text=" \
  "12|state=active ks=on id=B text=" "13|state=unknown ks=- id=- text=" "14|state=ended ks=on id=B text="
win_ win-open-at-end "11 13" "11|state=active ks=on id=B text=" "13|state=active ks=on id=B text="
win_ win-ksoff-reconnecting-closes "11 13" "11|state=active ks=off id=B text=" "13|state=active ks=off id=B $R"
win_ win-kson-reconnecting-holds "11 14" "11|state=active ks=on id=B text=" "13|state=active ks=on id=B $R" \
  "14|state=ended ks=on id=B text="
win_ win-crlf "11 12" "11|state=active ks=on id=B text="$'\r' "12|state=ended ks=on id=B text="$'\r'

# ─── live egress freshness: status_fresh_egress must not carry a probe that SPANNED the daemon stop (ABW 11-08,
# TLX S2 term_persist/kill: 4 false "LIE state=none egress=<node>" rows). A probe whose END is fresh but whose
# START predates the fresh window measured egress before the stop; it reads "unknown", so a teardown "none" sample
# is not a lie. This is the live-path counterpart of conv_ hung-probe (which covers the recorder path).
# egress-live.tsv row: <start ms_mono>  <end ms_mono>  <value>. now=100000, fresh (STATUS_EGRESS_FRESH_MS_LIVE)=2500.
egf_() {
  local name=$1 want=$2 start=$3 end=$4 val=$5 now=${6:-100000} got
  SCEN_DIR=$OUT/$name; mkdir -p "$SCEN_DIR"
  printf '%s\t%s\t%s\n' "$start" "$end" "$val" > "$SCEN_DIR/egress-live.tsv"
  got=$(status_fresh_egress "$SCEN_DIR/egress-live.tsv" "$now")
  if [ "$got" = "$want" ]; then echo "ok   $name: fresh-egress $got"
  else echo "MISS $name: fresh-egress ${got:-none}, wanted $want"; fails=$((fails + 1)); fi
}
egf_ egress-spanning-stop unknown 94000 99900 "$N"   # started 6 s ago (pre-stop), ended fresh: not judged
egf_ egress-fresh-node    "$N"    99100 99900 "$N"   # started 0.9 s ago: a real live reading
egf_ egress-fresh-direct  "$D"    99100 99900 "$D"   # a real direct reading stays judged
# end to end through status_lies: once the spanning probe reads "unknown", a teardown "none" is NOT a lie; a
# genuinely fresh node reading while state=none still IS (the cell's own session goes live first in both).
case_ stale-egress-not-a-lie PASS "$N|state=active ks=persist id=B text=" "unknown|state=none ks=persist id=B text=" \
  "unknown|state=none ks=persist id=B text="
case_ live-egress-is-a-lie FAIL "$N|state=active ks=persist id=B text=" "$N|state=none ks=persist id=B text=" \
  "$N|state=none ks=persist id=B text="

rm -rf "$OUT"
[ "$fails" = 0 ] && echo "status selftest: all cases as expected" || { echo "status selftest: $fails miss(es)"; exit 1; }
