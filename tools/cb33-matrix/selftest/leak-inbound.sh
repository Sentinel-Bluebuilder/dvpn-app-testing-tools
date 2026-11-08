#!/usr/bin/env bash
# ─── Selftest: the inbound side of checks/leak.sh (DIR 11-08, FMC G30) ───
# Builds small pcaps offline (python3, no network) and judges them with LEAK_OFFLINE=1, ks=on.
# Every case must come out as expected; exits 1 on any miss. Packet times are T0..T0+2, all inside the window.
# Usage (from ~/cb33-matrix, needs tcpdump + python3): bash selftest/leak-inbound.sh
set -u
cd "$(dirname "$0")/.." || exit 2
. lib/common.sh; . checks/leak.sh

OUT=$(mktemp -d); : > "$OUT/results.tsv"
NODE_IP=203.0.113.10; PHYS_ADDRS='10.128.0.5 2001:db8:5::5'; GATEWAY_IP=10.128.0.1; CONTROL_IP=198.51.100.7
LEAK_RPC_HOSTS=198.51.100.20; SUITE=selftest; PROTO=none
T0=$(date +%s)

# mkpcap <file> <spec>... ; spec = proto,src,sport,dst,dport,flags,payload_len  (proto tcp|udp; flags S|SA|A|R)
mkpcap() {
  python3 -I - "$@" <<'EOF'
import ipaddress, struct, sys, time
out, specs = sys.argv[1], sys.argv[2:]
t0 = int(time.time())
flagbits = {'S': 0x02, 'SA': 0x12, 'A': 0x10, 'R': 0x04, 'PA': 0x18}
with open(out, 'wb') as f:
    f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for i, spec in enumerate(specs):
        proto, src, sport, dst, dport, flags, plen = spec.split(',')
        sport, dport, plen = int(sport), int(dport), int(plen)
        payload = b'x' * plen
        if proto == 'tcp':
            l4 = struct.pack('!HHIIBBHHH', sport, dport, 1, 1, 5 << 4, flagbits[flags], 65535, 0, 0) + payload
            pnum = 6
        else:
            l4 = struct.pack('!HHHH', sport, dport, 8 + plen, 0) + payload
            pnum = 17
        s, d = ipaddress.ip_address(src), ipaddress.ip_address(dst)
        if s.version == 4:
            ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(l4), 0, 0, 64, pnum, 0, s.packed, d.packed)
            etype = 0x0800
        else:
            ip = struct.pack('!IHBB16s16s', 6 << 28, len(l4), pnum, 64, s.packed, d.packed)
            etype = 0x86dd
        frame = b'\x02' * 6 + b'\x04' * 6 + struct.pack('!H', etype) + ip + l4
        f.write(struct.pack('<IIII', t0 + i % 3, 0, len(frame), len(frame)))
        f.write(frame)
EOF
}

