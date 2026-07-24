# check.ps1 -- the acceptance oracle for nl-veil ITSELF (local mirror of the CI `check` job).
#
# A worker's definition of done: this script exits 0. It never touches the running app and never
# installs over zig-out\ (a live veil.exe can hold that path open) -- artifacts go to a throwaway
# prefix under the off-OneDrive cache. dev.ps1 is the only script that stops/starts the app.
#
# NOTE: keep this file pure ASCII. PowerShell 5.1 reads BOM-less scripts as ANSI and non-ASCII
# characters corrupt the parse.
#
#   .\scripts\check.ps1            run the gates: catalog sync, server build, src tests, desk tests
#   .\scripts\check.ps1 -Full      also build the default target (GUI merged in -- slow, raylib)
#   .\scripts\check.ps1 -Scan      no builds: print growth signals (drift, coverage gaps, TODOs)
param(
    [switch]$Scan,
    [switch]$Full,
    [int]$TimeoutSec = 600
)

$repo  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$zig   = "$env:USERPROFILE\zig-0.16.0\zig-x86_64-windows-0.16.0\zig.exe"
# Dedicated cache OUTSIDE OneDrive -- a repo-local .zig-cache goes stale against OneDrive and
# "successful" builds install yesterday's exe. Same cache dev.ps1 uses.
$cache  = "C:\zig-nlveil"
$prefix = Join-Path $cache "check-out"
$logs   = Join-Path $cache "check-logs"
New-Item -ItemType Directory -Force $logs | Out-Null
Set-Location $repo

# ---------------------------------------------------------------- gate runner
$script:results = @()
function Invoke-Gate([string]$name, [string]$exe, [string[]]$argv, [string]$workdir, [int]$timeout, [string]$onTimeout) {
    Write-Host ">> $name" -ForegroundColor Cyan
    $slug = (($name -replace '[^a-zA-Z0-9]+', '-') -replace '(^-+|-+$)', '').ToLower()
    $out  = Join-Path $logs "$slug.log"
    $err  = Join-Path $logs "$slug.err.log"
    $sp = @{ FilePath = $exe; WorkingDirectory = $workdir; NoNewWindow = $true; PassThru = $true;
             RedirectStandardOutput = $out; RedirectStandardError = $err }
    if ($argv -and $argv.Count -gt 0) { $sp.ArgumentList = $argv }
    $p = Start-Process @sp
    # PS 5.1: without touching .Handle before exit, .ExitCode never populates and every gate
    # misreports as FAIL (null -ne 0).
    $null = $p.Handle
    if (-not $p.WaitForExit($timeout * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $script:results += [pscustomobject]@{ gate = $name; status = "TIMEOUT ${timeout}s"; log = $out }
        Write-Host "   TIMEOUT after ${timeout}s   (log: $out)" -ForegroundColor Yellow
        if ($onTimeout) { Write-Host "   $onTimeout" -ForegroundColor Yellow }
        return $false
    }
    if ($p.ExitCode -ne 0) {
        $script:results += [pscustomobject]@{ gate = $name; status = "FAIL ($($p.ExitCode))"; log = $err }
        Write-Host "   FAIL exit=$($p.ExitCode)" -ForegroundColor Red
        # Print via Write-Host, NOT the pipeline: pipeline output becomes the function's return
        # value, which turns a failed gate truthy and makes the verdict lie ALL GREEN.
        Get-Content $err -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "   | $_" }
        return $false
    }
    $script:results += [pscustomobject]@{ gate = $name; status = "PASS"; log = $out }
    Write-Host "   PASS" -ForegroundColor Green
    return $true
}

# `zig build test` with a self-healing fallback. On this machine Defender can kill the build
# runner's test IPC: the failure names no test, just `failed command: "...test.exe" ... --listen=-`,
# while the same binary passes standalone. When that signature appears, rerun the exact exe the
# runner named (fallback: newest test.exe in the cache) and take ITS verdict.
function Invoke-ZigTests([string]$label, [string]$workdir, [int]$timeout, [string]$note) {
    if (Invoke-Gate "zig build test ($label)" $zig @("build", "test", "--cache-dir", $cache) $workdir $timeout $note) { return $true }
    # Only the exact IPC signature qualifies: the runner's failure names the compiled test.exe.
    # A compile error names zig.exe instead -- no fallback there, that red is real (and running the
    # NEWEST cached test.exe would silently test yesterday's tree).
    $lastLog = $script:results[-1].log
    $texe = $null
    $m = Select-String -Path $lastLog -Pattern 'failed command: "([^"]+test\.exe)"' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $texe = $m.Matches[0].Groups[1].Value -replace '\\\\', '\' }
    if (-not ($texe -and (Test-Path $texe))) { return $false }
    Write-Host "   build-runner failed without naming a test (IPC flake?) -- retrying standalone:" -ForegroundColor Yellow
    Write-Host "   $texe" -ForegroundColor Yellow
    return Invoke-Gate "standalone test exe ($label)" $texe @() $workdir $timeout $note
}

