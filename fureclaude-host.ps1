param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ForwardedArgs
)

$ErrorActionPreference = 'Stop'
if (-not $env:TERM -or $env:TERM -eq 'dumb') { $env:TERM = 'xterm-256color' }
$wrapper = Join-Path $PSScriptRoot 'fuclaude-host.ps1'
if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
    throw "The existing fuclaude wrapper is required: $wrapper"
}

$env:FUCLAUDE_REMOTE_COMMAND = if ($env:FURECLAUDE_REMOTE_COMMAND) {
    $env:FURECLAUDE_REMOTE_COMMAND
} else {
    '%LOCALAPPDATA%\fureclaude\bin\fureclaude-vm.ps1'
}

# Management commands do not depend on the caller's current project directory.
if ($ForwardedArgs.Count -gt 0 -and $ForwardedArgs[0] -in @(
    'login', 'logout', 'status', 'version', 'help', 'stop', 'org', 'config', 'logs', 'update-claude',
    '--version', '-v', '--help', '-h'
)) {
    $hostRoot = if ($env:FUCLAUDE_HOST_ROOT) { $env:FUCLAUDE_HOST_ROOT } else { 'D:\working' }
    Set-Location -LiteralPath $hostRoot
}

# Keep the original directory/argument mapping, but give interactive fureclaude
# its own terminal transport. Windows 10's inbox SSH ConPTY drops mouse events.
$management = $ForwardedArgs.Count -gt 0 -and $ForwardedArgs[0] -in @(
    'login', 'logout', 'status', 'version', 'help', 'stop', 'org', 'config', 'logs', 'update-claude',
    '--version', '-v', '--help', '-h'
)
$useTerminalRelay = -not $management -and $env:FUCLAUDE_DRY_RUN -ne '1' -and $env:FURECLAUDE_LEGACY_TTY -ne '1' -and
    -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and
    '-p' -notin $ForwardedArgs -and '--print' -notin $ForwardedArgs

if ($useTerminalRelay) {
    $realSsh = (Get-Command ssh.exe -CommandType Application -ErrorAction Stop).Source
    $terminalServer = Join-Path (Split-Path -Parent $env:FUCLAUDE_REMOTE_COMMAND) 'fureclaude-terminal-server.ps1'
    Add-Type -Path (Join-Path $PSScriptRoot 'fureclaude-terminal.cs')

    # This function exists only in this launcher process. The directory wrapper
    # resolves it when invoking its final SSH command.
    $function:ssh = {
        param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
        $shellIndex = [Array]::IndexOf($Arguments, 'powershell.exe')
        $encodedIndex = [Array]::IndexOf($Arguments, '-EncodedCommand')
        if ($shellIndex -lt 1 -or $encodedIndex -lt $shellIndex -or $encodedIndex + 1 -ge $Arguments.Count) {
            throw 'Unexpected SSH arguments from fuclaude-host.ps1.'
        }
        $relayArgs = @($Arguments[0..($shellIndex - 1)] | ForEach-Object {
            if ($_ -eq '-tt') { '-T' } else { $_ }
        })
        # Expand the helper path on the VM before its isolated profile is set.
        # Encoding the bootstrap also preserves usernames and paths with spaces.
        # Compress the nested payload to stay below Windows SSH's cmd.exe limit.
        $helperLiteral = "'" + $terminalServer.Replace("'", "''") + "'"
        $payloadBytes = [Convert]::FromBase64String($Arguments[$encodedIndex + 1])
        $buffer = [IO.MemoryStream]::new()
        $compressor = [IO.Compression.DeflateStream]::new($buffer, [IO.Compression.CompressionMode]::Compress, $true)
        try { $compressor.Write($payloadBytes, 0, $payloadBytes.Length) }
        finally { $compressor.Dispose() }
        $compressed = [Convert]::ToBase64String($buffer.ToArray())
        $buffer.Dispose()
        $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$source = [IO.MemoryStream]::new([Convert]::FromBase64String('$compressed'))
`$decoder = [IO.Compression.DeflateStream]::new(`$source, [IO.Compression.CompressionMode]::Decompress)
`$buffer = [IO.MemoryStream]::new()
try { `$decoder.CopyTo(`$buffer); `$payload = [Convert]::ToBase64String(`$buffer.ToArray()) }
finally { `$decoder.Dispose(); `$source.Dispose(); `$buffer.Dispose() }
& ([Environment]::ExpandEnvironmentVariables($helperLiteral)) -EncodedScript `$payload
exit `$LASTEXITCODE
"@
        $bootstrapEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        $relayArgs += @('powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $bootstrapEncoded)
        $global:LASTEXITCODE = [FureclaudeTerminal]::Client($realSsh, [string[]]$relayArgs)
    }.GetNewClosure()
}

& $wrapper @ForwardedArgs
exit $LASTEXITCODE
