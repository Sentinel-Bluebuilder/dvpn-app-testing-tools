# Known issues: final release (and the release candidates before it)

**Final release (2026-11-09):** the Windows (0.2.0, patched by 0.2.1), macOS (0.1.3), Linux (0.1.21) and Android (0.1.4) apps run on fork
cut final6.5; the node tools keep their tested final6.1 builds. What each platform proved on the final build, and what
is still open, is in section 3b. Sections 1 to 3 are the record from the release candidates. (The file keeps its
original name so existing links keep working.)

RC1 shipped the Windows, Linux and macOS apps and the three node tools on the final fork cut (final6.1). The Android
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

## 3b. Update for the final release (fork cut final6.5)

**Fixed in final6.5, proof pending RC3** (the proof run is the RC3 smoke / cut90 / cut90_ks / 30-minute soak per
platform; each stays on this list until that run is graded):

| Area | What a user saw | Fix |
|---|---|---|
| Windows CLI, `status` (Q0469) | `status` blocked for more than 5 s instead of failing fast while the service restarted or stopped. | Read-only status calls carry a 2 s deadline and report "starting or not responding". |
| Status honesty, Hysteria2 (Q0445) | After the path to the node died, status kept reading "healthy" for up to about 11 s. | A tunnel that receives nothing is flagged within 2 s (rx-stall floor). |
| Soak, false "Reconnecting" (Q0480) | In a 30-minute WireGuard soak, status briefly read "Reconnecting" about three times while traffic never stopped. | The rx-stall rule no longer counts idle time before a fresh request as a stall. |
| macOS, kill switch (Q0459) | During a 90 s cut with the kill switch on, status read "active" while the tunnel was down (10–11 wrong samples per cell). The packet capture showed no leak; only the label was wrong. | Status reads "Reconnecting" during the hold. |

**Proven on the final build (graded 2026-11-09):**

| Platform | Proof on final6.5 | Items closed for that platform |
|---|---|---|
| Linux (app 0.1.21) | S1 smoke 54/54 on Ubuntu 22 x64, 54/54 on Ubuntu 24 arm64, 54 PASS + 1 WARN on Fedora 44 (kill switch off, an edge packet, by design); S3 cut90 6/6; cut90_ks 18/18 on rerun; 30-minute WireGuard soak 173 samples, 0 false "Reconnecting" | Q0445, Q0480 |
| Android (app 0.1.4) | S1 core 42/42, S3 cut90 36/36, cut90_ks 42/42 result rows, 0 FAIL or SKIP; 30-minute WireGuard soak 173 samples, 0 off-tunnel, memory flat | Q0445, Q0480; "Android, status: active about 1 s before traffic" (section 3): 0 status failures on the final build |
| Windows (app 0.2.0, x64) | Clean install of the final installer: S1 12 cells (core + core_ks x 6 protocols) 84 PASS / 5 WARN (kill switch off, edge packets) / 0 FAIL; 30-minute WireGuard soak 131 samples, 0 false "Reconnecting"; kill switch held across a service restart with a stored http endpoint; data-dead node (Q0369): connect fails in 16 s with a plain message, nothing left behind | Q0469, Q0480, Q0478, Q0369; elevated service steps refused the service name `sentinel-dvpnd$c0` (fixed in 0.2.0) |
| Windows (app 0.2.1, x64; same daemon) | Upgrade over 0.2.0 and clean install; `daemon install --yes` twice in a row succeeds; S1 12 cells 84 PASS / 5 WARN (kill switch off, edge packets) / 0 FAIL; data-dead node: the app CLI and the session list show plain words only, the raw text stays in the app log | reinstall error 1378, Q0369 wording |

| macOS (app 0.1.3, x64) | S1 core 6/6 protocols, 0 dishonest status, leak PASS 6/6, throughput 6/6; S3 cut90_ks 6/6, 0 dishonest status, no outbound packet outside the tunnel, recovery seen, nothing left behind; 30-minute WireGuard soak "Protected" throughout, 0 blips | Q0459 (the earlier wrong-status samples came from a test-rig clock that stepped backward; on a wall clock: 0), Q0480, Q0468 |

**Open on Windows at the final release (not blockers):**

| Area | What a user may see | State |
|---|---|---|
| Status after a long cut | After a 90 s network cut on OpenVPN, V2Ray and Xray, the status call did not answer for about 100 s after the reconnect phase (seen on one test box with a swapped-in daemon). No leak and no wrong status. | Unattributed (product or that box); re-run on a clean install planned. |
| Reinstall / repair | Running `daemon install --yes` a second time, when the user is already in the `sentinel-dvpn` group, fails with "System error 1378". A first install works. | Fixed in 0.2.1 (proven on upgrade and on a clean install, two installs in a row). |
| Error wording | A failed connect appends raw `dial tcp ... connectex` text after the plain sentence, and status then reads "stopped by user". | App fixed in 0.2.1: the connect error and the session list are plain words; the raw text stays in the app log. Still in the daemon (unchanged in 0.2.1): its own CLI `sentinel-dvpn.exe` prints the raw text, and it records such a session as "stopped by user" (the app shows "Disconnected."). |
| arm64 | ARM64 installers had a smoke run only. | Full cells planned. |

