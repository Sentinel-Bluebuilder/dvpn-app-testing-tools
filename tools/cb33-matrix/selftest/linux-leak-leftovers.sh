#!/usr/bin/env bash
# ─── Phase-4 forced-fail cases for the LEAK and LEFTOVERS checks, Linux (TLX) ───
# Each case plants ONE real fault, runs the check, and expects FAIL. Two clean controls expect PASS, so the check
# can't pass the selftest by failing everything. Every plant is removed afterwards, also on error (trap).
# Run on the test VM, from the cb33-matrix dir, after the platform adapter is loaded:
#   bash selftest/linux-leak-leftovers.sh            → one line per case + a summary; exit 0 only if all match
# Needs: sudo -n, tcpdump, nft, iproute2. No session, no chain traffic, no wallet.
set -u
cd "$(dirname "$0")/.." || exit 2
. lib/common.sh; . plat/linux.sh; . checks/leak.sh; . checks/leftovers.sh
NODE=${NODE:-node-4}
OUT=${OUT:-$HOME/cb33-matrix-out/selftest-tlx-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$OUT"
SCEN_DIR=$OUT; plat_init >/dev/null 2>&1 || echo "note: plat_init failed (no daemon binary?); using fallbacks"
# The cases need no daemon; fill in what plat_init would have set.
NODE_IP=${NODE_IP:-192.0.2.4}
PHYS_IF=${PHYS_IF:-$(ip -4 route show default | awk '{print $5; exit}')}
GATEWAY_IP=${GATEWAY_IP:-$(ip -4 route show default | awk '{print $3; exit}')}
CONTROL_IP=${CONTROL_IP:-$(echo "${SSH_CLIENT:-}" | awk '{print $1}')}
INSTANCE=${INSTANCE:-c1}
# Cloud host channels (never the internet): Azure wireserver/DNS 168.63.129.16, metadata 169.254.169.254 (Azure,
# GCP, AWS). The box's own agents talk to them all the time; checks/leak.sh skips LEAK_ALLOW_HOSTS (FWX patch).
LEAK_ALLOW_HOSTS=${LEAK_ALLOW_HOSTS:-168.63.129.16 169.254.169.254}
# The plant's window is its own 1-2 s run, so there is no edge skew to allow for (checks/leak.sh LEAK_EDGE_S).
LEAK_EDGE_S=0
# A documentation address (RFC 5737) for planted routes: never a real destination.
PLANT_V4=192.0.2.77
# The dead-man's own probe (curl www.google.com every 40 s) would show up in every capture. A fresh hold makes it
# exit before probing; nothing here cuts the network, so holding it is safe. Refreshed every 30 s until we exit.
# Holder exits with this script ($$ = this script's pid): `while :` outlived a `timeout`-killed run on r2 (11-07).
( me=$$; while kill -0 "$me" 2>/dev/null; do sudo -n touch /run/ddv-deadman.hold; sleep 30; done ) & HOLDER=$!
ok=0; bad=0
expect() { # $1 case $2 expected PASS|FAIL $3 got
  if [ "$3" = "$2" ]; then ok=$((ok + 1)); echo "OK    $1: expected $2, got $3"
  else bad=$((bad + 1)); echo "WRONG $1: expected $2, got $3"; fi
}
got() { [ "${SCENARIO_FAILED:-0}" = 1 ] && echo FAIL || echo PASS; }

# ─── Leak: plant traffic on the physical NIC, then judge the capture ───
leak_case() { # $1 name $2 ks mode $3 expected $4.. command to plant (runs while capturing)
  local name=$1 ks=$2 want=$3; shift 3
  SCEN_DIR=$OUT/leak-$name; mkdir -p "$SCEN_DIR"; : > "$SCEN_DIR/active-windows.txt"
  leak_start; sleep 1
  local t0 t1; t0=$(date +%s)
  "$@" >/dev/null 2>&1
  t1=$(date +%s)
  sleep 1
  # KS off judges only while a session was active: mark exactly the plant's own run as active, so the box's
  # background lookups (there is no tunnel resolver in a selftest) stay outside the window.
  echo "$t0 $t1" > "$SCEN_DIR/active-windows.txt"
  SCENARIO_FAILED=0; SCENARIO=selftest-leak-$name leak_stop "$ks"
  expect "leak/$name (ks=$ks)" "$want" "$(got)"
}
nothing() { sleep 2; }
to_node() { curl -4 -s -m 4 --interface "$PHYS_IF" "https://$NODE_IP:18715/" -k; }
tcp_direct() { curl -4 -s -m 4 --interface "$PHYS_IF" https://1.1.1.1; }
dns_direct() { dig +time=2 +tries=1 @8.8.8.8 example.com A; }
dns_dot() { timeout 4 bash -c 'exec 3<>/dev/tcp/1.1.1.1/853'; }
v6_direct() { curl -6 -s -m 4 --interface "$PHYS_IF" https://[2606:4700:4700::1111]/; }

leak_case control-quiet      on  PASS nothing
leak_case control-to-node    on  PASS to_node
leak_case tcp-direct         on  FAIL tcp_direct
leak_case dns-udp-direct     on  FAIL dns_direct
leak_case dns-udp-direct-ksoff off FAIL dns_direct
leak_case dot-direct-ksoff   off FAIL dns_dot
leak_case tcp-direct-ksoff   off PASS tcp_direct      # KS off: plain TCP is allowed; only DNS/IPv6 count
if ip -6 route show default | grep -q .; then
  leak_case v6-direct-ksoff  off FAIL v6_direct
else
  echo "SKIP  leak/v6-direct-ksoff: no IPv6 default route on this VM"
fi

# ─── Leak, ks=persist: the block holds from the first active window to the last one's end (DIR 11-08) ───
# $1 name $2 expected $3 window placement relative to the plant: gap | before | after
leak_persist_case() {
  local name=$1 want=$2 where=$3
  SCEN_DIR=$OUT/leak-$name; mkdir -p "$SCEN_DIR"; : > "$SCEN_DIR/active-windows.txt"
  leak_start; sleep 1
  local t0 t1; t0=$(date +%s); tcp_direct >/dev/null 2>&1; t1=$(date +%s); sleep 1
  case $where in
    gap)    printf '%s %s
%s %s
' $((t0 - 30)) $((t0 - 20)) $((t1 + 20)) $((t1 + 30)) ;;  # daemon down between sessions
    before) printf '%s %s
' $((t1 + 20)) $((t1 + 30)) ;;                                  # plant before the first session
    after)  printf '%s %s
' $((t0 - 30)) $((t0 - 20)) ;;                                  # plant after the user's disconnect
  esac > "$SCEN_DIR/active-windows.txt"
  SCENARIO_FAILED=0; SCENARIO=selftest-leak-$name leak_stop persist
  expect "leak/$name (ks=persist)" "$want" "$(got)"
}
leak_persist_case persist-gap-between-sessions FAIL gap
leak_persist_case persist-before-first-session PASS before
leak_persist_case persist-after-last-session   PASS after

