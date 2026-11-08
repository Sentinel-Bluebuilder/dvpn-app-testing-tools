#!/usr/bin/env bash
# ─── az3-arm.sh: Windows 11 test VMs (KIND=arm64 default, or KIND=x64) on Azure-3 (TWA, PLAN-cb33-FINAL §5). Runs on ctl-1. ───
# Usage: [KIND=x64] az3-arm.sh <create|start|stop|ip|state> <region> [name]   (name default ddv3-wa-/ddv3-wx-<region>)
#   create  resource group ddv3-<region> + a D4ps_v5 Win11 ARM64 VM (Trusted Launch), sshd on, the azure2 key for ddv,
#           port 22 open only to this box's public IP. Then: arm-runner.sh prep <ip> (desktop auto-login, C:\ddv tree).
#   start / stop   start, or stop + DEALLOCATE (stop alone keeps billing the cores)
#   ip / state     the public IP / the power state
# Every create/start/stop prints one LEDGER line: paste it into your machine ledger.
# Quota is 4 vCPU per region (11-07), so one D4ps_v5 per region. The admin password is random, never printed and
# never stored: arm-runner prep sets its own ddv password for auto-login.
set -euo pipefail
export AZURE_CONFIG_DIR="$HOME/.azure-fleet3"
AZ="$HOME/azenv/bin/az"
step="${1:?create|start|stop|ip|state}"; region="${2:?region}"
KIND="${KIND:-arm64}"   # arm64 | x64
if [ "$KIND" = x64 ]; then
  name="${3:-ddv3-wx-$region}"; SIZES="Standard_D4s_v5 Standard_D4as_v5 Standard_D4s_v6 Standard_D4as_v6 Standard_D4s_v4 Standard_D4as_v4 Standard_D4s_v3"
  IMAGE=MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest
else
  name="${3:-ddv3-wa-$region}"; SIZES="Standard_D4ps_v5 Standard_D4ps_v6 Standard_D4pds_v6 Standard_D4pls_v5"
  IMAGE=MicrosoftWindowsDesktop:windows11preview-arm64:win11-26h2-pro:latest
fi
rg="ddv3-$region"
# create tries each size in SIZES (or just SIZE=<sku>) and moves on when Azure refuses it (fast, unlike list-skus).
if [ "$step" = create ]; then SIZES="${SIZE:-$SIZES}"; SIZE=${SIZES%% *}
else SIZE=$("$AZ" vm show -g "$rg" -n "$name" --query hardwareProfile.vmSize -o tsv 2>/dev/null || echo unknown); fi
PUB="$HOME/.ssh/azure2_ed25519.pub"
ledger() { echo "LEDGER $(date -u +%FT%TZ) azure3 TWA $1 $name ($rg, $SIZE) $2"; }

case "$step" in
  create)
    [ -f "$PUB" ] || { echo "no $PUB"; exit 1; }
    used=$("$AZ" vm list-usage -l "$region" --query "[?name.value=='cores'].currentValue | [0]" -o tsv)
    [ "${used:-0}" -le 0 ] || { echo "BLOCK $region already uses $used of 4 cores; pick another region"; exit 3; }
    me=$(curl -s -m 10 https://api.ipify.org)
    "$AZ" group create -n "$rg" -l "$region" -o none
    pw="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)Aa1!"
    ok=0
    for SIZE in $SIZES; do
      # Ampere v5 (D*ps_v5) refuses TrustedLaunch ("not supported ... with 'TrustedLaunch' security type"): Standard there.
      case "$SIZE" in *ps_v5) sec=(--security-type Standard) ;; *) sec=(--security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true) ;; esac
      if err=$("$AZ" vm create -g "$rg" -n "$name" -l "$region" --image "$IMAGE" --size "$SIZE" \
        "${sec[@]}" \
        --admin-username ddv --admin-password "$pw" --public-ip-sku Standard --nsg-rule NONE \
        --os-disk-size-gb 128 --license-type Windows_Client -o none 2>&1); then ok=1; break; fi
      echo "create $SIZE in $region refused: $(grep -oE 'RequestDisallowedByAzure|SkuNotAvailable|QuotaExceeded|InvalidParameter|ImageNotFound|PlatformImageNotFound|Conflict' <<<"$err" | sort -u | tr '\n' ' ')"
      { grep -v '^WARNING' <<<"$err" | head -c 600; echo; } || true
    done
    unset pw
    [ "$ok" = 1 ] || { echo "BLOCK $region refused every size ($SIZES); pick the next free region"; exit 3; }
    nsg=$("$AZ" network nsg list -g "$rg" --query "[0].name" -o tsv)
    "$AZ" network nsg rule create -g "$rg" --nsg-name "$nsg" -n ssh-ctl1 --priority 100 --protocol Tcp \
      --destination-port-ranges 22 --source-address-prefixes "$me/32" --access Allow -o none
    # sshd + the key for ddv (an admin: Windows reads administrators_authorized_keys), default shell stays PS 5.1
    key=$(cat "$PUB")
    "$AZ" vm run-command invoke -g "$rg" -n "$name" --command-id RunPowerShellScript -o none --scripts "
      Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
      New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
      Set-Service sshd -StartupType Automatic; Start-Service sshd
      \$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
      Set-Content -Path \$f -Value '$key' -Encoding ascii
      icacls \$f /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
      if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Protocol TCP -LocalPort 22 -Action Allow | Out-Null }"
    ip=$("$AZ" vm show -d -g "$rg" -n "$name" --query publicIps -o tsv)
    ssh -i "$HOME/.ssh/azure2_ed25519" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "ddv@$ip" "echo ssh ok" < /dev/null
    ledger CREATE "ip $ip; next: arm-runner.sh prep $ip"
    ;;
  start) "$AZ" vm start -g "$rg" -n "$name" -o none; ledger START "ip $("$AZ" vm show -d -g "$rg" -n "$name" --query publicIps -o tsv)" ;;
  stop) "$AZ" vm deallocate -g "$rg" -n "$name" -o none; ledger STOP-DEALLOCATE "" ;;
  ip) "$AZ" vm show -d -g "$rg" -n "$name" --query publicIps -o tsv ;;
  state) "$AZ" vm get-instance-view -g "$rg" -n "$name" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv ;;
  *) echo "unknown step $step"; exit 2 ;;
esac
