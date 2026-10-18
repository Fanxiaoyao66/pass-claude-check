# Run in a fresh Windows PowerShell 5.1 process:
# powershell.exe -NoProfile -File tests\Test-TerminalUnicode.ps1
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'fureclaude-terminal.cs')

# A native KEY_EVENT_RECORD contains a UTF-16 WCHAR at byte offset 14 of
# INPUT_RECORD. Exercise native-to-managed marshalling with the actual relay
# record type, rather than relying on terminal rendering or the active code page.
$recordType = [FureclaudeTerminal].GetNestedType('InputRecord', [Reflection.BindingFlags]::NonPublic)
$convert = [Runtime.InteropServices.Marshal].GetMethod('PtrToStructure', [type[]]@([IntPtr], [Type]))
$sizeMethod = [Runtime.InteropServices.Marshal].GetMethod('SizeOf', [type[]]@([Type]))
if ($sizeMethod.Invoke($null, @($recordType)) -ne 20) { throw 'Unexpected INPUT_RECORD size.' }

# Keep the source ASCII so Windows PowerShell does not need a source-file BOM.
$units = [uint16[]]@(0x4E2D, 0x6587, 0x7C98, 0x8D34, 0xFF0C, 0x3002, 0x0041, 0x002D, 0x0031, 0xD83D, 0xDE80)
$memory = [Runtime.InteropServices.Marshal]::AllocHGlobal(20)
$actual = [Text.StringBuilder]::new()
try {
    foreach ($unit in $units) {
        for ($at = 0; $at -lt 20; $at++) { [Runtime.InteropServices.Marshal]::WriteByte($memory, $at, 0) }
        [Runtime.InteropServices.Marshal]::WriteInt16($memory, 0, 1) # KEY_EVENT
        [Runtime.InteropServices.Marshal]::WriteInt32($memory, 4, 1) # key down
        [Runtime.InteropServices.Marshal]::WriteInt16($memory, 8, 1) # repeat count
        $signedUnit = [BitConverter]::ToInt16([BitConverter]::GetBytes($unit), 0)
        [Runtime.InteropServices.Marshal]::WriteInt16($memory, 14, $signedUnit)
        $record = $convert.Invoke($null, @($memory, $recordType))
        if ([int]$record.Character -ne $unit) {
            throw ('Unicode input corrupted: expected U+{0:X4}, got U+{1:X4}' -f $unit, [int]$record.Character)
        }
        [void]$actual.Append($record.Character)
    }
} finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($memory)
}

# The relay keeps a UTF-8 encoder across input batches. Split every UTF-16 code
# unit into a separate batch to check surrogate pairs arriving in separate reads.
$encoder = [Text.UTF8Encoding]::new($false, $true).GetEncoder()
$stream = [IO.MemoryStream]::new()
try {
    foreach ($character in $actual.ToString().ToCharArray()) {
        $bytes = New-Object byte[] 8
        $count = $encoder.GetBytes([char[]]@($character), 0, 1, $bytes, 0, $false)
        $stream.Write($bytes, 0, $count)
    }
    $expected = -join ($units | ForEach-Object { [char]$_ })
    if ([Text.Encoding]::UTF8.GetString($stream.ToArray()) -cne $expected) { throw 'UTF-8 batch round trip failed.' }
} finally {
    $stream.Dispose()
}
Write-Output 'PASS: Chinese, full-width punctuation, ASCII and split emoji surrogate pairs.'
