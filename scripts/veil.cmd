@echo off
REM veil - the front door (Windows). Alone it runs the server; with a verb it drives the running
REM server over its API. The CLI is built into the compiled binary now:
REM   veil                              run the server (add --desk to host the desktop)
REM   veil cast "add a header search"   deploy a swarm
REM   veil chat                         talk to the server-side veil brain
REM   veil list ^| stop ^<id^> ^| sched ^| hub   fleet + scheduled-task control
setlocal
set "DIR=%~dp0"
set "BIN=%DIR%zig-out\bin\veil.exe"
if not exist "%BIN%" set "BIN=%DIR%bin\veil.exe"
if not exist "%BIN%" (
  where zig >nul 2>nul
  if errorlevel 1 (
    echo veil: no binary and no zig on PATH. Install zig 0.16+ then run "zig build --release=fast" in %DIR% 1>&2
    exit /b 1
  )
  echo veil: building the binary ^(first run^)... 1>&2
  pushd "%DIR%" && zig build --release=fast & popd
  set "BIN=%DIR%zig-out\bin\veil.exe"
)
"%BIN%" %*
