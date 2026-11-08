#!/usr/bin/env bash
# ─── Built-in check: money reconciles (PLAN §1a) ───
# Client spent <= paid; once the session is closed the node's settled amount is within 1 % (or 1 base unit) of spent,
# plus the prepay the client signs ahead by design (MONEY_PREPAY_ALLOW base units, set by the adapter from the
# config's prepay window x price x sessions; default 0 = strict). Never below spent. No false "node overcharging" end. The adapter reads the numbers (daemon CLI + chain read for the channel).

money_start() { MONEY_BEFORE=$(plat_money 2>/dev/null); echo "$MONEY_BEFORE" > "$SCEN_DIR/money-before.txt"; }

money_stop() {
  local m spent paid settled over
  m=$(plat_money 2>/dev/null); echo "$m" > "$SCEN_DIR/money-after.txt"
  [ -z "$m" ] && { result money SKIP "adapter returned no numbers"; return 0; }
  spent=$(sed -nE 's/.*spent=([0-9]+).*/\1/p' <<<"$m"); paid=$(sed -nE 's/.*paid=([0-9]+).*/\1/p' <<<"$m")
  settled=$(sed -nE 's/.*node_settled=([0-9]+).*/\1/p' <<<"$m")
  # cb33 redeems on chain only when the CHANNEL closes, never at a session stop (TS36 11-08), so a chain-read
  # node_settled stays 0 per scenario: the adapter then reports node_settled=unknown (judged once at run end, see
  # money_run_end) or reads the node's own usage record (plat/lab.sh). CBM_REDEEM_WAIT > 0 re-polls every 5 s for
  # an adapter whose settled value lands late.
  local waited=0
  while [ -n "$settled" ] && [ -n "$spent" ] && [ "$spent" -gt 0 ] && [ "$waited" -lt "${CBM_REDEEM_WAIT:-0}" ] &&
    awk -v s="$spent" -v n="$settled" 'BEGIN { exit !(n < s * 0.99) }'; do
    sleep 5; waited=$((waited + 5))
    m=$(plat_money 2>/dev/null); settled=$(sed -nE 's/.*node_settled=([0-9]+).*/\1/p' <<<"$m")
  done
  [ "$waited" -gt 0 ] && { echo "$m" > "$SCEN_DIR/money-after.txt"; echo "waited ${waited}s for the redeem" >> "$SCEN_DIR/money-after.txt"; }
  over=$(plat_cli_outputs 2>/dev/null | grep -ci 'overcharg' || true)
  if [ -n "$spent" ] && [ -n "$paid" ] && [ "$spent" -gt "$paid" ]; then
    result money FAIL "spent $spent > paid $paid"; return 0
  fi
  if [ -n "$settled" ] && [ -n "$spent" ]; then
    # plat_money runs in a subshell, so its MONEY_PREPAY_ALLOW is read from its output (TS36)
    local allow; allow=$(sed -nE 's/.*prepay_allow=([0-9]+).*/\1/p' <<<"$m"); allow=${allow:-${MONEY_PREPAY_ALLOW:-0}}
    if ! awk -v s="$spent" -v n="$settled" -v p="$allow" 'BEGIN { tol = (s / 100 > 1 ? s / 100 : 1); exit !(n >= s - tol && n <= s + p + tol) }'; then
      result money FAIL "node settled $settled vs client spent $spent (allowed $spent..$((spent + allow)) +/- 1 %)"; return 0
    fi
  fi
  [ "$over" -gt 0 ] && { result money FAIL "a 'node overcharging' message appeared"; return 0; }
  result money PASS "$m"
}

