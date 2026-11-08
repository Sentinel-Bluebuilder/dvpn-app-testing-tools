#!/usr/bin/env bash
# ─── S9 Cycles (PLAN §1b). Owner: FAN (Android airplane) + every platform ───
# 50 connect → egress → switch → egress → disconnect → direct cycles, rotating through the platform's protocols
# (cycle k uses protocol k mod N and switches to protocol k+1 mod N, each with its own node entry from
# lib/nodes.sh), so one run covers every protocol and every switch pair without 6 × 50 connects. The switch runs
# when the adapter has plat_switch; S9_SWITCH=0 turns it off.
# Cycles 5, 15, 25, 35, 45 add a network drop while connected: plat_airplane (Android airplane mode) when the
# adapter has it, else plat_cut 10 s. After the network returns the session must be active again through the node
# within the recovery window (S9_RECOVER_S default 150 s, extended once to S9_RECOVER_MAX_S 240 s while the daemon
# is still reconnecting, so a slow redial schedule is not cut mid-backoff - TLX 11-08). Direct egress during/after
# the drop is a LEAK only when the kill switch is meant to hold (CBM_EXPECT_BLOCKED=1); at ks=off (this scenario)
# the reconnect block is off, so going direct while reconnecting is by design, as in leak.sh. Per-cycle times:
# $OUT/s9-cycles.tsv.
# Resources: before cycle 1 and after every S9_SAMPLE_EVERY (10) cycles, the daemon's memory (plat_daemon_mem, KiB)
# and open handles (plat_daemon_handles) are sampled when the adapter has them ($OUT/s9-resources.tsv). A leak =
# least-squares slope over the samples above S9_MEM_SLOPE_KIB (default 512 KiB per cycle) or S9_HANDLE_SLOPE (0.5
# per cycle). Samples follow the daemon across restarts (a new pid resets nothing: the slope is per cycle).
# Money drift: the driver's money row runs on this scenario like every other (spent <= signed <= deposit per channel).
SCENARIOS="s9_cycles_50:off:once"

# s9_leakcheck → 1 when direct egress during/after the airplane is a LEAK (the kill switch is meant to hold),
# 0 when it is by design (ks=off, CBM_EXPECT_BLOCKED=0). Isolated so it can be asserted (TLX S9 u22 11-08).
s9_leakcheck() { [ "${CBM_EXPECT_BLOCKED:-1}" = 0 ] && echo 0 || echo 1; }

s9_sample() { # $1 = cycle → one row in s9-resources.tsv (memory and handles when the adapter has them)
  local m='-' h='-'
  declare -F plat_daemon_mem >/dev/null && m=$(plat_daemon_mem)
  declare -F plat_daemon_handles >/dev/null && h=$(plat_daemon_handles)
  printf '%s\t%s\t%s\n' "$1" "${m:--}" "${h:--}" >> "$OUT/s9-resources.tsv"
}

# Samples before cycle S9_WARMUP (default 10) are left out of the fit: the first sessions load code and caches once
# (Android cb33f: 63 → 155 MB by cycle 10, then +0.3 MB/cycle), which is not growth per cycle.
s9_slope() { # $1 = column (2 memory, 3 handles) → least-squares slope per cycle, or "-" with < 3 samples
  awk -F'\t' -v c="$1" -v w="${S9_WARMUP:-10}" 'NR > 1 && $1 >= w && $c ~ /^[0-9]+$/ { n++; x += $1; y += $c; xx += $1 * $1; xy += $1 * $c }
    END { d = n * xx - x * x; if (n < 3 || d == 0) print "-"; else printf "%.2f\n", (n * xy - x * y) / d }' "$OUT/s9-resources.tsv"
}

s9_resources_verdict() { # → result rows s9-memory / s9-handles (PASS, FAIL, or SKIP when not sampled); rc 1 on a leak
  local ms hs ml=${S9_MEM_SLOPE_KIB:-512} hl=${S9_HANDLE_SLOPE:-0.5} rc=0
  ms=$(s9_slope 2); hs=$(s9_slope 3)
  if [ "$ms" = - ]; then result s9-memory SKIP "not sampled (adapter has no plat_daemon_mem, or < 3 samples)"
  elif awk -v s="$ms" -v l="$ml" 'BEGIN { exit !(s > l) }'; then result s9-memory FAIL "$ms KiB/cycle (limit $ml): the daemon grows per cycle"; rc=1
  else result s9-memory PASS "$ms KiB/cycle (limit $ml)"; fi
  if [ "$hs" = - ]; then result s9-handles SKIP "not sampled (adapter has no plat_daemon_handles, or < 3 samples)"
  elif awk -v s="$hs" -v l="$hl" 'BEGIN { exit !(s > l) }'; then result s9-handles FAIL "$hs handles/cycle (limit $hl): the daemon leaks handles"; rc=1
  else result s9-handles PASS "$hs handles/cycle (limit $hl)"; fi
  return $rc
}

