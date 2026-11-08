#!/usr/bin/env bash
# ─── cb33-matrix shared helpers (sourced by the driver; no side effects at source time) ───

# ─── Output ───
say() { echo "$(date -u +%T) $*" | tee -a "$OUT/run.log" >&2; }

# result <check> <PASS|FAIL|SKIP> <detail>  (uses SUITE SCENARIO PROTO from the driver)
result() {
  local check=$1 verdict=$2; shift 2
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${SUITE:-}" "${SCENARIO:-}" "${PROTO:-}" \
    "$check" "$verdict" "$(echo "$*" | tr '\t\n' '  ' | cut -c1-400)" >> "$OUT/results.tsv"
  [ "$verdict" = FAIL ] && SCENARIO_FAILED=1
  return 0
}

# ─── Downloads: route through the session's SOCKS proxy when it is a proxy-type protocol ───
# v2ray / xray sessions are a local SOCKS proxy, not a device tunnel, so a plain curl goes DIRECT by design: a
# throughput read then measures the box's own link (falsely fast) and a ks=on curl bypasses the tunnel and is
# dropped by the kill switch (a false core_ks FAIL) - Q0462, TLX2 11-08. cbm_download sends the request through the
# live session's proxy_endpoint when the adapter exposes one (plat_proxy_ep, empty for a real tunnel), matching the
# §2 rule that proxy egress must route through the session's proxy. Same args as curl after the implicit ones.
cbm_download() {
  local ep=''
  declare -F plat_proxy_ep >/dev/null && ep=$(plat_proxy_ep 2>/dev/null)
  if [ -n "$ep" ]; then curl --socks5-hostname "$ep" "$@"; else curl "$@"; fi
}

# ─── Time: monotonic milliseconds (wall clock jumps in S5 must not skew timings) ───
ms_mono() { awk '{printf "%d\n", $1 * 1000}' /proc/uptime 2>/dev/null || python3 -c 'import time;print(int(time.monotonic()*1000))'; }

# timed <var> <cmd...>: runs cmd, stores its elapsed ms in <var>, returns cmd's rc
timed() {
  local __v=$1 t0 rc; shift
  t0=$(ms_mono); "$@"; rc=$?
  printf -v "$__v" '%s' "$(( $(ms_mono) - t0 ))"
  return $rc
}

# ─── Chain etiquette: 7 s between txs per wallet ───
TX_GAP=${TX_GAP:-7}
LAST_TX_MS=0
tx_gap() {
  local now wait; now=$(ms_mono); wait=$(( TX_GAP * 1000 - (now - LAST_TX_MS) ))
  [ "$wait" -gt 0 ] && sleep "$(awk -v w="$wait" 'BEGIN{printf "%.1f", w/1000}')"
  LAST_TX_MS=$(ms_mono)
}

# ─── Deadman hold: keeps the VM's watchdog from rebooting / lets a cut be lifted remotely ───
deadman_start() {
  # The holder stops as soon as the driver is gone ($$ is the driver's pid, also inside this subshell). A plain
  # `while :` outlives a driver killed by a signal (bash skips the EXIT trap on SIGTERM) and keeps the dead-man
  # disarmed for good; that happened on r2 on 11-07 (FLX2).
  ( me=$$; while kill -0 "$me" 2>/dev/null; do sudo touch /run/ddv-deadman.hold 2>/dev/null; sleep 30; done ) &
  DEADMAN_PID=$!
}
deadman_stop() {
  [ -n "${DEADMAN_PID:-}" ] && kill "$DEADMAN_PID" 2>/dev/null; sudo rm -f /run/ddv-deadman.hold 2>/dev/null
  declare -F plat_mgmt_release > /dev/null && plat_mgmt_release   # the controller exemption ends with the run (linux)
  declare -F plat_hosts_release > /dev/null && plat_hosts_release   # the hostname pin ends with the run (linux)
  return 0
}

# ─── Small helpers ───
need() { declare -F "$1" >/dev/null || { say "adapter is missing $1 (see README contract)"; return 1; }; }
count_lines() { grep -c . <<<"${1:-}" || true; }  # count from text, never from a subshell variable

# ─── RPC lane (agents/RPC-PLAN.md): the test VMs use lane b ───
# Source the LANE file (it follows ctl-1's failover), never a raw key file. The key itself is never printed: the
# adapter's optional plat_set_rpc <rpc url> <ws url> puts it in the daemon's [rpc] url (not [tx.paymaster]) on the VM.
rpc_lane_init() {
  local f=${CBM_RPC_LANE_FILE:-$HOME/secrets/helius-lane-b.env}
  if [ -r "$f" ]; then
    # shellcheck disable=SC1090
    . "$f"
    say "   rpc: lane b (${RPC_LANE_SOURCE:-?}); the key stays in the lane file"
    if declare -F plat_set_rpc >/dev/null; then plat_set_rpc "$HELIUS_RPC_URL" "${HELIUS_WSS_URL:-}" || say "   rpc: plat_set_rpc failed, the daemon keeps its configured RPC"; fi
  else
    say "   rpc: no lane file at $f, the daemon keeps its configured RPC (public devnet)"
  fi
}

