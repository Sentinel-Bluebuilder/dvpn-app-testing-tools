#!/usr/bin/env bash
# ─── money.sh: the reclaim pipeline and the books, driven by env (no values in the repo) ───
# The read/close/withdraw/sweep/books logic lives in the public Node Tester for Solana
# (scripts/ops/*.mjs, decoder + IDL included); this wraps it with the fleet's parameters.
#
#   money.sh list   [--after-final a,b] [--only kind,…] [--gap-ms 8000]   > reclaim.md   read-only
#   money.sh own    --channels a,b [--subs c,d] [--no-withdraw] [--dry-run]                one wallet
#   money.sh sweep  [--keep-sol 0.05] [--keep-tdvpn 1] [--apply]                           one wallet
#   money.sh books  --since 2026-11-07T00:00:00Z                           > books.md     read-only
#
# Required env:
#   TESTER_DIR      checkout of sentinel-solana-node-tester with `npm ci` done
#   FUNDER_PUBKEY   the funder's PUBLIC key (list, sweep, books)
#   WALLET_LIST     wallet list (list, books); format in wallets.example.txt
#   LEDGER          top-up ledger written by sol-topup.sh (books)
# Signing (own, sweep): the wallet's key comes on stdin (--key-stdin is added) so it never needs
# to sit next to the tool:   ssh <box> cat <keyfile> | money.sh own --channels …
# Optional: SOLANA_RPC_URLS (comma list, first wins; default public devnet). Devnet only.
set -euo pipefail

: "${TESTER_DIR:?set TESTER_DIR (sentinel-solana-node-tester checkout)}"
export SOLANA_NETWORK=devnet
cd "$TESTER_DIR"
need() { for v in "$@"; do [ -n "${!v:-}" ] || { echo "set $v" >&2; exit 2; }; done; }

cmd="${1:-}"; shift || true
case "$cmd" in
  list)  need FUNDER_PUBKEY WALLET_LIST
         exec node scripts/ops/reclaim-cb33.mjs --wallets "$WALLET_LIST" --funder "$FUNDER_PUBKEY" --gap-ms 8000 "$@" ;;
  own)   exec node scripts/ops/reclaim-own.mjs --key-stdin "$@" ;;
  sweep) need FUNDER_PUBKEY
         exec node scripts/ops/sweep-to-funder.mjs --funder "$FUNDER_PUBKEY" --key-stdin "$@" ;;
  books) need FUNDER_PUBKEY WALLET_LIST LEDGER
         exec node scripts/ops/books-cb33.mjs --wallets "$WALLET_LIST" --ledger "$LEDGER" --funder "$FUNDER_PUBKEY" "$@" ;;
  *) echo "usage: money.sh list|own|sweep|books [args]" >&2; exit 2 ;;
esac
