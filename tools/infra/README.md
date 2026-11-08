# tools/infra

| Tool | Runs on | What it does |
|---|---|---|
| `fleet-watch.sh` | the director's machine | Read-only watchdog: stale agent heartbeats, running VMs with their load, VMs nobody claims, the last RPC failover. Changes nothing. |
| `rpc-failover.sh` | the controller VM, cron every 5 min | Probes each RPC key and points lane files at working keys; falls back to public devnet. Never prints a key. |

Every address, project, account and key path is an env var, listed at the top of each script. Nothing in this folder
holds a real value. Keys live in files outside the repo, mode 600.

**Why lanes:** clients read a lane file, not a key. When a key runs out, its lane moves to a healthy key and no client
changes. Nodes read their RPC only at start, so a `SWITCHED` line in the log means: re-point the nodes.

Example cron line on the controller:

```
*/5 * * * * SECRETS_DIR=$HOME/secrets bash $HOME/tools/infra/rpc-failover.sh >/dev/null 2>&1
```
