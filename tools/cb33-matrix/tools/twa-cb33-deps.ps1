# twa-cb33-deps.ps1 - install the WireGuard/AmneziaWG dep MSIs with the Level-2 feature selected (FWA #31 b090c28),
# add the helper dirs to the machine PATH, restart the daemon, and print FWA's proof lines. ASCII only (PS 5.1).
param([string]$Instance = 'c0', [string]$Deps = 'C:\cb33\deps')
$ErrorActionPreference = 'Stop'
$svc = 'sentinel-dvpnd$' + $Instance

# 1) wg + awg gate every file behind feature WireGuardFeature at Level 2; ADDLOCAL selects it. (OpenVPN already in.)
foreach ($pat in @('wireguard-*.msi', 'amneziawg-*.msi')) {
  $f = Get-ChildItem $Deps -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $f) { Write-Output ("MISSING " + $pat); continue }
  $p = Start-Process msiexec.exe -ArgumentList '/i', $f.FullName, '/qn', '/norestart', 'ADDLOCAL=WireGuardFeature' -Wait -PassThru
  Write-Output ("install " + $f.Name + " exit=" + $p.ExitCode)
}
# OpenVPN is not Level-2 gated (plain /qn installed openvpn.exe fine on x64); install it for the openvpn protocol.
$ov = Get-ChildItem $Deps -Filter 'OpenVPN-*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ov) {
  $p = Start-Process msiexec.exe -ArgumentList '/i', $ov.FullName, '/qn', '/norestart' -Wait -PassThru
  Write-Output ("install " + $ov.Name + " exit=" + $p.ExitCode)
}

# 2) add the helper dirs to the machine PATH (dvpnd calls the helper by bare name via LookPath)
$cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
foreach ($d in @('C:\Program Files\WireGuard', 'C:\Program Files\AmneziaWG', 'C:\Program Files\OpenVPN\bin')) {
  if (($cur -split ';') -notcontains $d) { $cur = $cur.TrimEnd(';') + ';' + $d }
}
[Environment]::SetEnvironmentVariable('Path', $cur, 'Machine')

# 3) restart the service so it inherits the new PATH
Restart-Service $svc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# 4) VERIFY (FWA's proof: present / signed / admin-owned)
function proveExe($dir, $label) {
  $exe = Get-ChildItem $dir -Recurse -Include *.exe -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match 'wireguard|amneziawg|awg' } | Select-Object -First 1
  if (-not $exe) { Write-Output ($label + " present: False"); return }
  $s = Get-AuthenticodeSignature $exe.FullName
  $own = (Get-Acl $dir).Owner
  Write-Output ($label + " present: True (" + $exe.FullName + ")")
  Write-Output ($label + " sig: " + $s.Status + " signer=" + ($s.SignerCertificate.Subject -replace ',.*',''))
  Write-Output ($label + " owner: " + $own)
}
proveExe 'C:\Program Files\WireGuard' 'wg'
proveExe 'C:\Program Files\AmneziaWG' 'awg'
Write-Output ("scm: " + (Get-Service $svc -ErrorAction SilentlyContinue).Status)
