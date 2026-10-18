$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'fureclaude-terminal.cs')

function Test-Route([string[]] $Chunks, [string] $Expected, [int] $Reads = 0, [string] $ClipboardText = 'clipboard') {
    $state = @{ Output = [Text.StringBuilder]::new(); Reads = 0 }
    $send = [Action[string]]{ param($text) [void]$state.Output.Append($text) }.GetNewClosure()
    $clipboard = [Func[string]]{ $state.Reads++; return $ClipboardText }.GetNewClosure()
    $router = [FureclaudeTerminal+InputRouter]::new($send, $clipboard)
    foreach ($chunk in $Chunks) { $router.Feed($chunk) }
    if ($Chunks.Count -eq 1 -and $Chunks[0] -ceq [string][char]27) {
        Start-Sleep -Milliseconds 100
        $router.FlushIdle()
    }
    if ($state.Output.ToString() -cne $Expected -or $state.Reads -ne $Reads) {
        $actualHex = [BitConverter]::ToString([Text.Encoding]::Unicode.GetBytes($state.Output.ToString()))
        $expectedHex = [BitConverter]::ToString([Text.Encoding]::Unicode.GetBytes($Expected))
        throw "Input routing failed at line $($MyInvocation.ScriptLineNumber) (clipboard reads: $($state.Reads), expected: $Reads). Actual=$actualHex Expected=$expectedHex"
    }
}

$escape = [string][char]27
$start = $escape + '[200~'
$end = $escape + '[201~'
$rightDown = $escape + '[<2;40;10M'
$rightUp = $escape + '[<2;40;10m'
$wheel = $escape + '[<64;40;10M' + $escape + '[<65;40;10M'
$left = $escape + '[<0;40;10M' + $escape + '[<0;40;10m'
$altK = $escape + 'k'
$clipboardText = -join ([uint16[]]@(0x4e2d, 0x6587, 0xff0c, 0xd83d, 0xde80) | ForEach-Object { [char]$_ })
$clipboardText += "`r`nJARVIS"
$inputText = 'before' + $rightDown + $rightUp + $wheel + $left + $altK + 'after'
$expected = 'before' + $start + $clipboardText + $end + $wheel + $left + $altK + 'after'

# Every split boundary, including the middle of the mouse report, must behave
# identically; a press/release pair pastes once and preserves wheel/left events.
for ($split = 0; $split -le $inputText.Length; $split++) {
    Test-Route @($inputText.Substring(0, $split), $inputText.Substring($split)) $expected 1 $clipboardText
}
Test-Route @($inputText.ToCharArray() | ForEach-Object { [string]$_ }) $expected 1 $clipboardText

# A mouse-looking string inside a normal Ctrl+V paste is literal text and must
# never trigger a clipboard read. Test it one UTF-16 code unit at a time.
$literal = $start + $clipboardText + $rightDown + $rightUp + $end + $wheel
Test-Route @($literal.ToCharArray() | ForEach-Object { [string]$_ }) $literal
Test-Route @($escape) $escape
Test-Route @(($escape + '[A'), ($escape + '[B')) ($escape + '[A' + $escape + '[B')
Test-Route @($rightDown, $rightUp) '' 1 ''
Test-Route @($rightDown) ($start + '[201~text' + $end) 1 ($escape + '[201~text')
Test-Route @($escape + '[<18;40;10M') ($escape + '[<18;40;10M')
Write-Output 'PASS: right-click paste, split sequences, wheel/keys, Unicode clipboard and literal pasted escape sequences.'
