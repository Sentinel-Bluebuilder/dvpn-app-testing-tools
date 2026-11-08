# tools/

The harness and utilities used to test the dVPN apps across Linux, Windows, macOS and Android.
Everything here is **parameterised and secret-free**: no keys, tokens, wallet files, provider URLs,
gate hosts or VM IPs. A publish gate (`secret-scan.sh`) enforces that.

## Layout

| Path | What | Owner |
|---|---|---|
| `cb33-matrix/` | The test harness: a driver (`cb33-matrix.sh`), 5 built-in checks (`checks/`), suites `S0`–`S13` (`suites/`), per-OS adapters (`plat/{linux,windows,macos,android,lab}.sh`), a `lib/`, a `selftest/`, and the harness's own tools (`tools/`: A/B scenarios `*-ab.sh`, `soak.sh`, capture helpers). See `cb33-matrix/README.md`. | FLX2 + rig owners |
| `money/` | Top-ups (`sol-topup.sh`), the reclaim pipeline (`money.sh list/own/sweep`, `reclaim-run.sh`) and the books (`money.sh books`). All values from env; dry run by default. See `money/README.md`. | #1b + DIR |
| `secret-scan.sh` | OSS-publish gate: fails on any API key, provider URL with a key, base58 secret, public/VM IP, ssh private key, or supplied personal name. | FLX2 |

### Running the harness
The harness is driven by `CBM_*` environment variables (no values are baked in):
`CBM_DIR` (harness dir), `INSTANCE` (client instance, e.g. `c0`/`c1`), `CLI_HOME`, `CFG` (daemon config),
`CBM_PLAT` (adapter), `CBM_BIG_URL` (throughput target, default a public speed endpoint),
plus the per-run topology vars below. See each adapter's header for its own knobs.

### Running the gate
```
tools/secret-scan.sh <dir>     # exits non-zero and prints LEAK[...] lines on any finding
```
Optional env: `SCAN_EXTRA_NAMES` (names to flag), `SCAN_ALLOW_IPS` (extra doc-example IPs),
`SCAN_SKIP_GLOBS`. The scanner hard-codes no secret and is safe to run in CI.

## Not yet in this directory (owner-domain tools)

Per the plan these are `FLX2 + owners`; they carry funder wallets, a controller IP and RPC-provider
topology, so their owners produce the scrubbed public versions (or decide to omit them). Each must
pass `secret-scan.sh` before it lands here.

| Tool | Why it is owner-domain | Owner | Leaks to scrub first |
|---|---|---|---|
| `fleet-watch` | SSHes the fleet to read load / RPC lanes | DIR (infra) | controller public IP, ssh key path, VM aliases |
| `rpc-failover` | Rotates the Helius RPC lanes | DIR (infra) | provider key env paths, private gate host:port, clients.json |
| `ftl-run` | (no script on disk; only `ftl-*` **wallet files**, which must never ship) | DIR / #1b | n/a — do not add wallet files |

## Topology scrub (applied to this staged copy; `secret-scan.sh` passes)

The harness was already parameterised — every live-topology value was a `${VAR:-<default>}` with a
baked default. The scrub strips each baked default so the env var is required (matching the harness's
own `*) ...:?set NODE_IP for a custom node` fallback). **This is applied to the published copy only;
the fleet's live working copy keeps its fleet-convenience defaults until the finish, so active fleet
runs are not disturbed.** The exact, reproducible recipe (run at repo assembly, after `git archive`):

```sh
# in tools/cb33-matrix/, over plat/{linux,android,mac,windows}.sh:
#   ${NODE3_ID:-<node-3 pubkey>}  -> ${NODE3_ID:?set NODE3_ID (node-3 pubkey)}
#   ${NODE3_IP:-<node-3 ip>}      -> ${NODE3_IP:?set NODE3_IP}
#   ${NODE4_ID:-<node-4 pubkey>}  -> ${NODE4_ID:?set NODE4_ID (node-4 pubkey)}
#   ${NODE4_IP:-<node-4 ip>}      -> ${NODE4_IP:?set NODE4_IP}
#   ${CBM_MINT:-<tdvpn mint>}     -> ${CBM_MINT:?set CBM_MINT}
#   ${CBM_MGMT_IPS:-<controller ip>} -> ${CBM_MGMT_IPS:-}   # mgmt exemption optional
# selftest/ offline fixtures: real IPs -> doc-reserved 192.0.2.x
# leak.sh / checks/leak.sh: strip the one stray node IP from a comment
```

So after assembly a user sets `NODE3_ID/IP`, `NODE4_ID/IP`, `CBM_MINT` (and optionally `CBM_MGMT_IPS`)
for their own deployment; no node, mint or controller identity ships.

Well-known public constants are **not** leaks and stay as literals: Azure wireserver `168.63.129.16`,
public DNS `1.1.1.1`/`8.8.8.8`/`8.8.4.4`, CGNAT `100.64/10`, RFC2544 `198.18/15`, GitHub-Pages
`185.199.108.x`, `0.0.0.0/8`, and the `45.1.2.x` / `192.0.2.x` selftest fixtures. The scanner's
allow-list exempts them; override with `SCAN_ALLOW_IPS` if your deployment adds more.
