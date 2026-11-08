#!/usr/bin/env bash
# ─── Linux adapter (from TLX's cb33 probes, #32 scripts/e2e/linux/oneoff, 8a6ba061) ───
# Expects the build under test in $CBM_DIR (default ~/cb33): ./sentinel-dvpnd and ./sentinel-dvpn, instance c1.
# Owner after the skeleton: FLX / FLX2 (distro bits: firewalld, resolvectl vs resolv.conf, rpm paths).

CBM_DIR=${CBM_DIR:-$HOME/cb33}
INSTANCE=${INSTANCE:-c1}
CLI_HOME=${CLI_HOME:-$HOME/.sentinel-dvpn}
CFG=${CFG:-/var/lib/sentinel-dvpn/$INSTANCE/config.toml}
DLOG=$CBM_DIR/daemon-cbm.log

cli() { local rc; (cd "$CBM_DIR" && sudo ./sentinel-dvpn --home "$CLI_HOME" "$@" --instance "$INSTANCE") 2>&1 | tee -a "$SCEN_DIR/cli.txt"; rc=${PIPESTATUS[0]}; cli_words_app "$@"; return "$rc"; }
# CBM_WORDS_VIA=app (FLX 11-08, Q0433): the words check grades what #32 tells the user, not the upstream CLI the
# harness drives. At each client status/start, #32's `devnet-dvpn status` runs at that same moment into app-cli.txt;
# plat_cli_outputs then returns that instead of cli.txt. Needs #32 installed and the user's socket access.
cli_words_app() {
  [ "${CBM_WORDS_VIA:-cli}" = app ] || return 0
  case "$1 $2" in 'client status'|'client start') ;; *) return 0 ;; esac
  command -v devnet-dvpn >/dev/null 2>&1 || { echo 'words: CBM_WORDS_VIA=app but devnet-dvpn is not installed' >> "$SCEN_DIR/app-cli.txt"; return 0; }
  timeout 20 devnet-dvpn status >> "$SCEN_DIR/app-cli.txt" 2>&1 || echo "(devnet-dvpn status exit $?)" >> "$SCEN_DIR/app-cli.txt"
}
# Chain reads for lib/nodes.sh (node show / node search): the build under test's CLI, not one on PATH (none on the
# test VMs; without this the run stopped at "could not read <node> from chain"). Lane-b URL when the driver has one.
# The signer for chain txs (run-end closes): CBM_CHAIN_HOME/CBM_CHAIN_KEY when the box keeps its wallet elsewhere
# (tlx-u22: --home ~ --key.name wallet = ~/keys/wallet.json; without it every close failed "owner.json: no such file").
plat_chain_cli() { (cd "$CBM_DIR" && sudo ./sentinel-dvpn --home "${CBM_CHAIN_HOME:-$CLI_HOME}" ${CBM_CHAIN_KEY:+--key.name "$CBM_CHAIN_KEY"} ${HELIUS_RPC_URL:+--rpc.url "$HELIUS_RPC_URL"} "$@"); }

# ─── Hostname pin (FLX 11-08, tlx-u22) ───
# sudo resolves the box's own hostname. Where /etc/hosts lacks it (this cloud's image; cloud-init on Ubuntu normally
# writes "127.0.1.1 <hostname>"), every sudo asks DNS, and once the tunnel holds DNS that lookup stalls: the status
# poller recorded 0 samples in a 33 s cell and a hy2-kill leak passed blind. The run adds the line, tagged, and the
# EXIT cleanup (deadman_stop → plat_hosts_release) removes it again, so the box is left as found.
HOSTS_TAG='# cb33-matrix hostname pin (removed at run end)'
plat_hosts_pin() {
  local h; h=$(hostname 2>/dev/null); [ -n "$h" ] || return 0
  if awk -v h="$h" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' /etc/hosts; then return 0; fi
  echo "127.0.1.1 $h $HOSTS_TAG" | sudo tee -a /etc/hosts >/dev/null && say "linux: pinned $h to 127.0.1.1 in /etc/hosts for the run (sudo must not resolve it over DNS)"
}
plat_hosts_release() { grep -qF "$HOSTS_TAG" /etc/hosts 2>/dev/null && sudo sed -i "\|$HOSTS_TAG|d" /etc/hosts; return 0; }

plat_init() {
  plat_hosts_pin
  case $NODE in
    # node-3 wg seed after FS36's 26de5240 swap (11-07 17:57Z), from chain (`node show`); lib/nodes.sh reads the rest.
    node-3) NODE_ID=${NODE3_ID:?set NODE3_ID (node-3 pubkey)}; NODE_IP=${NODE3_IP:?set NODE3_IP} ;;
    node-4) NODE_ID=${NODE4_ID:?set NODE4_ID (node-4 pubkey)}; NODE_IP=${NODE4_IP:?set NODE4_IP} ;;
    *) NODE_ID=$NODE; NODE_IP=${NODE_IP:?set NODE_IP for a custom node} ;;
  esac
  NODE_EGRESS=${NODE_EGRESS:-$NODE_IP}
  PHYS_IF=$(ip -4 route show default | awk '{print $5; exit}')
  PHYS_ADDRS=$(ip -o addr show dev "$PHYS_IF" scope global | awk '{split($4, a, "/"); print a[1]}' | tr '\n' ' ')
  GATEWAY_IP=$(ip -4 route show default | awk '{print $3; exit}')
  CONTROL_IP=${CONTROL_IP:-$(echo "${SSH_CLIENT:-}" | awk '{print $1}')}
  DIRECT_IP=$(curl -4 -s -m 8 https://api.ipify.org)
  [ -n "$DIRECT_IP" ] || return 1
  [ -x "$CBM_DIR/sentinel-dvpnd" ] || { say "no $CBM_DIR/sentinel-dvpnd"; return 1; }
  : > "$DLOG"; READY=0
  plat_mgmt_exempt
  deadman_start
}

plat_build() { (cd "$CBM_DIR" && ./sentinel-dvpnd version 2>&1 | head -1 | cut -c1-120); }
plat_protocols() { echo "${CBM_PROTOCOLS:-wireguard amneziawg openvpn hysteria2 v2ray xray}"; }

dpid() { pgrep -f "^\./sentinel-dvpnd run --instance $INSTANCE"; }
plat_daemon_running() { [ -n "$(dpid)" ]; }
# S9 resources (FAN 11-08): the daemon's resident memory (KiB) and open file descriptors.
plat_daemon_mem() { local p; p=$(dpid | head -1); [ -n "$p" ] && sudo awk '/^VmRSS:/ {print $2}' "/proc/$p/status"; }
plat_daemon_handles() { local p; p=$(dpid | head -1); [ -n "$p" ] && sudo ls "/proc/$p/fd" | grep -c .; }
# The matrix starts its own daemon, so the #32 unit's ExecStartPre (host-firewall.sh allow) never runs. On a firewalld
# or ufw host that drops every TCP connection through the Hysteria2 tun (Q0474, fedora44: egress none without the rule,
# 9/9 PASS with it). Apply the product's own rule (only the tun's /30 and /126), never a whole trusted zone.
host_firewall_allow() {
  local f
  for f in /usr/local/lib/devnet-dvpn/host-firewall.sh /opt/devnet-dvpn/resources/resources/scripts/host-firewall.sh; do
    [ -f "$f" ] || continue
    sudo bash "$f" allow >> "$DLOG" 2>&1 || say "   host-firewall.sh allow failed (rc $?): hysteria2 TCP may be dropped by the host firewall"
    return 0
  done
  if command -v firewall-cmd >/dev/null 2>&1 || command -v ufw >/dev/null 2>&1; then
    say "   host firewall present but no #32 host-firewall.sh: hysteria2 TCP may be dropped (install #32 or run its setup)"
  fi
}
plat_daemon_start() {
  plat_daemon_running && return 0
  # sudo resets PATH; the protocol tools (hysteria2, v2ray, xray) are found through the service's own PATH when the
  # #32 package wrote one (/etc/sentinel-dvpn/<instance>.env), else sudo's secure_path (TLX 11-07: hysteria2 not found).
  local dpath; dpath=$(grep -E '^PATH=' "/etc/sentinel-dvpn/$INSTANCE.env" 2>/dev/null | cut -d= -f2-)
  host_firewall_allow
  (cd "$CBM_DIR" && sudo ${dpath:+env PATH="$dpath"} setsid nohup ./sentinel-dvpnd run --instance "$INSTANCE" >> "$DLOG" 2>&1 < /dev/null &)
  local i; for i in $(seq 1 30); do
    [ "$(grep -c '"message":"ready"' "$DLOG" || true)" -gt "$READY" ] && { READY=$(grep -c '"message":"ready"' "$DLOG" || true); return 0; }
    sleep 1
  done
  return 1
}
plat_daemon_stop() {
  local p; p=$(dpid); [ -n "$p" ] && sudo kill "-${1:-TERM}" $p
  local i; for i in $(seq 1 20); do plat_daemon_running || return 0; sleep 1; done
  return 1
}

