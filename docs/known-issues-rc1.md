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
| Linux/Android speed | V2Ray was capped near 1.6 MB/s on Linux and Android. | The oversized socket buffer that Linux clamps is removed there. **Proven on Debian 12:** V2Ray 13–14 MB/s, the same as Xray. Fedora and Android still to measure. |
| Node metering | A WireGuard peer's traffic while the node service was down was lost from metering. | Counters are read before the leftover interface is removed. |
| Orphan tunnel | After the service was killed, a tunnel could stay up with status "none". | Cleaned on the next start. |
| Device wallet | No way to empty a device wallet. | New `key sweep` command. |
| Settings (all apps) | With an http blockchain endpoint stored (test networks), every `daemon set` failed, so the kill switch could not be turned on from the CLI. | The stored endpoint is carried through; the https rule applies only to a newly typed endpoint. Fixed in the macOS and Linux RC1 builds. Windows: see its build note. Android: fixed after RC1, so not in it. |

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

| Area | What a user may see | State |
|---|---|---|
| **Kill switch (Linux; Android shares the code)** | **Possible leak:** with the kill switch on, in 4 of 60 test cycles some traffic left directly for ~15 s after the background service restarted or a reconnect failed. | **High priority.** Not yet confirmed as a leak, because the firewall state wasn't sampled at those seconds. Re-measure with per-second firewall snapshots first; if confirmed, fix before the final release. Until then, don't rely on the kill switch across a service restart. |
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