# money_run_end: the chain settle check, once per run. An adapter that keeps one channel per node entry defines
# plat_close_run_channels (close each, 7 s apart) and plat_money_run, which prints
# "spent=<sum over the run> node_settled=<redeemed on chain after the closes> prepay_allow=<N>".
money_run_end() {
  declare -F plat_money_run >/dev/null || return 0
  SCENARIO=run-end; SCEN_DIR=$OUT/run-end; mkdir -p "$SCEN_DIR"; SCENARIO_FAILED=0
  declare -F plat_close_run_channels >/dev/null && plat_close_run_channels > "$SCEN_DIR/close.txt" 2>&1
  # A channel that never closed has nothing to settle: its "node settled 0" says nothing about the product.
  local nl; nl=$(grep -c '^CLOSE-NOT-LANDED ' "$SCEN_DIR/close.txt" 2>/dev/null || true)
  # Closes skipped for want of the owner key (Q0475, deb12 final6): nothing was closed, so the node redeems on its own
  # schedule; graded at once it read "redeemed 0 vs spent 115", and the chain showed 115 a few minutes later.
  # Not a silent pass (#29): each channel is written to money-pending.tsv and named here, so tools/money-regrade.sh grades
  # it from the chain once the node's own redeem has landed. A real redeem-0 then still turns up as a FAIL.
  if grep -q '^CLOSE-SKIPPED-NO-KEY ' "$SCEN_DIR/close.txt" 2>/dev/null; then
    local pend ids
    declare -F plat_money_run_channels >/dev/null && plat_money_run_channels > "$SCEN_DIR/money-pending.tsv" 2>/dev/null
    pend=$(grep -c '^channel=' "$SCEN_DIR/money-pending.tsv" 2>/dev/null || true)
    ids=$(sed -nE 's/^channel=([^ ]+) proto=([^ ]+).*/\1(\2)/p' "$SCEN_DIR/money-pending.tsv" 2>/dev/null | tr '\n' ' ')
    PROTO=all result money SKIP "PENDING-REGRADE ${pend:-0} channel(s), closes skipped (no owner key on this box): run tools/money-regrade.sh $SCEN_DIR/money-pending.tsv after the node's redeem window: ${ids:-none listed}"
    return 0
  fi
  if [ "${nl:-0}" -gt 0 ]; then
    result money FAIL "cannot judge: the run-end close did not land on chain for $nl channel(s) (see run-end/close.txt; RPC rate limit?), so node settlement is not comparable; not a product bug"
    return 0
  fi
  # Graded per channel, under that channel's protocol, when the adapter can list them (FS36/DIR 11-08: the summed
  # row was labelled with the run's LAST protocol, so a hysteria2 gap read as "xray").
  declare -F plat_money_run_channels >/dev/null && { money_run_end_channels; return 0; }
  PROTO=all   # the sum covers every channel this run opened
  plat_money() { plat_money_run; }
  CBM_REDEEM_WAIT=${CBM_RUN_REDEEM_WAIT:-120} money_stop
}

# One channel's bound. Upper: spent + the prepay its sessions sign ahead (+1 %). Lower: spent - one top-up step
# (-1 %), not spent. The node redeems the highest WHOLE signed voucher the delivered service covers (fork a27ae32,
# Q0348), so it can land up to one voucher step below spent: node-4 hysteria2 108 spent / 90 redeemed while the
# other five channels landed on a voucher boundary. The client does not report its signed vouchers, so "highest
# voucher <= spent" is bounded by spent - step, step = one session's prepay window. Back to a strict lower bound
# once upstream #29 (metered partial redeem) ships.
money_channel_ok() { # $1 spent $2 redeemed $3 step $4 sessions
  awk -v s="$1" -v r="$2" -v w="$3" -v n="$4" 'BEGIN { tol = (s / 100 > 1 ? s / 100 : 1)
    lo = s - w - tol; if (lo < 0) lo = 0; exit !(r >= lo && r <= s + n * w + tol) }'
}

money_rows_bad() { # rows on stdin → how many are outside the bound
  local line s r w n bad=0
  while read -r line; do
    [ -n "$line" ] || continue
    s=$(sed -nE 's/.*spent=([0-9]+).*/\1/p' <<<"$line"); r=$(sed -nE 's/.*redeemed=([0-9]+).*/\1/p' <<<"$line")
    w=$(sed -nE 's/.*step=([0-9]+).*/\1/p' <<<"$line"); n=$(sed -nE 's/.*sessions=([0-9]+).*/\1/p' <<<"$line")
    [ -n "$s" ] && [ -n "$r" ] && ! money_channel_ok "$s" "$r" "${w:-0}" "${n:-0}" && bad=$((bad + 1))
  done
  echo "$bad"
}

