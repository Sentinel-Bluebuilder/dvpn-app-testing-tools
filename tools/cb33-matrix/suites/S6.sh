#!/usr/bin/env bash
# ─── S6 LAN + split (PLAN §1b). Bodies: TLX2 11-08. Owner after review: FWX; Windows split-by-app FWA, macOS FMC ───
# Platform-agnostic: every machine action goes through plat_* hooks. A cell whose hook the adapter lacks returns 77
# and names the hook, so a platform that claims S6 must implement them. Hooks (Linux: plat/linux.sh):
#   plat_set_allow_lan <true|false>    [network] allow_lan in the instance config (daemon restart is the caller's)
#   plat_lan_up / plat_lan_down        a LAN peer on a private v4 net, a ULA /64 and a global /64, listening on TCP
#   plat_lan_inbound_probe             echo delivered|blocked: one UDP datagram FROM the LAN peer to this host (#16)
#   plat_lan_probe <v4|ula|global>     echo ok|blocked: a TCP connect to that peer address (not ping: ICMPv6 is
#                                      allowed for neighbour discovery, so a ping would pass through a block)
#   plat_set_split <off|include|exclude> [cidr...]   [split] mode + routes in the instance config
#   plat_split_supported               rc 0 when the build under test reads [split] (pure 26de5240 does not)
#   plat_resolve4 <host>               one IPv4 of host, resolved outside any tunnel
#   plat_egress_at <host> <ip>         the public IPv4 that https://host/ sees when reached at ip (6 s cap)
#   plat_proxy_only <protocol>         optional: rc 0 when that protocol is a SOCKS proxy here (no device routes)
# Planted fault (phase 4): S6_PLANT=1 makes each cell write the opposite setting, as a build that ignored the
# setting would behave. Every cell must then FAIL. The global-v6 cell expects "blocked" either way, so its plant is
# in plat_lan_probe: the probe hits an admitted address, as a build that treated a global /64 as LAN would.
SCENARIOS="s6_allow_lan_v4:on s6_inbound_lan_v4:on:once s6_allow_lan_v6_ula:on s6_allow_lan_v6_global:on s6_split_include:off s6_split_exclude:off s6_settings_change_live:on"

S6_HOST=${S6_HOST:-checkip.amazonaws.com}   # the split target: an echo service on a different provider from ipify

s6_need() { local f; for f in "$@"; do declare -F "$f" >/dev/null || { echo "adapter has no $f"; return 77; }; done; }
s6_flip() { [ "${S6_PLANT:-0}" = 1 ] && { [ "$1" = true ] && echo false || echo true; } || echo "$1"; }

s6_restart() { plat_daemon_stop TERM; plat_daemon_start || { echo "daemon did not come back"; return 1; }; }

s6_restore() {
  declare -F plat_set_allow_lan >/dev/null && plat_set_allow_lan false
  declare -F plat_split_supported >/dev/null && plat_split_supported && plat_set_split off
  declare -F plat_lan_down >/dev/null && plat_lan_down
  return 0
}

s6_wrap() { local rc; "$@"; rc=$?; s6_restore; return $rc; }

# ─── allow-LAN: one LAN peer family, connected with allow_lan off and on (KS on) ───
# s6_lan_cell <family> <expect with allow_lan off> <expect with allow_lan on>
s6_lan_cell() {
  local fam=$1 want_off=$2 want_on=$3 lan got bad=0 e
  s6_need plat_set_allow_lan plat_lan_up plat_lan_down plat_lan_probe || return 77
  plat_lan_up || { echo "could not create the LAN peer"; return 1; }
  [ "$(plat_lan_probe "$fam")" = ok ] || { echo "LAN peer ($fam) unreachable with no VPN: the fixture is broken"; return 1; }
  for lan in false true; do
    plat_set_allow_lan "$(s6_flip $lan)"; s6_restart || return 1
    plat_connect "$PROTO" || { echo "connect failed (allow_lan=$lan)"; return 1; }
    sleep 4
    e=$(plat_egress); got=$(plat_lan_probe "$fam")
    local want=$want_off; [ $lan = true ] && want=$want_on
    echo "allow_lan=$lan: LAN $fam peer $got (want $want), egress $e"
    [ "$got" = "$want" ] || bad=1
    [ "$e" = "$NODE_EGRESS" ] || { echo "egress $e is not the node ($NODE_EGRESS) while connected"; bad=1; }
    plat_disconnect
  done
  return $bad
}
s6_allow_lan_v4()        { s6_wrap s6_lan_cell v4 blocked ok; }
s6_allow_lan_v6_ula()    { s6_wrap s6_lan_cell ula blocked ok; }        # fc00::/7 is a LAN range (upstream PR #15)
s6_allow_lan_v6_global() { s6_wrap s6_lan_cell global blocked blocked; } # a global /64 is not "LAN": never admitted

