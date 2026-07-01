@echo off
REM veil - cast a hive-mind swarm on the fly (Windows). Thin wrapper over deploy.py:
REM   veil "add a header search to my landing page" --embed . --repl
python "%~dp0deploy.py" %*
