param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ForwardedArgs
)

$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $PSScriptRoot
$profileRoot = Join-Path $base 'home'
$binary = Join-Path $PSScriptRoot 'reclaude.exe'

# These commands configure Windows-wide integration or the normal installation.
if ($ForwardedArgs.Count -gt 0 -and $ForwardedArgs[0] -in @(
    'setup', 'unsetup', 'uninstall', 'update', 'app', 'app-reset',
    'app-update', 'vm-proxy', 'cowork'
)) {
    throw 'This isolated launcher supports Claude Code only. Installation, update and desktop commands must be managed separately.'
}

# Refuse links that could reconnect this profile to the shared original profile.
foreach ($relative in @('', '.claude', '.claude.json', '.reclaude', '.local', '.local\bin', 'AppData', 'AppData\Local', 'AppData\Roaming')) {
    $path = if ($relative) { Join-Path $profileRoot $relative } else { $profileRoot }
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing linked profile path: $path"
        }
    }
}
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Isolated ReClaude binary is missing: $binary"
}

# Scope all changes to this SSH process; never write persistent user variables.
Get-ChildItem Env: | Where-Object {
    $_.Name -match '^(ANTHROPIC_|CLAUDE_|RECLAUDE_)'
} | ForEach-Object { Remove-Item -LiteralPath ('Env:\' + $_.Name) }
$env:USERPROFILE = $profileRoot
$env:HOMEDRIVE = [IO.Path]::GetPathRoot($profileRoot).TrimEnd('\')
$env:HOMEPATH = $profileRoot.Substring($env:HOMEDRIVE.Length)
$env:APPDATA = Join-Path $profileRoot 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $profileRoot 'AppData\Local'
$env:PATH = (Join-Path $profileRoot '.local\bin') + ';' + $env:PATH
$env:RECLAUDE_NO_MODIFY_PATH = '1'
$env:RECLAUDE_DISABLE_SYSTEM_PROXY = '1'
$env:RECLAUDE_AUTO_UPDATE = '0'

# Windows-over-SSH otherwise forces the classic renderer. Use Claude's own
# conversation scrolling, with full repaint for the Windows ConPTY transport.
$env:CLAUDE_CODE_NO_FLICKER = '1'
$env:CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT = '1'
if (-not $env:TERM -or $env:TERM -eq 'dumb') { $env:TERM = 'xterm-256color' }

if ($ForwardedArgs.Count -gt 0 -and $ForwardedArgs[0] -eq 'update-claude') {
    $updateArgs = @($ForwardedArgs | Select-Object -Skip 1)
    & (Join-Path $PSScriptRoot 'fureclaude-update-claude.ps1') @updateArgs
    exit $LASTEXITCODE
}

& $binary @ForwardedArgs
exit $LASTEXITCODE
