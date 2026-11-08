#!/usr/bin/env bash
# ─── S11 Node side (PLAN §1b). Owner: TS36 lab + FS36 (node-4 final check) ───
# Node faults need the adapter's node hooks (plat_node_*: the lab adapter has them, it owns its nodes). Without them a
# scenario returns 77 (SKIP). Rows: Q0003-06, Q0070/71, Q0138, Q0184, Q0188, Q0189, Q0218, Q0225, Q0266, Q0267, Q0331,
# Q0349, Q0355-64, Q0395. Each scenario prints what it measured; the 5 built-in checks still wrap it.
SCENARIOS="s11_node_kill_mid_session:off s11_close_reason:off s11_node_mtu:off s11_node_no_ipv6:off:once s11_openvpn_close_time:off s11_voucher_latency_429:off s11_six_clients_one_node:off s11_tunnel_addr_reuse:off s11_tolerance_inflate:off s11_tolerance_inflate8:off s11_retransmit_billing:off s11_retransmit_billing0:off s11_retransmit_billing5:off s11_retransmit_billing10:off s11_node_clock_skew:off s11_credit_pause:off s11_node_down_stop:off s11_node_down_start:off"

s11_hooks() { local f; for f in "$@"; do declare -F "$f" > /dev/null || { echo "adapter has no $f"; return 77; }; done; }
s11_get() { # <url> <max s> -> "bytes secs" (curl, through the session when the adapter set a proxy)
  curl -s -m "$2" -o /dev/null -w "%{size_download} %{time_total}" "$1"
}
s11_node_lines() { plat_node_log | tail -n +"$(( ${1:-0} + 1 ))"; }

# Node daemon killed (SIGKILL) mid-download, down 20 s, restarted. The client must not claim "active" through the
# outage (status check), must leave the dead session (ended or redialled) and a fresh connect must carry traffic.
s11_node_kill_mid_session() {
  s11_hooks plat_node_kill plat_node_start || return $?
  local eg st i
  plat_connect "$1" || { echo "connect failed"; return 1; }
  eg=$(plat_egress); echo "egress before kill $eg (node $NODE_EGRESS)"; [ "$eg" = "$NODE_EGRESS" ] || return 1
  curl -s -m 60 -o /dev/null "${CBM_BIG_URL}" & local dl=$!
  sleep 2; plat_node_kill KILL || { echo "node did not die"; return 1; }; echo "node killed $(date -u +%T)"
  sleep 20
  st=$(plat_status_line); echo "client after 20 s node down: $st"
  plat_node_start || { echo "node restart failed"; return 1; }; echo "node restarted $(date -u +%T)"
  kill $dl 2> /dev/null; wait $dl 2> /dev/null
  for i in $(seq 1 30); do st=$(plat_status_line); case $st in state=active*) [ "$(plat_egress)" = "$NODE_EGRESS" ] && break ;; state=none*|state=ended*) break ;; esac; sleep 2; done
  echo "client 60 s after the restart: $st"
  plat_disconnect > /dev/null 2>&1; sleep 3
  plat_connect "$1" || { echo "reconnect after node restart failed"; return 1; }
  eg=$(plat_egress); echo "egress after reconnect $eg"; [ "$eg" = "$NODE_EGRESS" ] || return 1
  local m; m=$(s11_get "${CBM_SLOW_URL}" 60); echo "2 MB after restart: $m"; [ "${m%% *}" -ge 1900000 ] || return 1
  plat_disconnect
}

# Close reason (Q0331/Q0395): a client stop must end the node session with a plain reason ("closed by client").
s11_close_reason() {
  s11_hooks plat_node_log || return $?
  local n0 r
  n0=$(plat_node_log | grep -c .)
  plat_connect "$1" || { echo "connect failed"; return 1; }
  s11_get "${CBM_SLOW_URL}" 60 > /dev/null; plat_disconnect || return 1; sleep 5
  r=$(s11_node_lines "$n0" | grep -a '"session closed"' | grep -oE '"reason":"[^"]*"' | tail -1)
  echo "node close reason: ${r:-none}"
  [ "$r" = '"reason":"closed by client"' ]
}

