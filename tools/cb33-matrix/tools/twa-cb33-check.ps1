# twa-cb33-check.ps1 - READY check for a cb33 client instance on a Windows VM (TWA). Prints no secrets.
param([string]$Instance = 'c0', [string]$WinDir = 'C:\cb33')
$ErrorActionPreference = 'Continue'
Set-Location $WinDir
$svc = 'sentinel-dvpnd$' + $Instance
$s = Get-Service -Name $svc -ErrorAction SilentlyContinue
Write-Output ("scm      => " + $(if ($s) { $s.Status } else { 'NOT INSTALLED' }))
$cfg = "C:\ProgramData\sentinel-dvpn\$Instance\config.toml"
if (Test-Path $cfg) { Write-Output ("config   => " + ([regex]::Match([IO.File]::ReadAllText($cfg), "(?m)^kill_switch = .*$").Value)) }
Write-Output ("operator => " + ((& (Join-Path $WinDir 'sentinel-dvpnd.exe') key show operator --instance $Instance 2>&1 | Out-String).Trim()))
Write-Output ("sessions => " + ((& (Join-Path $WinDir 'sentinel-dvpn.exe') --home (Join-Path $WinDir 'cli') client sessions --instance $Instance 2>&1 | Out-String).Trim()))
$eg = 'BLOCKED'
try { $eg = (Invoke-RestMethod -Uri https://api.ipify.org -TimeoutSec 6).ToString().Trim() } catch { $eg = 'BLOCKED' }
Write-Output ("egress   => " + $eg)
