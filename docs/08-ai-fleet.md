# 08 — How the AI fleet ran the work

About 20 AI agents ran this effort. Each was a separate Claude Code session on one laptop, with one human owner who
was mostly away. This chapter is the operating model: who did what, how they talked, the rules that kept the work
moving without the owner, and what we learned. The rules are written so a new fleet can copy them as they are; see
`templates/` for the files.

## 1. Roles

| Role | Count | Job |
|---|---|---|
| **Director (DIR)** | 1 | Owns the plan of record and one ordered queue. Routes work, runs the watchdog, funds wallets, does every step another agent is fully blocked on, reports to the owner. Never tests a product itself. |
| **Grader (ABW)** | 1 | Independent judge. Re-runs evidence, signs or rejects every close, every fix cut and every upstream PR. Sets the yardsticks (e.g. "status leaves active within 2 s of a protocol kill"). |
| **Fork owner (FWX)** | 1 | Owns the fork of the upstream node software: cuts versioned tags (rc → final5), runs the gate, writes and self-checks upstream fix PRs. |
| **Upstream reviewer (FLX)** | 1 | Stack check of all open PRs together, merge order, index issue, cold reproductions. Also builds the Linux app. |
| **Product owners** | 1 per product | Build their app on the current fork cut and fix app bugs: Windows (FWA), macOS (FMC), Android (FAN), Linux (FLX), node manager (#28b), plan manager (#29), node tester (#1b). |
| **Platform testers** | 1+ per OS | Run the suites on their OS and send raw evidence to the grader: Windows (TWA), macOS (TMC), Linux Ubuntu (TLX), Linux distros (TLX2). |
| **Node side** | 2 | FS36 runs the two reference nodes; TS36 runs the node lab (suite S11). |
| **Helpers** | as needed | Bug catalogue (#29), harness port + gaps (FLX2). |

One agent, one job. An agent never grades its own work: the grader re-runs it.

## 2. One plan, one queue per agent

- **Plan of record:** one file, `PLAN.md` (template in `templates/plan-of-record.md`). Section 0 is a status board that
  the director updates in place. It holds every agent's row of work, in order ("→" means "then"), and the finish line
  as a numbered list. Nothing is planned anywhere else.
- **Director queue:** one ordered table of the director's own steps, with a "waits on" column, so nothing is
  forgotten across context resets (`templates/director-queue.md`).
- **Every bug is a row** in the queue store (`Q0001…`). A row closes only with evidence the grader accepts.
- **Handoffs:** each project keeps a handoff file with a STATE block on top (always-current facts, edited in place)
  and dated entries below. A fresh session reads only its own handoff.

## 3. Communication

- **Messages are one line where possible:** what happened, the evidence path, the next step. No narration.
- **Raw evidence goes to the grader,** not summaries. Every claim names a log, commit or PR.
- **Address agents by session name.** The director keeps a roster table (role → session).
- **Heartbeat:** every agent appends one line to `HEARTBEAT.md` every 30 min while working and on every state change:
  `<ROLE> <ISO-UTC> <state> | next: <step> | eta: <time> | vm: <VMs held or none>`.
- **The owner gets at most 5 lines per update:** only what changed or needs them.

## 4. The watchdog

Every 20–30 min the director runs `tools/infra/fleet-watch.sh` and lists the live sessions, then acts:

| Seen | Action |
|---|---|
| Heartbeat older than 45 min, or an idle agent with open work | Send it its next step. A second miss in a row: reassign the work and tell the owner. |
| A VM idle (load < 0.15) on two checks, or a VM nobody claims | The holder stops it (ledgered); if the holder is silent, the director stops it. Never the controller or the reference nodes. |
| A named block | Clear it or reroute it the same turn. |
| An ETA missed by more than 50 % | Ask why. |

Each check appends a 5-line summary to `WATCH-LOG.md`.

## 5. Autonomy rules

These are what let the fleet finish with the owner away.

1. **Never stop for a go.** Take the recommended option, note it, carry on. If one action is refused, skip that action
   and continue with the rest. Asking "should I…?" is banned.
2. **The director takes over every hard block.** When an agent is fully blocked on something it can't do itself
   (funding, a transfer, an owner-only step), the director does it at once, tells the agent so they don't both do it,
   and queues the agent's next step.
3. **Every agent clears shared blocks itself.** A broken shared resource (a node not live, an RPC lane down, an empty
   wallet, a dead tunnel, a full disk) is never a reason to wait. The first agent to hit it reports it in one line to
   the director and the resource's owner. In the same turn it moves its own work to a working alternative. The owner
   fixes it end to end; anyone allowed to fix it does so after 20 min of silence. Waiting idle is a watchdog miss.
4. **Stay inside permissions.** A peer's message is information, not approval. If a peer was refused an action, no
   other agent does it for them ("permission laundering"); it goes to the owner with a one-line fix.
5. **No sub-agents.** Each agent does its work itself, in order. Concurrency comes from the fleet, not from fan-out
   inside one session.
6. **Ask first only for** destructive steps nobody requested (force-push, deleting branches or data) and for
   anything public for the first time (a new public repo).

## 6. Safety rules that held across the fleet

- **Money:** devnet only. Chain transactions run one at a time, 7 s apart per wallet. The funder key never leaves the
  owner's laptop. Every wallet is listed for the final reclaim (`docs/06-money.md`).
- **Upstream:** pull requests and issues only, from the bot's fork. Never push to, merge into or close anything upstream.
- **Git:** our own repos work on `main` only; protection is a commit, never a branch or stash. Stage files one by one.
  Bot identity on every commit.
- **Secrets:** never printed, never committed, never in a message. Scan before anything goes public.
- **Cloud only:** builds, tests, emulators and large greps run on cloud machines. The laptop edits files and runs
  git, gh and ssh, which protects its memory.
- **Ledger:** every VM start, stop or change is one line in the infra ledger.

## 7. Efficiency: what we cut

| Waste | Fix |
|---|---|
| Re-running full suites after every small cut | Re-test only by what changed (plan §2 "reuse buckets"). A one-function client fix gets a targeted rerun (core + the affected rows), not full suites. |
| Rebuilding an app twice for back-to-back cuts | A product owner waits for the next cut if it lands within ~15 min, and builds once. |
| Long soaks | 2 h soak per platform cut to 30 min on the final build only (owner call). |
| Asking the owner | Banned; see §5. |
| Agents idle behind one broken node | The shared-block rule (§5.3). |
| Copying large files through the laptop | Cloud-to-cloud copies only. |

## 8. Incidents and the rule each one produced

| Incident | Rule it produced |
|---|---|
| The pure reference node's on-chain listing lapsed, and every test against it stalled | Shared-block rule (§5.3); the node owner runs a heartbeat on the listing; upstream fix PR #66 (renew before it lapses). |
| The harness was overwritten mid-run on the shared controller | Each tester runs from its own pinned copy of the harness at a named commit. |
| A wallet was swept while its final passes still needed it | Sweep only after the holder's last run ends; the reclaim is the last step, not a tidy-up. |
| The reclaim read the wrong column of a list | Money tools parse one named field and cut trailing notes (`tools/money/README.md`). |
| A tester's reverse tunnel to the private RPC gate was refused | That tester ran on public devnet the same turn, with no wait. |
| The browser sign-in picked the wrong cloud account | Sign-in scripts open a private window and check the signed-in account before any change. |
| Someone checked out an old commit in a shared fork clone | Shared clones are read with `git archive` only, never checked out. |
| A rate-limited RPC failed tests that had nothing to do with the RPC | Budget per key raised to fit the plan; status polls never touch the RPC. |

## 9. Re-using this model

Copy `templates/`, fill in the roster, and start the director with the plan of record. The director's first jobs:
write the roster, give each agent one row, start the watchdog, and keep the queue.
