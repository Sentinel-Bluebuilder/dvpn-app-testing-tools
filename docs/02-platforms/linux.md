# 02 · Platforms · Linux

The Linux product (#32), how it is built and pinned to a daemon cut, the rigs it was tested on (Ubuntu 22.04/24.04 on
x64 and arm64, Debian 12, Rocky 9, Fedora 44), the Linux harness adapter, the gotchas that each cost a run, and the
results. Writers: FLX (build, adapter, harness bugs), TLX (Ubuntu), TLX2 (Debian / Rocky / Fedora). No real
addresses, projects or keys appear here; VM names stand in for machines and every tool reads its endpoints from env vars.

Result cells marked **pending final5** are waiting for the rerun on the final daemon cut (final5) and are filled in once
the grader (ABW) signs them.

## 1. The product

- **App and CLI:** Electron + React + TypeScript, plus the `devnet-dvpn` CLI with the same commands. App and CLI share
  one state module, so the CLI `status` title is what the app's Home screen shows.
- **Daemon:** the fork's `sentinel-dvpnd`, client instance `c0`, driven over gRPC on a unix socket. Home
  `/var/lib/sentinel-dvpn/c0` (root, 0750, group `sentinel-dvpn`); units `sentinel-dvpnd@c0.{service,socket}` with the
  app's drop-ins; binaries copied to `/usr/local/lib/devnet-dvpn`.
- **Kill switch:** nftables table `inet sentinel-dvpn-c0`. The tunnel link is `dvpn-c0`.
- **Packages:** `.deb` (primary), AppImage, `.rpm` (Fedora / EL9) and Arch `.pkg.tar.zst`, each for amd64 and arm64,
  all built from one commit with a `SHA256SUMS` next to them.

## 2. Build pipeline (cloud only)

No build or test ran on the owner's laptop. The laptop edited files and ran git; everything else ran on cloud VMs.

1. **Daemon cut:** the fork is tagged (`final2`, `final3`, … `final5`). The daemon and CLI are built for linux amd64 +
   arm64 on the build VM, with the build identity (network, program id, mint) linked in at build time, and staged on
   the controller with `SHA256SUMS` and a `MANIFEST`.
2. **Repin:** `node scripts/repin-dvpnd.mjs <stage dir> [--bins <dir>]` checks the stage's sums and devnet identity,
   writes the new daemon hashes into #32's `build/deps.lock.json` and copies the third-party notices. The app refuses a
   daemon whose hash is not in the lock. One commit per repin.
3. **Version bump:** one commit.
4. **Package build** on the controller, under the shared build lock: typecheck, the full unit suite, then all 8
   packages and `SHA256SUMS`. A failed unit test stops the build (`FINAL-FAIL unit`) before any package is written.
5. **Live check** by the tester on a clean VM, installing from the hashes in `SHA256SUMS`.

**Releases on the final cut:**

| Version | Daemon | What changed | Status |
|---|---|---|---|
| 0.1.15 | final3 | kill-switch-aware Reconnecting copy | TLX passed the wording live |
| 0.1.16 | final3 | a removed service home is named before any install step (Q0431) | closed by TLX |
| 0.1.17 | **final5** | repin to the last client cut; "this wallet is the device key" refused before signing | targeted rerun (S1 smoke, S3 short-cut / end reason, S2 core, Q0428): **pending final5** |
| 0.1.18 | final5 (app-only) | daemon errors in plain words in the CLI and the connect screen (Q0433, Q0453) | unit 1015/1015; TLX2's Debian 12 repro clean (no raw gRPC: service stopped, second connect, revoked approval caught by the allowance pre-check), Q0433/Q0453 closed; S2 words cells via the app + smoke: **pending final5** |

Lessons from the pipeline:

- **Copy that describes daemon behaviour is written against the daemon cut it ships with, and checked live.** The
  first kill-switch-off copy was written against final2, where the daemon still blocked. The live run showed the
  mismatch; the commit was reverted and redone once the daemon owner ruled that final3 goes direct.
