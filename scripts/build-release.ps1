# ============================================================================
# build-release.ps1 - package a self-contained veil release bundle (Windows).
#
# Produces dist\veil-v<ver>-windows-x86_64.zip containing the server (veil.exe),
# the desktop (veil-desk.exe), the memory engine (bin\neuron.exe), and a
# start.cmd that runs the server AND the desktop together.
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

# ---- 1. build server + desktop ----
Say 'building the server + desktop (zig build -Ddesk=true)'
Push-Location $Root
& $Zig build -Ddesk=true
Pop-Location
$Server = Join-Path $Root 'zig-out\bin\veil.exe'
$Desk   = Join-Path $Root 'desk\zig-out\bin\veil-desk.exe'
if (-not (Test-Path $Server)) { throw "server binary not found at $Server" }
if (-not (Test-Path $Desk)) { Say '! veil-desk not built - bundling server only' }

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
if (-not $Neuron) { Say '! no neuron binary found - bundle will fetch/build it on first run (needs deploy.py)' }

# ---- 3. assemble the bundle ----
$Name = "veil-v$Version-$Os-$Arch"
$Out  = Join-Path $Dist $Name
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'bin') | Out-Null
Copy-Item $Server (Join-Path $Out 'veil.exe')
if (Test-Path $Desk) { Copy-Item $Desk (Join-Path $Out 'veil-desk.exe') }
if ($Neuron) { Copy-Item $Neuron (Join-Path $Out 'bin\neuron.exe') }

@"
@echo off
cd /d "%~dp0"
veil.exe --desk %*
"@ | Set-Content -Encoding ascii (Join-Path $Out 'start.cmd')

@"
the veil - v$Version ($Os/$Arch)

Run:  double-click start.cmd
It starts the server on http://127.0.0.1:8787 and opens the desktop dashboard.
Configure a model on first run (a local Ollama, or a hosted/BYOK endpoint).
Server-only:  veil.exe        (no desktop)

https://github.com/gary23w/nl-veil
"@ | Set-Content -Encoding ascii (Join-Path $Out 'README.txt')

# ---- 4. archive ----
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
$Zip = Join-Path $Dist "$Name.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path $Out -DestinationPath $Zip
Say "packaged dist\$Name.zip"
Say "done -> $Dist"
