# 07 — Infrastructure

Everything ran in the cloud. The owner's laptop only edited files, ran git, gh and ssh, sent messages between
agents, and held the funder key. This chapter lists the machine types, how they were used and the rules around them.
No real addresses, projects or keys are in this repo; every tool reads them from env vars.

## 1. Machines

| Machine | Cloud | Always up? | Use |
|---|---|---|---|
| **Controller** | GCP | yes | Shared hub: staged fork binaries per product with `SHA256SUMS`, the RPC gate, the failover cron, the cloud CLIs, the Test Lab runner, evidence storage. |
| **Reference node A (pure)** | GCP | yes | Runs unmodified upstream at the base commit: the "A" side of every node-side A/B. |
| **Reference node B (fork)** | GCP | yes | Runs the current fork cut: the "B" side. 7 protocol daemons (WireGuard, AmneziaWG, OpenVPN, Hysteria2, V2Ray, Xray, plus one spare). |
| **Build box** | Azure | while building | Shared Go/Electron builds and the fork gate (build, vet, cross-builds, `-race -count=3`). |
| **Node lab** | GCP | per run | Suite S11: node kill/restart, 6 clients on one node, clock skew, voucher latency. |
| **Windows x64 + arm64** | Azure | per run | Installer, kill switch (WFP), suites S0–S12. |
| **macOS guest** | GCP host running a macOS VM | per run | dmg install, pf anchor, suites. Apple Silicon was built but not live-proven (owner call). |
| **Android rig** | GCP | per run | Emulator + adb; S1/S2/S9 and soak. |
| **Real phones** | Firebase Test Lab | per run | Pixel 8a (Android 15) and Galaxy S24 (Android 16). |
| **Linux rigs** | Azure | per run | Ubuntu 22.04 / 24.04 (x64 + arm64), Debian 12, Fedora 44, Rocky 9: the distro pass. |

## 2. Rules

- **Cloud only.** Builds, tests, Docker, emulators, node/npm/go runs and log greps never run on the laptop.
- **Stop when idle.** A VM is stopped (deallocated on Azure) the moment its run ends. The watchdog
  (`tools/infra/fleet-watch.sh`) flags a VM idle on two checks, or one nobody claims, and the holder stops it.
- **Ledger.** Every create, start, stop, resize, firewall or access change is one dated line in the infra ledger:
  who, what, why, and the undo.
- **Claim board.** Every running VM has a holder on the claim board. An unclaimed VM is stopped.
- **The controller and both reference nodes are never stopped** during a campaign: every product's A/B depends on them.
- **Copies go cloud to cloud.** Large files never pass through the laptop.
- **Temporary access is removed at close-out:** keys added to other boxes, extra IAM roles, buckets.

## 3. RPC: one gate, several keys, lanes

Tests make many Solana RPC calls. One paid provider key per lane, a gate in front, and automatic failover:

- **Keys:** several provider keys, each in its own mode-600 file on the controller.
- **Lanes:** clients read a lane file, never a key file (`tools/infra/rpc-failover.sh`). Every 5 min the failover probes
  each key (healthy = 2 of 3 `getSlot` calls answer in under 5 s) and repoints any lane whose key failed. When every
  key fails, the lanes fall back to public devnet.
- **Gate:** a small proxy on the controller gives each client its own token, with a daily cap and a websocket cap per
  token. It counts usage per key, and when every key refuses it falls through to public devnet.
- **Size the caps to the plan.** Low caps voided real tests twice ("too many websockets" after daemon restarts). The
  fix was to size per-key and per-token caps to the provider plan, not to guess.
- **Nodes read their RPC only at start.** A lane switch means the node owner re-points the nodes.
- **Status polls never touch the RPC;** they talk to the local daemon. Only chain work (opens, settles, redeems,
  withdrawals) needs the gate.

## 4. Accounts and secrets

- **Cloud CLIs** run under a service account on the controller. Personal accounts are used only for a one-off grant,
  then signed out. Sign-in scripts open a private browser window and check the account before changing anything.
- **Extra roles** granted for one job (e.g. Test Lab on a second project) are listed for removal at close-out.
- **Azure** uses a service principal; its secret is reset at close-out.
- **Wallet keys** live on the box that uses them, never in a repo or a message. The funder key never leaves the
  owner's laptop.
- **Before anything goes public:** `tools/secret-scan.sh` (planted IPs and keys must fail it), plus a full-history scan.

## 5. Close-out checklist

1. Final reclaim done and the books reconciled (`docs/06-money.md`).
2. Every VM stopped except the controller and the reference nodes, each stop ledgered.
3. Temporary access removed: added ssh keys, extra IAM roles, extra buckets.
4. Azure service principal secret reset.
5. Ledger closed with the final state of every machine.
