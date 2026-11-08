#!/usr/bin/env bash
# ─── Windows adapter (FWA, 11-07; TWA owns the S12 uifire part) ───
# The driver runs on ctl-1 (bash); every function reaches the Windows VM over ssh and runs PowerShell there.
# Setup, done once per VM (plat_init checks each point and fails loudly):
#   - the build under test in $WIN_DIR (default C:\cb33): sentinel-dvpnd.exe + sentinel-dvpn.exe, instance c1
#     initialised and installed as the service "sentinel-dvpnd$c1" (cb33 tag.ServiceName("windows")).
#   - ctl-1 reaches the VM on its INTERNAL GCP address (10.x), and the instance config has allow_lan = true: the kill
#     switch then still admits the control ssh, as LAN. Over a public address, a KS-on scenario would cut the driver off.
#   - OpenSSH server on the VM; the ssh user is an administrator (WFP, services, pktmon).
# Env: WIN_HOST (internal IP, required), WIN_USER (default ddv), WIN_KEY (default ~/.ssh/ddv_gcp), WIN_DIR, INSTANCE.
# Not yet run live: every function is written against cb33 b036236 and #31's Windows scripts. The first live run is
# --selftest on ddv-win11-host-2 (WAIT-WIN-X64), and any fix goes here.

WIN_HOST=${WIN_HOST:-}
WIN_USER=${WIN_USER:-ddv}
WIN_KEY=${WIN_KEY:-$HOME/.ssh/ddv_gcp}
WIN_DIR=${WIN_DIR:-'C:\cb33'}
INSTANCE=${INSTANCE:-c0}   # FLX/DIR OS table: the client instance; override per run
WIN_SVC="sentinel-dvpnd\$$INSTANCE"
WIN_STATE="C:\\ProgramData\\sentinel-dvpn\\$INSTANCE"   # instance.Tag.StateDir("windows") = %ProgramData%\sentinel-dvpn\<tag> (ProductName)
# One shared ssh connection (ControlMaster): plat_status_line must answer in < 1 s.
WSSH="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ControlMaster=auto -o ControlPath=/tmp/cbm-win-%C -o ControlPersist=10m -i $WIN_KEY"
# For suites that run their own VM scripts (TWA S12): the full ssh command.
WIN_SSH="ssh $WSSH $WIN_USER@$WIN_HOST"

# wps <powershell code>: runs it on the VM, as one base64 UTF-16LE -EncodedCommand (no quoting through ssh/cmd).
wps() {
  local enc; enc=$(printf '%s' "$ProgressPreference_off$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  ssh $WSSH "$WIN_USER@$WIN_HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" 2>&1 | tr -d '\r'
}
ProgressPreference_off="\$ProgressPreference='SilentlyContinue'; \$ErrorActionPreference='Continue'; "

# cli <args>: the cb33 client CLI on the VM, output also kept for the plain-words check.
cli() {
  local a q=""
  for a in "$@"; do q="$q '${a//\'/\'\'}'"; done
  wps "Set-Location '$WIN_DIR'; & .\\sentinel-dvpn.exe --home '$WIN_DIR\\cli'$q --instance '$INSTANCE' 2>&1 | ForEach-Object { \"\$_\" }" | tee -a "$SCEN_DIR/cli.txt"
}

plat_init() {
  [ -n "$WIN_HOST" ] || { say "windows: set WIN_HOST (the VM's internal 10.x address)"; return 1; }
  # A public WIN_HOST is refused by default (a live KS-on scenario would cut the driver's own ssh). CBM_ALLOW_PUBLIC=1
  # permits it; plat_set_ks then refuses on/strict only for LIVE-path scenarios. A recorder-backed ks-on scenario
  # (CBM_KS_RECORDED=1) is safe on a public host — its actions run on the VM, not over ssh — so those are allowed.
  case $WIN_HOST in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) ;;
    *) [ "${CBM_ALLOW_PUBLIC:-}" = 1 ] || { say "windows: WIN_HOST $WIN_HOST is not a LAN address; a live KS-on scenario would cut the driver off (set CBM_ALLOW_PUBLIC=1 to allow public, recorder-backed ks-on included)"; return 1; }
       say "windows: CBM_ALLOW_PUBLIC=1 — public WIN_HOST $WIN_HOST allowed; live ks-on scenarios refused, recorder-backed ks-on allowed" ;;
  esac
  case $NODE in
    node-3) NODE_ID=${NODE3_ID:?set NODE3_ID (node-3 address)}; NODE_IP=${NODE3_IP:?set NODE3_IP} ;;
    node-4) NODE_ID=${NODE4_ID:?set NODE4_ID (node-4 pubkey)}; NODE_IP=${NODE4_IP:?set NODE4_IP} ;;
    *) NODE_ID=$NODE; NODE_IP=${NODE_IP:?set NODE_IP for a custom node} ;;
  esac
  NODE_EGRESS=${NODE_EGRESS:-$NODE_IP}
  local info
  info=$(wps "
    \$r = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1
    \"PHYS_IF=\$((Get-NetAdapter -InterfaceIndex \$r.ifIndex).Name)\"
    \"GATEWAY_IP=\$(\$r.NextHop)\"
    \"PHYS_ADDRS=\$((Get-NetIPAddress -InterfaceIndex \$r.ifIndex -ErrorAction SilentlyContinue | Where-Object { \$_.IPAddress -notlike 'fe80*' } | ForEach-Object { \$_.IPAddress }) -join ' ')\"
    \"CONTROL_IP=\$((\$env:SSH_CLIENT -split ' ')[0])\"
    \"DIRECT_IP=\$(try { (Invoke-RestMethod -Uri https://api.ipify.org -TimeoutSec 8) } catch { '' })\"
    \"BIN=\$([int](Test-Path '$WIN_DIR\\sentinel-dvpnd.exe') + [int](Test-Path '$WIN_DIR\\sentinel-dvpn.exe'))\"
    \"SVC=\$((Get-Service -Name '$WIN_SVC' -ErrorAction SilentlyContinue).Status)\"
    \"CFG=\$((Get-ChildItem '$WIN_STATE' -Recurse -Filter config.toml -ErrorAction SilentlyContinue | Where-Object { Select-String -LiteralPath \$_.FullName -Pattern '^\\s*kill_switch' -Quiet } | Select-Object -First 1).FullName)\"
    \"ADMIN=\$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))\"
  ")
  echo "$info" > "$OUT/windows-init.txt"
  PHYS_IF=$(sed -n 's/^PHYS_IF=//p' <<<"$info"); GATEWAY_IP=$(sed -n 's/^GATEWAY_IP=//p' <<<"$info")
  CONTROL_IP=$(sed -n 's/^CONTROL_IP=//p' <<<"$info"); DIRECT_IP=$(sed -n 's/^DIRECT_IP=//p' <<<"$info")
  WIN_CFG=$(sed -n 's/^CFG=//p' <<<"$info")
  # The NIC's own addresses: leak.sh keeps the sent side of the outbound check and judges the inbound side.
  PHYS_ADDRS=$(sed -n 's/^PHYS_ADDRS=//p' <<<"$info" | tr -d '\r')
  [ "$(sed -n 's/^ADMIN=//p' <<<"$info")" = True ] || { say "windows: the ssh user is not an administrator"; return 1; }
  [ "$(sed -n 's/^BIN=//p' <<<"$info")" = 2 ] || { say "windows: no sentinel-dvpnd.exe + sentinel-dvpn.exe in $WIN_DIR"; return 1; }
  [ -n "$(sed -n 's/^SVC=//p' <<<"$info")" ] || { say "windows: service $WIN_SVC is not installed"; return 1; }
  [ -n "$WIN_CFG" ] || { say "windows: no config.toml with kill_switch under $WIN_STATE"; return 1; }
  [ -n "$DIRECT_IP" ] || { say "windows: no direct egress"; return 1; }
  # allow_lan keeps the control ssh alive under a KS-on switch on a LAN host. Skipped with CBM_ALLOW_PUBLIC=1: there
  # only recorder-backed ks-on scenarios run (plat_set_ks refuses live ks-on), and their actions never use the ssh
  # control channel, so allow_lan is irrelevant to them and the channel is never put at risk.
  if [ "${CBM_ALLOW_PUBLIC:-}" != 1 ]; then
    wps "Select-String -LiteralPath '$WIN_CFG' -Pattern '^\\s*allow_lan\\s*=\\s*true' -Quiet" | grep -q True ||
      { say "windows: allow_lan is not true in $WIN_CFG: the control ssh would be cut by the kill switch"; return 1; }
  fi
  WIN_SSH="ssh $WSSH $WIN_USER@$WIN_HOST"; export WIN_SSH
  # Prime the ControlMaster so the first plat_status_line isn't a cold-connect >1s (TWA: first status 1210 ms -> false slow).
  wps "1" >/dev/null 2>&1 || true
  deadman_start
}

