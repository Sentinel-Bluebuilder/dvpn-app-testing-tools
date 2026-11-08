#!/usr/bin/env bash
# ─── Built-in check: leak sampler (PLAN §1a) ───
# Captures on the real NIC for the whole scenario. KS persist (first active window → last, gaps included) / on (active windows only): nothing may leave PHYS_IF except to the node, DHCP,
# IPv6 ND and the LAN gateway. KS off: no DNS (53/853) and no IPv6 to anywhere but the node while a session is active.

leak_start() {
  LEAK_PCAP="$SCEN_DIR/phys.pcap"
  plat_capture_start "$LEAK_PCAP"
}

# leak_stop <ks mode during the scenario>
leak_stop() {
  local ks=${1:-off} filter n
  [ "${LEAK_OFFLINE:-0}" = 1 ] || plat_capture_stop   # recorder mode: the capture is already collected
  [ -s "$LEAK_PCAP" ] || { result leak SKIP "no capture (adapter returned no pcap)"; return 0; }
  # Allowed on the wire in every mode: the node, DHCP, ND/RS/RA, ARP (not IP), the gateway itself.
  filter="not host $NODE_IP and not (udp port 67 or udp port 68 or udp port 546 or udp port 547)"
  # ND (133-137) and MLD (130-132 query/report/done, 143 report v2) are link-local IPv6 housekeeping to ff02::,
  # not a leak. Before this, type-143 listener reports to ff02::16 were counted as leaks (TWA 11-07).
  filter="$filter and not (icmp6 and ((ip6[40] >= 130 and ip6[40] <= 137) or ip6[40] == 143))"
  # The type match above uses a fixed ip6[40] offset, which misses MLD carrying a Hop-by-Hop Router Alert header
  # (as most MLD does) — that is why a Windows ks-on run still counted 29-38 fe80::->ff02::16 MLDv2 packets (TWA S1
  # 11-08). Exclude by destination too: link-local multicast (ff02::/16) never leaves the link, never a leak.
  filter="$filter and not (ip6 and dst net ff02::/16)"
  [ -n "${GATEWAY_IP:-}" ] && filter="$filter and not host $GATEWAY_IP"
  # The harness's own control channel (ssh from ctl-1) is not a leak.
  [ -n "${CONTROL_IP:-}" ] && filter="$filter and not host $CONTROL_IP"
  # The cloud host channels the box's own agents use (Azure wireserver, metadata; TLX 11-07). Set it empty to count them.
  for h in ${LEAK_ALLOW_HOSTS-168.63.129.16 169.254.169.254}; do filter="$filter and not host $h"; done
  # Only what this box sends is a leak. Inbound packets (cloud platform probes: Azure 40.80/40.87.x:23456 SYN-ACKs,
  # TLX 11-08) are not; PHYS_ADDRS (the NIC's own addresses, set by the adapter) keeps the sent side only.
  local srcf=''
  for a in ${PHYS_ADDRS:-}; do srcf="${srcf:+$srcf or }src host $a"; done
  [ -n "$srcf" ] && filter="$filter and ($srcf)"
  # The daemon's own RPC/WS addresses (LEAK_RPC_HOSTS, from its [rpc] url / ws_url) are on the kill switch's
  # allowlist by design (endpoints.go), so they are not a KS leak. While a full tunnel is up they still should
  # not appear on the NIC: that is a pooled connection from before the tunnel (upstream #6), reported as its own
  # rpc-direct row.
  local rpcf=''
  # Re-resolve at stop and keep the union: an RPC name can answer with another address mid-scenario (anycast),
  # which then counted as a KS leak on persist rows (TLX 11-08: 192.0.2.6:443 on S2 daemon_term_persist).
  if declare -F plat_rpc_hosts >/dev/null && [ "${LEAK_OFFLINE:-0}" != 1 ]; then
    LEAK_RPC_HOSTS=$(printf '%s
' ${LEAK_RPC_HOSTS:-} $(plat_rpc_hosts) | sort -u | tr '
' ' ')
  fi
  for h in ${LEAK_RPC_HOSTS:-}; do filter="$filter and not host $h"; rpcf="${rpcf:+$rpcf or }host $h"; done
  if [ -n "$rpcf" ] && [ -s "$SCEN_DIR/active-windows.txt" ]; then
    local r; r=$(leak_in_windows "" "$SCEN_DIR/active-windows.txt" "$rpcf")
    if [ "$r" = 0 ]; then result rpc-direct PASS "no RPC packet on the NIC while active"
    else result rpc-direct FAIL "$r RPC packet(s) on the NIC while active (pooled pre-tunnel connection, upstream #6)"; fi
  fi
  if [ "$ks" = off ]; then
    # KS off: only DNS and IPv6 count, and only while the session said active (the status poller writes the windows).
    filter="($filter) and (port 53 or port 853 or ip6)"
  fi
  tcpdump -nn -r "$LEAK_PCAP" "$filter" 2>/dev/null > "$SCEN_DIR/leak.txt"
  n=$(grep -c . "$SCEN_DIR/leak.txt" || true)
  # Where the block must hold (DIR 11-08; cb33 arms the kill switch with a session, session.go:686-703):
  #   off / on: inside each active window (a graceful stop lifts "on");
  #   persist:  from the first active window's start to the last one's end, so a daemon kill/term/restart gap
  #             between windows counts, and packets before the first session do not (persist is not a boot lockdown).
  # No active window (the session never came up) means nothing counts: before TLX 11-08 an empty window file
  # fell through to the whole-scenario count (9142 "leaks" for an awg session that never started).
  local edge=0 wins="$SCEN_DIR/active-windows.txt"
  if [ "$ks" = persist ] && [ -s "$wins" ]; then
    awk 'NR == 1 || $1 < s { s = $1 } NR == 1 || $2 > e { e = $2 } END { print s, e }' "$wins" > "$SCEN_DIR/persist-window.txt"
    wins="$SCEN_DIR/persist-window.txt"
  fi
  if [ ! -s "$wins" ]; then
    n=0
  elif [ "$n" -gt 0 ]; then
    # A window edge is only as exact as the 1 s status poll. Packets within LEAK_EDGE_S of an edge are a
    # state-change skew (the status check judges whether status was honest there): reported, not a leak.
    local e=${LEAK_EDGE_S:-2} all
    all=$(leak_in_windows "$SCEN_DIR/leak.txt" "$wins" "$filter")
    n=$(LEAK_MARGIN=$e leak_in_windows "$SCEN_DIR/leak.txt" "$wins" "$filter")
    edge=$(( all - n ))
  fi
  # Inbound side (DIR 11-08, FMC G30): a macOS KS leak showed only as completed handshakes and inbound app data
  # from public hosts. Where the block must hold, any of those inside the window is a FAIL of its own.
  if [ "$ks" != off ] && [ "${CBM_EXPECT_BLOCKED:-}" != 0 ]; then leak_inbound "$ks" "$wins"; fi
  # S2 lift-vs-hold (CBM_EXPECT_BLOCKED, set by the driver per scenario; unset => legacy ks-only behaviour):
  # when the scenario expects the block LIFTED (a TERM that releases the kill switch), direct egress is the
  # correct outcome, not a leak. When it expects the block HELD (persist / a KILL crash), fall through and count.
  if [ "${CBM_EXPECT_BLOCKED:-}" = 0 ]; then
    result leak PASS "block lifted (expected): direct egress is correct, not a leak ($n direct packet(s) seen)"
    [ "$edge" -gt 0 ] && result leak-edge WARN "ks=$ks: $edge packet(s) within ${LEAK_EDGE_S:-2} s of an active-window edge"
    return 0
  fi
  if [ "$n" = 0 ]; then result leak PASS "ks=$ks: no packet outside the tunnel"
  else result leak FAIL "ks=$ks: $n packet(s) outside the tunnel, first: $(head -1 "$SCEN_DIR/leak.txt")"; fi
  [ "$edge" -gt 0 ] && result leak-edge WARN "ks=$ks: $edge packet(s) within ${LEAK_EDGE_S:-2} s of an active-window edge"
  return 0
}

# leak_inbound <ks> <windows file> → one leak-inbound row.
# Counts packets TO the NIC's own addresses (PHYS_ADDRS) from a public host that is not on the allowlist, and
# only the shapes that prove a flow the box took part in:
#   - a TCP SYN-ACK to a local ephemeral port (the box sent the SYN);
#   - TCP data (payload > 0; it needs a completed handshake);
#   - UDP data that looks like a reply: from a service port (1-1023) to a local ephemeral port.
# A bare inbound SYN, RST or a UDP probe to a local service port is a scanner, not a leak: PASS.
# The allowlist is the outbound one (node, DHCP, gateway, control, LEAK_ALLOW_HOSTS, RPC hosts), plus private and
# link-local sources, plus LEAK_INBOUND_ALLOW (default: the Azure platform probes, 40.64.0.0/10 from port 23456).
leak_inbound() {
  local ks=$1 wins=$2 f dst='' a n all edge e
  for a in ${PHYS_ADDRS:-}; do dst="${dst:+$dst or }dst host $a"; done
  [ -n "$dst" ] || { result leak-inbound SKIP "PHYS_ADDRS unset: inbound cannot be told apart"; return 0; }
  f="($dst) and not host $NODE_IP and not (udp port 67 or udp port 68 or udp port 546 or udp port 547)"
  [ -n "${GATEWAY_IP:-}" ] && f="$f and not host $GATEWAY_IP"
  [ -n "${CONTROL_IP:-}" ] && f="$f and not host $CONTROL_IP"
  for a in ${LEAK_ALLOW_HOSTS-168.63.129.16 169.254.169.254} ${LEAK_RPC_HOSTS:-}; do f="$f and not host $a"; done
  f="$f and not (ip and (src net 10.0.0.0/8 or src net 172.16.0.0/12 or src net 192.168.0.0/16 or src net 100.64.0.0/10"
  f="$f or src net 169.254.0.0/16 or src net 127.0.0.0/8))"
  f="$f and not (ip6 and (src net fe80::/10 or src net fc00::/7 or src net ::1/128))"
  f="$f and not (${LEAK_INBOUND_ALLOW:-src net 40.64.0.0/10 and src port 23456})"
  # Signal shapes. IPv6 uses fixed offsets (no extension headers; TCP/UDP right after the 40-byte header).
  local syn4='(ip and tcp and tcp[13] & 0x12 == 0x12 and dst portrange 1024-65535)'
  local dat4='(ip and tcp and (ip[2:2] - ((ip[0] & 0xf) << 2) - ((tcp[12] & 0xf0) >> 2)) > 0)'
  local udp4='(ip and udp and udp[4:2] > 8 and src portrange 1-1023 and dst portrange 1024-65535)'
  local syn6='(ip6 and ip6[6] == 6 and ip6[53] & 0x12 == 0x12 and dst portrange 1024-65535)'
  local dat6='(ip6 and ip6[6] == 6 and (ip6[4:2] - ((ip6[52] & 0xf0) >> 2)) > 0)'
  local udp6='(ip6 and ip6[6] == 17 and ip6[44:2] > 8 and src portrange 1-1023 and dst portrange 1024-65535)'
  f="($f) and ($syn4 or $dat4 or $udp4 or $syn6 or $dat6 or $udp6)"
  if [ ! -s "$wins" ]; then result leak-inbound PASS "ks=$ks: no active window"; return 0; fi
  # Answered flows only (DIR 11-08, TWA arm64 OpenVPN): the capture sees a packet before the kill switch drops
  # it, so a server retransmitting into the window that the box never answers was dropped, and reached no app.
  # An inbound packet counts only when the box sent something on the same flow (same local and remote
  # address:port) inside the window: an ACK or data, or the SYN that this SYN-ACK answers.
  local src='' outk="$SCEN_DIR/leak-inbound-out.txt"
  for a in ${PHYS_ADDRS:-}; do src="${src:+$src or }src host $a"; done
  tcpdump -tt -nn -r "$LEAK_PCAP" "($src) and (tcp or udp)" 2>/dev/null |
    awk -v wf="$wins" 'BEGIN { while ((getline l < wf) > 0) { split(l, a, " "); n++; s[n]=a[1]; e[n]=a[2] } }
         { t=int($1); for (i=1; i<=n; i++) if (t >= s[i] && t <= e[i]) { d=$5; sub(/:$/, "", d); print $3, d; break } }' |
    sort -u > "$outk"
  # leak_inbound_pick <margin>: the answered inbound packets inside the windows (shrunk by margin).
  leak_inbound_pick() {
    tcpdump -tt -nn -r "$LEAK_PCAP" "$f" 2>/dev/null |
      awk -v wf="$wins" -v ok="$outk" -v m="$1" '
        BEGIN { while ((getline l < wf) > 0) { split(l, a, " "); n++; s[n]=a[1]+m; e[n]=a[2]-m }
                while ((getline l < ok) > 0) out[l] = 1 }
        { t=int($1); d=$5; sub(/:$/, "", d); if (!((d " " $3) in out)) next
          for (i=1; i<=n; i++) if (t >= s[i] && t <= e[i]) { print; break } }'
  }
  leak_inbound_pick 0 > "$SCEN_DIR/leak-inbound.txt"
  e=${LEAK_EDGE_S:-2}
  all=$(grep -c . "$SCEN_DIR/leak-inbound.txt" || true)
  n=$(leak_inbound_pick "$e" | grep -c . || true)
  edge=$(( all - n ))
  if [ "$n" = 0 ]; then
    result leak-inbound PASS "ks=$ks: no inbound handshake or data from a public host"
  else
    local srcs
    srcs=$(awk '{ for (i=1; i<=NF; i++) if ($i == ">") { s=$(i-1); sub(/\.[0-9]+$/, "", s); print s; break } }' \
      "$SCEN_DIR/leak-inbound.txt" | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s%s(%s)", (NR>1?" ":""), $2, $1}')
    result leak-inbound FAIL "ks=$ks: $n inbound packet(s) of a flow the box took part in, from: $srcs; first: $(head -1 "$SCEN_DIR/leak-inbound.txt")"
  fi
  [ "$edge" -gt 0 ] && result leak-inbound-edge WARN "ks=$ks: $edge inbound packet(s) within $e s of an active-window edge"
  return 0
}

# leak_in_windows <tcpdump text> <windows file: "start_epoch end_epoch" per line> <the mode's filter> → count inside any window
leak_in_windows() {
  # re-read with -tt for epoch times using leak_stop's own filter (it already excludes the node; TLX 11-08: a
  # hard-coded DNS-only filter here hid every non-DNS leak with ks=on), then count the packets inside any window
  tcpdump -tt -nn -r "$LEAK_PCAP" "$3" 2>/dev/null |
    awk -v wf="$2" -v m="${LEAK_MARGIN:-0}" 'BEGIN { while ((getline l < wf) > 0) { split(l, a, " "); n++; s[n]=a[1]+m; e[n]=a[2]-m } }
         { t=int($1); for (i=1; i<=n; i++) if (t >= s[i] && t <= e[i]) { c++; break } } END { print c+0 }'
}

leak_selftest() {
  SCEN_DIR=$OUT/selftest/leak; mkdir -p "$SCEN_DIR"
  local t0; t0=$(date +%s)
  leak_start; sleep 1
  # planted: direct, outside any tunnel. The adapter plants it on the test machine when the driver runs elsewhere.
  if declare -F plat_plant_leak >/dev/null; then plat_plant_leak; else curl -4 -s -m 5 --interface "$PHYS_IF" https://1.1.1.1 >/dev/null 2>&1; fi
  sleep 1
  # A window round the plant (no session runs here); persist then counts the plant like a mid-session packet.
  echo "$((t0 - 5)) $(( $(date +%s) + 5 ))" > "$SCEN_DIR/active-windows.txt"
  SCENARIO_FAILED=0; SCENARIO=selftest-leak LEAK_EDGE_S=0 leak_stop persist
  [ "$SCENARIO_FAILED" = 1 ] && echo "leak selftest: caught the planted packet" || echo "leak selftest: MISSED the planted packet"
}
