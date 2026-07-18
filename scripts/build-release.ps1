# ============================================================================
# build-release.ps1 - package a self-contained veil release bundle (Windows).
#
# Produces dist\veil-v<ver>-windows-x86_64.zip containing the app (veil.exe -
# ONE binary: the desktop GUI is compiled in and runs in-process alongside its
# server), the memory engine (bin\neuron.exe), and a start.cmd. There is no
# separate veil-desk.exe in the bundle any more.
#
#   scripts\build-release.ps1
#
# Env: ZIG=<zig>  NEURON=<path to prebuilt neuron.exe>  VERSION=<override>
# ============================================================================
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Version = if ($env:VERSION) { $env:VERSION } else { '1.0.0' }
$Dist = Join-Path $Root 'dist'
$Os = 'windows'; $Arch = 'x86_64'

function Say($m) { Write-Host "> $m" -ForegroundColor Red }

# ---- 0. bootstrap the toolchain (unless opted out) ----
. (Join-Path $PSScriptRoot 'lib-deps.ps1')
if ($env:NO_BOOTSTRAP -ne '1') {
  $Zig = Ensure-Zig
  if (-not $env:NEURON -and -not (Test-Path (Join-Path $Root 'bin\neuron.exe'))) {
    Assert-CC | Out-Null
    Ensure-Cargo | Out-Null
  }
} else {
  $Zig = if ($env:ZIG) { $env:ZIG } else { 'zig' }
}

# ---- 1. build the app (ONE binary - the desktop GUI is compiled into veil.exe) ----
# No separate veil-desk build: `zig build` (-Dapp defaults to true) links raylib and the desk sources
# straight into veil.exe, and a bare `veil` runs the window in-process.
Say 'building the app (zig build - desktop GUI compiled in)'
Push-Location $Root
& $Zig build
Pop-Location
$Server = Join-Path $Root 'zig-out\bin\veil.exe'
if (-not (Test-Path $Server)) { throw "veil binary not found at $Server" }

# ---- 2. locate or build the neuron memory engine ----
$Neuron = $null
if ($env:NEURON -and (Test-Path $env:NEURON)) { $Neuron = $env:NEURON }
elseif (Test-Path (Join-Path $Root 'bin\neuron.exe')) { $Neuron = Join-Path $Root 'bin\neuron.exe' }
else {
  $core = Join-Path $Root '..\neuron-db\rust\neuron-core'
  if ((Test-Path $core) -and (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Say 'building the neuron memory engine (cargo --release)'
    Push-Location $core
    cargo build --release --features "sqlite secure server trust"
    Pop-Location
    $cand = Join-Path $core 'target\release\neuron.exe'
    if (Test-Path $cand) { $Neuron = $cand }
  }
}
if (-not $Neuron) { Say '! no neuron binary found - commit one to bin/ or build neuron-db before bundling' }

# ---- 3. assemble the bundle ----
$Name = "veil-v$Version-$Os-$Arch"
$Out  = Join-Path $Dist $Name
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'bin') | Out-Null
Copy-Item $Server (Join-Path $Out 'veil.exe')
if ($Neuron) { Copy-Item $Neuron (Join-Path $Out 'bin\neuron.exe') }

# A bare `veil.exe` IS the app now (window + server in one process) - no flag, no second binary to start.
@"
@echo off
cd /d "%~dp0"
veil.exe %*
"@ | Set-Content -Encoding ascii (Join-Path $Out 'start.cmd')

@"
the veil - v$Version ($Os/$Arch)

Run:  double-click start.cmd  (or veil.exe directly - same thing)
It opens the desktop dashboard and runs its server on http://127.0.0.1:8787,
both inside the one process.
Configure a model on first run (a local Ollama, or a hosted/BYOK endpoint).
Server-only:  veil.exe --server-only     (no window)

https://github.com/gary23w/nl-veil
"@ | Set-Content -Encoding ascii (Join-Path $Out 'README.txt')

# ---- 4. archive ----
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
$Zip = Join-Path $Dist "$Name.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path $Out -DestinationPath $Zip
Say "packaged dist\$Name.zip"
Say "done -> $Dist"
