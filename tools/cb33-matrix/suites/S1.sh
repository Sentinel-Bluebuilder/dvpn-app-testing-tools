#!/usr/bin/env bash
# ─── S1 Core (PLAN §1b): connect, 50 MB, IP check, DNS check, IPv6 check, slow-reader download, disconnect ───
# Covers Q0011, Q0021/0233, Q0365, Q0421. Owner: FWX (Linux); platform owners port plat_* only.
SCENARIOS="s1_core:off s1_core_ks:on"

s1_body() {
  local proto=$1 eg dns ip6 t
  plat_connect "$proto" || { echo "connect failed"; return 1; }
  sleep 3
  eg=$(plat_egress); echo "egress $eg (node $NODE_EGRESS)"; [ "$eg" = "$NODE_EGRESS" ] || return 1
  dns=$(plat_dns_probe); echo "dns resolver $dns"
  ip6=$(plat_egress6); echo "ipv6 egress $ip6"   # must be none or the node's: the leak check sees any direct v6
  # Through the session's SOCKS proxy for proxy-type protocols (cbm_download); a plain curl would go direct and
  # measure the box's own link / be dropped by ks=on - Q0462. CBM_DL_URL is THE download target (DIR 11-08): it
  # defaults to a large public test file on a host that does NOT rate-limit (ash-speed.hetzner.com 100MB.bin;
  # speed.hetzner.de was RETIRED and no longer resolves, so the per-site host is used - verified 206 + 52428800
  # bytes from ctl-1, DIR+TLX2 11-09), fetched as a 50 MB byte range - speed.cloudflare.com was 429-throttling
  # node-4's egress IP (Q0473, TLX2: curl exit=0
  # http=429 bytes=1, through socks AND a real tunnel). A throttle is NO measurement, so s1_throughput grades a
  # 429/4xx/5xx as SKIP, never PASS and never the slow-link FAIL. Override CBM_DL_URL for a different file; a
  # query-sized URL (bytes=...) is fetched whole, a static file is 50 MB-ranged. CBM_BIG_URL is a back-compat alias.
  # s1_dl retries once on a curl error or a <1 MB body and logs the first failure as a visible DL-RETRY row (DIR).
  local url=${CBM_DL_URL:-${CBM_BIG_URL:-https://ash-speed.hetzner.com/100MB.bin}}
  local m rc bytes secs http bhdr=''
  case $url in *bytes=*) ;; *) bhdr='-r 0-52428799' ;; esac   # 50 MB range for a static file; query-sized fetched whole
  m=$(s1_dl 120 "$bhdr" "$url"); rc=$?; read -r bytes secs http <<<"$m"
  echo "50 MB download: curl exit=$rc http=${http:-?} bytes=${bytes:-?} secs=${secs:-?} url=${url%%\?*}"
  [ "$rc" = 0 ] || { echo "50 MB download failed (curl exit $rc)"; return 1; }
  s1_throughput "$proto" "$bytes $secs" "${http:-000}"
  # slow reader: 2 MB at 64 KB/s (Q0365: the tunnel must not stall a slow consumer). Same target; a range request so
  # a static file works without query-param sizing; CBM_SLOW_URL overrides (a query-sized URL is fetched whole).
  local surl=${CBM_SLOW_URL:-$url} sm src shdr=''
  case $surl in *bytes=*) ;; *) shdr='-r 0-1999999' ;; esac
  sm=$(s1_dl 90 "--limit-rate 64k $shdr" "$surl"); src=$?
  echo "slow reader: curl exit=$src $sm"
  # a throttle on the slow-reader is not a stall: skip it rather than fail the cell (Q0473).
  if [ "$src" = 0 ]; then case $(awk '{print $3}' <<<"$sm") in 429|4??|5??) echo "slow reader: upstream throttle, not measured" ;; esac
  else echo "slow reader failed (curl exit $src)"; return 1; fi
  plat_disconnect || { echo "disconnect failed"; return 1; }
  sleep 3
  eg=$(plat_egress); echo "after disconnect egress $eg (direct $DIRECT_IP)"; [ "$eg" = "$DIRECT_IP" ]
}
# s1_dl <max_s> "<extra curl args>" <url>: cbm_download with the diagnostic -w "<bytes> <seconds> <http_code>",
# retried ONCE on a curl error or a body under 1 MB (a transient upstream early-close/throttle). The first attempt
# failing is NOT hidden - it is printed as a greppable "DL-RETRY ..." row to the cell log (DIR 11-08) so any cell
# that needed a retry shows up in review; a retry is a signal to chase, never a silencer. The 1 MB floor is below
# the 2 MB slow-reader and 50 MB big, so a healthy cell never spuriously retries. Prints the returned attempt.
s1_dl() {
  local max=$1 extra=$2 url=$3 out rc i rb rs rh
  for i in 1 2; do
    out=$(cbm_download -sS -m "$max" $extra -o /dev/null -w "%{size_download} %{time_total} %{http_code}" "$url"); rc=$?
    [ "$rc" = 0 ] && [ "$(awk '{print ($1 >= 1000000)}' <<<"$out")" = 1 ] && break
    if [ "$i" = 1 ]; then read -r rb rs rh <<<"$out"
      # to stderr: this function's stdout is the captured result ("<bytes> <seconds> <http>"); the DL-RETRY row is a
      # log line (scenario.log), not part of the result, so it must not pollute $(s1_dl ...).
      echo "DL-RETRY ${url%%\?*} attempt=1 exit=$rc http=${rh:-?} bytes=${rb:-?} secs=${rs:-?} (retrying once)" >&2; sleep 2; fi
  done
  printf '%s' "$out"; return "$rc"
}

