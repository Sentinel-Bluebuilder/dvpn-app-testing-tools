#!/usr/bin/env bash
# ─── Android adapter (FAN, 2026-11-08). Contract in README.md; same shape as plat/linux.sh. ───
# The driver runs ON the Android rig host (the Linux VM that runs the emulator); every step reaches the phone with adb.
# What differs from Linux:
#   app       network.sentinel.devnetdvpn, debug build with the ddv-exec hook (~/hook.py). Connect, disconnect, kill
#             switch and settle go through the app CLI: that is the user's path (the app's VpnService owns the TUN
#             and hands dvpnd its fd; a bare `client start` would have no TUN).
#   daemon    sentinel-dvpnd runs under the app's VPN service; its supervisor (DaemonProcess.kt) restarts it with
#             backoff (1 s first) whenever it exits. So "stop" = kill the process and wait until THAT pid is gone;
#             "down" lasts until the supervisor's restart. There is no stopped-daemon state while the service lives.
#   reads     sessions / status / channel / node through a Linux build of the same cb33 sentinel-dvpn CLI ($CBM_CLI)
#             on the daemon's own socket: a root nc relay on the phone, adb forward, socat to a local
#             unix socket. ~30 ms a call (the app CLI takes ~1 s, over the status check's 1 s limit).
#   probes    /data/local/tmp/ddvprobe as the shell uid, which the VPN covers like any app: ip, ip6, dns, get. Egress
#             asks icanhazip, which the app never asks (its quality check uses ipify), so a direct DNS question
#             for it is always the test's. Needs ddvprobe with the URL argument (#34 tools/ddvprobe, 11-08).
#   capture   /data/local/tmp/ddvcap (tools/ddvcap) as root on the phone's NIC (wlan0 or eth0): the emulator's console
#             capture does not see the phone's Wi-Fi traffic and the image has no tcpdump.
#   own uid   the app's own uid is outside the VPN by design (dvpnd's node and RPC sockets, the app's chain reads),
#             so that traffic is direct with any kill switch. LEAK_ALLOW_HOSTS gets every listed node's IP and the
#             app's RPC hosts (no rpc-direct row: on Android RPC is always direct by design, not a pooled
#             pre-tunnel connection). tools/pcap-dns-drop.py drops DNS queries for those host names and link-local
#             multicast (mDNS/IGMP/MLD: LAN-scope like DHCP/ND), and writes what it dropped to <pcap>.filter.txt.
#             Everything else the phone sends counts.
#   edges     a status sample costs two adb round trips (~1-2 s), so LEAK_EDGE_S defaults to 3 here (one sample).
#   KS        off / persist through `daemon set --kill-switch` (the app's path). 'on' has no app path (Q0426: the
#             app's one On = persist), so 'on' is written into config.toml with run-as, like the other adapters.
#   cut       iptables DROP on the rig host: the emulator's packets leave through the host's own sockets.
#   airplane  plat_airplane on|off (S9): `cmd connectivity airplane-mode`.

export PATH=$PATH:/usr/local/bin
HERE_ANDROID=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG=${PKG:-network.sentinel.devnetdvpn}
INSTANCE=c0
APP_FILES=/data/user/0/$PKG/files
IHOME=$APP_FILES/sentinel-dvpn/$INSTANCE
CFG_REL=files/sentinel-dvpn/$INSTANCE/config.toml
CBM_CLI=${CBM_CLI:-$HOME/cbm-cli/sentinel-dvpn}
CLI_HOME=${CLI_HOME:-$HOME/cbm-cli/home}
SOCK=${CBM_SOCK:-/tmp/cbm-dvpnd.sock}
FWD_PORT=${CBM_FWD_PORT:-50191}
PROBE=/data/local/tmp/ddvprobe
CAP=/data/local/tmp/ddvcap
HOOK=${CBM_HOOK:-$HOME/hook.py}
BASIS=${CBM_BASIS:-per_gb}

# ─── Plumbing ───
redact() { sed -E 's/(api-key=)[^&"[:space:]]+/\1REDACTED/g'; }
# App CLI on the phone (the user's path). Output goes to the scenario's cli.txt for the words check.
app() { python3 "$HOOK" --env DVPN_KEYFILE="$APP_FILES/test/owner.json" cli "$@" 2>&1 | redact | tee -a "${SCEN_DIR:-/tmp}/cli.txt"; }
# Daemon reads over the forwarded socket.
dcli() { "$CBM_CLI" --home "$CLI_HOME" --daemon.endpoint "$SOCK" "$@" 2>&1; }
plat_chain_cli() { "$CBM_CLI" --home "$CLI_HOME" ${HELIUS_RPC_URL:+--rpc.url "$HELIUS_RPC_URL"} "$@"; }
asapp() { adb exec-out run-as "$PKG" "$@"; }
crlf() { tr -d '\r'; }