# Node uplink MTU 1400 (Q0421 class, #9): the tunnel must fit the uplink; a 50 MB TCP download must clear the floor.
s11_node_mtu() {
  s11_hooks plat_node_set_mtu plat_node_mtu plat_node_kill plat_node_start || return $?
  local m0 m rc=0 mbps
  m0=$(plat_node_mtu); plat_node_set_mtu 1400 || return 1
  plat_node_kill TERM; plat_node_start   # the node reads its uplink MTU at start (#9)
  echo "node uplink mtu $m0 -> $(plat_node_mtu)"
  if plat_connect "$1"; then
    m=$(s11_get "${CBM_BIG_URL}" 90); mbps=$(awk -v b="${m%% *}" -v s="${m##* }" 'BEGIN{printf "%.2f", (s > 0 ? b / s / 1e6 : 0)}')
    echo "50 MB at node mtu 1400: $m -> $mbps MB/s"
    awk -v x="$mbps" -v f="${CBM_MIN_MBPS:-2.5}" 'BEGIN{exit !(x >= f)}' || { echo "under the ${CBM_MIN_MBPS:-2.5} MB/s floor: MTU black hole at a 1400 uplink"; rc=1; }
    plat_disconnect
  else echo "connect failed at node mtu 1400"; rc=1; fi
  plat_node_set_mtu "$m0"; plat_node_kill TERM; plat_node_start
  return $rc
}

# Node without IPv6 (Q0184/Q0188): the node has no global v6; the client must get no v6 route through the tunnel
# that black-holes, and no direct v6 egress while active.
s11_node_no_ipv6() {
  s11_hooks plat_node_ipv6 || return $?
  local n6; n6=$(plat_node_ipv6); echo "node global ipv6 addresses: $n6"
  plat_connect "$1" || { echo "connect failed"; return 1; }
  echo "client v6 routes while active: $(ip -6 route show 2> /dev/null | grep -vE '^(fe80|multicast|ff00)' | tr '\n' ';')"
  local e6; e6=$(plat_egress6); echo "ipv6 egress $e6"
  plat_disconnect
  [ "$e6" = none ]
}

# OpenVPN close time (Q0138): stop -> no session and no openvpn process, within 10 s.
s11_openvpn_close_time() {
  [ "$1" = openvpn ] || return 77
  local t0 ms i
  plat_connect "$1" || { echo "connect failed"; return 1; }
  t0=$(ms_mono); plat_disconnect || return 1
  for i in $(seq 1 60); do
    [ -z "$(plat_sessions)" ] && ! ps -eo args | grep -qE '^[^ ]*openvpn ' && break; sleep 0.5
  done
  ms=$(( $(ms_mono) - t0 )); echo "openvpn close time ${ms} ms"
  [ "$ms" -le 10000 ]
}

# Voucher POST latency + 429 (Q0355-64): over a 50 MB download every voucher POST is accepted (no 429) and fast.
s11_voucher_latency_429() {
  s11_hooks plat_node_log || return $?
  local n0 lines n429 lat
  n0=$(plat_node_log | grep -c .)
  plat_connect "$1" || { echo "connect failed"; return 1; }
  s11_get "${CBM_BIG_URL}" 120 > /dev/null; plat_disconnect || return 1; sleep 3
  lines=$(s11_node_lines "$n0" | grep -a '/vouchers' | grep -av GIN-debug)
  n429=$(grep -c '"status":429' <<<"$lines" || true)
  lat=$(grep -oE '"latency":[0-9.]+' <<<"$lines" | cut -d: -f2 | sort -g | awk '{a[NR]=$1} END{printf "n=%d median=%s max=%s", NR, a[int((NR+1)/2)], a[NR]}')
  echo "voucher POSTs: $lat ms, 429s $n429"
  [ "$n429" = 0 ] && awk -v l="$lat" 'BEGIN{split(l, a, "max="); exit !(a[2] + 0 < 1000)}'
}

