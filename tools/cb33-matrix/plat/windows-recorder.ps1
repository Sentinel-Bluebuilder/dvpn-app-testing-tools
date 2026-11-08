# --- cbm-recorder.ps1: run one cb33-matrix scenario ON the Windows VM and record it (TWA; contract by FWA, 2026-11-07) ---
# For VMs the driver reaches only by public IP (Azure-3): a kill-switched session blocks the driver's ssh, so the whole
# scenario runs here as a SYSTEM task and ctl-1 collects the files after and runs the same checks on them.
# Deploy as C:\cb33\cbm-recorder.ps1. ASCII only (PowerShell 5.1 reads a BOM-less file as cp1252).
#
#   cbm-recorder.ps1 -Dir C:\cb33\rec\<scenario> -Seconds <max> [-Instance c0] [-AppState] [-Launch]
#     -Launch   register this same command (minus -Launch) as a SYSTEM scheduled task, start it, return at once:
#               the run survives the ssh drop. Without -Launch it runs in the foreground.
#
# Dir layout (the driver writes steps.ps1 before start; everything else is written here):
#   state        'started' while running, then 'done <exit of steps.ps1>' (or 'done deadman')
#   status.tsv   one row per second: <epoch_ms> TAB <ms the line took> TAB <state=.. ks=.. id=.. text=..> TAB <egress|none> [TAB app]
#                the daemon line every second; with -AppState also an 'app' row from app-state.cjs (5th column 'app')
#   egress.tsv   <epoch_ms> TAB <egress|none> from its own loop (ipify, 4 s cap); status.tsv carries the latest value
#   cli.txt      stdout + stderr of steps.ps1 (started after 3 s of baseline polling)
#   cap.etl / cap.pcapng   pktmon capture of the NIC component for the whole run
#   recorder.log what this script did, with times
#   stop         the driver may create it to end the run early
# At the end: every session stopped (7 s apart), pktmon stopped and converted, 'done <exit>' written.
# Deadman: a separate SYSTEM task waits -Seconds + 120 s; if 'done' never came it restores the network the way
# plat/windows.sh deadman_start does (cut rule off, sessions stopped, kill switch off, service restart).
# Never prints keys: status lines carry the session state and the CLI's error/message text only.
param(
  [Parameter(Mandatory = $true)][string]$Dir,
  [Parameter(Mandatory = $true)][int]$Seconds,
  [string]$Instance = 'c0',   # the app's client instance (cb33 instance.go; FLX layout.ts, FWA 7042312)
  [string]$WinDir = 'C:\cb33',
  [switch]$AppState,
  [switch]$Launch,
  [switch]$DeadmanRestore   # internal: the deadman task calls this to restore the network
)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$self = $MyInvocation.MyCommand.Path

