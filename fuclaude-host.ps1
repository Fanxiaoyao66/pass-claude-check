param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ForwardedArgs
)

$ErrorActionPreference = 'Stop'

$sshTarget = if ($env:FUCLAUDE_SSH_TARGET) { $env:FUCLAUDE_SSH_TARGET } else { 'windows-user@192.168.77.128' }
$sshKey = if ($env:FUCLAUDE_SSH_KEY) { $env:FUCLAUDE_SSH_KEY } else { Join-Path $env:USERPROFILE '.ssh\id_ed25519_fuclaude_vm' }
$hostRoot = if ($env:FUCLAUDE_HOST_ROOT) { $env:FUCLAUDE_HOST_ROOT } else { 'D:\working' }
$remoteRoot = if ($env:FUCLAUDE_REMOTE_ROOT) { $env:FUCLAUDE_REMOTE_ROOT } else { '\\vmware-host\Shared Folders\working' }
$remoteDrive = if ($env:FUCLAUDE_REMOTE_DRIVE) { $env:FUCLAUDE_REMOTE_DRIVE.TrimEnd('\') } else { 'W:' }
$remoteCommand = if ($env:FUCLAUDE_REMOTE_COMMAND) { $env:FUCLAUDE_REMOTE_COMMAND } else { 'claude' }

function Normalize-LocalPath([string] $path) {
    return [System.IO.Path]::GetFullPath($path).TrimEnd('\')
}

function Quote-PowerShellLiteral([string] $value) {
    return "'" + ($value -replace "'", "''") + "'"
}

$currentPath = (Get-Location).ProviderPath
if (-not $currentPath) {
    throw 'fuclaude must be run from a filesystem path.'
}

$hostRootFull = Normalize-LocalPath $hostRoot
$currentFull = Normalize-LocalPath $currentPath
$hostPrefix = $hostRootFull + '\'

if (($currentFull -ne $hostRootFull) -and (-not $currentFull.StartsWith($hostPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "Current directory '$currentFull' is not under configured host root '$hostRootFull'. Set FUCLAUDE_HOST_ROOT if needed."
}

if ($currentFull -eq $hostRootFull) {
    $relativePath = '.'
} else {
    $relativePath = $currentFull.Substring($hostPrefix.Length)
}

if ($relativePath -eq '.') {
    $remotePath = $remoteRoot.TrimEnd('\')
} else {
    $remotePath = $remoteRoot.TrimEnd('\') + '\' + ($relativePath -replace '/', '\')
}

$argText = ''
if ($ForwardedArgs.Count -gt 0) {
    $argText = ' ' + (($ForwardedArgs | ForEach-Object { Quote-PowerShellLiteral $_ }) -join ' ')
}

$remoteScript = @"
`$ErrorActionPreference = 'Stop'
`$shareRoot = $(Quote-PowerShellLiteral $remoteRoot.TrimEnd('\'))
`$relativePath = $(Quote-PowerShellLiteral $relativePath)
`$remotePath = $(Quote-PowerShellLiteral $remotePath)
if (`$shareRoot.StartsWith('\\')) {
    `$drive = $(Quote-PowerShellLiteral $remoteDrive)
    cmd.exe /c "net use `$drive /delete /y >nul 2>nul" | Out-Null
    `$mapOutput = cmd.exe /c "net use `$drive ```"`$shareRoot```" /persistent:no" 2>&1
    if (`$LASTEXITCODE -ne 0) {
        throw "Failed to map `$shareRoot to `$drive. `$mapOutput"
    }
    if (`$relativePath -eq '.') {
        `$remotePath = `$drive + '\'
    } else {
        `$remotePath = `$drive + '\' + (`$relativePath -replace '/', '\')
    }
}
Set-Location -LiteralPath `$remotePath
`$commandName = $(Quote-PowerShellLiteral $remoteCommand)
`$resolvedCommand = Get-Command `$commandName -ErrorAction SilentlyContinue | Select-Object -First 1
if (`$resolvedCommand) {
    `$commandPath = `$resolvedCommand.Source
} else {
    `$localBinCommand = Join-Path `$env:USERPROFILE ".local\bin\`$commandName.exe"
    if (-not (Test-Path -LiteralPath `$localBinCommand)) {
        throw "Official Claude Code was not found on the VM. Install it there or set FUCLAUDE_REMOTE_COMMAND."
    }
    `$commandPath = `$localBinCommand
}
& `$commandPath$argText
exit `$LASTEXITCODE
"@

if ($env:FUCLAUDE_DRY_RUN -eq '1') {
    Write-Output "sshTarget=$sshTarget"
    Write-Output "sshKey=$sshKey"
    Write-Output "hostPath=$currentFull"
    Write-Output "remotePath=$remotePath"
    Write-Output "remoteDrive=$remoteDrive"
    Write-Output "remoteCommand=$remoteCommand"
    Write-Output 'remoteScript:'
    Write-Output $remoteScript
    exit 0
}

$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remoteScript))
$sshArgs = @('-tt')
if (Test-Path -LiteralPath $sshKey) {
    $sshArgs += @('-i', $sshKey, '-o', 'IdentitiesOnly=yes')
}
$sshArgs += @('-o', 'StrictHostKeyChecking=accept-new', $sshTarget, 'powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
& ssh @sshArgs
exit $LASTEXITCODE
