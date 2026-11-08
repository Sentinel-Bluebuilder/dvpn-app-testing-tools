#!/usr/bin/env bash
# ─── S4 Switching (PLAN §1b). Owner: FWX (Linux), platform owners ───
# Needs the adapter's plat_switch <protocol> (connect to that protocol's entry while a session is live, replacing it:
# Android = the app's `connect --switch`). Without it every scenario SKIPs (rc 77). Optional plat_live_node prints the
# node entry of the live session, so a switch is proved to land on the new entry (node-3's entries share one IP).
# Bodies: FAN 11-08 (Android first); a platform with its own switch command only adds plat_switch.
SCENARIOS="s4_every_pair:off s4_switch_while_connecting:off:once s4_switch_ks_on:on:once s4_switch_ks_on_cross:on:once s4_fast_switch_x10:off:once"

# s4_after <protocol>: one live session, on that protocol's entry, through the node
s4_after() {
  local want=$NODE_ID live eg
  live=$(plat_live_sessions 2>/dev/null | grep -c . || true)
  [ "$live" = 1 ] || { echo "after switch to $1: $live live sessions (want 1)"; return 1; }
  if declare -F plat_live_node >/dev/null; then
    [ "$(plat_live_node)" = "$want" ] || { echo "after switch to $1: live session is on $(plat_live_node), not $want"; return 1; }
  fi
  eg=$(plat_egress); [ "$eg" = "$NODE_EGRESS" ] || { echo "after switch to $1: egress $eg"; return 1; }
  echo "switched to $1: one live session on $want, egress $eg"
}
# s4_watch <seconds>: egress samples while a switch runs; a direct sample = leak (rc 1)
s4_watch() {
  # Two probes (G26 A/B, FLX 11-08):
  #  - egress pinned to an IP resolved before the switch: during the gap the system DNS still points at the dead
  #    tunnel, so a name lookup only fails ("none") and hides a released block.
  #  - plat_block_sample <s> <file> (optional hook): one root `nft monitor`, every add/delete of the kill-switch table; it
  #    must never be deleted during the switch (a stop-start gap can be milliseconds, below any polling interval).
  local end=$(( $(ms_mono) + $1 * 1000 )) e ip n=0 rc=0 bf="${SCEN_DIR:-/tmp}/watch-block.txt" bp='' m g mx
  ip=$(declare -F plat_resolve4 >/dev/null && plat_resolve4 api.ipify.org | head -1)
  rm -f "$bf"
  if declare -F plat_block_sample >/dev/null; then plat_block_sample "$1" "$bf" & bp=$!; fi
  while [ "$(ms_mono)" -lt "$end" ]; do
    n=$((n + 1))
    if [ -n "$ip" ] && declare -F plat_egress_at >/dev/null; then e=$(plat_egress_at api.ipify.org "$ip"); else e=$(plat_egress); fi
    [ "$e" = "$DIRECT_IP" ] && [ "$e" != none ] && { echo "LEAK: direct egress during a switch (sample $n)"; rc=1; break; }
  done
  if [ -n "$bp" ]; then
    wait "$bp"; read -r m g mx < "$bf" || { m=0; g=0; mx=0; }
    echo "watch: kill-switch table events $m, gaps $g, longest ${mx} ms (nft monitor; a re-render within 50 ms is not a gap)"
    [ "$g" = 0 ] || { echo "BLOCK GAP: kill-switch table deleted for ${mx} ms during the switch"; rc=1; }
  fi
  echo "watch: $n egress samples${ip:+, probe pinned to $ip}"
  return $rc
}

s4_every_pair() {
  declare -F plat_switch >/dev/null || return 77
  local a=$1 b fails=0
  plat_connect "$a" || { echo "connect $a failed"; return 1; }
  for b in $(plat_protocols); do
    [ "$b" = "$a" ] && continue
    node_for "$b" || { echo "no entry for $b"; continue; }
    plat_switch "$b" || { echo "switch $a -> $b failed"; fails=$((fails + 1)); continue; }
    sleep 2; s4_after "$b" || fails=$((fails + 1))
    node_for "$a"; plat_switch "$a" || { echo "switch back to $a failed"; fails=$((fails + 1)); }
  done
  plat_disconnect || fails=$((fails + 1))
  [ "$fails" = 0 ]
}

s4_switch_while_connecting() {
  declare -F plat_switch >/dev/null || return 77
  local a=$1 b; b=$(plat_protocols | tr ' ' '\n' | grep -vx "$a" | head -1)
  # The first connect is still in flight when the switch starts.
  ( plat_connect "$a" >/dev/null 2>&1 ) & local bg=$!
  sleep 3
  node_for "$b" || return 1
  TX_GAP=0 plat_switch "$b" || { echo "switch during connect failed"; wait $bg; return 1; }
  wait $bg
  sleep 5; s4_after "$b" || { plat_disconnect; return 1; }
  plat_disconnect
}

s4_switch_ks_on() {
  declare -F plat_switch >/dev/null || return 77
  local a=$1 b rc=0; b=$(plat_protocols | tr ' ' '\n' | grep -vx "$a" | head -1)
  plat_connect "$a" || return 1
  node_for "$b" || return 1
  ( s4_watch 60 ) > "$SCEN_DIR/watch.txt" 2>&1 & local w=$!
  plat_switch "$b" || rc=1
  wait $w || rc=1; cat "$SCEN_DIR/watch.txt"
  s4_after "$b" || rc=1
  plat_disconnect || rc=1
  return $rc
}

