# cb33-matrix

The one test script for the cb33 plan (agents/PLAN-cb33-FINAL.md §1). Skeleton by FWX, 2026-11-07.
Canonical copy: this folder. Copy it to the controller for runs; never edit the copy there.
**Never mirror over a tree a run is using.** Runs execute from the tree itself (`cd ~/cb33-matrix && bash cb33-matrix.sh`),
so replacing files mid-run mixes versions (11-08: a status.sh trap parse error killed a run). Before a mirror, check
`pgrep -af 'bash cb33-matri[x].sh'` (the bracket stops it matching the ssh command that runs it); if any run is live, extract to `~/cb33-matrix-<rev>` and point new runs there.

## Run

```bash
bash cb33-matrix.sh --platform linux --side B --node node-3 --suites S1,S2,S3 --out ~/cbm-<label>
bash cb33-matrix.sh --platform linux --selftest      # phase 4: every built-in check must FAIL on its planted fault
```

- `--side A|B`: A = pure cb33 build, B = fork-cb33-1. The script only records it; you install the build.
- `--node`: `node-3` (pure 26de5240) or `node-4` (fork). Client fixes run A and B against node-3 (PLAN §1c).
- `--channel <id>`: reuse one channel for the whole run (no channel per cycle). Without it the first connect opens one
  with `--new-channel` and every later connect reuses it.
- Freeze is lifted for cb33 clients: close/settle allowed, 7 s between txs per wallet (`tx_gap` in lib/common.sh).

Scenario list entries are `fn:ks` or `fn:ks:once` (once = protocol-independent, e.g. app screens: run on the first protocol only).

Output: `<out>/results.tsv` = `time  suite  scenario  protocol  check  PASS|FAIL|SKIP  detail`, plus per-scenario
logs in `<out>/<suite>/<scenario>-<protocol>/`. A scenario row FAILs if any check FAILs.

## Layout