s9_cycles_50() {
  local n=${S9_CYCLES:-50} k p q protos fails=0 t0 tc eg i ok drop sw
  read -r -a protos <<<"$(plat_protocols)"
  printf 'cycle\tprotocol\tconnect_ms\tresult\tdetail\n' > "$OUT/s9-cycles.tsv"
  printf 'cycle\tmem_kib\thandles\n' > "$OUT/s9-resources.tsv"
  s9_sample 0
  for k in $(seq 1 "$n"); do
    p=${protos[$(( (k - 1) % ${#protos[@]} ))]}
    q=${protos[$(( k % ${#protos[@]} ))]}
    node_for "$p" || { printf '%s\t%s\t-\tSKIP\tno entry\n' "$k" "$p" >> "$OUT/s9-cycles.tsv"; continue; }
    t0=$(ms_mono)
    if ! plat_connect "$p"; then
      fails=$((fails + 1)); echo "cycle $k $p: connect failed"
      printf '%s\t%s\t%s\tFAIL\tconnect\n' "$k" "$p" "$(( $(ms_mono) - t0 ))" >> "$OUT/s9-cycles.tsv"
      plat_disconnect >/dev/null 2>&1; continue
    fi
    tc=$(( $(ms_mono) - t0 )); sleep 2
    eg=$(plat_egress); ok=1; drop=''; sw=''
    [ "$eg" = "$NODE_EGRESS" ] || { ok=0; echo "cycle $k $p: egress $eg, not the node"; }
    if [ "$ok" = 1 ] && [ $((k % 10)) = 5 ]; then
      # Direct egress during/after the drop is a LEAK only when the kill switch is meant to hold: at ks=off
      # (CBM_EXPECT_BLOCKED=0) the reconnect block is off, so going direct while reconnecting is by design and is
      # NOT a leak - the same rule leak.sh uses (TLX S9 u22 11-08, ABW graded harness). S9 runs ks=off, so the
      # airplane leak verdict was false; keep it for a ks-on/persist S9.
      local leakcheck; leakcheck=$(s9_leakcheck)
      if declare -F plat_airplane >/dev/null; then drop=airplane; plat_airplane enable; else drop=cut; plat_cut; fi
      for i in 1 2 3 4 5; do
        eg=$(plat_egress); [ "$leakcheck" = 1 ] && [ "$eg" = "$DIRECT_IP" ] && [ "$eg" != none ] && { ok=0; echo "cycle $k $p: LEAK direct egress during the $drop"; }
        sleep 1
      done
      if [ "$drop" = airplane ]; then plat_airplane disable; else plat_uncut; fi
      # Recovery window: wait long enough to see the daemon's FULL redial schedule, not cut it mid-backoff (TLX: a
      # 90 s window stopped cycle 5 before redial attempt 3/3 ran). Default widened to 150 s; and if the adapter
      # reports the daemon is still actively reconnecting at the window edge, extend once up to S9_RECOVER_MAX_S so a
      # still-running redial is never scored "not back". A still-failing cycle AFTER all attempts is then product.
      local rec=0 t1 win=${S9_RECOVER_S:-150} max=${S9_RECOVER_MAX_S:-240} extended=0; t1=$(ms_mono)
      while :; do
        local el=$(( ($(ms_mono) - t1) / 1000 ))
        if [ "$el" -ge "$win" ]; then
          if [ "$extended" = 0 ] && [ "$win" -lt "$max" ] && grep -Eq 'state=(reconnecting|connecting|checking)|reconnecting' <<<"$(plat_status_line)"; then
            win=$max; extended=1; echo "cycle $k $p: still reconnecting at ${el}s, extending the window to ${max}s"
          else break; fi
        fi
        eg=$(plat_egress)
        [ "$leakcheck" = 1 ] && [ "$eg" = "$DIRECT_IP" ] && [ "$eg" != none ] && { ok=0; echo "cycle $k $p: LEAK direct egress after the $drop"; break; }
        [ "$eg" = "$NODE_EGRESS" ] && grep -q 'state=active' <<<"$(plat_status_line)" && { rec=1; break; }
        sleep 3
      done
      [ "$rec" = 1 ] && echo "cycle $k $p: back through the node $(( ($(ms_mono) - t1) / 1000 )) s after the $drop" \
        || { ok=0; echo "cycle $k $p: not back within ${win} s after the $drop (all redials run): $(plat_status_line)"; }
    fi
    # Switch to the next protocol (not on a drop cycle: recovery is that cycle's check).
    if [ "$ok" = 1 ] && [ -z "$drop" ] && [ "${S9_SWITCH:-1}" = 1 ] && [ "$q" != "$p" ] && declare -F plat_switch >/dev/null; then
      if ! node_for "$q"; then
        sw="switch $q: no entry"   # a roster gap is not the cycle's failure
        node_for "$p" >/dev/null 2>&1
      elif plat_switch "$q"; then
        sw="switch $q"; sleep 2; eg=$(plat_egress)
        [ "$eg" = "$NODE_EGRESS" ] || { ok=0; echo "cycle $k $p→$q: egress $eg after the switch, not the node"; }
      else
        ok=0; sw="switch $q failed"; echo "cycle $k $p→$q: switch failed"
      fi
    fi
    plat_disconnect || { ok=0; echo "cycle $k $p: disconnect failed"; }
    sleep 2; eg=$(plat_egress)
    [ "$eg" = "$DIRECT_IP" ] || { ok=0; echo "cycle $k $p: after disconnect egress $eg (direct $DIRECT_IP)"; }
    [ "$ok" = 1 ] || fails=$((fails + 1))
    printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$p" "$tc" "$([ "$ok" = 1 ] && echo PASS || echo FAIL)" "${drop:-}${sw:+${drop:+ }$sw}" >> "$OUT/s9-cycles.tsv"
    echo "cycle $k/$n $p: $([ "$ok" = 1 ] && echo ok || echo FAIL) connect ${tc} ms${drop:+ ($drop)}${sw:+ ($sw)}"
    [ $((k % ${S9_SAMPLE_EVERY:-10})) = 0 ] && s9_sample "$k"
  done
  [ $((n % ${S9_SAMPLE_EVERY:-10})) = 0 ] || s9_sample "$n"
  echo "S9: $fails failed cycle(s) of $n"
  s9_resources_verdict || fails=$((fails + 1))
  [ "$fails" = 0 ]
}
