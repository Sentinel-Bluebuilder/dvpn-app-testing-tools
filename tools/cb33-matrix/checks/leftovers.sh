#!/usr/bin/env bash
# ─── Built-in check: leftover state (PLAN §1a) ───
# After plat_reset: no service, firewall table/sublayer, ip rule, route, link, proxy, DNS rule, temp file or secret
# file left behind. The adapter lists them; any line is a FAIL.

# Captured once per VM (driver, after plat_init) so install-time state that predates any scenario — e.g. the
# TAP-Windows6 + Wintun adapters an OpenVPN MSI leaves installed — is not counted as a scenario leftover (TWA S1
# 11-08: these failed leftovers every x64 scenario; arm64 with no OpenVPN was clean). Only NEW lines are flagged.
leftovers_baseline() { plat_leftovers > "$OUT/leftovers-baseline.txt" 2>&1 || true; }

leftovers_start() { plat_leftovers > "$SCEN_DIR/leftovers-before.txt" 2>&1; }

leftovers_stop() {
  local left
  plat_reset >> "$SCEN_DIR/reset.log" 2>&1
  sleep 3
  left=$(plat_leftovers 2>&1)
  # Drop anything present in the pre-test baseline (install-time adapters etc.); flag only what this scenario left.
  [ -s "$OUT/leftovers-baseline.txt" ] && left=$(grep -Fxv -f "$OUT/leftovers-baseline.txt" <<<"$left" || true)
  printf '%s\n' "$left" > "$SCEN_DIR/leftovers-after.txt"
  if [ -z "$left" ]; then result leftovers PASS "clean after reset"
  else result leftovers FAIL "$(grep -c . <<<"$left" || true) left: $(head -2 <<<"$left" | tr '\n' ';')"; fi
}

leftovers_selftest() {
  SCEN_DIR=$OUT/selftest/leftovers; mkdir -p "$SCEN_DIR"
  plat_plant_leftover   # adapter plants one (e.g. an nft table named sentinel-dvpn-c9)
  SCENARIO_FAILED=0; SCENARIO=selftest-leftovers
  plat_reset() { :; }   # the planted item must survive to be seen
  leftovers_stop
  plat_unplant_leftover
  [ "$SCENARIO_FAILED" = 1 ] && echo "leftovers selftest: caught the planted leftover" || echo "leftovers selftest: MISSED the planted leftover"
}