# Not in the lab yet (each says why; they SKIP, never PASS):
s11_six_clients_one_node() { echo "needs lab clients c3..c6 (provision pending)"; return 77; }

# Node down 45 s (G21, TLX 11-08): the client must leave "active" within ~6 s of the node dying (status per second vs
# real egress), keep the SAME session id visible while it redials, and then either take a stop of that id (stop
# variant: no node session reopens afterwards) or a fresh start (start variant: it replaces the redial).
# s11_cli_failed <rc> <output>: true when a CLI call failed. A success reply carries an EMPTY "error": "" field, so
# `grep -q error` read every successful start as a failure (TS36 11-08, false FAILs in G21 node_down_start B).
s11_cli_failed() {
  [ "$1" -ne 0 ] && return 0
  grep -qE '"error": *"[^"]+"|^error:' <<<"$2"
}
# self-test, run before every down_status row: it would have caught the false FAILs
s11_cli_failed_selftest() {
  s11_cli_failed 0 '{"id": "x", "error": ""}' && { echo "s11_cli_failed self-test: empty error read as failure"; return 1; }
  s11_cli_failed 0 '{"error": "node unreachable"}' || { echo "s11_cli_failed self-test: real error missed"; return 1; }
  s11_cli_failed 0 'error: calling daemon: rpc error' || { echo "s11_cli_failed self-test: error line missed"; return 1; }
  s11_cli_failed 1 '' || { echo "s11_cli_failed self-test: nonzero rc missed"; return 1; }
  return 0
}
s11_down_status() { # <proto> <stop|start>
  s11_hooks plat_node_kill plat_node_start || return $?
  s11_cli_failed_selftest || return 1
  local sid t0 t st eg lie=0 left='' seen=0 r rc=0 i n0 n1
  plat_connect "$1" || { echo "connect failed"; return 1; }
  sid=$(plat_sessions | head -1); sleep 3; n0=$(plat_node_session_count); echo "session $sid active, egress $(plat_egress), node sessions on the channel $n0"
  plat_node_kill KILL || { echo "node did not die"; return 1; }; t0=$(date +%s); echo "node killed $(date -u +%T)"
  while :; do
    t=$(( $(date +%s) - t0 )); [ "$t" -ge 35 ] && break
    st=$(cli client status "$sid" 2> /dev/null | grep -oE '"status": *"[a-z_]+"' | head -1 | grep -oE '[a-z_]+"$' | tr -d '"')
    eg=$(lab_curl -4 -s -m 1 "http://$INET:8090/" | grep -E '^[0-9.]+$' || echo none)
    echo "t+${t}s status=${st:-none} egress=$eg" >> "$SCEN_DIR/down-status.txt"
    [ "$st" = active ] && [ "$eg" = none ] && [ "$t" -gt 6 ] && lie=$((lie + 1))
    [ -z "$left" ] && [ "$st" != active ] && left=$t
    [ "$st" = "${CBM_DOWN_STATUS:-reconnecting}" ] && seen=$((seen + 1))
    sleep 1
  done
  echo "left active after: ${left:-never} s; active-while-dead samples after 6 s: $lie; '${CBM_DOWN_STATUS:-reconnecting}' samples: $seen (same id $sid)"
  [ "$lie" -eq 0 ] && [ -n "$left" ] && [ "$left" -le 8 ] || rc=1
  if [ "$2" = stop ]; then
    r=$(cli client stop "$sid" 2>&1); local src=$?; echo "stop at t+35 s: rc=$src $(grep -oE '"(error|message)": *"[^"]{0,120}|error: .{0,160}' <<<"$r" | head -1)"
    s11_cli_failed "$src" "$r" && rc=1
    sleep 10; plat_node_start || { echo "node restart failed"; return 1; }; sleep 20
    n1=$(plat_node_session_count)
    echo "node sessions opened after the stop + restart: $((n1 - n0)); client sessions live: $(plat_sessions | wc -l)"
    [ "$((n1 - n0))" -eq 0 ] && [ -z "$(plat_sessions)" ] || rc=1
  else
    sleep 10; plat_node_start || { echo "node restart failed"; return 1; }
    # same channel as the first session, so the money check (which sums every session on $CHANNEL and allows one
    # prepay window per session) covers the replacement too; a --new-channel start left it on a channel never read
    if [ -n "${CHANNEL:-}" ]; then r=$(cli client start --node "$NODE_ID" --channel "$CHANNEL" 2>&1)
    else r=$(cli client start --node "$NODE_ID" --new-channel --mode voucher --escrow-base-units "${ESCROW:-200000000}" 2>&1); fi
    local strc=$?
    echo "start during the redial (channel ${CHANNEL:-new}): rc=$strc $(grep -oE '"id": *"[^"]+"' <<<"$r" | head -1)$(grep -oE 'error: .{0,160}' <<<"$r" | head -1)"
    s11_cli_failed "$strc" "$r" && rc=1
    for i in $(seq 1 30); do [ "$(plat_egress)" = "$NODE_EGRESS" ] && break; sleep 2; done
    eg=$(plat_egress); echo "egress after the fresh start: $eg (node $NODE_EGRESS)"; [ "$eg" = "$NODE_EGRESS" ] || rc=1
  fi
  plat_disconnect > /dev/null 2>&1
  return $rc
}
s11_node_down_stop() { s11_down_status "$1" stop; }
s11_node_down_start() { s11_down_status "$1" start; }

# Tunnel address reuse + stale conntrack (SEC Q0184): a peer client pulls through the node, disconnects mid-pull, and
# this client connects within 4 s (likely the same tunnel address). Idle 15 s: what the node bills this session must
# match this client's own meter (a stale NAT flow of the peer would land here and inflate it).
s11_tunnel_addr_reuse() {
  s11_hooks plat_peer_connect plat_peer_disconnect plat_node_usage plat_client_usage || return $?
  local ps pa i dl ta nu cu nu0 cu0
  ps=$(plat_peer_connect) || { echo "peer connect failed"; return 1; }
  for i in $(seq 1 30); do plat_peer_active "$ps" && break; sleep 1; done
  pa=$(plat_peer_tunaddr); dl=$(plat_peer_pull "${CBM_BIG_URL/blob-50m/blob-200m}" 60)
  sleep 6; plat_peer_disconnect "$ps"; echo "peer $PEER ($pa) disconnected mid-pull $(date -u +%T)"
  sleep 1; plat_connect "$1" || { kill $dl 2> /dev/null; echo "connect failed"; return 1; }
  nu0=$(plat_node_usage); cu0=$(plat_client_usage)   # the matrix reuses one channel per node: deltas only
  ta=$(plat_tunaddr); echo "this client tunnel address $ta (peer had $pa)$([ -n "$ta" ] && [ "$ta" = "$pa" ] && echo ': REUSED')"
  sleep 15; kill $dl 2> /dev/null; wait $dl 2> /dev/null
  nu=$(( $(plat_node_usage) - nu0 )); cu=$(( $(plat_client_usage) - cu0 ))
  echo "idle 15 s: node bills ${nu:-?} B, client meter ${cu:-?} B"
  plat_disconnect
  # idle: both small; the node may not exceed the client by more than 64 KiB + 1 %
  [ -n "$nu" ] && [ -n "$cu" ] && awk -v n="$nu" -v c="$cu" 'BEGIN{exit !(n <= c * 1.01 + 65536)}'
}

# 5 % tolerance skim (SEC Q0337): the node reports usage x1.04 on WireGuard/AmneziaWG (inside the old flat 5 %). The client
# meter equals the node's wire bytes there, so it must not sign for the 4 %: PASS = a dispute/overcharge line, or the
# client paid no more than its own meter (+1 %) beyond the prepay block.
s11_tolerance_inflate() { # <proto> [factor, default 1.04 = Q0337: expected FAIL on a flat 5 % tolerance]
  case $1 in wireguard|amneziawg) ;; *) echo "tight tolerance applies to wireguard/amneziawg only"; return 77 ;; esac
  s11_hooks plat_node_hook_bin plat_node_restart_bin plat_node_usage plat_client_usage || return $?
  local b0 hb d0 m nu cu nu0 cu0 disp rc=1 fx=${2:-1.04}
  b0=$(plat_node_bin); hb=$(plat_node_hook_bin inflate-$fx) || { echo "no inflate hook build for $b0"; return 77; }
  plat_node_restart_bin "$hb" || return 1; echo "node on $hb"
  d0=$(grep -c . "$DLOG" 2> /dev/null || echo 0)
  if plat_connect "$1"; then
    nu0=$(plat_node_usage); cu0=$(plat_client_usage)
    m=$(s11_get "${CBM_BIG_URL}" 120); sleep 8
    nu=$(( $(plat_node_usage) - nu0 )); cu=$(( $(plat_client_usage) - cu0 ))
    disp=$(tail -n +"$((d0 + 1))" "$DLOG" | grep -aciE 'overcharg|dispute|usage.*(exceed|mismatch)' || true)
    echo "50 MB: $m | node reports ${nu:-?} B, client meter ${cu:-?} B (ratio $(awk -v n="${nu:-0}" -v c="${cu:-1}" 'BEGIN{printf "%.4f", n / c}')) | client dispute/overcharge lines: $disp"
    echo "$(plat_money)"
    plat_disconnect
    awk -v n="${nu:-0}" -v c="${cu:-1}" -v fx="$fx" 'BEGIN{exit !(n / c >= fx - 0.01)}' || echo "inflate did not take (ratio < $fx - 0.01): harness"
    [ "${disp:-0}" -gt 0 ] && rc=0
  else echo "connect failed"; fi
  plat_node_restart_bin "$b0"
  return $rc
}
s11_tolerance_inflate8() { s11_tolerance_inflate "$1" 1.08; }   # DIR 11-08: outside the flat 5 %, a dispute is expected even on stock

