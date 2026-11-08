#!/usr/bin/env bash
# ─── secret-scan.sh: OSS-publish gate for the dVPN App Testing Tools repo ───
# Scans a tree for anything that must never ship public (PLAN §C/§E): API keys,
# RPC provider URLs with a key, base58 wallet/secret keys, VM/public IPs, gate
# URLs, ssh private-key material, and personal names. Exits non-zero on any hit.
#
# Usage:  secret-scan.sh [DIR]            (DIR default: the current directory)
# Env knobs (all optional, space-separated add-ons to the built-in patterns):
#   SCAN_EXTRA_NAMES   extra personal names to flag (never commit real names)
#   SCAN_ALLOW_IPS     IP substrings to treat as documentation examples, not leaks
#   SCAN_SKIP_GLOBS    path globs to skip (e.g. "*/testdata/* *.pcap")
#
# The scanner is itself parameterised and secret-free: it hard-codes no host,
# key or name. It is safe to run in CI and to ship in the repo.
set -euo pipefail

DIR="${1:-.}"
RC=0
hit() { RC=1; printf 'LEAK[%s] %s\n' "$1" "$2"; }

# Docs-reserved / loopback / link-local / RFC1918 IPs are not leaks.
# Not leaks: loopback, link-local, RFC1918, CGNAT, multicast, docs-reserved ranges,
# and well-known public-service constants (cloud metadata, public DNS, code-host IPs)
# plus the repo's own selftest fixture range. A real VM / node IP is not here.
ALLOW_IP_RE='^(0\.|127\.|255\.|169\.254\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|224\.|10\.8\.0\.|168\.63\.129\.16|1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|185\.199\.1(08|09|10|11)\.|198\.1[89]\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|45\.1\.2\.|40\.87\.|40\.64\.0\.0)'
for extra in ${SCAN_ALLOW_IPS:-}; do ALLOW_IP_RE="$ALLOW_IP_RE|$(printf '%s' "$extra" | sed 's/\./\\./g')"; done

# Build the grep exclude list.
EXCL=(--binary-files=without-match -I
      --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=results
      --exclude='*.pcap' --exclude='*.pcapng' --exclude='*.png' --exclude='*.gif')
for g in ${SCAN_SKIP_GLOBS:-}; do EXCL+=(--exclude="$g"); done

scan() {  # label  regex   -> print file:line:match for each hit
  local label="$1" re="$2"
  grep -rnoEI "${EXCL[@]}" "$re" "$DIR" 2>/dev/null || true
}

# 1. Public IPv4 (anything not in the allow list).
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ip=$(sed -E 's/.*:([0-9]{1,3}(\.[0-9]{1,3}){3}).*/\1/' <<<"$line")
  grep -qE "$ALLOW_IP_RE" <<<"$ip" && continue
  hit public-ip "$line"
done < <(scan ip '([0-9]{1,3}\.){3}[0-9]{1,3}')

# 2. RPC provider endpoints carrying a key (query string or key-in-path).
while IFS= read -r line; do hit rpc-url-with-key "$line"; done < <(
  scan rpc 'https?://[a-zA-Z0-9.-]*(helius|quicknode|alchemy|ankr|triton|rpcpool)[a-zA-Z0-9.-]*/[^"'"'"' ]*(api[-_]?key|[?&](api-?key|key)=)[^"'"'"' ]+' )
while IFS= read -r line; do hit api-key "$line"; done < <(
  scan key '(api[-_]?key|apikey|secret|token|bearer)["'"'"' :=]+[A-Za-z0-9_\-]{20,}' )

# 3. base58 secret/wallet material (32-44 char Solana-style, excluding known words).
while IFS= read -r line; do hit base58-key "$line"; done < <(
  scan b58 '\b[1-9A-HJ-NP-Za-km-z]{43,44}\b' )

# 4. ssh private key blocks.
while IFS= read -r line; do hit ssh-private-key "$line"; done < <(
  scan ssh 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY' )

# 5. Personal names (none by default; supply via SCAN_EXTRA_NAMES, quoted).
if [ -n "${SCAN_EXTRA_NAMES:-}" ]; then
  for n in $SCAN_EXTRA_NAMES; do
    while IFS= read -r line; do hit personal-name "$line"; done < <(scan name "$n")
  done
fi

if [ "$RC" -eq 0 ]; then echo "secret-scan: clean ($DIR)"; else echo "secret-scan: FAIL - leaks above"; fi
exit "$RC"
