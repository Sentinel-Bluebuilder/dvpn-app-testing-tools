#!/usr/bin/env bash
# ─── S3 Network trouble (PLAN §1b) ───
# 90 s cut (from TLX tlx-q0372-cb33.sh / tlx-kshold-cb33.sh) is implemented; the rest are named stubs.
# Covers Q0264, Q0318, Q0353, Q0357–59, Q0366, Q0368/69, Q0372, Q0374, Q0375, Q0385, Q0398, Q0406, Q0413, Q0415.
# The honest-status check (every call < 1 s, status matches egress) does the Q0372 / Q0415 judging.
SCENARIOS="s3_cut90:off s3_cut90_ks:on s3_nic_flap:on s3_second_nic_down:off s3_loss3:off s3_latency:off s3_mtu1280_blackhole:off s3_udp_frag:off"

s3_cut90_body() {
  plat_connect "$1" || return 1; sleep 4
  echo "cut 90 s to $NODE_IP"; plat_cut 90
  sleep 30   # redial / recovery window
  echo "after the cut: $(plat_status_line) egress $(plat_egress) sessions $(plat_sessions | tr '\n' ' ')"
  plat_disconnect
}
s3_cut90() { s3_cut90_body "$1"; }
s3_cut90_ks() { s3_cut90_body "$1"; }

# TODO(FLX/FWA/FMC/FAN): platform fault injectors (plat_nic_flap, plat_netem loss/latency, plat_mtu_blackhole).
s3_nic_flap() { declare -F plat_nic_flap >/dev/null || return 77; plat_connect "$1" || return 1; plat_nic_flap 30; sleep 30; plat_disconnect; }
s3_second_nic_down() { return 77; }
s3_loss3() { declare -F plat_netem >/dev/null || return 77; plat_connect "$1" || return 1; plat_netem "loss 3%" 60; plat_disconnect; }
s3_latency() { declare -F plat_netem >/dev/null || return 77; plat_connect "$1" || return 1; plat_netem "delay 400ms 50ms" 60; plat_disconnect; }
s3_mtu1280_blackhole() { declare -F plat_mtu_blackhole >/dev/null || return 77; plat_connect "$1" || return 1; plat_mtu_blackhole 1280 60; plat_disconnect; }
s3_udp_frag() { return 77; }

# ─── Windows recorder step script (ks-on) — actions only (RECORDER-CONTRACT) ───
# Cut the route to the node from the VM for 90 s (the same cbmcut outbound-block plat_cut uses), then a 30 s recovery
# window, so the recorder samples whether the kill switch holds during the cut and the session redials after. Fits
# RECORD_MAX (default 900).
s3_cut90_ks_ps() { # $1 proto
  win_ps_header
  cat <<PS
Connect-Node
if (\$LASTEXITCODE -ne 0) { Write-Output 'connect failed'; exit 1 }
Start-Sleep -Seconds 4
New-NetFirewallRule -DisplayName cbmcut -Direction Outbound -RemoteAddress \$nodeip -Action Block | Out-Null
Write-Output ('cut 90 s to ' + \$nodeip)
Start-Sleep -Seconds 90
Remove-NetFirewallRule -DisplayName cbmcut -ErrorAction SilentlyContinue
Start-Sleep -Seconds 30
Disconnect-Node
Start-Sleep -Seconds 3
exit 0
PS
}

# Flap the physical NIC (down 30 s, 30 s recovery) so the recorder samples whether the kill switch holds while the
# underlay is gone and the session recovers after. SAFETY (DIR 11-08): before disabling, register an INDEPENDENT
# SYSTEM scheduled task that re-enables the adapter at +75 s — it survives the ssh drop and this script dying, so
# the VM's primary NIC can never be left disabled and stranded off-network. The normal in-script re-enable runs
# first (at +~35 s); the task is a backstop that no-ops if the NIC is already up, then is removed.
s3_nic_flap_ps() { # $1 proto
  win_ps_header
  cat <<PS
Connect-Node
if (\$LASTEXITCODE -ne 0) { Write-Output 'connect failed'; exit 1 }
Start-Sleep -Seconds 4
\$act = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -NonInteractive -Command Enable-NetAdapter -Name '\$phys'"
\$trg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(75))
Register-ScheduledTask -TaskName cbm-nic-restore -Action \$act -Trigger \$trg -User SYSTEM -RunLevel Highest -Force | Out-Null
Write-Output ('flap ' + \$phys)
Disable-NetAdapter -Name \$phys -Confirm:\$false
Start-Sleep -Seconds 30
Enable-NetAdapter -Name \$phys -Confirm:\$false
Start-Sleep -Seconds 30
Unregister-ScheduledTask -TaskName cbm-nic-restore -Confirm:\$false -ErrorAction SilentlyContinue
Disconnect-Node
Start-Sleep -Seconds 3
exit 0
PS
}
