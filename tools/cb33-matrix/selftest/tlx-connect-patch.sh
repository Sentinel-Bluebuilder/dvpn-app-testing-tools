#!/usr/bin/env bash
# ─── TLX override for plat/linux.sh plat_connect (proposed to FLX2; source AFTER plat/linux.sh) ───
# 1. fork-cb33-1 / cb33 `client start` has no --protocol: the protocol IS the node entry ($NODE_ID per protocol,
#    from lib/nodes.sh). Passing it made every connect fail with "unknown flag: --protocol" (tlx-u22 11-07 19:14Z).
# 2. A channel belongs to one node entry, so "one channel per run" becomes one channel per entry: CHANNELS[<entry>].
#    --channel on the driver still pins the FIRST entry's channel.
# 3. plat_capture_stop killed sudo's pid; Ubuntu 22.04's sudo does not relay that to tcpdump, so every capture kept
#    running (59 on tlx-u22, 11 GB). The capture now records tcpdump's own pid (exec keeps it) and is stopped by it.
plat_capture_start() {
  sudo sh -c 'echo $$ > "$1.pid"; exec tcpdump -i "$2" -nn -w "$1" -U' _ "$1" "$PHYS_IF" >/dev/null 2>&1 &
  CAP_FILE=$1; sleep 1
}
plat_capture_stop() {
  local p; p=$(sudo cat "$CAP_FILE.pid" 2>/dev/null)
  [ -n "$p" ] && sudo kill -INT "$p" 2>/dev/null
  local i; for i in 1 2 3 4 5; do [ -n "$p" ] && sudo kill -0 "$p" 2>/dev/null || break; sleep 1; done
  [ -n "$p" ] && sudo kill -KILL "$p" 2>/dev/null
  sudo rm -f "$CAP_FILE.pid"; sudo chmod a+r "$LEAK_PCAP" 2>/dev/null; return 0
}
declare -gA CHANNELS 2>/dev/null || true
plat_connect() {
  local proto=$1 out ch
  tx_gap
  ch=${CHANNELS[$NODE_ID]:-}
  [ -z "$ch" ] && [ -n "${CHANNEL:-}" ] && [ -z "${CHANNEL_ENTRY:-}" ] && { ch=$CHANNEL; CHANNEL_ENTRY=$NODE_ID; }
  if [ -n "$ch" ]; then
    out=$(cli client start --node "$NODE_ID" --channel "$ch")
  else
    out=$(cli client start --node "$NODE_ID" --new-channel --mode voucher --escrow-base-units "${ESCROW:-100000}")
    ch=$(grep -oE '"channel(_id)?": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$ch" ] && { CHANNEL_NEW=1; say "   opened channel $ch for $proto entry $NODE_ID (reused for this entry)"; }
  fi
  [ -n "$ch" ] && { CHANNELS[$NODE_ID]=$ch; CHANNEL=$ch; }
  SID=$(grep -oE '"(session_)?id": *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  [ -z "$SID" ] && SID=$(plat_sessions | head -1)
  [ -n "$SID" ]
}
