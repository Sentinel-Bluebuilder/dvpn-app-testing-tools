# Plan of record: <campaign name>

<!-- One file for the whole fleet. Section 0 is edited IN PLACE by the director; nothing is planned anywhere else. -->

## 0. Status board (updated in place by the director; last update <ISO-UTC>)

### 0.1 Where each part stands
| Part | State | Evidence |
|---|---|---|
| Fork cut | <tag + commit> | <gate log> |
| <product> | <build hash, suites passed> | <path> |

### 0.2 Every agent's row (in order; "→" = then)
| Role | Session | Row |
|---|---|---|
| Director | <session> | watchdog → routing → close-out |
| Grader | <session> | grade every close and every PR → final review |
| <role> | <session> | <step> → <step> → <step> |

### 0.3 Finish line (in order)
1. Every product on the final cut, suites passed, graded.
2. Every bug row closed with evidence; every upstream fix PR graded.
3. Upstream close-out: cold reproductions, stack check, index issue.
4. Reclaim + books.
5. Grader's final end-to-end review clean.
6. Machines stopped, temporary access removed, secrets reset.
7. Write-up published; director reports done.

## 1. Test structure
Built-in checks, suites, A/B rule, where each suite runs.

## 2. Re-test by what changed
| Bucket | Test |
|---|---|
| File untouched by the base, fix fork-only | Code test + suite pass |
| File changed by the base | Full A/B on its scenario |
| Fixed upstream / obsolete | One scenario confirming it |
| App-only fix | App suites |

## 3. Machines
| Machine | Holder | Always up? |
|---|---|---|

## 4. Rules
- Watchdog every 20–30 min; heartbeat every 30 min.
- Never stop for a go; the director takes every hard block; shared blocks are cleared by whoever hits them.
- Devnet only; chain transactions one at a time, 7 s apart per wallet.
- Upstream: PRs and issues only.
- Cloud only; ledger every machine change.
- No sub-agents; no permission laundering.