- **One build per cut.** A 0.1.17 build on final3 was stopped half-way when final5 was staged, so only one 0.1.17 exists.
- **Generated docs are part of the build.** A copy change made `docs/UI-CONTROLS.md` stale and failed the unit suite
  (1014/1015); regenerate with `node scripts/ui-controls-doc.mjs` before cutting.

## 3. Product fixes made on Linux this phase

| Fix | Why | Ported to |
|---|---|---|
| A closing session shows "Disconnecting", not "Connected" | the daemon lists a stopping session as still open | Windows, macOS |
| Reconnecting copy follows the kill switch | final3 routes go direct while reconnecting when the kill switch is off; one fixed title lied about a block | Windows, macOS, Android |
| RPC "silent since" status | port of the Android fix: how long the RPC has been unreachable | — |
| A removed service home is named, nothing is changed (Q0431) | an empty folder systemd recreated was taken as an installed home, so every install got the root step's raw error | — |
| "This wallet is this computer's device key" | a wallet loaded from the service's own key file is the device; the program refuses a grant to its granter (6003), which read as a range error | — |
| Daemon errors in plain words (Q0433, Q0453) | service down / not ready, a second start, a revoked spending approval (`OwnerMismatch`) and a short tDVPN balance came through as raw gRPC text | — |

## 4. Rigs

| VM | Arch / OS | SELinux | Role |
|---|---|---|---|
| tlx-u22 | x64, Ubuntu 22.04 | — | main runner: suites S1–S10, G21, soak |
| tlx-u22b | x64, clone of u22 | — | A/B twin: package installs, wording rows |
| tlx-u24a | arm64, Ubuntu 24.04 | — | arm64 runner |
| tlx-u24b | arm64, clone of u24a | — | A/B twin, lent to other agents |
| tlx2-deb12 | x64, Debian 12 | none | distro runner; also hosted a test node for one node-side A/B |
| tlx2-rocky9 | x64, Rocky 9.8 | Enforcing | distro runner |
| tlx2-fedora44 | x64, Fedora 44 | Enforcing | distro runner (systemd-resolved) |

- **Twins share the device key of their source.** Never connect a twin and its source at the same time: the node sees
  one device twice. The twins' cloned wallet files were renamed so they can't be used by mistake; each twin pays from
  its own `c0` key.
- **Control host:** the controller drives every run over ssh. Every VM start and stop goes in the shared ledger, and the
  distro VMs are deallocated when idle.
- **RPC:** each VM reaches the shared RPC gate through a reverse ssh tunnel from the controller (cap: 5 requests per
  second per token). Run the tunnel as a self-restarting loop (`while :; do ssh -N -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -R …; sleep 5; done`): a one-shot tunnel died mid-suite and voided
  10 S5 cells.
- **Watchdog:** `ddv-deadman.timer` stops the daemon after 3 failed network checks. A deliberate block holds it off by
  touching `/run/ddv-deadman.hold` (fresh for under 240 s; refresh it every 30 s from a holder loop).

## 5. How to run

### From zero: S1 smoke on one fresh Ubuntu 24.04 box

Written by a cold read: someone who had only this repo followed it on a new 2 vCPU / 8 GB Ubuntu 24.04 cloud VM and
fixed every step that was missing. It takes about 25 minutes of work and about 8 minutes of test run. Run all of it
as a normal user with `sudo`. Everything is devnet; the wallet you create here is a throwaway.

**0. What you need before you start**
- A Solana **devnet** funder wallet you control (a key file, kept off the box) and the Solana CLI + `spl-token` on the
  machine that holds it (`tools/money/README.md`). You send the test wallet 0.2 SOL, 5 tDVPN and 0.05 SOL for the
  operator key.
- The tDVPN **mint** address of the network you test (`CBM_MINT`). It is printed by the daemon you will install:
  `sentinel-dvpnd version` shows `mint` and `program_id`.
- A live **node** that lists the protocols you want. List nodes with `sentinel-dvpn node search`: the `address` of an
  entry is the node id, and `uri` carries its IP. Set `NODE4_ID` / `NODE4_IP` to them (the names are historic; any
  node works with `--node node-4`).
