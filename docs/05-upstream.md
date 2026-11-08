# 05 — Upstream: from finding to fix PR, and the merge order

Who does what: the fork owner takes a finding to a graded PR (first half); the upstream reviewer checks that every open PR merges together, in one order, and still passes (second half).

## What "upstream" means here

- **Upstream** is the public repo `sentinel-official/sentinel-solana`, pinned at base commit `26de5240` for this whole effort.
- **We never push to it, merge into it, approve on it or close anything there.** We open issues and pull requests only.
- Every PR comes from the bot's fork, `Sentinel-Bluebuilder/sentinel-official-solana`, one topic branch per fix.
- **The fork** (`fork-cb33-*` tags) is our own build line. It carries every upstream PR we opened plus the fork-only fixes. Its tags (rc1 → final5) are what the apps ship.

## Where a fix lives

Every bug ends up in exactly one of these. The catalogue status says which (`docs/10-bugs.md`).

| Status | Meaning | Example |
|---|---|---|
| FIXED-UPSTREAM-PR | The bug is in pure `26de5240`; the fix is an open upstream PR, and the fork carries the same commit | #20 final usage sample, #25 reconnect id, #62 busy chain reads |
| FIXED-FORK | The buggy code exists only in the fork, so there is nothing upstream to fix | Q0444: the Q0396 credit guess in `nodeEnded` is fork code; `git grep` on `26de5240` finds no `nodeEnded` and no `SpentPaid` |
| FIXED-APP | The fix lives in a product repo (#31–#34, #28b, #29, #1b), not in the daemon | the Mac installer moving its tools to `/Library/devnet-dvpn` |
| FIXED-HARNESS | The test harness was wrong, not the product | `client stop --all` (cb33-matrix dc013a0) |
| NOT-A-BUG | Proven to be by design, with the proof | the Windows trust check refusing `C:\cb33\bin`: the ACL really grants Authenticated Users Modify, and x64 ran a trusted copy elsewhere |

**How to decide:** reproduce on pure `26de5240`. If it reproduces there, the fix goes upstream. If it doesn't, find the fork commit that introduced it, and the fix is fork-only.

## The path of one finding

1. **Reproduce on pure 26de5240.**
   - Build pure on the build host and run it, the same way the finding was seen.
   - Example: #28b ran a fake RPC answering HTTP 429 with a JSON-RPC `-32429` body. Pure dvpnd exited (`preflight failed: rpc`) after 1 call in 1.5 s; final4 exited after 5 calls in 7.7 s.
   - That proves upstream has the bug and that the fork didn't introduce it.
2. **Search for duplicates.**
   - List every issue and PR in the repo (`gh issue list` / `gh pr list --state all`) and grep their titles. `gh search` returned nothing for several real matches, so listing is the reliable method.
   - Also check our own open PRs: two of us fixed the node RPC crash in parallel (fork commit 9a24ff2 and upstream PR #74). The rule that settled it: **upstream keeps the PR that was filed first, the fork keeps the fix that covers more**, and the other one is dropped with a reason.
3. **Write the fix on 26de5240** in a scratch tree (`git archive`, never a checkout in the shared fork clone).
   - If it touches code an open PR already changes, stack it on that PR and say so in the body. Example: #39 depends on #9; the node start-wait overlaps #41's `prepareRuntime`.
4. **Write a test that fails on pure.** Run the new test against the parent code; it must FAIL there.
   - When the test needs a new constant or API, add only that much to pure, so the failure is about behaviour.
   - Example: #70 added only `SessionStatusClosing` to pure. The test failed with `expected "closing", actual "ended"`.
5. **Write a surgical mutant.** Flip only the fixed logic, keep everything compiling, and the test must FAIL.
   - Examples: `if false &&` on the new branch; `-32429` → `-99999`; `closing` → `active`.
   - A mutant that didn't apply (0 substitutions) proves nothing. ABW rejects it and reruns.
6. **Run the gate** on Go 1.27.3 with `GOTOOLCHAIN=local`:
   - `go vet` on linux, windows and darwin;
   - `gofmt -l`;
   - `go test -race -count=3` on every touched package, plus the full module suite.
   - Cross-builds that also fail on pure (freebsd/amd64: `service.LinkStats` undefined) are noted in the body, not fixed.
7. **Live A/B, when the bug shows at runtime.** The same rig and node run pure (A) and the fix (B), each 3×.
   - Example: #70 on Rocky 9 with OpenVPN. A read `active` for the whole 15 s stop, 3/3. B read `closing` from the first poll, then `ended`, 3/3.
8. **Write the body** (the 8 points below), then `gh pr create --head Sentinel-Bluebuilder:<branch>`.
9. **Independent grade (ABW)** before the PR counts as done. ABW reruns the pure failure and the mutant itself and signs only on its own runs.
   - A different implementation of the same fix is regraded, never carried over. Example: 976ebe3 vs a40c610; 9a24ff2 vs #74.
10. **Merge order.** Run every open PR stacked in one order on 26de5240, with the full suite on the stack. The order and the conflicts are published in the index issue #67. (Second half of this chapter.)

## The PR body: 8 points

Every body answers all eight, in this order. Source: `agents/UPSTREAM-REVIEW.md` §checklist.

1. **Bug:** what the user sees, in plain words.
2. **Where:** file:line on 26de5240.
3. **Reproduction on pure 26de5240:** the code test that fails there, and the live steps when there are any.
4. **Fix**, plus the test that fails on pure, plus the mutant.
5. **Gate:** vet ×3 OSes, gofmt, race; what was run and where.
6. **Scope, risk and compatibility:** files and lines changed; who reads any new value.
   - Example: #70's new `closing` status. Every reader on 26de5240 compares only against `ended`, so older clients are safe.
7. **Alternatives ruled out**, and why.
8. **Clean:**
   - no keys, hosts, IPs, wallet files or internal names;
   - bot identity only;
   - the duplicate search and its result.

Before posting, grep the body and the diff for internal names. The gate's name once reached a test message (`"rpc-gate: global rate limit"`), and it was scrubbed on the PR (a40c610) and in the fork (4ac90d8).

## Pushing without git push

The PR branches are created through the GitHub API, not `git push`:
- `api-files-commit.js` creates a new branch from a parent and an expected tree.
- `api-files-update.js` fast-forwards an existing branch. It checks that the head still equals the parent, and it never forces.

Both refuse if the tree they build differs from the tree computed locally (`git write-tree` on a temporary index). That keeps what was tested and what was pushed byte-identical.

## What we learned

- **Pure first, always.** Three "fork bugs" turned out to be upstream, and two "upstream bugs" turned out to be fork-only. The pure run decides it in minutes.
- **One owner per finding.** The parallel node-crash fix cost a second implementation and a second grade.
- **Test messages and comments go public too.** Scan them like the body.
- **A fix in shared code changes every binary.** Prove which apps need a new build with a stamp-matched rebuild: build the new source with the old build's commit/tag stamp and compare hashes.
  - final4: the CLI and the Windows/Mac daemons were byte-identical, so those apps stayed on final3.
  - final4.1: every binary changed, but only the Mac behaves differently.

## The stack check and the merge order

### Why a stack check
Every fix PR is graded alone, on the upstream base commit. That proves each fix, but not that 50 of them compose:
two PRs can touch the same lines (a merge conflict), or merge cleanly and still break each other's tests
(a semantic conflict). The upstream maintainer will merge them one by one, so we hand over **one order that is known
to merge with no conflict and pass every gate after the last one**.

### Method (one run)
All steps run on the control VM under the gate lock, Go pinned (`GOTOOLCHAIN=local`). Scripts: `tools/flx-stack.sh`
(fetch, pairwise, sequential stack) and `tools/flx-stack-suite.sh` (the suite).

1. **Fetch every open bot PR head** (`gh pr list --json number,headRefOid`) into `refs/prs/<n>`; record the heads.
   A PR pushed after this point needs its checks re-run.
2. **Pairwise matrix:** `git merge-tree --write-tree --merge-base=<base> <a> <b>` for every pair (~1,200 pairs at 50
   PRs, seconds). Each conflicting pair is classified:
   - *stacked*: one PR is built on the other (merge in order, no fix);
   - *append-only*: both add tests at the same place (keep both sides);
   - *real*: both change the same code.
3. **Sequential stack:** start from the base, `git merge --no-ff` each PR in the proposed order; stop at the first
   conflict.
4. **Suite on the stack head:** in all 6 Go modules, `go vet ./...` and `go test ./...`. Then `go test -race` on every
   package any PR touches.
5. **Isolate any failure:** run the failing test on the base, on each PR alone that touches the package, on pairs, and
   stacked, each `-count=5`. This tells "PR X's own bug" from "X and Y together" from "flaky".

### Fixing a conflict (rules)
- The **later** PR in the order absorbs the earlier one: a normal **merge commit into the later branch**, the conflict
  resolved by hand, then a plain fast-forward push to the bot fork. **Never a rebase or force-push** (reviewers keep
  their place; owner rule).
- The resolved head is graded alone again: gofmt, vet, `-race`, its own tests, then re-signed by the grader.
- The PR body gets a first line: `**Merge order:** merge after #A and #B.`
- A test-only race or fixture fix goes on the PR that owns the test, with a commit message naming the stack run that
  caught it. The PR's author is told to fetch before their next push.

### What the runs found

| Run | PRs | Result | Notable |
|---|---|---|---|
| 1 | 21 | 3 failures | all fixed at later heads (#29 command registration, #21 race) |
| 2 | 38 | 7 conflicting pairs, 4 real; 1 suite failure | #29 × #46: #29 only claims metered usage, so #46's test fixture claimed 0. Fixed in #46's test |
| 3 | 39 | green with append-only overlaps | #53 × #7/#25/#52 and #37 × #51 append to the same test files |
| 4 | 42 | **42/42, all green** | restructure: #25 ← #6 + #7, #52 ← #25, #57 ← #52, #53 ← #57, #35 ← #20, #51 ← #37 |
| 5 | **50 (#6–#66)** | **50/50, all green** (FINAL) | #59 ← #34 + #43, #58 ← #35; one `-race` hit in #41's own tests (parallel tests pinning a global build identity), fixed test-only |

Run 5 suite: `go vet` + `go test` exit 0 in all 6 modules; `go test -race` exit 0 on all 28 touched packages.

**After Run 5 (not in any pairwise run yet).** Each one below was gated on its own against `26de5240` (or the PR it
stacks on) and graded with a failing test and a mutant. None of them has been merge-tested against the Run 5 set, so
rerun pairwise before merging any of them.

| PR | What | Head |
|---|---|---|
| #69 (issue #68) | redeem-now below the threshold | `e100ecd` |
| #72 (issue #71) | a new lease for a node whose old lease is still closing | `0a2ca1e` |
| #73 / #74 | node/provider wait out a busy RPC at start (start check, then the first chain read) | #74 `6311f73` |
| #75 | status flags a failing tunnel while the session is active | `a27856e` |
| #77 | StartSession answers an unreachable chain RPC with Unavailable in plain words | `f89c559` |
| #79 | `sentinel-dvpnd key sweep` (fixes #78) | `49ea76a` |
| #81 | Linux: a killed daemon's kernel tunnel is removed at once (fixes #80) | `c01bad2` |
| #49 (2nd commit) | the daemon-down line in plain words only | `7b4d031` |
| #64 (2nd commit) | a revoked delegate approval is named too | `0321923` |
| #62 (later commit) | a 429 always carries Retry-After | `ff0b180` |

The fork twin of all of these is the last cut, `fork-cb33-4-final6` = `630e232`.

### The final merge order (Run 5)
```
#6 #7 #9 #15 #16 #17 #18 #20 #21 #22 #24 #26 #27 #28 #29 #30 #31 #32 #33 #34 #36 #37 #38
#39 #40 #41 #43 #44 #45 #46 #47 #48 #49 #50 #54 #56 #60 #61 #62 #63 #64 #66
then  #25 → #52 → #57 → #53
      #35 → #58
      #51
      #59
```
The first block is independent (any order among themselves). The chains must keep their order; each chain's PR body
names its predecessor.

> **Note (Q0438, ABW 2026-11-08, corrected):** the fork already carries the leftover-metering
> feature (`PeerCarryover`/`carryLeftover`) in every cut — so this is **not** a missing-PR gap.
> The live failure was an ordering bug: `clearLeftovers` removed the `dvpn-<tag>` interface before
> the carrying service read its counters, so ~44 MB/kill went unbilled (Q0438). The fix is a
> reorder (`fs36-f6-order.patch`, final6.1), not a port of #47 — porting #47 on top would
> double-bill. (An earlier version of this note said the #47 fix was "absent, port it"; that was a
> grep against the upstream symbol name `LeftoverStatsReader`, which the fork does not use — a name
> artifact, caught by FS36. The money gap was real; the diagnosis was wrong.)

Heads changed by the stack work (merge commits or test-only fixes, all fast-forward):

| PR | change | merge after |
|---|---|---|
| #25 | + #6, #7 (session.go, issuer.go, export_test.go) | #6, #7 |
| #52 | + #25 (`markContactLocked` on #7's monotonic clock) | #25 |
| #57 | + #52 | #52 |
| #53 | + #57 (`keepsFirewall` gains `case reasonSwitching`); test rows for the switching reason | #57 |
| #35 | + #20 (client/connect.go) | #20 |
| #58 | + #35 (`writeConf(…, noIPv6)` → `writeConfWith(…, noIPv6, localV4, localV6)`; template keeps #35's IPv6 route and #58's excludes) | #35 |
| #51 | + #37 (which contains #49) | #49, #37 |
| #59 | + #34, #43 (pid_file.go: wrapper-launched check, then #34's `resolveForMatch`) | #34, #43 |
| #41 | test-only: the 5 unreachable-RPC tests run serially | — |

### Lessons
- **Re-run pairwise for every new head.** It takes seconds; a new PR (#58, #59, #64, #66) was the only thing that
  ever reopened a green stack.
- **A missing ref looks like a conflict.** `merge-tree` against a PR number that does not exist (an issue number)
  fails on every pair. Check that each ref resolves before reading the matrix.
- **`-race` on the stack finds what alone-runs cannot.** Tests that write a package global (`t.Parallel()` +
  a pinned build identity) race only once enough other tests share the package.
- **Fixture drift is not a bug in either fix.** When fix B changes a rule that fix A's test fixture relied on, fix
  the fixture in A and keep both fixes.
