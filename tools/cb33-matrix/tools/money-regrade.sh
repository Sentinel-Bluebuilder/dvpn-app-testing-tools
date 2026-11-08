#!/usr/bin/env bash
# ─── money-regrade.sh: grade a run's PENDING-REGRADE money rows from the chain ───
# A run whose run-end closes were skipped (no owner key on the box) writes run-end/money-pending.tsv instead of a grade
# (checks/money.sh). After the node's own redeem window, this re-reads each channel's on-chain `redeemed` and grades it
# with the same per-channel bound as checks/money.sh (spent - one step - 1 % .. spent + sessions x step + 1 %).
#
# Usage:  money-regrade.sh <money-pending.tsv>
# Env:    CBM_DIR   folder holding the sentinel-dvpn CLI under test (required)
#         CBM_RPC_URL  RPC to read from (optional; the CLI's own default otherwise). Never printed.
# Exit:   0 all PASS, 1 any FAIL or unreadable channel, 2 usage.
set -uo pipefail

PEND="${1:-}"
[ -f "$PEND" ] && [ -n "${CBM_DIR:-}" ] || { echo "usage: CBM_DIR=<cli dir> $0 <money-pending.tsv>" >&2; exit 2; }

HOME_TMP=$(mktemp -d)
trap 'rm -rf "$HOME_TMP"' EXIT
redeemed_of() { # $1 channel → on-chain redeemed, or empty
  "$CBM_DIR/sentinel-dvpn" --home "$HOME_TMP" channel show "$1" ${CBM_RPC_URL:+--rpc.url "$CBM_RPC_URL"} 2>/dev/null \
    | grep -oE '"redeemed": *[0-9]+' | head -1 | grep -oE '[0-9]+$'
}
ok() { # $1 spent $2 redeemed $3 step $4 sessions (same bound as money_channel_ok)
  awk -v s="$1" -v r="$2" -v w="$3" -v n="$4" 'BEGIN { tol = (s / 100 > 1 ? s / 100 : 1)
    lo = s - w - tol; if (lo < 0) lo = 0; exit !(r >= lo && r <= s + n * w + tol) }'
}

rc=0
while read -r line; do
  case "$line" in channel=*) ;; *) continue ;; esac
  ch=$(sed -nE 's/.*channel=([^ ]+).*/\1/p' <<<"$line"); p=$(sed -nE 's/.*proto=([^ ]+).*/\1/p' <<<"$line")
  s=$(sed -nE 's/.*spent=([0-9]+).*/\1/p' <<<"$line"); w=$(sed -nE 's/.*step=([0-9]+).*/\1/p' <<<"$line")
  n=$(sed -nE 's/.*sessions=([0-9]+).*/\1/p' <<<"$line")
  r=$(redeemed_of "$ch")
  if [ -z "$r" ]; then echo "UNREADABLE $ch ($p): redeemed not readable from chain"; rc=1
  elif ok "${s:-0}" "$r" "${w:-0}" "${n:-0}"; then echo "PASS $ch ($p): redeemed $r vs spent $s"
  else echo "FAIL $ch ($p): redeemed $r vs spent $s (step ${w:-0}, sessions ${n:-0})"; rc=1
  fi
  sleep 1
done < "$PEND"
exit "$rc"