| Path | What | Owner |
|---|---|---|
| `cb33-matrix.sh` | driver: args, loops suites → scenarios → protocols, runs the checks around each scenario | FWX |
| `lib/common.sh` | logging, results, timing, deadman hold, tx gap, helpers every platform uses | FWX |
| `checks/*.sh` | the 5 built-in checks (§1a), each with `<check>_start`, `<check>_stop`, `<check>_selftest` | FWX |
| `plat/linux.sh` | Linux adapter (from TLX's cb33 probes, #32 8a6ba061) | FWX → FLX/FLX2 |
| `plat/windows.ps1` + `plat/windows.sh` | Windows adapter (ssh to the VM, PowerShell side) | FWA (TWA: S12 uifire) |
| `plat/mac.sh` | macOS adapter | FMC |
| `plat/android.sh` | Android adapter (adb) | FAN |
| `suites/S0.sh` … `suites/S13.sh` | scenarios; each `sN_<name>()` gets the protocol as `$1` | per table in PLAN §1b |

## Platform adapter contract

Every `plat/<name>.sh` defines these functions. The driver and the checks call nothing else, so a platform port touches
only its adapter (and its rows in a suite if a scenario needs a platform-only fault).

| Function | Must do |
|---|---|
| `plat_init` | find binaries, instance, home; set `DIRECT_IP` (egress with no VPN), `PHYS_IF`, `NODE_ID`, `NODE_IP` for `--node`; start the deadman hold |
| `plat_protocols` | echo the protocols this platform ships, space separated |
| `plat_daemon_start` / `plat_daemon_stop <TERM\|KILL>` / `plat_daemon_running` | start (wait for ready), stop with the signal, 0 if up |
| `plat_connect <protocol>` | connect over `$CHANNEL` (sets it on first use), sets `SID`; rc 0 = connected |
| `plat_disconnect` | stop every session of the instance; rc 0 = stopped |
| `plat_sessions` | echo every session id, newest first (poll all of them: the first id goes stale after a redial) |
| `plat_status_line` | one line `state=<active\|reconnecting\|ended\|none> ks=<on\|off\|persist> text=<what the user sees>`; must return in < 1 s |
| `plat_egress` | echo the public IPv4 egress or `none` (6 s cap) |
| `plat_egress6` | public IPv6 egress or `none` |
| `plat_dns_probe` | echo the resolver IP that answered (leak = not the tunnel's) |
| `plat_set_ks <off\|on\|persist>` | change the kill switch in the instance config (daemon restart is the caller's) |
| `plat_capture_start <file>` / `plat_capture_stop` | packet capture on `PHYS_IF` (pcap) |
| `plat_leftovers` | echo one line per leftover: services, firewall tables/sublayers, ip rules, routes, links, proxy, DNS rules, temp files, secrets (OpenVPN/Hysteria2 key files) |
| `plat_cut <seconds>` / `plat_uncut` | drop all traffic to `NODE_IP` (the "network trouble" fault) |
| `plat_cli_outputs` | echo every CLI/app message the scenario produced (for the plain-words check) |
| `plat_money` | echo `spent=<base units> paid=<base units> node_settled=<base units\|unknown> redeemed=<base units\|unknown>` for `$CHANNEL` |
| `plat_reset` | back to a clean state after a scenario (stop sessions, daemon up, KS off) |
| `plat_live_sessions` | echo the ids of sessions not yet ended (S4 + `plat_disconnect`; ended history is skipped) |
| `plat_switch <protocol>` | S4: replace the live session with one on the current `$NODE_ID` entry (the suite calls `node_for <protocol>` first); rc 0 = exactly one live session on the new entry. Use the platform's own switch when it has one (Android `connect --switch`); cb33 has none (StartSession refuses "a session is already active"), so Linux does stop every live session, wait ≤ 15 s for none live, then `plat_connect`. Without it S4 SKIPs (rc 77) |
| `plat_live_node` | optional, S4: echo the node (entry) address of the live session (`"node"` in `client status`), so a switch is proved to land on the new entry when entries share one IP |
| `plat_block_present` | optional: rc 0 while the kill-switch rules are loaded (Linux: the `inet sentinel-dvpn-<inst>` nft table) |
| `plat_block_sample <s> <file>` | optional, S4: ONE root `nft monitor tables` for <s> seconds, writing "<KS table events> <gaps> <longest gap ms|open>" to <file> and the timestamped events to <file>.log. A gap = the KS table deleted and not re-added within 50 ms (a re-render in one nft transaction is 2-3 ms and not a gap). `s4_watch` runs it during a ks-on switch; any gap is a BLOCK GAP (G26: pure 26de5240 1.6-2.3 s). Polling misses these gaps, and a sudo per sample stalls in them (dead DNS) |
| `plat_lan_inbound_probe` | optional, S6: echo delivered|blocked for one UDP datagram FROM the S6 LAN peer TO this host (`s6_inbound_lan_v4`, upstream #16: pure filters output only) |

## Built-in checks (§1a) and their planted faults (§4 phase 4)

| Check | Rule | Selftest plants |
|---|---|---|
| leak | KS on: zero packets on `PHYS_IF` except to `NODE_IP`, DHCP/ND, and the LAN gateway, for the whole scenario. KS off: no DNS (53/853) or IPv6 to anywhere but the node while `state=active` | a `curl` direct to 1.1.1.1 outside the tunnel |
| status | every 1 s: `plat_status_line` answers in < 1 s, and `state=active` only while `plat_egress` = the node's egress; "blocked" text only while egress = `none` | a status line forced to `active` while egress = direct |
| words | every message: no Go/RPC wrapping (`rpc error:`, `code = `, `desc = `, `context deadline exceeded`, `%!`, stack frames), no hex/base58 run > 44 chars except ids the user typed, no "please contact support" | the text `rpc error: code = Unavailable desc = x` |
| money | `spent <= paid`, `node_settled` within 1 % or 1 base unit of `spent` once closed, no "node overcharging" line | `spent` > `paid` |
| leftovers | after `plat_reset`: `plat_leftovers` prints nothing | a planted `sentinel-dvpn-c9` nft table / tunnel service |

## Rules learned the hard way (TLX, FLX2, FWX)
- With a kill-switched session up, inbound SSH is blocked: the deadman hold (`/run/ddv-deadman.hold`) runs for the
  whole script, refreshed every 30 s, and the trap always lifts cuts and stops sessions.
- Never count inside `$(...)`: a counter set in a subshell reads 0. Count from the printed line.
- `client status <first id>` goes stale after a redial (Q0423); `plat_sessions` returns every id.
- One channel per run (`--channel`), 7 s between txs per wallet.
- Times are measured with a monotonic clock (`date +%s%3N` is wall time: the S5 clock-jump scenario breaks it; use
  `ms_mono` from lib/common.sh).

## Added 11-07 (evening)
- **Throughput floor (S1, DIR):** each protocol's 50 MB download is recorded in `<out>/throughput.tsv` (`protocol  MB/s  bytes  seconds`) and judged as a `throughput` row: FAIL under 30 % of the same run's WireGuard rate, or under 50 % of the A run's rate for that protocol when `CBM_A_THROUGHPUT=<A run>/throughput.tsv` is set. Keep `wireguard` first in `plat_protocols` so the reference exists.
- **Recorder mode (FWA, opt-in per adapter):** a kill-switch scenario whose suite also defines `<fn>_ps` runs as one job on the machine when the adapter has `plat_record_start <name> <steps-file> <max-seconds>` and `plat_record_collect <scen_dir>`. The collected `status.tsv` (the recorder's order `epoch_ms  ms  line  egress  [app]` is converted by the driver; app rows go to `status-app.tsv`), `phys.pcap`/`*.pcapng` and `cli.txt` are judged offline by the same checks; money and leftovers run live after the block is gone.
- **`plat_plant_leak` (optional):** the leak selftest plants its packet through it when the driver runs off the test machine.
- **RPC lane b (RPC-PLAN.md):** the driver sources `~/secrets/helius-lane-b.env` on ctl-1 (never a raw `helius-<x>.env`) and hands the URL to the adapter's optional `plat_set_rpc <rpc> <ws>`, which copies it to the VM at the start of every run and sets the daemon's `[rpc]` url. It never prints the key. The run ends with `== rpc: requests=<n> 429s=<n>` in `rpc.txt` (`plat_rpc_requests` optional).
- **Throughput extras (TS36):** `CBM_MIN_MBPS=<MB/s>` sets an absolute floor (lab: 2.5 = 20 Mbit/s). An optional `plat_tcp_retrans` adds retransmits to the row. A FAIL row says "likely an MTU/MSS black hole", because small packets (connect, egress, DNS) already passed. Selftest plant for adapters: drop tunnel packets > 1400 B (e.g. nft in the client netns) and expect the row to FAIL.
- **Node entries from chain (DIR):** a node lists one entry per protocol, each on its own port, and the port order differs per node. At run start, `lib/nodes.sh` reads the seed node (`--node`, an address) with `node show`, then makes one `node search --owner` call, cached in `<out>/node-entries.json`. It maps each entry to a protocol by the SDK's protocol bits (wg 1, v2ray 2, openvpn 4, amneziawg 8, xray 16, hysteria2 32). Each scenario then gets `NODE_ID`, `NODE_IP` and `NODE_PORT` for its protocol, and a protocol the node doesn't list is a SKIP. The selftest fails on any literal node port (187xx) in the code. Adapters may define `plat_chain_cli`; the default is `$CBM_CLI` with the lane-b RPC.

## S5 hooks (TLX 11-08)
`suites/S5.sh` (interrupts) calls these optional adapter hooks; a missing hook makes its cell SKIP (77), never PASS:
`plat_cancel_connect <proto> <after_s> [new]` (the app's Cancel / ^C on `client start`; `new` = cut inside a new
channel's deposit), `plat_power_cut_mid_connect <proto> <after_s>`, `plat_reboot` (needs a driver OFF the test
machine; returns when the daemon is back), `plat_sleep <s>`, `plat_clock_jump <±s>` + `plat_clock_restore`.
Linux (plat/linux.sh) has all but `plat_reboot`; its power cut and sleep are VM simulations (SIGKILL / SIGSTOP + all
traffic dropped) and say so in the scenario log. Reboots on Linux: #32 `scripts/e2e/linux/oneoff/tlx-s5-reboot.sh`
from ctl-1. Every cell ends by proving the NEXT connect carries traffic.

## S10 hooks (FLX2 11-08)
`suites/S10.sh` (install lifecycle) calls these optional adapter hooks; a missing hook makes its cell SKIP (77),
never PASS. The runner stages the previous-release and under-test packages and sets `CBM_PKG_OLD` / `CBM_PKG_NEW`;
a scenario that needs both SKIPs when either is empty. The cells are protocol-independent (`:off:once`), since
install is not per-protocol.
`plat_pkg_old` / `plat_pkg_new` (echo the staged package file or empty), `plat_pkg_install <file> [setup]` (`setup`,
the initial install only, runs device setup; a no-flag install never creates a new device/wallet),
`plat_pkg_upgrade <file>` (the package manager's upgrade), `plat_pkg_uninstall` (keep user config),
`plat_pkg_installed` (rc), `plat_pkg_version`, `plat_pkg_files` (one `<mode> <owner> <path>` per installed file),
`plat_service_active` / `plat_service_enabled` (rc), `plat_run_as_nonadmin <args…>` (run the CLI unprivileged, echo
output, rc = the CLI's), `plat_device_id` (echo a stable fingerprint of the installed instance's device/wallet
identity — unchanged across an upgrade/reinstall that keeps the device), `plat_config_present` (rc 0 iff the
installed instance's user config/wallet is still on disk), `plat_connect_short <proto>` (connect the **installed**
instance briefly, ~10 s, egress = node, then disconnect; rc 0 = it carried traffic), and the optional
`plat_service_install_timeout` (install with a slow/blocked service start; rc 0 iff the installer returns and
reports it, not hangs).
Rule (DIR + FMC): on-chain device setup happens **once**, at the old install. An upgrade and a reinstall must keep
the device, wallet and settings with **no new on-chain setup** (a fresh setup = FAIL): `plat_device_id` must be
identical before and after, and a short wg connect must carry traffic. Uninstall keeps the user config
(`plat_config_present` stays true) and leaves no root-owned system leftovers.
Linux (plat/linux.sh) implements all of them, including `plat_service_install_timeout` (a systemd drop-in with
`ExecStartPre=sleep` beyond `TimeoutStartSec`): it uses dpkg/apt or rpm/dnf per the staged package's extension,
package name `devnet-dvpn` and service `sentinel-dvpnd@c0` (override with `CBM_PKG_NAME` / `CBM_SVC`). On u22 the
runner sets `CBM_PKG_OLD=~/devnet-dvpn_0.1.11_amd64.deb` and `CBM_PKG_NEW=~/devnet-dvpn_0.1.12_amd64.deb`. Windows
hooks: FWA. macOS hooks: FMC.