# `client start` has no --protocol: the protocol IS the node entry ($NODE_ID per protocol, from lib/nodes.sh).
# A channel belongs to one node entry, so the run keeps one channel per entry (CHANNELS[entry]); a --channel given to
# the driver pins the first entry's channel. (TLX, tlx-u22 11-07: "unknown flag: --protocol" failed every connect.)
declare -gA CHANNELS 2>/dev/null || true
plat_connect() {
  local proto=$1 out ch
  tx_gap
  # Only a --channel given to the driver pins an entry; CHANNEL is rewritten after every connect (money reads it),
  # so it must not be taken as a pin for the next protocol's entry (TLX 11-07: amneziawg got wireguard's channel).
  [ -z "${CBM_CONNECTED:-}" ] && { CHANNEL_PIN=${CHANNEL:-}; CBM_CONNECTED=1; }
  ch=${CHANNELS[$NODE_ID]:-}
  [ -z "$ch" ] && [ -n "${CHANNEL_PIN:-}" ] && [ -z "${CHANNEL_ENTRY:-}" ] && { ch=$CHANNEL_PIN; CHANNEL_ENTRY=$NODE_ID; }
  if [ -n "$ch" ]; then
    out=$(cli client start --node "$NODE_ID" --channel "$ch")
  else
    out=$(cli client start --node "$NODE_ID" --new-channel --mode voucher --escrow-base-units "${ESCROW:-100000}")
    ch=$(grep -oE '"channel(_id)?": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$ch" ] && { CHANNEL_NEW=1; RUN_NEW_CHANNELS="${RUN_NEW_CHANNELS:-} $ch"; RUN_CHANNEL_PROTO="${RUN_CHANNEL_PROTO:-} $ch=$proto"; say "   opened channel $ch for $proto entry $NODE_ID (reused for this entry)"; }
  fi
  [ -n "$ch" ] && { CHANNELS[$NODE_ID]=$ch; CHANNEL=$ch; }
  SID=$(grep -oE '"(session_)?id": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  # Fallback = a LIVE session only: the newest DB row can be an ended one, so a failed start read as connected
  # (TLX 11-08: G2 "passed" with no tunnel, every start refused for lack of SOL).
  grep -qE '^error:|rpc error' <<<"$out" && [ -z "$SID" ] && { say "   connect failed: $(grep -m1 -E '^error:|rpc error' <<<"$out" | cut -c1-200)"; return 1; }
  [ -z "$SID" ] && SID=$(plat_live_sessions | head -1)
  [ -n "$SID" ]
}
plat_disconnect() {
  local s rc=0
  for s in $(plat_live_sessions); do tx_gap; cli client stop "$s" >/dev/null || rc=1; done
  return $rc
}
# Sessions not yet ended. `client sessions` keeps every ended session of the instance, and stopping each of them
# (7 s gap apiece) made one disconnect take minutes on a VM with history.
plat_live_sessions() {
  cli client sessions 2>/dev/null | awk '/"id":/ {gsub(/[",]/, "", $2); id = $2} /"status":/ {gsub(/[",]/, "", $2); if ($2 != "ended" && id != "") print id; id = ""}'
}
plat_sessions() { cli client sessions 2>/dev/null | grep -oE '"id": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/'; }

# S4 switch: replace the live session with one on the current $NODE_ID entry (the suite calls node_for first).
# cb33 has no in-place switch: StartSession refuses while a session is live ("a session is already active",
# sentinel-dvpnd internal/client/session.go:129), so what a cb33 CLI user can do is stop + start. The gap between
# the two is real and is what s4_switch_ks_on measures (StopSession releases a kill switch set to 'on').
plat_switch() {
  local s i keep=()
  # CBM_SWITCH_VIA=app (FLX 11-08, G26 on Linux): switch the way a user does, with #32's CLI (`devnet-dvpn connect
  # <node> --switch --yes`). It stops with the x-keep-kill-switch header (#32 connection.ts), which the fork's daemon
  # CLI cannot send (it has no keep option), so this is the only arm that measures the product's switch. Needs the
  # #32 package installed and set up for the instance under test; it pays its own deposit (money rows may not judge).
  if [ "${CBM_SWITCH_VIA:-cli}" = app ]; then
    local app; app=$(command -v devnet-dvpn 2>/dev/null) || { echo "switch: CBM_SWITCH_VIA=app but devnet-dvpn is not installed"; return 1; }
    tx_gap
    timeout 180 "$app" connect "$NODE_ID" --switch --yes >> "$SCEN_DIR/cli.txt" 2>&1 || { echo "switch: devnet-dvpn connect --switch failed (see cli.txt)"; return 1; }
    for i in $(seq 1 30); do
      [ "$(plat_live_sessions | wc -l)" = 1 ] && [ "$(plat_live_node)" = "$NODE_ID" ] && return 0
      sleep 1
    done
    echo "switch: no single live session on $NODE_ID 30 s after devnet-dvpn connect --switch"; return 1
  fi
  # CBM_SWITCH_KEEPKS=1 (G26 B arm: a dvpnd whose StopSession has keep_kill_switch): the stop keeps the
  # kill switch and admits the next entry ($NODE_ID, set by node_for) to it, so the switch never goes direct.
  [ "${CBM_SWITCH_KEEPKS:-0}" = 1 ] && keep=(--keep-kill-switch --next-node "$NODE_ID")
  for s in $(plat_live_sessions); do tx_gap; cli client stop "$s" "${keep[@]}" >/dev/null || { echo "switch: stopping $s failed"; return 1; }; done
  for i in $(seq 1 15); do [ -z "$(plat_live_sessions)" ] && break; sleep 1; done
  [ -z "$(plat_live_sessions)" ] || { echo "switch: a session is still live 15 s after stop"; return 1; }
  plat_connect "$1"
}
# The node (entry) address of the live session, for s4_after (node-3's entries share one IP, so egress alone can't tell).
plat_live_node() {
  local id; id=$(plat_live_sessions | head -1); [ -n "$id" ] || return 0
  timeout 5 bash -c "cd '$CBM_DIR' && sudo ./sentinel-dvpn --home '$CLI_HOME' client status '$id' --instance '$INSTANCE'" 2>/dev/null |
    grep -oE '"node": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

plat_status_line() {
  local s out='' st='' ks sess t0 cms=0   # out/st set for set -u when there is no session (TLX 11-07, "out: unbound")
  ks=$(sudo grep -oE "^kill_switch = '[a-z]+'" "$CFG" 2>/dev/null | grep -oE "'[a-z]+'" | tr -d "'")
  # ONE status call per tick, timed on its own (FLX 11-08; deb12 S2 56/35 FAIL, DIR). The old loop listed sessions
  # TWICE (plat_live_sessions + plat_sessions) and ran `client status` per candidate — ~7 CLI spawns, ~3.3 s — so
  # every sample read SLOW though the daemon answers in ~27 ms. List once, pick the live session (else the newest),
  # make ONE `client status` call, and report call_ms = just that call: the CLI start-up + sudo + the session
  # listing are harness cost, not the daemon's < 1 s promise (same rule the Windows adapter uses). The call keeps a
  # short per-call timeout and status_line_capped still bounds the whole thing, so the sampler never blocks.
  sess=$(cli client sessions 2>/dev/null)
  s=$(awk '/"id":/ {gsub(/[",]/,"",$2); id=$2} /"status":/ {gsub(/[",]/,"",$2); if ($2!="ended" && id!=""){print id; id=""}}' <<<"$sess" | head -1)
  [ -n "$s" ] || s=$(grep -oE '"id": *"[^"]+"' <<<"$sess" | tail -1 | sed -E 's/.*"([^"]+)"$/\1/')
  if [ -n "$s" ]; then
    t0=$(ms_mono)
    out=$(timeout "${STATUS_CALL_TIMEOUT_S:-3}" bash -c "cd '$CBM_DIR' && sudo ./sentinel-dvpn --home '$CLI_HOME' client status '$s' --instance '$INSTANCE'" 2>&1)
    cms=$(( $(ms_mono) - t0 ))
    st=$(grep -oE '"status": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  fi
  # proxy=1: a v2ray/xray session (local SOCKS proxy, no tunnel); rpc-direct judges full-tunnel time only.
  local px=0; grep -qE '"proxy_endpoint": *"[^"]+"' <<<"$out" && px=1
  echo "state=${st:-none} ks=${ks:-off} id=${s:--} call_ms=$cms proxy=$px text=$(grep -oE '"(error|message)": *"[^"]*"' <<<"$out" | head -1 | tr '\n' ' ')"
}

# v2ray / xray sessions are a local SOCKS proxy, not a tunnel (session "proxy_endpoint": "127.0.0.1:1080"; the #32 app
# points the desktop at it). A plain curl goes direct by design there, so egress is read through the live session's
# proxy when it has one (FLX 11-08: S4 every_pair read "egress <box IP>" after every switch to v2ray/xray).
# Cached per session id: a status call can take seconds and the S4 watch samples every second.
_PROXY_SID='' _PROXY_EP=''
_live_proxy() {
  local id; id=$(plat_live_sessions 2>/dev/null | head -1)
  [ -n "$id" ] || { _PROXY_SID='' _PROXY_EP=''; return 0; }
  if [ "$id" != "$_PROXY_SID" ]; then
    _PROXY_SID=$id
    _PROXY_EP=$(timeout 5 bash -c "cd '$CBM_DIR' && sudo ./sentinel-dvpn --home '$CLI_HOME' client status '$id' --instance '$INSTANCE'" 2>/dev/null |
      grep -oE '"proxy_endpoint": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  fi
  echo "$_PROXY_EP"
}
plat_egress() {
  local ep; ep=$(_live_proxy)
  if [ -n "$ep" ]; then curl -4 -s -m 6 --socks5-hostname "$ep" https://api.ipify.org || echo none
  else curl -4 -s -m 6 https://api.ipify.org || echo none; fi
}
plat_egress6() {
  local ep; ep=$(_live_proxy)
  if [ -n "$ep" ]; then curl -6 -s -m 6 --socks5-hostname "$ep" https://api64.ipify.org || echo none
  else curl -6 -s -m 6 https://api64.ipify.org || echo none; fi
}
# The live session's SOCKS proxy_endpoint (host:port) when it is a proxy-type protocol, else empty. Lets
# cbm_download route a throughput/slow-reader fetch through the proxy instead of going direct (Q0462).
plat_proxy_ep() { _live_proxy; }
plat_dns_probe() { dig +short -t TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null | tr -d '"' | head -1; }

plat_set_ks() { sudo sed -i -E "s/^kill_switch = '[a-z]+'/kill_switch = '$1'/" "$CFG"; }

# tcpdump's own pid goes in <pcap>.pid: $! is sudo's pid, and Ubuntu 22.04's sudo does not relay a kill to tcpdump
# (TLX: 59 captures left running on tlx-u22).
# The daemon's [rpc] url / ws_url hosts, resolved: the kill switch admits them by design, so checks/leak.sh reports them
# as its own rpc-direct row instead of a KS leak (TLX2 deb12: helius packets on every ks=on row). Host only, never the key.
plat_rpc_hosts() {
  local h
  for h in $(sudo awk '/^\[/{s=$0} s=="[rpc]" && /^(ws_)?url = /' "$CFG" 2>/dev/null | sed -nE "s#^[a-z_]+ = '[a-z]+://([^/:?']+).*#\1#p" | sort -u); do
    getent ahostsv4 "$h" | awk '{print $1}'
  done | sort -u | tr '\n' ' '
}
plat_capture_start() {
  LEAK_RPC_HOSTS=$(plat_rpc_hosts)
  sudo sh -c 'echo $$ > "$1.pid"; exec tcpdump -i "$2" -nn -w "$1" -U' _ "$1" "$PHYS_IF" >/dev/null 2>&1 &
  sleep 1
}
plat_capture_stop() {
  local p; p=$(sudo cat "$LEAK_PCAP.pid" 2>/dev/null)
  [ -n "$p" ] && sudo kill -INT "$p" 2>/dev/null
  sleep 1; sudo rm -f "$LEAK_PCAP.pid"; sudo chmod a+r "$LEAK_PCAP" 2>/dev/null; return 0
}

plat_leftovers() {
  sudo nft list tables 2>/dev/null | grep -E "sentinel-dvpn|wg-quick" | sed 's/^/nft: /'
  ip -br link 2>/dev/null | awk '$1 ~ /^(dvpn|wg|tun|sing)/ {print "link: " $1}'
  ip rule 2>/dev/null | grep -vE "^(0|5200|32766|32767):" | sed 's/^/ip rule: /'
  ip -6 rule 2>/dev/null | grep -vE "^(0|32766|32767):" | sed 's/^/ip6 rule: /'
  # Routes a crashed backend leaves behind (Q0428: OpenVPN's host route to the node). Box routes from DHCP/RA/kernel stay.
  ip -4 route show table main 2>/dev/null | grep -vE '^default|proto (kernel|dhcp|ra)|dev lo|metric 5200' | sed 's/^/route: /'
  ip -6 route show table main 2>/dev/null | grep -vE '^default|proto (kernel|dhcp|ra)|dev lo|^(fe80|multicast|ff00)' | sed 's/^/route6: /'
  { ip -4 route show table all; ip -6 route show table all; } 2>/dev/null | grep -E ' table ' | grep -vE ' table (local|main|default)( |$)' | sed 's/^/route table: /'
  resolvectl dns 2>/dev/null | grep -E "dvpn|wg|tun" | sed 's/^/dns: /'
  # by program name, not command line: the hand-run daemon's `sudo env PATH=…/hysteria2…` matched -f (TLX 11-07)
  pgrep -a -x "xray|v2ray|hysteria|hysteria2|openvpn|awg-quick|amneziawg-go" | sed 's/^/process: /'
  sudo find "/var/lib/sentinel-dvpn/$INSTANCE" -maxdepth 3 -type f \( -name '*.key' -o -name '*auth.txt' -o -name '*.conf' -o -name '*.yaml' \) 2>/dev/null | sed 's/^/file: /'
}
# Plants two leftover classes: an nft table, and a Q0428-style host route (192.0.2.9 is RFC 5737 TEST-NET, never real).
plat_plant_leftover() { sudo nft add table inet sentinel-dvpn-c9 && sudo ip route add 192.0.2.9 via "$GATEWAY_IP" dev "$PHYS_IF"; }
plat_unplant_leftover() {
  sudo nft delete table inet sentinel-dvpn-c9 2>/dev/null
  sudo ip route del 192.0.2.9 2>/dev/null
  return 0
}

plat_cut() {
  sudo nft add table inet cbmcut && sudo nft 'add chain inet cbmcut out { type filter hook output priority -10; }' \
    && sudo nft add rule inet cbmcut out ip daddr "$NODE_IP" drop
  [ -n "${1:-}" ] && { sleep "$1"; plat_uncut; }
  return 0
}
plat_uncut() { sudo nft delete table inet cbmcut 2>/dev/null; return 0; }

# ─── Airplane (FAN 11-08; tools/air-ab.sh): the host loses its network, as a laptop losing Wi-Fi does ───
# Two modes, by whether a gate-keep IP is set (CBM_AIR_KEEP_IP, else CBM_SLEEP_KEEP_IP):
#
# NIC-down (no gate-keep IP) — the physical NIC goes down, so every route out goes with it while
# systemd-resolved's stub (127.0.0.53) stays up: lookups fail with "server misbehaving", dials with ENETUNREACH.
# ssh to this box drops too, so run air-ab.sh detached (setsid nohup). Faithful for a box whose chain RPC does not
# ride the NIC we drop (Android real airplane; air-ab.sh standalone).
#
# keep-gate (gate-keep IP set) — a box whose chain RPC rides an ssh -R tunnel to a gate on this NIC (tlx-u22 ->
# ctl-1). Downing the NIC also kills that tunnel, so RPC stays dead after the cut and every redial fails — the S9
# airplane cycle AND the cycles clustered after it fail for a HARNESS reason, not the product (TLX S9 37/50, DIR
# 11-08). So instead of downing the NIC we keep it up and nft-drop everything except lo + the gate host: no public
# egress (so no false leak), the node dropped (the cut), the RPC gate alive across the cut, as DIR's "a gate that
# survives the cut" option. The product still sees no node and no data path; only the harness's own RPC transport
# is preserved — it is test infrastructure, like the ssh control channel leak.sh already exempts via CONTROL_IP.
# (This mirrors plat_sleep's CBM_SLEEP_KEEP_IP fix for the same ctl-1-gate-dies-on-interruption artifact.)
# A transient systemd timer lifts the block after AIR_S+90 s even if this script dies.
plat_airplane() {
  local keep=${CBM_AIR_KEEP_IP:-${CBM_SLEEP_KEEP_IP:-}}
  case $1 in
    enable)
      if [ -n "$keep" ]; then
        sudo systemd-run --quiet --unit=cbm-air-deadman --on-active=$(( ${AIR_S:-20} + 90 )) \
          /bin/sh -c "nft delete table inet cbmair 2>/dev/null; ip link set dev $PHYS_IF up" >/dev/null 2>&1
        sudo nft -f - <<NFT
table inet cbmair {
  chain o { type filter hook output priority -300; policy drop; oifname "lo" accept; ip daddr $keep accept; }
  chain i { type filter hook input priority -300; policy drop; iifname "lo" accept; ip saddr $keep accept; }
}
NFT
      else
        sudo systemd-run --quiet --unit=cbm-air-deadman --on-active=$(( ${AIR_S:-20} + 90 )) \
          /bin/sh -c "ip link set dev $PHYS_IF up; networkctl reconfigure $PHYS_IF || true" >/dev/null 2>&1
        sudo ip link set dev "$PHYS_IF" down
      fi ;;
    *)
      sudo nft delete table inet cbmair 2>/dev/null
      sudo ip link set dev "$PHYS_IF" up
      command -v networkctl >/dev/null && sudo networkctl reconfigure "$PHYS_IF" >/dev/null 2>&1
      sudo systemctl stop cbm-air-deadman.timer >/dev/null 2>&1
      return 0 ;;
  esac
}

# ─── S5 interrupt hooks (TLX 11-08; suites/S5.sh) ───
# No plat_reboot here: the driver runs on this machine, so a reboot ends the run. Reboots are proven off-box
# (#32 oneoff/tlx-s5-reboot.sh, run from ctl-1); the matrix cells SKIP on Linux.
S5_PROTO_PROCS='xray|v2ray|hysteria|hysteria2|openvpn|amneziawg-go'
s5_cli_start_bg() { # $1 out file  $2 "new" for a fresh channel; starts `client start` in the background, sets S5_BG
  local ch=${CHANNELS[$NODE_ID]:-} args
  if [ "${2:-}" = new ] || [ -z "$ch" ]; then args="--new-channel --mode voucher --escrow-base-units ${ESCROW:-100000}"
  else args="--channel $ch"; fi
  tx_gap
  (cd "$CBM_DIR" && exec sudo ./sentinel-dvpn --home "$CLI_HOME" client start --node "$NODE_ID" $args --instance "$INSTANCE") > "$1" 2>&1 &
  S5_BG=$!
}
s5_channels() { cli client channels 2>/dev/null | grep -oE '"address": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sort -u; }
s5_note_new_channels() { # $1 the channel list before; channels the cut deposit created get closed with the run's
  local ch; for ch in $(comm -13 <(echo "$1") <(s5_channels)); do RUN_NEW_CHANNELS="${RUN_NEW_CHANNELS:-} $ch"; echo "new channel $ch"; done
}
# The app's Cancel / ^C on `client start`: the CLI cancels its gRPC call, and the daemon's connect runs under that
# call's context (cb33 runSession), so the connect stops. Tries shorter delays if the connect finished first.
plat_cancel_connect() { # $1 proto $2 after (s) $3 "new" = cut inside the deposit of a new channel
  local after=$2 out=$SCEN_DIR/cancel.txt before rc try
  for try in 1 2 3; do
    before=$(s5_channels)
    s5_cli_start_bg "$out" "${3:-}"; sleep "$after"
    sudo pkill -INT -f "sentinel-dvpn --home $CLI_HOME client start --node $NODE_ID" 2>/dev/null
    wait "$S5_BG"; rc=$?; cat "$out" >> "$SCEN_DIR/cli.txt"
    s5_note_new_channels "$before"
    [ "$rc" != 0 ] && { echo "cancelled after ${after} s (rc $rc): $(tr '\n' ' ' < "$out" | cut -c1-200)"; return 0; }
    echo "connect finished before the cancel at ${after} s; disconnecting and retrying shorter"
    plat_disconnect > /dev/null 2>&1; sleep 3; after=$(awk -v a="$after" 'BEGIN {print a / 2}')
  done
  return 1
}
# Simulated on a VM (a real power cut needs an off-box driver): SIGKILL the daemon and every protocol process
# mid-connect, so nothing runs a cleanup; the caller starts the daemon again (its startup recovery must clean up).
plat_power_cut_mid_connect() { # $1 proto $2 after (s)
  local out=$SCEN_DIR/powercut.txt before; before=$(s5_channels)
  s5_cli_start_bg "$out"; sleep "$2"
  local p; p=$(dpid); [ -n "$p" ] && sudo kill -KILL $p
  sudo pkill -KILL -x "$S5_PROTO_PROCS" 2>/dev/null
  wait "$S5_BG"; cat "$out" >> "$SCEN_DIR/cli.txt"
  echo "simulated: daemon pid ${p:-none} + protocol processes SIGKILLed ${2} s into the connect (no reboot); start said: $(tr '\n' ' ' < "$out" | cut -c1-160)"
}
# Simulated on a VM (no suspend on cloud VMs): freeze the daemon and protocol processes (SIGSTOP) and drop all
# traffic for the time asleep, then resume. Linux monotonic timers do not run during a real suspend either, but the
# wall clock does; the clock-step cells cover that half.
plat_sleep() { # $1 seconds
  # CBM_SLEEP_KEEP_IP: a host the drop lets through, for a box whose chain RPC rides an ssh tunnel to it (tlx-u22 ->
  # ctl-1 gate). Without it the frozen tunnel left the RPC dead for minutes after resume and every redial failed on
  # getAccountInfo (S5 sleep_resume awg/hy2, TLX 11-08): an artifact, a real wake reconnects HTTPS at once.
  local pids; pids="$(dpid) $(pgrep -x "$S5_PROTO_PROCS" | tr '\n' ' ')"
  sudo nft -f - <<NFT
table inet cbmsleep {
  chain o { type filter hook output priority -300; policy drop; oifname "lo" accept; ${CBM_SLEEP_KEEP_IP:+ip daddr $CBM_SLEEP_KEEP_IP accept;} }
  chain i { type filter hook input priority -300; policy drop; iifname "lo" accept; ${CBM_SLEEP_KEEP_IP:+ip saddr $CBM_SLEEP_KEEP_IP accept;} }
}
NFT
  # sudo stops itself when its child is stopped, and a CONT to the child alone leaves sudo frozen for good: it never
  # reaps the daemon, and its driver subshell keeps the box "busy" (u22 S5 11-08, TLX). So CONT the parents too.
  local par; par=$(for p in $pids; do ps -o ppid= -p "$p" 2>/dev/null; done | tr -d ' ' | grep -vx 1 | sort -u | tr '\n' ' ')
  sudo kill -STOP $pids 2>/dev/null; sleep "$1"; sudo kill -CONT $pids $par 2>/dev/null
  sudo nft delete table inet cbmsleep 2>/dev/null
  echo "simulated sleep: froze pids $pids and dropped all traffic for $1 s, resumed"
}
# A real wall-clock step. NTP (chrony on Azure images, else timesyncd) is off until plat_clock_restore.
plat_clock_jump() { # $1 ±seconds
  sudo systemctl stop chrony chronyd 2>/dev/null; sudo timedatectl set-ntp false 2>/dev/null
  CLOCK_STEP=$1; sudo date -s "@$(( $(date +%s) + $1 ))" > /dev/null
  echo "wall clock now $(date -u +%T) (stepped $1 s, NTP off)"
}
plat_clock_restore() {
  [ -n "${CLOCK_STEP:-}" ] && sudo date -s "@$(( $(date +%s) - CLOCK_STEP ))" > /dev/null; CLOCK_STEP=''
  sudo timedatectl set-ntp true 2>/dev/null; sudo systemctl start chrony chronyd 2>/dev/null
  command -v chronyc > /dev/null && sudo chronyc -a makestep > /dev/null 2>&1
  echo "wall clock $(date -u +%T), NTP $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
}

plat_cli_outputs() { if [ "${CBM_WORDS_VIA:-cli}" = app ]; then grep -v '^(devnet-dvpn status exit' "$SCEN_DIR/app-cli.txt" 2>/dev/null; else cat "$SCEN_DIR/cli.txt" 2>/dev/null; fi; grep -oE '"(error|message|reason)":"[^"]*"' "$DLOG" 2>/dev/null | tail -50; }

# Chain read of $CHANNEL: `channel show` prints the on-chain account ("escrow", "redeemed" in base units). One RPC call.
# `redeemed` counts for the whole channel's life, so it only equals this run's node_settled when this run opened the
# channel (CHANNEL_NEW=1, set by plat_connect); on a reused channel it is reported but node_settled stays unknown.
chain_channel_field() { # $1 field
  [ -n "${CHANNEL:-}" ] || return 1
  (cd "$CBM_DIR" && sudo ./sentinel-dvpn --home "$CLI_HOME" channel show "$CHANNEL") 2>/dev/null \
    | grep -oE "\"$1\": *[0-9]+" | head -1 | grep -oE '[0-9]+$'
}
plat_money() {
  local j redeemed escrow settled=unknown
  j=$(cli client sessions 2>/dev/null)
  redeemed=$(chain_channel_field redeemed); escrow=$(chain_channel_field escrow)
  # The node redeems when the channel closes, so a per-scenario `redeemed` is not the scenario's settlement:
  # node_settled stays unknown here and plat_money_run judges it once, after plat_close_run_channels.
  # cb33 `client sessions` has no owed/paid fields, only per-session "spent" + "channel" (checked on cb33092e). Sum
  # "spent" over this channel's sessions; paid has no client-side source, so it stays unknown (money.sh skips it).
  local spent
  spent=$(awk -v ch="$CHANNEL" '/"spent":/ {gsub(/[^0-9]/, "", $2); s = $2} /"channel":/ {if (index($0, ch) && ch != "") t += s; s = 0} END {print t + 0}' <<<"$j")
  # Prepay the client signs ahead by design (FWX 2c7d771): one window per session on this channel, priced at the node's
  # advertised rate. per_gb: max(prepay_bytes, node min) × price_per_gb / 1e9; per_hour: max(prepay_seconds, node min)
  # × price_per_hour / 3600; rounded up per session. Unknown price → 0 (strict).
  local n; n=$(awk -v ch="$CHANNEL" '/"channel":/ {if (index($0, ch) && ch != "") c++} END {print c + 0}' <<<"$j")
  MONEY_PREPAY_ALLOW=$(( n * $(prepay_window_units) ))
  echo "spent=$spent paid=unknown node_settled=$settled redeemed=${redeemed:-unknown} escrow=${escrow:-unknown} prepay_allow=$MONEY_PREPAY_ALLOW"
}
# Run-end settle check (checks/money.sh money_run_end). Only channels THIS run opened are closed (a --channel pin belongs
# to whoever opened it); the node redeems the last voucher once the close starts. 7 s between the close txs.
# A close counts only once the chain shows it (close_started_at > 0): on u22 11-08 both run-end closes failed silently
# under 429s=256 on a 5 rps gate token, the channels stayed open and money_run_end FAILed "node settled 0" (TLX/ABW).
# So: up to 4 tries with backoff, then CLOSE-NOT-LANDED, which money_run_end turns into "cannot judge", not a FAIL.
plat_close_run_channels() {
  local ch k out started key
  [ -n "${RUN_NEW_CHANNELS:-}" ] || return 0
  # Fail fast when the signer key is absent (e.g. the owner key stays on the controller, not the VM):
  # start-close needs the OWNER key; the opener key gets Unauthorized (6000). Without this, each close
  # retries 4x with backoff (~2.7 min/channel) only to fail (TLX2 11-08: 27 min + 130 channels left open).
  key="${CBM_CHAIN_HOME:-$CLI_HOME}/keys/${CBM_CHAIN_KEY:-owner}.json"
  if ! sudo test -r "$key" 2>/dev/null; then
    echo "no owner key ($key): closes skipped, reclaim from the funder"
    echo "CLOSE-SKIPPED-NO-KEY $(wc -w <<<"$RUN_NEW_CHANNELS") channel(s): $RUN_NEW_CHANNELS"
    return 0
  fi
  for ch in ${RUN_NEW_CHANNELS:-}; do
    say "   closing channel $ch (opened by this run)"
    for k in 1 2 3 4; do
      tx_gap
      out=$(plat_chain_cli channel start-close-channel --channel "$ch" 2>&1)
      grep -oE '"(signature|error|message)": *"[^"]*"' <<<"$out" | head -2
      sleep 3; started=$(CHANNEL=$ch chain_channel_field close_started_at)
      [ -n "$started" ] && [ "$started" -gt 0 ] && { echo "close landed $ch (try $k, close_started_at $started)"; continue 2; }
      echo "close not landed $ch (try $k): $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
      sleep $((k * 15))
    done
    echo "CLOSE-NOT-LANDED $ch"
  done
}
# spent = summed over every session on the run's new channels; node_settled = their summed on-chain `redeemed`.
plat_money_run() {
  local j ch spent=0 settled=0 n=0 r s c
  [ -n "${RUN_NEW_CHANNELS:-}" ] || { echo "spent=0 paid=unknown node_settled=unknown prepay_allow=0"; return; }
  j=$(cli client sessions 2>/dev/null)
  for ch in $RUN_NEW_CHANNELS; do
    s=$(awk -v ch="$ch" '/"spent":/ {gsub(/[^0-9]/, "", $2); v = $2} /"channel":/ {if (index($0, ch)) t += v; v = 0} END {print t + 0}' <<<"$j")
    c=$(awk -v ch="$ch" '/"channel":/ {if (index($0, ch)) k++} END {print k + 0}' <<<"$j")
    r=$(CHANNEL=$ch chain_channel_field redeemed); [ -n "$r" ] || { echo "spent=$spent paid=unknown node_settled=unknown prepay_allow=0"; return; }
    spent=$((spent + s)); settled=$((settled + r)); n=$((n + c))
  done
  MONEY_PREPAY_ALLOW=$(( n * $(prepay_window_units) ))
  echo "spent=$spent paid=unknown node_settled=$settled channels=$(wc -w <<<"$RUN_NEW_CHANNELS") sessions=$n prepay_allow=$MONEY_PREPAY_ALLOW"
}
plat_money_run_channels() { # one line per channel, graded per channel by checks/money.sh
  local j ch s c r w p
  j=$(cli client sessions 2>/dev/null); w=$(prepay_window_units)
  for ch in ${RUN_NEW_CHANNELS:-}; do
    s=$(awk -v ch="$ch" '/"spent":/ {gsub(/[^0-9]/, "", $2); v = $2} /"channel":/ {if (index($0, ch)) t += v; v = 0} END {print t + 0}' <<<"$j")
    c=$(awk -v ch="$ch" '/"channel":/ {if (index($0, ch)) k++} END {print k + 0}' <<<"$j")
    r=$(CHANNEL=$ch chain_channel_field redeemed); p=$(tr ' ' '\n' <<<"${RUN_CHANNEL_PROTO:-}" | sed -n "s/^$ch=//p" | head -1)
    echo "channel=$ch proto=${p:-unknown} spent=$s redeemed=${r:-unknown} sessions=$c step=${w:-0}"
  done
}
prepay_window_units() { # base units one session may sign ahead
  local basis pb ps meta uri mpb mps ppg pph
  basis=$(sudo sed -nE "s/^basis = '([a-z_]+)'/\1/p" "$CFG" | head -1)
  pb=$(sudo sed -nE 's/^prepay_bytes = ([0-9]+)/\1/p' "$CFG" | head -1); ps=$(sudo sed -nE 's/^prepay_seconds = ([0-9]+)/\1/p' "$CFG" | head -1)
  uri=$( (cd "$CBM_DIR" && sudo ./sentinel-dvpn --home "$CLI_HOME" node show "$NODE_ID") 2>/dev/null | grep -oE '"uri": *"https://[^"]+"' | head -1 | grep -oE 'https://[^"]+')
  [ -n "$uri" ] && meta=$(curl -sk -m 8 "$uri/v1/metadata")
  mpb=$(grep -oE '"min_channel_prepay_bytes":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); mps=$(grep -oE '"min_channel_prepay_seconds":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  ppg=$(grep -oE '"channel_price_per_gb":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); pph=$(grep -oE '"channel_price_per_hour":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  awk -v b="${basis:-per_gb}" -v pb="${pb:-0}" -v ps="${ps:-0}" -v mpb="${mpb:-0}" -v mps="${mps:-0}" -v ppg="${ppg:-0}" -v pph="${pph:-0}" 'BEGIN {
    if (b == "per_hour") { s = (ps > mps ? ps : mps); v = s * pph / 3600 } else { y = (pb > mpb ? pb : mpb); v = y * ppg / 1e9 }
    printf "%d\n", (v == int(v) ? v : int(v) + 1) }'
}

# RPC lane b (RPC-PLAN): put the lane URL in the daemon's [rpc] section (NOT [tx.paymaster]; both keys are `url`).
# The key never reaches argv, a log or stdout: awk reads it from the environment and the file is rewritten as root 600.
# The first call keeps the original config as $CFG.pre-rpc; plat_unset_rpc puts it back.
plat_set_rpc() { # $1 rpc url  $2 ws url (optional)
  [ -n "${1:-}" ] || return 1
  sudo test -f "$CFG.pre-rpc" || sudo cp -p "$CFG" "$CFG.pre-rpc" || return 1
  local tmp; tmp=$(umask 077; mktemp) || return 1
  sudo cat "$CFG" | CBM_U="$1" CBM_W="${2:-}" awk '
    /^\[/ { sec = $0 }
    sec == "[rpc]" && /^url = / { print "url = '\''" ENVIRON["CBM_U"] "'\''"; next }
    sec == "[rpc]" && /^ws_url = / && ENVIRON["CBM_W"] != "" { print "ws_url = '\''" ENVIRON["CBM_W"] "'\''"; next }
    { print }' > "$tmp" || { rm -f "$tmp"; return 1; }
  grep -q '^url = ' "$tmp" && sudo install -m 600 -o root -g root "$tmp" "$CFG"; local rc=$?
  rm -f "$tmp"
  [ "$rc" = 0 ] && say "   rpc: [rpc] url set from the lane file (key not shown)"
  return $rc
}
plat_unset_rpc() { sudo test -f "$CFG.pre-rpc" && sudo mv "$CFG.pre-rpc" "$CFG"; return 0; }

# set_ks only edits config.toml; the running daemon keeps the kill switch it loaded at start, so after a ks=on or a
# daemon_term_persist scenario the `inet sentinel-dvpn-<inst>` table stays loaded and shows up as a leftover (TLX
# 11-08, S2 daemon_term_persist on wg/awg/hy2). Once config is off: bounce the daemon so startup recovery reconciles
# it — a non-persistent leftover is released outright; a persistent one is re-applied and left present. If a table is
# still loaded after the bounce, a stop with no live session releases it: the daemon frees a *present* firewall even
# for an unknown session id (session.go stopSessionByID: conn==nil -> releaseFirewall), and the CLI has no
# disconnect-all / kill-switch-off verb. A real active session with a mismatched id is untouched (it bails first).
plat_release_ks() { # remove a kill-switch table the running daemon still holds
  local i
  sudo nft list tables 2>/dev/null | grep -q "inet sentinel-dvpn-$INSTANCE\b" || return 0
  plat_daemon_stop TERM; plat_daemon_start >/dev/null 2>&1 || return 0
  for i in 1 2 3 4 5; do
    sudo nft list tables 2>/dev/null | grep -q "inet sentinel-dvpn-$INSTANCE\b" || return 0
    cli client stop __reset__ >/dev/null 2>&1   # no live session -> releases the re-applied persistent firewall
    sleep 1
  done
  return 0
}
reset_nft() { echo "$(date -u +%T) ${SUITE:-}/${SCENARIO:-}/${PROTO:-} $1: $(sudo nft list tables 2>/dev/null | grep -oE 'sentinel-dvpn[^ ]*|wg-quick[^ ]*' | tr '\n' ' ')" >> "$OUT/reset-nft.log"; }
# ─── Management exemption (TLX 11-08, DIR) ───
# A full tunnel (wg's `not fwmark 0xca6c lookup 51820` rule, hy2/openvpn ::/0 + 0/0) also captures the replies to the
# controller, so every VM went SSH-dark from ctl-1 while a tunnel was up. Correct product behaviour, so the HARNESS
# exempts the controller with a /32 route in MAIN via the physical gateway (tagged metric 5200). Not an ip rule: the wg
# client inserts its rules just below the lowest existing priority, so any rule we add gets shadowed (seen on u24a:
# ours 5200, theirs 5198/5199). A main-table /32 wins anyway, because the tunnels' own `lookup main
# suppress_prefixlength 0` only skips main's default route, and openvpn's def1 /1 routes are less specific.
# Added by plat_init, re-ensured by plat_reset, removed by deadman_stop at the very end (never between scenarios).
CBM_MGMT_IPS=${CBM_MGMT_IPS:?set CBM_MGMT_IPS}   # ctl-1; add more space-separated
plat_mgmt_exempt() {
  local ip; [ -n "${GATEWAY_IP:-}" ] && [ -n "${PHYS_IF:-}" ] || return 0
  for ip in $CBM_MGMT_IPS ${CONTROL_IP:-}; do
    sudo ip -4 route replace "$ip/32" via "$GATEWAY_IP" dev "$PHYS_IF" metric 5200
  done
}
plat_mgmt_release() { local ip; for ip in $CBM_MGMT_IPS ${CONTROL_IP:-}; do sudo ip -4 route del "$ip/32" metric 5200 2>/dev/null; done; return 0; }
plat_reset() {   # reset-nft.log: the KS tables before/after each reset (TLX for FLX2, 11-08)
  plat_mgmt_exempt
  reset_nft before
  plat_uncut
  plat_daemon_running || plat_daemon_start
  plat_disconnect >/dev/null 2>&1
  plat_set_ks off
  reset_nft after-set_ks
  plat_release_ks
  reset_nft after
  return 0
}

# ─── S6 hooks (TLX2 11-08): allow-LAN peer, split routes ───
# The LAN peer is a netns on a veth pair: 192.168.77.2 (private v4), fd77:6::2 (ULA), 2001:db8:77::2 (global scope;
# RFC 3849 documentation range, never routed outside this box). A python listener answers TCP 8077 on all three.
S6_NS=s6lan
plat_lan_up() {
  plat_lan_down
  sudo ip netns add $S6_NS && sudo ip link add s6h type veth peer name s6p && sudo ip link set s6p netns $S6_NS || return 1
  sudo ip addr add 192.168.77.1/24 dev s6h; sudo ip -6 addr add fd77:6::1/64 dev s6h nodad; sudo ip -6 addr add 2001:db8:77::1/64 dev s6h nodad
  sudo ip link set s6h up
  sudo ip netns exec $S6_NS sh -c 'ip link set lo up; ip link set s6p up; ip addr add 192.168.77.2/24 dev s6p;
    ip -6 addr add fd77:6::2/64 dev s6p nodad; ip -6 addr add 2001:db8:77::2/64 dev s6p nodad'
  # The peer serves a per-run token. A user-space TUN stack (hysteria2's sing-tun) completes the TCP handshake
  # itself, so only reading the token back proves the LAN peer answered (TLX2 11-08: a bare connect read "ok" via hy2).
  S6_TOKEN=s6-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  sudo mkdir -p /run/s6lan && echo "$S6_TOKEN" | sudo tee /run/s6lan/t.txt > /dev/null
  sudo ip netns exec $S6_NS setsid nohup python3 -m http.server 8077 --bind :: --directory /run/s6lan > /dev/null 2>&1 < /dev/null &
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(plat_lan_probe v4)" = ok ] && return 0; sleep 0.5; done
  return 1
}
plat_lan_down() {
  sudo ip netns pids $S6_NS 2>/dev/null | xargs -r sudo kill 2>/dev/null
  sudo ip link del s6h 2>/dev/null; sudo ip netns del $S6_NS 2>/dev/null; sudo rm -rf /run/s6lan
  return 0
}
plat_lan_probe() { # $1 v4|ula|global → ok|blocked (HTTP GET of the peer's token, 3 s)
  local a; case $1 in v4) a=192.168.77.2 ;; ula) a=fd77:6::2 ;; global) a=2001:db8:77::2 ;; *) echo blocked; return 0 ;; esac
  # Planted fault for the global cell (S6_PLANT=1): probe the ULA instead, as a build that admitted a global /64 would.
  [ "$1" = global ] && [ "${S6_PLANT:-0}" = 1 ] && a=fd77:6::2
  case $a in *:*) a="[$a]" ;; esac   # brackets only for IPv6: http://[192.168.77.2]/ is not a valid URL
  [ "$(curl -s -g -m 3 --noproxy '*' "http://$a:8077/t.txt" 2>/dev/null)" = "${S6_TOKEN:-unset}" ] && echo ok || echo blocked
}
# plat_lan_inbound_probe → delivered|blocked: the LAN peer sends one UDP datagram (a fresh token) TO this host
# (192.168.77.1:8078) and a listener here reports whether it arrived. UDP, so the answer does not depend on the output
# chain (a TCP SYN-ACK is dropped there either way): it shows whether the kill switch filters INBOUND (upstream #16).
plat_lan_inbound_probe() {
  # The send runs through sudo, and sudo resolves this host's name: under a tunnel that lookup can stall for seconds
  # (G26 11-08). So the listener waits 20 s and the send is timed; a send slower than the listener reads "unknown".
  local tok got t0 t1; tok=in-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  ( timeout 22 python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("192.168.77.1", 8078)); s.settimeout(20); print(s.recv(64).decode())' 2>/dev/null > /tmp/s6in.$$ ) & local l=$!
  sleep 0.5; t0=$(ms_mono)
  sudo ip netns exec $S6_NS python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); [s.sendto(sys.argv[1].encode(), ("192.168.77.1", 8078)) for _ in range(3)]' "$tok" 2>/dev/null
  t1=$(ms_mono); echo "inbound probe: send took $((t1 - t0)) ms" >&2
  wait $l; got=$(head -1 /tmp/s6in.$$ 2>/dev/null); rm -f /tmp/s6in.$$
  if [ "$got" = "$tok" ]; then echo delivered; elif [ $((t1 - t0)) -ge 19000 ]; then echo unknown; else echo blocked; fi
}
s6_net_hdr() { sudo grep -oE '^\[([a-z_]+\.)?network\]' "$CFG" | head -1; }
plat_set_allow_lan() { # $1 true|false: replace allow_lan, or add it under the [network] header
  if sudo grep -qE '^allow_lan *=' "$CFG"; then sudo sed -i -E "s/^allow_lan *=.*/allow_lan = $1/" "$CFG"
  else local h; h=$(s6_net_hdr); [ -n "$h" ] || { echo "no [network] table in $CFG"; return 1; }
    sudo awk -v h="$h" -v v="$1" '{print} $0 == h {print "allow_lan = " v}' "$CFG" | sudo tee "$CFG.s6" > /dev/null &&
      sudo sh -c "cat '$CFG.s6' > '$CFG' && rm -f '$CFG.s6'"; fi
}
# The fork reads [split] (mode, apps, routes) next to [network]; pure 26de5240 has no such table.
plat_split_supported() { (cd "$CBM_DIR" && grep -aq 'split route %q' ./sentinel-dvpnd); }
plat_set_split() { # $1 off|include|exclude, then CIDR routes
  local mode=$1 h p r list=""; shift
  h=$(s6_net_hdr); p=${h%network]}; p=${p#[}
  sudo awk -v t="[${p}split]" '$0 == t {skip = 1; next} /^\[/ {skip = 0} !skip' "$CFG" | sudo tee "$CFG.s6" > /dev/null
  for r in "$@"; do list="$list${list:+, }'$r'"; done
  [ "$mode" = off ] || printf "\n[%ssplit]\nmode = '%s'\napps = []\nroutes = [%s]\n" "$p" "$mode" "$list" | sudo tee -a "$CFG.s6" > /dev/null
  sudo sh -c "cat '$CFG.s6' > '$CFG' && rm -f '$CFG.s6'"
}
plat_resolve4() { getent ahostsv4 "$1" | awk 'NR == 1 {print $1}'; }
plat_block_present() { sudo nft list tables 2>/dev/null | grep -q "^table inet sentinel-dvpn-$INSTANCE$"; }
# One root `nft monitor tables` for the whole window (every add/delete, no sampling: a stop-start gap can be ms; and a sudo per
# sample stalls in the gap on dead DNS). Writes "<events on the KS table> <gaps> <longest gap ms|open>" to <file>, the event
# log to <file>.log. A gap = a delete of the KS table not re-added within 50 ms: applyFirewall re-renders with
# "delete table; table {...}" in ONE nft transaction (delete+add 3 ms apart, no packet sees it); a stop-start
# release is seconds (pure 26de5240 on tlx-u22: 1586 ms and 1899 ms, G26 11-08).
plat_block_sample() { sudo bash -c 'echo "tables at start: $(nft list tables | tr "\n" " ")" > "$3.log"; timeout "$1" nft monitor tables | while read -r l; do echo "$(date -u +%T.%N | cut -c1-12) $l" >> "$3.log"; done' _ "$1" "$INSTANCE" "$2"; awk -v t="table inet sentinel-dvpn-$INSTANCE" 'function ms(s, a) { split(s, a, ":"); return ((a[1] * 60 + a[2]) * 60 + a[3]) * 1000 } $0 ~ (t "$") { n++ } $0 ~ ("delete " t "$") { d = ms($1); next } $0 ~ ("add " t "$") && d != "" { g = ms($1) - d; if (g > 50) { gaps++; if (g > mx) mx = g } d = "" } END { if (d != "") { gaps++; mx = "open" } printf "%d %d %s\n", n, gaps, (mx == "" ? 0 : mx) }' "$2.log" > "$2"; }
plat_egress_at() { curl -4 -s -m 6 --resolve "$1:443:$2" "https://$1/" | tr -d '[:space:]' | grep -E '^[0-9.]+$' || echo none; }

# ─── S10 install lifecycle (FLX2 11-08; README "S10 hooks") ───
# The runner stages the previous-release and under-test packages and sets CBM_PKG_OLD / CBM_PKG_NEW (.deb or .rpm);
# a scenario that needs both SKIPs when either is empty. Package name and service unit the fleet package ships are
# env-overridable — confirm the exact strings with the packaging owner.
CBM_PKG_NAME=${CBM_PKG_NAME:-devnet-dvpn}
CBM_SVC=${CBM_SVC:-sentinel-dvpnd@c0}

_s10_pm() { # echo deb|rpm from the staged package extension, else the host's package manager, else none
  case "${CBM_PKG_NEW:-}${CBM_PKG_OLD:-}" in
    *.deb) echo deb; return ;;
    *.rpm) echo rpm; return ;;
  esac
  command -v dpkg > /dev/null && { echo deb; return; }
  command -v rpm  > /dev/null && { echo rpm;  return; }
  echo none
}