if [ "${LEAK_ONLY:-0}" = 1 ]; then
  echo "SUMMARY linux-leak (LEAK_ONLY): $ok as expected, $bad wrong (evidence in $OUT)"
  kill "$HOLDER" 2>/dev/null; sudo -n rm -f /run/ddv-deadman.hold
  [ "$bad" = 0 ]; exit
fi

# ─── Leftovers: plant one leftover of each kind, run the check, remove it ───
UNPLANT=()
cleanup() { local u; for u in "${UNPLANT[@]}"; do eval "$u" >/dev/null 2>&1; done; UNPLANT=()
  kill "$HOLDER" 2>/dev/null; sudo -n rm -f /run/ddv-deadman.hold; }
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM   # a timeout kill still runs cleanup (TLX, 11-07)
left_case() { # $1 name $2 expected $3 plant command $4 unplant command
  local name=$1 want=$2
  SCEN_DIR=$OUT/left-$name; mkdir -p "$SCEN_DIR"
  [ -n "$3" ] && { eval "$3" >/dev/null 2>&1 || { echo "SKIP  leftovers/$name: could not plant"; return; }; }
  UNPLANT+=("$4")
  SCENARIO_FAILED=0; SCENARIO=selftest-left-$name
  ( plat_reset() { :; }; leftovers_stop; echo "$SCENARIO_FAILED" > "$SCEN_DIR/failed" )
  SCENARIO_FAILED=$(cat "$SCEN_DIR/failed" 2>/dev/null || echo 0)
  eval "$4" >/dev/null 2>&1; UNPLANT=("${UNPLANT[@]:0:${#UNPLANT[@]}-1}")
  expect "leftovers/$name" "$want" "$(got)"
}
left_case control-clean   PASS "" ":"
left_case nft-table       FAIL "sudo nft add table inet sentinel-dvpn-c9" "sudo nft delete table inet sentinel-dvpn-c9"
left_case wgquick-table   FAIL "sudo nft add table ip wg-quick-dvpn-c9" "sudo nft delete table ip wg-quick-dvpn-c9"
left_case tunnel-link     FAIL "sudo ip link add dvpn-c9 type dummy" "sudo ip link del dvpn-c9"
left_case ip-rule         FAIL "sudo ip rule add pref 9001 to 100.100.100.100/30 lookup 2022" "sudo ip rule del pref 9001"
left_case ip6-rule        FAIL "sudo ip -6 rule add pref 9002 lookup 2022" "sudo ip -6 rule del pref 9002"
# Q0428: OpenVPN's host route to the node, left in the main table after the process dies
left_case host-route-main FAIL "sudo ip route add $PLANT_V4/32 via $GATEWAY_IP dev $PHYS_IF" "sudo ip route del $PLANT_V4/32"
left_case route-other-table FAIL "sudo ip route add default dev lo table 2022" "sudo ip route del default dev lo table 2022"
# A harmless copy of sleep NAMED openvpn (the check matches program names, pgrep -x); 7311 makes the unplant exact.
left_case protocol-process FAIL "mkdir -p /tmp/tlx-sel && cp /bin/sleep /tmp/tlx-sel/openvpn && setsid /tmp/tlx-sel/openvpn 7311 </dev/null >/dev/null 2>&1 &" "pkill -f '^/tmp/tlx-sel/openvpn 7311$'; rm -rf /tmp/tlx-sel"
left_case secret-file     FAIL "sudo mkdir -p /var/lib/sentinel-dvpn/$INSTANCE/openvpn && sudo touch /var/lib/sentinel-dvpn/$INSTANCE/openvpn/tlx-selftest.key" "sudo rm -f /var/lib/sentinel-dvpn/$INSTANCE/openvpn/tlx-selftest.key"

echo "SUMMARY linux-leak-leftovers: $ok as expected, $bad wrong (evidence in $OUT)"
[ "$bad" = 0 ]
