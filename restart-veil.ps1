# One-shot: stop the running veil server + desk, rebuild both from the committed tree,
# and relaunch per the known-good procedure (Start-Process from a user shell, cwd = repo root,
# server output to data/server-*.log). Run from anywhere: it cd's itself.
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$zig = "$env:USERPROFILE\zig-0.16.0\zig-x86_64-windows-0.16.0\zig.exe"
Set-Location $repo

# Stop the desk + server, but SPARE the `veil local-host` browser daemon when it runs from its TEMP copy —
# killing it on every restart is what forced a cold browser launch on the first tool call of every session.
# A daemon still running from the repo's zig-out exe (a pre-TEMP-copy build) must die anyway: it holds the
# exe open and the rebuild below could not replace it.
Write-Host "stopping veil-desk + veil (sparing the TEMP-hosted local-host browser daemon)..."
Get-Process veil-desk -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='veil.exe'" -ErrorAction SilentlyContinue | Where-Object {
    -not ($_.CommandLine -match 'local-host' -and $_.ExecutablePath -notlike "$repo*")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# Dedicated cache (C:\zig went stale against the OneDrive tree once - builds "succeeded" but installed
# yesterday's exe). If a build ever looks ignored again: delete this dir and rebuild.
$cache = "C:\zig-nlveil"

Write-Host "building server (ReleaseFast)..."
& $zig build --release=fast --cache-dir $cache
if ($LASTEXITCODE -ne 0) { Write-Host "SERVER BUILD FAILED" -ForegroundColor Red; exit 1 }

Write-Host "building desk (ReleaseFast)..."
Push-Location "$repo\desk"
& $zig build --release=fast --cache-dir $cache
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
} catch { Write-Host "server did not answer /fleet yet - check data/server-stderr.log" -ForegroundColor Yellow }
Get-Process veil, veil-desk -ErrorAction SilentlyContinue | Format-Table Name, Id -AutoSize
Write-Host "done. Tasks is the 6th top tab (edit + per-task model + recent runs live there)."
