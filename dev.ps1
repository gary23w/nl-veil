# One-shot dev loop: stop the running veil, rebuild from the committed tree, relaunch.
#
# The app is now ONE binary — the desktop GUI is compiled into veil.exe (-Dapp, default on) and runs
# in-process, so there is no separate desk to build, launch, or stop. Closing the window shuts the
# server down with it.
#
# Run from anywhere: it cd's itself.
#
#   .\dev.ps1              rebuild + launch the app (server + desktop window)
#   .\dev.ps1 -ServerOnly  rebuild + launch the server alone (web UI at :8787, no window)
#   .\dev.ps1 -NoGui       build with -Dapp=false (no raylib link at all — fastest loop,
#                                   ~5MB exe; use this when you are working on the server or web UI)
param(
    [switch]$ServerOnly,
    [switch]$NoGui
)

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$zig = "$env:USERPROFILE\zig-0.16.0\zig-x86_64-windows-0.16.0\zig.exe"
Set-Location $repo

# Stop the app, but SPARE the `veil local-host` browser daemon when it runs from its TEMP copy — killing
# it on every restart is what forced a cold browser launch on the first tool call of every session. A
# daemon still running from the repo's zig-out exe must die anyway: it holds the exe open, and the
# rebuild below could not replace it (the install step fails with AccessDenied).
Write-Host "stopping veil (sparing the TEMP-hosted local-host browser daemon)..."
Get-Process veil-desk -ErrorAction SilentlyContinue | Stop-Process -Force   # legacy two-binary builds
Get-CimInstance Win32_Process -Filter "Name='veil.exe'" -ErrorAction SilentlyContinue | Where-Object {
    -not ($_.CommandLine -match 'local-host' -and $_.ExecutablePath -notlike "$repo*")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# Dedicated cache. The repo lives under OneDrive and a repo-local .zig-cache goes stale against it —
# builds "succeed" while installing yesterday's exe. If a build ever looks ignored again: delete this
# directory and rebuild.
$cache = "C:\zig-nlveil"

# The web UI (index.html / app.js / styles.css / models.json) is @embedFile'd into the binary by
# build.zig, so editing web/public/ does NOTHING until a rebuild. That is what this step is for.
$args = @("build", "--release=fast", "--cache-dir", $cache)
if ($NoGui) {
    $args += "-Dapp=false"
    Write-Host "building (ReleaseFast, NO GUI - server + web UI only)..."
} else {
    Write-Host "building (ReleaseFast, GUI linked in)..."
}
& $zig @args
if ($LASTEXITCODE -ne 0) { Write-Host "BUILD FAILED" -ForegroundColor Red; exit 1 }

$exe = "$repo\zig-out\bin\veil.exe"
if ($ServerOnly -or $NoGui) {
    # --server-only: boot the server without opening a window. Required for -NoGui (there is no GUI
    # compiled in), and useful on its own when you only want the web UI.
    Write-Host "starting server on :8787 (no window)..."
    Start-Process -FilePath $exe -ArgumentList "--server-only" -WorkingDirectory $repo `
        -RedirectStandardOutput "$repo\data\server-stdout.log" -RedirectStandardError "$repo\data\server-stderr.log"
} else {
    # A bare `veil` IS the one-click default: it starts the server and opens the desktop window in the
    # same process. No second Start-Process, and no --desk flag (that flag is retired).
    Write-Host "starting the app (server + desktop window)..."
    Start-Process -FilePath $exe -WorkingDirectory $repo
}
Start-Sleep -Seconds 4

try {
    $fleet = Invoke-RestMethod -Uri "http://127.0.0.1:8787/api/v1/fleet" -TimeoutSec 6
    Write-Host ("server up: v{0}, {1} swarms" -f $fleet.version, $fleet.swarms) -ForegroundColor Green
} catch {
    Write-Host "server did not answer /fleet yet - check data\server-stderr.log" -ForegroundColor Yellow
}
Get-Process veil -ErrorAction SilentlyContinue | Format-Table Name, Id -AutoSize
Write-Host "web UI: http://127.0.0.1:8787   (hard-reload the browser - /app.js caches aggressively)"