# s1_throughput <protocol> "<bytes> <seconds>" [http_code]: records MB/s and judges the floor (DIR 11-07: cb33
# AmneziaWG ran in-process at 0.46 MB/s against 33 MB/s, 72x slower, and no old check caught it).
#   - a throttle/error http_code (429 or any 4xx/5xx) => SKIP "throughput not measured": a throttled download is NO
#     measurement, never a PASS and never the slow-link FAIL (Q0473, TLX2 11-08: a 429 1-byte body had graded PASS).
#   - under 30 % of this run's WireGuard rate on the same box = FAIL  (CBM_WG_RATIO, default 0.30; 0 = off, e.g. a lab where WG is unusually fast)
#   - under 50 % of the A run's rate for this protocol = FAIL (CBM_A_THROUGHPUT=<A run's throughput.tsv>)
s1_throughput() {
  local proto=$1 bytes=${2%% *} secs=${2##* } http=${3:-200} mbps wg a verdict=PASS why=''
  case $http in 429|4??|5??) result throughput SKIP "throughput not measured: upstream HTTP $http (download throttled/failed, not the tunnel) - $bytes bytes in $secs s"; echo "throughput $proto: SKIP (upstream HTTP $http, $bytes bytes)"; return 0 ;; esac
  mbps=$(awk -v b="$bytes" -v s="$secs" 'BEGIN { printf "%.2f", (s > 0 ? b / s / 1e6 : 0) }')
  printf '%s\t%s\t%s\t%s\n' "$proto" "$mbps" "$bytes" "$secs" >> "$OUT/throughput.tsv"
  wg=$(awk -F'\t' '$1 == "wireguard" { v = $2 } END { print v }' "$OUT/throughput.tsv")
  if [ "$proto" != wireguard ] && [ -n "$wg" ] && awk -v m="$mbps" -v w="$wg" -v r="${CBM_WG_RATIO:-0.30}" 'BEGIN { exit !(r > 0 && m < r * w) }'; then
    verdict=FAIL; why="under ${CBM_WG_RATIO:-0.30} x WireGuard's $wg MB/s"
  fi
  if [ -n "${CBM_A_THROUGHPUT:-}" ] && [ -f "$CBM_A_THROUGHPUT" ]; then
    a=$(awk -F'\t' -v p="$proto" '$1 == p { v = $2 } END { print v }' "$CBM_A_THROUGHPUT")
    if [ -n "$a" ] && awk -v m="$mbps" -v x="$a" 'BEGIN { exit !(m < 0.50 * x) }'; then
      verdict=FAIL; why="${why:+$why; }under 50 % of the A run's $a MB/s"
    fi
  fi
  # absolute floor (TS36: 20 Mbit/s = 2.5 MB/s in the lab; CBM_MIN_MBPS in MB/s, unset = none)
  if [ -n "${CBM_MIN_MBPS:-}" ] && awk -v m="$mbps" -v f="$CBM_MIN_MBPS" 'BEGIN { exit !(m < f) }'; then
    verdict=FAIL; why="${why:+$why; }under the $CBM_MIN_MBPS MB/s floor"
  fi
  local rtx=''
  declare -F plat_tcp_retrans >/dev/null && rtx=$(plat_tcp_retrans 2>/dev/null)
  # connect, egress and DNS (small packets) already passed to get here: a slow bulk TCP is the full-MSS signature
  [ "$verdict" = FAIL ] && why="$why (small packets pass, bulk TCP is slow: likely an MTU/MSS black hole)"
  echo "throughput $proto: $mbps MB/s ($bytes bytes in $secs s)${rtx:+ retrans=$rtx}"
  result throughput "$verdict" "$mbps MB/s${wg:+ (WG $wg)}${a:+ (A $a)}${rtx:+ retrans=$rtx}${why:+: $why}"
}

s1_core() { s1_body "$1"; }
s1_core_ks() { s1_body "$1"; }

# ─── Windows recorder step scripts (ks-on) — plat/RECORDER-CONTRACT.md ───
# For a ks-on scenario the driver runs "<fn>_ps <PROTO>" on the driver to print a steps.ps1, which TWA's
# cbm-recorder.ps1 runs ON THE VM as SYSTEM (surviving the KS-on control-ssh cut) while it samples egress/state
# into status.tsv. steps.ps1 performs the scenario's ACTIONS only; the egress/leak/words checks read status.tsv
# afterward. Its exit code is the action rc (0 ok). The driver has already set NODE_ID (per protocol) via node_for.
# These run only on Windows (the driver gates on plat_record_start being defined) and are inert elsewhere.
s1_core_ks_ps() { # $1 proto (already encoded as $NODE_ID's entry)
  cat <<PS
\$ErrorActionPreference = 'Continue'
Set-Location '$WIN_DIR'
\$cli = '.\\sentinel-dvpn.exe'; \$h = '$WIN_DIR\\cli'; \$node = '$NODE_ID'; \$inst = '$INSTANCE'
\$o = & \$cli --home \$h client start --node \$node --new-channel --mode voucher --escrow-base-units ${ESCROW:-100000} --instance \$inst 2>&1 | Out-String
Write-Output \$o
if (\$LASTEXITCODE -ne 0) { Write-Output 'connect failed'; exit 1 }
Start-Sleep -Seconds 10
# exercise the tunnel so the recorder samples a real egress (50 MB; failure is not fatal to the action rc)
try { Invoke-WebRequest -Uri '${CBM_BIG_URL:-https://speed.cloudflare.com/__down?bytes=50000000}' -OutFile "\$env:TEMP\\s1dl.bin" -TimeoutSec 120 -UseBasicParsing | Out-Null } catch { Write-Output "download: \$_" }
Remove-Item "\$env:TEMP\\s1dl.bin" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
$(win_ps_stop_all)
Stop-AllSessions
Start-Sleep -Seconds 4
exit 0
PS
}