- The binaries. The public product repos do **not** carry binary releases yet, and the fork cut the results were
  measured on is not public either. Use the Linux app package you built or were given
  (`devnet-dvpn_<version>_amd64.deb`; it ships `sentinel-dvpnd` and the protocol tools) and build the `sentinel-dvpn`
  command-line client from upstream `sentinel-official/sentinel-solana` (`sentinel-dvpn/`, `make build`, Go 1.27.3).
  A run on a pure upstream build can show reds that `docs/known-issues-rc1.md` lists for it.

**1. Packages**
```sh
sudo apt-get update                                   # a fresh image has no package lists; the .deb's dependencies fail without this
sudo apt-get install -y ./devnet-dvpn_*_amd64.deb tcpdump dnsutils curl jq
sudo devnet-dvpn daemon repair-drivers --yes          # AmneziaWG tools + kernel module (builds a DKMS module, ~3 min)
devnet-dvpn daemon drivers                            # every line must say present/ok
```

**2. Binaries in the harness folder** (`CBM_DIR`, default `~/cb33`, owned by you: the harness writes its daemon log there)
```sh
mkdir -p ~/cb33 && cp /opt/devnet-dvpn/resources/resources/bin/sentinel-dvpnd ~/cb33/ && cp <your built>/sentinel-dvpn ~/cb33/
chmod +x ~/cb33/sentinel-dvpn ~/cb33/sentinel-dvpnd
~/cb33/sentinel-dvpnd version                         # note mint + program_id
```
The protocol tools (`hysteria2`, `v2ray`, `xray`) must sit in a **root-owned tree nobody else can write**. The daemon
refuses them from the package's `/opt` folder ("binary is replaceable by an untrusted account") and 9 of the 12 S1
cells go red on that alone:
```sh
sudo mkdir -p /usr/local/lib/devnet-dvpn/bin
for n in hysteria2 v2ray xray; do sudo cp -a /opt/devnet-dvpn/resources/resources/bin/$n /usr/local/lib/devnet-dvpn/bin/; done
sudo chown -R root:root /usr/local/lib/devnet-dvpn && sudo chmod -R go-w /usr/local/lib/devnet-dvpn
B=/usr/local/lib/devnet-dvpn/bin
sudo mkdir -p /etc/sentinel-dvpn
echo "PATH=$B/hysteria2:$B/v2ray:$B/xray:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" | sudo tee /etc/sentinel-dvpn/c1.env
```
(The adapter reads the daemon's `PATH` from `/etc/sentinel-dvpn/<instance>.env`.)

**3. A client instance and its wallet** (the matrix defaults to instance `c1` and CLI home `~/.sentinel-dvpn`; the app's
own instance `c0` is a different thing). A headless box cannot use the app's wallet commands (they need a desktop
keyring), so create the owner key with the command-line client:
```sh
cd ~/cb33
./sentinel-dvpn key new owner --unencrypted           # prints {"name":"owner","public_key":"<OWNER>",...}
sudo ./sentinel-dvpnd init --instance c1 --owner <OWNER> --plain-key   # prints the operator public key <OPERATOR>
```
`<OWNER>` is the base58 `public_key` value, not the whole JSON line. Back both key files up somewhere safe now
(`~/.sentinel-dvpn/keys/owner.json`, `/var/lib/sentinel-dvpn/c1/keys/operator.json`): you need the owner key to take the
money back at the end.

**4. Fund it and approve spending** (7 s between transactions)
```sh
# on the machine with the funder key; wallet list line format: <pubkey> <min_sol> <target_sol> <min_tdvpn> <target_tdvpn> <label>
#   <OWNER> 0.1 0.2 1 5 owner        <OPERATOR> 0.03 0.05 0 0 operator
APPLY=1 tools/money/sol-topup.sh
# on the box, as the owner:
./sentinel-dvpn wallet create-token-account --key.name owner
sleep 7; ./sentinel-dvpn wallet approve-delegate --amount-base-units unlimited --key.name owner
sleep 7; ./sentinel-dvpn grant open-grant --key.name owner --grantee <OPERATOR> --target 11111111111111111111111111111111 \
  --permissions 788529152 --expires-at 0 --allowance 18446744073709551615
sudo ./sentinel-dvpnd doctor --instance c1            # fix anything with severity "error"; warnings about a protocol tool mean step 2 is incomplete
```
`doctor` prints the exact command for every missing grant or approval; when in doubt, run it and do what it says.