# ---------------------------------------------------------------- scan: growth signals, no builds
if ($Scan) {
    Write-Host "== growth signals ==" -ForegroundColor Cyan
    $signals = 0

    # 0) in-flight work: dirty tracked files touched in the last 20 min are probably someone ELSE's
    #    mid-feature edits (the owner or a resident swarm shares this tree). Their reds are not
    #    yours -- report, don't fix (see CLAUDE.md hard rules).
    $hot = @()
    foreach ($d in @(git -C $repo diff --name-only HEAD 2>$null)) {
        $p = Join-Path $repo ($d -replace '/', '\')
        if ((Test-Path $p) -and (((Get-Date) - (Get-Item $p).LastWriteTime).TotalMinutes -lt 20)) { $hot += $d }
    }
    if ($hot.Count -gt 0) {
        Write-Host ("[in-flight] {0} tracked file(s) modified in the last 20 min -- likely mid-feature work; their reds are not yours:" -f $hot.Count) -ForegroundColor Yellow
        $hot | ForEach-Object { Write-Host "    $_" }
    }

    # 1) test reachability: `zig build test` only collects test blocks from files REACHABLE from the
    #    test root (tests.zig) through @import chains, plus named modules that get their own test
    #    artifact in build.zig. A test-bearing file outside that graph is a suite that never runs.
    foreach ($pkg in @(
        @{ root = (Join-Path $repo "src");      tests = (Join-Path $repo "src\tests.zig");      build = (Join-Path $repo "build.zig");      label = "src" },
        @{ root = (Join-Path $repo "desk\src"); tests = (Join-Path $repo "desk\src\tests.zig"); build = (Join-Path $repo "desk\build.zig"); label = "desk" }
    )) {
        if (-not (Test-Path $pkg.tests)) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($pkg.tests)
        # Named modules (bare imports in tests.zig, e.g. "modelcfg") are rooted elsewhere by
        # build.zig and get their own test artifact -- seed the walk with their root files.
        if (Test-Path $pkg.build) {
            $rawBuild = Get-Content $pkg.build -Raw
            Select-String -Path $pkg.tests -Pattern '@import\("([^"]+)"\)' -AllMatches | ForEach-Object {
                foreach ($m in $_.Matches) {
                    $imp = $m.Groups[1].Value
                    if ($imp -like "*.zig") { continue }
                    $mm = [regex]::Match($rawBuild, "const\s+$imp\s*=\s*b\.createModule\(\.\{\s*\.root_source_file\s*=\s*b\.path\(""([^""]+)""\)", 'Singleline')
                    if ($mm.Success) {
                        $queue.Enqueue([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pkg.build) ($mm.Groups[1].Value -replace '/', '\'))))
                    }
                }
            }
        }
        $reach = @{}
        while ($queue.Count -gt 0) {
            $f = [IO.Path]::GetFullPath($queue.Dequeue())
            if ($reach.ContainsKey($f.ToLower())) { continue }
            $reach[$f.ToLower()] = $true
            if (-not (Test-Path $f)) { continue }
            Select-String -Path $f -Pattern '@import\("([^"]+\.zig)"\)' -AllMatches | ForEach-Object {
                foreach ($m in $_.Matches) {
                    $t = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $f) ($m.Groups[1].Value -replace '/', '\')))
                    if ($t.ToLower().StartsWith($pkg.root.ToLower())) { $queue.Enqueue($t) }
                }
            }
        }
        $orphans = @(); $untested = 0
        Get-ChildItem $pkg.root -Recurse -Filter *.zig | ForEach-Object {
            $rel = $_.FullName.Substring($pkg.root.Length + 1)
            if ($rel -eq "tests.zig") { return }
            $hasTests = Select-String -Path $_.FullName -Pattern '^\s*test[\s"{]' -Quiet
            if ($hasTests) {
                if (-not $reach.ContainsKey($_.FullName.ToLower())) { $orphans += $rel }
            } else { $untested++ }
        }
        if ($orphans.Count -gt 0) {
            $signals += $orphans.Count
            Write-Host ("[{0}] {1} file(s) HAVE test blocks but are UNREACHABLE from tests.zig (they never run):" -f $pkg.label, $orphans.Count) -ForegroundColor Yellow
            $orphans | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host ("[{0}] test reachability: clean (every test-bearing file is in the test graph)" -f $pkg.label) -ForegroundColor Green
        }
        Write-Host ("[{0}] {1} module(s) carry no test blocks at all (coverage frontier)" -f $pkg.label, $untested)
    }

    # 2) twin drift: httpc.zig is intentionally duplicated across packages. The contract (stated in
    #    each file's header) is byte-for-byte identity BELOW the //! header block -- the header prose
    #    legitimately differs per package, so compare bodies only.
    $a = Join-Path $repo "src\worker\httpc.zig"; $b = Join-Path $repo "desk\src\httpc.zig"
    if ((Test-Path $a) -and (Test-Path $b)) {
        $bodyA = ((Get-Content $a) -notmatch '^//!') -join "`n"
        $bodyB = ((Get-Content $b) -notmatch '^//!') -join "`n"
        if ($bodyA -ne $bodyB) {
            $signals++
            Write-Host "[twins] httpc.zig twin BODIES differ (below-header contract broken) -- mirror them" -ForegroundColor Yellow
        } else {
            Write-Host "[twins] httpc.zig twins in sync (below-header contract holds)" -ForegroundColor Green
        }
    }

    # 3) version stamp drift across the hand-stamped locations.
    $vZon  = (Select-String -Path (Join-Path $repo "build.zig.zon") -Pattern '\.version\s*=\s*"([^"]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
    $vMain = (Select-String -Path (Join-Path $repo "src\main.zig")  -Pattern 'VERSION\s*=\s*"([^"]+)"'   | Select-Object -First 1).Matches[0].Groups[1].Value
    $relNotes = (Select-String -Path (Join-Path $repo ".github\workflows\release.yml") -Pattern 'RELEASE-v([^\s]+)\.md' | Select-Object -First 1).Matches[0].Groups[1].Value
    if ($vZon -ne $vMain) {
        $signals++
        Write-Host "[version] build.zig.zon=$vZon vs src/main.zig=$vMain -- stamp both" -ForegroundColor Yellow
    } else {
        Write-Host "[version] $vZon (zon matches main.zig; release notes pinned at v$relNotes)" -ForegroundColor Green
    }
    # MANIFEST must always carry the current version (the notes pointer above deliberately lags
    # until the next bump; MANIFEST does not get that excuse).
    $manifest = Join-Path $repo "bin\MANIFEST.txt"
    if ((Test-Path $manifest) -and (-not (Select-String -Path $manifest -Pattern ([regex]::Escape($vZon)) -Quiet))) {
        $signals++
        Write-Host "[version] bin/MANIFEST.txt carries no '$vZon' stamp -- run scripts\bump-version.ps1" -ForegroundColor Yellow
    }

    # 4) docs mirror drift: docs/docs-src/ carries one .md per module; new/renamed modules rot it.
    $missingDocs = @()
    foreach ($m in @(
        @{ root = (Join-Path $repo "src");      docs = (Join-Path $repo "docs\docs-src") },
        @{ root = (Join-Path $repo "desk\src"); docs = (Join-Path $repo "docs\docs-src\desk") }
    )) {
        if (-not (Test-Path $m.docs)) { continue }
        Get-ChildItem $m.root -Recurse -Filter *.zig | ForEach-Object {
            $rel = $_.FullName.Substring($m.root.Length + 1)
            if ($rel -eq "tests.zig") { return }
            $md = Join-Path $m.docs ($rel -replace '\.zig$', '.md')
            if (-not (Test-Path $md)) { $missingDocs += ($_.FullName.Substring($repo.Length + 1)) }
        }
    }
    if ($missingDocs.Count -gt 0) {
        Write-Host ("[docs] {0} module(s) have no docs-src case file (first 15):" -f $missingDocs.Count) -ForegroundColor Yellow
        $missingDocs | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "[docs] docs-src mirror complete" -ForegroundColor Green
    }

    # 5) marker debt. Case-sensitive: the markers are an uppercase convention, and insensitive
    #    matching inflated the count with prose hits (23 vs the true 11 when this was aligned
    #    with check.sh's grep).
    $todo = @(Get-ChildItem (Join-Path $repo "src"), (Join-Path $repo "desk\src") -Recurse -Filter *.zig |
        Select-String -CaseSensitive -Pattern 'TODO|FIXME|HACK|XXX').Count
    Write-Host "[markers] $todo TODO/FIXME/HACK/XXX across src + desk/src"

    # 6) allocPrint-append leaks: appendSlice COPIES the formatted slice, so a gpa-backed
    #    allocPrint result passed inline is never freed -- a slow per-call bleed in a long-lived
    #    server. Found live in writer (ledger 0004) and commons (0009); arena/ta-backed variants
    #    are fine and are not matched.
    # appendSlice COPIES; plain .append() of the slice pointer transfers ownership (freed by the
    # consumer) and is NOT a leak -- match appendSlice only.
    $leaks = @(Get-ChildItem (Join-Path $repo "src"), (Join-Path $repo "desk\src") -Recurse -Filter *.zig |
        Select-String -CaseSensitive -Pattern 'appendSlice\([^,]+,\s*std\.fmt\.allocPrint\(gpa[,)]')
    if ($leaks.Count -gt 0) {
        $signals += $leaks.Count
        Write-Host ("[leaks] {0} inline allocPrint(gpa)-into-append site(s) (each leaks per call; capture + defer free):" -f $leaks.Count) -ForegroundColor Yellow
        $leaks | ForEach-Object { Write-Host ("    {0}:{1}" -f $_.Path.Substring($repo.Length + 1), $_.LineNumber) }
    } else {
        Write-Host "[leaks] no inline allocPrint(gpa)-into-append sites" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host ("scan done: {0} actionable signal(s). Cross-check harness/LEDGER.md open items." -f $signals) -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------- gates (mirror of CI `check`)
$python = "python"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { $python = "py" }

# Verdict guard (ledger H13): one live run summarized NOT GREEN while every effective gate row was
# PASS -- something in the flake path emitted extra pipeline values. A PS function's return is
# EVERYTHING it emitted, so judge a gate by the LAST Boolean it produced (returns are emitted last;
# any pollution precedes them) and shout with types when a gate returns anything but one pure bool,
# so the next occurrence diagnoses itself instead of silently flipping the verdict.
function Confirm-Gate($r) {
    $flat = @($r)
    $bools = @($flat | Where-Object { $_ -is [bool] })
    if ($flat.Count -ne 1 -or $bools.Count -ne 1) {
        $shape = ($flat | ForEach-Object { "[{0}]{1}" -f $_.GetType().Name, $_ }) -join ", "
        Write-Host "   [h13] gate emitted $($flat.Count) value(s): $shape" -ForegroundColor Magenta
    }
    if ($bools.Count -eq 0) { return $false }
    return $bools[-1]
}

$ok = $true
$ok = (Confirm-Gate (Invoke-Gate "catalog sync (models.yaml vs web/public/models.json)" $python @("scripts/gen-models-json.py", "--check") $repo 60 "")) -and $ok
$ok = (Confirm-Gate (Invoke-Gate "zig build server-only (-Dapp=false)" $zig @("build", "-Dapp=false", "--cache-dir", $cache, "--prefix", $prefix) $repo $TimeoutSec "")) -and $ok
$ok = (Confirm-Gate (Invoke-ZigTests "src suite" $repo $TimeoutSec "")) -and $ok
$ok = (Confirm-Gate (Invoke-ZigTests "desk suite" (Join-Path $repo "desk") 300 "Known: the desk suite's final net test needs a live server on :8787. If everything before it passed, treat that as the verdict and see the hermetic-desk-tests ledger item.")) -and $ok
if ($Full) {
    $ok = (Confirm-Gate (Invoke-Gate "zig build default (GUI merged in)" $zig @("build", "--cache-dir", $cache, "--prefix", $prefix) $repo $TimeoutSec "")) -and $ok
}

Write-Host ""
Write-Host "== verdict ==" -ForegroundColor Cyan
$script:results | Format-Table gate, status -AutoSize
if ($ok) {
    Write-Host "ALL GREEN" -ForegroundColor Green
    exit 0
}
Write-Host "NOT GREEN -- logs in $logs" -ForegroundColor Red
exit 1
