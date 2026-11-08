# macOS platform

How the macOS build of the consumer dVPN app is tested and packaged: the test rig, the steps of a
pass, the gotchas worth knowing before you start, the findings from the cb33 hardening cycle with
their fixes, and the final results of the signed-off build.

Shas and version numbers are point-in-time for the cb33 cycle (final5, 2026-11-08). Re-derive from
the live build tree before trusting them for a later cut.

---

## The rig

- **One macOS guest.** A macOS virtual machine runs under QEMU (OSX-KVM) on a Linux cloud host. The
  host is Linux; the guest is the macOS target the app runs on.
- **The guest is Intel (x86_64), not Apple Silicon.** This matters, because Homebrew treats Intel as
  a lower-priority tier (its installer refuses a fresh x86_64 install, though an already-installed
  `brew` keeps working), and several findings below come directly from the Intel/Homebrew directory
  layout. Test the x64 build on this guest; the arm64 build is produced in the same pass but is
  validated separately.
- **SSH routes.** There is a host hop and a guest hop; the guest is reached by jumping through the
  host. The host's public address changes every time the VM is restarted, so the local SSH config is
  updated on each boot.
- **The guest cannot SSH its own host.** To run a script on the guest from a workstation, write the
  script to a file, copy it onto the guest through the host, and run it with `bash -s` reading from
  that file. Do not try to inline a quoted script over SSH — the nested quoting breaks.
- **BSD userland, not GNU.** `ls --time-style` is unsupported, `sed -i` needs an explicit empty
  backup argument (`sed -i ''`), and tooling you expect from Linux may be missing or elsewhere.
  Prefer a single `grep -oE` extraction over piping `awk` through SSH, where quoting is fragile.

## Running a test pass

1. **Verify the dmg checksum before installing.** Match the x64 dmg against the builder's published
   sha256. Never install an unverified dmg, or one that simply "appeared" on the guest — more than
   once during this cycle a dmg on the guest turned out to be a stale, partial, or superseded build
   rather than the one meant for test.
2. **Install by drag-install from the dmg.** Attach the dmg, copy the app into `/Applications` with
   `ditto` (which preserves the ad-hoc code signature), then detach the dmg.
3. **Bring up the service through the shipping path, not a hand-assembled script.** The app's own CLI
   command installs the background service: it writes the launch definition, copies the service's
   tool binaries in root-owned, and starts the service under one administrator prompt. Using the
   shipping installer is the point — it is what real users run, so it is what must be tested.
4. **Load the wallet without the Keychain.** In an SSH session the login Keychain is locked, so the
   normal wallet import fails. Point the CLI at a key file on disk instead: it reads the key in place,
   read-only, with no Keychain and no password. A key-file wallet is read-only by design — you set the
   environment variable, you do not import.
5. **Check the balance before any connect.** Connecting spends a little SOL for transaction fees plus
   a refundable token deposit. If the wallet is thin, request a top-up from the funder — that is a
   money operation owned by the funder/coordinator roles, not something a tester does inline.
6. **Keep the host relay up for fault injection.** A small relay on the host reads fault requests the
   guest writes to a file, applies or clears the network fault, and acks back. Keep it running for the
   duration of the run; it clears every fault on exit.
7. **Tear down cleanly.** The service runs as a launch daemon. The shipping build removes it with the
   CLI's own `daemon uninstall`, which also detaches the firewall anchor (see the anchor finding
   below). When testing a build whose CLI lacks that command, the manual teardown is: stop the launch
   daemon, remove its definition, flush **only our own firewall anchor's rules** (never the whole
   firewall), remove the tools directory, and leave the dead-man launch daemon, the on-disk key file,
   and the device-key home untouched.

## Gotchas worth knowing (don't re-learn these)

- `pkill -f` over SSH can kill its own shell — find and kill exact process IDs instead.
- The guest-boot "already running" check greps for the QEMU process; never put that same literal
  string on the SSH command line that runs the check, or it matches itself and the guest never boots.
- The host's public address changes every restart — update the local SSH config each boot.
- Quote-nested scripts sent over SSH break — write a file and pipe it to `bash -s`.
- The guest's test count runs a little below the control host's, because some tests are gated to a
  platform the guest doesn't match. That gap is expected, not a failure.
- When the daemon binary has been hand-swapped for a test, the CLI's "daemon" self-check shows one
  expected version-mismatch failure. Also expected.
- The CLI can report "no wallet" purely because of the locked Keychain, even when the device key and
  spending grant are intact on disk — check with the key-file wallet before concluding the teardown
  wiped anything.
- **The installed daemon binary's sha does not equal the build pin — by design.** The ad-hoc code
  signing rewrites each bundled binary in place after it is fetched and verified. The valid proof of
  what shipped is the dmg/zip sha plus the build's own "verified local dvpnd" line, not the sha of the
  binary inside the installed bundle.