# --- -Launch: hand the run to a SYSTEM task and return ---
if ($Launch) {
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Dir `"$Dir`" -Seconds $Seconds -Instance $Instance -WinDir `"$WinDir`""
  if ($AppState) { $a += ' -AppState' }
  $task = 'cbm-recorder'
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $a
  $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($Seconds + 600)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Settings $set -Force | Out-Null
  Start-ScheduledTask -TaskName $task
  Write-Output "launched $task -> $Dir"
  exit 0
}

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$log = Join-Path $Dir 'recorder.log'
function Log([string]$m) { [IO.File]::AppendAllText($log, ((Get-Date).ToUniversalTime().ToString('o') + ' ' + $m + "`r`n"), $utf8) }
function Put([string]$name, [string]$text) { [IO.File]::WriteAllText((Join-Path $Dir $name), $text, $utf8) }
function EpochMs { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

$cli = Join-Path $WinDir 'sentinel-dvpn.exe'
$cliHome = Join-Path $WinDir 'cli'
$svc = 'sentinel-dvpnd$' + $Instance
$stateDir = 'C:\ProgramData\sentinel-dvpn\' + $Instance
$cfg = (Get-ChildItem $stateDir -Recurse -Filter config.toml -ErrorAction SilentlyContinue | Where-Object { Select-String -LiteralPath $_.FullName -Pattern '^\s*kill_switch' -Quiet } | Select-Object -First 1).FullName
if (-not (Test-Path $cli)) { Log "no $cli"; Put 'state' 'done setup'; exit 2 }
if (-not $cfg) { Log "no config.toml with kill_switch under $stateDir"; Put 'state' 'done setup'; exit 2 }

function SessionIds {
  $out = & $cli --home $cliHome client sessions --instance $Instance 2>&1 | Out-String
  [regex]::Matches($out, '"id": *"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
}
# The plat_status_line format, from every session newest first (the first id goes stale after a redial, Q0423).
function DaemonLine {
  $ks = (Select-String -LiteralPath $cfg -Pattern "^\s*kill_switch\s*=\s*['`"]([a-z]+)" | Select-Object -First 1).Matches.Groups[1].Value
  $st = ''; $out = ''; $script:CallMs = 0
  foreach ($s in @(SessionIds)) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $cli --home $cliHome client status $s --instance $Instance 2>&1 | Out-String
    $script:CallMs = [long]$sw.ElapsedMilliseconds
    $st = ([regex]::Match($out, '"status": *"([^"]+)"')).Groups[1].Value
    if ($st -in 'active', 'reconnecting', 'connecting', 'checking') { break }
  }
  $txt = ([regex]::Match($out, '"(error|message)": *"[^"]*"')).Value
  if (-not $st) { $st = 'none' }; if (-not $ks) { $ks = 'off' }
  if (-not $s) { $s = '-' }
  "state=$st ks=$ks id=$s call_ms=$($script:CallMs) text=$txt" -replace "[`t`r`n]+", ' '
}
function Restore([string]$why) {
  Log "restore: $why"
  Remove-NetFirewallRule -DisplayName cbmcut -ErrorAction SilentlyContinue
  foreach ($s in @(SessionIds)) { & $cli --home $cliHome client stop $s --instance $Instance 2>&1 | Out-Null; Start-Sleep -Seconds 7 }
  $t = [IO.File]::ReadAllText($cfg)
  [IO.File]::WriteAllText($cfg, [regex]::Replace($t, "(?m)^(\s*kill_switch\s*=\s*)['`"][a-z]+['`"]", "`${1}'off'"), $utf8)
  Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
}

# --- the deadman: its own SYSTEM task, so it fires even if this process dies ---
$dmTask = 'cbm-rec-deadman'
$dmFile = Join-Path $Dir 'deadman.ps1'
$dmBody = @"
Start-Sleep -Seconds $($Seconds + 120)
`$st = Get-Content -LiteralPath '$Dir\state' -ErrorAction SilentlyContinue
if ("`$st" -like 'done*') { exit 0 }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$self' -Dir '$Dir' -Seconds 0 -Instance $Instance -WinDir '$WinDir' -DeadmanRestore
"@
if ($DeadmanRestore) { Restore 'deadman: no done after the time limit'; Put 'state' 'done deadman'; exit 1 }
[IO.File]::WriteAllText($dmFile, $dmBody, $utf8)
Unregister-ScheduledTask -TaskName $dmTask -Confirm:$false -ErrorAction SilentlyContinue
$dmAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dmFile`""
$dmPr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $dmTask -Action $dmAct -Principal $dmPr -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($Seconds + 900))) -Force | Out-Null
Start-ScheduledTask -TaskName $dmTask
Log "deadman armed: $($Seconds + 120) s"

# --- capture ---
$etl = Join-Path $Dir 'cap.etl'
& pktmon stop 2>&1 | Out-Null
& pktmon filter remove 2>&1 | Out-Null
$pk = & pktmon start --capture --comp nics --file-name $etl 2>&1 | Out-String
Log ("pktmon start: " + ($pk -replace '\s+', ' ').Trim())
Put 'state' 'started'

# --- egress loop (its own process, 4 s cap per probe) ---
$egFile = Join-Path $Dir 'egress.tsv'
$egScript = Join-Path $Dir 'egress.ps1'
[IO.File]::WriteAllText($egScript, @"
while (-not (Test-Path '$Dir\stopeg')) {
  `$t = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  try { `$e = (Invoke-RestMethod -Uri https://api.ipify.org -TimeoutSec 4).ToString().Trim() } catch { `$e = 'none' }
  [IO.File]::AppendAllText('$egFile', "`$t``t`$e``r``n")
  Start-Sleep -Milliseconds 1000
}
"@, $utf8)
$eg = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$egScript`"" -WindowStyle Hidden -PassThru
function LatestEgress { $l = Get-Content -LiteralPath $egFile -Tail 1 -ErrorAction SilentlyContinue; if ($l) { ($l -split "`t")[1] } else { 'none' } }

# --- app-state (optional): the app's own line, from app-state.cjs over CDP ---
$node = $null; $appJs = 'C:\ddv\app-state.cjs'
if ($AppState) {
  $n = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($n) { $node = $n.Source } else {
    $exe = Get-ChildItem 'C:\Program Files\Devnet dVPN' -Filter 'Devnet dVPN.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { $node = $exe.FullName }   # Electron as Node (ELECTRON_RUN_AS_NODE=1)
  }
  if (-not $node -or -not (Test-Path $appJs)) { Log "AppState: no node or no $appJs; app rows skipped"; $AppState = $false }
}
function AppLine {
  $env:ELECTRON_RUN_AS_NODE = '1'
  $o = & $node $appJs 2>&1 | Select-Object -Last 1
  Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  "$o" -replace "[`t`r`n]+", ' '
}

# --- poll, steps after 3 s of baseline, stop on Dir\stop or the time limit ---
$st = Join-Path $Dir 'status.tsv'
$steps = Join-Path $Dir 'steps.ps1'
$t0 = Get-Date; $proc = $null; $exit = 'none'
while ($true) {
  $tick = Get-Date
  # ms = the one `client status` call whose answer is reported (the < 1 s promise), not the session list and the
  # other sessions' calls this harness makes to pick it (TWA 11-08: those made every Windows sample ~1.5 s).
  $a = EpochMs; $line = DaemonLine; $ms = $script:CallMs
  [IO.File]::AppendAllText($st, "$a`t$ms`t$line`t$(LatestEgress)`r`n", $utf8)
  if ($AppState) { $a = EpochMs; $al = AppLine; $ms = (EpochMs) - $a; [IO.File]::AppendAllText($st, "$a`t$ms`t$al`t$(LatestEgress)`tapp`r`n", $utf8) }
  $el = ((Get-Date) - $t0).TotalSeconds
  if (-not $proc -and $el -ge 3) {
    if (Test-Path $steps) {
      $proc = Start-Process cmd.exe -ArgumentList "/c powershell -NoProfile -ExecutionPolicy Bypass -File `"$steps`" > `"$Dir\cli.txt`" 2>&1" -WindowStyle Hidden -PassThru
      Log "steps started (pid $($proc.Id))"
    } else { Log 'no steps.ps1: recording only'; $proc = 'none' }
  }
  if ($proc -and $proc -ne 'none' -and $proc.HasExited -and $exit -eq 'none') { $exit = $proc.ExitCode; Log "steps exited $exit" }
  if (Test-Path (Join-Path $Dir 'stop')) { Log 'stop file'; break }
  if ($el -ge $Seconds) { Log "time limit $Seconds s"; break }
  if ($exit -ne 'none' -and $el -ge 3) { Start-Sleep -Seconds 3; Log 'steps done; 3 s tail recorded'; break }
  $left = 1000 - ((Get-Date) - $tick).TotalMilliseconds
  if ($left -gt 0) { Start-Sleep -Milliseconds ([int]$left) }
}
if ($proc -and $proc -ne 'none' -and -not $proc.HasExited) { Log 'steps still running at stop: killed'; Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; $exit = 'killed' }

# --- end: sessions down (7 s apart), capture out, done ---
foreach ($s in @(SessionIds)) { & $cli --home $cliHome client stop $s --instance $Instance 2>&1 | Out-Null; Log "stopped session $s"; Start-Sleep -Seconds 7 }
New-Item -ItemType File -Force -Path (Join-Path $Dir 'stopeg') | Out-Null
Start-Sleep -Seconds 2
if (-not $eg.HasExited) { Stop-Process -Id $eg.Id -Force -ErrorAction SilentlyContinue }
& pktmon stop 2>&1 | Out-Null
$cv = & pktmon etl2pcap $etl --out (Join-Path $Dir 'cap.pcapng') 2>&1 | Out-String
Log ("etl2pcap: " + ($cv -replace '\s+', ' ').Trim())
Unregister-ScheduledTask -TaskName $dmTask -Confirm:$false -ErrorAction SilentlyContinue
Put 'state' "done $exit"
Log "done $exit"