plat_pkg_old() { echo "${CBM_PKG_OLD:-}"; }
plat_pkg_new() { echo "${CBM_PKG_NEW:-}"; }

plat_pkg_install() { # $1 package file; $2 "setup" = run device setup (the initial install only)
  case "$(_s10_pm)" in
    deb) sudo dpkg -i "$1" || sudo apt-get -f install -y || return 1 ;;
    rpm) sudo rpm -Uvh --force "$1" || sudo dnf install -y "$1" || return 1 ;;
    *)   return 77 ;;
  esac
  # Device setup runs ONLY when "setup" is passed (the initial install). A no-flag install never creates a wallet /
  # on-chain identity, so a reinstall after a config-purge has no device and the body FAILs "device lost".
  # NOTE: here "setup" = register the templated unit and start the daemon (first run generates the c0 device);
  # confirm the exact setup/keygen step with the packaging owner before trusting a PASS.
  if [ "${2:-}" = setup ]; then
    sudo /usr/local/lib/devnet-dvpn/sentinel-dvpnd service install --instance "${CBM_PKG_INSTANCE:-c0}" > /dev/null 2>&1 || true
    sudo systemctl enable --now "$CBM_SVC" > /dev/null 2>&1 || true
    # A funded wallet can't open a channel until the program delegate is approved (TLX2 11-08). Best-effort here
    # (needs the wallet funded with SOL for the fee); a box funded out-of-band runs the same command post-funding,
    # and preflight_delegate blinds any cell whose delegate is still short.
    plat_delegate_approve "${CBM_DELEGATE_AMOUNT:-unlimited}" > /dev/null 2>&1 || true
  fi
  return 0
}

