# bump-version.ps1 -- stamp a new version across every hand-stamped location, all or none
# (ledger H5: the stamps drifted apart before because each was edited by hand).
#
# Locations:
#   build.zig.zon                 .version = "X"
#   src\main.zig                  const VERSION = "X"   (served at /api/v1/health + startup banner)
#   bin\MANIFEST.txt              every literal occurrence of the old version
#   .github\workflows\release.yml body_path: docs/release/RELEASE-vX.md
#   docs\release\RELEASE-vX.md    stub created if missing (fill it before tagging)
#
#   .\scripts\bump-version.ps1 1.1.0            apply
#   .\scripts\bump-version.ps1 1.1.0 -DryRun    show what would change, write nothing
#
# The release.yml body_path deliberately lags: it points at the LAST PUBLISHED release's notes
# until you bump for the next one (so a same-version re-apply is byte-neutral everywhere EXCEPT
# that pointer, which it advances to the new stub -- that is the intended bump behavior).
#
# NOTE: keep this file pure ASCII (PS 5.1 reads BOM-less scripts as ANSI).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$DryRun
)

if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') {
    Write-Host "not a version: '$Version' (want e.g. 1.1.0 or 1.1.0-alpha.1)" -ForegroundColor Red
    exit 1
}
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$utf8 = New-Object System.Text.UTF8Encoding($false)

$zon = Join-Path $repo "build.zig.zon"
$old = ([regex]::Match([IO.File]::ReadAllText($zon), '\.version\s*=\s*"([^"]+)"')).Groups[1].Value
if (-not $old) { Write-Host "could not read current version from build.zig.zon" -ForegroundColor Red; exit 1 }
Write-Host "bump: $old -> $Version" -ForegroundColor Cyan

$edits = @(
    @{ file = $zon;                                          find = '(\.version\s*=\s*")[^"]+(")';        repl = "`${1}$Version`${2}" },
    @{ file = (Join-Path $repo "src\main.zig");              find = '(const VERSION\s*=\s*")[^"]+(")';    repl = "`${1}$Version`${2}" },
    @{ file = (Join-Path $repo "bin\MANIFEST.txt");          find = [regex]::Escape($old);                repl = $Version },
    @{ file = (Join-Path $repo ".github\workflows\release.yml"); find = 'RELEASE-v[^\s]+\.md';            repl = "RELEASE-v$Version.md" }
)

$failed = $false
foreach ($e in $edits) {
    if (-not (Test-Path $e.file)) { Write-Host ("MISSING {0}" -f $e.file) -ForegroundColor Red; $failed = $true; continue }
    $raw = [IO.File]::ReadAllText($e.file)
    $hits = ([regex]::Matches($raw, $e.find)).Count
    $rel = $e.file.Substring($repo.Length + 1)
    if ($hits -eq 0) { Write-Host ("  {0}: NO MATCH -- the stamp moved; fix this script" -f $rel) -ForegroundColor Red; $failed = $true; continue }
    Write-Host ("  {0}: {1} stamp(s)" -f $rel, $hits)
    if (-not $DryRun) {
        [IO.File]::WriteAllText($e.file, [regex]::Replace($raw, $e.find, $e.repl), $utf8)
    }
}

$notes = Join-Path $repo "docs\release\RELEASE-v$Version.md"
if (-not (Test-Path $notes)) {
    Write-Host ("  docs\release\RELEASE-v$Version.md: will create stub (fill it before tagging)")
    if (-not $DryRun) {
        [IO.File]::WriteAllText($notes, "# the veil v$Version`n`n(release notes -- written before the tag; release.yml attaches this file)`n", $utf8)
    }
} else {
    Write-Host ("  docs\release\RELEASE-v$Version.md: exists")
}

if ($failed) { Write-Host "INCOMPLETE -- nothing to trust; review before committing" -ForegroundColor Red; exit 1 }
if ($DryRun) { Write-Host "dry run: nothing written" -ForegroundColor Yellow; exit 0 }
Write-Host "stamped. Verify: scripts\check.ps1 -Scan   Commit the five files together." -ForegroundColor Green
