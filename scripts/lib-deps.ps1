# ============================================================================
# lib-deps.ps1 - Windows dependency bootstrap, shared by build-release.ps1.
#
#   $zig = Ensure-Zig            downloads the pinned zig into .\.zig if absent
#   Ensure-Cargo                 installs rustup (minimal) if cargo is absent
#   Assert-CC                    warns (does not install) if no C compiler
#
# Windows raylib links against system libs already present, so the desktop
# needs only zig. neuron (Rust) needs cargo + a C toolchain for its sqlite build.
# Honor $env:ASSUME_YES / $env:NO_BOOTSTRAP.
# ============================================================================

$script:DepZigVersion = if ($env:DEP_ZIG_VERSION) { $env:DEP_ZIG_VERSION } else { '0.16.0' }
$script:DepRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function _DepSay($m) { Write-Host "> $m" -ForegroundColor Red }
function _DepHave($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function _DepYes($q) {
  if ($env:ASSUME_YES -eq '1') { return $true }
  if ([Environment]::UserInteractive -eq $false) { return $true }
  $a = Read-Host "$q [Y/n]"
  return ($a -notmatch '^[nN]')
}

function Ensure-Zig {
  if ($env:ZIG -and (Test-Path $env:ZIG)) { return $env:ZIG }
  if (_DepHave zig) { return (Get-Command zig).Source }
  $local = Join-Path $script:DepRoot '.zig\zig.exe'
  if (Test-Path $local) { return $local }
  if (-not (_DepYes "download Zig $($script:DepZigVersion) into .\.zig now (~50 MB)?")) {
    throw "Zig not found. Install from https://ziglang.org/download/ or set `$env:ZIG."
  }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'aarch64' } else { 'x86_64' }
  $base = "zig-$arch-windows-$($script:DepZigVersion)"
  $url  = "https://ziglang.org/download/$($script:DepZigVersion)/$base.zip"
  $tmp  = Join-Path $script:DepRoot '.zig-dl'
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  _DepSay "fetching Zig $($script:DepZigVersion)"
  $zip = Join-Path $tmp 'zig.zip'
  Invoke-WebRequest -Uri $url -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $dest = Join-Path $script:DepRoot '.zig'
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Move-Item (Join-Path $tmp $base) $dest
  Remove-Item -Recurse -Force $tmp
  if (Test-Path $local) { return $local }
  throw "zig download failed - install from https://ziglang.org/download/"
}

function Ensure-Cargo {
  if (_DepHave cargo) { return $true }
  $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
  if (Test-Path (Join-Path $cargoBin 'cargo.exe')) { $env:PATH = "$cargoBin;$env:PATH"; if (_DepHave cargo) { return $true } }
  if (-not (_DepYes "the neuron memory engine needs Rust - install it now via rustup?")) {
    _DepSay "install from https://rustup.rs and re-run (or set `$env:NEURON to a prebuilt neuron.exe)"; return $false
  }
  $init = Join-Path $env:TEMP 'rustup-init.exe'
  Invoke-WebRequest -Uri 'https://win.rustup.rs/x86_64' -OutFile $init
  & $init -y --profile minimal --default-toolchain stable
  $env:PATH = "$cargoBin;$env:PATH"
  if (_DepHave cargo) { return $true }
  _DepSay "cargo still not on PATH - open a new shell and re-run"; return $false
}

function Assert-CC {
  if ((_DepHave cl) -or (_DepHave gcc) -or (_DepHave clang)) { return $true }
  _DepSay "no C compiler found - cargo's sqlite build needs one:"
  _DepSay "  install the MSVC 'Desktop development with C++' workload (Visual Studio Build Tools),"
  _DepSay "  or a mingw-w64 gcc, then re-run."
  return $false
}