# adbd stays unrooted: the app's debug hook only answers the shell uid (2000). Root work goes through `su 0`
# (userdebug image). The socket path: a root toybox nc relay on the phone's loopback (one `nc -U` per connection)
# → adb forward → socat to a local unix socket on the rig.
RELAY_PORT=${CBM_RELAY_PORT:-50192}
su0() { adb shell "su 0 $*"; }
sock_up() {
  su0 pidof nc >/dev/null 2>&1 \
    || su0 "sh -c 'setsid nohup nc -L -s 127.0.0.1 -p $RELAY_PORT nc -U $IHOME/daemon.sock </dev/null >/dev/null 2>&1 &'"
  adb forward "tcp:$FWD_PORT" "tcp:$RELAY_PORT" >/dev/null || return 1
  pgrep -f "^socat UNIX-LISTEN:$SOCK" >/dev/null && return 0
  rm -f "$SOCK"
  (setsid nohup socat "UNIX-LISTEN:$SOCK,fork,mode=600" "TCP:127.0.0.1:$FWD_PORT" >/dev/null 2>&1 < /dev/null &)
  sleep 1
}

dpid() { su0 pidof sentinel-dvpnd 2>/dev/null | crlf | awk '{print $1}'; }
# S9 resources: the daemon's resident memory (KiB) and open file descriptors.
plat_daemon_mem() { local p; p=$(dpid); [ -n "$p" ] && su0 "sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' /proc/$p/status" | crlf; }
plat_daemon_handles() { local p; p=$(dpid); [ -n "$p" ] && su0 "ls /proc/$p/fd" | crlf | grep -c .; }

