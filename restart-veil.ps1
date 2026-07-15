# One-shot: stop the running veil server + desk, rebuild both from the committed tree,
# and relaunch per the known-good procedure (Start-Process from a user shell, cwd = repo root,
# server output to data/server-*.log). Run from anywhere: it cd's itself.
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$zig = "$env:USERPROFILE\zig-0.16.0\zig-x86_64-windows-0.16.0\zig.exe"
Set-Location $repo

Write-Host "stopping veil-desk + veil..."
Get-Process veil-desk, veil -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

Write-Host "building server (ReleaseFast)..."
& $zig build --release=fast --cache-dir C:\zig
if ($LASTEXITCODE -ne 0) { Write-Host "SERVER BUILD FAILED" -ForegroundColor Red; exit 1 }

Write-Host "building desk (ReleaseFast)..."
Push-Location "$repo\desk"
& $zig build --release=fast --cache-dir C:\zig
if ($LASTEXITCODE -ne 0) { Write-Host "DESK BUILD FAILED" -ForegroundColor Red; Pop-Location; exit 1 }
Pop-Location

Write-Host "starting server on :8787..."
Start-Process -FilePath "$repo\zig-out\bin\veil.exe" -WorkingDirectory $repo `
    -RedirectStandardOutput "$repo\data\server-stdout.log" -RedirectStandardError "$repo\data\server-stderr.log"
Start-Sleep -Seconds 4

Write-Host "starting desk..."
Start-Process -FilePath "$repo\desk\zig-out\bin\veil-desk.exe" -WorkingDirectory $repo
Start-Sleep -Seconds 3

try {
    $fleet = Invoke-RestMethod -Uri "http://127.0.0.1:8787/api/v1/fleet" -TimeoutSec 6
    Write-Host ("server up: v{0}, {1} swarms" -f $fleet.version, $fleet.swarms) -ForegroundColor Green
} catch { Write-Host "server did not answer /fleet yet — check data/server-stderr.log" -ForegroundColor Yellow }
Get-Process veil, veil-desk -ErrorAction SilentlyContinue | Format-Table Name, Id -AutoSize
Write-Host "done. The Scheduled tab is the 6th top tab; steer fixes are live server-side."
