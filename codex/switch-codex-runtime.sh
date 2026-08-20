#!/usr/bin/env bash
# Call the Windows Codex runtime switcher from WSL.
set -euo pipefail
win_home="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
win_script="${win_home}\\.codex\\scripts\\Switch-CodexRuntime.ps1"
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win_script" "$@"
