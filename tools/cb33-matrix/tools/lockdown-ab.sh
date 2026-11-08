#!/usr/bin/env bash
# ─── Lockdown A/B (FAN 11-08, DIR order): with the kill switch on, which other apps still go direct? ───
# Runs on the Android rig. Arms Android's Always-on VPN for the app with "Block connections without VPN" = $2
# (on|off; needs a reboot, API 35 reads it at user start), kill switch on, connects wireguard, then watches the
# phone's NIC for LOCKDOWN_S (default 90) s with the per-uid socket sampler and the capture: no egress probe runs
# inside the window, so the test harness adds no traffic of its own.
# Reports the direct sockets alive mid-session by uid (sockets.txt IN-WINDOW rows) minus the app's own uid
# (outside the VPN by design, D-A2), and the capture's packets outside the tunnel.
# Usage: bash lockdown-ab.sh <label> on|off   → ~/lockdown-ab/<label>/
set -uo pipefail
LABEL=${1:?label}; LOCK=${2:?on|off}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HOME/lockdown-ab/$LABEL; mkdir -p "$OUT"; SCEN_DIR=$OUT; LEAK_PCAP=$OUT/phys.pcap
NODE=${LOCK_NODE:-node-3}
say() { echo "$*"; }
tx_gap() { sleep "${TX_GAP:-7}"; }
deadman_start() { :; }; deadman_stop() { :; }
. "$HERE/lib/nodes.sh"
. "$HERE/plat/android.sh"
PKG=${PKG:-network.sentinel.devnetdvpn}

want=$([ "$LOCK" = on ] && echo 1 || echo 0)
[ "$LOCK" = on ] && export CBM_LOCKDOWN=1
if [ "$(adb shell settings get secure always_on_vpn_app | tr -d '\r')" != "$PKG" ] ||
   [ "$(adb shell settings get secure always_on_vpn_lockdown | tr -d '\r')" != "$want" ]; then
  # A arm = Always-on without lockdown (tools/android-lockdown.sh off has no Always-on at all).
  adb shell settings put secure always_on_vpn_app "$PKG"
  adb shell settings put secure always_on_vpn_lockdown "$want"
  echo "rebooting the emulator so Android applies Always-on (lockdown=$want)"
  adb reboot; sleep 20; adb wait-for-device
  for _ in $(seq 1 90); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2; done
  sleep 30
fi
adb shell dumpsys connectivity 2>/dev/null | grep -iE "lockdown|always" | head -5 > "$OUT/system-vpn.txt"
plat_init >/dev/null || { echo "plat_init failed"; exit 2; }
RUN_START_CHANNELS=$(sess_rows | awk '{print $3}' | sort -u | tr '\n' ' '); RUN_NEW_CHANNELS=''
OUT_SAVE=$OUT; node_resolve || { echo "could not resolve $NODE's entries from chain"; exit 2; }; OUT=$OUT_SAVE
NODE_ID=$(awk '$1 == "wireguard" {print $2; exit}' "$OUT/node-entries.txt")
python3 "$HOOK" --env DVPN_KEYFILE="$APP_FILES/test/owner.json" cli daemon set --kill-switch on --yes >/dev/null 2>&1; sleep 10
echo "build: $(plat_build)  lockdown=$LOCK ks=on node=$NODE_ID" | tee "$OUT/build.txt"
plat_connect wireguard >/dev/null || { echo "connect failed"; exit 1; }
eg=$(plat_egress); echo "egress connected: $eg (node $NODE_EGRESS)" | tee -a "$OUT/build.txt"
sleep 3
t0=$(date +%s); plat_capture_start
sleep "${LOCKDOWN_S:-90}"
t1=$(date +%s); echo "$t0 $t1" > "$OUT/active-windows.txt"
plat_capture_stop
plat_disconnect >/dev/null 2>&1
python3 "$HOOK" --env DVPN_KEYFILE="$APP_FILES/test/owner.json" cli daemon set --kill-switch off --yes >/dev/null 2>&1
app_uid=$(grep -F "$PKG " "$UID_MAP" | grep -o 'uid:[0-9]*' | head -1 | tr -dc 0-9)
# IN-WINDOW rows not from the app's own uid and not the LAN (DHCP to the emulator's gateway).
grep IN-WINDOW "$OUT/sockets.txt" | grep -v "uid=${app_uid:-10216} " | grep -v " 10\.0\.2\.[0-9]*:" > "$OUT/direct-sockets.txt"
pk=$(tcpdump -nr "$LEAK_PCAP" 2>/dev/null | grep -v " $NODE_EGRESS\.\| > $NODE_EGRESS\." | grep -c . || true)
# non_node_packets also holds the app's own direct traffic (RPC, node API by name): informational only.
printf 'label\tlockdown\tdirect_sockets\tnon_node_packets\n%s\t%s\t%s\t%s\n' "$LABEL" "$LOCK" "$(grep -c . "$OUT/direct-sockets.txt")" "$pk" | tee "$OUT/summary.tsv"
cat "$OUT/direct-sockets.txt"
plat_close_run_channels
