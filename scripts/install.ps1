# nl-veil one-command installer — Windows PowerShell
#   iwr -useb https://raw.githubusercontent.com/gary23w/nl-veil/main/install.ps1 | iex
#
# What it does (and nothing more): put the repo at $env:VEIL_HOME (default ~\nl-veil), add it to
# your user PATH so `veil` works in any new terminal, and tell you the next two commands. Zig 0.16+
# is the one thing it won't install for you; on first run the `veil` shim builds the binary with
# `zig build`, and the neuron-db memory engine ships prebuilt in bin\. No Python required.
$ErrorActionPreference = "Stop"

$repo = "https://github.com/gary23w/nl-veil"
$dir = if ($env:VEIL_HOME) { $env:VEIL_HOME } else { Join-Path $HOME "nl-veil" }

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Host "! nl-veil builds from source and needs Zig 0.16+ first: https://ziglang.org/download/"
    exit 1
}

if (Test-Path (Join-Path $dir ".git")) {
    Write-Host "- updating the existing install at $dir"
    git -C $dir pull --ff-only
}
elseif (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "- cloning nl-veil into $dir"
    git clone --depth 1 $repo $dir
}
else {
    Write-Host "- git not found; downloading a zip into $dir"
    $zip = Join-Path $env:TEMP "nl-veil-main.zip"
    Invoke-WebRequest -UseBasicParsing "$repo/archive/refs/heads/main.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath $env:TEMP -Force
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item (Join-Path $env:TEMP "nl-veil-main\*") $dir -Recurse -Force
    Remove-Item $zip -Force
}

# `veil.cmd` lives at the repo root — putting the repo on the user PATH makes `veil` a command
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$dir", "User")
    Write-Host "  added $dir to your user PATH (open a NEW terminal to pick it up)"
}

Write-Host ""
Write-Host "  installed -> $dir"
Write-Host ""
Write-Host "  next (in a new terminal):"
Write-Host "    veil                # run the server (first run builds the binary)"
Write-Host "    veil cast `"...`"      # deploy a swarm    |    veil chat    # talk to the veil"
