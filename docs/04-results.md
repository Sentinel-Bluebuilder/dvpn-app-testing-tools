# 04 — Results

OS × suite pass/fail with evidence, the final version per product, and the disposition of every
bug found. This is the tally; the *method* behind it is `01-test-method.md`, the upstream fixes
are `05-upstream.md`, and the money accounting is `06-money.md`.

Every number here is traced to a raw artifact on the controller (the test controller) and was re-derived from
that artifact, not transcribed. Where a cell is owned by a platform tester's result file, it cites
that file; a cell with no traced evidence is left `—`, not guessed.

> **Status:** final release 2026-11-09. Section 2b and section 5b hold the graded final-build results and hashes; section 2 and section 5 are the release-candidate record (their "pending" cells are superseded by 2b and 5b). Per-product binary hashes come from the build owners' SHA256SUMS.

## 1. Legend

- **PASS** — all five built-in checks passed on a valid run.
- **harness** — a failure in the test rig, not the product (dead gate tunnel, wrong key path,
  SOCKS egress probed without the proxy, un-patched node, self-inflicted reclaim-on-live-channels).
- **VOID** — the run is invalid and ungradeable (mixed tree, a cut below the retry budget, a
  pre-redeem settled read, a node predating the fix under test).
- **not-a-leak** — a status/egress disagreement that the packet capture resolves as node-only
  egress or a probe artifact (not a kill-switch failure).
- **product** — a real defect; links to its disposition in §3.
- **n/a** — suite not applicable to that OS/platform.

## 2. OS × suite matrix — RC1 build (final6.1), draft as of 2026-11-09

Protocols per cell: wireguard · amneziawg · openvpn · hysteria2 · v2ray · xray (as applicable). Kill-switch modes:
off · on · persist. **pending** = the run on the RC1 build has not finished; the release director refreshes these
numbers at the end. Evidence for each cell is the raw result folder of that run, kept per run on the test controller
(not published; this repository carries the harness that produces it).

