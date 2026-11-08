#!/usr/bin/env bash
# ─── reclaim-run.sh: run one wallet's "run now" steps from a reclaim list, 7 s apart ───
# For a wallet whose key is held by the `sentinel-dvpn` CLI (its --home), e.g. the funder.
# Wallets with a key file can use `money.sh own` instead, which re-reads each account first.
#
#   reclaim-run.sh <reclaim.md> <wallet-label>         dry run: prints the commands
#   APPLY=1 reclaim-run.sh <reclaim.md> <wallet-label> runs them
#
# Required env (APPLY=1): DVPN_CLI (path to sentinel-dvpn), DVPN_HOME (its home dir with the key).
# Optional: LEDGER (one summary line per run), AGENT (name in that line, default reclaim-run),
#           GAP_S (seconds between txs, default 7, never lower).
#
# Only field 9 ("run now") is ever executed. Field 10 ("then, in order") holds the later steps
# with their wait written in front ("(after 7200 s) `…`"); passing that cell to the CLI fails
# with `unknown command "(after"`. A "run now" cell can also end in a note, e.g.
# "`… withdraw-user-balance` (as <label>, after its channels close)"; the note is cut off before
# running (it once failed as `unknown command "(as"`). After the wait, regenerate the list (`money.sh list`): the
# next step for each account's new state is then in "run now".
set -euo pipefail

LIST="${1:?usage: reclaim-run.sh <reclaim.md> <wallet-label>}"
LABEL="${2:?usage: reclaim-run.sh <reclaim.md> <wallet-label>}"
APPLY="${APPLY:-0}"
GAP_S="${GAP_S:-7}"; [ "$GAP_S" -ge 7 ] || GAP_S=7
AGENT="${AGENT:-reclaim-run}"
[ -r "$LIST" ] || { echo "cannot read $LIST" >&2; exit 2; }
if [ "$APPLY" = 1 ]; then
  : "${DVPN_CLI:?set DVPN_CLI (sentinel-dvpn binary)}"
  : "${DVPN_HOME:?set DVPN_HOME (the CLI home holding the wallet key)}"
fi

# Table rows: | # | wallet | kind | account | state | money | tag | run now | then |
#   awk -F'|' → $2 #, $3 wallet, $9 run now, $10 then.
mapfile -t rows < <(awk -F'|' -v want="$LABEL" '
  /^\| [0-9]+ \|/ {
    w = $3; sub(/^ +/, "", w); split(w, a, " ");
    if (a[1] != want) next;
    c = $9; gsub(/`/, "", c); sub(/ *\(.*\) *$/, "", c); gsub(/^ +| +$/, "", c);
    r = $2; gsub(/ /, "", r);
    print r "\t" c
  }' "$LIST")

ok=0; bad=0; skip=0
for line in "${rows[@]}"; do
  row="${line%%$'\t'*}"; cmd="${line#*$'\t'}"
  case "$cmd" in
    ''|-) skip=$((skip+1)); continue ;;
    'sentinel-dvpn '*) ;;
    *) echo "row $row SKIP not a command: ${cmd:0:60}"; skip=$((skip+1)); continue ;;
  esac
  args="${cmd#sentinel-dvpn }"
  if [ "$APPLY" != 1 ]; then echo "row $row would run: sentinel-dvpn $args"; continue; fi
  # shellcheck disable=SC2086  # the cell is a whitespace-separated argument list by construction
  if out=$("$DVPN_CLI" --home "$DVPN_HOME" --output json $args 2>&1); then
    ok=$((ok+1)); echo "row $row OK $(printf '%s' "$out" | grep -oE '"signature":"[^"]+"' | head -1 | cut -d'"' -f4 | cut -c1-12)"
  else
    bad=$((bad+1)); echo "row $row FAIL $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  fi
  sleep "$GAP_S"
done
echo "DONE $LABEL ok=$ok fail=$bad skip=$skip$([ "$APPLY" = 1 ] || echo ' (dry run)')"
if [ "$APPLY" = 1 ] && [ -n "${LEDGER:-}" ]; then
  printf -- '- %s %s reclaim run-now: %s ok=%s fail=%s\n' "$(date -u +%FT%TZ)" "$AGENT" "$LABEL" "$ok" "$bad" >> "$LEDGER"
fi
