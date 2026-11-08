#!/usr/bin/env bash
# ─── cb33-matrix driver (PLAN-cb33-FINAL §1): suites → scenarios → protocols, 5 built-in checks around each ───
# Usage: see README.md. Exit 0 = every scenario passed, 1 = at least one FAIL, 2 = setup error.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)

PLATFORM='' SIDE=B NODE=node-3 SUITES='S1' OUT='' SELFTEST=0 CHANNEL='' ONLY_PROTO='' ONLY_SCEN=''
while [ $# -gt 0 ]; do
  case $1 in
    --platform) PLATFORM=$2; shift ;;
    --side) SIDE=$2; shift ;;
    --node) NODE=$2; shift ;;
    --suites) SUITES=$2; shift ;;
    --out) OUT=$2; shift ;;
    --channel) CHANNEL=$2; shift ;;
    --protocol) ONLY_PROTO=$2; shift ;;
    --scenario) ONLY_SCEN=$2; shift ;;
    --selftest) SELFTEST=1 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$PLATFORM" ] || { echo "--platform is required (linux, windows, mac, android)" >&2; exit 2; }
OUT=${OUT:-$HOME/cbm-$PLATFORM-$SIDE-$(date -u +%m%dT%H%M)}
mkdir -p "$OUT"; : >> "$OUT/results.tsv"

. "$HERE/lib/common.sh"
. "$HERE/lib/nodes.sh"
. "$HERE/plat/$PLATFORM.sh" || { echo "no adapter plat/$PLATFORM.sh" >&2; exit 2; }
for c in leak status words money leftovers; do . "$HERE/checks/$c.sh"; done

for fn in plat_init plat_protocols plat_daemon_start plat_daemon_stop plat_connect plat_disconnect plat_sessions \
  plat_status_line plat_egress plat_set_ks plat_capture_start plat_capture_stop plat_leftovers plat_cut plat_uncut \
  plat_cli_outputs plat_money plat_reset; do
  need "$fn" || exit 2
done

# plat_reset leaves a daemon RUNNING (it is the between-scenario reset), so the end of a run must also stop it, or
# every run leaves a c1 daemon behind (seen on r2 11-07 after each selftest; FLX2).
cleanup() { plat_uncut >/dev/null 2>&1; plat_reset >/dev/null 2>&1; plat_daemon_stop >/dev/null 2>&1; deadman_stop; }
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM   # a signal goes through exit, so the EXIT cleanup runs (TLX, 11-07)

plat_init || { say "plat_init failed"; exit 2; }
leftovers_baseline   # snapshot install-time state once so it is not counted as a scenario leftover (TWA S1 11-08)
say "== cb33-matrix platform=$PLATFORM side=$SIDE node=$NODE ($NODE_ID $NODE_IP) suites=$SUITES out=$OUT"
say "   direct=$DIRECT_IP phys=$PHYS_IF build=$(plat_build 2>/dev/null)"
# Which matrix ran (DIR 11-08): the git revision when run from the repo, else the .rev a tar carries.
# Make a tar with: git -C <repo> rev-parse --short HEAD > cb33-matrix/.rev &&
#   git -C <repo> status --short cb33-matrix >> cb33-matrix/.rev
matrix_rev() {
  local rev dirty
  if rev=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null); then
    dirty=$(git -C "$HERE" status --short -- . 2>/dev/null | grep -c . || true)
    echo "$rev (git, $dirty changed file(s))"
    git -C "$HERE" status --short -- . 2>/dev/null
  elif [ -s "$HERE/.rev" ]; then
    echo "$(head -1 "$HERE/.rev") (tar, $(( $(grep -c . "$HERE/.rev") - 1 )) changed file(s) at tar time)"
    tail -n +2 "$HERE/.rev"
  else
    echo "unknown (no git, no .rev: this run cannot be traced to a matrix revision)"
  fi
}
matrix_rev > "$OUT/matrix-rev.txt"
say "   matrix=$(head -1 "$OUT/matrix-rev.txt")"
rpc_lane_init
node_resolve || { [ "$SELFTEST" = 1 ] || exit 2; }

if [ "$SELFTEST" = 1 ]; then
  for c in nodes leak status words money leftovers delegate; do "${c}_selftest" | tee -a "$OUT/selftest.txt"; done
  grep -q MISSED "$OUT/selftest.txt" && exit 1 || exit 0
fi

