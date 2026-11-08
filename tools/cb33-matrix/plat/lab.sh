#!/usr/bin/env bash
# ─── Lab adapter (TS36, 11-07): the netns bandwidth rig (a separate lab checkout) ───
# Localnet validator + 7 nodes (one protocol each) + clients in network namespaces, inside the lab container.
# Run the WHOLE driver inside the client's netns, as root in the container, so curl / egress / capture are the client's:
#   ip netns exec bwl-c2 bash cb33-matrix.sh --platform lab --side A --node n1 --suites S1 --out /root/cbm-lab-A
# --node takes a lab node (n1..n7); every lab node has the same owner, so lib/nodes.sh finds one entry per protocol.
# Chain and daemon CLI calls run from the hub netns (a client kill switch would block the lab RPC from bwl-c2).
# Knobs: CBM_LAB_CLIENT (c2), CBM_LAB_BIN (the dvpnd under test, default = the one the rig started the client with),
#        CBM_LAB_PLANT_MTU=1 (selftest for the S1 floor: drop tunnel packets > 1400 B into the client).

LAB=${LAB:-/home/ubuntu/bw-lab}
INSTANCE=${CBM_LAB_CLIENT:-c2}
LHOME=$LAB/homes/$INSTANCE
CFG=$LHOME/config.toml
DLOG=$LHOME/dvpnd.log
INET=198.18.0.1
LAB_CLI=$(sed -n 's/^cli=//p' "$LAB/homes/.cb33" 2>/dev/null)
LAB_RPC=(--rpc.url http://10.77.0.1:8899 --rpc.ws-url ws://10.77.0.1:8900)
TX_GAP=${TX_GAP:-2}   # localnet: no shared wallet, no rate limit (devnet stays 7 s)
declare -A CHAN_BY_NODE=()

sudo() { "$@"; }   # the driver runs as root in the container; the checks call sudo
cli() { ip netns exec bwl-hub "$LAB_CLI" "${LAB_RPC[@]}" --output json --daemon.endpoint "$LHOME/daemon.sock" \
  --instance "$INSTANCE" "$@" 2>&1 | tee -a "${SCEN_DIR:-$OUT}/cli.txt"; }
plat_chain_cli() { ip netns exec bwl-hub "$LAB_CLI" "${LAB_RPC[@]}" --output json "$@"; }

plat_init() {
  [ "$(ip netns identify $$)" = "bwl-$INSTANCE" ] || { say "run the driver inside netns bwl-$INSTANCE (see plat/lab.sh)"; return 1; }
  [ -x "$LAB_CLI" ] || { say "no cb33 CLI in $LAB/homes/.cb33"; return 1; }
  local n=${NODE#lab-}; [ -f "$LAB/homes/$n/node.json" ] || { say "no lab node $n"; return 1; }
  NODE_ID=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["node"])' "$LAB/homes/$n/node.json")
  NODE_IP=$(ip netns exec "bwl-$n" ip -4 -br addr show eth0 | awk '{print $3}' | cut -d/ -f1)
  NODE_EGRESS=$NODE_IP
  PHYS_IF=eth0; GATEWAY_IP=$(ip -4 route show default | awk '{print $3; exit}'); CONTROL_IP=''; LEAK_ALLOW_HOSTS=''
  DIRECT_IP=$(ip -4 -br addr show eth0 | awk '{print $3}' | cut -d/ -f1)
  PHYS_ADDRS=$(ip -o addr show dev eth0 scope global | awk '{split($4, a, "/"); print a[1]}' | tr '\n' ' ')
  LAB_BIN=${CBM_LAB_BIN:-$(awk '/ start /{b=$NF} END{print b}' "$LHOME/binary.log")}
  [ -x "$LAB_BIN" ] || { say "no dvpnd $LAB_BIN"; return 1; }
  command -v tcpdump >/dev/null || say "   no tcpdump in the container: the leak check will SKIP (apt-get install -y tcpdump)"
  lab_hub_services || return 1
  CBM_BIG_URL=${CBM_BIG_URL:-http://$INET:8080/blob-50m}; CBM_SLOW_URL=${CBM_SLOW_URL:-http://$INET:8080/blob-2m}
  CBM_MIN_MBPS=${CBM_MIN_MBPS:-2.5}
  CBM_WG_RATIO=${CBM_WG_RATIO:-0}   # lab WG runs 60-90 MB/s: judge on the absolute floor + the A-run rule (FWX 4e28365)
  CBM_REDEEM_WAIT=${CBM_REDEEM_WAIT:-30}   # node_settled is the node's own record here, there is no chain redeem to wait for
  ESCROW=${ESCROW:-200000000}
  RTX_LAST=$(lab_retrans)
  deadman_start
}
# The hub "internet": an egress echo (who am I, as the hub sees me) on :8090, and 50 MB / 2 MB blobs next to blob-200m.
lab_hub_services() {
  local d; d=$(find "$LAB" /root /home/ubuntu -maxdepth 3 -name blob-200m -printf '%h\n' 2>/dev/null | head -1)
  [ -n "$d" ] || { say "no blob-200m under $LAB"; return 1; }
  [ -s "$d/blob-50m" ] || head -c 50000000 "$d/blob-200m" > "$d/blob-50m"
  [ -s "$d/blob-2m" ] || head -c 2000000 "$d/blob-200m" > "$d/blob-2m"
  curl -s -m 3 -o /dev/null "http://$INET:8080/blob-2m" || { say "hub http :8080 does not serve $d"; return 1; }
  curl -s -m 3 "http://$INET:8090/" | grep -qE '^[0-9.]+$' && return 0
  ip netns exec bwl-hub setsid nohup python3 -I -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = self.client_address[0].encode(); self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("198.18.0.1", 8090), H).serve_forever()' > /dev/null 2>&1 < /dev/null &
  sleep 1; curl -s -m 3 "http://$INET:8090/" | grep -qE '^[0-9.]+$' || { say "egress echo on :8090 did not start"; return 1; }
}

# Every lab node has its own owner (one protocol each), so the owner search in lib/nodes.sh finds one entry. Same
# chain source, wider net: `node show` for each lab node home, parsed by the shared node_entries_parse (chain bits).
node_resolve() {
  local f="$OUT/node-entries.json" h a
  if [ ! -s "$f" ]; then
    { echo '['; local sep=''
      for h in "$LAB"/homes/n[0-9]*/node.json; do
        a=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["node"])' "$h") || continue
        printf '%s' "$sep"; plat_chain_cli node show "$a" 2>/dev/null || return 1; sep=','
      done; echo ']'; } > "$f" || { say "   nodes: node show failed"; return 1; }
  fi
  node_entries_parse "$f" > "$OUT/node-entries.txt" || return 1
  [ -s "$OUT/node-entries.txt" ] || { say "   nodes: no listed lab entry"; return 1; }
  say "   nodes (chain, lab): $(awk '{ printf "%s=%s ", $1, $3 }' "$OUT/node-entries.txt")"
}

