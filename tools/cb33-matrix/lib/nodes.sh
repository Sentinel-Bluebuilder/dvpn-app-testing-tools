#!/usr/bin/env bash
# ─── Node entries from chain (DIR 11-07): one listed entry per protocol, each with its own port ───
# Never a fixed port or address map: at run start one `node show` (owner) + one `node search --owner` (cached in
# $OUT/node-entries.json) give the entry per protocol, matched by the SDK protocol bits:
#   wireguard 1<<0, v2ray 1<<1, openvpn 1<<2, amneziawg 1<<3, xray 1<<4, hysteria2 1<<5 (sentinel-go-sdk/<proto>)
# The driver then sets NODE_ID / NODE_PORT for each scenario's protocol.

node_chain_cli() {
  if declare -F plat_chain_cli >/dev/null; then plat_chain_cli "$@"
  else "${CBM_CLI:-sentinel-dvpn}" ${HELIUS_RPC_URL:+--rpc.url "$HELIUS_RPC_URL"} "$@"; fi
}

# node_entries_parse <search json> → "protocol address host port" per listed entry
node_entries_parse() {
  python3 -I - "$1" <<'PY'
import json, sys, urllib.parse
bits = {1: 'wireguard', 2: 'v2ray', 4: 'openvpn', 8: 'amneziawg', 16: 'xray', 32: 'hysteria2'}
for e in json.load(open(sys.argv[1])):
    v = e.get('value', {})
    if v.get('status') != 1:
        continue
    u = urllib.parse.urlsplit(v.get('uri', ''))
    for b, name in bits.items():
        if v.get('protocols', 0) & b:
            print(name, e['address'], u.hostname, u.port)
PY
}

node_resolve() {
  local owner f="$OUT/node-entries.json"
  NODE_SEED=$NODE_ID
  if [ ! -s "$f" ]; then
    owner=$(node_chain_cli node show "$NODE_SEED" 2>/dev/null | sed -nE 's/.*"owner": *"([1-9A-HJ-NP-Za-km-z]+)".*/\1/p' | head -1)
    [ -n "$owner" ] || { say "   nodes: could not read $NODE_SEED from chain"; return 1; }
    node_chain_cli node search --owner "$owner" 2>/dev/null > "$f" || { say "   nodes: search failed"; return 1; }
  fi
  node_entries_parse "$f" > "$OUT/node-entries.txt" || return 1
  [ -s "$OUT/node-entries.txt" ] || { say "   nodes: no listed entry for $NODE_SEED's owner"; return 1; }
  say "   nodes (chain): $(awk '{ printf "%s=%s ", $1, $4 }' "$OUT/node-entries.txt")"
}

# node_for <protocol>: sets NODE_ID and NODE_PORT to that protocol's entry; rc 1 when the node does not offer it
node_for() {
  local row; row=$(awk -v p="$1" '$1 == p { print; exit }' "$OUT/node-entries.txt")
  [ -n "$row" ] || return 1
  read -r _ NODE_ID NODE_IP NODE_PORT <<<"$row"   # the host too: chain, not the adapter default
}

nodes_selftest() {
  local f; f=$(mktemp); : > "$OUT/selftest-nodes.txt"
  # planted: two hosts whose ports per protocol differ; the resolver must follow the bits, not a port order
  cat > "$f" <<'J'
[{"address":"AAA","value":{"status":1,"protocols":1,"uri":"https://192.0.2.1:18711"}},
 {"address":"BBB","value":{"status":1,"protocols":8,"uri":"https://192.0.2.1:18712"}},
 {"address":"CCC","value":{"status":1,"protocols":4,"uri":"https://192.0.2.1:18716"}},
 {"address":"DDD","value":{"status":2,"protocols":32,"uri":"https://192.0.2.1:18714"}}]
J
  local got; got=$(node_entries_parse "$f" | tr '\n' ';'); rm -f "$f"
  if [ "$got" = "wireguard AAA 192.0.2.1 18711;amneziawg BBB 192.0.2.1 18712;openvpn CCC 192.0.2.1 18716;" ]; then
    echo "nodes selftest: entries follow the chain bits (delisted skipped)"
  else
    echo "nodes selftest: MISSED (got $got)"
  fi
  # planted check: no code may carry a fixed node port
  local hard; hard=$(grep -rnE '\b187[0-9]{2}\b' "$HERE"/cb33-matrix.sh "$HERE"/lib "$HERE"/checks "$HERE"/plat "$HERE"/suites 2>/dev/null | grep -v '192\.0\.2\.1')
  if [ -z "$hard" ]; then echo "nodes selftest: no hard-coded node port in the code"
  else echo "nodes selftest: MISSED a hard-coded node port: $(head -1 <<<"$hard")"; fi
}
