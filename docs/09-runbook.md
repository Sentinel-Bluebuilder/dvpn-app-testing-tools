# 09 — Runbook: repeat all of this on a new upstream commit

Follow these steps in order. Each step names its owner role (`docs/08-ai-fleet.md`) and the tool it uses.
"Base" means the new upstream commit you are testing.

## Step 0 — Set up (director)

1. Copy `templates/` into the fleet's notes folder: plan of record, director queue, heartbeat, handoff.
2. Fill in the roster: one agent per role, session name next to it.
3. Bring up the controller, the two reference nodes and the build box (`docs/07-infra.md`). Ledger each.
4. Put the RPC keys on the controller, install `tools/infra/rpc-failover.sh` in cron, start the gate.
5. Fund the test wallets from the funder (`tools/money/sol-topup.sh`, wallet list format in `tools/money/README.md`).
6. Start the watchdog: `tools/infra/fleet-watch.sh` every 20–30 min.

## Step 1 — Reference nodes (node side)

1. Node A: build pure upstream at the base. Start all protocol daemons and list them on chain.
2. Node B: same build, plus the fork (step 2) once it exists.
3. Record each node's per-protocol ids where the harness can read them (`tools/cb33-matrix/lib/nodes.sh` reads env).
4. Keep both listings alive. A lapsed listing stalls every test.

## Step 2 — Fork cut (fork owner)

1. Merge the fork onto the base. Mark each fork commit NEEDED / FIXED-UPSTREAM / OBSOLETE.
2. Work in scratch trees (`git archive <rev> | tar -x`). Never check out in the shared fork clone. Other agents
   archive from it, and a moved HEAD sends their next build to the wrong commit.
3. Gate: build, vet, cross-builds for every OS, `go test -race -count=3`, and the on-chain program diff must be empty.
   If a gate fails, rerun the failing test alone under `-race -count=6`. A test that fails only sometimes is fixed in
   the test, with its own test-only commit, never retried until it passes.
4. Tag the cut (`rc1`, then each final). Stage the binaries per product on the controller with `SHA256SUMS`.
5. For every cut after the first, decide which products need a rebuild by a **stamp-matched rebuild**: build the new
   source with the previous cut's commit and tag stamps (same flags: `CGO_ENABLED=0 -trimpath`) and compare hashes.
   A byte-identical binary needs no rebuild and no rerun. A changed binary whose change is unreachable for that
   product's role (node-only code in a client) needs no rebuild either. Say so explicitly when announcing it. Mobile
   libraries link the Linux-tagged code too, so check them the same way.
6. Announce the stage path and hashes to every product owner directly.

## Step 3 — Build every product (product owners)

1. Pin the fork cut's binaries by hash (`deps.lock` or the equivalent).
2. Build. Check the shipped binaries' hashes against `SHA256SUMS`.
3. Hand the build hashes to the platform tester.

## Step 4 — Prove the harness (grader + harness owner)

1. Plant known failures (a leak, a dishonest status, a wrong amount) and confirm every built-in check catches them.
2. Run the pure build: the known bugs must show up.
3. Each tester runs from its own pinned copy of the harness at a named commit. A harness change goes into a **new**
   directory named for its commit. Never copy it over a tree a run is using: check with
   `pgrep -af 'bash cb33-matri[x].sh'` first. A mid-run overwrite voids every cell of that run.

## Step 5 — Full run (platform testers)

`tools/cb33-matrix/cb33-matrix.sh` with the platform adapter (`plat/<os>.sh`). Suites S0–S13
(`docs/01-test-method.md`). The five built-in checks run during every scenario.

- One main machine per platform; the A control runs on the same machine.
- Distro pass on Linux: S1 + S2 + S6 + S10 per distro.
- Real phones: `tools/ftl/ftl-run.sh` (env vars in `tools/ftl/README.md`).
- Node side: S11 in the lab plus a short check on node B.
- Send raw evidence to the grader; the grader signs or rejects each cell.

## Step 6 — Every bug gets a fix (fork owner, product owners)

1. Each failure becomes a queue row with its evidence.
2. Classify it: upstream, fork-only, app-only, harness, infra or not a bug.
3. Upstream bugs: search for duplicates, write the fix with a test that fails without it and a surgical compiling
   mutant, run the A/B with one side changed, gate it, open the issue and the PR from the bot fork. Body standard:
   `docs/05-upstream.md`.
4. The grader grades each PR independently with its own re-run. Zero false positives.

## Step 7 — Re-test by what changed (everyone)

- File untouched by the base and the fix is fork-only: code test plus a suite pass. The old A/B stands.
- File changed by the base: full A/B on its scenario.
- A new fork cut with a small client diff: swap the binary and run a targeted rerun (S1 smoke on every protocol,
  plus the rows tied to the change, plus S2 core). Not full suites.
- A node-side-only cut: only the reference nodes and the node tools swap. Products whose binaries the stamp-matched
  rebuild (step 2.5) shows unchanged keep their results.
- Declare a "last client cut" near the end. After it, a client fix waits in the fork (tagged, so the catalogue can
  cite it) unless it is a proven ship-blocker. Its upstream PR alone closes the bug.
- One 30-min soak per platform and one S9 50-cycle run, on the final build only.

## Step 8 — Upstream close-out (upstream reviewer)

1. Cold reproduction: an agent who didn't write a PR follows only its public body on a clean base checkout.
2. Stack check: apply every open PR in order on a clean base; full suite; record conflicts and the merge order.
3. One public index issue listing every PR in merge order and every bug issue with its fix.

## Step 9 — Close out (director)

1. Reclaim every wallet (`tools/money/reclaim-run.sh`: start-close → wait → close → withdraw → sweep, 7 s per wallet).
   Reconcile the books.
2. Grader's final end-to-end review. Anything failing goes back to its owner until clean.
3. Stop every VM except the controller and the reference nodes. Remove temporary access. Reset the cloud secrets.
4. Update the handoffs; write up the results (this repo).

## Done when

Every queue row is closed with evidence, the bug catalogue reconciles with 0 open, every upstream PR is graded, the
books balance, and the machines are stopped.