# ─── Init ───
plat_init() {
  case $NODE in
    node-3) NODE_ID=${NODE3_ID:?set NODE3_ID (node-3 pubkey)}; NODE_IP=${NODE3_IP:?set NODE3_IP} ;;
    node-4) NODE_ID=${NODE4_ID:?set NODE4_ID (node-4 pubkey)}; NODE_IP=${NODE4_IP:?set NODE4_IP} ;;
    *) NODE_ID=$NODE; NODE_IP=${NODE_IP:?set NODE_IP for a custom node} ;;
  esac
  NODE_EGRESS=${NODE_EGRESS:-$NODE_IP}
  adb get-state >/dev/null 2>&1 || { say "no emulator on adb"; return 1; }
  [ -x "$CBM_CLI" ] || { say "no $CBM_CLI (Linux build of the cb33 sentinel-dvpn CLI)"; return 1; }
  sock_up || { say "could not forward the daemon socket"; return 1; }
  adb shell "[ -x $PROBE ] && [ -x $CAP ]" || { say "push ddvprobe and ddvcap to /data/local/tmp first"; return 1; }
  # Start with no session and KS off, so the direct egress and the NIC are the phone's own.
  plat_daemon_running || plat_daemon_start || { say "dvpnd is not running under the app"; return 1; }
  app daemon restore-network >/dev/null
  plat_set_ks off; plat_restart_daemon
  PHYS_IF=$(adb shell ip route get 1.1.1.1 2>/dev/null | crlf | grep -oE 'dev [a-z0-9]+' | head -1 | cut -d' ' -f2)
  PHYS_ADDRS=$(adb shell ip -o -4 addr show 2>/dev/null | crlf | awk '$2 ~ /^(wlan|eth)/ {split($4, a, "/"); print a[1]}' | tr '\n' ' ')
  # Lockdown denies the route lookup to the shell uid: take the first wlan/eth interface with an address.
  [ -n "$PHYS_IF" ] || PHYS_IF=$(adb shell ip -o -4 addr show 2>/dev/null | crlf | awk '$2 ~ /^(wlan|eth)/ {print $2; exit}')
  GATEWAY_IP=$(adb shell ip route get 1.1.1.1 2>/dev/null | crlf | grep -oE 'via [0-9.]+' | head -1 | cut -d' ' -f2)
  CONTROL_IP=''   # adb is not on the phone's network
  DIRECT_IP=$(plat_egress)
  # Android lockdown (Always-on + block without VPN) has no direct egress until the VPN is up: by design.
  # ks-on/persist cells run with it on (product config, tools/android-lockdown.sh); off = the "lockdown off" variant.
  [ "$(adb shell settings get secure always_on_vpn_lockdown 2>/dev/null | crlf)" = 1 ] && CBM_LOCKDOWN=1
  ANDROID_LOCKDOWN=$([ -n "${CBM_LOCKDOWN:-}" ] && echo on || echo off)
  echo "$ANDROID_LOCKDOWN" > "${OUT:-/tmp}/android-lockdown.txt"
  case $DIRECT_IP in none|'') [ -n "${CBM_LOCKDOWN:-}" ] || { say "no direct egress from the phone"; return 1; } ;; esac
  [ -n "$PHYS_IF" ] || return 1
  # The app's own uid is outside the VPN by design: every listed node (its probes) and the RPC hosts go direct.
  local nodes rpc
  # Every listed node's host (the app probes them all every few minutes): IPs as is, names resolved here and
  # added to APP_HOSTS so their DNS questions are dropped too.
  local nhosts
  nhosts=$(app nodes list --no-probe --json 2>/dev/null | python3 -c '
import json, sys, urllib.parse
d = json.load(sys.stdin)
d = d.get("nodes", d) if isinstance(d, dict) else d
print(" ".join(sorted({h for h in (urllib.parse.urlsplit(n.get("uri", "")).hostname for n in d) if h and not h.endswith(".invalid")})))')
  [ -n "$nhosts" ] || { say "could not read the node list from the app"; return 1; }
  nodes=$(for h in $nhosts; do if [[ $h =~ ^[0-9.]+$ ]]; then echo "$h"; else getent ahostsv4 "$h" | awk '{print $1}'; fi; done | sort -u | tr '\n' ' ')
  CBM_APP_HOSTS="${CBM_APP_HOSTS:-} $(tr ' ' '\n' <<<"$nhosts" | grep -vE '^[0-9.]*$' | tr '\n' ' ')"
  APP_HOSTS=$(asapp cat "$CFG_REL" files/data/rpc-pin.json 2>/dev/null | grep -oE "(https|wss)://[A-Za-z0-9.-]+" | sed -E 's#^[a-z]+://##' | sort -u | tr '\n' ' ')
  # + the app's connection-quality IP lookups (src/core/quality/quality.ts IP_SERVICES), also the app's own uid.
  # Not icanhazip: the rig's probe asks it as the shell uid, which the VPN covers, so a direct packet is a leak.
  APP_HOSTS="$APP_HOSTS api.devnet.solana.com api.ipify.org api64.ipify.org ifconfig.co ${CBM_APP_HOSTS:-}"
  rpc=$(for h in $APP_HOSTS; do getent ahostsv4 "$h" | awk '{print $1}'; done | sort -u | tr '\n' ' ')
  LEAK_ALLOW_HOSTS="168.63.129.16 169.254.169.254 $nodes $rpc"
  LEAK_RPC_HOSTS_FIXED=''
  LEAK_EDGE_S=${LEAK_EDGE_S:-3}
  SOCKS=/data/local/tmp/cbm-socks.sh
  adb push "$HERE_ANDROID/../tools/cbm-socks.sh" "$SOCKS" >/dev/null 2>&1 && adb shell chmod 755 "$SOCKS"
  UID_MAP=${OUT:-/tmp}/uid-map.txt
  adb shell pm list packages -U 2>/dev/null | crlf > "$UID_MAP"
  say "   android: lockdown=$ANDROID_LOCKDOWN if=$PHYS_IF addrs=$PHYS_ADDRS gw=$GATEWAY_IP app hosts=$(echo $APP_HOSTS | tr ' ' ',') listed nodes=$(wc -w <<<"$nodes")"
  RUN_START_CHANNELS=$(dcli client sessions --instance "$INSTANCE" | sed -nE 's/.*"channel": *"([^"]+)".*/\1/p' | sort -u | tr '\n' ' ')
  # After the dvpnd restart above (s1c 11-08: checked before it, the call failed and every sample fell back to the hop).
  local try; for try in 1 2 3; do phone_status_up && break; sleep 3; done
  [ "${PHONE_STATUS:-0}" = 1 ] && say "   status: call_ms timed on the phone" \
    || say "   status: the phone-side timed call is not available; call_ms falls back to the adb hop"
  deadman_start
}

plat_build() { echo "apk $(adb shell dumpsys package "$PKG" | crlf | grep -m1 versionName | tr -d ' ') dvpnd $(python3 "$HOOK" dvpnd version 2>&1 | head -1 | cut -c1-140)"; }
# S2 protocol kill: the protocol program's pid on the phone, killed there (plat_kill_pid).
plat_protocol_pid() { su0 pidof "$1" 2>/dev/null | crlf; }
plat_kill_pid() { su0 kill "-$1" "$2"; }
plat_protocols() { echo "${CBM_PROTOCOLS:-wireguard amneziawg openvpn hysteria2 v2ray xray}"; }

# ─── Daemon ───
plat_daemon_running() { [ -n "$(dpid)" ]; }
daemon_ready() { dcli client sessions --instance "$INSTANCE" | grep -q '"sessions"'; }
plat_daemon_start() {
  local i
  if ! plat_daemon_running; then
    # No dvpnd at all = the VPN service is not up: open the app, which starts it.
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  fi
  for i in $(seq 1 60); do
    plat_daemon_running && { sock_up; daemon_ready && return 0; }
    sleep 1
  done
  return 1
}
# Kill dvpnd and wait for that pid to go; the app's supervisor starts a new one after its backoff.
plat_daemon_stop() {
  local sig=${1:-TERM} p i
  p=$(dpid); [ -n "$p" ] || return 0
  su0 kill "-$sig" "$p"
  for i in $(seq 1 20); do adb shell "[ -d /proc/$p ]" || return 0; sleep 0.5; done
  return 1
}
plat_restart_daemon() { plat_daemon_stop TERM; sleep 2; plat_daemon_start; }