# plat_money_run_channels prints one line per channel this run opened:
#   channel=<id> proto=<protocol> spent=<client> redeemed=<chain, or unknown> sessions=<N> step=<prepay window units>
money_run_end_channels() {
  local rows waited=0 line ch p s r w n over
  while :; do
    rows=$(plat_money_run_channels 2>/dev/null)
    [ "$(money_rows_bad <<<"$rows")" = 0 ] || [ "$waited" -ge "${CBM_RUN_REDEEM_WAIT:-120}" ] && break
    sleep 5; waited=$((waited + 5))
  done
  { echo "$rows"; [ "$waited" -gt 0 ] && echo "waited ${waited}s for the redeem"; } > "$SCEN_DIR/money-after.txt"
  [ -n "$rows" ] || { PROTO=all result money SKIP "adapter listed no channels"; return 0; }
  while read -r line; do
    [ -n "$line" ] || continue
    ch=$(sed -nE 's/.*channel=([^ ]+).*/\1/p' <<<"$line"); p=$(sed -nE 's/.*proto=([^ ]+).*/\1/p' <<<"$line")
    s=$(sed -nE 's/.*spent=([0-9]+).*/\1/p' <<<"$line"); r=$(sed -nE 's/.*redeemed=([0-9]+).*/\1/p' <<<"$line")
    w=$(sed -nE 's/.*step=([0-9]+).*/\1/p' <<<"$line"); n=$(sed -nE 's/.*sessions=([0-9]+).*/\1/p' <<<"$line")
    PROTO=${p:-unknown}
    if [ -z "$r" ]; then result money SKIP "channel $ch: redeemed not readable from chain"
    elif money_channel_ok "$s" "$r" "${w:-0}" "${n:-0}"; then result money PASS "$line"
    else result money FAIL "channel $ch: node redeemed $r vs client spent $s (allowed $((s > w ? s - w : 0))..$((s + ${n:-0} * ${w:-0})) +/- 1 %, step $w)"
    fi
  done <<<"$rows"
  over=$(plat_cli_outputs 2>/dev/null | grep -ci 'overcharg' || true)
  [ "${over:-0}" -gt 0 ] && PROTO=all result money FAIL "a 'node overcharging' message appeared"
  return 0
}

money_selftest() {
  SCEN_DIR=$OUT/selftest/money; mkdir -p "$SCEN_DIR"
  plat_money() { echo 'spent=2000 paid=1000 node_settled=unknown redeemed=unknown'; }   # planted
  plat_cli_outputs() { :; }
  SCENARIO_FAILED=0; SCENARIO=selftest-money money_stop
  [ "$SCENARIO_FAILED" = 1 ] && echo "money selftest: caught spent > paid" || echo "money selftest: MISSED spent > paid"
  plat_money() { echo "spent=120 paid=unknown node_settled=400 redeemed=400 prepay_allow=80"; }   # planted: settled past the prepay
  SCENARIO_FAILED=0; SCENARIO=selftest-money2 money_stop
  [ "$SCENARIO_FAILED" = 1 ] && echo "money selftest: caught settled past spent + prepay" || echo "money selftest: MISSED settled past spent + prepay"
  plat_money() { echo "spent=120 paid=unknown node_settled=196 redeemed=196 prepay_allow=80"; }   # control: inside the prepay
  SCENARIO_FAILED=0; SCENARIO=selftest-money3 money_stop
  [ "$SCENARIO_FAILED" = 0 ] && echo "money selftest: control inside the prepay passes" || echo "money selftest: MISSED (control inside the prepay failed)"
  # per channel: one voucher step below spent passes (node-4 hy2 108/90), more than a step below or past the prepay fails
  money_channel_ok 108 90 100 1 && echo "money selftest: whole-voucher redeem (108/90, step 100) passes" || echo "money selftest: MISSED (108/90 failed)"
  money_channel_ok 108 106 100 1 && echo "money selftest: exact-ish redeem passes" || echo "money selftest: MISSED (108/106 failed)"
  ! money_channel_ok 308 90 100 3 && echo "money selftest: caught more than a step under (308/90)" || echo "money selftest: MISSED 308/90"
  ! money_channel_ok 108 400 100 1 && echo "money selftest: caught redeemed past spent + prepay (108/400)" || echo "money selftest: MISSED 108/400"
}
