#!/usr/bin/env bash
# ─── sol-topup: keep every test wallet above its minimum, paid from the funder ───
# Reads a wallet list (see wallets.example.txt):
#   <pubkey> <min_sol> <target_sol> <min_tdvpn> <target_tdvpn> <label>
# A wallet below a minimum is topped up to its target. 7 s between transactions; one ledger
# line per wallet funded. Stops before any transfer if the funder is under its reserve.
#
# Required env (values live outside the repo):
#   FUNDER_KEYFILE  funder key file (JSON). Read by the solana CLI only; never printed.
#   MINT            tDVPN mint (Token-2022)
#   WALLET_LIST     path to the wallet list
#   LEDGER          path to the append-only ledger (markdown lines)
# Optional env:
#   SOLANA_RPC_URL  default https://api.devnet.solana.com (devnet only: anything else is refused)
#   RESERVE_SOL     funder SOL floor (default 2)
#   SOLANA_BIN      dir holding solana / spl-token (default: from PATH)
#   APPLY=1         really send. Default is a dry run that prints what it would send.
#   AGENT           who ran it, written in the ledger lines (default funder)
set -euo pipefail

: "${FUNDER_KEYFILE:?set FUNDER_KEYFILE (funder key file, outside the repo)}"
: "${MINT:?set MINT (tDVPN mint)}"
: "${WALLET_LIST:?set WALLET_LIST (see wallets.example.txt)}"
: "${LEDGER:?set LEDGER (ledger file)}"
URL="${SOLANA_RPC_URL:-https://api.devnet.solana.com}"
RESERVE_SOL="${RESERVE_SOL:-2}"
APPLY="${APPLY:-0}"
AGENT="${AGENT:-funder}"
SOLANA="${SOLANA_BIN:+$SOLANA_BIN/}solana"
SPL="${SOLANA_BIN:+$SOLANA_BIN/}spl-token"

case "$URL" in *devnet*) ;; *) echo "devnet only: SOLANA_RPC_URL must be a devnet endpoint" >&2; exit 2 ;; esac
[ -r "$FUNDER_KEYFILE" ] || { echo "cannot read FUNDER_KEYFILE" >&2; exit 2; }
FUNDER=$("${SOLANA_BIN:+$SOLANA_BIN/}solana-keygen" pubkey "$FUNDER_KEYFILE")

sol_of() { "$SOLANA" balance -u "$URL" "$1" 2>/dev/null | awk 'NR==1{print $1+0}'; }
tok_of() { "$SPL" balance -u "$URL" --program-2022 --owner "$1" "$MINT" 2>/dev/null | awk 'NR==1{print $1+0}'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

fund_sol=$(sol_of "$FUNDER"); fund_sol=${fund_sol:-0}
fund_tok=$(tok_of "$FUNDER"); fund_tok=${fund_tok:-0}
echo "== sol-topup $(date -u +%FT%TZ) funder ${FUNDER:0:8}… ${fund_sol} SOL / ${fund_tok} tDVPN (reserve ${RESERVE_SOL} SOL)$([ "$APPLY" = 1 ] || echo ' DRY RUN')"
if lt "$fund_sol" "$RESERVE_SOL"; then echo "FUNDER LOW: under the reserve, no top-ups" >&2; exit 3; fi

grep -vE '^\s*(#|$)' "$WALLET_LIST" | while read -r pk min_s tgt_s min_t tgt_t label; do
  s=$(sol_of "$pk"); s=${s:-0}
  t=$(tok_of "$pk"); t=${t:-0}
  act=""
  if lt "$s" "$min_s"; then
    amt=$(awk -v a="$tgt_s" -v b="$s" 'BEGIN{printf "%.3f", a-b}')
    if [ "$APPLY" = 1 ]; then
      sig=$("$SOLANA" transfer -u "$URL" -k "$FUNDER_KEYFILE" --allow-unfunded-recipient "$pk" "$amt" 2>&1 | awk '/Signature/{print $2}')
      [ -n "$sig" ] || { echo "$label: SOL transfer failed" >&2; continue; }
      act="+${amt} SOL ${sig:0:10}"; sleep 7
    else act="would +${amt} SOL"; fi
  fi
  if lt "$t" "$min_t"; then
    amt=$(awk -v a="$tgt_t" -v b="$t" 'BEGIN{printf "%.2f", a-b}')
    if [ "$APPLY" = 1 ]; then
      sig=$("$SPL" transfer -u "$URL" --owner "$FUNDER_KEYFILE" --fee-payer "$FUNDER_KEYFILE" --program-2022 \
        --fund-recipient "$MINT" "$amt" "$pk" 2>&1 | awk '/Signature/{print $2}')
      [ -n "$sig" ] || { echo "$label: tDVPN transfer failed" >&2; continue; }
      act="$act +${amt} tDVPN ${sig:0:10}"; sleep 7
    else act="$act would +${amt} tDVPN"; fi
  fi
  printf '%-14s %s… sol=%-8s tdvpn=%-8s %s\n' "$label" "${pk:0:8}" "$s" "$t" "${act:-ok}"
  if [ -n "$act" ] && [ "$APPLY" = 1 ]; then
    printf -- '- %s %s sol-topup: %s %s %s\n' "$(date -u +%FT%TZ)" "$AGENT" "$label" "$pk" "$act" >> "$LEDGER"
  fi
done