# ─── Sessions ───
# The protocol IS the node entry (lib/nodes.sh sets NODE_ID per protocol). The app reuses its open channel for the
# entry (Q0411) and opens one when there is none; a live session elsewhere is switched (--switch).
plat_connect() {
  local proto=$1 out sw='' before
  tx_gap
  before=$(plat_live_sessions | tr '\n' ' ')
  # A switch always says so: during a connect in flight there is no session row yet, and the CLI
  # refuses a plain connect then ("Disconnect the current session first.").
  { [ -n "$before" ] || [ -n "${CBM_SWITCH:-}" ]; } && sw=--switch
  out=$(app connect "$NODE_ID" --basis "$BASIS" --units 1 $sw --yes)
  echo "$out" | tail -3
  # Wait for a NEW session (a switch keeps the old one live for a moment).
  local i s; SID=''
  for i in $(seq 1 40); do
    for s in $(plat_live_sessions); do case " $before " in *" $s "*) ;; *) SID=$s; break ;; esac; done
    [ -n "$SID" ] && [ "$(sess_field "$SID" status)" = active ] && break
    sleep 1
  done
  [ -n "$SID" ] || return 1
  CHANNEL=$(sess_field "$SID" channel)
  case " ${RUN_START_CHANNELS:-} ${RUN_NEW_CHANNELS:-} " in
    *" $CHANNEL "*) ;;
    *) [ -n "$CHANNEL" ] && { RUN_NEW_CHANNELS="${RUN_NEW_CHANNELS:-} $CHANNEL"; RUN_CHANNEL_PROTO="${RUN_CHANNEL_PROTO:-} $CHANNEL=$proto"; say "   opened channel $CHANNEL for $proto entry $NODE_ID"; } ;;
  esac
  [ "$(sess_field "$SID" status)" = active ]
}
# S4: the app's switch is a connect while a session is live (plat_connect adds --switch).
plat_switch() { CBM_SWITCH=1 plat_connect "$1" && { local i; for i in $(seq 1 15); do [ "$(plat_live_sessions | grep -c .)" = 1 ] && return 0; sleep 1; done; return 0; }; }
plat_live_node() {
  local id; id=$(plat_live_sessions | head -1); [ -n "$id" ] || return 0
  dcli client sessions --instance "$INSTANCE" | python3 -c '
import json, sys
for x in json.load(sys.stdin).get("sessions", []):
    if x.get("id") == sys.argv[1]: print(x.get("node", ""))
' "$id"
}
plat_disconnect() {
  [ -n "$(plat_live_sessions)" ] || return 0
  tx_gap
  app disconnect >/dev/null
  local i; for i in $(seq 1 20); do [ -z "$(plat_live_sessions)" ] && return 0; sleep 1; done
  return 1
}
# sessions JSON → "id status channel" per session, newest first
sess_rows() { dcli client sessions --instance "$INSTANCE" | sess_parse; }
# ─── Phone-side timed status call (FLX2 1b9a6d2 pattern: time the daemon call alone) ───
# The rig CLI is a static x86_64 Linux binary, so it runs on the emulator as is. PHONE_SESS runs ONE `client sessions`
# against dvpnd's socket on the phone, timed there in ns, and prints "call_ms=<n>" then the JSON: the adb trip that
# carries the answer back (which reads 1-4 s while S1's capture + download load the emulator) is not charged.
PHONE_CLI=/data/local/tmp/cbm-cli
PHONE_SESS=/data/local/tmp/cbm-sess.sh
phone_status_up() {
  [ "${CBM_PHONE_STATUS:-1}" = 1 ] || return 1
  adb shell "[ -x $PHONE_CLI ]" || { adb push "$CBM_CLI" "$PHONE_CLI" >/dev/null && adb shell chmod 755 "$PHONE_CLI"; } || return 1
  printf '%s\n' '#!/system/bin/sh' \
    "t0=\$(date +%s%N); HOME=/data/local/tmp timeout 5 $PHONE_CLI --home /data/local/tmp/cbm-home --daemon.endpoint $IHOME/daemon.sock client sessions --instance $INSTANCE > /data/local/tmp/cbm-sess.json 2>/dev/null; rc=\$?; t1=\$(date +%s%N)" \
    'echo "call_ms=$(( (t1 - t0) / 1000000 )) rc=$rc"; cat /data/local/tmp/cbm-sess.json' > "${TMPDIR:-/tmp}/cbm-sess.sh"
  adb push "${TMPDIR:-/tmp}/cbm-sess.sh" "$PHONE_SESS" >/dev/null && adb shell chmod 755 "$PHONE_SESS" || return 1
  su0 "$PHONE_SESS" 2>/dev/null | crlf | head -1 | grep -q '^call_ms=[0-9]* rc=0$' || return 1
  PHONE_STATUS=1
}
sess_parse() {
  python3 -c '
import json, sys
try:
    s = json.load(sys.stdin).get("sessions", [])
except ValueError as e:
    print("sess_rows: bad json: %s" % e, file=sys.stderr); sys.exit(1)
s.sort(key=lambda x: (x.get("started_at") or {}).get("seconds", 0), reverse=True)
out = "".join("%s %s %s %s\n" % (x.get("id", ""), x.get("status", ""), x.get("channel", "") or "-", (x.get("error") or x.get("warning") or "").replace("\n", " ")) for x in s)
try:
    sys.stdout.write(out); sys.stdout.flush()
except BrokenPipeError:  # a reader that stops early (awk exit, head) is fine
    sys.stdout = None
'
}
plat_sessions() { sess_rows | awk '{print $1}'; }
plat_live_sessions() { sess_rows | awk '$2 != "ended" {print $1}'; }
sess_field() { sess_rows | awk -v id="$1" -v f="$2" '$1 == id { if (f == "status") print $2; else if (f == "channel") print $3; exit }'; }

