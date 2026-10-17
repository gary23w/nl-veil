# Build an unsigned MSIX for Microsoft Store upload, or an explicitly marked development package.
# Build veil first; this script never includes local databases, credentials, caches or model weights.
# Windows PowerShell 5.1 and PowerShell 7 are supported.
[CmdletBinding()]
param(
    [string]$IdentityPath,
    [string]$AppPath,
    [string]$NeuronPath,
    [string]$OutputDirectory,
    [string]$MakeAppxPath,
    [switch]$Development,
    [switch]$StageOnly
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $IdentityPath) { $IdentityPath = Join-Path $RepoRoot 'packaging\windows\store-identity.json' }
if (-not $AppPath) { $AppPath = Join-Path $RepoRoot 'dist\windows-store\build\bin\veil.exe' }
if (-not $NeuronPath) { $NeuronPath = Join-Path $RepoRoot 'bin\neuron.exe' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $RepoRoot 'dist\windows-store\packages' }

function Read-AppProbe([string]$Executable, [string]$Argument) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Argument
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'could not start app probe' }
        if (-not $process.WaitForExit(20000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "app probe timed out: $Argument"
        }
        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        $stderr = $process.StandardError.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0) { throw "app probe failed: $stderr" }
        return $stdout
    } finally { $process.Dispose() }
}

function Assert-X64Pe([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "not a Windows executable: $Path" }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset + 6 -gt $stream.Length) { throw "invalid PE header: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "Store package currently requires x64 executables: $Path"
        }
    } finally { $reader.Dispose() }
}