# run_scenario <suite> <fn> <protocol> <ks mode>: the checks wrap the scenario body
run_scenario() {
  SUITE=$1 SCENARIO=${2#*_} PROTO=$3; local fn=$2 ks=${4:-off}
  SCEN_DIR="$OUT/$SUITE/$SCENARIO-$PROTO"; mkdir -p "$SCEN_DIR"; SCENARIO_FAILED=0
  node_for "$PROTO" || { result setup SKIP "node does not list $PROTO on chain"; return; }
  # A scenario whose platform hook is missing says so up front (${fn}_needs): one SKIP row, no checks around a body
  # that cannot run (the checks then FAIL "no samples", u22 S5 reboot 11-08, ABW).
  if declare -F "${fn}_needs" > /dev/null && ! "${fn}_needs"; then
    result scenario SKIP "not implemented on $PLATFORM yet (a platform hook it needs is missing)"
    say "   $SUITE $SCENARIO $PROTO: SKIP"; return
  fi
  say "-- $SUITE $SCENARIO $PROTO (ks=$ks) node entry $NODE_ID port $NODE_PORT"
  # Recorder-eligible = a ks-on scenario whose actions run on the VM via the recorder (not live over ssh).
  # Computed before plat_set_ks so the ks gate can tell a recorder-backed ks-on run (safe: ssh is not the control
  # path, the VM deadman backstops) from a live ks-on run (would cut the driver). Reused by the branch below.
  CBM_KS_RECORDED=0
  [ "$ks" != off ] && declare -F plat_record_start >/dev/null && declare -F "${fn}_ps" >/dev/null && CBM_KS_RECORDED=1
  export CBM_KS_RECORDED
  # CBM_EXPECT_BLOCKED tells leak.sh whether direct egress during the scenario's down/cut window is a leak (TWA
  # 11-08): 1 = the block must hold (persist, a KILL crash, a cut, a normal ks-on active window), 0 = the block is
  # expected to lift (a graceful daemon stop under ks='on'). Default from ks; a scenario overrides via ${fn}_eb.
  CBM_EXPECT_BLOCKED=$([ "$ks" = off ] && echo 0 || echo 1)
  declare -F "${fn}_eb" >/dev/null && CBM_EXPECT_BLOCKED=$("${fn}_eb")
  export CBM_EXPECT_BLOCKED
  plat_set_ks "$ks"; plat_daemon_stop TERM; plat_daemon_start || { result setup FAIL "daemon did not start"; return; }
  # A 0/low program-delegate allowance makes open_channel fail token-2022 InsufficientFunds (TLX2 11-08); blind the
  # cell "cannot judge" rather than scoring that as a product FAIL. Funding/setup approves the delegate.
  preflight_delegate || { say "   $SUITE $SCENARIO $PROTO: BLIND (delegate not approved)"; return; }
  leftovers_start; money_start
  local rc
  if [ "$CBM_KS_RECORDED" = 1 ]; then
    # Recorder mode (FWA): with the kill switch up the driver cannot reach the machine, so the scenario runs as
    # one job there (1 s status poller, capture, steps, disconnect, deadman) and the checks read what it wrote.
    STATUS_PID=0
    "${fn}_ps" "$PROTO" > "$SCEN_DIR/steps.ps1"
    plat_record_start "$SUITE-$SCENARIO-$PROTO" "$SCEN_DIR/steps.ps1" "${RECORD_MAX:-900}" > "$SCEN_DIR/scenario.log" 2>&1
    rc=$?
    # A collect miss only fails a run the body PASSED. A SKIP (rc 77, e.g. wg/awg protocol-kill exits 77 at once
    # with a near-empty recorder dir) or a body FAIL keeps its own rc, so 77 still maps to SKIP (TWA 11-08).
    local crc=0; plat_record_collect "$SCEN_DIR" >> "$SCEN_DIR/scenario.log" 2>&1 || crc=1
    [ "$rc" = 0 ] && rc=$crc
    # The recorder's status.tsv → the status check's format (checks/status.sh status_from_recorder).
    if [ -f "$SCEN_DIR/status.tsv" ] && awk -F'\t' 'NR == 1 { exit !($3 ~ /^state=/) }' "$SCEN_DIR/status.tsv"; then
      mv "$SCEN_DIR/status.tsv" "$SCEN_DIR/status-recorder.tsv"
      status_from_recorder "$SCEN_DIR"
    fi
    LEAK_PCAP=$(ls "$SCEN_DIR"/phys.pcap "$SCEN_DIR"/*.pcapng 2>/dev/null | head -1)
    LEAK_OFFLINE=1; status_stop; leak_stop "$ks"; LEAK_OFFLINE=0; words_stop; money_stop; leftovers_stop
  else
    leak_start; status_start; words_start
    "$fn" "$PROTO" > "$SCEN_DIR/scenario.log" 2>&1
    rc=$?
    status_stop; leak_stop "$ks"; words_stop; money_stop; leftovers_stop
  fi
  case $rc in
    0) result scenario PASS "body rc 0" ;;
    77) result scenario SKIP "not implemented on $PLATFORM yet (owner: see suite file)" ;;
    *) result scenario FAIL "body rc $rc (see $SCEN_DIR/scenario.log)" ;;
  esac
  # Keep this cell's daemon log: the adapter truncates it at the next daemon start (u22 S5 sleep 11-08: lost).
  [ -n "${DLOG:-}" ] && [ -f "$DLOG" ] && cp "$DLOG" "$SCEN_DIR/daemon.log" 2>/dev/null
  # A skipped body (rc 77) is SKIP even when its checks passed: nothing was exercised (DIR 11-08).
  local verdict=PASS
  [ "$rc" = 77 ] && verdict=SKIP
  [ "$SCENARIO_FAILED" = 0 ] || verdict=FAIL
  say "   $SUITE $SCENARIO $PROTO: $verdict"
}

# suite_verdict <suite>: FAIL if any cell has a FAIL row; NOT RUN if no cell ran (all SKIP, or none);
# else PASS. Counts are cells (scenario x protocol), from results.tsv.
suite_verdict() {
  awk -F'\t' -v s="$1" '
    $2 != s { next }
    $5 == "scenario" { cell[$3 "|" $4] = $6 }
    $6 == "FAIL" { failed[$3 "|" $4] = 1 }
    END {
      for (k in cell) { n++; if (k in failed) f++; else if (cell[k] == "SKIP") sk++; else p++ }
      if (f > 0) printf "FAIL cells: %d total, %d FAIL, %d PASS, %d SKIP\n", n, f, p, sk
      else if (p == 0) printf "NOT RUN cells: %d SKIP, 0 run\n", sk
      else printf "PASS cells: %d PASS, %d SKIP\n", p, sk
    }' "$OUT/results.tsv"
}

for S in ${SUITES//,/ }; do
  [ -f "$HERE/suites/$S.sh" ] || { say "no suite $S"; continue; }
  . "$HERE/suites/$S.sh"
  # each suite file sets SCENARIOS="fn:ks[:once] ..." (ks = the kill switch mode the checks expect;
  # once = protocol-independent, run on the first protocol only, no rows for the others)
  for item in $SCENARIOS; do
    IFS=: read -r fn ks once <<<"$item"
    # s1_core or core; a comma list picks several (s3_cut90,cut90_ks)
    [ -n "$ONLY_SCEN" ] && case ",$ONLY_SCEN," in *",$fn,"* | *",${fn#*_},"*) ;; *) continue ;; esac
    for p in $(plat_protocols); do
      [ -n "$ONLY_PROTO" ] && [ "$p" != "$ONLY_PROTO" ] && continue
      run_scenario "$S" "$fn" "$p" "${ks:-off}"
      [ "$once" = once ] && break
    done
  done
  say "== suite $S: $(suite_verdict "$S")"
  RAN_SUITES="${RAN_SUITES:-} $S"
done

money_run_end
rpc_summary
fails=$(awk -F'\t' '$6 == "FAIL"' "$OUT/results.tsv" | grep -c . || true)
skips=$(awk -F'\t' '$5 == "scenario" && $6 == "SKIP"' "$OUT/results.tsv" | grep -c . || true)
notrun=''
for S in ${RAN_SUITES:-}; do case $(suite_verdict "$S") in "NOT RUN"*) notrun="$notrun $S" ;; esac; done
say "== done: $(grep -c . "$OUT/results.tsv" || true) results, $fails FAIL, $skips SKIP cells, NOT RUN suites:${notrun:- none} → $OUT/results.tsv"
# A suite that never ran is not a pass: exit 3 so a caller can't read the run as green.
[ "$fails" = 0 ] || exit 1
[ -z "$notrun" ] || exit 3
exit 0
