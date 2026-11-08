# Tools — Node Manager, Plan Manager, Node Tester

<!-- #29 (Plan Manager) adds its section here. -->

## Node Manager for Solana

Code: the private `sentinel-node-manager-solana` repo. A public export (fresh squashed tree, `tools/export-public.sh`)
waits for the owner's go.

### What it is

An Electron + React desktop app that deploys and runs Sentinel dVPN nodes on the Solana `dvpn` program (devnet). A
node runs on the same computer ("local", Docker) or on a server reached over SSH ("remote"; the app installs Docker
there). The app never re-implements the program: program calls go through `sentinel-dvpn` (the CLI) inside the node
image, and the node itself is `sentinel-dvpnd run --instance n1` in a container. Wallet transfers use
`@solana/web3.js`.

The node image is built from the fork's source tree. Its tag is a hash of the Dockerfile, the build arguments and the
source, so a new fork tag always builds a new image. Xray and Hysteria2 come from `<source>/.snm-vendor/` when present
(hash-pinned copies; the pinned SHA256 is checked either way), from their GitHub releases otherwise.

### Rigs

| Rig | What it proves | Notes |
|---|---|---|
| Control VM, headless app | Local mode on Linux (rootful Docker, app as a non-root user) | Electron under Xvfb in a transient systemd unit; CLI server on a Unix socket. The cloud firewall has no node ports, so outside reach can't be proven here (one environment skip). |
| GCP test VM, ufw on, node ports open in the cloud firewall | Remote mode end to end: host firewall rule, outside clients, paid sessions | ufw is switched on with SSH allowed first. Stop the VM when idle. |
| Azure test VM, no host firewall, SSH only (FINAL2) | Remote mode where the cloud blocks node ports | Proves paid sessions from the node's own host; outside-reach rows can't run. |

### How to run

1. Put the fork's source tree on the control VM; the launcher takes `NM28B_UPSTREAM=<dir>` and sets the app's
   `upstreamDir`.
2. `nm28b-app.sh start` builds the app, starts it under Xvfb, and waits for the CLI socket.
3. `nm28b-app.sh e2e --target local|remote --protocols wireguard,hysteria2 [--ssh-host … --ssh-user … --ssh-key …]`,
   with `TEST_KEYFILE` (the funded devnet test key) and the gate's RPC env file loaded.
4. After the bond unbonding (1 h) and the channel grace (2 h): `e2e --finish` with the same SSH flags. It withdraws the
   bonds, sweeps the node keys, refunds the test channels, and checks on chain and on the host that nothing is left.
5. Chain tests run one at a time, never two suites at once. Each run locks 1 tDVPN of bond for 1 h and needs ≥ 4 tDVPN
   at the start.

### The suite (`tests/e2e/cli-e2e.mjs`)

