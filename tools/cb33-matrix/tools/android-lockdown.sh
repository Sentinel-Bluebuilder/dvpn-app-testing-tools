#!/usr/bin/env bash
# ─── Android Always-on VPN + lockdown for the app, the product config for ks-on/persist cells (FWX/FAN 11-08) ───
# on:  Always-on for the app with "Block connections without VPN" (lockdown). Other apps' sockets opened before the
#      VPN (Play services :5228) can't go direct; without it the kill switch can't stop them (lockdown A/B 11-08).
# off: no Always-on. Use it for ks-off cells, and label ks-on cells run this way as the "lockdown off" variant:
#      their :5228 leak-inbound FAIL is the documented platform gap (the KS screen sends users to lockdown).
# Android reads the setting at user start, so a change reboots the emulator. Records the state in ~/.android-lockdown,
# which plat_init reports (ANDROID_LOCKDOWN).
# Usage: bash tools/android-lockdown.sh on|off|show
set -uo pipefail
PKG=${PKG:-network.sentinel.devnetdvpn}
cur() { echo "$(adb shell settings get secure always_on_vpn_app | tr -d '\r') $(adb shell settings get secure always_on_vpn_lockdown | tr -d '\r')"; }
case ${1:?on|off|show} in
  show) cur; exit 0 ;;
  on) want="$PKG 1" ;;
  off) want="null 0" ;;
  *) echo "on|off|show"; exit 2 ;;
esac
if [ "$(cur)" != "$want" ]; then
  if [ "$1" = on ]; then
    adb shell settings put secure always_on_vpn_app "$PKG"; adb shell settings put secure always_on_vpn_lockdown 1
  else
    adb shell settings delete secure always_on_vpn_app >/dev/null; adb shell settings put secure always_on_vpn_lockdown 0
  fi
  echo "rebooting the emulator so Android applies it"
  adb reboot; sleep 20; adb wait-for-device
  for _ in $(seq 1 90); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
  sleep 30
fi
echo "$1" > "$HOME/.android-lockdown"
echo "lockdown=$1 ($(cur))"