plat_pkg_upgrade() { # $1 package file, via the package manager's upgrade path
  case "$(_s10_pm)" in
    deb) sudo apt-get install -y --allow-downgrades --reinstall "$1" 2>/dev/null || sudo dpkg -i "$1" ;;
    rpm) sudo rpm -Uvh "$1" || sudo dnf -y upgrade "$1" ;;
    *)   return 77 ;;
  esac
}

plat_pkg_uninstall() {
  case "$(_s10_pm)" in
    deb) sudo dpkg -r "$CBM_PKG_NAME" ;;
    rpm) sudo rpm -e "$CBM_PKG_NAME" ;;
    *)   return 77 ;;
  esac
}

plat_pkg_installed() {
  case "$(_s10_pm)" in
    deb) dpkg-query -W -f='${Status}' "$CBM_PKG_NAME" 2>/dev/null | grep -q "install ok installed" ;;
    rpm) rpm -q "$CBM_PKG_NAME" > /dev/null 2>&1 ;;
    *)   return 1 ;;
  esac
}

plat_pkg_version() {
  case "$(_s10_pm)" in
    deb) dpkg-query -W -f='${Version}' "$CBM_PKG_NAME" 2>/dev/null ;;
    rpm) rpm -q --qf '%{VERSION}-%{RELEASE}' "$CBM_PKG_NAME" 2>/dev/null ;;
  esac
}

