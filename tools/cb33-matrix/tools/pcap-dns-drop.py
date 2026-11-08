#!/usr/bin/env python3
"""Copy a pcap, dropping DNS queries (UDP/TCP 53) whose question name is one of the given hosts or under them.

    pcap-dns-drop.py <in.pcap> <out.pcap> [--drop-link-mcast] [--drop-arp] [--shift=<seconds>] <host> [<host> ...]

--drop-arp drops ARP (link layer, never a tunnel leak). --shift adds <seconds> (may be negative or fractional) to
every timestamp: the capture runs on the phone, whose clock is not the rig's, and the leak check compares packet
times with the rig's active windows.

Used by plat/android.sh: the app's own uid is outside the VPN by design, so its lookups of its own RPC hosts go to the
network's resolver with any kill switch. Every other packet, and every query for any other name, is kept. Ethernet and
raw-IP link types; anything it cannot parse is kept (never hidden). --drop-link-mcast also drops link-local multicast
(224.0.0.0/24, ff02::/16: mDNS, IGMP, MLD), which never leaves the LAN, like DHCP/ND. Prints what it dropped.
"""
import struct
import sys


def qname(dns):
    if len(dns) < 13:
        return None
    i, parts = 12, []
    while i < len(dns):
        n = dns[i]
        if n == 0:
            return ".".join(parts).lower()
        if n & 0xC0 or i + 1 + n > len(dns):
            return None
        parts.append(dns[i + 1:i + 1 + n].decode("ascii", "replace"))
        i += 1 + n
    return None


def dns_payload(frame, link):
    off = 14 if link == 1 else 0
    if link == 1:
        if len(frame) < 14:
            return None
        et = struct.unpack("!H", frame[12:14])[0]
        if et == 0x8100 and len(frame) >= 18:
            et = struct.unpack("!H", frame[16:18])[0]
            off = 18
    ip = frame[off:]
    if not ip:
        return None
    v = ip[0] >> 4
    if v == 4:
        ihl = (ip[0] & 15) * 4
        proto, l4 = ip[9], ip[ihl:]
    elif v == 6 and len(ip) >= 40:
        proto, l4 = ip[6], ip[40:]
    else:
        return None
    if proto == 17 and len(l4) >= 8:
        sport, dport = struct.unpack("!HH", l4[:4])
        return l4[8:] if 53 in (sport, dport) else None
    if proto == 6 and len(l4) >= 20:
        sport, dport = struct.unpack("!HH", l4[:4])
        doff = (l4[12] >> 4) * 4
        body = l4[doff:]
        return body[2:] if 53 in (sport, dport) and len(body) > 2 else None
    return None


def link_mcast(frame, link):
    off = 14 if link == 1 else 0
    ip = frame[off:]
    if len(ip) >= 20 and ip[0] >> 4 == 4:
        return ip[16] == 224 and ip[17] == 0 and ip[18] == 0
    if len(ip) >= 40 and ip[0] >> 4 == 6:
        return ip[24] == 0xFF and (ip[25] & 0x0F) == 2
    return False


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    args = sys.argv[3:]
    mcast = "--drop-link-mcast" in args
    arp = "--drop-arp" in args
    shift = 0.0
    for a in args:
        if a.startswith("--shift="):
            shift = float(a.split("=", 1)[1])
    hosts = [h.lower().rstrip(".") for h in args if h and not h.startswith("--")]
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    if len(data) < 24:
        print("pcap-dns-drop: no pcap header", file=sys.stderr)
        return 1
    magic = struct.unpack("<I", data[:4])[0]
    end = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    link = struct.unpack(end + "I", data[20:24])[0]
    unit = 1_000_000_000 if magic in (0xA1B23C4D, 0x4D3CB2A1) else 1_000_000
    out, i, kept, dropped, mc, na = [data[:24]], 24, 0, 0, 0, 0
    while i + 16 <= len(data):
        incl = struct.unpack(end + "I", data[i + 8:i + 12])[0]
        rec = data[i:i + 16 + incl]
        frame = rec[16:]
        i += 16 + incl
        if shift:
            sec, frac = struct.unpack(end + "II", rec[:8])
            t = sec * unit + frac + round(shift * unit)
            rec = struct.pack(end + "II", t // unit, t % unit) + rec[8:]
        if mcast and link_mcast(frame, link):
            mc += 1
            continue
        if arp and link == 1 and len(frame) >= 14 and frame[12:14] == b"\x08\x06":
            na += 1
            continue
        d = dns_payload(frame, link)
        q = qname(d) if d is not None else None
        if q and any(q == h or q.endswith("." + h) for h in hosts):
            dropped += 1
            continue
        out.append(rec)
        kept += 1
    with open(sys.argv[2], "wb") as f:
        f.write(b"".join(out))
    print("kept %d dropped %d app-dns %d link-local-multicast %d arp shift %+.3fs" % (kept, dropped, mc, na, shift))
    return 0


if __name__ == "__main__":
    sys.exit(main())
