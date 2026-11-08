#!/usr/bin/env bash
# ─── Selftest: S9 airplane leak-skip gate (TLX S9 u22 11-08, ABW graded harness) ───
# Direct egress during/after the airplane drop is a LEAK only when the kill switch is meant to hold
# (CBM_EXPECT_BLOCKED=1); at ks=off (CBM_EXPECT_BLOCKED=0) going direct while reconnecting is by design, so the
# airplane leak verdict must be skipped. s9_leakcheck isolates that decision. Usage: bash selftest/s9.sh
set -u
cd "$(dirname "$0")/.." || exit 2

# load just the s9_leakcheck body from the suite (its closing brace is the first column-0 } after it).
eval "$(awk '/^s9_leakcheck\(\)/ { f=1 } f { print; if ($0 ~ /^}/) exit }' suites/S9.sh)"
if ! declare -F s9_leakcheck >/dev/null; then echo "MISSED: could not load s9_leakcheck from suites/S9.sh"; exit 1; fi

fails=0
want() { local name=$1 expect=$2 got; got=$3
  if [ "$got" = "$expect" ]; then echo "ok   $name: $got"; else echo "MISSED $name: got $got, wanted $expect"; fails=$((fails + 1)); fi
}
# ks=off: block is off, direct-while-reconnecting is by design -> do NOT run the leak verdict (0)
want "ks-off (EXPECT_BLOCKED=0): skip leak verdict" 0 "$(CBM_EXPECT_BLOCKED=0 s9_leakcheck)"
# ks=on / persist: the block must hold -> direct egress IS a leak, run the verdict (1)
want "ks-on (EXPECT_BLOCKED=1): enforce leak verdict" 1 "$(CBM_EXPECT_BLOCKED=1 s9_leakcheck)"
# unset (legacy/safety): default to enforcing the leak verdict (1), never silently skip
want "unset: default to enforce"                     1 "$(unset CBM_EXPECT_BLOCKED; s9_leakcheck)"

[ "$fails" = 0 ] && echo "s9 selftest: all cases as expected" || { echo "s9 selftest: $fails miss(es)"; exit 1; }
