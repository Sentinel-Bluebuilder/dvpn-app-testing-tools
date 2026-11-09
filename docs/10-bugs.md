# 10 — Bugs: every one identified, and how it was resolved

One catalogue for the whole effort, from the first queue row to the RC1 cut. A row is a *finding* that was given an id (Q####) and driven to a disposition. **Identified = sum of the statuses below** (reconciled from the source table on the controller; the director re-counts at the end).

> Draft numbers as of the RC1 pause (2026-11-09). Rows whose proof run on the RC1 build is still running are listed in §6 as *pending*, not as closed. The grade of the independent grader is the final word; the totals are refreshed by the director.

## 1. Statuses

- **FIXED-APP** — fixed in a client app (Windows, Linux, macOS, Android, Node Manager).
- **FIXED-FORK** — fixed in our fork of the daemon (dvpnd) / node / CLI; carried in the fork cut tags.
- **FIXED-UPSTREAM-PR** — fixed by a pull request to the public Sentinel Solana repository (see `05-upstream.md`).
- **FIXED-HARNESS** — a defect in the test tooling itself (false pass, false fail, stall); fixed there.
- **FIXED-INFRA** — a test-environment / hosting problem, fixed or worked around.
- **NOT-A-BUG** — investigated; the evidence shows the product behaves correctly.
- **RETIRED** — no longer applicable (feature removed, superseded), with the reason recorded.

There is no "known issue" status: a finding is fixed, shown not to be a bug, or retired. Items still waiting for their RC1 proof run are tracked in `known-issues-rc1.md`.

## 2. Totals

**506 findings identified** = 140 FIXED-APP + 68 FIXED-FORK + 36 FIXED-UPSTREAM-PR + 157 FIXED-HARNESS + 40 FIXED-INFRA + 45 NOT-A-BUG + 20 RETIRED.

Of those, 17 are duplicates merged into another row (they follow the target's status and are kept so nothing is dropped).

## 3. By product

| Product | APP | FORK | UPSTREAM-PR | HARNESS | INFRA | NOT-A-BUG | RETIRED | Total |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| Windows app | 43 | 13 | 2 | 60 | 13 | 14 | 10 | 155 |
| Linux app | 23 | 11 | 8 | 43 | 11 | 8 | 0 | 104 |
| Daemon (dvpnd) node + client | 6 | 30 | 20 | 12 | 0 | 7 | 5 | 80 |
| Node Manager | 33 | 1 | 2 | 14 | 7 | 0 | 1 | 58 |
| Android app | 16 | 6 | 0 | 15 | 5 | 10 | 1 | 53 |
| macOS app | 19 | 1 | 2 | 11 | 4 | 5 | 2 | 44 |
| All products | 0 | 4 | 0 | 2 | 0 | 0 | 1 | 7 |
| Chain / program round | 0 | 0 | 1 | 0 | 0 | 1 | 0 | 2 |
| SDK | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| CLI (bundled in every app) | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| Daemon node (upstream build) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 1 |

## 4. By OS

| OS | APP | FORK | UPSTREAM-PR | HARNESS | INFRA | NOT-A-BUG | RETIRED | Total |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| Linux | 52 | 43 | 31 | 62 | 13 | 13 | 6 | 220 |
| Windows | 43 | 13 | 2 | 60 | 13 | 14 | 10 | 155 |
| Android | 16 | 6 | 0 | 15 | 5 | 10 | 1 | 53 |
| macOS | 19 | 1 | 2 | 11 | 4 | 5 | 2 | 44 |
| All / not OS-specific | 10 | 5 | 0 | 9 | 5 | 2 | 1 | 32 |
| Chain | 0 | 0 | 1 | 0 | 0 | 1 | 0 | 2 |

## 5. By protocol and by class

A finding that touches several protocols counts once under each.

| Protocol | APP | FORK | UPSTREAM-PR | HARNESS | INFRA | NOT-A-BUG | RETIRED | Total |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| not protocol-specific | 89 | 23 | 17 | 94 | 27 | 27 | 16 | 293 |
| v2ray | 24 | 22 | 5 | 28 | 7 | 9 | 1 | 96 |
| wireguard | 22 | 15 | 8 | 26 | 6 | 6 | 1 | 84 |
| xray | 17 | 17 | 6 | 25 | 7 | 7 | 1 | 80 |
| openvpn | 14 | 25 | 5 | 25 | 5 | 4 | 1 | 79 |
| amneziawg | 19 | 11 | 4 | 23 | 2 | 9 | 0 | 68 |
| hysteria2 | 12 | 14 | 8 | 19 | 6 | 4 | 2 | 65 |

| Class | APP | FORK | UPSTREAM-PR | HARNESS | INFRA | NOT-A-BUG | RETIRED | Total |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| harness | 4 | 0 | 0 | 157 | 0 | 3 | 5 | 169 |
| kill switch/leak | 53 | 26 | 9 | 0 | 5 | 9 | 1 | 103 |
| status honesty | 45 | 9 | 6 | 0 | 11 | 4 | 1 | 76 |
| money | 9 | 20 | 14 | 0 | 5 | 5 | 1 | 54 |
| other | 6 | 4 | 1 | 0 | 6 | 15 | 8 | 40 |
| install | 6 | 4 | 0 | 0 | 5 | 5 | 3 | 23 |
| RPC | 2 | 4 | 4 | 0 | 7 | 3 | 1 | 21 |
| node-side | 15 | 1 | 2 | 0 | 1 | 1 | 0 | 20 |

| Severity | APP | FORK | UPSTREAM-PR | HARNESS | INFRA | NOT-A-BUG | RETIRED | Total |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| low | 3 | 0 | 1 | 123 | 28 | 29 | 15 | 199 |
| medium | 86 | 36 | 21 | 0 | 0 | 4 | 2 | 149 |
| high | 37 | 32 | 14 | 29 | 7 | 12 | 3 | 134 |
| unrated | 14 | 0 | 0 | 5 | 5 | 0 | 0 | 24 |

## 6. Still pending an RC1 proof run (27 rows, status shown is the fix class)

These carry a fix in RC1 (or a fix being made for RC2) but the proof run on the RC1 build is not finished. Pending cells are refreshed by the director. Closed since the source table was cut (graded 2026-11-09): Q0438 and Q0192 (WireGuard kill metering), Q0466 (V2Ray speed). Q0479 was cleared as not-a-leak and is not a finding. Linux totals in section 4 include node-side daemon findings.

| Q | What | Fix class | Proof state |
|---|---|---|---|
| Q0190 | Windows RC2 0.1.2 x64: a WireGuard connect killed at 15 s (after dvpnd installed WireGuardTunnel$dvpn-wg-clien | FORK | fixed pending final |
| Q0195 | Client usage guard ends a WG session as 'node overcharging' on a lossy last mile: the node legitimately bills  | APP | fixed pending final |
| Q0242 | RC3 0.1.3 arm64 edge:double-settle 13/1 (wa1 03:36Z): two settles race; one ends 'Done', the other prints 'Err | APP | fixed pending final |
| Q0247 | After a dvpnd service restart mid-session, an OpenVPN session sometimes comes back with traffic going DIRECT ( | FORK | reopened |
| Q0265 | x64 wx5: reboot-persist:amneziawg left service AmneziaWGTunnel$dvpn-awg-client RUNNING after StopSession OK (0 | APP | fixed pending final |
| Q0268 | W-arm64-ui: 30 FAIL / 183 PASS on wa3 desktop 07:51-07:57Z. Reasons (43 unique FAIL lines): control not found  | HARNESS | fixed pending final |
| Q0280 | x64 edge:shutdown-during-settle:wireguard (wx4 04:28Z, RC3 app + node-4 RC4): the service stopping mid-settle  | APP | fixed pending final |
| Q0281 | x64 wx1 (RC3, desktop user test host): after 'devnet-dvpn proxy off' + 'disconnect', HKCU Internet Settings st | APP | fixed pending final |
| Q0319 | A subscription made outside the app (CLI or another device of the wallet) shows on Plans only at the next 600  | APP | ready for proof |
| Q0368 | Q0357 pin 19dc608 on Windows: tunnel check SKIPPED for AmneziaWG and OpenVPN (no gate, no probe, not even a lo | FORK | proving |
| Q0369 | Q0357 pin 19dc608 Windows WireGuard: dead-tunnel error arrives +10.4 s after the adapter is Up (11 s after 'se | FORK | fixed pending final |
| Q0415 | Windows AWG, kill switch kept after 'connection lost': every reconnect fails on RPC 'lookup api.devnet.solana. | FORK | proving |
| Q0417 | Windows: dvpnd never starts again after a v2ray session ends in reconnect-attempts-exhausted. Stale client\cli | FORK | fixed pending final |
| Q0418 | arm64 lab.7 (dvpnd cf4c-23cb385-test host.38-lab-428981d), edge suite with the kill switch OFF, clock +150 s f | UPSTREAM-PR | triaged |
| Q0419 | W-x64-edge:switch-while-coming-up:amneziawg (test host, lab-0bb7b3b, 06:44-06:47Z): check 'message: every outp | APP | triaged |
| Q0441 | Client surfaces any upstream failure as opaque 'FailedPrecondition: internal: internal error', losing the spec | UPSTREAM-PR | fixed pending final |
| Q0445 | status detection latency: after a data-path loss the client status reads state=active with empty error text (t | UPSTREAM-PR | reopened |
| Q0458 | device key SOL is stranded: no shipped tool moves the fee SOL off a device (daemon) key. sentinel-dvpn 'wallet | UPSTREAM-PR | new |
| Q0459 | Mac ks-leak cut90: status reads state=active ks=on with an EMPTY error ("error": "") during a cut, instead of  | FORK | new |
| Q0461 | Orphaned awg/wg tunnel for (path) s after a dvpnd SIGKILL while status reads none: the kill switch held (263 p | UPSTREAM-PR | triaged |
| Q0463 | sentinel-dvpn CLI (fork, bundled by every app) still ends its plain message with the raw gRPC error (rpc error | FORK | fixed pending final |
| Q0464 | HIGH: kill switch lifted on an unrequested session end. A node-metadata fetch failure during a sustained node  | HARNESS | triaged |
| Q0468 | daemon set --kill-switch on echoes killSwitch:on (rc=0) but may not arm the service KS: test team saw service  | APP | claimed |
| Q0469 | Windows: `sentinel-dvpn status` blocks for more than 5 s instead of failing fast while dvpnd restarts or stops | FORK | triaged |
| Q0470 | HIGH, candidate ship-blocker: Windows arm64 final6 630e232: hysteria2(path) never start: ErrUntrustedBinary (' | APP | triaged |
| Q0477 | hysteria2 TestServer_RemovePeer_FailureKeepsThePause failed once in the final6.1-draft2 gate; 0 of 100+ reruns | FORK | new |
| Q0478 | Sibling of Q0468 (Mac, fixed dbf2116f): the Windows (), Linux () and Android () config writers renderConfig/re | APP | triaged |

## 7. Full catalogue

Every row, one line each, with how it was resolved: [`../bugs/catalogue.md`](../bugs/catalogue.md).

## 8. Highlights (graded, signed)

The graded dispositions with their evidence (failing test, mutant, live A/B) are in `04-results.md` §3. Notable results from the RC1 round: Q0438/Q0192 (WireGuard kill metering) proven on the RC1 daemon — node billed 55,621 vs client 55,629 bytes, against 48,861 vs 55,680 on the previous cut; Q0466 (V2Ray speed) proven on Debian 12 and Fedora 44, V2Ray at parity with Xray; Q0479 (possible Linux kill-switch leak) **cleared** — see `known-issues-rc1.md`.