# Retransmit billing (SEC Q0349): 2 % loss on the node's uplink egress (tunnel packets to the client) during a 50 MB
# download. TCP inside the tunnel resends; the node may bill wire bytes, but not more than payload + framing + loss.
s11_retransmit_billing() { # <proto> [loss %, default 2]
  s11_hooks plat_node_netem plat_node_usage plat_client_usage || return $?
  local m nu cu b nu0 cu0 lp=${2:-2}
  plat_connect "$1" || { echo "connect failed"; return 1; }
  sleep 3; nu0=$(plat_node_usage); cu0=$(plat_client_usage)
  plat_node_netem "loss ${lp}%" || { plat_disconnect; echo "netem failed"; return 1; }
  m=$(s11_get "${CBM_BIG_URL}" 300); plat_node_netem off; sleep 6
  nu=$(( $(plat_node_usage) - nu0 )); cu=$(( $(plat_client_usage) - cu0 )); b=${m%% *}
  echo "50 MB at ${lp} % node-egress loss: $m | node bills ${nu:-?} B, client meter ${cu:-?} B, payload $b B -> node/payload $(awk -v n="${nu:-0}" -v p="${b:-1}" 'BEGIN{printf "%.3f", n / (p > 0 ? p : 1)}'), node/client $(awk -v n="${nu:-0}" -v c="${cu:-1}" 'BEGIN{printf "%.3f", n / (c > 0 ? c : 1)}')"
  plat_disconnect
  [ "${b:-0}" -ge 49000000 ] && awk -v n="${nu:-0}" -v p="$b" 'BEGIN{exit !(n / p <= 1.12)}'
}
s11_retransmit_billing0() { s11_retransmit_billing "$1" 0; }   # baseline, same build
s11_retransmit_billing5() { s11_retransmit_billing "$1" 5; }   # DIR 11-08: honest-gap data for the Q0337 per-tunnel default
s11_retransmit_billing10() { s11_retransmit_billing "$1" 10; }
s11_node_clock_skew() { echo "a netns cannot skew CLOCK_REALTIME; needs a node VM (FS36, node-4 final check)"; return 77; }
s11_credit_pause() { echo "FS36 (billing) owns the credit-pause/credit-exhausted rows"; return 77; }
