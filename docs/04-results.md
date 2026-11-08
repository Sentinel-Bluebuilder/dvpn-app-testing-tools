# 04 — Results

OS × suite pass/fail with evidence, the final version per product, and the disposition of every
bug found. This is the tally; the *method* behind it is `01-test-method.md`, the upstream fixes
are `05-upstream.md`, and the money accounting is `06-money.md`.

Every number here is traced to a raw artifact on the controller (`ctl-1`) and was re-derived from
that artifact, not transcribed. Where a cell is owned by a platform tester's result file, it cites
that file; a cell with no traced evidence is left `—`, not guessed.

> **Author:** ABW (independent grader), assembled last from the graded record (`FINAL-REVIEW-0.3.7.md`).
> Per-product binary hashes come from the build owners' `SHA256SUMS`, cited per row when pinned.

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

## 2. OS × suite matrix

Protocols per cell: wireguard · amneziawg · openvpn · hysteria2 · v2ray · xray (as applicable).
ks modes: off · on · persist. Cells are filled from each platform tester's result TSV on `ctl-1`;
`—` = not yet landed at the time of writing.

| Suite | Linux (u22/deb12/rocky9/fedora44) | Windows | macOS | Android |
|-------|-----------------------------------|---------|-------|---------|
| S1  core + core_ks | PASS (TLX/TLX2 final5/0.1.17-18, node-4) | — | PASS (FMC/TMC) | PASS (node-4) |
| S2  restart/teardown | PASS (final6 deb12 190/2, rocky9 187/5); words=Q0433(fixed); daemon_term_persist `state=none id=- egress=node`=stale-probe not-a-leak (pcap-confirmed, NOT Q0461); protocol_kill `state=active egress=none`=connect-ramp not-Q0445; awg not-ready raw-gRPC=Q0471 | — | — | PASS |
| S3  crash/cut (cut90/cut90ks) | PASS (Q0444 live-proof: network-down-RPC-up, 0 credit-mislabel); hy2 Q0445 field=CANDIDATE (Q0472) | — | — | — |
| S9  50-cycle soak | final6 45/50 (TLX u22): 5 airplane cycles=harness (ks=off direct-egress by design + harness stops before reconnect 3/3); clusters from 0.1.17 GONE; 1371 status honest. (0.1.17-era was 37/50, 1 leak→Q0460 fixed) | — | — | PASS (node-4) |
| S2 words (app path) | words9 9/9 PASS (0.1.18 #32, devnet-dvpn status) | — | — | — |
| money (per-protocol) | exact (whole-voucher a27ae32; see §4/06) | — | SIGNED w/ boundary (FMC) | by-design whole-voucher |
| kill-switch (KS-on cut) | — | — | not-a-leak (Q0459); teardown bug = Q0464 HIGH | — |

> Non-PASS buckets (refined on final6): S9 airplane = harness (ks=off direct egress is by design — no
> kill switch to block the reconnect — plus the harness stops the session before reconnect attempt 3/3;
> the earlier gate-tunnel cause was the 0.1.17 run). S2 daemon_term_persist `state=none id=- egress=node`
> = stale spanning-probe (honest `none`, node reading clears in 2 samples), pcap-confirmed not-a-leak and
> NOT Q0461 (Q0461's signature is traffic still routing while status lies — the SIGKILL orphaned-tunnel
> case). S2 protocol_kill `state=active egress=none` = connect-ramp (next sample egress=node), not Q0445.
> hy2 cut90_ks field gap was an apparent 11s refuted by pcap to ~3-6s = Q0445 CANDIDATE (Q0472). Mac
> KS-on cut `state=active egress=direct` = Q0459 not-a-leak + Q0464 (wrong teardown) HIGH. Windows suites
> owned elsewhere. (Q0445's 2s guarantee is unit-enforced by the signed mutant regardless of field noise.)

## 3. Bug disposition (graded)

Every bug found, its fix, and the grade. Code-signed = own-run surgical mutant, subs=1, 1:1
discrimination on a fresh checkout; live = own-read raw on devnet.

| Q | What | Fix | Grade | Evidence |
|---|------|-----|-------|----------|
| Q0433 | CLI/client leaks raw gRPC after the plain line | daemonDownError (#49/7b4d031, fork b854006) | ✅ code-signed + live (app+CLI) | mutant FAILs TestWrapCallError/TestDialer 1:1 |
| Q0441 | client rejects a 429 lacking Retry-After | error.go stamps Retry-After:2 (final5.2 0c4618e, #62 ff0b180) | ✅ code-signed + live A/B | mutant `==""`→`!=""` FAILs TestBusyAnswer_PassesTheClientValidator 1:1; live (TS36 G4X): client held pure cb33092e, node-only diff — A fails "Retry-After missing", B clean "rate_limited", 1:1 |
| Q0443 | node exits on a start-time 429 | start-check wait (#74/9a24ff2) | ✅ code-signed + live serve-through | -32429 mutant 1:1; TS36 G4X A/B + #28b real node |
| Q0444 | client mislabels network-down as credit-exhausted | creditCloseAssumed && !networkDown (fork 718d25d, FIXED-FORK — absent on 26de5240) | ✅ code-signed + live | mutant drop networkDown 1:1; TLX s3_cut90 0 credit-mislabel |
| Q0445 | status reads healthy >2s after node loss | sample() flags stats-unavailable (#75/f7bbc7c); rx-stall detection (final6.1 c1d9419) | ✅ code-signed (both) | mutant FAILs "must not read healthy >2s" 1:1; rx-stall mutant (drop `conn.rxStalled(now) ||`) FAILs TestRuntime_IssueLoop_ReportsReconnectingWhenTheTunnelReceivesNothing 1:1. (hy2 cut90_ks field CANDIDATE Q0472 now resolved — rx-stall fix in final6.1) |
| Q0463 | CLI/app leaks raw gRPC on restart/not-ready | daemonDownError path (Q0433) + S2 words 0 "rpc error: code" | ✅ S2-clean; ⚠ not-ready path = Q0471 | S2 all 12 words rows PASS, 0 raw suffix; BUT awg not-ready "waiting for network: preflight failed: rpc" still leaks raw suffix (Q0471) |
| Q0446 | syncChain 429 not ridden out at start | retry-while-chainUnavailable (#74/6311f73, 739739f) | ✅ code-signed + live A/B | mutant→if true FAILs both pkgs; TS36 G4X-sync serves |
| Q0453 | revoked-delegate start leaks raw OwnerMismatch(4) | explainOpenFailure (#64/0321923, fork 5b85986) | ✅ code-signed (upstream+fork) | mutant drop OwnerMismatch FAILs revoked_approval 1:1 |
| Q0458 | key sweep could send full balance | Lamports = balance - fee (final6 f891749) | ✅ code-signed | mutant drop -fee FAILs TestKeySweep 1:1 |
| Q0459 | Mac KS-on 90s cut — direct egress? | n/a (not a leak) | ✅ NOT-A-LEAK (higher bar) | own-pcap: 0 non-node egress in armed window; control discriminates |
| Q0460 | client StartSession leaks raw getAccountInfo on unreachable RPC | chainUnreachable→Unavailable+plain (#77/f89c559) | ✅ code-signed | mutant drop guard FAILs TestGRPC_...PlainWords 1:1 |
| Q0461 | orphaned tunnel still routes after SIGKILL (status none) | Pdeathsig guard removes iface on daemon death (final6 630e232) | ✅ code-signed | mutant drop Pdeathsig FAILs TestGuard (real SIGKILL) 1:1 |
| Q0464 | KS wrongly lifts mid-cut ("stopped by user" mislabel skips #57 hold) | (FWX, in progress) | ⏳ HIGH — live rerun pending (bar: pcap 0 direct while KS on) | DIR-filed from Q0459 grade |
| Q0331 | clock-skew: node forfeits earned vouchers (T10c) | refuse-new + redeem-at-chain-time (de19127) | ✅ code-signed (loop+refuse+chain-time) + live A/B | money conservation −2 unredeemed = +2 redeemed; mutant chainNow()→local 1:1 |
| Q0465 | keyed gate token leak in plan-manager logs | n/a (not leaked) | ✅ NOT-A-BUG | own-scrub 3 logs = 0; own positive control = 1 (discriminates) |
| Q0471 | awg not-ready path leaks raw gRPC suffix | waiting-for-network plain words (final6.1 c9d7ae2) | ✅ code-signed | mutant (guard→`false`) FAILs TestWrapCallError/unavailable_waiting_for_network 1:1; fixes "not ready … waiting for network: preflight failed: rpc" |

Other upstream PRs graded (prior): #70 closing-status (da62fc8), #72 keep-leases (0a2ca1e),
#62 -32429 rate-limit (976ebe3 + 2ee120e), #69 redeem-due (e100ecd + 1ce7b88), #66 final-voucher
skip-audit (fba25bc) — all code-signed 1:1.

> **OPEN (money) — Q0438: an ORDERING bug, not a missing fix.** The fork already carries the
> leftover-metering feature (`PeerCarryover`/`carryLeftover`) in every cut — but `clearLeftovers`
> removed the `dvpn-<tag>` interface before the carrying service's `Start` read its counters, so
> the bytes a kernel WG peer forwarded while the daemon was down were never billed (~44 MB/kill;
> TS36 WG-kill row node 11,422 vs client 55,547). Fix = reorder so a `PeerCarryover` service keeps
> its interface through `clearLeftovers` (`fs36-f6-order.patch`, test
> `TestRuntime_ClearLeftovers_KeepsTheInterfaceACarryingServiceReads`), landing in final6.1 — **not**
> a port of upstream #47 (porting #47 on top would double-bill). Correction: an earlier ABW note
> here read "`LeftoverStatsReader` 0 hits → #47 absent, port it"; that was a name artifact (the fork
> uses `PeerCarryover`), caught by FS36. Q0192's WG-money part waits on this fix; its false "node
> overcharging" end is already gone (WG+AWG).

## 4. End-to-end corroboration (non-suite)

Full paid-session e2e runs on the final cuts, cross-checking that the component results compose
into a working product. All ABW own-read.

| Run | Cut | Result | Evidence (ctl-1) |
|-----|-----|--------|------------------|
| #29 Plan Manager (node-4 ovpn) | final3 131d3a2 | 102/0/0 | ~/plans29/e2e-final3b.log |
| #29 Plan Manager (node-4 hy2) | final5 718d25d | 102/0/0 | ~/plans29/e2e-final5.log (money exact, sweep over HTTP) |
| #29 Plan Manager (node-4 hy2) | **final6 630e232** | **102/0/0** | ~/plans29/e2e-final6.log (money exact S80-S96; Q0465 not-a-bug, token-scrub 0 + control 1) |
| #1b (node-4) | final5 718d25d | 129/0/0 | ~/snt1b/e2e-final5.log (M2 285.51 Mbps, M2b 366 MB, X3 cleanup) |
| #1b (node-4) | **final6 630e232** | **118/0/1** | ~/snt1b/e2e-final6.log (skip = plan-section --plan-skip per DIR; M2 298.33 Mbps, M7 memo decodes from chain) |
| #28b Node Manager local | final5.1 8ff1b27 | 70/0/2 | 0 fails; skips = outside-reach + time-gated bond |
| #28b Node Manager remote | final5.1 8ff1b27 | 76/0/1 | 0 fails; 1 time-gated skip; slow Docker creates = host/harness (28cae4e 120s guard) |
| #28b Node Manager local | **final6 630e232** | **70/0/2** | 0 fails; + live-429 serve-through re-proves Q0443 (real gate −32429, restarts=0) |
| #28b Node Manager remote (ufw) | **final6 630e232** | **76/0/1** | 0 fails; ~/fleet/r429-node-… |

> final6 closes graded so far: plan-manager 102/0/0, node-tester 118/0/1, node-manager 70/0/2 +
> 76/0/1 (all ABW own-read). Mac / Android / TWA(Windows) / TS36 S11 follow as their raw lands.
> Note: final6.1 (= 81d3fee + Q0441-classify + Q0438-order, both ABW-signed 1:1) is the cut that
> carries the Q0438 WG-kill-metering and Q0441 auth-grant-classify fixes; §3 rows cite it.

## 5. Final version per product

Pinned from the build owners' `SHA256SUMS` on the controller. The daemon `dvpnd` is the shared
heart; each product pins the exact fork-cut binary by hash.

| Product | Cut | Binary / dvpnd hash | Evidence |
|---------|-----|---------------------|----------|
| daemon (dvpnd) | final6 630e232 | (from gate SHA256SUMS) | FWX stage dir, sha256 -c |
| Devnet dVPN — Windows | — | — | TWA stage (final6 run started 16:53Z) |
| Devnet dVPN — Linux | — | — | FLX stage |
| Devnet dVPN — macOS | — | — | FMC stage |
| Devnet dVPN — Android | — | — | FAN stage |
| Node Manager (Solana) | final5.1 8ff1b27 | — | #28b stage |
| Node Tester (Solana) | — | — | #1b stage |
| Plan Manager (Solana) | final6 630e232 | — | #29 stage (e2e-final6 green) |

> Hashes fill in as each product's final6 build + SHA256SUMS land; `—` = not yet pinned. Hashes are
> read from the owners' SHA256SUMS, never transcribed from chat.
