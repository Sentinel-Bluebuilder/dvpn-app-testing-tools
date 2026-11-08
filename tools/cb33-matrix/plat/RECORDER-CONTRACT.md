# Recorder contract — what the driver calls, what the recorder writes (TWA, for FWA, 2026-11-07)

For a `ks != off` scenario the driver (cb33-matrix.sh run_scenario, lines ~64-78) uses the recorder
instead of the live path, but **only if both** `plat_record_start` is defined **and** the scenario has a
sibling `<fn>_ps` function. So each ks-on scenario needs a `<fn>_ps` that emits its steps.ps1 to stdout,
and plat/windows.sh needs `plat_record_start` + `plat_record_collect`.

## The three calls the driver makes (in order)
1. `"<fn>_ps" "<PROTO>" > "$SCEN_DIR/steps.ps1"`  — scenario author provides `<fn>_ps`; prints a PowerShell
   step script (the body that `<fn>` would run live) to stdout. It runs ON the VM, as the recorder's steps.ps1.
2. `plat_record_start "<SUITE-SCENARIO-PROTO>" "<path to steps.ps1>" "<RECORD_MAX, default 900>"`
   - stdout+stderr → scenario.log; **return code is the scenario rc** (0 pass, nonzero fail, 77 skip).
   - It must: scp steps.ps1 to the VM, launch the recorder as a SYSTEM task, and **block until the run ends**
     (poll the VM's `<Dir>\state` until it reads `done <exit>` / `done deadman` / `done killed`), returning that exit.
3. `plat_record_collect "<SCEN_DIR>"`  — pull the recorder's files back into SCEN_DIR; nonzero → rc=1.

## What the driver expects in SCEN_DIR after collect
- `status.tsv`, rows **tab-separated**: `epoch_ms  ms  <state=… ks=… text=…>  egress  [app]`
  (col3 starts `state=`; col5 is literally `app` only on app-line rows.) The driver auto-detects this shape
  (NR==1 col3 ~ /^state=/), renames it to status-recorder.tsv, and reformats to the live `status.tsv`
  the checks read (`epoch_s  ms  egress  line`) + a `status-app.tsv`. So: just deliver status.tsv as the
  recorder writes it.
- a capture named `phys.pcap` or `*.pcapng` (offline leak check picks the first). cbm-recorder writes `cap.pcapng`.

## What cbm-recorder.ps1 (this dir → deploy as C:\cb33\cbm-recorder.ps1) writes in -Dir
`state` ('started', then `done <exit>`), `status.tsv` (exact shape above, 1 Hz; daemon line, plus an `app`
row when -AppState), `egress.tsv`, `cli.txt` (steps.ps1 stdout+stderr), `cap.etl` + `cap.pcapng`,
`recorder.log`. It writes steps.ps1/egress.ps1/deadman.ps1 itself.

### Invocation (what plat_record_start should run)
- Deployed by the driver: plat_record_start uploads windows-recorder.ps1 → `C:\cb33\cbm-recorder.ps1` on every run, so the VM never runs an older copy.
- Per run, as the ssh admin:
  `powershell -File C:\cb33\cbm-recorder.ps1 -Dir C:\cb33\rec\<label> -Seconds <max> -Instance $INSTANCE [-AppState] -Launch`
  `-Launch` registers SYSTEM task `cbm-recorder`, starts it, returns at once (survives the ssh drop when KS blocks).
- Then poll `Get-Content C:\cb33\rec\<label>\state`; when it matches `done *`, parse the exit after `done `.
  (`done <int>` = steps.ps1 exit; `done deadman` = time limit hit → treat as fail/1; `done killed` = steps
  overran → fail.)
- Suggest: plat_record_start writes the remote Dir to `$SCEN_DIR/.rdir`; plat_record_collect reads it and
  scps `<Dir>\{status.tsv,cap.pcapng,cli.txt,egress.tsv,recorder.log}` → SCEN_DIR.
- `<label>` sanitised for a Windows path (no `:` etc.); `SUITE-SCENARIO-PROTO` is already safe.

Deadman is built in (separate SYSTEM task `cbm-rec-deadman`, fires at Seconds+120 s): cut rule off, sessions
stopped 7 s apart, kill switch off, service restart — same restore as plat/windows.sh deadman_start.

## One sample pass (s1_core_ks, wireguard) — status.tsv rows
```
1762549200123	41	state=active ks=on text=Connected - via wireguard	185.199.108.7
1762549201170	47	state=active ks=on text=Connected - via wireguard	185.199.108.7
1762549260310	38	state=ended ks=on text=Disconnected	none
```
Pass = while active, egress is the node's IP (no leak), ks stays `on`; after the steps disconnect, `state=ended`.
`185.199.108.7` stands in for the node egress; `none` = egress probe blocked or after disconnect.
