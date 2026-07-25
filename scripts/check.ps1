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
        # WHAT ACTUALLY BROKE, first. A failing desk run buries its one real assertion under dozens
        # of CONNECTION_REFUSED stack dumps from tests that hit a dead port ON PURPOSE (std prints a
        # trace for every unexpectedStatus in Debug), and a compile error can sit above a page of
        # linker chatter. These three patterns are the lines a human actually needs: Zig's test
        # failure header, a compile error with its file:line, and the build runner's own summary.
        $signal = Get-Content $err -ErrorAction SilentlyContinue |
            Select-String -Pattern "^error: '.*' failed:|^.*\.zig:\d+:\d+: error:|^error: the following|tests passed|tests failed" |
            Select-Object -Last 8
        if ($signal) {
            Write-Host "   -- what failed --" -ForegroundColor Red
            $signal | ForEach-Object { Write-Host "   > $($_.Line)" -ForegroundColor Red }
            Write-Host "   -- tail --" -ForegroundColor DarkGray
        }
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

    # 1) test registration. Zig collects test blocks only from imports it ANALYZES, and lazy
    #    analysis means a textual @import chain is NOT proof of collection: desk/assets.zig sat in
    #    the graph via theme.zig for months with its tests never running, because no test reaches
    #    theme's icon paths. So this reports two things — files outside the import graph entirely
    #    (certainly dead), and test-bearing files not named DIRECTLY in tests.zig (only probably
    #    live). Direct registration is the only guarantee.
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
        # Named-module roots are exempt below: build.zig gives them their OWN test artifact, and a
        # path import in tests.zig would double-own the file ("file exists in modules 'root' and X").
        $modRoots = @{}
        foreach ($q in $queue.ToArray()) { if ($q -ne $pkg.tests) { $modRoots[([IO.Path]::GetFullPath($q)).ToLower()] = $true } }
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
        # Indirect = in the graph but not named in tests.zig. Lazy analysis can drop these silently,
        # which is exactly how desk/assets.zig's tests went unrun; name them and the doubt is gone.
        $indirect = @()
        Get-ChildItem $pkg.root -Recurse -Filter *.zig | ForEach-Object {
            $rel = $_.FullName.Substring($pkg.root.Length + 1)
            if ($rel -eq "tests.zig" -or $rel -like "*_test.zig") { return }
            if (-not (Select-String -Path $_.FullName -Pattern '^\s*test[\s"{]' -Quiet)) { return }
            if ($orphans -contains $rel) { return }
            if ($modRoots.ContainsKey($_.FullName.ToLower())) { return } # its own test artifact
            if (-not (Select-String -Path $pkg.tests -SimpleMatch ('"' + ($rel -replace '\\', '/') + '"') -Quiet)) { $indirect += $rel }
        }
        if ($indirect.Count -gt 0) {
            Write-Host ("[{0}] {1} test-bearing file(s) reach the root only INDIRECTLY -- collection is not guaranteed; register them:" -f $pkg.label, $indirect.Count) -ForegroundColor Yellow
            $indirect | ForEach-Object { Write-Host "    $_" }
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
            # tests.zig and *_test.zig are test harnesses, not modules -- no case file owed.
            if ($rel -eq "tests.zig" -or $rel -like "*_test.zig") { return }
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

    # 6b) the built-in palettes are mirrored BY HAND into the web stylesheet — plug/theme.zig says so
    #     ("web/public/styles.css mirrors the same hex set"). Nothing checked it. A slot recoloured in
    #     one and not the other is the kind of drift nobody reports as a bug; it just looks slightly
    #     wrong in one client.
    $themePath = Join-Path $repo "src\plug\theme.zig"
    $cssPath = Join-Path $repo "web\public\styles.css"
    if ((Test-Path $themePath) -and (Test-Path $cssPath)) {
        $css = (Get-Content $cssPath -Raw).ToLower()
        $themeSrc = Get-Content $themePath -Raw
        $missing = @()
        $total = 0
        foreach ($set in @("dark_colors", "light_colors")) {
            $m = [regex]::Match($themeSrc, "const\s+$set\s*=\s*\[SLOT_COUNT\]u32\{(.*?)\}", 'Singleline')
            if (-not $m.Success) { continue }
            foreach ($hx in [regex]::Matches($m.Groups[1].Value, '0x([0-9a-fA-F]{6})')) {
                $total++
                $hex = $hx.Groups[1].Value.ToLower()
                if ($css -notmatch "#$hex") { $missing += "$set 0x$hex" }
            }
        }
        if ($missing.Count -gt 0) {
            $signals += $missing.Count
            Write-Host ("[theme] {0} of {1} palette slots are NOT in web/public/styles.css -- the mirror drifted:" -f $missing.Count, $total) -ForegroundColor Yellow
            $missing | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host ("[theme] all {0} palette slots mirrored in web/public/styles.css" -f $total) -ForegroundColor Green
        }
    }

    # 7) the two oracles must gate on the SAME things. check.ps1 is what a worker runs; check.sh is
    #    what CI runs. A gate added to one and not the other means local green and CI red (or worse,
    #    the reverse) — the drift class this repo keeps finding, and one I nearly caused myself
    #    editing both by hand. Names are normalised because the ps1 routes its two test gates
    #    through a helper that labels them "src suite" where the sh spells out "zig build test
    #    (src suite)"; the $label entries inside that helper are internal, not top-level gates.
    function Gate-Keys([string[]]$names) {
        $out = @()
        foreach ($n in $names) {
            if ($n -match '\$label') { continue }
            $out += (($n -replace 'zig build test', '') -replace '[^a-zA-Z0-9]', '').ToLower()
        }
        return $out | Sort-Object -Unique
    }
    $ps1_names = (Select-String -Path $PSCommandPath -Pattern 'Invoke-(?:Gate|ZigTests) "([^"]+)"' -AllMatches).Matches | ForEach-Object { $_.Groups[1].Value }
    $shPath = Join-Path $repo "scripts\check.sh"
    $sh_names = @()
    if (Test-Path $shPath) {
        $sh_names = (Select-String -Path $shPath -Pattern '^\s*gate "([^"]+)"' -AllMatches).Matches | ForEach-Object { $_.Groups[1].Value }
    }
    $a = Gate-Keys $ps1_names
    $b = Gate-Keys $sh_names
    $onlyPs1 = $a | Where-Object { $b -notcontains $_ }
    $onlySh = $b | Where-Object { $a -notcontains $_ }
    if ($onlyPs1.Count -gt 0 -or $onlySh.Count -gt 0) {
        $signals += ($onlyPs1.Count + $onlySh.Count)
        Write-Host "[oracles] check.ps1 and check.sh gate on DIFFERENT things -- local and CI would disagree:" -ForegroundColor Yellow
        $onlyPs1 | ForEach-Object { Write-Host "    only in check.ps1: $_" }
        $onlySh | ForEach-Object { Write-Host "    only in check.sh:  $_" }
    } else {
        Write-Host ("[oracles] check.ps1 and check.sh gate on the same {0} things" -f $a.Count) -ForegroundColor Green
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
