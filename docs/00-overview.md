# 00 — Overview

## What we set out to prove

Seven Sentinel dVPN products, built on the Solana version of the Sentinel protocol, work end to end on devnet against
the **public upstream** `sentinel-official/sentinel-solana` at base commit `26de5240`. "Work" means: they connect on
every protocol and keep status honest. They never leak with the kill switch on, charge the right amount, leave
nothing behind, and install, upgrade and uninstall cleanly. Every bug found was fixed, and every fix that belongs
upstream was sent as a public pull request with a reproduction and a test.

## Architecture

```
            public upstream (base 26de5240)
                     │  3-way merge
                     ▼
              fork cut (rc1 … final5) ── gate: build, vet, cross-builds, race tests
                     │  staged binaries + SHA256SUMS on the controller
       ┌─────────────┼──────────────────────────────┐
       ▼             ▼                              ▼
  client apps     node tools                  reference node B (fork)
  (Win/Linux/     (node manager,               reference node A (pure upstream)
   Mac/Android)    plan manager, node tester)         ▲
       │                                              │
       └──────── test sessions (6 protocols) ─────────┘
                     │
              Solana devnet ◄── RPC gate ◄── lanes ◄── provider keys (failover every 5 min)
```

- **The `dvpnd` daemon** is the heart of every product: it opens payment channels, runs the protocol client or
  server, meters traffic and settles on chain. The apps are front ends that drive it over gRPC.
- **Fork:** our changes on top of upstream. Each fork commit is NEEDED (still missing upstream), FIXED-UPSTREAM or
  OBSOLETE. Versioned cuts let every product pin the exact same binaries by hash.
- **Two reference nodes:** A runs pure upstream, B runs the fork. A client-side fix is proven by changing only the
  client against node A. A node-side fix is proven by the same client against A and then B. One side changes at a
  time.
- **Protocols:** WireGuard, AmneziaWG, OpenVPN, Hysteria2, V2Ray, Xray.
- **RPC:** one gate with per-client tokens in front of several provider keys, with automatic failover
  (`docs/07-infra.md`).

## How the work was organised

An AI agent fleet ran the work under one plan of record: a director, an independent grader, a fork owner, an
upstream reviewer, one owner per product, testers per OS and two node-side agents (`docs/08-ai-fleet.md`). The human
owner set direction and made the few calls only an owner can make.

## Timeline

| Phase | What happened |
|---|---|
| 1. Unblock | Fork gate green, cloud accounts and wallets ready. |
| 2. Rebuild all 7 | Every product rebuilt on the fork cut, pinned by hash. |
| 3. Script + coverage map | One harness (`tools/cb33-matrix`) with an adapter per platform; every earlier bug mapped to a suite and scenario. |
| 4. Prove the script | Planted failures caught by every check; a pure run finds the known bugs. |
| 5. Full run | Suites S0–S13 on every platform; real phones in Firebase Test Lab; the node lab. |
| 6. Upstream | Every upstream bug got an issue and a fix PR; cold reproductions; a stack check of all PRs together; one index issue with the merge order. |
| 7. Final cuts | final3 (client), final4 (node: listing renew), final4.1 (node: redeem-now, rate-limit handling, busy RPC at start; Mac AmneziaWG), final5 (client: the end reason after a short cut), final5.1 (node: wait out a busy RPC at start), final5.2 (node: `Retry-After` on a 429), final6 (the last cut: honest status within 2 s on a protocol or session kill, plain-words errors, the device-wallet key sweep, the orphan-tunnel fix). Targeted reruns on each. |
| 8. Close out | Reclaim every wallet, books, the grader's final review, machines stopped, this write-up. |

The numbers for each phase (rows, PRs, pass/fail) go in `docs/04-results.md` and `docs/10-bugs.md`, each with its
evidence. Both are written last, after the grader's final review, so every number in them is final.