**5. Run** (detached: while a kill-switch cell is active the box can stall your ssh session for up to a minute, and
a session that dies would kill a foreground run. The harness exempts the machine you ssh in from, so the session
comes back between cells)
```sh
git clone https://github.com/Sentinel-Bluebuilder/sentinel-solana-dvpn-testing-tools && cd sentinel-solana-dvpn-testing-tools/tools/cb33-matrix
export INSTANCE=c1 CBM_DIR=$HOME/cb33 CBM_MINT=<mint> NODE4_ID=<node address> NODE4_IP=<node ip>
bash cb33-matrix.sh --platform linux --selftest --out ~/cbm-self        # no node needed; exit code 0 and no MISSED line in ~/cbm-self/selftest.txt
setsid nohup bash cb33-matrix.sh --platform linux --side B --node node-4 --suites S1 --out ~/cbm-s1 > ~/s1.log 2>&1 < /dev/null &
tail -f ~/s1.log                                                         # one "-- S1 core <protocol>" line per cell
```
Without a lane file the daemon uses the public devnet RPC, which is slower and rate-limited (the cold read ran this
way). If you have your own endpoint, put `HELIUS_RPC_URL=...` (and optionally `HELIUS_WSS_URL=...`) in an env file and
point `CBM_RPC_LANE_FILE` at it; the matrix writes it into the instance's `[rpc]` at the start of the run.

**6. Read the result.** S1 is 12 cells: `core` (kill switch off) and `core_ks` (on) for wireguard, amneziawg, openvpn,
hysteria2, v2ray, xray; about 8 minutes on 2 vCPU. The verdict line is `== suite S1: ... cells: 12 total, N FAIL, M
PASS`. Details: `~/cbm-s1/results.tsv` (one row per check; filter the `FAIL` rows) and `~/cbm-s1/S1/<scenario>-<protocol>/`
(`scenario.log`, `daemon.log`, `cli.txt`). Seen on the RC2 Linux package against a final6.1 node, after the setup was
right, over three runs of the same node: hysteria2, v2ray, xray and amneziawg passed both cells every time; wireguard
`core` failed once and passed on the re-run; openvpn `core` passed once and failed once; openvpn `core_ks` failed once
and passed once. So **one run can show 1-2 red cells that do not repeat**; re-run a red cell alone with
`--protocol <p>` before calling it a finding. The reds that came and went:
- `rpc-direct` (1 RPC packet on the NIC while active, "pooled pre-tunnel connection"): upstream #6 (`docs/05-upstream.md`).
  It lands on one wireguard or openvpn cell in a run and not on the next.
- one `status` LIE sample on openvpn `core_ks` (state `active` with the direct IP): the same finding the Fedora S1 row
  in `docs/04-results.md` mentions; it did not repeat on the re-run.
Anything else red (`words`, `leak`, a `connect failed` line) is a setup problem first: read `scenario.log`. A first run
with only 4 of 12 passing and `binary is replaceable by an untrusted account` in the logs is step 2's protocol-tool
folder.

**7. Take the money back.** Channels the run opened refund after a wait: start-close, then close 7200 s later, then
withdraw (`tools/money/README.md`, "The reclaim pipeline"). Then `tools/money/money.sh sweep` (dry run first, then
`--apply`) returns SOL and tDVPN to the funder, keeping 0.05 SOL + 1 tDVPN. Only then delete the VM; the keys from step 3
are the only way to the money.

### Ubuntu (matrix wrapper)
- `tlx-distro-matrix.sh [suites] [node]` wraps `cb33-matrix` with `PLATFORM=linux`.
  - `CBM_ARGS='--scenario X'` runs one cell; `CBM_PROTOCOLS='amneziawg hysteria2'` narrows the protocols.
  - `CBM_RPC_URL` comes from the VM's gate env; the delegate preflight needs it.
  - `CBM_CHAIN_HOME` / `CBM_CHAIN_KEY` name the wallet that signs the run-end closes.
  - `CBM_SLEEP_KEEP_IP` names the control host, so the simulated sleep does not cut the RPC tunnel.