# case <name> <expect PASS|FAIL> <spec>...
fails=0
case_() {
  local name=$1 want=$2; shift 2
  SCEN_DIR=$OUT/$name; mkdir -p "$SCEN_DIR"; LEAK_PCAP=$SCEN_DIR/phys.pcap
  mkpcap "$LEAK_PCAP" "$@" || { echo "leak-inbound selftest: $name: pcap build failed"; fails=$((fails + 1)); return; }
  echo "$((T0 - 10)) $((T0 + 10))" > "$SCEN_DIR/active-windows.txt"
  SCENARIO=$name SCENARIO_FAILED=0 LEAK_OFFLINE=1 LEAK_EDGE_S=0 leak_stop on >/dev/null 2>&1
  local got
  got=$(awk -F'\t' -v s="$name" '$3 == s && $5 == "leak-inbound" { print $6 }' "$OUT/results.tsv" | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $name: leak-inbound $got"
  else echo "MISS $name: leak-inbound ${got:-none}, wanted $want"; fails=$((fails + 1)); fi
}

# Noise that must never count: a scanner SYN to ssh, a scanner UDP probe to a service port, a bare RST,
# an Azure platform probe SYN-ACK, the node's own data, the RPC host, the gateway, a private LAN host.
NOISE=(
  tcp,45.1.2.3,40000,10.128.0.5,22,S,0
  udp,45.1.2.4,5000,10.128.0.5,53,A,40
  tcp,45.1.2.5,443,10.128.0.5,50001,R,0
  tcp,40.87.1.1,23456,10.128.0.5,50002,SA,0
  tcp,203.0.113.10,443,10.128.0.5,50003,PA,500
  tcp,198.51.100.20,443,10.128.0.5,50004,PA,500
  udp,10.128.0.1,53,10.128.0.5,50005,A,60
  tcp,10.0.0.9,443,10.128.0.5,50006,PA,100
)
case_ noise-only PASS "${NOISE[@]}"
# Planted leaks: the box answers the flow inside the window (its SYN / ACK / query), the server's packets come back.
case_ planted-v4-handshake-data FAIL "${NOISE[@]}" tcp,10.128.0.5,50100,8.8.4.4,443,S,0 tcp,8.8.4.4,443,10.128.0.5,50100,SA,0 \
  tcp,10.128.0.5,50100,8.8.4.4,443,A,0 tcp,8.8.4.4,443,10.128.0.5,50100,PA,700
case_ planted-v4-synack-only FAIL "${NOISE[@]}" tcp,10.128.0.5,50101,8.8.4.4,443,S,0 tcp,8.8.4.4,443,10.128.0.5,50101,SA,0
case_ planted-v4-udp-reply FAIL "${NOISE[@]}" udp,10.128.0.5,50102,1.1.1.1,53,A,30 udp,1.1.1.1,53,10.128.0.5,50102,A,80
case_ planted-v6-data FAIL "${NOISE[@]}" tcp,2001:db8:5::5,50103,2606:4700::1111,443,A,0 tcp,2606:4700::1111,443,2001:db8:5::5,50103,PA,300
case_ scanner-v6-syn PASS "${NOISE[@]}" tcp,2606:4700::1,40000,2001:db8:5::5,22,S,0
# A bare ACK (no payload) proves nothing on its own; these pin the header-length arithmetic on both families.
case_ bare-ack-v4 PASS "${NOISE[@]}" tcp,10.128.0.5,50104,8.8.4.4,443,A,0 tcp,8.8.4.4,443,10.128.0.5,50104,A,0
case_ bare-ack-v6 PASS "${NOISE[@]}" tcp,2001:db8:5::5,50105,2606:4700::1111,443,A,0 tcp,2606:4700::1111,443,2001:db8:5::5,50105,A,0
# TWA arm64 OpenVPN (DIR 11-08): a pre-window flow's server retransmits data into the window and the box never
# answers (the kill switch dropped it after the capture saw it). Not a leak.
case_ unanswered-retransmit PASS "${NOISE[@]}" tcp,192.0.2.5,443,10.128.0.5,64547,PA,51 tcp,192.0.2.5,443,10.128.0.5,64547,PA,51
# The box answering a DIFFERENT flow to the same host does not make this one answered.
case_ other-flow-answer PASS "${NOISE[@]}" tcp,10.128.0.5,50200,8.8.4.4,443,A,0 tcp,8.8.4.4,443,10.128.0.5,50201,PA,100

# ─── Blind cells (DIR 11-08, FLX u22): no active window must never pass where the block must hold ───
# blind_ <name> <ks> <expect-blocked or ""> <want leak row>  (status.tsv empty, active-windows.txt empty)
blind_() {
  local name=$1 ks=$2 eb=$3 want=$4 got
  SCEN_DIR=$OUT/$name; mkdir -p "$SCEN_DIR"; LEAK_PCAP=$SCEN_DIR/phys.pcap
  mkpcap "$LEAK_PCAP" tcp,10.128.0.5,50300,8.8.4.4,443,S,0 || { fails=$((fails + 1)); return; }
  : > "$SCEN_DIR/active-windows.txt"; : > "$SCEN_DIR/status.tsv"
  SCENARIO=$name SCENARIO_FAILED=0 LEAK_OFFLINE=1 CBM_EXPECT_BLOCKED=$eb leak_stop "$ks" >/dev/null 2>&1
  got=$(awk -F'\t' -v s="$name" '$3 == s && $5 == "leak" { print $6 }' "$OUT/results.tsv" | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $name: leak $got"
  else echo "MISS $name: leak ${got:-none}, wanted $want"; fails=$((fails + 1)); fi
}
blind_ blind-ks-on on '' FAIL
blind_ blind-persist persist 1 FAIL
blind_ blind-lift-expected on 0 PASS
blind_ blind-ks-off off '' PASS

rm -rf "$OUT"
[ "$fails" = 0 ] && echo "leak-inbound selftest: all cases as expected" || { echo "leak-inbound selftest: $fails miss(es)"; exit 1; }