---

## Findings and fixes (cb33 hardening cycle)

Five findings were found and fixed across the cycle. All five are resolved and were validated live on
the Intel guest in the signed-off build. The first two were ship-blockers.

### 1. Tool-integrity check rejected the service's own tools (ship-blocker — fixed)

- **Symptom:** every WireGuard connect failed with a tunnel error reporting that a tool binary was
  "replaceable by an untrusted account: `/usr/local/lib` (owner uid 501)".
- **Cause:** the daemon's tool-integrity check walks the full ancestor path of each tool binary and
  refuses to run it if any ancestor directory is writable by a non-root user. The service's own tool
  copies were correctly root-owned, but they lived under `/usr/local/lib`, which on an Intel Mac with
  Homebrew is owned by the user — the standard layout. So the build refused its own root-owned tools
  and connects failed on any Intel Mac with Homebrew, across all protocols.
- **The check is correct, not too strict.** A user who owns `/usr/local/lib` could rename it and plant
  a malicious tool that the root daemon would then execute — a genuine privilege-escalation path. The
  integrator confirmed the check should stay; the fix is to move the tools, not to loosen the check.
- **Fix (installer-side only):** relocate the service's tool install off `/usr/local/lib` to a
  root-owned directory, with upgrade handling that removes the old location.
- **Evidence:** the integrity check lives in the go-sdk trust code; the regression entered with the
  trusted-path commit on 2026-11-07 and was present in the release candidates through the first
  final build. An earlier build that predated the check did connect on this same guest.

### 2. A space in the tools path broke WireGuard/AmneziaWG (ship-blocker — fixed)

- The first relocation target was a root-owned directory whose name contained a space. That fixed the
  integrity block, but `wg-quick` and `awg-quick` (Homebrew shell scripts) re-parse the tool path
  internally and choke on the space, so the tunnel scripts could not find their own binaries.
- **Scoped to the WireGuard-family scripts only.** OpenVPN connected fine on the spaced path, because
  it executes its binary directly instead of re-parsing the path string. Other direct-exec transports
  are expected to be unaffected for the same reason.
- **Fix:** use a space-free root-owned tools directory.

### 3. Firewall anchor left attached after teardown (low severity — fixed)

- A teardown left the kill-switch firewall anchor *attached* in the main rule set with empty rules.
  It was functionally harmless (no rules in it), but the attachment line lingered: flushing the
  anchor's rules clears its contents, not the attachment itself.
- **Cause:** the firewall teardown flushed and disabled the firewall but never detached the anchor.
- **Fix:** detach our anchor on uninstall by reading the current rules, dropping our own anchor line,
  and reloading — rather than reloading the OS default firewall file, which would discard other
  programs' live firewall rules (a second VPN, Little Snitch, etc.). Confirmed in the signed-off
  build: the anchor is present while connected, gone after disconnect, and gone after the CLI's own
  uninstall.

### 4. AmneziaWG hit the integrity check on a Homebrew bash (fixed)

- After the tools were relocated, AmneziaWG connects still tripped the tool-integrity check — this
  time on a Homebrew copy of `bash` under `/usr/local/bin`, which the user owns. The AmneziaWG tunnel
  script's own interpreter line was correct; the stale reference was elsewhere in how the AmneziaWG
  path was being invoked.
- **Fix (daemon-side):** resolve the bash used for the AmneziaWG path to the relocated, root-owned
  tools copy. Validated in the signed-off build: AmneziaWG connects, protects the session, and logs
  zero integrity errors for the connect.

### 5. Kill-switch setting rejected an unchanged http RPC url (low severity — fixed)

- Turning the kill switch on through `daemon set` failed with "RPC url must use https" when the
  service was pointed at an http RPC endpoint — even though the connect command accepted the very same
  endpoint. The check reproduced with the service uninstalled, which placed it in the CLI's own
  settings path rather than the daemon.
- **Fix:** `daemon set` no longer re-validates an unchanged stored RPC url; https is still enforced
  when the url is actually being set and on every config writer.

### A note on money grading

Earlier in the cycle the macOS adapter had no run-end money check, so per-channel money grading was
simply skipped on Mac. That gap is now closed: the Mac adapter implements the run-end money check, so
Mac runs grade money the same way the other platforms do.

---

## Final results (signed-off build)

The cb33 macOS port was signed off on 2026-11-08. The shipped build passed every targeted suite with
zero open findings.

### Suite results