# s4_switch_ks_on_cross: kill switch on, switch to the same protocol on ANOTHER host (G26 cross-host: the kept block
# must admit the new host before the dial, since a block admits only its own node). The other host's entry comes from
# the run's node listing (same owner) or CBM_CROSS_NODE=<node address> (e.g. node-4 for a node-3 run). SKIP (77)
# when there is no second host. A direct egress sample during the switch is a leak; leak.sh (ks-on) judges the pcap.
s4_switch_ks_on_cross() {
  declare -F plat_switch >/dev/null || return 77
  local a=$1 here row uri rc=0 eg
  node_for "$a" || return 77
  here=$NODE_IP
  row=$(awk -v p="$a" -v h="$here" '$1 == p && $3 != h { print; exit }' "$OUT/node-entries.txt")
  if [ -z "$row" ] && [ -n "${CBM_CROSS_NODE:-}" ]; then
    uri=$(node_chain_cli node show "$CBM_CROSS_NODE" 2>/dev/null | sed -nE 's#.*"uri": *"https://([^":/]+):([0-9]+).*#\1 \2#p' | head -1)
    [ -n "$uri" ] && row="$a $CBM_CROSS_NODE $uri"
  fi
  [ -n "$row" ] || { echo "no $a entry on a host other than $here (set CBM_CROSS_NODE): SKIP"; return 77; }
  plat_connect "$a" || return 1
  read -r _ NODE_ID NODE_IP NODE_PORT <<<"$row"
  ( s4_watch 60 ) > "$SCEN_DIR/watch.txt" 2>&1 & local w=$!
  plat_switch "$a" || { echo "cross-host switch $here -> $NODE_IP failed"; rc=1; }
  wait $w || rc=1; cat "$SCEN_DIR/watch.txt"
  eg=$(plat_egress)
  if [ "$eg" = "$DIRECT_IP" ] || [ "$eg" = none ]; then echo "after cross-host switch: egress $eg"; rc=1
  else echo "cross-host switch $here -> $NODE_IP ($NODE_ID): egress $eg"; fi
  plat_disconnect || rc=1
  node_for "$a" >/dev/null 2>&1   # back to the scenario's own entry for the driver
  return $rc
}

s4_fast_switch_x10() {
  declare -F plat_switch >/dev/null || return 77
  local a=$1 b k p fails=0; b=$(plat_protocols | tr ' ' '\n' | grep -vx "$a" | head -1)
  plat_connect "$a" || return 1
  for k in $(seq 1 10); do
    p=$([ $((k % 2)) = 1 ] && echo "$b" || echo "$a")
    node_for "$p" || return 1
    plat_switch "$p" || { echo "fast switch $k to $p failed"; fails=$((fails + 1)); }
  done
  sleep 5; s4_after "$a" || fails=$((fails + 1))
  plat_disconnect || fails=$((fails + 1))
  [ "$fails" = 0 ]
}

# ─── Windows recorder body for the ks-on switch (FWA, RECORDER-CONTRACT) ───
# Windows can't run a live ks-on switch — arming the kill switch cuts the driver's ssh — so the switch runs on the VM
# as a SYSTEM job under the recorder (defining this makes the driver treat s4_switch_ks_on as recorder-backed, so the
# ks gate allows ks-on). cb33 has no in-place switch, so: connect A, stop all (StopSession releases the kill switch
# — the gap under test), wait for none live, connect B. The release means direct egress is possible in the gap;
# leak.sh (ks-on, block-must-hold) catches it offline — the expected s4_switch_ks_on FAIL (G26, FLX fixing). Needs
# both entries, so it resolves B via node_for and restores the driver's entry state to A before returning.
s4_switch_ks_on_ps() { # $1 = protocol A (:once, so the first protocol only)
  local a=$1 b aentry; aentry=$NODE_ID
  b=$(plat_protocols | tr ' ' '\n' | grep -vx "$a" | head -1)
  if [ -z "$b" ] || ! node_for "$b"; then node_for "$a" >/dev/null 2>&1; echo 'exit 77'; return; fi
  local bentry=$NODE_ID
  NODE_ID=$aentry; win_ps_header
  cat <<PS
\$nodeB = '$bentry'
Connect-Node
if (\$LASTEXITCODE -ne 0) { Write-Output 'connect A failed'; exit 1 }
Start-Sleep -Seconds 8
# switch to B: stop every session (releases the kill switch), wait for none live, start on B's entry.
Disconnect-Node
Start-Sleep -Seconds 10
& \$cli --home \$h client start --node \$nodeB --new-channel --mode voucher --escrow-base-units ${ESCROW:-100000} --instance \$inst 2>&1 | Out-String | Write-Output
Start-Sleep -Seconds 20
Disconnect-Node
Start-Sleep -Seconds 3
exit 0
PS
  node_for "$a" >/dev/null 2>&1   # restore the driver's entry state (NODE_ID/IP/PORT) to A
}
