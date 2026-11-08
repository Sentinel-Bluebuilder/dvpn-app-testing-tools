# Heartbeat line and watchdog prompt

## Heartbeat (every agent, every 30 min while working and on every state change)

Append one line to `HEARTBEAT.md`:

```
<ROLE> <ISO-UTC> <state> | next: <step from your row> | eta: <time> | vm: <VMs held or none>
```

Example:

```
TLX 2026-11-08T13:05Z S2 rerun 4/6 on 0.1.16 | next: soak 30 min | eta: 13:50Z | vm: linux-u22b
```

## Watchdog prompt (the director, every 20–30 min)

```
Watchdog check. Run tools/infra/fleet-watch.sh and list the live agent sessions.
For each STALE heartbeat (> 45 min) or idle agent with open work: send it its next step
(second miss in a row: reassign + tell the owner).
For each IDLE VM (two checks in a row) or UNCLAIMED VM: ask its holder to stop it (ledgered),
or stop it yourself if the holder is silent; never the controller or the reference nodes.
Clear or reroute any named block.
Append a 5-line summary to WATCH-LOG.md.
Report to the owner only what changed or needs them, in at most 5 lines.
```
