#!/usr/bin/env bash
# ─── S12 App screens (PLAN §1b): a 15-min uifire pass + the static UI-CONTROLS check. Owner: TWA (Windows); FMC/FAN port. ───
# Covers Q0058, Q0290, Q0297, Q0309, Q0310, Q0317, Q0321, Q0324, Q0330, Q0339, Q0351, Q0386.
#
# The pass reuses the uifire cells (scripts/e2e/ui-controls-walk.cjs + the vm-uifire-{twa,twx,fwa}.ps1 launchers): each one
# drives the real app through CDP and prints `PASS|FAIL  uifire <name> (...) [cell:uifire:<name>]`. One PASS line per name =
# that screen works; a FAIL line or no line = the scenario fails. The built-in checks wrap the whole pass as usual.
#
# Windows only for now. Needs from plat/windows.sh (FWA): WIN_SSH (an ssh command line that reaches the VM as ddv), and
# a desktop VM (C:\ddv\DESKTOP, ddv logged on) with the app + C:\ddv\vm-run.ps1 + the launchers in C:\ddv.
# App screens don't depend on the protocol: ':once' runs each scenario on the first protocol only (driver, FWX 96bfe2a).
SCENARIOS="s12_uifire_pass_15min:off:once s12_ui_controls_static:off:once"

# name  launcher  extra-args  limit-min  — order matters: install first, the throwaway-profile onboarding next, money last.
S12_PASS="
install-service       vm-uifire-fwa.ps1  -                3
onboard-import        vm-uifire-twa.ps1  -                3
onboard-backup        vm-uifire-twa.ps1  -Capture         3
browse-app            vm-uifire-twx.ps1  -                2
connect-switch        vm-uifire-twa.ps1  -                4
ks-always             vm-uifire-twx.ps1  -                3
settings-apply        vm-uifire-twx.ps1  -                2
restore-network-home  vm-uifire-fwa.ps1  -                2
export-csv            vm-uifire-twx.ps1  -                2
activity-settle       vm-uifire-twa.ps1  -                3
wallet-withdraw       vm-uifire-twa.ps1  -                3
"
# What the plan lists → which name covers it: install → install-service; wallet → onboard-import; node list → browse-app;
# connect → connect-switch; KS + daemon restart → ks-always; disconnect + history → connect-switch + export-csv;
# settings → settings-apply; restore network → restore-network-home; money dialogs → activity-settle + wallet-withdraw;
# recovery phrase checked + hidden from capture → onboard-backup -Capture (Q0297 check-back, Q0324 display affinity).

# win_vmrun <test> <script> <args> <limit-min>: run a C:\ddv script as ddv in its desktop session, wait, print the log (UTF-8).
# vm-run.ps1 hands -ScriptArgs to cmd.exe as one quoted string: spaces are fine, '|' and '&' are not.
win_vmrun() {
  local t=$1 s=$2 a=$3 m=$4 i
  [ -n "${WIN_SSH:-}" ] || { echo "WIN_SSH is not set (plat/windows.sh plat_init)"; return 2; }
  $WIN_SSH "powershell -NoProfile -Command \"Remove-Item -Force -ErrorAction SilentlyContinue C:\\ddv\\$t.done, C:\\ddv\\$t.log\"" < /dev/null
  local st
  st=$($WIN_SSH "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\ddv\\vm-run.ps1 -Test $t -Script $s -ScriptArgs \"$a\" -Interactive ddv -LimitMinutes $((m + 2))" < /dev/null | tr -d '\r')
  echo "$st"
  grep -q '^BUSY' <<<"$st" && { echo "BLOCK  uifire ${a#-Name } VM busy with another test"; return 3; }
  for ((i = 0; i < (m + 3) * 6; i++)); do
    $WIN_SSH "powershell -NoProfile -Command Test-Path C:\\ddv\\$t.done" < /dev/null 2>/dev/null | grep -q True && break
    sleep 10
  done
  # PS *> logs are UTF-16; print them as UTF-8 so grep works
  $WIN_SSH "powershell -NoProfile -Command \"[Console]::OutputEncoding = [Text.Encoding]::UTF8; Get-Content -LiteralPath C:\\ddv\\$t.log\"" < /dev/null | tr -d '\r'
}

s12_uifire_pass_15min() {
  local name lch extra lim log bad=0 t0 refund
  t0=$(ms_mono)
  refund=$($WIN_SSH "powershell -NoProfile -Command Test-Path C:\\ddv\\REFUND" < /dev/null 2>/dev/null | tr -d '\r')
  while read -r name lch extra lim; do
    [ -n "$name" ] || continue
    [ "$extra" = - ] && extra=''
    if [ "$name" = wallet-withdraw ] && [ "$refund" != True ]; then
      result "uifire:$name" SKIP "no refundable balance on this wallet (C:\\ddv\\REFUND missing); the withdraw dialog needs one"; continue
    fi
    log=$(win_vmrun "s12-$name" "$lch" "-Name $name${extra:+ $extra}" "$lim")
    echo "$log" > "$SCEN_DIR/uifire-$name.log"
    if grep -qE "^PASS +uifire $name .*\[cell:uifire:$name\]" <<<"$log" && ! grep -qE "^FAIL +uifire $name\b" <<<"$log"; then
      result "uifire:$name" PASS "$(grep -m1 -E "^PASS +uifire $name" <<<"$log" | cut -c1-200)"
    else
      bad=1; result "uifire:$name" FAIL "$(grep -m1 -E "^(FAIL|BLOCK) +uifire $name" <<<"$log" | cut -c1-200)$(grep -qE "uifire $name" <<<"$log" || echo "no verdict line (see uifire-$name.log)")"
    fi
  done <<<"$S12_PASS"
  echo "pass took $(( ($(ms_mono) - t0) / 1000 )) s (target 900 s)"
  [ "$bad" = 0 ]
}

# The static check: every interactive control in the renderer has a documented UI-CONTROLS row (tests/unit/ui-controls.test.ts,
# the same scan as scripts/ui-controls-inventory.mjs). Runs on the VM's source tree (C:\ddv\src, built by the lab install).
s12_ui_controls_static() {
  local log
  log=$($WIN_SSH "powershell -NoProfile -Command \"Set-Location C:\\ddv\\src; npx vitest run tests/unit/ui-controls.test.ts 2>&1\"" < /dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')
  echo "$log" > "$SCEN_DIR/ui-controls.log"
  grep -qE "Test Files +1 passed" <<<"$log"
}
