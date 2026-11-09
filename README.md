# dVPN App Testing Tools

How we tested seven Sentinel dVPN products on Solana devnet against the public upstream
[`sentinel-official/sentinel-solana`](https://github.com/sentinel-official/sentinel-solana), end to end: every test on
every OS, every bug we found and how each was fixed, the tools, and how an AI agent fleet ran the work.

Use this repo to repeat the whole effort on a new upstream commit.

## The seven products

| Product | Platform | What it is |
|---|---|---|
| Devnet dVPN for Windows | Windows x64 + arm64 | Desktop app (Electron) driving the `dvpnd` daemon |
| Devnet dVPN for Linux | Ubuntu, Debian, Fedora, Rocky (x64 + arm64) | `.deb` / AppImage + CLI |
| Devnet dVPN for macOS | Intel (Apple Silicon built, not live-proven) | `.dmg` + CLI |
| Devnet dVPN for Android | Android 15/16 (emulator + real phones) | Kotlin + WebView app with an on-device daemon |
| Node Manager | Linux hosts | Deploys and runs dVPN nodes, locally or over ssh |
| Plan Manager | Web + CLI | Creates subscription plans and links nodes to them |
| Node Tester | Web + CLI | Tests nodes end to end with paid sessions |

## Downloads

Each product has its own repo and a final release (devnet only, builds are not publisher-signed). Every release
carries `SHA256SUMS`; its notes list what was tested on that exact build. The apps run on fork cut final6.5
(`90014b2`); the node tools keep the final6.1 build they were tested with (final6.5 changed client code only).
Results: [`docs/04-results.md`](docs/04-results.md). Known problems:
[`docs/known-issues-rc1.md`](docs/known-issues-rc1.md).

| Product | Final release |
|---|---|
| Windows app | [`sentinel-solana-dvpn-windows` 0.2.0](https://github.com/Sentinel-Bluebuilder/sentinel-solana-dvpn-windows/releases/latest) |
| macOS app | [`sentinel-solana-dvpn-macos` 0.1.3](https://github.com/Sentinel-Bluebuilder/sentinel-solana-dvpn-macos/releases/latest) |
| Linux app | [`sentinel-solana-dvpn-linux` 0.1.21](https://github.com/Sentinel-Bluebuilder/sentinel-solana-dvpn-linux/releases/latest) |
| Android app | [`sentinel-solana-dvpn-android` 0.1.4](https://github.com/Sentinel-Bluebuilder/sentinel-solana-dvpn-android/releases/latest) |
| Node Manager | [`sentinel-solana-node-manager` 0.2.0](https://github.com/Sentinel-Bluebuilder/sentinel-solana-node-manager/releases/latest) |
| Plan Manager | [`sentinel-solana-plan-manager` 0.1.0](https://github.com/Sentinel-Bluebuilder/sentinel-solana-plan-manager/releases/latest) |
| Node Tester | [`sentinel-solana-node-tester` 0.1.0](https://github.com/Sentinel-Bluebuilder/sentinel-solana-node-tester/releases/latest) |

## Quick start

1. Read `docs/00-overview.md` for the architecture: upstream vs fork, the two reference nodes, the RPC lanes.
2. Read `docs/01-test-method.md` for the five checks that run in every scenario and suites S0–S13.
3. Run the harness on one Linux machine against a live devnet node. The machine needs the Linux app package, a client
   instance with a funded wallet, and a node id and address. The exact steps (about 25 minutes the first time) are
   `docs/02-platforms/linux.md` §5, "From zero". Once those exist:
   ```
   cd tools/cb33-matrix
   export INSTANCE=c1 CBM_DIR=$HOME/cb33 CBM_MINT=<tDVPN mint> NODE4_ID=<node address> NODE4_IP=<node ip>
   bash cb33-matrix.sh --platform linux --selftest          # every built-in check must FAIL on its planted fault; needs no node
   bash cb33-matrix.sh --platform linux --side B --node node-4 --suites S1 --out ~/cbm-first
   ```
   `--node node-4` means "the node named by `NODE4_ID` / `NODE4_IP`" (any node; the name is historic).
   `tools/cb33-matrix/README.md` lists every setting.
4. For the whole effort, follow `docs/09-runbook.md` step by step.

## Map

| Path | What's there |
|---|---|
| `docs/00-overview.md` | Architecture and timeline |
| `docs/01-test-method.md` | Built-in checks, suites, A/B with one side changed, mutants, reuse by what changed |
| `docs/02-platforms/` | One page per OS: rigs, adapters, how to run, gotchas, final results |
| `docs/03-node-side.md` | Reference nodes, the node lab, liveness, metering |
| `docs/04-results.md` | Every OS × suite result with its evidence and the final build hashes |
| `docs/05-upstream.md` | How a finding became an upstream issue and fix PR; the merge order |
| `docs/06-money.md` | Funder, wallets, top-ups, reclaim, books |
| `docs/07-infra.md` | Machines, cloud-only rule, RPC gate and lanes, secrets |
| `docs/08-ai-fleet.md` | How the AI fleet ran: roles, communication, autonomy rules, lessons |
| `docs/09-runbook.md` | Repeat everything on a new upstream commit |
| `docs/10-bugs.md` + `bugs/` | Every bug identified and how it was resolved |
| `tools/` | Harness, Test Lab runner, money tools, infra tools, secret scan |
| `templates/` | Plan of record, director queue, heartbeat, handoff, PR body, watchdog prompt |

## Rules for this repo

- Every claim points to evidence: a log, commit or PR.
- Nothing secret: no keys, tokens, wallet files, gate URLs or machine addresses. Run `tools/secret-scan.sh` before
  every commit.
- Devnet only.