**By design (documented behaviour):** Kill switch and chain traffic: with the kill switch on, traffic to the configured
blockchain RPC endpoint is still allowed, so the app can settle and reconnect. Nothing else leaves outside the tunnel.

Reconnect budget: if the node you are connected to becomes unreachable (not
your own network), the app retries 3 times over about 14 s, then ends the session with "the connection to this server
stopped working" and you reconnect manually. If your own network drops, it waits and resumes when the network is back.

**Reclassified (not product defects):**

| Item | Class | Reason |
|---|---|---|
| Money check "node overcharging" | Test-rig | The rule read the whole persisted session history, so old ended sessions on the same channel tripped it in every cell. Scoped to the cell's own sessions; no cell showed an actual overcharge. |
| Money check "settled 1 vs spent 3" | Test-rig | Voucher-step lag: the per-scenario bound lacked the step allowance the channel check already had. |
| Kill switch off, direct egress while the path is cut | By design | With the kill switch off nothing blocks traffic during the cut, so egress going direct is expected. It is only a failure if egress goes direct while the tunnel is healthy, status lies, recovery is not seen after the cut ends, or something is left behind. |

| Windows 50-cycle soak, failed cut cycles (RC2: x64 32/50, arm64 46/50) | Test-rig | The "5 s" cut held the block rule about 22 s (the harness ran its probes while it was up), longer than the daemon's reconnect budget, so the session ended as designed. The "stopped by user" text came from the harness reading an older session. The later x64 failure run was a VM-wide network loss, not attributed to the product. Recovery after a cut is rechecked by the RC3 cut90 cells. |
| macOS, kill switch: Apple push traffic (APNs, 17.57.x:5223) flagged as a leak | Test-rig | In the packet capture the traffic falls in the connect and stop edges, outside the active window; 0 packets inside it. The harness leak window started too early. |
| macOS, "leftovers" after a service stop with the kill switch on persist (12 rows) | Test-rig | The check ran before the reset; the kept block is by design. |

**Still open (not decided), macOS:** the kill-switch hold after the tunnel process is killed is **not proven on
macOS**. Three earlier `protocol_kill` cells with the kill switch on (WireGuard, Hysteria2, V2Ray) counted outbound
packets (689, 860 and 1). They are not shown to be a leak or to be harmless; one Hysteria2 cell that also captures the pf
rules will decide it. The macOS arm64 build was not run live.

**Closed, not reproduced:** Windows stale tunnel (stopping the service with a left-over WireGuard tunnel from a
crash). 0 of 14 stops hung (about 5 s each), then 0 of 5 on the final run. The one real effect found is by design:
after a crash, the left-over tunnel black-holes egress until the service starts again.

## 3c. Node Manager 0.3.0 (installers)

| Area | What a user may see | State |
|---|---|---|
| Wallet, send SOL | Sending the whole SOL balance fails with "insufficient funds for rent": the wallet keeps its token account, which needs about 0.002 SOL. Send a little less than the balance. | A "Max" button that leaves the rent is planned for the next release. |
| Test node refund | Each in-app **Test node** pays about 0.2 tDVPN into a test channel. Getting it back takes two runs of `nodes.sweepTestChannels` (CLI) about 2 hours apart, and the sweep needs Docker on this computer, so a user who only hosts nodes over SSH cannot reclaim it yet. | Planned for the next release: start the close right after the test, run the sweep through the node's server, and add a button. |
| Remote nodes after a restart | SSH passwords and keys are never stored, so after the app restarts a remote node waits on its page for **Reconnect** (shown as a banner). Removal and changes resume after it. | By design. |
| Windows arm64, macOS arm64 | Checked as packages (CPU type of every native module, contents), not run on a device. | No test hardware. |

## 3d. Node Manager 0.3.1-rc.1 (release candidate)

| Area | What a user may see | State |
|---|---|---|
| Remote nodes after a restart | As in 0.3.0: a server node shows "Not connected" until **Reconnect**; its chain actions wait for it. | By design; a Reconnect prompt at launch is planned. |
| HNS Resolver | Apps that use their own encrypted DNS (DNS over HTTPS) skip the node's resolver, so Handshake names do not open in them. The first sync downloads about 210 MB; the node needs outbound TCP to Handshake peers (the page says so when it cannot reach them). | By design / documented. |
| Log noise | While a node page is open the app runs one short-lived helper container per chain read, and the node log records each status read. Two app log lines that repeated on every check are fixed for the next build. | Planned for the next release. |
| Windows arm64, macOS arm64 | Checked as packages, not run on a device. | No test hardware. |

## 4. Test-setup only (no user impact)

- The macOS test machine's own safety job stopped the service during long cuts. It is disarmed for those tests now.
- A Windows test folder was writable by any signed-in user, so the service correctly refused to run programs from it.
  The setup script now locks it.
