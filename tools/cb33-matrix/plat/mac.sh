#!/usr/bin/env bash
# ─── macOS adapter (FMC, 2026-11-07). Contract in README.md; same shape as plat/linux.sh. ───
# Runs INSIDE the macOS guest (Homebrew bash /usr/local/bin/bash, as the rig user), like linux.sh runs on its VM.
# Reach it from the GCP host the usual way: cell-guest.sh pipes a script to `bash -s` (the guest reads its own
# rig password; never copy it out). Expects the build under test in $CBM_DIR: ./sentinel-dvpnd and ./sentinel-dvpn.
#
# What differs from Linux (cb33092e sources):
#   home      /Library/Application Support/sentinel-dvpn/<tag> (instance.StateRoot darwin; has a SPACE: quote it)
#   socket    <home>/daemon.sock; launchd label co.sentinel.sentinel-dvpnd.<tag>; log /Library/Logs/sentinel-dvpn/<tag>.log
#   KS        pf anchor sentinel-dvpn-<tag> (client_darwin.go newFirewall = Tag.ObjectName()), token <home>/pf.token
#   deadman   the guest's ddv-deadman honours /var/run/ddv-deadman.hold (macOS has no /run)
#   faults    ON THE GCP HOST (ddv-faultctl drops QEMU's packets). dvpnd keeps its KS anchor first in pf, so a cut
#             inside the guest could pass for the wrong reason. The guest holds no host credential, so plat_cut
#             writes a request to $FAULT_REQ and plat/mac-host-relay.sh (started on the host by the run owner)
#             runs it and acks into $FAULT_ACK. No ack in 10 s = plat_cut fails, never a silent no-op.
#             Never pfctl -F all / -d (rig rule): the selftest plant only touches the KS anchor.
#   sudo      always sudo -n: a password prompt over ssh with no tty looks like a hang.
#   old app   the pre-cb33 service network.sentinel.devnet-dvpn.dvpnd must be gone (two KS anchors / utun owners).
#   tools     no `timeout`, `ip`, `setsid`, GNU sed: perl alarm, route/ifconfig/netstat, nohup, sed -i ''.
# DAEMON_MODE=manual (default) runs `sentinel-dvpnd run` by hand like linux.sh; DAEMON_MODE=launchd drives the
# installed service (the app's install) through launchctl instead.

export LC_ALL=C LANG=C  # the guest's perl warns about the locale on stderr; the words check would flag it
CBM_DIR=${CBM_DIR:-$HOME/cb33}
INSTANCE=${INSTANCE:-c0}
STATE_ROOT=${STATE_ROOT:-/Library/Application Support/sentinel-dvpn}
IHOME=${IHOME:-$STATE_ROOT/$INSTANCE}
CLI_HOME=${CLI_HOME:-$HOME/.sentinel-dvpn}
CFG=${CFG:-$IHOME/config.toml}
DAEMON_MODE=${DAEMON_MODE:-manual}
LABEL=${LABEL:-co.sentinel.sentinel-dvpnd.$INSTANCE}
OLD_LABEL=network.sentinel.devnet-dvpn.dvpnd
KS_ANCHOR=${KS_ANCHOR:-sentinel-dvpn-$INSTANCE}
FAULT_REQ=${FAULT_REQ:-/tmp/cbm-fault.req}
FAULT_ACK=${FAULT_ACK:-/tmp/cbm-fault.ack}
DLOG=$CBM_DIR/daemon-cbm.log
[ "$DAEMON_MODE" = launchd ] && DLOG=/Library/Logs/sentinel-dvpn/$INSTANCE.log
HOLD=/var/run/ddv-deadman.hold