P0 CLI and registry · P1 wallet (create, restore, import, funds) · P2 settings and RPC health · P3 send · P4 deploy (node
account on chain; remote: ufw active and the node's rule present) · P4b a deploy cancelled after funding (key swept) ·
P5 inspect (reachable, signed metadata, TLS pin, discoverable) · P6/P7 paid sessions per protocol from a throwaway client
container, plus an outside client on the public URI (remote) · P8 prices on chain and across a restart · P9 revenue
withdraw · P10 stop, start, relist, close session, redeem · P11 test-channel sweep and host-leftover scan · P12 remove
(delist, close, unbonding) · P13 finish (bond, key sweep, refunds, nothing left on the host) · P14 diagnostics export.

A row skips only for a stated environment reason. Since final3 the only skips are the time-gated bond row (closed by the
`--finish` report) and, in local mode, outside reach.

### Final results

| Fork tag | Local | Remote | Notes |
|---|---|---|---|
| fork-cb33-4-final2 (9a2e810) | 70 / 0 / 2 | 76 / 0 / 1 (ufw host) | |
| fork-cb33-4-final3 (131d3a2) | 70 / 0 / 2 | 76 / 0 / 1 | ABW confirmed |
| fork-cb33-4-final4 (5fdc34b) | 63 / 6 / 2, then 70 / 0 / 2 | 72 / 4 / 1 | First local run: the gate refused the app at a client cap and the node daemon exited (upstream bug Q0443, below). Remote: shared ufw rule removed (app fix 0aba731), RPC refusals, a slow Docker create. |
| fork-cb33-4-final4.1 (2ee120e) | 69 / 1 / 2 | 76 / 0 / 1 | The local fail: a Docker create took over 30 s (app 28cae4e: 120 s limit, slow creates logged) |
| fork-cb33-4-final5.1 (8ff1b27) | 70 / 0 / 2 | 76 / 0 / 1 | App 28cae4e. Report `e2e-2026-11-08T15-00-34-719Z.md` (local). Six container creates took 10.8–29 s and passed under the 120 s limit. |
| **fork-cb33-4-final6 (630e232, last cut)** | **70 / 0 / 2** | **76 / 0 / 1** | App d77c414. Reports `e2e-2026-11-08T17-01-33-914Z.md` (local), `e2e-2026-11-08T17-08-49-509Z.md` (remote). Live 429 crash test PASS (below). |

Close-out of the final6 runs (finish, withdraw, sweep): PENDING.

### Node crash under RPC refusals (Q0443 / Q0446, upstream)

A node daemon exited with `preflight failed: rpc` (exit code 1) when its RPC answered 429 at start, then crash-looped
under Docker for as long as the RPC refused it. Found in the final4 run, then reproduced with a fake RPC that answers
only 429 (no chain transactions) on pure 26de5240 (exit after 1.5 s) and on final4 (exit after 7.7 s). Only the client
runtime had a wait for an unreachable RPC (`run.go`, `startBlocker`).

- Q0443 (start checks): fixed in fork 9a24ff2 (upstream issue #73, PR #74).
- Q0446 (the chain sync in `Runtime.Start`, `fetching config`, after the start checks pass): found by the live test on
  final4.1; fixed in final5.1.
- Proof on final5.1:
  - Fake RPC that answers the start checks and refuses only the config read: 30 refusals over 75 s, 0 restarts.
  - Real deployed node pointed at a gate client capped at 1 credit for 2 minutes: 36 refused `getHealth` calls,
    0 restarts, "start checks passed", "service started" and "ready" within 1 s of the cap lifting.
  - The live cap stops the node at `getHealth`, so the config-read wait is proven by the fake test only.
- Final6 live test: 0 restarts, the node waited through the cap, then "start checks passed", "service started" and
  "ready" after the lift.

### Gotchas

- **Local mode on Linux:** the node container writes root-owned files into the node home. A non-root app needs `sudo -n`
  for those paths (the app falls back to it), or rootless Docker.
- **The final client refuses a node whose address isn't public,** so a local deploy publishes the machine's public IP.
- **A node or client on another server can't reach this machine's loopback or private RPC addresses.** Remote runtimes
  skip local-only RPC URLs.
- **web3.js puts the websocket of an `http://` RPC on port + 1.** The gate serves websockets on both ports; a gateway
  that doesn't breaks `sendAndConfirmTransaction` ("block height exceeded" on a landed transaction).
- **ufw rules are keyed by port range.** A node deployed on the ports of a node still being removed shares its rule; the
  app now keeps a rule while another node on the same host holds it.
- **GitHub release downloads can fail (504) for everyone at once.** Keep the hash-pinned `.snm-vendor/` copies with
  the source.
- **SSH credentials live in memory only.** After an app restart, remote cleanup waits for `nodes.reconnect`.
- **The CLI allows one client at a time.** A second client gets "busy: held by agent". Scripts must check for that
  instead of reading the reply as a result.

## Node Tester for Solana

Public code:
github.com/Sentinel-Bluebuilder/sentinel-solana-node-tester.

### What it is

The Cosmos Node Tester (server, pages, database, continuous loop) moved onto the Solana `dvpn` program on devnet. It
finds every listed node, checks its signed metadata, pays for a real session on it, measures the speed, and writes a
signed report memo on chain. The pages and API are the Cosmos ones, kept identical on purpose (wording edits only), so
the same dashboard serves both chains.

### How a test runs

1. **Discovery + scan.** Read node accounts from the program, fetch each node's metadata, and refuse it before paying if
   the signature, the claims or the TLS certificate pin are wrong.
2. **Paid session in a throwaway container.** The client (`dvpnd`) never runs on the host: a client captures the default
   route and adds a kill switch, which would cut the tester's own RPC and dashboard. Each session is one Docker container
   with its own network namespace, deleted on exit.
3. **Channel recorded the moment the client prints it,** not when the container exits, so a crash cannot lose it.
4. **Speed.** The steady method: our own pinned origin serves unpredictable bytes; 4 time-bounded streams for 10 s;
   steady-state median; every byte verified. A tampering or capped origin is reported as that, never as a node speed.
5. **Close.** Per-hour (stream) channels are closed right after the session because they bill until closed; per-GB
   (voucher) channels are closed by the sweep after the 2 h grace.

Modes: per GB (default), per hour (`start --hours`), subscription plan (`--plan`, access tickets). **TEST RUN** does
discovery and scan only, with no channel, memo or spend.

Not-the-node failures (protocol unsupported, plan connection limit, speed source unavailable, client exited, Docker
unavailable) are skips, not node failures, and are never reported on chain as the node's fault.

### Running it

- Linux host with Docker (the fleet ran it on the cloud build box; never on a laptop).
- `.env`: RPC URLs (the fleet's RPC gate first, public devnet as fallback), `TEST_KEYFILE` (a devnet key file),
  `DVPND_IMAGE` (client image tag), speed origin URL + pin.
- Client image: `scripts/ops/repin-client.sh <stage-dir> [--apply]` checks the build's SHA256SUMS and manifest, builds
  `snt-tester/dvpnd:<tag>`, checks the binaries inside the image against the sums, and with `--apply` sets `DVPND_IMAGE`.
  Only release tags (`fork-cb33-N-rcN` / `-finalN`) pass the build check.
- `npm test` (unit, handlers, page and server drift checks) before every commit.
- `npm run test:e2e` drives every CLI command live (spends a few channels); `npm run test:e2e:finish` after the 2 h grace
  closes them and checks the refunds. `--node`/`--node2`/`--only` limit it to named nodes, so other teams' nodes on the
  shared devnet are never touched.

### Money tools (see 06-money.md)

Wrapped for the fleet in `tools/money/` (see its README). In the tester: `scripts/ops/books-cb33.mjs` (books), `reclaim-cb33.mjs` + `reclaim-fill-rent.mjs` (reclaim list), `reclaim-own.mjs`
(close and withdraw a wallet's own rows), `sweep-to-funder.mjs` (return funds, keep a reserve). All read-only or dry run
by default.

### Final results

| Build | Node | Result | Evidence |
|---|---|---|---|
| fork-cb33-2 + pure client (S13, 11-07) | node-4 | 116 PASS / 0 FAIL / 2 SKIP | e2e-3-steady.log |
| fork-cb33-4-final2 (11-08) | node-4 | 129 / 0 / 0 | e2e-final2e.log; rerun with the websocket fix e2e-final2f.log 129 / 0 / 0 |
| fork-cb33-4-final3 (11-08) | node-4 | 128 / 1 / 0, plus a single-session M2b rerun PASS = 129 / 0 / 0 | e2e-final3.log; the 1 was the speed origin's per-IP daily cap refusing the node (cost guard, not the build); rerun with the origin in lab mode for one session, 540 Mbps steady, 521 MB verified |
| **fork-cb33-4-final5 (11-08, last client cut)** | node-4 | **129 / 0 / 0 in one run** (ABW confirmed) | e2e-final5.log; paid session 285.51 Mbps, steady 285.51 payload / 311.95 line, 366 MB verified, Stop clears the container within 10 s |

Close-out of the final5 run (finish, withdraw, sweep): PENDING, ~2 h after the run.

### Gotchas

- **The speed origin has a cost guard:** 10 GB per IP and 30 GB in total per day. Many runs through one node in a day
  exhaust that node's allowance, and the steady check then fails with "origin request failed". `--lab` lifts the guard
  for a short, logged window.
- **Client containers must stop, not vanish.** Removing a container while its client holds an RPC websocket leaves the
  socket open on the gate for about 5 minutes. The session script traps SIGTERM and stops the daemon, and the tester
  runs `docker stop -t 3` before `rm -f`.
- **RPC gate rate cap:** keep ≥ 8 s between full account scans on one token.
- **Decode with the IDL and the deployed account sizes**, never `program.account.X.all()`; branch on error numbers, not
  messages. The cb33 IDL renamed `rent_payer` to `rent_recipient`.
- **Chain transactions are sequential, ≥ 7 s apart.**
- **The wallet is shared** with other tools, so the refund sweep touches only the channels the tester itself recorded.