- **Deploy the matrix:** tar it from the canonical copy with a `.rev` file and back up the VM's old copy first. Never
  edit a VM's copy in place.
- **Daemon under test:** the matrix runs its own `./sentinel-dvpnd run --instance c0` from its bin folder. Swap builds by
  copying the daemon and CLI there and checking `sha256sum`. The installed unit is stopped for the run and restarted
  afterwards.
- **Soak:** `SOAK_PLATFORM=linux SOAK_NODE=<node> bash tools/soak.sh <label> 30 wireguard`. Stop the package unit
  first; the soak starts its own daemon.
- **One-off drivers** (`scripts/e2e/linux/oneoff/` in #32): node outage + app wording with the kill switch off/on, the
  same row across several daemon builds, OpenVPN. Run them detached (`sudo setsid nohup … &`): the ssh session is cut
  whenever the tunnel holds the route.

### Debian / Rocky / Fedora (S1 + S2)
1. Install the product package after checking `SHA256SUMS`: `.deb` on Debian, `.rpm` on Rocky / Fedora.
2. Put the matching `sentinel-dvpn` + `sentinel-dvpnd` in a folder the test user owns under `/usr/local/lib/`, labelled
   `bin_t` on SELinux hosts. The matrix writes its daemon log into `CBM_DIR`, so the folder must be writable by the user
   that runs the matrix.
3. Point the matrix's RPC lane at the VM's gate token with `CBM_RPC_LANE_FILE`, through the reverse tunnel. The matrix
   copies the lane file into c0's `[rpc]` at every run start, so a raw key left in another env file on the VM comes back
   after each run: keep only the gate token there.
4. Fund the **root owner** named in c0's config (not the c0 operator key) and approve the program delegate on the
   owner's token account (`wallet approve-delegate --amount-base-units unlimited`). The daemon draws every channel
   escrow from the owner through that delegate.
5. Stop the packaged c0 (`sentinel-dvpnd@c0.socket` and `.service`; it holds the instance lock), then
   `INSTANCE=c0 CBM_DIR=… bash cb33-matrix.sh --platform linux --node <node> --suites S1|S2 --out …`. Restore c0 after.

## 6. The Linux harness adapter (`tools/cb33-matrix/plat/linux.sh`)

The matrix driver is the same on every OS; each OS supplies `plat_*` hooks. On Linux they call the fork's
`sentinel-dvpn` CLI as root against instance `c0` (`CBM_DIR` holds the binaries). The `c0` service holds the home's
lock, so a run stops it and an exit trap starts it again: the box is left as found.

- `plat_connect` / `plat_disconnect` / `plat_live_sessions`: only sessions not yet ended count as live. Each new channel
  is recorded with its protocol for the run-end money check.
- `plat_switch` (S4): the fork's CLI has no in-place switch and no keep-kill-switch option, so the default arm is a
  plain stop then start, which releases the kill switch by design. `CBM_SWITCH_VIA=app` switches with #32's own CLI
  (`devnet-dvpn connect <node> --switch --yes`). **Only that arm measures the product's switch.**
- `plat_egress` / `plat_egress6`: read through the live session's SOCKS proxy when it has one.
- `plat_status_line`: the honest-status poller, one status call per sample (`call_ms`, `proxy=` per sample).
- `plat_close_run_channels` / `plat_money_run_channels`: close only the channels this run opened (7 s apart, landed
  when `close_started_at > 0`, else `CLOSE-NOT-LANDED` → "cannot judge"), then one line per channel
  (`channel= proto= spent= redeemed= sessions= step=`) graded by `checks/money.sh`.
- **Words: which layer is graded.** By default the words check reads the upstream `sentinel-dvpn` CLI the adapter
  drives. `CBM_WORDS_VIA=app` also runs #32's `devnet-dvpn status` at each `client status` / `client start` and grades
  that instead. A raw-gRPC line in the default arm is an upstream CLI finding, not a #32 one.

**General rule (grader):** any egress or leak probe for a proxy-type protocol must go through that session's proxy
endpoint, or it measures the box, not the product.

## 7. Gotchas (each one cost a run)

### Harness (all fixed)
| Symptom | Cause | Fix |
|---|---|---|
| Every S4 cell "blind" | wrong instance home, a stale matrix tarball, an RPC lane the box could not use | run on the funded instance; repack with a `.rev`; read the RPC URL from the daemon's own config |
| switch_ks_on "leak": 112 packets outside the tunnel, a 9 s kill-switch gap | the harness switched with a plain CLI stop (releases the kill switch by design) | `CBM_SWITCH_VIA=app`. Not a product leak; kill switch during a switch stays NOT PROVEN until the app arm runs |
| v2ray/xray "egress = box IP" after every switch | v2ray/xray sessions are a local SOCKS proxy, not a tunnel; a plain curl goes direct by design | egress probes go through the session's proxy endpoint |
| "status call did not answer in 5 s" on every cell | the poller made one status call per session in the instance's whole history (200 after a day of runs); an isolated call takes 27–30 ms | one status call per sample |
| `rpc-direct` red on every final3 cell (6–36 RPC packets on the NIC) | the upstream #6 fix in final3 closes pre-tunnel connections at tunnel up, and that close (FIN/ACK, no payload) leaves on the NIC; the rest was RPC during an xray session, which has no tunnel | count only SYN or payload packets, only in full-tunnel windows; final2 controls still fail |
| 9 S2 words FAILs on final5 (wg/awg/hy2 × daemon_term / term_persist / daemon_kill) | the raw `rpc error: code = …` tail is the upstream CLI's text, which the adapter drives | graded upstream (fix PR upstream); #32's layer proven with `CBM_WORDS_VIA=app` |
| Run-end closes "did not land" | the close signed with a key file that does not exist on the box; the old step hid the error | `CBM_CHAIN_HOME` / `CBM_CHAIN_KEY`; the close retries and prints `CLOSE-NOT-LANDED` |
| Money FAIL after a failed close | the node's settlement is not comparable | money says "cannot judge", not a product FAIL |
| "another cb33-matrix driver is running" | the simulated sleep SIGSTOPped the daemon; a CONT to the child alone left the `sudo` parent frozen | CONT the parents too |
| Sleep/resume: every redial fails `getAccountInfo` | the sleep dropped the RPC tunnel too, and sshd held the dead forward for minutes | `CBM_SLEEP_KEEP_IP` |
| A cell's daemon log missing | the adapter truncates it at the next daemon start | each cell keeps its own `daemon.log` |
| A run killed mid-way left subshells | background pollers outlive the driver | the driver handles TERM through its exit cleanup; stop leftovers by exact PID, then check for no kill-switch tables or policy rules |
| Launchers end early during sleep cells | an ssh timeout was read as "driver exited" | tolerate up to 20 missed polls |

### Rig and distro
| Symptom | Cause | Fix |
|---|---|---|
| Blocking the node with a blackhole route changes nothing | dvpnd routes the node through its own rule 8989 → table 8990 | block with an nft table (`ip daddr <node> drop` on output, `ip saddr` on input) |
| `Finish device setup first` when running as root | root reads `/root`'s data folder | `DVPN_DATA_DIR="<user home>/.config/Devnet dVPN"` |
| OpenVPN script aborts | the Linux device is `dvpn-c0`, and the script filtered it out | match `dvpn-c0` |
| every cell "daemon did not start" | `CBM_DIR` root-owned; the matrix cannot write its daemon log | chown the bin folder to the test user |
| `token-2022 InsufficientFunds` with a funded wallet | delegate allowance 0 or used up on the owner's token account | approve the delegate `unlimited`; the matrix now approves it and blinds a cell when allowance < escrow; final3 names the cause |
| S2 opens run dry after ~10 channels | the payer is c0's root owner, holding 1 tDVPN (= 10 × 100000 escrow) | fund the owner (5 tDVPN for S1 + S2) |
| Fedora: "binary not found: v2ray / xray / hysteria2 / wg-quick" | c0 predated the package, so the app's first-run setup never laid out `/usr/local/lib/devnet-dvpn` or `/etc/sentinel-dvpn/c0.env` | set c0 up through the app (or recreate that layout) |
| Fedora: "unknown group sentinel-dvpn" | same: no package setup | the group comes with the package's setup step |
| Rocky / Fedora: exec of the test binaries denied | SELinux blocks exec from home folders (`user_home_t`) | install under `/usr/local/lib/…` and `chcon -t bin_t` |
| `NodeNotLive (6016)` on one node's v2ray/xray | the node's hourly listing renewal hit RPC 429s and does not retry | node-side fix (upstream PR); rerun once the entry is live, or use another node |
| SSH to the VM times out mid-run | a kill-switch cell blocks inbound while active | wait for the cell, or check out of band through the cloud's run-command |
| `pgrep -f` / `pkill -f` kills your own shell | it matches the remote command line | stop processes by exact PID |
| An old capture still running hours later | a tcpdump from an earlier suite (1.86 GB) | kill exact PIDs at cleanup; check `pgrep tcpdump` |
| `client service isn't running` in a sleep cell | the CLI is answered while the daemon is frozen; a real suspend freezes the CLI too | a simulation artifact, not product |

## 8. Results (signed by ABW unless marked)

### Ubuntu
- **G21, app wording during a node outage (0.1.14, 0.1.15):** "Reconnecting…" no more than 6 s after the daemon loses
  the node, "Protected" 2–3 s after recovery. On 0.1.15, kill switch off: "Reconnecting… traffic is going direct (kill
  switch is off)"; on: "Reconnecting — internet blocked to protect you". **G21 CLOSED.**