| Suite | Result | Notes |
|---|---|---|
| S0 baseline | PASS | Service up on the space-free tools root; no legacy tool locations present. |
| S1 connect — WireGuard | PASS | Connects, egress moves to the exit node, session protected. |
| S1 connect — OpenVPN | PASS | Connects, egress moves, session protected. |
| S1 connect — AmneziaWG | PASS | Connects, egress moves, protected; zero integrity errors (finding 4 fixed). |
| S2 coverage | PASS | Node discovery healthy. |
| S3 end-reason | PASS | Structured, human-readable session-end reasons on normal disconnect and on error/abrupt-stop paths. |
| S6 LAN + split (at rest) | PASS | Settings applied correctly. |
| S9 soak | PASS | 30-minute hold, 15 cycles; memory flat (~1–1.5% working-set drift, no leak), thread count flat, egress pinned to the node throughout, clean settle. |
| S10 install/upgrade | PASS | Upgrade over a legacy install removes both old tool locations and leaves a single clean service. |
| Firewall anchor detach | PASS | Anchor gone after disconnect and after uninstall (finding 3 fixed). |
| Money grading | PASS | 7 of 7 channels graded; redeemed meets the per-channel lower bound. |

### Build lineage (point-in-time)

The installer fixes (findings 1–3) shipped in one app/installer line; the daemon then bumped twice,
for the AmneziaWG fix (finding 4) and for the end-reason change, with the kill-switch settings fix
(finding 5) riding in the CLI. The signed-off build is **final5**.

Published dmg/zip sha256 checksums for the signed-off build:

| Artifact | sha256 |
|---|---|
| x64 dmg | `ae37f6046fa227144bf421819078764f8edc43c2feedc5f99793ca3afffd1bcd` |
| x64 zip | `a9e6873f683315155513b53a5a9a61b4f9cd9a8358da52138abd8fbf15cddfe4` |
| arm64 dmg | `7009e1e50a00cbd69068edd539e8002e9b0c124254270d854e0610500b877efe` |
| arm64 zip | `7e058c00cd19113eabfc306992cb782d61ec1b1d2712276ecf3494ed8c6c9ae3` |

### Where the evidence lives

- Full per-suite results, root-cause notes, and the end-reason catalogue: the Mac results map in the
  fleet notes (`cb33-matrix-MAC-MAP.md`).
- Per-session money data used for grading (node, protocol, channel, spent, usage) was exported from
  the app's `sessions --json` and graded on the control host.

---

## Build & packaging (how the macOS dmgs are produced)

### The build must run on a Mac

The `.dmg`/`.zip` for both architectures are produced by the Mac release script on the macOS guest,
because electron-builder needs macOS (ad-hoc signing, architecture check, and the DMG/zip targets).
A workstation only edits files and runs git/scp; it never builds. Running with no architecture flag
builds both architectures in one pass — the canonical path. Per-architecture runs wipe the output
directory, so never run two in parallel into the same output directory.

### Per-architecture pipeline

1. **Fetch and verify dependencies.** The fetch step reads the dependency lock file and, for each
   dependency, either downloads it or copies a local entry (the cb33 daemon and a patched transport
   build). Every file's sha256 is verified against the lock before use. The daemon is a local entry:
   its staging directory must hold a binary whose sha matches the lock, or the build fails fast.
2. **Package and sign.** electron-builder ad-hoc signs the app and its bundled binaries (no
   notarization, an owner decision) and builds the DMG and the macOS zip.
3. **Post-checks.** An architecture check confirms every bundled executable is the target
   architecture; a secret scan confirms there is no inline API key in the payload.

Output is a per-architecture dmg (~210–224 MB) and zip (~202–216 MB). A zip far below ~180 MB is a
truncated or mid-write artifact — wait for the process to exit and the size to stabilize before
trusting a checksum.

### Bumping the daemon (dependency-lock repin)

To ship a new daemon cut, edit only the two daemon lines per architecture in the lock file (source
tag and sha256), preserving the compact format with surgical string edits — never a full rewrite,
which reflows the whole file. Stage the matching binaries. The embedded daemon sha will not equal the
lock sha, because ad-hoc signing rewrites each binary in place after verification; the valid proof is
the fetch step's "verified local dvpnd" line, taken before signing.

### Gotchas that cost build time

- **Release-server timeouts** on the remote transport downloads can block a build. Work around them
  by seeding the local dependency cache from an earlier build — the fetch step re-verifies each cached
  file's sha against the lock, so a matching cached file is used and the download is skipped. All
  remote dependencies are version-pinned, so caches stay valid.
- **SSH stdout truncates** when the session closes mid-write. Write the build log to a file on the
  guest and read sizes and checksums in a separate short query, rather than relying on a piped tail of
  the long-running build.
- **A space in the install root** breaks the WireGuard-family tunnel scripts (finding 2) — keep the
  tools root space-free.
- The guest project tree is a clean `git archive` extract, not a checkout. To refresh it for a new
  revision, remove the tree directories and extract the new archive, but preserve the local dependency
  cache (re-seed it after extract) so you don't re-hit the release-server timeouts.
