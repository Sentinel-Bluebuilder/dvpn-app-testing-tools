# Known issues: release candidate 1 (RC1)

RC1 ships the Windows, Linux and macOS apps and the three node tools on the final fork cut (final6.1). The Android
app ships on the previous cut (final6), the last one fully tested on Android. Every fix below is in the RC1 code. "Not
yet retested" means its proof run on the RC1 build is still to come. This list closes only when each item has that
proof.

## 1. Fixed in RC1, proof run still to come

| Area | What a user saw | Fix |
|---|---|---|
| Status honesty | After the path to the node died, Hysteria2 (and WireGuard) kept reading "healthy" for up to 11 s. The goal is under 2 s. | A tunnel that sends but hears nothing for 1.5 s now reads "Reconnecting". |
| Plain words | One "service not ready" message still ended in a raw gRPC error. | It is mapped to plain words. |
| Windows CLI | `status` hung for over 5 s while the background service restarted. | Each connection attempt is capped at 1 s, then reports "service not running". |
| Node, busy network | When the node's blockchain connection was rate-limited, a new session got "internal error". | The node answers "busy" with a retry time. |
| Linux/Android speed | V2Ray was capped near 1.6 MB/s on Linux and Android. | The oversized socket buffer that Linux clamps is removed there. **Proven** on Debian 12 (V2Ray 13–14 MB/s, same as Xray), Fedora 44 (11–13 MB/s vs Xray 13) and Android (5.2–5.4 vs 5.1 MB/s). |
| Node metering (**proven**: node 55,621 vs client 55,629 bytes on RC1; previous build 48,861 vs 55,680) | A WireGuard peer's traffic while the node service was down was lost from metering. | Counters are read before the leftover interface is removed. |
| Orphan tunnel | After the service was killed, a tunnel could stay up with status "none". | Cleaned on the next start. |
| Device wallet | No way to empty a device wallet. | New `key sweep` command. |
| Settings (all apps) — first call sites **(a missed call site remains; see section 3)** | With an http blockchain endpoint stored (test networks), every `daemon set` failed, so the kill switch could not be turned on from the CLI. | The stored endpoint is carried through; the https rule applies only to a newly typed endpoint. Fixed in the macOS and Linux RC1 builds. Windows: fixed in RC1. Android: fixed after RC1, so not in it. |

## 2. Windows app: fixed earlier, final proof run pending

These were fixed in earlier builds and carry into RC1. Their last proof run was stopped by the pause:
- cancelling WireGuard while it connects;
- the lossy-network money check;
- no double settlement;
- the kill switch kept after a reboot;
- the screen walk-through;
- the end reason after a short cut;
- the proxy restored at start-up;
- the Plans list refresh;
- MTU blackhole handling (AmneziaWG, OpenVPN);
- the WireGuard adapter clamp undo;
- V2Ray service clean-up;
- a clock jump;
- switching servers while connecting.

## 3. Open

**Cleared since the first list:** the possible Linux/Android kill-switch leak after a service restart (internally Q0479) is **not a leak**. In 60 of 60 test cycles (kill switch on, persist, 1-second firewall/route/probe/packet-capture sampling) the block held across every restart. The direct probes seen earlier were the test rig's own safety job releasing the block on purpose, not the product.


| Area | What a user may see | State |
|---|---|---|
| Settings, kill switch (all apps) | A second config writer still rejected an http blockchain endpoint (test networks), so `daemon set --kill-switch on` failed on the RC1 macOS build. One call site was missed in the first fix. | Fix in progress for RC2 on all four apps; proof = the CLI turning the kill switch on with an http endpoint stored. |
| Linux, OpenVPN | After the background service restarts, about 1 in 20 times a host route was left behind (Ubuntu 24.04). | 60-cycle proof run planned. |
| macOS, kill switch | During a 90 s network cut, status honesty with the kill switch on still needs a clean re-measure. | Re-run planned on the RC1 build. |
| Windows, stale tunnel | With a WireGuard tunnel left over from a crash, stopping the service was seen to hang for 15–19 min. | Being reproduced; if confirmed, it gets a fix. |
| Node payments | A node can be paid up to one voucher step less than it served when a session ends mid-step. | The fix needs an on-chain program upgrade; proposed upstream. |
| Android, status | With the kill switch on, status can read "active" about 1 s before traffic flows. RC1 Android is on final6, so the section 1 fixes are not in it. | Judge on the final6.1 Android build. |
| Developer test | One hysteria2 unit test failed once in 176 runs. | Test fix in progress (no user impact). |

## 4. Test-setup only (no user impact)

- The macOS test machine's own safety job stopped the service during long cuts. It is disarmed for those tests now.
- A Windows test folder was writable by any signed-in user, so the service correctly refused to run programs from it.
  The setup script now locks it.