# ─── split by route (KS off): one echo service's address in or out of the tunnel ───
# s6_split_cell <include|exclude>
s6_split_cell() {
  local mode=$1 ip at direct_seen want_at want_rest bad=0
  s6_need plat_set_split plat_split_supported plat_resolve4 plat_egress_at || return 77
  plat_split_supported || { echo "this build has no [split] setting"; return 77; }
  declare -F plat_proxy_only >/dev/null && plat_proxy_only "$PROTO" && { echo "$PROTO is a SOCKS proxy here: a route split does not apply"; return 77; }
  ip=$(plat_resolve4 "$S6_HOST"); [ -n "$ip" ] || { echo "could not resolve $S6_HOST"; return 1; }
  [ "$(plat_egress_at "$S6_HOST" "$ip")" = "$DIRECT_IP" ] || { echo "$S6_HOST at $ip does not echo the direct IP with no VPN"; return 1; }
  if [ "${S6_PLANT:-0}" = 1 ]; then plat_set_split off; else plat_set_split "$mode" "$ip/32"; fi
  s6_restart || return 1
  plat_connect "$PROTO" || { echo "connect failed (split $mode $ip/32)"; return 1; }
  sleep 4
  if [ "$mode" = include ]; then want_at=$NODE_EGRESS; want_rest=$DIRECT_IP; else want_at=$DIRECT_IP; want_rest=$NODE_EGRESS; fi
  at=$(plat_egress_at "$S6_HOST" "$ip"); direct_seen=$(plat_egress)
  echo "split $mode $ip/32: $S6_HOST sees $at (want $want_at); everything else (ipify) sees $direct_seen (want $want_rest)"
  [ "$at" = "$want_at" ] || bad=1
  [ "$direct_seen" = "$want_rest" ] || bad=1
  plat_disconnect
  return $bad
}
s6_split_include() { s6_wrap s6_split_cell include; }
s6_split_exclude() { s6_wrap s6_split_cell exclude; }

# ─── a settings change during a live session (KS on) ───
# The app applies settings by writing the config and restarting the service (devnet-dvpn-linux settings.ts). Change
# allow_lan off → on with a session up, restart as the app does, then the new setting must hold on the live (or
# resumed) session and on the next connect.
s6_settings_change_live_body() {
  local st e got bad=0
  s6_need plat_set_allow_lan plat_lan_up plat_lan_down plat_lan_probe || return 77
  plat_lan_up || { echo "could not create the LAN peer"; return 1; }
  plat_set_allow_lan false; s6_restart || return 1
  plat_connect "$PROTO" || { echo "connect failed"; return 1; }
  sleep 4
  got=$(plat_lan_probe v4); echo "before the change: LAN v4 $got (want blocked), egress $(plat_egress)"
  [ "$got" = blocked ] || bad=1
  plat_set_allow_lan "$(s6_flip true)"; s6_restart || return 1
  sleep 15
  st=$(plat_status_line); e=$(plat_egress); got=$(plat_lan_probe v4)
  echo "after the change + restart: $st | egress $e | LAN v4 $got"
  case $st in
    state=active*) [ "$got" = ok ] || { echo "the live session kept the old setting"; bad=1; }
                   [ "$e" = "$NODE_EGRESS" ] || { echo "active but egress $e is not the node"; bad=1; } ;;
    *) echo "the session did not survive the restart; reconnecting" ;;
  esac
  plat_disconnect
  plat_connect "$PROTO" || { echo "reconnect failed"; return 1; }
  sleep 4
  got=$(plat_lan_probe v4); e=$(plat_egress)
  echo "next connect: LAN v4 $got (want ok), egress $e"
  [ "$got" = ok ] || bad=1
  [ "$e" = "$NODE_EGRESS" ] || bad=1
  plat_disconnect
  return $bad
}
s6_settings_change_live() { s6_wrap s6_settings_change_live_body; }

# ─── inbound (KS on, allow_lan off): a LAN peer must not reach this host either (upstream #16, FLX 11-08) ───
# Pure 26de5240 filters output only, so the peer's datagram is delivered: FAIL there, PASS with #16's input chain.
s6_inbound_lan_v4() {
  s6_need plat_set_allow_lan plat_lan_up plat_lan_down plat_lan_inbound_probe || return 77
  s6_wrap s6_inbound_cell
}
s6_inbound_cell() {
  local got e
  plat_lan_up || { echo "could not create the LAN peer"; return 1; }
  [ "$(plat_lan_inbound_probe)" = delivered ] || { echo "LAN peer cannot reach this host with no VPN: the fixture is broken"; return 1; }
  plat_set_allow_lan false; s6_restart || return 1
  plat_connect "$PROTO" || { echo "connect failed"; return 1; }
  sleep 4
  got=$(plat_lan_inbound_probe 2>> "$SCEN_DIR/scenario.log"); e=$(plat_egress)
  echo "ks=on allow_lan=false: inbound datagram from the LAN peer $got (want blocked), egress $e"
  plat_disconnect
  [ "$got" = unknown ] && { echo "the probe send stalled past the listener: cannot judge"; return 1; }
  [ "$got" = blocked ]
}
