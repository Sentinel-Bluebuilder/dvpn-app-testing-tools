#!/usr/bin/env bash
# ─── S5 Interrupts (PLAN §1b). Bodies: TLX 11-08. Platform-agnostic through plat_* hooks (README "S5 hooks"). ───
# A user or the OS interrupts a session at a bad moment; the daemon must come out clean every time: no live session
# it can't account for, no leftovers (the leftovers check runs after each scenario), egress direct or through the
# node (never dead), and the NEXT connect must work. Hooks a platform lacks make that cell SKIP (77), never PASS.
#   plat_cancel_connect <proto> <after_s> [new]   interrupt a connect after <after_s> s (the app's Cancel / ^C on the
#                                                 CLI); "new" forces a new channel so the cut lands in the deposit
#   plat_power_cut_mid_connect <proto> <after_s>  hard power loss mid-connect, box back up and daemon started
#   plat_reboot                                    reboot the test machine, return when the daemon is back (off-box)
#   plat_sleep <seconds>                           sleep/suspend the machine for <seconds>, then resume
#   plat_clock_jump <±seconds> / plat_clock_restore   step the wall clock, then put it back (NTP on again)
SCENARIOS="s5_cancel_connecting:off s5_disconnect_during_deposit:off s5_power_cut_mid_connect:off s5_reboot_ks_on:on s5_reboot_ks_off:off s5_sleep_resume:off s5_clock_jump_plus150:off s5_clock_jump_minus150:off"

s5_need() { local h; for h in "$@"; do declare -F "$h" > /dev/null || { echo "no $h on this platform"; return 77; }; done; }

# A channel for this entry first, so a cancel cuts the session start, not the first deposit (except where asked).
s5_warm() {
  [ -n "${CHANNELS[$NODE_ID]:-}" ] && return 0
  plat_connect "$1" || { echo "warm-up connect failed"; return 1; }
  sleep 3; plat_disconnect > /dev/null 2>&1; sleep 3
}

# Clean afterwards: no live session, egress direct, then a fresh connect carries traffic to the node.
s5_after_clean() { # $1 proto  $2 what happened (for the log)
  local live eg
  sleep 5
  live=$(plat_live_sessions 2>/dev/null | grep -c . || true)
  eg=$(plat_egress)
  echo "after $2: live sessions ${live:-?}, status $(plat_status_line), egress $eg (direct $DIRECT_IP)"
  [ "${live:-0}" = 0 ] || { echo "a session is still live after $2"; return 1; }
  [ "$eg" = "$DIRECT_IP" ] || { echo "egress not direct after $2: $eg"; return 1; }
  plat_connect "$1" || { echo "the next connect after $2 failed"; return 1; }
  sleep 4; eg=$(plat_egress); echo "next connect: egress $eg (node $NODE_EGRESS)"
  [ "$eg" = "$NODE_EGRESS" ] || return 1
  plat_disconnect
}

# Pending channels must resolve (open or closed), not hang: the deposit was cut mid-flight.
s5_no_pending_channel() {
  local i n
  for i in $(seq 1 12); do
    n=$(cli client channels 2>/dev/null | grep -cE '"status": *"pending"' || true)
    [ "${n:-0}" = 0 ] && { echo "no pending channel after $((i * 5)) s"; return 0; }
    sleep 5
  done
  echo "a channel is still pending 60 s after the cut deposit"; return 1
}

s5_cancel_connecting() {
  s5_need plat_cancel_connect || return $?
  s5_warm "$1" || return 1
  local r; r=$(plat_cancel_connect "$1" "${S5_CANCEL_AFTER:-2}"); echo "cancel: $r"
  s5_after_clean "$1" "a cancelled connect"
}

s5_disconnect_during_deposit() {
  s5_need plat_cancel_connect || return $?
  local r; r=$(plat_cancel_connect "$1" "${S5_DEPOSIT_AFTER:-3}" new); echo "cancel during deposit: $r"
  s5_no_pending_channel || return 1
  s5_after_clean "$1" "a connect cancelled during its deposit"
}

s5_power_cut_mid_connect() {
  s5_need plat_power_cut_mid_connect || return $?
  s5_warm "$1" || return 1
  local r; r=$(plat_power_cut_mid_connect "$1" "${S5_CUT_AFTER:-3}"); echo "power cut: $r"
  plat_daemon_running || plat_daemon_start || { echo "daemon not back after the power cut"; return 1; }
  s5_after_clean "$1" "a power cut mid-connect"
}

s5_reboot() { # $1 proto  $2 ks (for the log; the scenario's ks is already set and the daemon restarted)
  s5_need plat_reboot || return $?
  plat_connect "$1" || { echo "connect failed"; return 1; }
  sleep 4; echo "before reboot (ks=$2): egress $(plat_egress)"
  plat_reboot || { echo "the machine or the daemon did not come back"; return 1; }
  # After a reboot the old session can't be live; with ks=on the block must be gone (the daemon was not stopped by
  # the user, but a reboot ends the session and 'on' does not persist across it).
  s5_after_clean "$1" "a reboot with ks=$2"
}
s5_reboot_ks_on() { s5_reboot "$1" on; }
s5_reboot_ks_off() { s5_reboot "$1" off; }
# Checked by run_scenario before any check starts: without plat_reboot the cell is one SKIP row, not FAIL rows from
# checks that wrapped a body that never ran (u22 S5 11-08, ABW).
s5_reboot_ks_on_needs() { declare -F plat_reboot > /dev/null; }
s5_reboot_ks_off_needs() { declare -F plat_reboot > /dev/null; }

# Through a sleep or a clock step the session must come back by itself (same session or a redial) within 60 s, with
# status honest the whole time (the status check reads every second): egress = node at the end, nothing ended in error.
s5_back_by_itself() { # $1 what happened
  local i eg st
  for i in $(seq 1 30); do
    st=$(plat_status_line); eg=$(plat_egress)
    case $st in state=active*) [ "$eg" = "$NODE_EGRESS" ] && { echo "back after $((i * 2)) s: $st egress $eg"; return 0; } ;; esac
    sleep 1
  done
  echo "not back 60 s after $1: $st egress $eg"; return 1
}

s5_sleep_resume() {
  s5_need plat_sleep || return $?
  plat_connect "$1" || { echo "connect failed"; return 1; }
  sleep 4; local n0; n0=$(plat_sessions | grep -c .)
  echo "sleeping ${S5_SLEEP_S:-60} s: $(plat_sleep "${S5_SLEEP_S:-60}")"
  s5_back_by_itself "resume" || { plat_disconnect; return 1; }
  echo "sessions: $n0 -> $(plat_sessions | grep -c .) (a redial adds one)"
  plat_disconnect
}

s5_clock_jump() { # $1 proto $2 ±seconds
  s5_need plat_clock_jump plat_clock_restore || return $?
  plat_connect "$1" || { echo "connect failed"; return 1; }
  sleep 4; local n0 rc=0; n0=$(plat_sessions | grep -c .)
  echo "clock step $2 s: $(plat_clock_jump "$2")"
  s5_back_by_itself "a $2 s clock step" || rc=1
  sleep 30   # past the 30 s node timeout: a step must not end or redial the session later either
  s5_back_by_itself "a $2 s clock step (+30 s)" || rc=1
  echo "sessions: $n0 -> $(plat_sessions | grep -c .) (a redial adds one)"
  echo "clock restored: $(plat_clock_restore)"
  plat_disconnect
  return $rc
}
s5_clock_jump_plus150() { s5_clock_jump "$1" 150; }
s5_clock_jump_minus150() { s5_clock_jump "$1" -150; }