plat_pkg_files() { # one "<mode> <owner> <path>" per installed regular file
  local list f
  case "$(_s10_pm)" in
    deb) list=$(dpkg -L "$CBM_PKG_NAME" 2>/dev/null) ;;
    rpm) list=$(rpm -ql "$CBM_PKG_NAME" 2>/dev/null) ;;
    *)   return 1 ;;
  esac
  printf '%s\n' "$list" | while IFS= read -r f; do
    [ -f "$f" ] && stat -c '%A %U %n' "$f" 2>/dev/null
  done
}

plat_service_active()  { systemctl is-active  --quiet "$CBM_SVC"; }
plat_service_enabled() { systemctl is-enabled --quiet "$CBM_SVC" 2>/dev/null; }

plat_run_as_nonadmin() { # run the installed CLI as an unprivileged user; echo output, rc = the CLI's
  local bin; bin=$(command -v sentinel-dvpn 2>/dev/null || echo /usr/local/lib/devnet-dvpn/sentinel-dvpn)
  sudo -n -u "${CBM_NOADMIN_USER:-nobody}" "$bin" --home /tmp/s10-noadmin-home "$@" 2>&1
}

# The installed package's instance (home + CLI), separate from the harness's CBM_DIR c1 build.
CBM_PKG_HOME=${CBM_PKG_HOME:-/var/lib/sentinel-dvpn/c0}
CBM_PKG_INSTANCE=${CBM_PKG_INSTANCE:-c0}
_s10_cli() { command -v sentinel-dvpn 2>/dev/null || echo /usr/local/lib/devnet-dvpn/sentinel-dvpn; }

