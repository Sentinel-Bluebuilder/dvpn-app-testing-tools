# Test method

How every bug in this repo was found, reproduced, fixed, and independently graded. The
discipline below is what lets the catalogue claim "every bug resolved" without a single false
positive: a fix is not *resolved* until an independent grader reproduces the bug, re-runs the
fix, and proves — with a mutant — that the test actually catches the bug.

> Method owners: ABW + FLX2. Counts and the per-product version/hash table are reconciled in
> `04-results.md`; nothing here is a count.

## 1. The five built-in checks (every live run)

Every live test cell, on every OS, runs five checks against the real daemon + a real paid
devnet session — not mocks:

1. **scenario** — the user action actually completes (connect / switch / disconnect / sleep /
   reboot) and the tunnel carries traffic. The throughput cell downloads a large file through
   the session; its URL is the `CBM_DL_URL` knob (default `https://ash-speed.hetzner.com/100MB.bin`,
   fetched as a 50 MB byte range, HTTP 206). The default host must NOT rate-limit: a third-party
   throttle is **not a measurement**, so an HTTP 429/4xx/5xx grades the throughput **SKIP**, never
   a false PASS and never the slow-link FAIL — but a SKIP would also *hide* a genuinely slow rate,
   so a cell must land a real non-zero MB/s to prove throughput, not a SKIP. A failed first fetch
   is retried once and the failure is logged as a visible `DL-RETRY` row (never a silent retry).
   Re-check the default URL before relying on it (`speed.hetzner.de` was retired):
   `curl -s -o /dev/null -r 0-52428799 -w '%{http_code} %{size_download}\n' <url>` must give
   `206 52428800`.
   - **ABW (Q0473, 2026-11-08).** `speed.cloudflare.com` 429-throttled a node's egress IP
     (`curl exit=0 http=429 bytes=1`, through SOCKS *and* a real tunnel) — the old default would
     have failed real cells on an upstream problem. With `CBM_DL_URL` pointed at the
     non-throttling host, 6/6 proxy cells measured real rates: deb12 core_ks v2ray 1.63 / xray
     16.20 / hy2 18.22 MB/s; fedora44 core v2ray 7.74 / xray 18.64 / hy2 19.62 MB/s. The slow
     v2ray rate is now *visible* (feeding Q0466), which the SKIP grade alone would have hidden.
2. **leak** — no payload egresses outside the tunnel while a session is up. For proxy-type
   protocols (v2ray / xray / hysteria2) the egress probe MUST route through the session's
   SOCKS `proxy_endpoint`; a plain curl reads the box IP and falsely looks like a leak.
   Egress going direct is a leak only when the kill switch is on/persist — at **ks=off,
   direct egress is by design** (the kill switch *is* the reconnect block). The packet capture
   on the physical NIC is the authoritative leak signal; the status poller (check 4) only
   *raises questions* that the capture answers (§8).
3. **rpc-direct** — chain reads/writes go RPC-first (LCD only on fallback).
4. **words** — the user-facing text is honest: a dead/stale session never reads a frozen
   "active/Protected"; reconnecting reads "Reconnecting…"; ks=off reconnect says traffic is
   going direct; ks=on/persist says traffic is blocked. Honesty is judged against a **fresh**
   egress measurement, never a stale one (§8).
5. **money** — the node collects what the client spent. Graded on the node's **stored
   cumulative** and **post-redeem** settled, never the pre-redeem position (a pre-redeem read
   shows only the lead and falsely looks like under-collection).

## 2. Suites S0–S13

Suites group the cells by user journey; each runs the five checks per protocol
(wireguard / amneziawg / openvpn / hysteria2 / v2ray / xray) and per kill-switch mode
(off / on / persist):

| Suite | Journey |
|-------|---------|
| S0 | kill-switch on/persist baseline (block holds) |
| S1 | core connect + core_ks (session establishes and holds) |
| S3 | crash / restart recovery |
| S4 | protocol switch (fast switch, switch-while-connecting, every-pair) |
| S5 | OS events: sleep/resume, clock jump, reboot |
| S7 | settlement races (Windows settle-race) |
| S8 | escrow / credit-exhausted edges |
| S9 | 50-cycle soak (connect/cut/recover) |
| S10 | Windows-specific cells |
| S11 | billing-skim / OpenVPN reconnect-refusal / node-kill mid-session |
| S13 | (see plan) |

> Suite→OS pass/fail is `04-results.md`. This file is the method, not the tally.

## 3. How a fix is proven: A/B one-side change + surgical mutant

- **A/B one-side change.** The only difference between arm A (base) and arm B (fix) is the
  one commit under test. Same node, same wallet, same protocol, same seed. If A reproduces the
  bug and B does not, the fix is *necessary* — but not yet *proven*.
- **Surgical compiling mutant.** The fix is proven only when a mutant that reverses the fix's
  one load-bearing line — and still compiles — makes the fix's test **FAIL 1:1** (that test and
  only that test). This is what proves the test catches the bug rather than passing vacuously.
  - **subs=1 is mandatory.** A mutant that does not substitute (pattern miss) is a *non-run*; a
    green result from a non-run proves nothing and is rejected, never signed.
  - **Clean control + scope control.** The un-mutated tree passes; a second, out-of-scope test
    stays unaffected (proving the mutant is targeted, not a blanket break).
  - **Equivalent mutants.** If no compiling mutant can change observable behavior, the line is
    an equivalent mutant (no test can catch it) — distinct from a coverage gap, and recorded as
    such rather than filed as a failure.
  - **Test-only fixes** (race fixes, coverage adds) are proven by (a) a test-only diff and
    (b) either clean-under-`-race`×5 (race) or a mutant of the *pre-existing* production line the
    new test claims to cover (coverage).

