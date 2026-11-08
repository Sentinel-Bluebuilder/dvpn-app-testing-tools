# Director queue (in order; the director updates it in place)

**Never stop for a go. Keep doing the recommended task end to end. A refused action: skip that action and continue
with the rest.**

| # | Task | State | Waits on |
|---|---|---|---|
| A1 | <testing step> | RUNNING / ROUTED / WAITING / DONE: <evidence> | <owner or row> |
| B1 | Reclaim every wallet → books | WAITING | final passes |
| B2 | Grader's final review | WAITING | B1 |
| B3 | Stop machines, remove temporary access, reset secrets | WAITING | B2 |
| C1 | Write-up repo | DRAFTING | B2 |
| D1 | Handoffs; report done | WAITING | B3, C1 |

## Done today
- <one line per finished item, with evidence>