function Write-Utf8([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

$AppPath = (Resolve-Path -LiteralPath $AppPath).Path
$NeuronPath = (Resolve-Path -LiteralPath $NeuronPath).Path
Assert-X64Pe $AppPath
Assert-X64Pe $NeuronPath
if ((Read-AppProbe $AppPath '--package-support') -ne 'veil-msix-v1') {
    throw 'This executable lacks MSIX data paths and Store-managed updates. Rebuild the desktop app from current source.'
}
$version = Read-AppProbe $AppPath '--build-version'
if ($version -notmatch '^([1-9][0-9]*)\.([0-9]+)\.([0-9]+)$') {
    throw "Store packaging requires a stable three-part app version: $version"
}
foreach ($part in $version.Split('.')) {
    if ([long]$part -gt 65535) { throw 'MSIX version fields must be at most 65535' }
}
$packageVersion = "$version.0"
if ($Development) {
    $identity = [pscustomobject]@{
        identityName = 'VeilDevelopment'
        publisher = 'CN=VeilDevelopment'
        publisherDisplayName = 'Local development'
        displayName = 'the Veil (development)'
    }
} else {
    if (-not (Test-Path -LiteralPath $IdentityPath -PathType Leaf)) {
        throw 'Reserve an MSIX app in Partner Center, then copy store-identity.example.json to store-identity.json and enter the exact identity values. Use -Development only for a local test package.'
    }
    $identity = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json
    foreach ($field in @('identityName', 'publisher', 'publisherDisplayName', 'displayName')) {
        if (-not $identity.$field -or $identity.$field -match 'COPY |FROM PARTNER CENTER') { throw "Missing real Store identity field: $field" }
    }
    if ($identity.identityName -eq 'VeilDevelopment' -or $identity.publisher -eq 'CN=VeilDevelopment') {
        throw 'Development identity cannot be used for a Store upload.'
    }
}
if ($identity.identityName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$') { throw 'Invalid Package.Identity.Name' }
if ($identity.publisher -notmatch '^CN=') { throw 'Use the complete Partner Center publisher value, beginning CN=' }
if ($identity.displayName.Length -gt 256 -or $identity.publisherDisplayName.Length -gt 256) { throw 'Display names are too long' }

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$suffix = if ($Development) { '-development' } else { '' }
$filename = "nl-veil-$packageVersion-x64$suffix.msix"
$packagePath = Join-Path $OutputDirectory $filename
if (-not $StageOnly -and (Test-Path -LiteralPath $packagePath)) {
    throw "Package already exists; choose another OutputDirectory or build a newer version: $packagePath"
}
$stage = Join-Path $OutputDirectory ('stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($subdir in @('bin', 'Assets', 'licenses')) {
    New-Item -ItemType Directory -Path (Join-Path $stage $subdir) | Out-Null
}
Copy-Item -LiteralPath $AppPath -Destination (Join-Path $stage 'veil.exe')
Copy-Item -LiteralPath $NeuronPath -Destination (Join-Path $stage 'bin\neuron.exe')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'desk\assets\fonts\OFL.txt') -Destination (Join-Path $stage 'licenses\OpenDyslexic-OFL.txt')
# No veil-install.txt: this distribution is updated exclusively through the Store.
# Generate required resolutions from the actual app artwork, preserving its alpha channel.
Add-Type -AssemblyName System.Drawing
$art = [Drawing.Image]::FromFile((Join-Path $RepoRoot 'desk\assets\icon48x48.png'))
try {
    foreach ($asset in @(
        @{ name = 'Square44x44Logo.png'; size = 44 },
        @{ name = 'Square150x150Logo.png'; size = 150 },
        @{ name = 'StoreLogo.png'; size = 50 },
        @{ name = 'ListingIcon.png'; size = 300 }
    )) {
        $bitmap = New-Object Drawing.Bitmap($asset.size, $asset.size)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
            $edge = [Math]::Min($asset.size / $art.Width, $asset.size / $art.Height)
            $width = [int][Math]::Round($art.Width * $edge)
            $height = [int][Math]::Round($art.Height * $edge)
            $graphics.DrawImage($art, [int](($asset.size - $width) / 2), [int](($asset.size - $height) / 2), $width, $height)
            $bitmap.Save((Join-Path $stage ('Assets\' + $asset.name)), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $art.Dispose() }

$manifest = Get-Content -LiteralPath (Join-Path $RepoRoot 'packaging\windows\AppxManifest.xml.in') -Raw
foreach ($entry in @{
    '@IDENTITY_NAME@' = $identity.identityName
    '@PUBLISHER@' = $identity.publisher
    '@DISPLAY_NAME@' = $identity.displayName
    '@PUBLISHER_DISPLAY_NAME@' = $identity.publisherDisplayName
    '@VERSION@' = $packageVersion
}.GetEnumerator()) {
    $manifest = $manifest.Replace($entry.Key, [Security.SecurityElement]::Escape([string]$entry.Value))
}
Write-Utf8 (Join-Path $stage 'AppxManifest.xml') $manifest

if (-not $StageOnly) {
    if (-not $MakeAppxPath) {
        $command = Get-Command makeappx.exe -ErrorAction SilentlyContinue
        if ($command) { $MakeAppxPath = $command.Source }
        else {
            # Only inspect the SDK version directory and two explicit tool paths per version.
            $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
            if (Test-Path -LiteralPath $sdkRoot) {
                foreach ($sdk in (Get-ChildItem -LiteralPath $sdkRoot -Directory | Sort-Object Name -Descending)) {
                    foreach ($arch in @('x64', 'x86')) {
                        $candidate = Join-Path $sdk.FullName "$arch\makeappx.exe"
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $MakeAppxPath = $candidate; break }
                    }
                    if ($MakeAppxPath) { break }
                }
            }
        }
    }
    if (-not $MakeAppxPath) { throw "MakeAppx not found. Install the Windows SDK, or pass -MakeAppxPath. Staged files: $stage" }
    & $MakeAppxPath pack /d $stage /p $packagePath /h SHA256
    if ($LASTEXITCODE -ne 0) { throw "MakeAppx validation/packaging failed (exit $LASTEXITCODE)" }
}
$report = [ordered]@{
    development = [bool]$Development
    version = $packageVersion
    identityName = $identity.identityName
    publisher = $identity.publisher
    stagedDirectory = $stage
    packagePath = if ($StageOnly) { $null } else { $packagePath }
    appSha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'veil.exe') -Algorithm SHA256).Hash
    neuronSha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'bin\neuron.exe') -Algorithm SHA256).Hash
    packageSha256 = if ($StageOnly) { $null } else { (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash }
}
$reportPath = if ($StageOnly) { Join-Path $stage 'staging-report.json' } else { Join-Path $OutputDirectory ($filename + '.json') }
Write-Utf8 $reportPath ($report | ConvertTo-Json)
Write-Host "Staged app: $stage"
if (-not $StageOnly) { Write-Host "Unsigned package: $packagePath" }
Write-Host "Build report: $reportPath"
if ($Development) { Write-Warning 'DEVELOPMENT IDENTITY ONLY. Do not upload this package to Partner Center.' }