plat_build() { wps "& '$WIN_DIR\\sentinel-dvpnd.exe' version 2>&1 | Select-Object -First 1" | cut -c1-120; }
plat_protocols() { echo "${CBM_PROTOCOLS:-wireguard amneziawg openvpn hysteria2 v2ray xray}"; }

plat_daemon_running() { wps "(Get-Service -Name '$WIN_SVC').Status" | grep -qx Running; }
plat_daemon_start() {
  plat_daemon_running && return 0
  wps "Start-Service -Name '$WIN_SVC'; (Get-Service -Name '$WIN_SVC').WaitForStatus('Running', [TimeSpan]::FromSeconds(30))" >/dev/null
  # Running is reported before the gRPC server answers: wait for the CLI to get an answer.
  local i; for i in $(seq 1 30); do
    wps "& '$WIN_DIR\\sentinel-dvpn.exe' --home '$WIN_DIR\\cli' client sessions --instance '$INSTANCE' *> \$null; \$LASTEXITCODE" | grep -qx 0 && return 0
    sleep 1
  done
  return 1
}

# S9 resource samples (DIR 11-08): working set in KiB (to match linux/android VmRSS) and the open handle count of
# the dvpnd service process, via Get-Process on the service's PID. Empty when the service has no PID, so S9 records
# '-' (not sampled) rather than a bogus 0.
# The service name contains a literal '$' (sentinel-dvpnd$c0), so it must go through a single-quoted PS string:
# in a double-quoted "Name='...$c0'" PowerShell would expand $c0 and never match the service.
plat_daemon_mem() {
  wps "\$s = '$WIN_SVC'; \$p = (Get-CimInstance Win32_Service -Filter \"Name='\$s'\").ProcessId; if (\$p) { [math]::Round((Get-Process -Id \$p -ErrorAction SilentlyContinue).WorkingSet64 / 1KB) }" | tail -1
}
plat_daemon_handles() {
  wps "\$s = '$WIN_SVC'; \$p = (Get-CimInstance Win32_Service -Filter \"Name='\$s'\").ProcessId; if (\$p) { (Get-Process -Id \$p -ErrorAction SilentlyContinue).HandleCount }" | tail -1
}