## 4. Reuse buckets

Findings are bucketed so the catalogue stays honest about what each run shows:
**product** (a real defect), **harness** (the test rig, not the product), **VOID** (an
invalidated run — mixed tree, dead tunnel, rate-limited gate, un-patched node), **CANDIDATE**
(a real-looking symptom whose decisive evidence — usually the daemon log — is not yet captured;
held, never graded, until the evidence lands), and **equivalent/coverage** for mutant outcomes.

## 5. §9c: zero false positives

The independent grader re-runs every filed fix on a fresh checkout (pinned SHA inside a
read-only-mounted container, `golang` toolchain), not the author's tree. Rules:

- **Own-run every load-bearing claim.** A relayed "it passes" is never a sign.
- **A SEC/leak finding is graded at a higher bar** — repro on a pure tree, file:line, A/B, own
  read of the raw capture, and for a leak-fix a live-stop proof, never green units alone.
- **Verify a peer's "not a bug" / "not the build" too** — a negative verdict on a leak or a
  regression is exactly where confirmation bias bites; reproduce the discriminator yourself.
- **Reconcile failure-looking lines against the acceptance on the same row** before concluding
  under-collection (a `settled|1000` next to a `voucher POST 200`/`cumulative=owed` is a
  pre-redeem artifact, not a loss).
- **Own your errors.** When a re-read or a peer correction overturns a sign, withdraw it in the
  record, say why, and check whether the same mistake sits elsewhere — but do not over-correct:
  grade each run on its own evidence (one run collecting does not clear a different run that
  genuinely under-collected).

## 6. Cold reproduction

Every catalogued bug has a cold repro: the minimal steps that reproduce it from the public body
on a clean checkout, with no insider state. If it cannot be cold-reproduced, it is not
catalogued as resolved.

## 7. Stack check

The whole set of fixes must apply in one order with no conflict and pass vet / test / `-race`
as a stack (not just individually). The applying order is pinned in `UPSTREAM-STACK.md`; the
stack-green run is the integration-level confirmation that the individually-graded fixes
compose.

## 8. A worked false positive: the stale-egress LIE

The zero-false-positive discipline (§5) is not abstract — it has to hold inside the harness's
own measurements. One example from this campaign shows why, and is the template for every
honesty check here.

The status check (check 4) polls the daemon's reported state every second and, in a separate
loop, probes real egress (which IP a request actually exits from). A sample is scored a **lie**
only when state and a *fresh* egress reading disagree twice in a row — e.g. the daemon reports
`state=none` (disconnected) while traffic still leaves via the node, or `state=active` while
egress is not the node.

The trap is latency. The egress probe is a real network call that takes time to return. A probe
that **started while the tunnel was up** (so it exits via the node) but **finished after the
daemon was stopped** carries its pre-stop node value forward — stamped with a fresh *finish*
time — into a teardown `state=none` sample. Scored naively that reads as
`LIE state=none egress=<node>`: the app looks like it is lying about being disconnected while
traffic still flows through the node. It is not. By that moment there are zero routes to the
node and the kill switch came down cleanly — both confirmed against the route table and the
packet capture. The node value is simply **stale**: measured before the stop by a probe that
only happened to finish after it.

The fix is a freshness rule, not a new signal: a probe is judged only if it both **started and
ended** inside the freshness window. A probe that spanned the stop reads `unknown`, and the
authoritative verdict for the teardown moment belongs to the **packet capture** (check 2), not
the status poller. A paired self-test locks it in and keeps the fix honest in both directions:

- a planted **stale** (stop-spanning) node reading must **not** be scored a lie, and
- a planted **live** leak — a genuinely fresh node reading while the app says disconnected —
  must **still FAIL**.

The second half matters as much as the first: a fix that silences a false positive must be
proven not to blunt the real signal it guards (this is the §3 mutant idea applied to a harness
rule).

The window is bounded by the **product** honesty deadline, not chosen for convenience. Q0445
pins that a session must not keep reading healthy (`state=active`, empty error) past ~2 s over a
genuinely dead data path — a `require.Eventually(2 s)` unit test enforces it at the product
level. The harness freshness window (`STATUS_EGRESS_FRESH_MS_LIVE`, 2.5 s) is held close to that
bound: wide enough to drop a stop-spanning probe, never wide enough to license a reading that
stays healthy past the deadline over a dead path to slip the lie check. And because the start+end
freshness rule ages a *hung* probe (a curl that never returns over a dead path) to `unknown`
rather than to a stale node value, the dead-path verdict there falls to the pcap and to Q0445's
own unit bound — not to the poller, which by design stops asserting once it has no fresh reading.

The same shape turns up on the `state=active` side. During an OpenVPN cut/reconnect blip the
status egress probe can momentarily resolve the host's NAT/external address while the daemon
still reads `active`, which looks like a kill-switch leak. The packet capture settles it: zero
packets to that address inside the active window means it was a probe artifact, not a leak.

The rule throughout: **a status-vs-egress disagreement is a question, not a verdict — the
packet capture answers it.** A harness that scores its own measurement latency as a product lie
fails §5 before the product ever gets a fair reading, so every honesty check here is written to
distrust a stale or single-sample reading and to defer the hard call to the capture.
