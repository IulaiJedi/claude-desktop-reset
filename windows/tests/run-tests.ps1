# Runs the Pester 3.4 suite that ships with Windows PowerShell 5.1.
# Tests work only on fake trees inside Pester's TestDrive; they never touch real Claude data.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 3.4.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$r = Invoke-Pester -Script (Join-Path $here 'ClaudeReset.Tests.ps1') -PassThru -OutputFormat NUnitXml -OutputFile (Join-Path $env:TEMP 'ClaudeReset.Tests.xml')
"PASSED=$($r.PassedCount) FAILED=$($r.FailedCount)"
exit $r.FailedCount