plat_status_line() {
  local ks row st text
  ks=$(cat "$OUT/.android-ks" 2>/dev/null)   # written by plat_set_ks from config.toml (one adb trip less per sample)
  # call_ms = the one `client sessions` call alone (rig CLI → adb forward → phone relay → dvpnd), like Windows'
  # call_ms: the poller's wall time also counts the bash/awk work and waits behind S1's own adb jobs (capture,
  # egress poll, download) on the one emulator, which read 1-4 s while dvpnd answered in < 0.5 s (status-ab, 11-08).
  local rows t0 call out
  if [ "${PHONE_STATUS:-0}" = 1 ] && out=$(su0 "$PHONE_SESS" 2>/dev/null | crlf) && [[ $(head -1 <<<"$out") =~ ^call_ms=([0-9]+)\ rc=0$ ]]; then
    call=${BASH_REMATCH[1]}; rows=$(tail -n +2 <<<"$out" | sess_parse)
  else
    t0=$(date +%s%3N); rows=$(sess_rows); call=$(( $(date +%s%3N) - t0 ))
  fi
  row=$(awk '$2 ~ /^(active|reconnecting|connecting|checking)$/ {print; exit}' <<<"$rows")
  [ -z "$row" ] && row=$(head -1 <<<"$rows")
  st=$(awk '{print $2}' <<<"$row"); text=$(cut -d' ' -f4- <<<"$row")
  [ "$st" = ended ] && st=none
  echo "state=${st:-none} ks=${ks:-off} id=$(awk '{print $1}' <<<"$row" | grep . || echo -) call_ms=$call text=$text"
}