| Suite | Linux (Ubuntu 22/24, Debian 12, Rocky 9, Fedora 44) | Windows (x64 + arm64) | macOS (x64 + arm64) | Android |
|---|---|---|---|---|
| S1 core + core_ks | smoke PASS on all 3 distros after a serial OpenVPN retry (parallel runs caused the node's "busy" answer); Fedora: 1 of 40 status samples read active with a direct IP, under review. Evidence: `g10/ovpn-61-*` | pending | pending | 12 cells: 11 PASS first run, OpenVPN rerun PASS (node was busy). Evidence: Android final6.1 run folder |
| S2 restart / teardown / words | words 9/9 PASS on the previous cut; RC1 run pending | pending | pending (Q0468 retest needs the RC2 fix) | 21 PASS, 2 SKIP, 1 cannot-judge; v2ray daemon-kill rerun logged 1 status sample ~1.5 s early (window rounds running) |
| S3 cut / crash (cut90, cut90_ks) | Hysteria2 cut90: status-honesty FAIL on all 3 distros at the time of that run (rx-stall fix is in final6.1, re-run pending); Ubuntu 22 `cut90_ks` x6 pending. Evidence: `tlx-evidence/final61b-linux` | pending | pending (Q0459 is a proven not-a-leak; teardown fix Q0464 pending) | cut90_ks 6/6 PASS |
| S9 50-cycle soak | pending (Ubuntu 22) | pending | pending | 50 cycles, 0 failed; 1 status sample ~3 s early with the kill switch off (under review) |
| 30-minute soak | pending | pending | pending | PASS (WireGuard, 173 samples, 0 off-tunnel, memory flat) |
| Kill switch across a service restart | **Q0479 CLEARED**: 60 of 60 cycles held the block; the direct probes seen were the test rig's own safety job (see `known-issues-rc1.md`) | pending | pending | shares the Linux code; covered by the Linux result |
| V2Ray vs Xray speed (Q0466) | PASS: Debian 12 V2Ray 13.3–14.2 vs Xray 12.9–14.3 MB/s; Fedora 44 11.4–13.2 vs 13.1–13.3 MB/s (worst run 86% of Xray, within noise) | n/a | n/a | PASS (5.2–5.4 vs 5.1 MB/s, parity) |
| WireGuard kill metering (Q0438/Q0192) | PASS on the node: billed 55,621 vs client 55,629 bytes (previous cut: 48,861 vs 55,680) | n/a | n/a | n/a |
| Node "busy" answer (Q0441) | node side PASS (clean busy answer, client retries, 0 internal errors); retry-then-succeed proof on final6.1 **pending** | n/a | n/a | n/a |
| Money (per protocol) | exact (whole-voucher) | pending | signed with boundary | by design whole-voucher |

> Non-PASS buckets (refined on final6): S9 airplane = harness (ks=off direct egress is by design — no
> kill switch to block the reconnect — plus the harness stops the session before reconnect attempt 3/3;
> the earlier gate-tunnel cause was the 0.1.17 run). S2 daemon_term_persist `state=none id=- egress=node`
> = stale spanning-probe (honest `none`, node reading clears in 2 samples), pcap-confirmed not-a-leak and
> NOT Q0461 (Q0461's signature is traffic still routing while status lies — the SIGKILL orphaned-tunnel
> case). S2 protocol_kill `state=active egress=none` = connect-ramp (next sample egress=node), not Q0445.
> hy2 cut90_ks field gap was an apparent 11s refuted by pcap to ~3-6s = Q0445 CANDIDATE (Q0472). Mac
> KS-on cut `state=active egress=direct` = Q0459 not-a-leak + Q0464 (wrong teardown) HIGH. Windows suites
> owned elsewhere. (Q0445's 2s guarantee is unit-enforced by the signed mutant regardless of field noise.)

## 2b. RC3 column (final6.5, the last client cut) — filled at the end

RC3 = fork cut final6.5 (final6.1 plus the status/stall fixes). Only the status/stall path changed, so RC3 re-runs
only what that path touches: **S1 smoke, S3 cut90 + cut90_ks, and one 30-minute WireGuard soak** per platform
(Windows and macOS: x64 as the main arch; arm64 gets S1 smoke only). Every other cell carries the RC2 result, and
only if the carry-over check (final6.1..final6.5 diff, non-test files) shows the changed code only *reports* status
and drives no teardown, redial, kill-switch, billing or route action. If it does drive one, RC3 also runs one S9
50-cycle and the kill-switch cells. A cell is **PENDING-RC3** until its RC3 run is graded; **CARRIED** cells name
their RC2 evidence folder (kept on the test controller, not published); see the cell marks below the table.

| Suite | Linux | Windows | macOS | Android |
|---|---|---|---|---|
| S1 smoke (6 protocols; arm64 = smoke only) | PASS (final6.5, signed 2026-11-09: Ubuntu 22 x64 54/54, Ubuntu 24 arm64 54/54, Fedora 44 54 PASS + 1 WARN (ks=off edge packet, by design)) | PASS x64 (final 0.2.0 installer, clean install, signed 2026-11-09: 12 cells core + core_ks x 6 protocols, 84 PASS / 5 WARN (ks=off edge packets, by design) / 0 FAIL). arm64: smoke only, not separately graded at sign-off | PASS x64 (final 0.1.3 package, signed 2026-11-09: core 6/6 protocols, 0 dishonest status, leak PASS 6/6, throughput 6/6 (V2Ray 10.13 MB/s). Single status samples 1.0-1.6 s late (inside the 2 s rule, 2-vCPU nested guest). arm64: built, not run live | PASS (final6.5, signed 2026-11-09: core 42/42 PASS, 0 FAIL/SKIP) |
| S1 core_ks | NOT RUN as a separate cell on final6.5 (Linux S1 = core: 54 rows = 6 cells x 9 checks); the kill switch on final6.5 is covered by S3 cut90_ks 6/6 (18/18 on rerun) | PASS x64 (final6.5: part of the 12 S1 cells above, 0 FAIL). Earlier: CARRIED-WITH-FAILS (RC2 x64 and arm64: 48 PASS / 5 WARN / 8 FAIL each; all 8 FAIL = money "node overcharging", a test-rig rule, reclassified, no real overcharge) | CARRIED-WITH-FAILS (RC2: leak-under-KS FAIL 6/6 = harness, Apple push traffic (APNs 17.57.x:5223) fell in the connect/stop edges outside the active window, 0 packets inside it; status-LIE rows = Q0459, cleared on final 0.1.3: the "lies" came from a test-rig clock that stepped backward) | UNVERIFIED (no readable RC2 evidence: the folder cited earlier does not exist; only older final6 evidence exists) |
| S2 restart / teardown / words | CARRIED-WITH-FAILS (RC2: 92 PASS / 1 WARN / 4 FAIL; all 4 FAIL = one status sample `state=none` right after the daemon restart, boundary LIE, no leak; words 12/12 PASS) | NOT RUN on the final build (the RC2 S2 runs have no readable results). Restart and teardown paths that were checked on the final build: upgrade and repeated reinstall (0.2.1) PASS, kill switch across a service restart PASS, dead-data (Q0369) PASS | CARRIED-WITH-FAILS (RC2: S2 words 23/23 PASS (one hysteria2 daemon_term SKIP); 12 `daemon_term_persist`/`daemon_kill` leftovers FAIL = harness (the check ran before the reset), not a defect; the 3 earlier protocol_kill "leak" rows came from cells where the old Mac test rig never killed the process. Rerun on final 0.1.3 with a real kill (SIGKILL), kill switch on, 6 protocols: leak PASS 6/6, leak-inbound PASS 6/6, status PASS 6/6; the pf rules stay after the cell because the kill switch stays on by design) | UNVERIFIED (earlier "21 PASS / 2 SKIP" has no readable source) |
| S3 cut90 | PASS (6/6) | PASS-WITH-CAVEAT x64 (binary-swap install, final6.5: 0 dishonest status, 0 leak; on OpenVPN, V2Ray and Xray the status call did not answer for about 100 s after the reconnect phase, unattributed: product or that test box) | NOT RUN on the final build (the final Mac pass ran cut90_ks only; cut90 carries the RC2 result) | PASS (36/36 rows) |
| S3 cut90_ks | PASS (18/18 on rerun; the first run failed 4/6 on amneziawg + v2ray, a gate-tunnel gap right after a cut = harness) | PASS x64 (binary-swap install, final6.5: the AmneziaWG "leak" = 53 packets to the chain RPC, which the kill switch allows by design; WireGuard 1 status sample 1 s late at a boundary) | PASS x64 (final 0.1.3, 6/6 protocols: 0 dishonest status (Q0459 cleared: the earlier "lies" came from a test-rig clock that stepped backward), no outbound packet outside the tunnel, recovery seen, nothing left behind) | PASS (42/42 rows) |
| S9 50-cycle soak | CARRIED-WITH-FAILS (RC2 `tlx-evidence/final61b-linux`, WireGuard: 11 PASS / 1 FAIL = one boundary status sample) | CARRIED-WITH-FAILS (RC2: x64 32/50, arm64 46/50. Verdict = HARNESS: the "5 s" cut really held the firewall rule ~22 s, longer than the daemon's reconnect budget, so the session ended as designed; "stopped by user" is the harness reading an older session; the x64 c35-c50 cascade = VM-wide network loss, not attributed to the product. No product fix; recovery from a cut is rechecked by RC3 S3 cut90) | CARRIED-WITH-FAILS (RC2: 49 PASS / 1 FAIL = cycle 16 hysteria2 connect, hy2 child exited status 1; memory and handles PASS; status-dishonest rows = Q0459, fixed in final6.5) | UNVERIFIED (earlier "50 cycles, 0 failed" has no readable RC2 source) |
| 30-min soak (one, WireGuard) | PASS (173 samples, 173 active, 0 false "reconnecting"; the harness file verdict reads FAIL only because of its own channel-close step, not a daemon sample) | PASS x64 (final6.5: 131 samples, 0 reconnecting, 0 not-active, egress always via the node) | PASS x64 (final6.5: 30 min WireGuard, "Protected" at every logged tick, egress via the node 15/15, 0 blips, memory 39.9 to 44.3 MB, flattening) | PASS (173 samples, 0 off-tunnel, 0 slow; memory 86.9 to 89.9 MB flat, 17 file handles flat) |
| Kill switch across a service restart (Q0468/Q0478) | CARRIED (RC2: block held 22/22 samples) | PASS x64 (final6.5 + the elevated-argument fix: the kill switch held across a service restart with a stored http endpoint) | CARRIED (RC2 Q0468 mac cell: PASS; setting reads back `persist`, anchor held 37 rules while connected, doctor "held by the running service") | UNVERIFIED |
| Money (per protocol) | UNVERIFIED (no per-platform RC2 money record cited) | CARRIED-WITH-FAILS (the 8 "node overcharging" rows above, test-rig) | UNVERIFIED (the Mac test rig has no owner key, so it cannot read the node-side settlement) | UNVERIFIED |
| Node-side (busy answer, metering, V2Ray speed) | CARRIED (RC2 node-4 runs; per-run folder not cited here) | n/a | n/a | UNVERIFIED |

Cell marks: **CARRIED** = RC2 result read from raw and clean. **CARRIED-WITH-FAILS** = RC2 result carried, but the RC2
run had FAILs; each is listed with its class (harness / test-rig / open). **UNVERIFIED** = no readable RC2 evidence;
the cell must be re-run or stays unproven. An UNVERIFIED or PENDING-RC3 cell is not a pass.

RC3 numbers to enter (hash, pass counts, sample counts) are listed in the release checklist; none is entered here
until graded.

## 3. Bug disposition (graded)

Every bug found, its fix, and the grade. Code-signed = own-run surgical mutant, subs=1, 1:1
discrimination on a fresh checkout; live = own-read raw on devnet.

| Q | What | Fix | Grade | Evidence |
|---|------|-----|-------|----------|
| Q0433 | CLI/client leaks raw gRPC after the plain line | daemonDownError (#49/7b4d031, fork b854006) | ✅ code-signed + live (app+CLI) | mutant FAILs TestWrapCallError/TestDialer 1:1 |
| Q0441 | client rejects a 429 lacking Retry-After | error.go stamps Retry-After:2 (final5.2 0c4618e, #62 ff0b180) | ✅ code-signed + live A/B | mutant `==""`→`!=""` FAILs TestBusyAnswer_PassesTheClientValidator 1:1; live (the test team G4X): client held pure cb33092e, node-only diff — A fails "Retry-After missing", B clean "rate_limited", 1:1 |
| Q0443 | node exits on a start-time 429 | start-check wait (#74/9a24ff2) | ✅ code-signed + live serve-through | -32429 mutant 1:1; the test team G4X A/B + real node |
| Q0444 | client mislabels network-down as credit-exhausted | creditCloseAssumed && !networkDown (fork 718d25d, FIXED-FORK — absent on 26de5240) | ✅ code-signed + live | mutant drop networkDown 1:1; the test team s3_cut90 0 credit-mislabel |
| Q0445 | status reads healthy >2s after node loss | sample() flags stats-unavailable (#75/f7bbc7c); rx-stall detection (final6.1 c1d9419) | ✅ code-signed (both) | mutant FAILs "must not read healthy >2s" 1:1; rx-stall mutant (drop `conn.rxStalled(now) ||`) FAILs TestRuntime_IssueLoop_ReportsReconnectingWhenTheTunnelReceivesNothing 1:1. (hy2 cut90_ks field CANDIDATE Q0472 now resolved — rx-stall fix in final6.1) |
| Q0463 | CLI/app leaks raw gRPC on restart/not-ready | daemonDownError path (Q0433) + S2 words 0 "rpc error: code" | ✅ S2-clean; ⚠ not-ready path = Q0471 | S2 all 12 words rows PASS, 0 raw suffix; BUT awg not-ready "waiting for network: preflight failed: rpc" still leaks raw suffix (Q0471) |
| Q0446 | syncChain 429 not ridden out at start | retry-while-chainUnavailable (#74/6311f73, 739739f) | ✅ code-signed + live A/B | mutant→if true FAILs both pkgs; the test team G4X-sync serves |
| Q0453 | revoked-delegate start leaks raw OwnerMismatch(4) | explainOpenFailure (#64/0321923, fork 5b85986) | ✅ code-signed (upstream+fork) | mutant drop OwnerMismatch FAILs revoked_approval 1:1 |
| Q0458 | key sweep could send full balance | Lamports = balance - fee (final6 f891749) | ✅ code-signed | mutant drop -fee FAILs TestKeySweep 1:1 |
| Q0459 | Mac KS-on 90s cut — direct egress? | n/a (not a leak) | ✅ NOT-A-LEAK (higher bar) | own-pcap: 0 non-node egress in armed window; control discriminates |
| Q0460 | client StartSession leaks raw getAccountInfo on unreachable RPC | chainUnreachable→Unavailable+plain (#77/f89c559) | ✅ code-signed | mutant drop guard FAILs TestGRPC_...PlainWords 1:1 |
| Q0461 | orphaned tunnel still routes after SIGKILL (status none) | Pdeathsig guard removes iface on daemon death (final6 630e232) | ✅ code-signed | mutant drop Pdeathsig FAILs TestGuard (real SIGKILL) 1:1 |
| Q0464 | KS wrongly lifts mid-cut ("stopped by user" mislabel skips #57 hold) | (the test team, in progress) | ⏳ HIGH — live rerun pending (bar: pcap 0 direct while KS on) | filed from the Q0459 grade |
| Q0331 | clock-skew: node forfeits earned vouchers (T10c) | refuse-new + redeem-at-chain-time (de19127) | ✅ code-signed (loop+refuse+chain-time) + live A/B | money conservation −2 unredeemed = +2 redeemed; mutant chainNow()→local 1:1 |
| Q0465 | keyed gate token leak in plan-manager logs | n/a (not leaked) | ✅ NOT-A-BUG | own-scrub 3 logs = 0; own positive control = 1 (discriminates) |
| Q0471 | awg not-ready path leaks raw gRPC suffix | waiting-for-network plain words (final6.1 c9d7ae2) | ✅ code-signed | mutant (guard→`false`) FAILs TestWrapCallError/unavailable_waiting_for_network 1:1; fixes "not ready … waiting for network: preflight failed: rpc" |

Other upstream PRs graded (prior): #70 closing-status (da62fc8), #72 keep-leases (0a2ca1e),
#62 -32429 rate-limit (976ebe3 + 2ee120e), #69 redeem-due (e100ecd + 1ce7b88), #66 final-voucher
skip-audit (fba25bc) — all code-signed 1:1.

> **CLOSED (money) — Q0438 (proven on final6.1 on 2026-11-09: node 55,621 vs client 55,629 bytes; the previous cut read 48,861 vs 55,680): an ORDERING bug, not a missing fix.** The fork already carries the
> leftover-metering feature (`PeerCarryover`/`carryLeftover`) in every cut — but `clearLeftovers`
> removed the `dvpn-<tag>` interface before the carrying service's `Start` read its counters, so
> the bytes a kernel WG peer forwarded while the daemon was down were never billed (~44 MB/kill;
> the test team WG-kill row node 11,422 vs client 55,547). Fix = reorder so a `PeerCarryover` service keeps
> its interface through `clearLeftovers` (patch + test
> `TestRuntime_ClearLeftovers_KeepsTheInterfaceACarryingServiceReads`), landing in final6.1 — **not**
> a port of upstream #47 (porting #47 on top would double-bill). Correction: an earlier the grader note
> here read "`LeftoverStatsReader` 0 hits → #47 absent, port it"; that was a name artifact (the fork
> uses `PeerCarryover`), caught by the test team. Q0192's WG-money part waits on this fix; its false "node
> overcharging" end is already gone (WG+AWG).

## 4. End-to-end corroboration (non-suite)

Full paid-session e2e runs on the final cuts, cross-checking that the component results compose
into a working product. All the grader own-read.

| Run | Cut | Result | Evidence (test controller) |
|-----|-----|--------|------------------|
| Plan Manager (node-4 ovpn) | final3 131d3a2 | 102/0/0 | (run log) |
| Plan Manager (node-4 hy2) | final5 718d25d | 102/0/0 | (run log) (money exact, sweep over HTTP) |
| Plan Manager (node-4 hy2) | **final6 630e232** | **102/0/0** | (run log) (money exact S80-S96; Q0465 not-a-bug, token-scrub 0 + control 1) |
| (node-4) | final5 718d25d | 129/0/0 | (run log) (M2 285.51 Mbps, M2b 366 MB, X3 cleanup) |
| (node-4) | **final6 630e232** | **118/0/1** | (run log) (skip = plan-section --plan-skip per the director; M2 298.33 Mbps, M7 memo decodes from chain) |
| Node Manager local | final5.1 8ff1b27 | 70/0/2 | 0 fails; skips = outside-reach + time-gated bond |
| Node Manager remote | final5.1 8ff1b27 | 76/0/1 | 0 fails; 1 time-gated skip; slow Docker creates = host/harness (28cae4e 120s guard) |
| Node Manager local | **final6 630e232** | **70/0/2** | 0 fails; + live-429 serve-through re-proves Q0443 (real gate −32429, restarts=0) |
| Node Manager remote (ufw) | **final6 630e232** | **76/0/1** | 0 fails; (run log) |

> final6 closes graded so far: plan-manager 102/0/0, node-tester 118/0/1, node-manager 70/0/2 +
> 76/0/1 (all the grader own-read). Mac / Android / the test team(Windows) / the test team S11 follow as their raw lands.
> Note: final6.1 (= 81d3fee + Q0441-classify + Q0438-order, both the grader-signed 1:1) is the cut that
> carries the Q0438 WG-kill-metering and Q0441 auth-grant-classify fixes; §3 rows cite it.

## 5. Final version per product (RC1)

Pinned from the RC1 release index. Every folder holds its own SHA256SUMS and was checked with `sha256sum -c` (all
OK). Fork cut: final6.1 (commit 02b22fc) on public upstream 26de5240. The later final6.2 differs from it in one test
file only, so every binary is byte-identical.

| Product | Build | Hashes (first 8 hex of SHA-256) | Fork cut | Tested on this build |
|---|---|---|---|---|
| Daemon + CLI (6 OS/arch) | final6.1 | Linux 0fbd947e / a702e2b6, macOS a478d9cf / 89976b4a, Windows b44c739e / fe2a13d9 | final6.1 | gate green, graded |
| macOS app | 0.1.3 | x64 de6c291b, arm64 fd9dcd6a | final6.1 | pending |
| Linux app | 0.1.20 | amd64 .deb d140293c, AppImage d532baa5 | final6.1 | pending |
| Windows app | 0.2.0 / 0.1.0 | 0.2.0 x64 f469f80b, arm64 2a4bfdcd; 0.1.0 x64 396dbda3, arm64 3922ca66 | final6.1 | pending |
| Android app | f6-0.1.4 | release apk 20c5cd17 | final6 | S1, S3, S9, soak PASS on the node |
| Node Manager | d77c414 | — | final6.1 | local 70/0/2, live busy-answer PASS, remote 76/0/1 |
| Plan Manager | stage build | — | final6.1 | e2e 102/0/0 |
| Node Tester | stage build | — | final6.1 | e2e 117/1/1 (the 1 = a harness regex, fixed) |

> RC2 carries the Q0468/Q0478 call-site fix (config writers that skipped the plain-http endpoint rule missed one call
> site) across all four apps. The "pending" cells of this RC1 table are superseded by section 5b.

### 5b. Final release (fork cut final6.5, commit 90014b2)

Daemon + CLI (sentinel-dvpnd / sentinel-dvpn): Linux amd64 7eb090ce / fe675398, arm64 81aed46a / a1437084; macOS
amd64 7c8978c0 / 46241db6, arm64 5f5b8752 / 4da2b470; Windows amd64 8203598a / 18a95582, arm64 125200ce / 8fd1b0ea.
Every app package below was unpacked and its embedded daemon compared with these hashes.

| Product | Version | Package hashes (first 8 hex of SHA-256) | Tested on this build |
|---|---|---|---|
| Linux app | 0.1.21 | .deb amd64 94e34516, arm64 47ef07ec; .rpm x86_64 7de03aff, aarch64 d7f701bf; .pkg.tar.zst x64 9bcc673a, aarch64 89ee18e4; AppImage x86_64 abfc66d9, arm64 2854fa43 (SHA256SUMS 25fac16c) | S1, S3 cut90 + cut90_ks, 30-min soak PASS (section 2b), signed 2026-11-09 |
| Android app | 0.1.4 | release apk 1e0f6be2 (libdvpnd arm64 c88fd463, x86_64 6153ff8e; SHA256SUMS fa6aef35) | S1, S3 cut90 + cut90_ks, 30-min soak PASS on the debug-type apk 2a623710 built from the same source and libraries (section 2b), signed 2026-11-09 |
| Windows app | 0.2.1 (patch, latest) | 0.2.1 x64 e8e1d98e, arm64 cead9aea (embedded daemon x64 8203598a, arm64 125200ce, unchanged; release SHA256SUMS 9c7cd3e1) | x64: upgrade over 0.2.0 and clean install; `daemon install --yes` twice in a row (reinstall error 1378 fixed); S1 12/12 cells 84 PASS / 5 WARN (kill switch off, edge packets) / 0 FAIL; data-dead node shows plain words only in the app CLI and session list (Q0369 wording); arm64 built, not run live. Signed 2026-11-09 |
| Windows app | 0.2.0 / 0.1.0 | 0.2.0 x64 91b0aee9, arm64 7582b363; 0.1.0 x64 68d5cc20, arm64 b684c64f (embedded daemon x64 8203598a, arm64 125200ce; release SHA256SUMS 98cc28a5) | x64: S1 12/12 cells on a clean install, 30-min soak, kill switch across a restart, Q0369 PASS; S3 on a binary-swap install (section 2b); arm64 smoke only; 0.1.0 installers not run live. Signed 2026-11-09 |
| macOS app | 0.1.3 | dmg x64 f4537894, arm64 e1063d4c; zip x64 3e612567, arm64 734eb621 (embedded daemon equal to final6.5 apart from the ad-hoc signature) | x64: S1 core 6/6, S3 cut90_ks 6/6, 30-min soak PASS; kill switch after the tunnel process is killed NOT proven (see known issues); arm64 built, not run live. Signed 2026-11-09 |
| Node Manager | **0.3.1-rc.1 (release candidate, pre-release)** | Windows setup x64 e74272fd, arm64 13a604d6, portable fccd3233; macOS dmg x64 51d7449d, arm64 a2b58f80, zip x64 84cde810, arm64 7e2b5992; Linux deb amd64 3bb14ff3, arm64 a5fc9e73, rpm x86_64 fbbe187c, aarch64 b3ab7a34, AppImage x86_64 23a319be; node image 0.3.7 amd64 bced203a, arm64 faf7532b (pinned in the app; release node-image-0.3.7); release SHA256SUMS aab26397 | One commit on every OS (app bundle identical on all 6 OS/CPU builds). Unit 407/407; devnet end-to-end 109/0/1 incl. HNS on all six protocols, refunds 21/0; clean installs Linux 3/3 per CPU, Windows and macOS upgrade from 0.3.0 with data kept; ~10 h soak on Windows, macOS and Linux with paid tests (HNS + ordinary names), an OS reboot and a firewall block (red, then green within 60 s of unblocking). Windows arm64 and macOS arm64 checked as packages only. Signed 2026-11-13 |
| Node Manager | **0.3.0 (installers, latest stable)** | Windows setup x64 8209f31a, arm64 f35ac52c, portable 7de2ca4a; macOS dmg x64 5e531213, arm64 ace677b4, zip x64 f2277ccb, arm64 75a6268f; Linux deb amd64 7f9d12e9, arm64 66202634, rpm x86_64 ad96da16, aarch64 7e8859b2, AppImage x86_64 e1ed8f0a; node image amd64 bb907126, arm64 a8be220f (pinned in the app); daemon + CLI final6.5 amd64 505ce0b2 / 7f080e2f, arm64 72d13a6e / c78b569c; SHA256SUMS bad160f7 | unit 266/266; package checks Windows 35/35, macOS 56/56, Linux x64 27/27 + arm64 25/25 (each includes all six protocol logos); clean install Ubuntu 24.04 / Debian 12 / Fedora 41 + AppImage x64 28/28, arm64 21/21; upgrade keeps wallet + settings (Linux from 0.2.0 7/7, Windows 6/6, macOS); install to a node listed on chain on Windows 11 (3 OS clicks, no admin prompt) and macOS 14 (about 10 app clicks), paid session through it, an outside client through the macOS-deployed node, remove, uninstall with no leftovers; remote deploy with outside clients on all six protocols (arm64 server); bonds withdrawn and node keys emptied on chain |
| Node Manager | 0.2.0 (= RC1 build) | daemon + CLI final6.1 (amd64 0fbd947e / b0247dc5, arm64 a702e2b6 / 059ae244); SHA256SUMS 42cd6df6 | local 70/0/2, remote 76/0/1, live busy-answer PASS (final6.1) |
| Plan Manager | 0.1.0 (= RC1 build) | daemon + CLI final6.1 amd64 0fbd947e / b0247dc5; SHA256SUMS 10d8f139 | e2e 102/0/0 (final6.1) |
| Node Tester | 0.1.0 (= RC1 build) | daemon + CLI final6.1 amd64 0fbd947e / b0247dc5; SHA256SUMS 10d8f139 | e2e 117/1/1, the 1 = a harness pattern, fixed (final6.1) |

> The node tools stay on final6.1: final6.1..final6.5 changes client-side code only (status/stall path, client CLI
> commands), no node or server code, so the tested RC1 builds are the final ones.