plat_build() { "$LAB_BIN" version 2>&1 | head -1 | cut -c1-160; }
plat_protocols() { echo "${CBM_PROTOCOLS:-wireguard amneziawg openvpn hysteria2 v2ray xray}"; }

dpid() { ps -eo pid,args | awk -v h="$LHOME" '$2 ~ /\/dvpnd(-[a-z0-9+-]+)?$/ { for (i = 3; i <= NF; i++) if ($i == h) print $1 }' | head -1; }
plat_daemon_running() { [ -n "$(dpid)" ]; }
plat_daemon_start() {
  plat_daemon_running && return 0
  # setsid: a daemon started under `docker exec` dies with that exec unless it has its own session (11-07, c2 lost)
  (cd "$LAB/lab" && DVPND=$LAB_BIN setsid bash provision.sh start "$INSTANCE" < /dev/null) >> "$OUT/daemon-starts.log" 2>&1 || return 1
  local i; for i in $(seq 1 20); do [ -S "$LHOME/daemon.sock" ] && cli client sessions > /dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
plat_daemon_stop() {
  local p; p=$(dpid); [ -n "$p" ] && kill "-${1:-TERM}" "$p"
  local i; for i in $(seq 1 20); do plat_daemon_running || { rm -f "$LHOME/dvpnd.pid"; return 0; }; sleep 1; done
  return 1
}

# Lab nodes serve one protocol each, so a channel belongs to a node: one channel per node for the run.
plat_connect() {
  local proto=$1 out
  NODE_EGRESS=$NODE_IP   # node_for set this protocol's node; the hub sees the node's own address (NAT)
  CHANNEL=${CHAN_BY_NODE[$NODE_ID]:-}
  tx_gap
  if [ -n "$CHANNEL" ]; then
    out=$(cli client start --node "$NODE_ID" --channel "$CHANNEL")
  else
    out=$(cli client start --node "$NODE_ID" --new-channel --mode voucher --escrow-base-units "$ESCROW")
    CHANNEL=$(grep -oE '"channel(_id)?": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$CHANNEL" ] && { CHAN_BY_NODE[$NODE_ID]=$CHANNEL; CHANNEL_NEW=1; say "   opened channel $CHANNEL to $NODE_ID"; }
  fi
  SID=$(grep -oE '"id": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  [ -z "$SID" ] && SID=$(plat_sessions | head -1)
  [ -n "$SID" ] || return 1
  local i st; for i in $(seq 1 30); do
    st=$(cli client status "$SID" | grep -oE '"status": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ "$st" = active ] && break; sleep 1
  done
  [ "${CBM_LAB_PLANT_MTU:-0}" = 1 ] && lab_plant_mtu
  lab_proxy_on "$proto"
  [ "$st" = active ]
}
# Lab v2ray/xray clients are proxy-only (c2 <svc>/config.toml: proxy_port, no tun): traffic that should use the
# session goes through that local SOCKS port. S1's curls see ALL_PROXY; the background status poller (forked before
# the connect) reads the flag file instead.
LAB_PROXY_FLAG=''
lab_proxy_on() {
  local port; LAB_PROXY_FLAG=$OUT/.lab-proxy
  case $1 in v2ray|xray) port=$(sed -nE 's/^proxy_port = ([0-9]+)/\1/p' "$LHOME/$1/config.toml") ;; *) port='' ;; esac
  if [ -n "$port" ]; then echo "socks5h://127.0.0.1:$port" > "$LAB_PROXY_FLAG"; export ALL_PROXY=$(cat "$LAB_PROXY_FLAG")
  else lab_proxy_off; fi
}
lab_proxy_off() { rm -f "$OUT/.lab-proxy"; unset ALL_PROXY; }
lab_curl() { local p; p=$(cat "$OUT/.lab-proxy" 2>/dev/null); if [ -n "$p" ]; then curl -x "$p" "$@"; else curl --noproxy '*' "$@"; fi; }
plat_disconnect() {
  local s rc=0
  lab_proxy_off   # before the stop: the "after disconnect" probes are direct
  for s in $(plat_sessions); do tx_gap; cli client stop "$s" > /dev/null || rc=1; done
  lab_unplant_mtu
  return $rc
}
plat_sessions() {
  cli client sessions 2>/dev/null | python3 -I -c 'import json,sys
d = json.load(sys.stdin); ss = d.get("sessions", d) if isinstance(d, dict) else d
for s in ss or []:
    if s.get("status") in ("active", "reconnecting", "connecting", "checking"): print(s["id"])' 2>/dev/null
}
plat_status_line() {
  local s out st ks
  ks=$(grep -oE "^kill_switch = '[a-z]+'" "$CFG" | grep -oE "'[a-z]+'" | tr -d "'")
  for s in $(plat_sessions); do
    out=$(timeout 1 ip netns exec bwl-hub "$LAB_CLI" --output json --daemon.endpoint "$LHOME/daemon.sock" --instance "$INSTANCE" client status "$s" 2>&1)
    st=$(grep -oE '"status": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    case $st in active|reconnecting|connecting|checking) break ;; esac
  done
  echo "state=${st:-none} ks=${ks:-off} id=${s:--} text=$(grep -oE '"(error|message)": *"[^"]*"' <<<"${out:-}" | head -1 | tr '\n' ' ')"
}

plat_egress() { lab_curl -4 -s -m 6 "http://$INET:8090/" | grep -E '^[0-9.]+$' || echo none; }
plat_egress6() { echo none; }   # the lab has no IPv6 path (S11 node_no_ipv6 covers the node side)
plat_dns_probe() { awk '/^nameserver/{print $2; exit}' /etc/resolv.conf; }   # lab clients run dns_backend 'none'

plat_set_ks() { sed -i -E "s/^kill_switch = '[a-z]+'/kill_switch = '$1'/" "$CFG"; }

plat_capture_start() {
  command -v tcpdump >/dev/null || { CAP_PID=''; return 0; }
  tcpdump -i "$PHYS_IF" -nn -w "$1" -U > /dev/null 2>&1 & CAP_PID=$!; sleep 1
}
plat_capture_stop() { [ -n "${CAP_PID:-}" ] && kill "$CAP_PID" 2>/dev/null; sleep 1; return 0; }
plat_plant_leak() { curl -s -m 3 -o /dev/null "http://$INET:8080/blob-2m" --interface eth0; }

plat_leftovers() {
  nft list tables 2>/dev/null | grep -vE "cbmcut|cbmmtu" | sed 's/^/nft: /'
  ip -br link 2>/dev/null | awk '$1 ~ /^(dvpn|wg|tun|sing)/ {print "link: " $1}'
  ip rule 2>/dev/null | grep -vE "^(0|32766|32767):" | sed 's/^/ip rule: /'
  ip -4 route show table main 2>/dev/null | grep -vE '^default|proto kernel|dev lo' | sed 's/^/route: /'
  ip -4 route show table all 2>/dev/null | grep -E ' table ' | grep -vE ' table (local|main|default)( |$)' | sed 's/^/route table: /'
  ps -eo args | awk -v h="$LHOME" 'index($0, h) && $1 ~ /(xray|v2ray|hysteria|openvpn)/' | sed 's/^/process: /'
  find "$LHOME" -maxdepth 3 -type f \( -name '*.key' -o -name '*auth.txt' -o -name '*.conf' -o -name '*.yaml' \) 2>/dev/null | sed 's/^/file: /'
}
plat_plant_leftover() { nft add table inet sentinel-dvpn-c9 && ip route add 192.0.2.9 via "$GATEWAY_IP" dev eth0; }
plat_unplant_leftover() { nft delete table inet sentinel-dvpn-c9 2>/dev/null; ip route del 192.0.2.9 2>/dev/null; return 0; }

plat_cut() {
  nft add table inet cbmcut && nft 'add chain inet cbmcut out { type filter hook output priority -10; }' \
    && nft add rule inet cbmcut out ip daddr "$NODE_IP" drop
  [ -n "${1:-}" ] && { sleep "$1"; plat_uncut; }
  return 0
}
plat_uncut() { nft delete table inet cbmcut 2>/dev/null; return 0; }

# S1 floor selftest (FWX 11-07): an MTU black hole on purpose. Small tunnel packets pass, full-size ones (> 1400 B
# outer) from the node are dropped, so connect/egress/DNS pass and only bulk TCP collapses: the throughput row must FAIL.
lab_plant_mtu() {
  nft add table inet cbmmtu && nft 'add chain inet cbmmtu in { type filter hook input priority -10; }' \
    && nft add rule inet cbmmtu in ip saddr "$NODE_IP" ip length gt 1400 counter drop \
    && say "   PLANT: dropping packets > 1400 B from $NODE_IP (S1 floor selftest)"
}
lab_unplant_mtu() { nft list tables 2>/dev/null | grep -q cbmmtu && { say "   PLANT counters: $(nft list table inet cbmmtu | grep -oE 'packets [0-9]+ bytes [0-9]+')"; nft delete table inet cbmmtu; }; return 0; }

lab_retrans() { awk '/^Tcp:/{if(!h){for(i=1;i<=NF;i++) if($i=="RetransSegs") c=i; h=1} else print $c}' /proc/net/snmp; }
plat_tcp_retrans() { local now; now=$(lab_retrans); echo $(( now - ${RTX_LAST:-now} )); RTX_LAST=$now; }

plat_cli_outputs() { cat "$SCEN_DIR/cli.txt" 2>/dev/null; grep -oE '"(error|message|reason)":"[^"]*"' "$DLOG" 2>/dev/null | tail -50; }

chain_channel_field() { # $1 field
  [ -n "${CHANNEL:-}" ] || return 1
  plat_chain_cli channel show "$CHANNEL" 2>/dev/null | grep -oE "\"$1\": *[0-9]+" | head -1 | grep -oE '[0-9]+$'
}
plat_money() {
  local j redeemed escrow settled=unknown spent n
  j=$(cli client sessions 2>/dev/null)
  spent=$(awk -v ch="$CHANNEL" '/"spent":/ {gsub(/[^0-9]/, "", $2); s = $2} /"channel":/ {if (index($0, ch) && ch != "") t += s; s = 0} END {print t + 0}' <<<"$j")
  redeemed=$(chain_channel_field redeemed); escrow=$(chain_channel_field escrow)
  # cb33 nodes redeem on chain only when the channel closes (closerace: start_close_channel, node redeems in the grace),
  # and the matrix keeps one channel open per node, so chain `redeemed` stays 0 all run. The lab owns its nodes: the
  # node's own session usage for this channel (rx+tx at its price per GB) is what it will redeem = node_settled.
  [ -n "${CHANNEL:-}" ] && settled=$(lab_node_settled) || settled=unknown
  n=$(awk -v ch="$CHANNEL" '/"channel":/ {if (index($0, ch) && ch != "") c++} END {print c + 0}' <<<"$j")
  MONEY_PREPAY_ALLOW=$(( n * $(prepay_window_units) ))
  echo "spent=$spent paid=unknown node_settled=$settled redeemed=${redeemed:-unknown} escrow=${escrow:-unknown} prepay_allow=$MONEY_PREPAY_ALLOW"
}
lab_node_settled() {
  local h nh='' ppg
  for h in "$LAB"/homes/n[0-9]*; do grep -q "\"$NODE_ID\"" "$h/node.json" 2>/dev/null && { nh=$h; break; }; done
  [ -n "$nh" ] || { echo unknown; return; }
  ppg=$(plat_chain_cli node show "$NODE_ID" 2>/dev/null | grep -oE '"channel_price_per_gb": *[0-9]+' | grep -oE '[0-9]+$')
  ip netns exec bwl-hub "$LAB_CLI" --output json --daemon.endpoint "$nh/daemon.sock" --instance "${nh##*/}" node sessions 2>/dev/null |
    python3 -I -c 'import json,sys,math
ch, ppg = sys.argv[1], int(sys.argv[2] or 0)
b = sum(s["usage"]["rx_bytes"] + s["usage"]["tx_bytes"] for s in json.load(sys.stdin).get("sessions", []) if s.get("subject") == ch)
print(math.ceil(b * ppg / 1e9) if ppg else "unknown")' "$CHANNEL" "${ppg:-0}" 2>/dev/null || echo unknown
}
prepay_window_units() { # same formula as plat/linux.sh (FWX 2c7d771), node metadata read over the lab net
  local basis pb ps meta uri mpb mps ppg pph
  basis=$(sed -nE "s/^basis = '([a-z_]+)'/\1/p" "$CFG" | head -1)
  pb=$(sed -nE 's/^prepay_bytes = ([0-9]+)/\1/p' "$CFG" | head -1); ps=$(sed -nE 's/^prepay_seconds = ([0-9]+)/\1/p' "$CFG" | head -1)
  uri=$(plat_chain_cli node show "$NODE_ID" 2>/dev/null | grep -oE '"uri": *"https://[^"]+"' | head -1 | grep -oE 'https://[^"]+')
  [ -n "$uri" ] && meta=$(curl -sk -m 8 "$uri/v1/metadata")
  mpb=$(grep -oE '"min_channel_prepay_bytes":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); mps=$(grep -oE '"min_channel_prepay_seconds":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  ppg=$(grep -oE '"channel_price_per_gb":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); pph=$(grep -oE '"channel_price_per_hour":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  awk -v b="${basis:-per_gb}" -v pb="${pb:-0}" -v ps="${ps:-0}" -v mpb="${mpb:-0}" -v mps="${mps:-0}" -v ppg="${ppg:-0}" -v pph="${pph:-0}" 'BEGIN {
    if (b == "per_hour") { s = (ps > mps ? ps : mps); v = s * pph / 3600 } else { y = (pb > mpb ? pb : mpb); v = y * ppg / 1e9 }
    printf "%d\n", (v == int(v) ? v : int(v) + 1) }'
}

# ─── Node-side hooks (S11; lab only: the lab owns its nodes) ───
plat_node_home() { local h; for h in "$LAB"/homes/n[0-9]*; do grep -q "\"$NODE_ID\"" "$h/node.json" 2>/dev/null && { echo "$h"; return 0; }; done; return 1; }
plat_node_pid() { local h; h=$(plat_node_home) || return 1
  ps -eo pid,args | awk -v h="$h" '$2 ~ /\/dvpnd(-[a-z0-9+-]+)?$/ { for (i = 3; i <= NF; i++) if ($i == h) print $1 }' | head -1; }
plat_node_kill() { local p; p=$(plat_node_pid); [ -n "$p" ] && kill "-${1:-KILL}" "$p"; local i; for i in $(seq 1 20); do [ -z "$(plat_node_pid)" ] && return 0; sleep 1; done; return 1; }
plat_node_start() { # same binary the node last started with
  local h b; h=$(plat_node_home) || return 1; [ -n "$(plat_node_pid)" ] && return 0
  b=$(awk '/ start /{b=$NF} END{print b}' "$h/binary.log"); rm -f "$h/dvpnd.pid"
  (cd "$LAB/lab" && DVPND=$b setsid bash provision.sh start "${h##*/}" < /dev/null) >> "$OUT/daemon-starts.log" 2>&1
  lab_node_serving "$h"
}
# A restart counts only when the node serves again (Q0439: an orphaned openvpn made every start exit at once).
lab_node_serving() { # <home>: API port listening and the daemon alive, within 20 s
  local i n=${1##*/}
  for i in $(seq 1 20); do
    [ -n "$(plat_node_pid)" ] && ip netns exec "bwl-$n" ss -lnt 2> /dev/null | grep -q ":18443 " && return 0; sleep 1
  done
  say "node $n did not come back: $(tail -1 "$1/dvpnd.log" 2> /dev/null | cut -c1-200)"; return 1
}
plat_node_log() { local h; h=$(plat_node_home) && cat "$h/dvpnd.log"; }
plat_node_set_mtu() { local h; h=$(plat_node_home) || return 1; ip netns exec "bwl-${h##*/}" ip link set dev eth0 mtu "$1"; }
plat_node_mtu() { local h; h=$(plat_node_home) || return 1; ip netns exec "bwl-${h##*/}" cat /sys/class/net/eth0/mtu; }
plat_node_ipv6() { local h; h=$(plat_node_home) || return 1; ip netns exec "bwl-${h##*/}" ip -6 -br addr show scope global | grep -c . ; }
# S11 money/security rows (TS36 11-07: SEC Q0184 / Q0337 / Q0349).
plat_node_bin() { local h; h=$(plat_node_home) && awk '/ start /{b=$NF} END{print b}' "$h/binary.log"; }
plat_node_restart_bin() { # <binary path>: restart the node on it (plat_node_start then keeps it)
  local h; h=$(plat_node_home) || return 1; [ -x "$1" ] || { say "no node binary $1"; return 1; }
  plat_node_kill TERM; rm -f "$h/dvpnd.pid"
  (cd "$LAB/lab" && DVPND=$1 setsid bash provision.sh start "${h##*/}" < /dev/null) >> "$OUT/daemon-starts.log" 2>&1; lab_node_serving "$h"
}
plat_node_hook_bin() { # <hook> -> a lab hook binary for the node's current build (inflate-1.04: BWLAB_INFLATE wrapper)
  local b; b=$(plat_node_bin); b=${b%-inflate-*}; b=${b%-lab}
  case $1 in
    inflate-*) [ -x "$b-lab" ] || return 1
      [ -x "$b-$1" ] || printf '#!/bin/sh\nBWLAB_INFLATE=%s exec %s-lab "$@"\n' "${1#inflate-}" "$b" > "$b-$1"; chmod +x "$b-$1"; echo "$b-$1" ;;
    *) return 1 ;;
  esac
}
plat_node_netem() { # "<netem args>" | off: on the node's uplink egress (tunnel packets to the client go out there)
  local h; h=$(plat_node_home) || return 1
  if [ "$1" = off ]; then ip netns exec "bwl-${h##*/}" tc qdisc del dev eth0 root 2> /dev/null; return 0; fi
  ip netns exec "bwl-${h##*/}" tc qdisc replace dev eth0 root netem $1
}
plat_node_usage() { # node's rx+tx bytes for $CHANNEL
  local h; h=$(plat_node_home) || return 1
  ip netns exec bwl-hub "$LAB_CLI" --output json --daemon.endpoint "$h/daemon.sock" --instance "${h##*/}" node sessions 2>/dev/null |
    python3 -I -c 'import json,sys
print(sum(s["usage"]["rx_bytes"] + s["usage"]["tx_bytes"] for s in json.load(sys.stdin).get("sessions", []) if s.get("subject") == sys.argv[1]))' "$CHANNEL"
}
plat_client_usage() { # this client's rx+tx bytes for $CHANNEL (its own meter)
  cli client sessions 2>/dev/null | python3 -I -c 'import json,sys
print(sum(s["usage"]["rx_bytes"] + s["usage"]["tx_bytes"] for s in json.load(sys.stdin).get("sessions", []) if s.get("channel") == sys.argv[1]))' "$CHANNEL"
}
# Peer client (a second lab client on the same node, default c1) for the tunnel-reuse row.
PEER=${CBM_LAB_PEER:-c1}
peer_cli() { ip netns exec bwl-hub "$LAB_CLI" "${LAB_RPC[@]}" --output json --daemon.endpoint "$LAB/homes/$PEER/daemon.sock" --instance "$PEER" "$@"; }
plat_peer_connect() { # starts a session on the same node; echoes the session id
  local r; r=$(peer_cli client start --node "$NODE_ID" --new-channel --mode voucher --escrow-base-units "${ESCROW:-200000000}") || { say "peer start: ${r: -200}"; return 1; }
  python3 -I -c 'import json,sys;print(json.loads(sys.argv[1])["session"]["id"])' "$r"
}
plat_peer_active() { peer_cli client status "$1" 2>/dev/null | grep -q '"status": *"active"'; }
plat_peer_tunaddr() { ip -n "bwl-$PEER" -4 -br addr | awk '$1 != "lo" && $1 !~ /^eth0/ {print $3}' | head -1; }
plat_peer_pull() { ip netns exec "bwl-$PEER" curl -s -o /dev/null --limit-rate 4M -m "${2:-60}" "$1" & echo $!; }
plat_peer_disconnect() { peer_cli client stop "$1" > /dev/null 2>&1; }
plat_tunaddr() { ip -4 -br addr | awk '$1 != "lo" && $1 !~ /^eth0/ {print $3}' | head -1; }

plat_reset() { plat_uncut; lab_unplant_mtu; lab_proxy_off; plat_node_netem off 2> /dev/null; plat_daemon_running || plat_daemon_start; plat_disconnect > /dev/null 2>&1; plat_set_ks off; return 0; }
plat_node_session_count() { # sessions the node knows for this channel (any state)
  local h; h=$(plat_node_home) || return 1
  ip netns exec bwl-hub "$LAB_CLI" --output json --daemon.endpoint "$h/daemon.sock" --instance "${h##*/}" node sessions 2>/dev/null |
    python3 -I -c 'import json,sys
print(sum(1 for s in json.load(sys.stdin).get("sessions", []) if s.get("subject") == sys.argv[1]))' "$CHANNEL"
}
