#!/bin/bash
# ─── rpc-failover ───
# Run on the controller every 5 min (cron). Probes each RPC key file and points each lane file at a working key.
# A lane keeps its own key while that key is healthy; a dead key's lane moves to the healthiest other key.
# If every key is dead, the lanes point at public devnet. Never prints a key or URL.
#
# Settings (env):
#   SECRETS_DIR  dir holding rpc-<k>.env key files (each with RPC_URL= and WSS_URL=); lane files are written here too
#   KEYS         key/lane names, space-separated (default "a b c"); lane <k> prefers key <k>
#   LOG          log path (default ~/rpc-failover.log)
#   PUBLIC_RPC / PUBLIC_WSS  last-resort endpoints (default public devnet)
# Lane files: $SECRETS_DIR/rpc-lane-<k>.env, mode 600, holding RPC_URL, WSS_URL and RPC_LANE_SOURCE.
# Clients source a lane file, never a key file, so a switch needs no client change.
set -u
: "${SECRETS_DIR:?set SECRETS_DIR}"
KEYS="${KEYS:-a b c}"
LOG="${LOG:-$HOME/rpc-failover.log}"
PUBLIC_RPC="${PUBLIC_RPC:-https://api.devnet.solana.com}"
PUBLIC_WSS="${PUBLIC_WSS:-wss://api.devnet.solana.com}"

# ─── Probe: 3 getSlot calls; healthy = at least 2 of 3 answer in < 5 s (one slow reply must not flip lanes) ───
probe() {
  local url="$1" ok=0 i
  for i in 1 2 3; do
    curl -s -m 5 -X POST "$url" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' | grep -q '"result"' && ok=$((ok + 1))
    sleep 1
  done
  echo "$ok"
}

declare -A HEALTH
for k in $KEYS; do
  f="$SECRETS_DIR/rpc-$k.env"
  if [ -f "$f" ]; then HEALTH[$k]=$(probe "$(grep '^RPC_URL=' "$f" | cut -d= -f2-)"); else HEALTH[$k]=0; fi
done

best=""
for k in $KEYS; do [ "${HEALTH[$k]}" -ge 2 ] && { best="$k"; break; }; done

line="$(date -u +%FT%TZ) health"
for k in $KEYS; do line="$line $k=${HEALTH[$k]}"; done
for lane in $KEYS; do
  target="$SECRETS_DIR/rpc-lane-$lane.env"
  if [ "${HEALTH[$lane]}" -ge 2 ]; then src="rpc-$lane"
  elif [ -n "$best" ]; then src="rpc-$best"
  else src=public; fi
  (
    umask 077
    if [ "$src" = public ]; then
      printf 'RPC_URL=%s\nWSS_URL=%s\nRPC_LANE_SOURCE=public\n' "$PUBLIC_RPC" "$PUBLIC_WSS" > "$target.tmp"
    else
      { grep -E '^(RPC|WSS)_URL=' "$SECRETS_DIR/$src.env"; echo "RPC_LANE_SOURCE=$src"; } > "$target.tmp"
    fi
  )
  prev=$(grep '^RPC_LANE_SOURCE=' "$target" 2>/dev/null | cut -d= -f2)
  mv "$target.tmp" "$target"
  line="$line lane-$lane=$src"
  [ -n "$prev" ] && [ "$prev" != "$src" ] && line="$line(SWITCHED from $prev)"
done
echo "$line" >> "$LOG"
echo "$line"