- **Kill-switch-off reconnect across daemon builds:** final2 arms a reconnect hold (policy drop); pure upstream arms
  nothing and traffic stalls in the dead tunnel while the app reads connected; final3 arms nothing and egress goes
  direct (PASS, matches the copy).
- **OpenVPN (#51):** PASS 4/4.
- **S4 switching (0.1.14):** switching PASS; slow but honest status is a perf note; the money FAIL was the harness
  (closes not landed). Upstream #6 proven on final3 (pooled pre-tunnel connections closed at tunnel up, no RPC data on
  the NIC in 7 cells; final2 controls fail).
- **S5 interrupts:** sleep/resume on awg/hy2 is not product (the RPC tunnel was the cause). Clock jump ±150 s passes on
  wg/hy2; awg rerun **pending final5**. Disconnect during deposit vs a final4 node: PASS × 3 protocols, 0 opaque errors.
- **S9 50 cycles (0.1.15 vs one node):** 45/50, 0 product defects. vs a final4 node: **pending final5**.
- **S2 on final5 (0.1.17):** 0 #32 product fails (9 words → upstream CLI, 4 status → teardown, not a leak, 1 no-samples →
  harness). Words via the app on 0.1.18: **pending final5**.
- **0.1.17 targeted rerun** (S1 smoke all protocols, S3 short-cut / end reason, S2 core, OpenVPN SIGKILL host route):
  **pending final5**.
- **Soak 30 min:** **pending final5**.

### Debian 12 / Rocky 9 / Fedora 44 (final3, node-4)
| Distro | S1 | S2 |
|---|---|---|
| Debian 12 | 68 PASS / 29 FAIL (status poller, since fixed) | 125 PASS / 56 FAIL (blind rows) |
| Rocky 9 | 82 PASS / 16 FAIL | 152 PASS / 35 FAIL |
| Fedora 44 | 78 PASS / 19 FAIL (after the layout fix) | pending final5 |

These are the runs before the status-poller fix; the clean rerun on the fix is **pending final5**.

## 9. Known limits
- **The status walker can read a replaced session** (a redial leaves the old one in the list). Harness; grade from the
  daemon log.
- **The simulated sleep is SIGSTOP plus an nft drop, not a kernel suspend.** It cannot freeze the CLI, so the "service
  isn't running" words rows in sleep cells are artifacts.
- **No `plat_reboot` on Linux.** The S5 reboot cells SKIP (one row), never FAIL.
- **Kill switch during a switch** stays NOT PROVEN until the `CBM_SWITCH_VIA=app` arm runs.