# ─── Probes (shell uid, inside the VPN) ───
plat_egress() {
  local e; e=$(timeout 6 adb shell "$PROBE ip ${CBM_IP_URL:-https://ipv4.icanhazip.com}" 2>/dev/null | crlf | head -1)
  [[ $e =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$e" || echo none
}
plat_egress6() {
  local e; e=$(timeout 6 adb shell "$PROBE ip6 ${CBM_IP6_URL:-https://ipv6.icanhazip.com}" 2>/dev/null | crlf | head -1)
  [[ $e == *:* ]] && echo "$e" || echo none
}
# ddvprobe has no "which resolver answered" query; report the answer for a name only the tests use.
plat_dns_probe() { timeout 6 adb shell "$PROBE dns speed.cloudflare.com" 2>/dev/null | crlf | head -1; }
# The suites download with `curl` (S1 50 MB + slow reader, S2 protocol kill). On Android that traffic must come
# from the phone, so curl to a test URL runs `ddvprobe get` there; any other curl (node metadata) stays on the rig.
# ddvprobe has no rate limit, so --limit-rate (S1's slow reader) is a plain download here: noted in the results.
curl() {
  local a url='' w='' m=120
  for a in "$@"; do case $a in https://speed.cloudflare.com/*|"${CBM_BIG_URL:-@@}"|"${CBM_SLOW_URL:-@@}") url=$a ;; esac; done
  [ -n "$url" ] || { command curl "$@"; return; }
  while [ $# -gt 0 ]; do case $1 in -w) w=$2; shift ;; -m) m=$2; shift ;; esac; shift; done
  # CBM_BIG_PIN (sha256//<b64>): the fleet's self-signed speed origin, verified by key (ddvprobe DDVPROBE_PIN).
  local r; r=$(timeout "$m" adb shell "${CBM_BIG_PIN:+DDVPROBE_PIN=$CBM_BIG_PIN }$PROBE get '$url'" 2>/dev/null | crlf | head -1)
  [[ $r =~ ^[0-9]+\ [0-9.]+ ]] || { echo "phone download failed: $r" >&2; return 28; }
  [ -n "$w" ] && echo "${r% *}"
  return 0
}

# ─── Kill switch ───
plat_set_ks() {
  case $1 in
    on) asapp sed -i -E "s/^kill_switch = '[a-z]+'/kill_switch = 'on'/" "$CFG_REL" ;;
    *) # `daemon set` restarts dvpnd: wait for the new one to answer, or the next connect lands mid-restart
      # ("The VPN service is not running", final6 S3 cut90_ks hysteria2 18:07Z).
      local old i; old=$(dpid)
      python3 "$HOOK" --env DVPN_KEYFILE="$APP_FILES/test/owner.json" cli daemon set --kill-switch "$1" --yes >/dev/null 2>&1
      for i in $(seq 1 30); do [ -n "$(dpid)" ] && [ "$(dpid)" != "$old" ] && break; sleep 0.5; done
      plat_daemon_start || say "dvpnd did not come back after daemon set --kill-switch $1" ;;
  esac
  asapp grep -oE "^kill_switch = '[a-z]+'" "$CFG_REL" 2>/dev/null | grep -oE "'[a-z]+'" | tr -d "'" > "$OUT/.android-ks"
}

# ─── Capture on the phone's NIC ───
plat_capture_start() {
  LEAK_RPC_HOSTS=$LEAK_RPC_HOSTS_FIXED
  CAP_FILE=/data/local/tmp/cbm-$(date +%s%N).pcap
  su0 "sh -c 'setsid nohup $CAP $PHYS_IF $CAP_FILE </dev/null >$CAP_FILE.log 2>&1 &'"
  # Who owns each direct socket (tools/cbm-socks.sh): the pcap has no uid; this says app vs Play services vs …
  local pat a; pat=''
  for a in $PHYS_ADDRS; do IFS=. read -r o1 o2 o3 o4 <<<"$a"; pat="${pat:+$pat|}$(printf '%02X%02X%02X%02X' "$o4" "$o3" "$o2" "$o1")"; done
  [ -n "$pat" ] && su0 "sh -c 'setsid nohup sh $SOCKS $CAP_FILE.socks \"$pat\" </dev/null >/dev/null 2>&1 &'"
  sleep 1
}
plat_capture_stop() {
  [ -n "${CAP_FILE:-}" ] || return 0
  timeout 10 adb shell "su 0 pkill -INT -f '$CAP $PHYS_IF $CAP_FILE'"
  timeout 10 adb shell "su 0 pkill -f '$SOCKS $CAP_FILE.socks'"
  sleep 2; su0 chmod 644 "$CAP_FILE" "$CAP_FILE.socks"
  adb pull "$CAP_FILE" "$LEAK_PCAP.raw" >/dev/null 2>&1
  adb pull "$CAP_FILE.socks" "$SCEN_DIR/sockets.raw" >/dev/null 2>&1 &&
    python3 -I "$HERE_ANDROID/../tools/cbm-socks-decode.py" "$SCEN_DIR/sockets.raw" "$UID_MAP" "$SCEN_DIR/active-windows.txt" > "$SCEN_DIR/sockets.txt" 2>&1
  su0 rm -f "$CAP_FILE" "$CAP_FILE.log" "$CAP_FILE.socks"
  # DNS questions for the app's own hosts are the app uid's (outside the VPN by design), not a leak.
  # The capture is stamped by the phone's clock (the emulator ran 1.4 s behind the rig, 11-08); shift it onto the
  # rig's, which the active windows use.
  local shift; shift=$(plat_clock_offset)
  echo "$shift" > "$LEAK_PCAP.shift"
  python3 -I "$HERE_ANDROID/../tools/pcap-dns-drop.py" "$LEAK_PCAP.raw" "$LEAK_PCAP" --drop-link-mcast --drop-arp "--shift=$shift" $APP_HOSTS > "$LEAK_PCAP.filter.txt" \
    || cp "$LEAK_PCAP.raw" "$LEAK_PCAP"
  CAP_FILE=''
  return 0
}
plat_plant_leak() { adb shell "$PROBE tcp 1.1.1.1:443" >/dev/null 2>&1; }
# rig clock - phone clock in seconds (median of 3, each corrected for half the adb round trip)
plat_clock_offset() {
  local i h0 p h1
  for i in 1 2 3; do
    h0=$(date +%s.%N); p=$(adb shell date +%s.%N | crlf); h1=$(date +%s.%N)
    echo "($h0 + $h1) / 2 - $p" | bc -l
  done | sort -n | sed -n 2p | xargs printf '%.3f\n'
}

# ─── Leftovers ───
plat_leftovers() {
  # A tunnel link with no session (the VPN still up after reset).
  adb shell ip -br link 2>/dev/null | crlf | awk '$1 ~ /^(tun[0-9]|dvpn|wg)/ {print "link: " $1}'
  adb shell dumpsys connectivity 2>/dev/null | crlf | grep -E '^ *NetworkAgentInfo' | grep -F 'ni{VPN' | head -2 | sed 's/^ */vpn network: /' | cut -c1-160
  su0 ps -A -o NAME 2>/dev/null | crlf | grep -E '^(xray|v2ray|hysteria|hysteria2|openvpn)$' | sed 's/^/process: /'
  asapp find "files/sentinel-dvpn/$INSTANCE" -maxdepth 3 -type f \( -name '*.key' -o -name '*auth.txt' -o -name '*.conf' -o -name '*.yaml' \) 2>/dev/null | crlf | sed 's/^/file: /'
  sudo iptables -S OUTPUT 2>/dev/null | grep -F 'cbm-cut' | sed 's/^/rig cut: /'
}
plat_plant_leftover() { asapp sh -c "echo x > files/sentinel-dvpn/$INSTANCE/cbm-planted.key"; }
plat_unplant_leftover() { asapp rm -f "files/sentinel-dvpn/$INSTANCE/cbm-planted.key"; return 0; }

# ─── Faults (rig host) ───
plat_cut() {
  sudo iptables -I OUTPUT -d "$NODE_IP" -m comment --comment cbm-cut -j DROP || return 1
  sudo iptables -I INPUT -s "$NODE_IP" -m comment --comment cbm-cut -j DROP
  [ -n "${1:-}" ] && { sleep "$1"; plat_uncut; }
  return 0
}
plat_uncut() {
  local r
  while r=$(sudo iptables -S OUTPUT 2>/dev/null | grep -F 'cbm-cut' | head -1) && [ -n "$r" ]; do
    sudo iptables ${r/-A /-D } || break
  done
  while r=$(sudo iptables -S INPUT 2>/dev/null | grep -F 'cbm-cut' | head -1) && [ -n "$r" ]; do
    sudo iptables ${r/-A /-D } || break
  done
  return 0
}
plat_airplane() { adb shell cmd connectivity airplane-mode "${1:-enable}" >/dev/null; }

# ─── Messages ───
plat_cli_outputs() {
  cat "$SCEN_DIR/cli.txt" 2>/dev/null
  asapp tail -200 files/logs/dvpnd.log 2>/dev/null | grep -oE '"(error|message|reason)":"[^"]*"' | tail -50
}

# ─── Money ───
# Sessions on $CHANNEL: spent from the daemon; the chain account from `channel show` (escrow, redeemed).
chain_channel_field() { # $1 field, $2 channel
  plat_chain_cli channel show "${2:-$CHANNEL}" 2>/dev/null | grep -oE "\"$1\": *[0-9]+" | head -1 | grep -oE '[0-9]+$'
}
spent_on() { # $1 channel → "spent sessions"
  dcli client sessions --instance "$INSTANCE" | python3 -c '
import json, sys
ch = sys.argv[1]
s = [x for x in json.load(sys.stdin).get("sessions", []) if x.get("channel") == ch]
print(sum(int(x.get("spent", 0) or 0) for x in s), len(s))
' "$1"
}
prepay_window_units() {
  local pb ps basis
  basis=$(asapp sed -nE "s/^basis = '([a-z_]+)'/\1/p" "$CFG_REL" | head -1)
  pb=$(asapp sed -nE 's/^prepay_bytes = ([0-9]+)/\1/p' "$CFG_REL" | head -1); ps=$(asapp sed -nE 's/^prepay_seconds = ([0-9]+)/\1/p' "$CFG_REL" | head -1)
  local uri meta mpb mps ppg pph
  uri=$(plat_chain_cli node show "$NODE_ID" 2>/dev/null | grep -oE '"uri": *"https://[^"]+"' | head -1 | grep -oE 'https://[^"]+')
  [ -n "$uri" ] && meta=$(curl -sk -m 8 "$uri/v1/metadata")
  mpb=$(grep -oE '"min_channel_prepay_bytes":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); mps=$(grep -oE '"min_channel_prepay_seconds":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  ppg=$(grep -oE '"channel_price_per_gb":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); pph=$(grep -oE '"channel_price_per_hour":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  awk -v b="${basis:-per_gb}" -v pb="${pb:-0}" -v ps="${ps:-0}" -v mpb="${mpb:-0}" -v mps="${mps:-0}" -v ppg="${ppg:-0}" -v pph="${pph:-0}" 'BEGIN {
    if (b == "per_hour") { s = (ps > mps ? ps : mps); v = s * pph / 3600 } else { y = (pb > mpb ? pb : mpb); v = y * ppg / 1e9 }
    printf "%d\n", (v == int(v) ? v : int(v) + 1) }'
}
plat_money() {
  [ -n "${CHANNEL:-}" ] || { echo "spent=0 paid=unknown node_settled=unknown redeemed=unknown"; return; }
  local sp n redeemed escrow
  read -r sp n <<<"$(spent_on "$CHANNEL")"
  redeemed=$(chain_channel_field redeemed); escrow=$(chain_channel_field escrow)
  echo "spent=${sp:-0} paid=unknown node_settled=unknown redeemed=${redeemed:-unknown} escrow=${escrow:-unknown} prepay_allow=$(( ${n:-0} * $(prepay_window_units) ))"
}
# Run end: close only the channels this run opened, through the app (`settle run --channel`), 7 s apart.
plat_close_run_channels() {
  local ch
  for ch in ${RUN_NEW_CHANNELS:-}; do
    tx_gap
    say "   closing channel $ch (opened by this run) with the app's settle run"
    app settle run --channel "$ch" --yes | tail -2
  done
}
plat_money_run() {
  local ch spent=0 settled=0 n=0 s c r
  [ -n "${RUN_NEW_CHANNELS:-}" ] || { echo "spent=0 paid=unknown node_settled=unknown prepay_allow=0"; return; }
  for ch in $RUN_NEW_CHANNELS; do
    read -r s c <<<"$(spent_on "$ch")"
    r=$(chain_channel_field redeemed "$ch"); [ -n "$r" ] || { echo "spent=$spent paid=unknown node_settled=unknown prepay_allow=0"; return; }
    spent=$((spent + s)); settled=$((settled + r)); n=$((n + c))
  done
  echo "spent=$spent paid=unknown node_settled=$settled channels=$(wc -w <<<"$RUN_NEW_CHANNELS") sessions=$n prepay_allow=$(( n * $(prepay_window_units) ))"
}
plat_money_run_channels() { # one line per channel, graded per channel by checks/money.sh
  local ch s c r w p
  w=$(prepay_window_units)
  for ch in ${RUN_NEW_CHANNELS:-}; do
    read -r s c <<<"$(spent_on "$ch")"
    r=$(chain_channel_field redeemed "$ch"); p=$(tr ' ' '\n' <<<"${RUN_CHANNEL_PROTO:-}" | sed -n "s/^$ch=//p" | head -1)
    echo "channel=$ch proto=${p:-unknown} spent=${s:-0} redeemed=${r:-unknown} sessions=${c:-0} step=${w:-0}"
  done
}

# ─── Program delegate (lib/common.sh preflight_delegate; mirrors plat/linux.sh) ───
# The app's wallet is the rig CLI key CBM_KEY_NAME (the same key file the app holds, e.g. fanb2 on b2).
_and_cfg_val() { # $1 = sed program on the app's config.toml; strips TOML quotes
  asapp cat "$CFG_REL" 2>/dev/null | crlf | sed -nE "$1" | head -1 | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//"
}
plat_delegate_approve() { # $1 = base units or "unlimited" (default unlimited)
  tx_gap
  plat_chain_cli wallet approve-delegate --amount-base-units "${1:-unlimited}" --key.name "${CBM_KEY_NAME:-owner}" 2>&1 | redact
}
plat_delegate_read() { # echo the wallet's program-delegate allowance in base units; empty + rc 1 on failure
  local rpc owner mint have
  rpc=${CBM_RPC_URL:-${HELIUS_RPC_URL:-$(_and_cfg_val '/^\[rpc\]/,/^\[/{ s/^[[:space:]]*url[[:space:]]*=[[:space:]]*(.+)$/\1/p }')}}
  owner=${CBM_OWNER:-$(_and_cfg_val '1,/^\[/{ s/^[[:space:]]*owner[[:space:]]*=[[:space:]]*(.+)$/\1/p }')}
  mint=${CBM_MINT:?set CBM_MINT}
  [ -n "$rpc" ] && [ -n "$owner" ] || return 1
  have=$(curl -s -m 15 "$rpc" -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$owner\",{\"mint\":\"$mint\"},{\"encoding\":\"jsonParsed\"}]}" 2>/dev/null \
    | jq -r 'if (.result.value|type) != "array" then "" else (.result.value[0].account.data.parsed.info) as $i | if ($i|not) or ($i.delegate==null) then "0" else ($i.delegatedAmount.amount // "0") end end' 2>/dev/null)
  case "$have" in ''|null) return 1 ;; *) echo "$have" ;; esac
}

# ─── Reset ───
plat_reset() {
  plat_uncut
  adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1
  plat_daemon_running || plat_daemon_start
  plat_disconnect >/dev/null 2>&1
  app daemon restore-network >/dev/null 2>&1
  plat_set_ks off
  return 0
}
