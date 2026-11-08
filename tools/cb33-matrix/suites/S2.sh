#!/usr/bin/env bash
# ─── S2 Kill switch (PLAN §1b): daemon stop, hard kill, protocol-process kill, restart; KS on + persist ───
# Covers Q0012, Q0304, Q0311, Q0389, Q0426, 22e627ef (ARM64). From TLX tlx-ksrestart-cb33.sh / tlx-q0247sharp-cb33.sh.
# Expectation (cb33 session.go:405, firewall.go:66): 'on' lifts the block on a graceful stop, 'persist' keeps it;
# a crash (KILL) leaves the block until the daemon is back. Direct egress while a block is expected = FAIL.
SCENARIOS="s2_daemon_term:on s2_daemon_term_persist:persist s2_daemon_kill:on s2_protocol_kill:on"

s2_down_sample() { # $1 = expect blocked (1) or not (0); prints one line, rc 1 on a leak
  local e k direct=0
  for k in 1 2 3; do e=$(plat_egress); echo "down sample $k: $e"; [ "$e" = "$DIRECT_IP" ] && [ "$e" != none ] && direct=$((direct + 1)); sleep 1; done
  [ "$1" = 1 ] && [ "$direct" -gt 0 ] && { echo "LEAK: $direct direct sample(s) while the block should hold"; return 1; }
  return 0
}

s2_restart() { # $1 = signal, $2 = expect blocked while down
  local proto=$PROTO
  plat_connect "$proto" || return 1; sleep 4
  plat_daemon_stop "$1"; sleep 5
  s2_down_sample "$2" || return 1
  plat_daemon_start || { echo "daemon did not come back"; return 1; }
  sleep 15
  echo "after restart: $(plat_status_line) egress $(plat_egress)"
  plat_disconnect
}
s2_daemon_term() { s2_restart TERM 0; }
s2_daemon_term_persist() { s2_restart TERM 1; }
s2_daemon_kill() { s2_restart KILL 1; }

s2_protocol_kill() {
  # Kill the protocol process mid-download (Q0247 sharp trigger); leak = active + direct. In-kernel WireGuard has no
  # process: its equivalent is the tunnel interface vanishing (plat_tunnel_kill, Linux: ip link del; DIR 11-08).
  local proto=$1 p
  plat_connect "$proto" || return 1; sleep 4
  ( curl -s -m 60 -o /dev/null "${CBM_BIG_URL:-https://speed.cloudflare.com/__down?bytes=50000000}" ) &
  sleep 3
  if declare -F plat_tunnel_kill >/dev/null; then
    p=$(plat_tunnel_kill "$proto") || { echo "could not kill the $proto tunnel: $p"; plat_disconnect; return 1; }
  else
    case $proto in wireguard|amneziawg) echo "no user-space process for $proto"; plat_disconnect; return 77 ;; esac
    declare -F plat_protocol_pid >/dev/null || { plat_disconnect; return 77; }
    # plat_kill_pid when the process is on another machine than the driver (Android: on the phone, FAN 11-08)
    p=$(plat_protocol_pid "$proto")
    [ -n "$p" ] && { if declare -F plat_kill_pid >/dev/null; then plat_kill_pid KILL "$p"; else sudo kill -KILL $p; fi; }
  fi
  echo "killed $proto: $p"
  s2_down_sample 1 || return 1
  sleep 20; echo "after: $(plat_status_line) egress $(plat_egress)"
  plat_disconnect
}

# ─── Windows recorder step scripts (ks-on) — actions only; recorder samples the down window (RECORDER-CONTRACT) ───
# s2_down_sample's leak judgment is NOT replicated here (steps.ps1 is actions-only): the leak check reads status.tsv
# across the down window. The expect-blocked-vs-lifted distinction (TERM on 'on' lifts; 'persist' and a KILL crash
# hold the block) is the leak check's call from $ks plus the recorder's state line — flagged to TWA as a contract
# item. Each body holds the daemon down ~10 s (well under the deadman's 3-min stale window) so the 1 Hz recorder
# gets a clear down sample, then restarts and disconnects. win_ps_header (plat/windows.sh) supplies the helpers.
win_ps_s2_restart() { # $1 = TERM|KILL
  win_ps_header
  cat <<PS
Connect-Node
if (\$LASTEXITCODE -ne 0) { Write-Output 'connect failed'; exit 1 }
Start-Sleep -Seconds 4
$([ "$1" = KILL ] && echo 'Stop-DaemonKill' || echo 'Stop-DaemonTerm')
Start-Sleep -Seconds 10
Start-Daemon
Start-Sleep -Seconds 15
Disconnect-Node
Start-Sleep -Seconds 3
exit 0
PS
}
# A graceful daemon stop under ks='on' LIFTS the block (cb33 session.go:405/firewall.go:66), so direct egress during
# the down window is expected, not a leak. Every other ks-on S2 scenario holds the block (persist, KILL crash,
# protocol kill) and keeps leak.sh's default expect-blocked=1.
s2_daemon_term_eb()         { echo 0; }
s2_daemon_term_ps()         { win_ps_s2_restart TERM; }
s2_daemon_term_persist_ps() { win_ps_s2_restart TERM; }
s2_daemon_kill_ps()         { win_ps_s2_restart KILL; }

s2_protocol_kill_ps() { # $1 proto — kill the user-space protocol process mid-download; wg/awg have none (SKIP 77)
  local proc
  case $1 in
    wireguard|amneziawg) printf '%s\n' "exit 77"; return 0 ;;
    xray) proc=xray ;; v2ray) proc=v2ray ;; hysteria2) proc=hysteria2 ;; openvpn) proc=openvpn ;;
    *) proc=$1 ;;
  esac
  win_ps_header
  cat <<PS
Connect-Node
if (\$LASTEXITCODE -ne 0) { Write-Output 'connect failed'; exit 1 }
Start-Sleep -Seconds 4
\$dl = Start-Job -ScriptBlock { try { Invoke-WebRequest -Uri '${CBM_BIG_URL:-https://speed.cloudflare.com/__down?bytes=50000000}' -OutFile "\$env:TEMP\\s2dl.bin" -TimeoutSec 60 -UseBasicParsing | Out-Null } catch {} }
Start-Sleep -Seconds 3
\$p = Get-Process '$proc' -ErrorAction SilentlyContinue
if (\$p) { \$p | Stop-Process -Force -ErrorAction SilentlyContinue; Write-Output ('killed $proc pid ' + ((\$p.Id) -join ',')) } else { Write-Output 'no $proc process found' }
Start-Sleep -Seconds 10
Stop-Job \$dl -ErrorAction SilentlyContinue; Remove-Job \$dl -Force -ErrorAction SilentlyContinue
Remove-Item "\$env:TEMP\\s2dl.bin" -ErrorAction SilentlyContinue
Disconnect-Node
Start-Sleep -Seconds 3
exit 0
PS
}