# perl alarm stands in for coreutils timeout (not on a stock Mac).
tmo() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }
cli() { (cd "$CBM_DIR" && sudo -n ./sentinel-dvpn --home "$CLI_HOME" "$@" --instance "$INSTANCE") 2>&1 | tee -a "$SCEN_DIR/cli.txt"; }
# chain CLI: node_chain_cli's generic else-branch drops --home and the lane URL, so a Mac plat hook is required
# for `node show`/`node search` to use lane-b (mirrors linux.sh:15). TMC 2026-11-08.
plat_chain_cli() { (cd "$CBM_DIR" && sudo -n ./sentinel-dvpn --home "$CLI_HOME" ${HELIUS_RPC_URL:+--rpc.url "$HELIUS_RPC_URL"} "$@"); }

# ─── Program delegate (mac): approve + read the token-2022 delegate allowance ──
# A funded c0 can't open a channel until the program's token delegate is approved (TLX2 11-08);
# preflight_delegate / CBM_DELEGATE_AMOUNT in lib/common.sh blind any cell whose delegate is short.
# Mirrors linux.sh:597-614 with Mac mechanics (sudo -n, CLI_HOME, the service config.toml). TMC 2026-11-08.
plat_delegate_approve() { # $1 = base units or "unlimited" (default unlimited); approve the program delegate
  tx_gap
  (cd "$CBM_DIR" && sudo -n ./sentinel-dvpn --home "$CLI_HOME" ${HELIUS_RPC_URL:+--rpc.url "$HELIUS_RPC_URL"} \
    wallet approve-delegate --amount-base-units "${1:-unlimited}" --key.name operator 2>&1)
}
plat_delegate_read() { # echo the wallet's program-delegate allowance in base units (or "unlimited"); empty on failure
  local cfg="$CLI_HOME/config.toml" rpc owner mint have
  # rpc.url is under [rpc]; owner is a ROOT-level key (before the first [section]). Single-quoted TOML — strip ' or ".
  rpc=${CBM_RPC_URL:-${HELIUS_RPC_URL:-$(sudo -n sed -nE '/^\[rpc\]/,/^\[/{ s/^[[:space:]]*url[[:space:]]*=[[:space:]]*(.+)$/\1/p }' "$cfg" 2>/dev/null | head -1 | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//")}}
  owner=${CBM_OWNER:-$(sudo -n sed -nE '1,/^\[/{ s/^[[:space:]]*owner[[:space:]]*=[[:space:]]*(.+)$/\1/p }' "$cfg" 2>/dev/null | head -1 | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//")}
  mint=${CBM_MINT:?set CBM_MINT}
  [ -n "$rpc" ] && [ -n "$owner" ] || return 1
  have=$(curl -s -m 15 "$rpc" -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$owner\",{\"mint\":\"$mint\"},{\"encoding\":\"jsonParsed\"}]}" 2>/dev/null \
    | jq -r '(.result.value[0].account.data.parsed.info) as $i | if ($i|not) or ($i.delegate==null) then "0" else ($i.delegatedAmount.amount // "0") end' 2>/dev/null)
  case "$have" in ''|null) return 1 ;; *) echo "$have" ;; esac
}

# ─── Deadman (overrides lib/common.sh's Linux /run path) ───
deadman_start() {
  ( while :; do sudo -n touch "$HOLD" 2>/dev/null; sleep 30; done ) &
  DEADMAN_PID=$!
}
deadman_stop() { [ -n "${DEADMAN_PID:-}" ] && kill "$DEADMAN_PID" 2>/dev/null; sudo -n rm -f "$HOLD" 2>/dev/null; return 0; }

# DNS servers + SOCKS proxy state per network service, one line each (leftovers diff it against plat_init).
net_snapshot() {
  local s
  networksetup -listallnetworkservices 2>/dev/null | sed 1d | grep -v '^\*' | while IFS= read -r s; do
    echo "$s|$(networksetup -getdnsservers "$s" 2>/dev/null | tr '\n' ' ')|$(networksetup -getsocksfirewallproxy "$s" 2>/dev/null | awk '/^Enabled/ {print $2; exit}')"
  done
}

plat_init() {
  case $NODE in
    node-3) NODE_ID=${NODE3_ID:?set NODE3_ID (node-3 address)}; NODE_IP=${NODE3_IP:?set NODE3_IP} ;;
    node-4) NODE_ID=${NODE4_ID:?set NODE4_ID (node-4 pubkey)}; NODE_IP=${NODE4_IP:?set NODE4_IP} ;;
    *) NODE_ID=$NODE; NODE_IP=${NODE_IP:?set NODE_IP for a custom node} ;;
  esac
  NODE_EGRESS=${NODE_EGRESS:-$NODE_IP}
  sudo -n true 2>/dev/null || { say "sudo -n needs a password here"; return 1; }
  sudo -n launchctl print "system/$OLD_LABEL" >/dev/null 2>&1 \
    && { say "old service $OLD_LABEL is still loaded: uninstall the pre-cb33 app first"; return 1; }
  PHYS_IF=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
  PHYS_ADDRS=$(ifconfig "$PHYS_IF" 2>/dev/null | awk '$1 == "inet" {print $2} $1 == "inet6" && $2 !~ /^fe80/ {print $2}' | tr '\n' ' ')
  GATEWAY_IP=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
  CONTROL_IP=${CONTROL_IP:-$(echo "${SSH_CLIENT:-}" | awk '{print $1}')}
  DIRECT_IP=$(curl -4 -s -m 8 https://api.ipify.org)
  [ -n "$DIRECT_IP" ] && [ -n "$PHYS_IF" ] || return 1
  [ -x "$CBM_DIR/sentinel-dvpnd" ] || { say "no $CBM_DIR/sentinel-dvpnd"; return 1; }
  BASE_NET=$(net_snapshot)
  : > "$FAULT_REQ"; : > "$FAULT_ACK"; FAULT_N=0
  [ "$DAEMON_MODE" = manual ] && : > "$DLOG"
  READY=$(sudo -n grep -c '"message":"ready"' "$DLOG" 2>/dev/null || true); READY=${READY:-0}
  deadman_start
}

plat_build() { (cd "$CBM_DIR" && ./sentinel-dvpnd version 2>&1 | head -1 | cut -c1-120); }
plat_protocols() { echo "${CBM_PROTOCOLS:-wireguard amneziawg openvpn hysteria2 v2ray xray}"; }

dpid() {
  if [ "$DAEMON_MODE" = launchd ]; then
    sudo -n launchctl print "system/$LABEL" 2>/dev/null | awk '$1 == "pid" {print $3; exit}'
  else
    pgrep -f "^\./sentinel-dvpnd run --instance $INSTANCE"
  fi
}
plat_daemon_running() { [ -n "$(dpid)" ]; }
# S9 slope sources, matching linux.sh:42-43's contract: mem = RSS in KB (macOS ps -o rss is KB, == linux VmRSS kB);
# handles = numbered fds only (lsof FD col starts with a digit, ~ linux /proc/<pid>/fd); empty (not 0) when no pid. FMC/TMC 2026-11-08.
plat_daemon_mem() { local p; p=$(dpid | head -1); [ -n "$p" ] && ps -o rss= -p "$p" 2>/dev/null | awk 'NR==1{print $1+0}'; }
plat_daemon_handles() { local p; p=$(dpid | head -1); [ -n "$p" ] && sudo -n lsof -nP -p "$p" 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]/' | wc -l | tr -d ' '; }
wait_ready() {
  # launchd keepalive restart may emit no fresh ready line; in that mode the socket answering IS readiness. TMC 2026-11-08.
  local i n sock="$CLI_HOME/daemon.sock"
  for i in $(seq 1 30); do
    n=$(sudo -n grep -c '"message":"ready"' "$DLOG" 2>/dev/null || true)
    [ "${n:-0}" -gt "$READY" ] && { READY=$n; return 0; }
    if [ "$DAEMON_MODE" = launchd ] && [ -S "$sock" ] && (cd "$CBM_DIR" && sudo -n ./sentinel-dvpn --home "$CLI_HOME" client sessions --instance "$INSTANCE" >/dev/null 2>&1); then
      READY=${n:-$READY}; return 0
    fi
    sleep 1
  done
  return 1
}
plat_daemon_start() {
  plat_daemon_running && return 0
  if [ "$DAEMON_MODE" = launchd ]; then
    # After bootout, kickstart returns 0 yet cannot start it ("not in domain"); bootstrap first, then kickstart. TMC 2026-11-08.
    sudo -n launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" >/dev/null 2>&1 || true
    sudo -n launchctl kickstart "system/$LABEL" >/dev/null 2>&1 || true
  else
    (cd "$CBM_DIR" && sudo -n nohup ./sentinel-dvpnd run --instance "$INSTANCE" >> "$DLOG" 2>&1 < /dev/null &)
  fi
  wait_ready
}
# launchd: TERM = a clean stop that stays stopped (bootout); KILL = a crash (launchd may restart it: that is the point).
plat_daemon_stop() {
  local sig=${1:-TERM} p
  if [ "$DAEMON_MODE" = launchd ] && [ "$sig" = TERM ]; then
    sudo -n launchctl bootout "system/$LABEL" >/dev/null 2>&1
  else
    p=$(dpid); [ -n "$p" ] && sudo -n kill "-$sig" $p
  fi
  [ "$DAEMON_MODE" = launchd ] && [ "$sig" = KILL ] && return 0
  local i; for i in $(seq 1 20); do plat_daemon_running || return 0; sleep 1; done
  return 1
}

plat_connect() {
  local proto=$1 out
  tx_gap
  # cb33 has no `client start --protocol`: the protocol follows the node. cb33-matrix/lib/nodes.sh
  # (sourced by cb33-matrix.sh before any plat_* call) has already set NODE_ID/NODE_IP/NODE_PORT for
  # $proto, or SKIPped it. A channel is per node ENTRY, so cache it keyed on NODE_ID:NODE_PORT and
  # never reuse it across entries.
  local chkey chfile; chkey="${NODE_ID}:${NODE_PORT:-}"
  chfile="$CBM_DIR/.channel-$(printf '%s' "$chkey" | tr -c 'A-Za-z0-9' _)"
  [ -f "$chfile" ] && CHANNEL=$(cat "$chfile") || CHANNEL=""
  if [ -n "$CHANNEL" ]; then
    out=$(cli client start --node "$NODE_ID" --channel "$CHANNEL")
  else
    out=$(cli client start --node "$NODE_ID" --new-channel --mode voucher --escrow-base-units "${ESCROW:-100000}")
    CHANNEL=$(grep -oE '"channel(_id)?": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$CHANNEL" ] && {
      printf '%s\n' "$CHANNEL" > "$chfile"; say "   opened channel $CHANNEL for $chkey (cached per node entry)"
      # Record channels THIS run opened, for the run-end money grade (checks/money.sh). Only new
      # channels are closed + graded; a reused cached channel is not re-added. Mirrors linux.sh.
      case " ${RUN_NEW_CHANNELS:-} " in *" $CHANNEL "*) : ;; *) RUN_NEW_CHANNELS="${RUN_NEW_CHANNELS:+$RUN_NEW_CHANNELS }$CHANNEL"; RUN_CHANNEL_PROTO="${RUN_CHANNEL_PROTO:+$RUN_CHANNEL_PROTO }$CHANNEL=$proto" ;; esac
    }
  fi
  SID=$(grep -oE '"(session_)?id": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  [ -z "$SID" ] && SID=$(plat_sessions | head -1)
  [ -n "$SID" ]
}
plat_disconnect() {
  local s rc=0
  for s in $(plat_live_sessions); do tx_gap; cli client stop "$s" >/dev/null || rc=1; done
  return $rc
}
plat_sessions() { cli client sessions 2>/dev/null | grep -oE '"id": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/'; }
# S4 hooks (README plat_switch contract 0cb8dc9), mirroring linux.sh:93-113. cb33 has no native switch:
# stop every live (non-ended) session, wait <=15 s for none live, then plat_connect the current $NODE_ID entry. TMC 2026-11-08.
plat_live_sessions() {
  cli client sessions 2>/dev/null | awk '/"id":/ {gsub(/[",]/, "", $2); id = $2} /"status":/ {gsub(/[",]/, "", $2); if ($2 != "ended" && id != "") print id; id = ""}'
}
plat_switch() {
  local s i
  for s in $(plat_live_sessions); do tx_gap; cli client stop "$s" >/dev/null || { echo "switch: stopping $s failed"; return 1; }; done
  for i in $(seq 1 15); do [ -z "$(plat_live_sessions)" ] && break; sleep 1; done
  [ -z "$(plat_live_sessions)" ] || { echo "switch: a session is still live 15 s after stop"; return 1; }
  plat_connect "$1"
}
plat_live_node() {
  local id; id=$(plat_live_sessions | head -1); [ -n "$id" ] || return 0
  (cd "$CBM_DIR" && tmo 5 sudo -n ./sentinel-dvpn --home "$CLI_HOME" client status "$id" --instance "$INSTANCE") 2>/dev/null |
    grep -oE '"node": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

plat_status_line() {
  local s out st ks
  ks=$(sudo -n grep -oE "^kill_switch = '[a-z]+'" "$CFG" 2>/dev/null | grep -oE "'[a-z]+'" | tr -d "'")
  for s in $(plat_sessions); do
    out=$(cd "$CBM_DIR" && tmo 5 sudo -n ./sentinel-dvpn --home "$CLI_HOME" client status "$s" --instance "$INSTANCE" 2>&1)
    st=$(grep -oE '"status": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    case $st in active|reconnecting|connecting|checking) break ;; esac
  done
  echo "state=${st:-none} ks=${ks:-off} id=${s:--} text=$(grep -oE '"(error|message)": *"[^"]*"' <<<"$out" | head -1 | tr '\n' ' ')"
}

plat_egress() { curl -4 -s -m 6 https://api.ipify.org || echo none; }
plat_egress6() { curl -6 -s -m 6 https://api64.ipify.org || echo none; }
plat_dns_probe() { dig +short -t TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null | tr -d '"' | head -1; }

plat_set_ks() { sudo -n sed -i '' -E "s/^kill_switch = '[a-z]+'/kill_switch = '$1'/" "$CFG"; }

plat_capture_start() { sudo -n tcpdump -i "$PHYS_IF" -nn -w "$1" -U >/dev/null 2>&1 & CAP_PID=$!; sleep 1; }
plat_capture_stop() {
  # $CAP_PID is the sudo wrapper; stop the tcpdump under it too.
  [ -n "${CAP_PID:-}" ] && { sudo -n pkill -INT -P "$CAP_PID" tcpdump 2>/dev/null; sudo -n kill "$CAP_PID" 2>/dev/null; }
  sleep 1; sudo -n chmod a+r "$LEAK_PCAP" 2>/dev/null; return 0
}

plat_leftovers() {
  local r
  r=$(sudo -n pfctl -a "$KS_ANCHOR" -s rules 2>/dev/null); [ -n "$r" ] && echo "pf: anchor $KS_ANCHOR still has $(grep -c . <<<"$r") rule(s)"
  sudo -n test -e "$IHOME/pf.token" && echo "file: $IHOME/pf.token (pf enable token not released)"
  # utun with an IPv4 address = a tunnel (the system's utun0-3 carry only IPv6 link-local).
  ifconfig 2>/dev/null | awk '/^[a-z]/ {u = ($1 ~ /^utun[0-9]+:$/) ? $1 : ""} u && /inet / {sub(":", "", u); print "link: " u; u = ""}'
  netstat -rn -f inet 2>/dev/null | awk '$NF ~ /^utun/ {print "route: " $1 " via " $NF}' | sort -u
  diff <(echo "$BASE_NET") <(net_snapshot) | sed -n 's/^> /dns-or-proxy changed: /p'
  pgrep -l -f "xray|v2ray|hysteria|openvpn|wireguard-go|amneziawg-go" 2>/dev/null | grep -v pgrep | sed 's/^/process: /'
  sudo -n find "$IHOME" -maxdepth 3 -type f \( -name '*.key' -o -name '*auth.txt' -o -name '*.conf' -o -name '*.yaml' \) 2>/dev/null | sed 's/^/file: /'
}
plat_plant_leftover() { echo 'block drop out quick proto tcp to 192.0.2.1 port 9' | sudo -n pfctl -a "$KS_ANCHOR" -f - 2>/dev/null; }
plat_unplant_leftover() { sudo -n pfctl -a "$KS_ANCHOR" -F rules 2>/dev/null; return 0; }

# ─── Host-side faults through plat/mac-host-relay.sh ───
# One request line "<n> <verb> <args>" in $FAULT_REQ; the relay appends "<n> rc=<rc>" to $FAULT_ACK.
FAULT_N=0
fault_req() {
  local i ack
  FAULT_N=$((FAULT_N + 1))
  echo "$FAULT_N $*" >> "$FAULT_REQ"
  for i in $(seq 1 20); do
    ack=$(grep "^$FAULT_N rc=" "$FAULT_ACK" 2>/dev/null | head -1)
    [ "$ack" = "$FAULT_N rc=0" ] && return 0
    [ -n "$ack" ] && { say "host fault '$*' failed: $ack"; return 1; }
    sleep 0.5
  done
  say "host fault '$*' not acked in 10 s: is plat/mac-host-relay.sh running on the host?"
  return 1
}
# Without seconds the cut holds until plat_uncut (ddv-faultctl caps a fault at 600 s, so a lost driver never strands it).
plat_cut() {
  fault_req block "$NODE_IP" "${1:-600}" || return 1
  [ -n "${1:-}" ] && { sleep "$1"; plat_uncut; }
  return 0
}
plat_uncut() { [ "$FAULT_N" -gt 0 ] || return 0; fault_req clear; return 0; }

plat_cli_outputs() { cat "$SCEN_DIR/cli.txt" 2>/dev/null; sudo -n grep -oE '"(error|message|reason)":"[^"]*"' "$DLOG" 2>/dev/null | tail -50; }

# ─── Money (ported from linux.sh:356-444 for the shared grade in checks/money.sh; FLX pattern 2026-11-08) ───
# cb33 `client sessions` has no owed/paid fields: sum per-session "spent" over a channel; "paid" has no
# client-side source (money.sh skips it). node_settled/redeemed come from a chain read of the channel.
chain_channel_field() { # $1 field — reads $CHANNEL from chain (no --instance; a chain query, not a daemon call)
  [ -n "${CHANNEL:-}" ] || return 1
  plat_chain_cli channel show "$CHANNEL" 2>/dev/null | grep -oE "\"$1\": *[0-9]+" | head -1 | grep -oE '[0-9]+$'
}
# base units one session may sign ahead: max(config prepay, node min) × node price, rounded up. Unknown price → 0.
prepay_window_units() {
  local basis pb ps meta uri mpb mps ppg pph
  basis=$(sudo -n sed -nE "s/^basis = '([a-z_]+)'/\1/p" "$CFG" | head -1)
  pb=$(sudo -n sed -nE 's/^prepay_bytes = ([0-9]+)/\1/p' "$CFG" | head -1); ps=$(sudo -n sed -nE 's/^prepay_seconds = ([0-9]+)/\1/p' "$CFG" | head -1)
  uri=$(plat_chain_cli node show "$NODE_ID" 2>/dev/null | grep -oE '"uri": *"https://[^"]+"' | head -1 | grep -oE 'https://[^"]+')
  [ -n "$uri" ] && meta=$(curl -sk -m 8 "$uri/v1/metadata")
  mpb=$(grep -oE '"min_channel_prepay_bytes":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); mps=$(grep -oE '"min_channel_prepay_seconds":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  ppg=$(grep -oE '"channel_price_per_gb":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); pph=$(grep -oE '"channel_price_per_hour":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  awk -v b="${basis:-per_gb}" -v pb="${pb:-0}" -v ps="${ps:-0}" -v mpb="${mpb:-0}" -v mps="${mps:-0}" -v ppg="${ppg:-0}" -v pph="${pph:-0}" 'BEGIN {
    if (b == "per_hour") { s = (ps > mps ? ps : mps); v = s * pph / 3600 } else { y = (pb > mpb ? pb : mpb); v = y * ppg / 1e9 }
    printf "%d\n", (v == int(v) ? v : int(v) + 1) }'
}
plat_money() { # per-scenario: spent summed over $CHANNEL's sessions; redeemed/node_settled judged once at run end
  local j spent n redeemed escrow
  j=$(cli client sessions 2>/dev/null)
  spent=$(awk -v ch="${CHANNEL:-}" '/"spent":/ {gsub(/[^0-9]/, "", $2); s = $2} /"channel":/ {if (ch != "" && index($0, ch)) t += s; s = 0} END {print t + 0}' <<<"$j")
  n=$(awk -v ch="${CHANNEL:-}" '/"channel":/ {if (ch != "" && index($0, ch)) c++} END {print c + 0}' <<<"$j")
  redeemed=$(chain_channel_field redeemed); escrow=$(chain_channel_field escrow)
  MONEY_PREPAY_ALLOW=$(( n * $(prepay_window_units) ))
  echo "spent=$spent paid=unknown node_settled=unknown redeemed=${redeemed:-unknown} escrow=${escrow:-unknown} prepay_allow=$MONEY_PREPAY_ALLOW"
}
# Run-end: close only the channels THIS run opened (7 s apart), up to 4 tries; CLOSE-NOT-LANDED → "cannot judge".
# start-close needs the OWNER key (CBM_CHAIN_KEY); absent → CLOSE-SKIPPED-NO-KEY (reclaim from the funder).
plat_close_run_channels() {
  local ch k out started key
  [ -n "${RUN_NEW_CHANNELS:-}" ] || return 0
  key="${CBM_CHAIN_HOME:-$CLI_HOME}/keys/${CBM_CHAIN_KEY:-owner}.json"
  if ! sudo -n test -r "$key" 2>/dev/null; then
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
# Summed fallback (checks/money.sh uses plat_money_run_channels when present; this is the all-channels sum).
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
plat_money_run_channels() { # one line per channel, graded per channel by checks/money.sh money_channel_ok (7d9affb)
  local j ch s c r w p
  j=$(cli client sessions 2>/dev/null); w=$(prepay_window_units)
  for ch in ${RUN_NEW_CHANNELS:-}; do
    s=$(awk -v ch="$ch" '/"spent":/ {gsub(/[^0-9]/, "", $2); v = $2} /"channel":/ {if (index($0, ch)) t += v; v = 0} END {print t + 0}' <<<"$j")
    c=$(awk -v ch="$ch" '/"channel":/ {if (index($0, ch)) k++} END {print k + 0}' <<<"$j")
    r=$(CHANNEL=$ch chain_channel_field redeemed); p=$(tr ' ' '\n' <<<"${RUN_CHANNEL_PROTO:-}" | sed -n "s/^$ch=//p" | head -1)
    echo "channel=$ch proto=${p:-unknown} spent=$s redeemed=${r:-unknown} sessions=$c step=${w:-0}"
  done
}

plat_reset() { plat_uncut; plat_daemon_running || plat_daemon_start; plat_disconnect >/dev/null 2>&1; plat_set_ks off; return 0; }
