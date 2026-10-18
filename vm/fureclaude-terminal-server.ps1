param([Parameter(Mandatory=$true)][string]$EncodedScript)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -Path (Join-Path $PSScriptRoot 'fureclaude-terminal.cs')
exit [FureclaudeTerminal]::Server((Join-Path $PSScriptRoot 'OpenConsole.exe'), $EncodedScript)
