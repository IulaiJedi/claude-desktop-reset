#!/usr/bin/env bash
# From WSL: run the Windows test suite and return its exit code.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$here/run-tests.ps1")" 2>&1 | tr -d '\r'
exit "${PIPESTATUS[0]}"