# ─── Program delegate (linux): approve + read the token-2022 delegate allowance ──
# A funded c0 can't open a channel until the program's token delegate is approved
# (TLX2 11-08); see preflight_delegate / CBM_DELEGATE_AMOUNT in lib/common.sh.
plat_delegate_approve() { # $1 = base units or "unlimited" (default unlimited); approve the program delegate
  local cli; cli=$(_s10_cli); tx_gap
  sudo "$cli" --home "$CBM_PKG_HOME" wallet approve-delegate \
    --amount-base-units "${1:-unlimited}" --key.name operator 2>&1
}
plat_delegate_read() { # echo the wallet's program-delegate allowance in base units (or "unlimited"); empty on failure
  local cfg="$CBM_PKG_HOME/config.toml" rpc owner mint have
  # Both come from the daemon's own config.toml (single-quoted TOML — strip ' or "); owner is a ROOT-level key
  # (before the first [section]), rpc.url lives under [rpc]. (wallet balance is avoided: its keyring sudo wants a tty.)
  rpc=${CBM_RPC_URL:-${HELIUS_RPC_URL:-$(sudo sed -nE '/^\[rpc\]/,/^\[/{ s/^[[:space:]]*url[[:space:]]*=[[:space:]]*(.+)$/\1/p }' "$cfg" 2>/dev/null | head -1 | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//")}}
  owner=${CBM_OWNER:-$(sudo sed -nE '1,/^\[/{ s/^[[:space:]]*owner[[:space:]]*=[[:space:]]*(.+)$/\1/p }' "$cfg" 2>/dev/null | head -1 | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//")}
  mint=${CBM_MINT:?set CBM_MINT}
  [ -n "$rpc" ] && [ -n "$owner" ] || return 1
  # Three tries: right after a daemon_kill / persistent-ks cell the RPC path can be down for a moment (TLX2 11-08,
  # deb12: one "unreadable" in 23 cells while the same query answered 5/5 a minute later).
  local i
  for i in 1 2 3; do
    have=$(curl -s -m 15 "$rpc" -X POST -H 'content-type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$owner\",{\"mint\":\"$mint\"},{\"encoding\":\"jsonParsed\"}]}" 2>/dev/null \
      | jq -r 'if (.result.value|type)!="array" or (.result.value|length)==0 then empty
               else (.result.value[0].account.data.parsed.info) as $i | if ($i.delegate==null) then "0" else ($i.delegatedAmount.amount // "0") end end' 2>/dev/null)
    # An empty account list is an unanswered read, not a 0 allowance (fedora44 S2 11-08 read "0" once mid-run).
    case "$have" in ''|null) sleep 3 ;; *) echo "$have"; return 0 ;; esac
  done
  return 1
}

plat_device_id() { # stable fingerprint of the on-chain identity material (keys/wallet) in the installed home
  # cb33 keeps the device key at keys/operator.json (TLX 11-08: '*.key'/'*wallet*' matched nothing, so every
  # fingerprint was the hash of an empty list and "same device after upgrade" would always pass).
  sudo find "$CBM_PKG_HOME" -maxdepth 3 -type f \( -path '*/keys/*.json' -o -name '*.key' -o -iname '*wallet*' -o -iname '*keyring*' \) \
    -exec sha256sum {} + 2>/dev/null | awk '{print $1}' | sort | sha256sum | awk '{print $1}'
}

plat_config_present() { # rc 0 iff the installed instance still has config/key material on disk
  sudo test -d "$CBM_PKG_HOME" || return 1
  [ -n "$(sudo find "$CBM_PKG_HOME" -maxdepth 3 -type f \
      \( -name '*.key' -o -iname '*wallet*' -o -name '*.toml' -o -name 'config*' \) 2>/dev/null | head -1)" ]
}

plat_connect_short() { # $1 proto — briefly connect the INSTALLED c0 instance (daemon via systemd + its CLI)
  # cb33 CLI shape (TLX 11-08, checked against the 0.1.12 package on u22): the daemon is picked by --instance (its
  # socket /var/lib/sentinel-dvpn/<inst>/daemon.sock); --home is the CLI's OWN folder, never the daemon's home.
  #   start: client start --node <entry> (--channel <ch> | --new-channel --mode voucher --escrow-base-units N) --instance c0
  #   stop:  client stop <session id> --instance c0   (an id is required; ids from `client sessions`)
  # Paid by c0's key (keys/operator.json); u22 c0 = AUYUGLiP…, u24a c0 = 2A6UQWKA…, both in WALLETS-cb33.
  local cli eg out ch s ok=1 home=${CBM_CLI_HOME:-$HOME/.sentinel-dvpn}; cli=$(_s10_cli)
  declare -F node_for > /dev/null && node_for "$1" || [ -n "${NODE_ID:-}" ] || { echo "no node entry for $1"; return 1; }
  sudo systemctl is-active --quiet "$CBM_SVC" || sudo systemctl start "$CBM_SVC" || { echo "installed service not up"; return 1; }
  ch=${CHANNELS[$NODE_ID]:-}
  tx_gap
  if [ -n "$ch" ]; then out=$(sudo "$cli" --home "$home" client start --node "$NODE_ID" --channel "$ch" --instance "$CBM_PKG_INSTANCE" 2>&1)
  else
    out=$(sudo "$cli" --home "$home" client start --node "$NODE_ID" --new-channel --mode voucher \
      --escrow-base-units "${ESCROW:-100000}" --instance "$CBM_PKG_INSTANCE" 2>&1)
    ch=$(grep -oE '"channel(_id)?": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$ch" ] && { CHANNELS[$NODE_ID]=$ch; RUN_NEW_CHANNELS="${RUN_NEW_CHANNELS:-} $ch"; RUN_CHANNEL_PROTO="${RUN_CHANNEL_PROTO:-} $ch=${proto:-${1:-unknown}}"; }
  fi
  echo "$out" >> "${SCEN_DIR:-/tmp}/cli.txt"
  grep -qE '^error:|rpc error' <<<"$out" && { echo "installed-instance connect start failed: $(grep -m1 -E '^error:|rpc error' <<<"$out" | cut -c1-200)"; return 1; }
  sleep 8
  eg=$(plat_egress)
  echo "installed-instance short connect ($1): egress $eg (node $NODE_EGRESS)"
  for s in $(sudo "$cli" --home "$home" client sessions --instance "$CBM_PKG_INSTANCE" 2>/dev/null |
             awk '/"id":/ {gsub(/[",]/, "", $2); id = $2} /"status":/ {gsub(/[",]/, "", $2); if ($2 != "ended") print id}'); do
    tx_gap; sudo "$cli" --home "$home" client stop "$s" --instance "$CBM_PKG_INSTANCE" > /dev/null 2>&1 || ok=0
  done
  [ "$ok" = 1 ] || echo "stopping the installed instance's session failed"
  [ "$eg" = "$NODE_EGRESS" ] && [ "$ok" = 1 ]
}
plat_service_install_timeout() {
  # Force the service's start to exceed TimeoutStartSec (a drop-in with ExecStartPre=sleep), then prove the start
  # RETURNS (systemd times out, it does not hang) and leaves no half-installed state.
  plat_pkg_installed || return 77
  local dropdir="/etc/systemd/system/$CBM_SVC.service.d" conf rc
  conf="$dropdir/s10-slowstart.conf"
  sudo mkdir -p "$dropdir"
  printf '[Service]\nTimeoutStartSec=5\nExecStartPre=/bin/sleep 30\n' | sudo tee "$conf" > /dev/null
  sudo systemctl daemon-reload

  timeout 40 sudo systemctl restart "$CBM_SVC" > /dev/null 2>&1; rc=$?
  echo "service start under the slow-start fault: rc=$rc (124 = our 40 s bound killed a hang)"

  # Remove the fault and restore a healthy service, whatever happened above.
  sudo rm -f "$conf"; sudo rmdir "$dropdir" 2>/dev/null
  sudo systemctl daemon-reload
  sudo systemctl restart "$CBM_SVC" > /dev/null 2>&1

  [ "$rc" != 124 ] || { echo "the start hung past the 40 s bound (TimeoutStartSec did not fire)"; return 1; }
  [ "$rc" != 0 ]   || { echo "the start unexpectedly succeeded despite the 30 s ExecStartPre vs 5 s timeout"; return 1; }
  journalctl -u "$CBM_SVC" --since "-60s" 2>/dev/null | grep -qiE "timeout|timed out" \
    || { echo "no start-timeout message in the journal"; return 1; }
  plat_pkg_installed  || { echo "the package is no longer installed after the timeout (half-installed state)"; return 1; }
  plat_service_active || { echo "the service did not recover to active after the fault was removed"; return 1; }
  echo "slow start timed out cleanly (rc=$rc), journal reported it, package intact, service recovered"
}

# ─── S2 protocol_kill (TLX2 11-08): the Linux equivalent of killing the protocol ───
# wireguard / amneziawg: delete the session's tunnel interface (the kernel side), and kill amneziawg-go when the
# box runs the user-space AWG. hysteria2 / v2ray / xray / openvpn: SIGKILL the newest process. Echoes what it killed.
plat_tunnel_kill() {
  local proto=$1 ifs i p out=""
  case $proto in
    wireguard|amneziawg)
      ifs=$( { sudo wg show interfaces 2>/dev/null; sudo awg show interfaces 2>/dev/null; } | tr ' ' '\n' | grep . | sort -u)
      [ -n "$ifs" ] || { echo "no $proto interface"; return 1; }
      for i in $ifs; do sudo ip link del "$i" && out="$out link $i"; done
      [ "$proto" = amneziawg ] && for p in $(pgrep -x amneziawg-go); do sudo kill -KILL "$p" && out="$out pid $p"; done ;;
    *)
      p=$(pgrep -n -x "$(case $proto in hysteria2) echo 'hysteria|hysteria2' ;; *) echo "$proto" ;; esac)")
      [ -n "$p" ] || { echo "no $proto process"; return 1; }
      sudo kill -KILL "$p" && out="pid $p" ;;
  esac
  echo "${out# }"
}
