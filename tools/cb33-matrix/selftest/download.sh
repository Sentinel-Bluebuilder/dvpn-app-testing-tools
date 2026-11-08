#!/usr/bin/env bash
# ─── Selftest: cbm_download routes through the session SOCKS proxy (Q0462, TLX2 11-08) ───
# For a proxy-type protocol (plat_proxy_ep returns host:port) the download MUST go through the proxy, or a
# throughput read measures the box's own link and a ks=on fetch bypasses the tunnel. For a real tunnel
# (plat_proxy_ep empty) it is a plain curl. Stubs curl, loads the real cbm_download, asserts both.
# Usage (from ~/cb33-matrix): bash selftest/download.sh
set -u
cd "$(dirname "$0")/.." || exit 2

LOG=$(mktemp "${TMPDIR:-/tmp}/cbm-dl.XXXXXX")
fails=0
reset() { : > "$LOG"; }
curl() { echo "curl $*" >> "$LOG"; }   # stub: record the invocation, do not fetch

# the real cbm_download body from lib/common.sh (its closing brace is the first column-0 } after it).
eval "$(awk '/^cbm_download\(\)/ { f=1 } f { print; if (!h && $0 ~ /^}/) exit }' lib/common.sh)"
if ! declare -F cbm_download >/dev/null; then echo "MISS: could not load cbm_download from lib/common.sh"; exit 1; fi

has()  { grep -qF -- "$1" "$LOG"; }
want() { local what=$1 pat=$2; if has "$pat"; then echo "ok   $what"; else echo "MISS $what: '$pat' not in calls"; fails=$((fails + 1)); fi; }
nowant() { local what=$1 pat=$2; if has "$pat"; then echo "MISS $what: '$pat' should NOT appear"; fails=$((fails + 1)); else echo "ok   $what"; fi; }

# ── proxy-type protocol: plat_proxy_ep returns an endpoint -> route through it ──
reset; plat_proxy_ep() { echo "127.0.0.1:1080"; }
cbm_download -s -o /dev/null https://example.invalid/x
want   "proxy: --socks5-hostname with the endpoint" 'curl --socks5-hostname 127.0.0.1:1080 -s -o /dev/null https://example.invalid/x'

# ── real tunnel: plat_proxy_ep returns empty -> plain curl, no proxy ──
reset; plat_proxy_ep() { echo ""; }
cbm_download -s -o /dev/null https://example.invalid/x
want   "tunnel: plain curl, same args"              'curl -s -o /dev/null https://example.invalid/x'
nowant "tunnel: no proxy added"                     '--socks5-hostname'

# ── adapter without plat_proxy_ep at all -> plain curl ──
reset; unset -f plat_proxy_ep
cbm_download -s -o /dev/null https://example.invalid/x
want   "no hook: plain curl"                        'curl -s -o /dev/null https://example.invalid/x'
nowant "no hook: no proxy added"                    '--socks5-hostname'

rm -f "$LOG"
[ "$fails" = 0 ] && echo "download selftest: all cases as expected" || { echo "download selftest: $fails miss(es)"; exit 1; }
