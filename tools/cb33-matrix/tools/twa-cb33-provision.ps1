# twa-cb33-provision.ps1 - finish a cb33 client instance for the matrix on a Windows VM (TWA).
# Pre: C:\cb33\sentinel-dvpnd.exe + sentinel-dvpn.exe present; `dvpnd init --instance <I> --plain-key --owner <wx pubkey>`
# already run (operator key + config exist); the funded wallet is at C:\ddv\vm-wallet.json (64-int array).
# Does, in order: kill switch OFF (before any service start - these are public-IP boxes), install the funded wallet
# AS the operator key (operator == owner == funded) + lock its ACL, lock the whole C:\cb33 tree so its proxy
# sidecars are not Authenticated-Users-writable (Q0470), then service install + start + status.
# Never prints key contents. ASCII only (PS 5.1).
param([string]$Instance = 'c0', [string]$WinDir = 'C:\cb33')
$ErrorActionPreference = 'Stop'
Set-Location $WinDir
$state = "C:\ProgramData\sentinel-dvpn\$Instance"
$cfg = Join-Path $state 'config.toml'
$opk = Join-Path $state 'keys\operator.json'
$wallet = 'C:\ddv\vm-wallet.json'
$dvpnd = Join-Path $WinDir 'sentinel-dvpnd.exe'
if (-not (Test-Path $cfg)) { throw "no config at $cfg - run dvpnd init first" }
if (-not (Test-Path $wallet)) { throw "no funded wallet at $wallet" }

# 1) kill switch off (safety on a public-IP box)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$t = [IO.File]::ReadAllText($cfg)
$t = [regex]::Replace($t, "(?m)^kill_switch = .*$", "kill_switch = 'off'")
[IO.File]::WriteAllText($cfg, $t, $utf8)
Write-Output ("kill_switch => " + ([regex]::Match($t, "(?m)^kill_switch = .*$").Value))

# 2) funded wallet as the operator key (both are 64-int arrays)
Copy-Item $wallet $opk -Force
& icacls.exe $opk /inheritance:r /grant:r 'SYSTEM:F' 'Administrators:F' | Out-Null
$pub = (& $dvpnd key show operator --instance $Instance 2>&1 | Out-String).Trim()
Write-Output ("operator pubkey => " + $pub)

# 2b) lock C:\cb33 like the installer locks Program Files (Q0470, TWA 11-08). The cause is an Authenticated-Users
# ACE inherited from an ANCESTOR (the default C:\ ACL grants AU Modify), so the proxy sidecars under $WinDir\bin are
# AU-writable and the daemon correctly refuses them as "replaceable by an untrusted account". This hits BOTH arches
# equally - it is an ACL problem, not a LookPath-order one. Sever inheritance, re-grant SYSTEM/Admins full + Users
# RX, then explicitly strip any Authenticated-Users ACE (SID S-1-5-11) from grant AND deny, in case one survives the
# inheritance cut. Must run AFTER $WinDir is fully populated and BEFORE the service starts.
& icacls.exe $WinDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'Users:(OI)(CI)RX' /T /C | Out-Null
& icacls.exe $WinDir /remove:g '*S-1-5-11' /remove:d '*S-1-5-11' /T /C | Out-Null
Write-Output ("acl lock => " + $WinDir + " inheritance severed; Authenticated-Users (S-1-5-11) ACE removed (Q0470)")

# 3) service
Write-Output ("install => " + ((& $dvpnd service install --instance $Instance 2>&1 | Out-String).Trim()))
Start-Sleep -Seconds 2
Write-Output ("start   => " + ((& $dvpnd service start --instance $Instance 2>&1 | Out-String).Trim()))
Start-Sleep -Seconds 3
Write-Output ("status  => " + ((& $dvpnd service status --instance $Instance 2>&1 | Out-String).Trim()))
Write-Output ("scm     => " + (Get-Service -Name ("sentinel-dvpnd`$" + $Instance) -ErrorAction SilentlyContinue).Status)
