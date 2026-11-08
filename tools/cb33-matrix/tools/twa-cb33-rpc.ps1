# twa-cb33-rpc.ps1 - point a cb33 client instance's [rpc] at the lane-b Helius endpoint (TWA, RPC-PLAN lane b).
# Reads the URLs from a staged env file (never from argv/logs), rewrites [rpc].url/ws_url in config.toml, deletes the
# env file, restarts the service. Prints only the host, never the api-key query. ASCII only (PS 5.1).
param([string]$Instance = 'c0', [string]$WinDir = 'C:\cb33', [string]$EnvFile = 'C:\cb33\secrets\rpc.env')
$ErrorActionPreference = 'Stop'
$cfg = "C:\ProgramData\sentinel-dvpn\$Instance\config.toml"
if (-not (Test-Path $cfg)) { throw "no config at $cfg" }
if (-not (Test-Path $EnvFile)) { throw "no env file at $EnvFile" }
$rpc = ''; $wss = ''
foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
  if ($line -match '^HELIUS_RPC_URL=(.+)$') { $rpc = $Matches[1].Trim() }
  if ($line -match '^HELIUS_WSS_URL=(.+)$') { $wss = $Matches[1].Trim() }
}
if (-not $rpc -or -not $wss) { throw "env file missing HELIUS_RPC_URL / HELIUS_WSS_URL" }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$t = [IO.File]::ReadAllText($cfg)
# Scoped: only the public-devnet defaults are these exact literals (paymaster url is '').
$t = $t.Replace("url = 'https://api.devnet.solana.com'", "url = '$rpc'")
$t = $t.Replace("ws_url = 'wss://api.devnet.solana.com'", "ws_url = '$wss'")
[IO.File]::WriteAllText($cfg, $t, $utf8)
Remove-Item -LiteralPath $EnvFile -Force
# host only, no api-key query
$host1 = ([uri]$rpc).Host
Write-Output ("rpc set -> host=" + $host1 + " (key hidden); ws host=" + ([uri]$wss).Host)
& (Join-Path $WinDir 'sentinel-dvpnd.exe') service restart --instance $Instance 2>&1 | Out-String | ForEach-Object { "restart: " + $_.Trim() }
Start-Sleep -Seconds 3
Write-Output ("scm => " + (Get-Service -Name ('sentinel-dvpnd$' + $Instance) -ErrorAction SilentlyContinue).Status)
