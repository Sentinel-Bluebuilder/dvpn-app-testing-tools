#!/usr/bin/env bash
# ─── Selftest: plat_airplane keep-gate mode (DIR 11-08, TLX S9 37/50) ───
# The S9 airplane drop must not kill the client's RPC gate tunnel. With a gate-keep IP set, plat_airplane keeps
# the NIC up and nft-drops everything except lo + the gate host (RPC survives the cut); with none set it falls
# back to downing the NIC. This test stubs the privileged commands and asserts the real plat_airplane body builds
# the right thing in both modes. Usage (from ~/cb33-matrix): bash selftest/airplane.sh
set -u
cd "$(dirname "$0")/.." || exit 2

LOG=$(mktemp "${TMPDIR:-/tmp}/cbm-air.XXXXXX")
fails=0
reset() { : > "$LOG"; }

# stubs: sudo runs its argument (so the stubbed nft/ip/etc. below run); the rest just record their calls.
sudo() { "$@"; }
nft() { echo "nft $*" >> "$LOG"; if [ "${1:-}" = -f ] && [ "${2:-}" = - ]; then cat >> "$LOG"; fi; }
ip() { echo "ip $*" >> "$LOG"; }
systemd-run() { echo "systemd-run $*" >> "$LOG"; }
networkctl() { echo "networkctl $*" >> "$LOG"; }
systemctl() { echo "systemctl $*" >> "$LOG"; }

# the real plat_airplane body, extracted from the adapter. The nft heredoc has a column-0 } (the table close),
# so a plain /^}/ range truncates it; track the <<NFT..NFT heredoc and end only on a column-0 } outside it.
eval "$(awk '/^plat_airplane\(\)/ { f=1 }
             f { print; if ($0 ~ /<<NFT/) h=1; else if ($0 == "NFT") h=0; else if (!h && $0 ~ /^}/) exit }' plat/linux.sh)"
if ! declare -F plat_airplane >/dev/null; then echo "MISS: could not load plat_airplane from plat/linux.sh"; exit 1; fi

has()  { grep -qF -- "$1" "$LOG"; }
want() { local what=$1 pat=$2; if has "$pat"; then echo "ok   $what"; else echo "MISS $what: '$pat' not in calls"; fails=$((fails + 1)); fi; }
nowant() { local what=$1 pat=$2; if has "$pat"; then echo "MISS $what: '$pat' should NOT appear"; fails=$((fails + 1)); else echo "ok   $what"; fi; }

PHYS_IF=eth-test

# ── keep-gate mode: nft all-drop keeping lo + the gate, NIC stays up ──
reset; CBM_AIR_KEEP_IP=192.0.2.50 CBM_SLEEP_KEEP_IP= plat_airplane enable
want   "keep-enable: nft policy drop"        'policy drop'
want   "keep-enable: gate host kept (out)"   'ip daddr 192.0.2.50 accept'
want   "keep-enable: gate host kept (in)"    'ip saddr 192.0.2.50 accept'
want   "keep-enable: loopback kept"          'oifname "lo" accept'
nowant "keep-enable: NIC NOT downed"         'ip link set dev eth-test down'
want   "keep-enable: deadman lifts the drop" 'nft delete table inet cbmair'

# ── CBM_SLEEP_KEEP_IP is the fallback gate-keep source ──
reset; CBM_AIR_KEEP_IP= CBM_SLEEP_KEEP_IP=192.0.2.60 plat_airplane enable
want   "sleep-keep fallback: gate host kept" 'ip daddr 192.0.2.60 accept'
nowant "sleep-keep fallback: NIC NOT downed" 'ip link set dev eth-test down'

# ── disable: lift the nft block and bring the NIC up ──
reset; CBM_AIR_KEEP_IP=192.0.2.50 plat_airplane disable
want   "disable: nft table deleted"          'nft delete table inet cbmair'
want   "disable: NIC brought up"             'ip link set dev eth-test up'

# ── NIC-down mode (no gate-keep IP): fall back to downing the NIC, no nft table ──
reset; CBM_AIR_KEEP_IP= CBM_SLEEP_KEEP_IP= plat_airplane enable
want   "nic-down: NIC downed"                'ip link set dev eth-test down'
nowant "nic-down: no keep-gate nft table"    'table inet cbmair'

rm -f "$LOG"
[ "$fails" = 0 ] && echo "airplane selftest: all cases as expected" || { echo "airplane selftest: $fails miss(es)"; exit 1; }
