#!/usr/bin/env python3
"""Decode cbm-socks.sh output into one row per (uid, proto, remote): first/last seen and the package.

    cbm-socks-decode.py <sockets.raw> <uid-map> <active-windows.txt> > sockets.txt

uid-map lines are `pm list packages -U` output. A row whose seen-time overlaps an active window is marked IN-WINDOW:
a direct socket during a session. The app's own uid is outside the VPN by design; every other uid IN-WINDOW is a leak
candidate. Listening sockets (remote 0) are skipped.
"""
import socket
import struct
import sys


def addr(h):
    ip, port = h.split(":")
    port = int(port, 16)
    raw = bytes.fromhex(ip)
    if len(raw) == 4:
        return "%s:%d" % (socket.inet_ntop(socket.AF_INET, raw[::-1]), port)
    words = b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4))
    if words[:12] == b"\0" * 10 + b"\xff\xff":
        return "%s:%d" % (socket.inet_ntop(socket.AF_INET, words[12:]), port)
    return "[%s]:%d" % (socket.inet_ntop(socket.AF_INET6, words), port)


def main():
    raw, umap, wins = sys.argv[1:4]
    pkgs = {}
    for line in open(umap, encoding="utf-8", errors="replace"):
        if "uid:" in line:
            name = line.split("package:", 1)[-1].split()[0]
            uid = line.rsplit("uid:", 1)[1].strip().split(",")[0]
            pkgs.setdefault(uid, []).append(name)
    windows = []
    for line in open(wins):
        p = line.split()
        if len(p) >= 2:
            windows.append((int(p[0]), int(p[1])))
    rows = {}
    for line in open(raw, encoding="utf-8", errors="replace"):
        p = line.split()
        if len(p) < 10 or not p[0].isdigit():
            continue
        t, proto, rem, uid = int(p[0]), p[1], p[4], p[9]
        if rem.split(":")[0].strip("0") == "":
            continue
        k = (uid, proto, addr(rem))
        a, b = rows.get(k, (t, t))
        rows[k] = (min(a, t), max(b, t))
    for (uid, proto, rem), (a, b) in sorted(rows.items(), key=lambda kv: kv[1][0]):
        inw = any(a <= e and b >= s for s, e in windows)
        name = ",".join(pkgs.get(uid, ["?"]))[:60]
        print("%s %d %d uid=%s %s %s %s" % ("IN-WINDOW" if inw else "outside  ", a, b, uid, proto, rem, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