# S4 switching hooks (FLX contract 0cb8dc9) — mirror plat/linux.sh. cb33 has no in-place switch (StartSession
# refuses "a session is already active"), so a switch = stop every live session, wait ≤15 s for none live, then
# connect the new entry. These drive the CLI over ssh, so they serve the ks=off S4 cells (every_pair,
# switch_while_connecting, fast_switch_x10). s4_switch_ks_on on Windows can't use this live path — turning the kill
# switch on cuts the ssh control channel — so it needs a recorder body (flagged to DIR/FLX; not built here).
# Also plat_disconnect's list: stopping an ended session answers NotFound "no active session", which the words check
# counted against the cell, one raw error per earlier session (TWA S1 11-08: wg 0, awg 1, openvpn 2).
plat_live_sessions() {
  SCEN_DIR=${SCEN_DIR:-/tmp} cli client sessions 2>/dev/null | tr -d '\r' |
    awk '/"id":/ {gsub(/[",]/, "", $2); id = $2} /"status":/ {gsub(/[",]/, "", $2); if ($2 != "ended" && id != "") print id; id = ""}'
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
  SCEN_DIR=${SCEN_DIR:-/tmp} cli client status "$id" 2>/dev/null | grep -oE '"node": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}
# plat_daemon_stop TERM = a clean service stop; KILL = the process killed with no stop (SCM's restart actions may then
# start it again after their delay, as on a real crash; the scenario reads plat_daemon_running for that).
plat_daemon_stop() {
  if [ "${1:-TERM}" = KILL ]; then
    wps "\$p = (Get-CimInstance Win32_Service -Filter \"Name='$WIN_SVC'\").ProcessId; if (\$p) { Stop-Process -Id \$p -Force }" >/dev/null
    sleep 2; return 0
  fi
  wps "Stop-Service -Name '$WIN_SVC' -Force; (Get-Service -Name '$WIN_SVC').WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))" >/dev/null
  plat_daemon_running && return 1 || return 0
}

# `client start` has NO --protocol in cb33: the protocol IS the node entry ($NODE_ID per protocol, from lib/nodes.sh).
# A channel is per node entry (CHANNELS[$NODE_ID]), not per run; the driver pins the first entry's channel via
# CHANNEL_PIN. CHANNEL is rewritten after every connect (money reads it), so it is not reused as the next entry's pin.
# (TLX, tlx-u22 11-07: "unknown flag: --protocol" failed every connect.) Same logic as plat/linux.sh.
declare -gA CHANNELS 2>/dev/null || true
plat_connect() {
  local proto=$1 out ch
  tx_gap
  [ -z "${CBM_CONNECTED:-}" ] && { CHANNEL_PIN=${CHANNEL:-}; CBM_CONNECTED=1; }
  ch=${CHANNELS[$NODE_ID]:-}
  [ -z "$ch" ] && [ -n "${CHANNEL_PIN:-}" ] && [ -z "${CHANNEL_ENTRY:-}" ] && { ch=$CHANNEL_PIN; CHANNEL_ENTRY=$NODE_ID; }
  if [ -n "$ch" ]; then
    out=$(cli client start --node "$NODE_ID" --channel "$ch")
  else
    out=$(cli client start --node "$NODE_ID" --new-channel --mode voucher --escrow-base-units "${ESCROW:-100000}")
    ch=$(grep -oE '"channel(_id)?": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$ch" ] && { CHANNEL_NEW=1; RUN_NEW_CHANNELS="${RUN_NEW_CHANNELS:-} $ch"; say "   opened channel $ch for $proto entry $NODE_ID (reused for this entry)"; }
  fi
  [ -n "$ch" ] && { CHANNELS[$NODE_ID]=$ch; CHANNEL=$ch; }
  SID=$(grep -oE '"(session_)?id": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  [ -z "$SID" ] && SID=$(plat_sessions | head -1)
  [ -n "$SID" ]
}
plat_disconnect() {
  local s rc=0
  for s in $(plat_live_sessions); do tx_gap; cli client stop "$s" >/dev/null || rc=1; done
  return $rc
}
plat_sessions() { SCEN_DIR=${SCEN_DIR:-/tmp} cli client sessions 2>/dev/null | grep -oE '"id": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/'; }

# One ssh round trip for the whole line (status must answer in < 1 s; ssh to a LAN VM is ~0.2 s).
plat_status_line() {
  wps "
    \$ks = (Select-String -LiteralPath '$WIN_CFG' -Pattern \"^\\s*kill_switch\\s*=\\s*['\`\"]([a-z]+)\" | Select-Object -First 1).Matches.Groups[1].Value
    \$cli = '$WIN_DIR\\sentinel-dvpn.exe'
    \$ids = [regex]::Matches((& \$cli --home '$WIN_DIR\\cli' client sessions --instance '$INSTANCE' 2>&1 | Out-String), '\"id\": *\"([^\"]+)\"') | ForEach-Object { \$_.Groups[1].Value }
    \$st = ''; \$out = ''; \$cms = 0
    foreach (\$s in \$ids) {
      \$sw = [Diagnostics.Stopwatch]::StartNew()
      \$out = & \$cli --home '$WIN_DIR\\cli' client status \$s --instance '$INSTANCE' 2>&1 | Out-String
      \$cms = [long]\$sw.ElapsedMilliseconds
      \$st = ([regex]::Match(\$out, '\"status\": *\"([^\"]+)\"')).Groups[1].Value
      if (\$st -in 'active','reconnecting','connecting','checking') { break }
    }
    \$txt = ([regex]::Match(\$out, '\"(error|message)\": *\"[^\"]*\"')).Value
    if (-not \$st) { \$st = 'none' }; if (-not \$ks) { \$ks = 'off' }
    if (-not \$s) { \$s = '-' }
    \"state=\$st ks=\$ks id=\$s call_ms=\$cms text=\$txt\"
  " | tail -1
}

plat_egress() { local e; e=$(wps "try { Invoke-RestMethod -Uri https://api.ipify.org -TimeoutSec 6 } catch { 'none' }" | tail -1); echo "${e:-none}"; }
plat_egress6() { local e; e=$(wps "try { Invoke-RestMethod -Uri https://api6.ipify.org -TimeoutSec 6 } catch { 'none' }" | tail -1); echo "${e:-none}"; }
plat_dns_probe() { wps "(Resolve-DnsName -Name o-o.myaddr.l.google.com -Type TXT -Server ns1.google.com -DnsOnly -ErrorAction SilentlyContinue | Select-Object -First 1).Strings" | head -1; }

plat_set_ks() {
  # With CBM_ALLOW_PUBLIC=1 the WIN_HOST may be public, so a ks-on switch would cut the driver's own ssh — UNLESS this
  # scenario is recorder-backed (CBM_KS_RECORDED=1, set by run_scenario): then the actions run on the VM as a SYSTEM
  # job the KS cut cannot reach, the VM-side recorder deadman restores, and ssh is not the control path. So refuse
  # on/strict under public ONLY for a live-path scenario; a recorder-backed ks-on run is safe and allowed.
  if [ "${CBM_ALLOW_PUBLIC:-}" = 1 ] && [ "$1" != off ] && [ "$1" != none ] && [ "${CBM_KS_RECORDED:-0}" != 1 ]; then
    say "windows: refusing kill_switch='$1' with CBM_ALLOW_PUBLIC=1 on a live-path scenario (public WIN_HOST; a ks-on switch would cut the control ssh). A recorder-backed ks-on scenario (one with a <fn>_ps) is allowed."; return 1
  fi
  wps "\$t = [IO.File]::ReadAllText('$WIN_CFG'); \$n = [regex]::Replace(\$t, \"(?m)^(\\s*kill_switch\\s*=\\s*)['\`\"][a-z]+['\`\"]\", \"\`\${1}'$1'\"); [IO.File]::WriteAllText('$WIN_CFG', \$n, (New-Object Text.UTF8Encoding(\$false)))" >/dev/null
}

# ─── Kill-switch leak recorder (ks != off scenarios) — plat/RECORDER-CONTRACT.md ───
# TWA's C:\cb33\cbm-recorder.ps1 runs the scenario's steps.ps1 as a SYSTEM task and samples egress/state at 1 Hz
# into status.tsv + cap.pcapng, surviving the ssh drop a KS-on switch causes. The driver uses the recorder for a
# ks-on scenario only when plat_record_start is defined AND the scenario has a <fn>_ps. CBM_APP_STATE=1 adds -AppState
# (app rows) when the Electron app is deployed; off by default (CLI-only runs have no app).
RECORD_MAX=${RECORD_MAX:-900}
plat_record_start() { # $1 label (SUITE-SCENARIO-PROTO, path-safe)  $2 local steps.ps1 path  $3 max seconds
  local label=$1 steps=$2 max=${3:-$RECORD_MAX}
  local rdir="C:\\cb33\\rec\\$label" rfwd="C:/cb33/rec/$label"
  wps "New-Item -ItemType Directory -Force '$rdir' | Out-Null; Remove-Item '$rdir\\*' -Recurse -Force -ErrorAction SilentlyContinue" >/dev/null
  scp -q $WSSH "$steps" "$WIN_USER@$WIN_HOST:$rfwd/steps.ps1" || { say "windows: record: steps.ps1 upload failed"; return 1; }
  echo "$rdir" > "$SCEN_DIR/.rdir"
  # The matrix's recorder is the canonical one (RECORDER-CONTRACT.md): upload it every run, so the VM never runs an
  # older copy (TWA 11-08: id= and call_ms= missing from a9ecc5b recorder rows, because C:\cb33 still had the old one).
  scp -q $WSSH "$HERE/plat/windows-recorder.ps1" "$WIN_USER@$WIN_HOST:$(tr '\\' / <<<"$WIN_DIR")/cbm-recorder.ps1" ||
    { say "windows: record: recorder upload failed"; return 1; }
  local app=''; [ "${CBM_APP_STATE:-}" = 1 ] && app='-AppState'
  wps "powershell -File '$WIN_DIR\\cbm-recorder.ps1' -Dir '$rdir' -Seconds $max -Instance '$INSTANCE' $app -Launch" >/dev/null
  # Block until <Dir>\state reads 'done <exit>' (recorder survives the KS-on ssh drop; deadman at max+120s on the VM).
  local waited=0 lim=$((max + 180)) st
  while :; do
    st=$(wps "Get-Content '$rdir\\state' -ErrorAction SilentlyContinue" | tr -d '\r' | grep . | tail -1)
    case $st in done\ *) break ;; esac
    [ $waited -ge $lim ] && { say "windows: record: timed out after ${lim}s (state='$st')"; return 1; }
    sleep 5; waited=$((waited + 5))
  done
  local code=${st#done }
  case $code in
    deadman|killed) say "windows: record: $code"; return 1 ;;
    ''|*[!0-9]*) say "windows: record: bad state '$st'"; return 1 ;;
    *) return "$code" ;;
  esac
}
plat_record_collect() { # $1 SCEN_DIR
  local sdir=$1 rdir rfwd rc=0 f
  rdir=$(cat "$sdir/.rdir" 2>/dev/null) || { say "windows: record: no .rdir in $sdir"; return 1; }
  rfwd=${rdir//\\//}
  for f in status.tsv cap.pcapng cli.txt egress.tsv recorder.log; do
    scp -q $WSSH "$WIN_USER@$WIN_HOST:$rfwd/$f" "$sdir/$f" 2>/dev/null || { case $f in status.tsv|cap.pcapng) rc=1 ;; esac; }
  done
  [ "$rc" = 0 ] || say "windows: record: status.tsv or cap.pcapng did not come back"
  return $rc
}

# pktmon on the NIC component only: a packet WFP blocks never reaches it, so what it sees did leave the machine.
plat_capture_start() {
  CAP_LOCAL=$1
  wps "pktmon stop *> \$null; pktmon filter remove *> \$null; Remove-Item '$WIN_DIR\\cap.etl','$WIN_DIR\\cap.pcapng' -ErrorAction SilentlyContinue; pktmon start --capture --comp nics --pkt-size 0 --file-name '$WIN_DIR\\cap.etl' | Out-Null; 'started'" | grep -q started
}
plat_capture_stop() {
  [ -n "${CAP_LOCAL:-}" ] || return 0
  wps "pktmon stop | Out-Null; pktmon etl2pcap '$WIN_DIR\\cap.etl' --out '$WIN_DIR\\cap.pcapng' | Out-Null" >/dev/null
  scp -q $WSSH "$WIN_USER@$WIN_HOST:${WIN_DIR//\\//}/cap.pcapng" "$CAP_LOCAL" 2>/dev/null
  return 0
}

plat_leftovers() {
  wps "
    Get-Service | Where-Object { \$_.Name -like 'sentinel-dvpnd\$*' -and \$_.Name -ne '$WIN_SVC' -or \$_.Name -like 'WireGuardTunnel\$*' -or \$_.Name -like 'AmneziaWGTunnel\$*' } | ForEach-Object { \"service: \$(\$_.Name) \$(\$_.Status)\" }
    netsh wfp show filters file='$WIN_DIR\\wfp.xml' | Out-Null
    \$n = (Select-String -LiteralPath '$WIN_DIR\\wfp.xml' -Pattern 'sentinel|dvpn' -AllMatches -ErrorAction SilentlyContinue | Measure-Object).Count
    if (\$n -gt 0) { \"wfp: \$n filter line(s) naming sentinel/dvpn\" }
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { \$_.Name -match '^(dvpn|wg|tun|sing|ddv)' -or \$_.InterfaceDescription -match 'WireGuard|AmneziaWG|Wintun|TAP-Windows' } | ForEach-Object { \"link: \$(\$_.Name) (\$(\$_.InterfaceDescription)) \$(\$_.Status)\" }
    Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { \$_.InterfaceAlias -match '^(dvpn|wg|tun|sing)' } | ForEach-Object { \"route: \$(\$_.DestinationPrefix) via \$(\$_.InterfaceAlias)\" }
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue | ForEach-Object { \"dns rule: \$(\$_.Namespace) -> \$(\$_.NameServers -join ',')\" }
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | ForEach-Object { \$k = Get-ItemProperty \"Registry::\$(\$_.Name)\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\" -ErrorAction SilentlyContinue; if (\$k.ProxyEnable -eq 1) { \"proxy: \$(\$_.PSChildName) \$(\$k.ProxyServer)\" } }
    Get-Process -Name xray,v2ray,hysteria,hysteria2,openvpn -ErrorAction SilentlyContinue | ForEach-Object { \"process: \$(\$_.Name) \$(\$_.Id)\" }
    Get-ChildItem '$WIN_STATE' -Recurse -File -Include *.key,*auth.txt,*.conf,*.yaml,*.ovpn -ErrorAction SilentlyContinue | ForEach-Object { \"file: \$(\$_.FullName)\" }
    Get-NetFirewallRule -DisplayName cbmcut -ErrorAction SilentlyContinue | ForEach-Object { 'firewall: cbmcut rule (harness cut not lifted)' }
  "
}
# A never-started service under the next instance's name: as a crashed client would leave it.
plat_plant_leftover() { wps "sc.exe create 'sentinel-dvpnd\$c9' binPath= 'C:\\Windows\\System32\\cmd.exe /c exit 0' start= demand | Out-Null" >/dev/null; }
plat_unplant_leftover() { wps "sc.exe delete 'sentinel-dvpnd\$c9' | Out-Null" >/dev/null; return 0; }
# For the leak selftest (needs a hook in checks/leak.sh, asked of FWX): one packet straight to 1.1.1.1 from the VM.
plat_plant_leak() { wps "try { Invoke-WebRequest -Uri https://1.1.1.1 -TimeoutSec 5 -UseBasicParsing | Out-Null } catch { }" >/dev/null; return 0; }

# Windows Firewall block rule: a block in any WFP sublayer wins over dvpnd's permit for the node (unless dvpnd's permit
# carries a hard right). The S3 selftest must show the egress stops during the cut; if not, this needs a WFP filter.
plat_cut() {
  wps "New-NetFirewallRule -DisplayName cbmcut -Direction Outbound -RemoteAddress '$NODE_IP' -Action Block | Out-Null" >/dev/null
  [ -n "${1:-}" ] && { sleep "$1"; plat_uncut; }
  return 0
}
plat_uncut() { wps "Remove-NetFirewallRule -DisplayName cbmcut -ErrorAction SilentlyContinue" >/dev/null; return 0; }

plat_cli_outputs() {
  cat "$SCEN_DIR/cli.txt" 2>/dev/null
  wps "Get-ChildItem '$WIN_STATE' -Recurse -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1 | ForEach-Object { Get-Content -LiteralPath \$_.FullName -Tail 400 }" |
    grep -oE '"(error|message|reason)":"[^"]*"' | tail -50
}

# plat_chain_cli <args>: lib/nodes.sh node_chain_cli uses this hook when defined, so node show/search run the
# client CLI ON THE VM (where it exists) instead of on ctl-1 (which has no CLI). Chain read only: no --instance
# (no daemon call), and the lane-b RPC is passed when HELIUS_RPC_URL is set (same as node_chain_cli's else branch).
plat_chain_cli() {
  local a q="" rpc=""
  for a in "$@"; do q="$q '${a//\'/\'\'}'"; done
  [ -n "${HELIUS_RPC_URL:-}" ] && rpc=" --rpc.url '${HELIUS_RPC_URL//\'/\'\'}'"
  wps "Set-Location '$WIN_DIR'; & .\\sentinel-dvpn.exe --home '$WIN_DIR\\cli'$q$rpc 2>&1 | ForEach-Object { \"\$_\" }"
}
# cli_chain: same VM-side chain read, used by plat_money (channel show).
cli_chain() { plat_chain_cli "$@"; }
# Chain read of $CHANNEL ("escrow", "redeemed" in base units). One RPC call. `redeemed` covers the channel's life, so it
# is this run's node_settled only when this run opened the channel (CHANNEL_NEW=1, set by plat_connect). Same as Linux.
chain_channel_field() { # $1 field
  [ -n "${CHANNEL:-}" ] || return 1
  cli_chain channel show "$CHANNEL" | grep -oE "\"$1\": *[0-9]+" | head -1 | grep -oE '[0-9]+$'
}
# cb33 `client sessions` has no owed/paid fields, only per-session "spent" + "channel" (FLX2 on cb33092e). Sum "spent"
# over this channel's sessions; paid has no client-side source (unknown: money.sh skips it). Same as Linux.
plat_money() {
  local j redeemed escrow settled=unknown spent n
  j=$(SCEN_DIR=${SCEN_DIR:-/tmp} cli client sessions 2>/dev/null)
  redeemed=$(chain_channel_field redeemed); escrow=$(chain_channel_field escrow)
  [ "${CHANNEL_NEW:-0}" = 1 ] && [ -n "$redeemed" ] && settled=$redeemed
  spent=$(awk -v ch="$CHANNEL" '/"spent":/ {gsub(/[^0-9]/, "", $2); s = $2} /"channel":/ {if (index($0, ch) && ch != "") t += s; s = 0} END {print t + 0}' <<<"$j")
  n=$(awk -v ch="$CHANNEL" '/"channel":/ {if (index($0, ch) && ch != "") c++} END {print c + 0}' <<<"$j")
  MONEY_PREPAY_ALLOW=$(( n * $(prepay_window_units) ))
  echo "spent=$spent paid=unknown node_settled=$settled redeemed=${redeemed:-unknown} escrow=${escrow:-unknown} prepay_allow=$MONEY_PREPAY_ALLOW"
}
# Base units one session may sign ahead (FWX 2c7d771): per_gb max(prepay_bytes, node min) x price_per_gb / 1e9,
# per_hour max(prepay_seconds, node min) x price_per_hour / 3600, rounded up. Unknown price -> 0 (strict).
# The node's metadata is fetched from ctl-1 (its public URI), not through the VM.
prepay_window_units() {
  local cfg basis pb ps meta uri mpb mps ppg pph
  cfg=$(wps "[IO.File]::ReadAllText('$WIN_CFG')")
  basis=$(sed -nE "s/^basis = '([a-z_]+)'.*/\1/p" <<<"$cfg" | head -1)
  pb=$(sed -nE 's/^prepay_bytes = ([0-9]+).*/\1/p' <<<"$cfg" | head -1); ps=$(sed -nE 's/^prepay_seconds = ([0-9]+).*/\1/p' <<<"$cfg" | head -1)
  uri=$(cli_chain node show "$NODE_ID" | grep -oE '"uri": *"https://[^"]+"' | head -1 | grep -oE 'https://[^"]+')
  [ -n "$uri" ] && meta=$(curl -sk -m 8 "$uri/v1/metadata")
  mpb=$(grep -oE '"min_channel_prepay_bytes":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); mps=$(grep -oE '"min_channel_prepay_seconds":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  ppg=$(grep -oE '"channel_price_per_gb":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$'); pph=$(grep -oE '"channel_price_per_hour":[0-9]+' <<<"${meta:-}" | grep -oE '[0-9]+$')
  awk -v b="${basis:-per_gb}" -v pb="${pb:-0}" -v ps="${ps:-0}" -v mpb="${mpb:-0}" -v mps="${mps:-0}" -v ppg="${ppg:-0}" -v pph="${pph:-0}" 'BEGIN {
    if (b == "per_hour") { s = (ps > mps ? ps : mps); v = s * pph / 3600 } else { y = (pb > mpb ? pb : mpb); v = y * ppg / 1e9 }
    printf "%d\n", (v == int(v) ? v : int(v) + 1) }'
}

# RPC lane b (RPC-PLAN): the lane URL goes into the daemon's [rpc] url (not [tx.paymaster], whose key is also `url`).
# The key never reaches a log or stdout: it travels base64 inside the -EncodedCommand payload and is decoded in
# PowerShell on the VM. The first call keeps the original as <cfg>.pre-rpc; plat_unset_rpc puts it back.
plat_set_rpc() { # $1 rpc url  $2 ws url (optional)
  # Windows config SPLIT: the c1 SERVICE daemon reads %ProgramData%\sentinel-dvpn\c1 ($WIN_CFG) while the raw CLIENT
  # reads $WIN_DIR\cli. Set [rpc] url in BOTH (INSERTING the line if the [rpc] block has none — else the daemon falls
  # back to its built-in 127.0.0.1:8899 and ks-on preflight fails), restart the service so the daemon reloads, then
  # verify both configs carry the lane url (fail on mismatch). The key never reaches a log: base64 in -EncodedCommand.
  [ -n "${1:-}" ] || return 1
  local u w
  u=$(printf '%s' "$1" | base64 -w0); w=$(printf '%s' "${2:-}" | base64 -w0)
  wps "\$u = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$u')); \$w = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$w'))
function Set-RpcCfg(\$c) {
  if (-not \$c -or -not (Test-Path -LiteralPath \$c)) { return }
  if (-not (Test-Path -LiteralPath \"\$c.pre-rpc\")) { Copy-Item -LiteralPath \$c -Destination \"\$c.pre-rpc\" }
  \$sec = ''; \$seen = \$false; \$out = New-Object System.Collections.Generic.List[string]
  foreach (\$l in [IO.File]::ReadAllLines(\$c)) {
    if (\$l -match '^\[') { if (\$sec -eq '[rpc]' -and -not \$seen) { \$out.Add(\"url = '\$u'\"); \$seen = \$true }; \$sec = \$l.Trim() }
    if (\$sec -eq '[rpc]' -and \$l -match '^url = ') { \$out.Add(\"url = '\$u'\"); \$seen = \$true }
    elseif (\$sec -eq '[rpc]' -and \$w -and \$l -match '^ws_url = ') { \$out.Add(\"ws_url = '\$w'\") }
    else { \$out.Add(\$l) } }
  if (\$sec -eq '[rpc]' -and -not \$seen) { \$out.Add(\"url = '\$u'\") }
  [IO.File]::WriteAllText(\$c, ((\$out -join \"\`n\") + \"\`n\"), (New-Object Text.UTF8Encoding(\$false)))
}
function Get-RpcUrl(\$c) {
  if (-not (Test-Path -LiteralPath \$c)) { return '' }
  \$sec = ''; foreach (\$l in [IO.File]::ReadAllLines(\$c)) {
    if (\$l -match '^\[') { \$sec = \$l.Trim() }
    elseif (\$sec -eq '[rpc]' -and \$l -match \"^url = '([^']*)'\") { return \$Matches[1] } }
  return '' }
\$svcCfg = '$WIN_CFG'; \$cliCfg = '$WIN_DIR\\cli\\config.toml'
Set-RpcCfg \$svcCfg; Set-RpcCfg \$cliCfg
Restart-Service -Name '$WIN_SVC' -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 4
\$a = Get-RpcUrl \$svcCfg; \$b = Get-RpcUrl \$cliCfg
\$svcStatus = (Get-Service -Name '$WIN_SVC' -ErrorAction SilentlyContinue).Status
\$sa = if (\$a -eq \$u) { 'set' } else { 'unset' }; \$sb = if (\$b -eq \$u) { 'set' } else { 'unset' }
if (\$a -eq \$u -and \$b -eq \$u -and \$svcStatus -eq 'Running') { 'rpc-set-both' } else { \"rpc-fail svc=\$sa cli=\$sb service=\$svcStatus\" }" | grep -qx rpc-set-both || { say "   rpc: FAILED - [rpc] not set in both configs, or service not Running after restart (key not shown)"; return 1; }
  say "   rpc: [rpc] url set in service + client configs, daemon restarted + Running (key not shown)"
}
plat_unset_rpc() { wps "foreach (\$c in @('$WIN_CFG','$WIN_DIR\\cli\\config.toml')) { if (Test-Path -LiteralPath \"\$c.pre-rpc\") { Move-Item -LiteralPath \"\$c.pre-rpc\" -Destination \$c -Force } }" >/dev/null; return 0; }

plat_reset() { plat_uncut; plat_daemon_running || plat_daemon_start; plat_disconnect >/dev/null 2>&1; plat_set_ks off; return 0; }

# ─── Deadman (replaces lib/common.sh's /run hold): a SYSTEM task on the VM; if the hold file is not refreshed for 3 min
# it stops every session, sets the kill switch off, lifts the harness cut and restarts the service. ───
deadman_start() {
  wps "
    \$w = @'
\$hold = '$WIN_DIR\\deadman.hold'; \$cli = '$WIN_DIR\\sentinel-dvpn.exe'
while (\$true) {
  Start-Sleep -Seconds 20
  if (-not (Test-Path \$hold)) { continue }
  if (((Get-Date) - (Get-Item \$hold).LastWriteTime).TotalSeconds -lt 180) { continue }
  Add-Content '$WIN_DIR\\deadman.log' \"\$(Get-Date -Format o) hold stale: restoring\"
  Remove-NetFirewallRule -DisplayName cbmcut -ErrorAction SilentlyContinue
  \$ids = [regex]::Matches((& \$cli --home '$WIN_DIR\\cli' client sessions --instance '$INSTANCE' 2>&1 | Out-String), '\"id\": *\"([^\"]+)\"') | ForEach-Object { \$_.Groups[1].Value }
  foreach (\$s in \$ids) { & \$cli --home '$WIN_DIR\\cli' client stop \$s --instance '$INSTANCE' 2>&1 | Out-Null; Start-Sleep -Seconds 7 }
  \$t = [IO.File]::ReadAllText('$WIN_CFG'); [IO.File]::WriteAllText('$WIN_CFG', [regex]::Replace(\$t, \"(?m)^(\\s*kill_switch\\s*=\\s*)['\`\"][a-z]+['\`\"]\", \"\`\${1}'off'\"), (New-Object Text.UTF8Encoding(\$false)))
  Restart-Service -Name '$WIN_SVC' -Force -ErrorAction SilentlyContinue
  Remove-Item \$hold -ErrorAction SilentlyContinue
}
'@
    [IO.File]::WriteAllText('$WIN_DIR\\cbm-deadman.ps1', \$w, (New-Object Text.UTF8Encoding(\$false)))
    \$a = New-ScheduledTaskAction -Execute powershell.exe -Argument \"-NoProfile -ExecutionPolicy Bypass -File $WIN_DIR\\cbm-deadman.ps1\"
    Register-ScheduledTask -TaskName cbm-deadman -Action \$a -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12)) -Force | Out-Null
    Start-ScheduledTask -TaskName cbm-deadman
    Set-Content -LiteralPath '$WIN_DIR\\deadman.hold' -Value (Get-Date -Format o)
  " >/dev/null
  ( while :; do wps "Set-Content -LiteralPath '$WIN_DIR\\deadman.hold' -Value (Get-Date -Format o)" >/dev/null 2>&1; sleep 30; done ) &
  DEADMAN_PID=$!
}
deadman_stop() {
  [ -n "${DEADMAN_PID:-}" ] && kill "$DEADMAN_PID" 2>/dev/null
  wps "Stop-ScheduledTask -TaskName cbm-deadman -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName cbm-deadman -Confirm:\$false -ErrorAction SilentlyContinue; Remove-Item '$WIN_DIR\\deadman.hold' -ErrorAction SilentlyContinue" >/dev/null 2>&1
  return 0
}

# ─── Recorder step-script emitters (used by the suites' <fn>_ps on Windows; see RECORDER-CONTRACT.md) ───
# win_ps_header prints the PowerShell prelude every <fn>_ps shares: the cli/daemon/node variables and helper
# functions, with the driver's per-scenario values (NODE_ID, WIN_SVC, PHYS_IF, NODE_IP, ESCROW, INSTANCE) baked in at
# emit time. A <fn>_ps prints win_ps_header then its own action sequence. steps.ps1 is actions ONLY (RECORDER-CONTRACT):
# the recorder samples egress/state into status.tsv and the leak/status checks judge; the exit code is the action rc.
# Stop methods mirror plat_daemon_stop exactly (TERM = Stop-Service; KILL = Stop-Process of the service PID).
# Stop-AllSessions: the PowerShell twin of plat_disconnect. `client stop` takes one id (it has no --all), so list the
# sessions and stop each one that has not ended. Needs $cli, $h and $inst set. Quoted heredoc: nothing expands here.
win_ps_stop_all() {
  cat <<'PS'
function Stop-AllSessions {
  $id = $null
  foreach ($l in ((& $cli --home $h client sessions --instance $inst 2>&1 | Out-String) -split "`n")) {
    if ($l -match '"id":\s*"([^"]+)"') { $id = $Matches[1] }
    elseif ($l -match '"status":\s*"([^"]+)"') {
      if ($id -and $Matches[1] -ne 'ended') { & $cli --home $h client stop $id --instance $inst 2>&1 | Out-String | Write-Output }
      $id = $null
    }
  }
}
PS
}

win_ps_header() {
  cat <<PS
\$ErrorActionPreference = 'Continue'
Set-Location '$WIN_DIR'
\$cli = '$WIN_DIR\\sentinel-dvpn.exe'; \$h = '$WIN_DIR\\cli'; \$inst = '$INSTANCE'
\$node = '$NODE_ID'; \$svc = '$WIN_SVC'; \$nodeip = '$NODE_IP'; \$phys = '$PHYS_IF'
function Connect-Node { & \$cli --home \$h client start --node \$node --new-channel --mode voucher --escrow-base-units ${ESCROW:-100000} --instance \$inst 2>&1 | Out-String | Write-Output }
$(win_ps_stop_all)
function Disconnect-Node { Stop-AllSessions }
function Stop-DaemonTerm { Stop-Service -Name \$svc -Force; (Get-Service -Name \$svc).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30)) }
function Stop-DaemonKill { \$p = (Get-CimInstance Win32_Service -Filter "Name='\$svc'").ProcessId; if (\$p) { Stop-Process -Id \$p -Force } }
function Start-Daemon { Start-Service -Name \$svc; (Get-Service -Name \$svc).WaitForStatus('Running',[TimeSpan]::FromSeconds(30)) }
PS
}

# ─── S10 install lifecycle (FWA 11-08) ───
# Drives the INSTALLED 0.2.0 app (NSIS, perMachine, service sentinel-dvpnd$c0, home
# %ProgramData%\sentinel-dvpn\c0), which is SEPARATE from the harness build at $WIN_DIR (instance c1).
# The package files are the Devnet-dVPN-Setup-<ver>-<arch>.exe installers, staged on the VM by the harness,
# with CBM_PKG_OLD / CBM_PKG_NEW set to their VM paths (e.g. C:\pkg\Devnet-dVPN-Setup-0.2.0-arm64.exe).
# The ssh user is a local admin, so the installer's manifest elevation is satisfied in-session (no UAC prompt).
CBM_PKG_INSTANCE=${CBM_PKG_INSTANCE:-c0}
CBM_PKG_SVC="sentinel-dvpnd\$$CBM_PKG_INSTANCE"
CBM_PKG_HOME_WIN=${CBM_PKG_HOME_WIN:-"C:\\ProgramData\\sentinel-dvpn\\$CBM_PKG_INSTANCE"}
CBM_PKG_NAME=${CBM_PKG_NAME:-'Devnet dVPN'}
# PowerShell snippet: the installed-product's registry uninstall record (x64 + WOW6432Node), matched by DisplayName.
_PKG_REC="\$rec = @('HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall','HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall') | Get-ChildItem -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty \$_.PSPath } | Where-Object { \$_.DisplayName -eq '$CBM_PKG_NAME' } | Select-Object -First 1;"

plat_pkg_old() { echo "${CBM_PKG_OLD:-}"; }
plat_pkg_new() { echo "${CBM_PKG_NEW:-}"; }

# Run an NSIS installer silently and wait; echo nothing, return its exit code. /S = silent for an assisted
# (oneClick=false) perMachine installer; -Wait blocks until the whole install (incl. install-deps.ps1) finishes.
_pkg_run_installer() { # $1 = VM path to the Setup .exe
  wps "\$p = Start-Process -FilePath '$1' -ArgumentList '/S' -Wait -PassThru; exit \$p.ExitCode"
}

plat_pkg_install() { # $1 Setup .exe (VM path); $2 "setup" = initial install (the NSIS installer always runs
  # setup-daemon.ps1 = service install + the c0 device, so "setup" needs no extra step on Windows).
  [ -n "$1" ] || { echo "no package file"; return 77; }
  _pkg_run_installer "$1" || { echo "installer exited non-zero"; return 1; }
  local i
  for i in $(seq 1 25); do
    wps "if (Get-Service -Name '$CBM_PKG_SVC' -ErrorAction SilentlyContinue) { 'y' }" | grep -qx y && return 0
    sleep 1
  done
  echo "service $CBM_PKG_SVC not present after install"; return 1
}

plat_pkg_upgrade() { # $1 new Setup .exe, installed over the existing install (NSIS replaces in place = install-over-old)
  [ -n "$1" ] || { echo "no package file"; return 77; }
  _pkg_run_installer "$1" || { echo "upgrade installer exited non-zero"; return 1; }
  local i
  for i in $(seq 1 25); do
    wps "if (Get-Service -Name '$CBM_PKG_SVC' -ErrorAction SilentlyContinue) { 'y' }" | grep -qx y && return 0
    sleep 1
  done
  echo "service $CBM_PKG_SVC not present after upgrade"; return 1
}

plat_pkg_uninstall() { # QuietUninstallString (NSIS, silent). Keeps user config: the uninstaller removes INSTDIR
  # but leaves %ProgramData%\sentinel-dvpn (the c0 home + wallet).
  local uninst
  uninst=$(wps "$_PKG_REC \$rec.QuietUninstallString")
  [ -n "$uninst" ] || { echo "no QuietUninstallString for $CBM_PKG_NAME"; return 1; }
  wps "\$p = Start-Process -FilePath cmd.exe -ArgumentList '/c',\"$uninst\" -Wait -PassThru; exit \$p.ExitCode" || return 1
  local i
  for i in $(seq 1 25); do plat_pkg_installed || return 0; sleep 1; done
  echo "still installed after uninstall"; return 1
}

plat_pkg_installed() { # rc 0 iff the product's registry uninstall record exists
  wps "$_PKG_REC if (\$rec) { 'y' }" | grep -qx y
}

plat_pkg_version() { # echo the installed DisplayVersion (e.g. 0.2.0)
  wps "$_PKG_REC \$rec.DisplayVersion"
}

plat_pkg_files() { # one "<mode> <owner> <path>" per installed regular file under InstallLocation
  wps "$_PKG_REC \$d = \$rec.InstallLocation; if (\$d -and (Test-Path -LiteralPath \$d)) { Get-ChildItem -LiteralPath \$d -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { \$o = try { (Get-Acl \$_.FullName).Owner } catch { '?' }; '{0} {1} {2}' -f \$_.Mode, \$o, \$_.FullName } }"
}

plat_service_active() { wps "(Get-Service -Name '$CBM_PKG_SVC' -ErrorAction SilentlyContinue).Status" | grep -qx Running; }

plat_config_present() { # rc 0 iff the installed c0 home still holds config/key material
  wps "if ((Test-Path -LiteralPath '$CBM_PKG_HOME_WIN') -and (Get-ChildItem -LiteralPath '$CBM_PKG_HOME_WIN' -Recurse -File -Include '*.json','*.key','config*','*wallet*' -ErrorAction SilentlyContinue | Select-Object -First 1)) { 'y' }" | grep -qx y
}

plat_device_id() { # stable fingerprint of the installed c0 key material (cb33 device key = keys\operator.json)
  wps "Get-ChildItem -LiteralPath '$CBM_PKG_HOME_WIN' -Recurse -File -ErrorAction SilentlyContinue | Where-Object { \$_.FullName -match '\\\\keys\\\\.*\\.json\$' -or \$_.Name -match '(?i)(\\.key\$|wallet|keyring)' } | Sort-Object FullName | Get-FileHash -Algorithm SHA256 | ForEach-Object { \$_.Hash }" | tr 'A-Z' 'a-z' | tr -d ' \r\n' | sha256sum | awk '{print $1}'
}

# $1 proto — briefly connect the INSTALLED c0 instance via its own CLI (the app ships bin\devnet-dvpn.cmd), then
# disconnect. Needs the run's node/channel env (node_for/NODE_ID/CHANNELS/plat_egress), same as plat_connect.
plat_connect_short() {
  local inst="$CBM_PKG_INSTANCE" eg out s ok=1 cmd
  declare -F node_for >/dev/null && node_for "$1"
  [ -n "${NODE_ID:-}" ] || { echo "no node entry for $1"; return 1; }
  plat_service_active || { wps "Start-Service -Name '$CBM_PKG_SVC' -ErrorAction SilentlyContinue"; sleep 2; }
  plat_service_active || { echo "installed service $CBM_PKG_SVC not up"; return 1; }
  # Installed TS CLI; InstallLocation\resources\app.asar bin shim. Resolve it from the registry each call.
  cmd=$(wps "$_PKG_REC Join-Path \$rec.InstallLocation 'bin\\devnet-dvpn.cmd'")
  [ -n "$cmd" ] || { echo "installed CLI not found"; return 1; }
  tx_gap
  local ch=${CHANNELS[$NODE_ID]:-}
  if [ -n "$ch" ]; then
    out=$(wps "& '$cmd' client start --node '$NODE_ID' --channel '$ch' --instance '$inst' 2>&1 | ForEach-Object { \"\$_\" }")
  else
    out=$(wps "& '$cmd' client start --node '$NODE_ID' --new-channel --mode voucher --escrow-base-units '${ESCROW:-100000}' --instance '$inst' 2>&1 | ForEach-Object { \"\$_\" }")
    ch=$(grep -oE '"channel(_id)?": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$ch" ] && { CHANNELS[$NODE_ID]=$ch; RUN_NEW_CHANNELS="${RUN_NEW_CHANNELS:-} $ch"; }
  fi
  echo "$out" >> "${SCEN_DIR:-/tmp}/cli.txt"
  grep -qE '^error:|rpc error' <<<"$out" && { echo "installed-instance connect failed: $(grep -m1 -E '^error:|rpc error' <<<"$out" | cut -c1-200)"; return 1; }
  sleep 8
  eg=$(plat_egress)
  echo "installed-instance short connect ($1): egress $eg (node $NODE_EGRESS)"
  for s in $(wps "& '$cmd' client sessions --instance '$inst' 2>&1" | awk '/"id":/ {gsub(/[",]/,"",$2); id=$2} /"status":/ {gsub(/[",]/,"",$2); if ($2 != "ended") print id}'); do
    tx_gap; wps "& '$cmd' client stop '$s' --instance '$inst' 2>&1 | Out-Null" || ok=0
  done
  [ "$ok" = 1 ] || echo "stopping the installed instance's session failed"
  [ "$eg" = "$NODE_EGRESS" ] && [ "$ok" = 1 ]
}
