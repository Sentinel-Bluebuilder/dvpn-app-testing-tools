#!/system/bin/sh
# ─── Phone-side socket sampler (FAN 11-08): who owns each socket bound to the phone's own NIC address ───
# A socket whose local address is the Wi-Fi/Ethernet address talks outside the VPN; the uid column says
# which app. Run as root (reads every uid's sockets): cbm-socks.sh <out file> <grep -E pattern of hex addrs>
# Output lines: "<epoch> <the /proc/net/{tcp,tcp6,udp,udp6} line>", once a second until killed.
OUT=$1; PAT=$2
while :; do
  d=$(date +%s)
  for f in tcp tcp6 udp udp6; do grep -hE "$PAT" /proc/net/$f 2>/dev/null | sed "s/^/$d $f /"; done
  sleep 1
done > "$OUT"