# rpc_summary: 429s seen in this run's logs (RPC-PLAN rule 6); the daemon's request count comes from the adapter
# when it has plat_rpc_requests.
rpc_summary() {
  local n429 req=unknown
  n429=$(cat "$OUT"/*/*/scenario.log "$OUT"/*/*/cli.txt 2>/dev/null | awk '/429|Too Many Requests/ { n++ } END { print n+0 }')
  declare -F plat_rpc_requests >/dev/null && req=$(plat_rpc_requests 2>/dev/null)
  say "== rpc: requests=$req 429s=$n429" | tee -a "$OUT/rpc.txt"
}

# ─── Program delegate preflight (TLX2 11-08) ──────────────────────────────────
# A freshly funded wallet cannot open any channel until it approves the program's
# token-2022 delegate allowance; the daemon draws escrow through that delegate, so
# with allowance 0 every open_channel fails "simulation failed: token-2022
# InsufficientFunds" even with dvpn in the wallet. The funding / device-setup step
# approves it (plat_delegate_approve); this guard FAILs the cell "cannot judge" (a
# blind row, not a product FAIL) whenever the allowance is below the escrow the
# cell is about to stake, so a missing delegate is never scored against the product.
CBM_DELEGATE_AMOUNT=${CBM_DELEGATE_AMOUNT:-unlimited}   # amount the funding step approves
_DELEGATE_MAXU64=18446744073709551615

# _delegate_judge <allowance> <escrow>: pure decision. rc 0 = ok to run, 1 = blind.
_delegate_judge() {
  local have=$1 esc=${2:-0}
  # The allowance sits on the token account of the client OWNER (root `owner` in c0's config.toml), which pays the
  # escrow; the owner's key approves it, not the device's operator key (TLX2 11-08).
  local hint="approve it with the owner's key: 'sentinel-dvpn wallet approve-delegate --amount-base-units unlimited' as the client owner"
  case "$have" in
    unlimited|"$_DELEGATE_MAXU64") return 0 ;;
    ''|*[!0-9]*)
      result delegate FAIL "cannot judge: program-delegate allowance unreadable — $hint (a 0 delegate fails open_channel with token-2022 InsufficientFunds; not a product bug)"
      return 1 ;;
  esac
  # An unlimited approval counts down from u64 max as escrows are drawn (e.g. 18446744073707651615); bash's [ -lt ]
  # rejects 20-digit numbers ("integer expression expected"), so any 19+ digit allowance counts as unlimited.
  [ ${#have} -ge 19 ] && return 0
  if [ "$have" -lt "$esc" ]; then
    result delegate FAIL "cannot judge: program-delegate allowance $have < escrow $esc — $hint (a low/zero delegate fails open_channel with token-2022 InsufficientFunds; not a product bug)"
    return 1
  fi
  return 0
}

# preflight_delegate [escrow]: read the wallet's current delegate allowance via the
# adapter and judge it. Platforms without plat_delegate_read opt out (no guard).
preflight_delegate() {
  local esc=${1:-${ESCROW:-100000}} have
  declare -F plat_delegate_read >/dev/null || return 0
  have=$(plat_delegate_read 2>/dev/null)
  _delegate_judge "$have" "$esc"
}

# delegate_selftest: the judge is pure, so no chain / funds are needed (SELFTEST).
delegate_selftest() {
  SUITE=selftest SCENARIO=selftest-delegate PROTO=-; local ok=1
  SCENARIO_FAILED=0; _delegate_judge 0         100000 && ok=0; [ "$SCENARIO_FAILED" = 1 ] || ok=0   # zero       -> blind
  SCENARIO_FAILED=0; _delegate_judge ''        100000 && ok=0                                        # unreadable -> blind
  SCENARIO_FAILED=0; _delegate_judge 50000     100000 && ok=0                                        # below      -> blind
  SCENARIO_FAILED=0; _delegate_judge 200000    100000 || ok=0; [ "$SCENARIO_FAILED" = 0 ] || ok=0    # above      -> runs
  SCENARIO_FAILED=0; _delegate_judge unlimited 100000 || ok=0                                        # unlimited  -> runs
  SCENARIO_FAILED=0; _delegate_judge 18446744073707651615 100000 || ok=0; [ "$SCENARIO_FAILED" = 0 ] || ok=0  # drawn-down u64 -> runs
  [ -z "$(_delegate_judge 18446744073707651615 100000 2>&1 >/dev/null)" ] || ok=0                    # ... with no bash "[: integer expression expected"
  [ "$ok" = 1 ] && echo "delegate selftest: zero/unreadable/below -> blind; above/unlimited/drawn-down u64 -> runs" \
                || echo "delegate selftest: MISSED the delegate preflight"
}
