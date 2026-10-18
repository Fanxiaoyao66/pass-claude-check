param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ForwardedArgs
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($ForwardedArgs.Count -gt 1 -or ($ForwardedArgs.Count -eq 1 -and $ForwardedArgs[0] -ne '--check')) {
    throw 'Usage: fureclaude update-claude [--check]'
}
$checkOnly = $ForwardedArgs.Count -eq 1
$base = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$profileRoot = Join-Path $base 'home'
if ($env:USERPROFILE -ne $profileRoot) {
    throw 'Run this updater through fureclaude update-claude.'
}
$binDir = [IO.Path]::GetFullPath((Join-Path $profileRoot '.local\bin'))
if (-not $binDir.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The Claude binary directory must stay inside the isolated installation.'
}
$target = Join-Path $binDir 'claude.exe'
$backup = Join-Path $binDir 'claude.previous.exe'
foreach ($path in @($profileRoot, (Join-Path $profileRoot '.local'), $binDir, $target, $backup)) {
    if ((Test-Path -LiteralPath $path) -and
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing linked installation path: $path"
    }
}
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Isolated Claude Code is missing: $target"
}

$lock = $null
$staged = $null
try {
    $lock = [IO.File]::Open((Join-Path $binDir '.claude-update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $currentOutput = (& $target --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $currentOutput -notmatch '^(\d+\.\d+\.\d+)\s') {
        throw 'Could not determine the installed Claude Code version.'
    }
    $currentVersion = $Matches[1]
    $releaseBase = 'https://downloads.claude.ai/claude-code-releases'
    $latest = ([string](Invoke-RestMethod -Uri "$releaseBase/latest" -TimeoutSec 30)).Trim()
    if ($latest -notmatch '^\d+\.\d+\.\d+$') {
        throw 'The release server returned an invalid version.'
    }
    Write-Output "Claude Code: installed $currentVersion; latest $latest"
    if ([version]$currentVersion -ge [version]$latest) {
        Write-Output 'Claude Code is up to date.'
        exit 0
    }
    if ($checkOnly) { exit 0 }

    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $platform = switch ($architecture) {
        'AMD64' { 'win32-x64' }
        'ARM64' { 'win32-arm64' }
        default { throw "Unsupported architecture: $architecture" }
    }
    $manifest = Invoke-RestMethod -Uri "$releaseBase/$latest/manifest.json" -TimeoutSec 30
    $release = $manifest.platforms.$platform
    $expected = [string]$release.checksum
    if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The release manifest is missing a valid SHA256 checksum.'
    }
    $staged = Join-Path $binDir ('claude.download.' + [Guid]::NewGuid().ToString('N') + '.exe')
    Write-Output "Downloading Claude Code $latest ($platform)..."
    Invoke-WebRequest -Uri "$releaseBase/$latest/$platform/claude.exe" -UseBasicParsing -OutFile $staged -TimeoutSec 300
    if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $expected) {
        throw 'Downloaded Claude Code failed SHA256 verification.'
    }
    $downloadedOutput = (& $staged --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $downloadedOutput -notmatch ('^' + [regex]::Escape($latest) + '\s')) {
        throw 'The verified binary did not report the expected version.'
    }

    # Keep one previous version. A locked backup causes failure before replacing the current program.
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    Move-Item -LiteralPath $target -Destination $backup
    try {
        Move-Item -LiteralPath $staged -Destination $target
        $staged = $null
    } catch {
        if (-not (Test-Path -LiteralPath $target)) {
            Move-Item -LiteralPath $backup -Destination $target
        }
        throw
    }
    Write-Output "Updated Claude Code: $currentVersion -> $latest (SHA256 verified)."
    Write-Output "Previous version: $backup"
    Write-Output 'Exit the current Claude Code session and run fureclaude again to use the new version.'
} finally {
    if ($staged -and (Test-Path -LiteralPath $staged)) {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    }
    if ($lock) { $lock.Dispose() }
}
exit 0
