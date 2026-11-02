#Requires -Version 5.1
<#
.SYNOPSIS
    v10 bitstream burn for Tang Mega 60K (GW5AT-60B) using Gowin programmer_cli.

.DESCRIPTION
    Sequence (same order that worked for v7, see evidence/v10_burn_plan.md):
        1) programmer_cli --scan                          (read only, JTAG/device check)
        2) op2  = SRAM Program                            (--operation_index 2)
        3) op73 = Read User Code                          (--operation_index 73, verify == expected)
        4) op69 = exFlash Erase,Program,Verify ...5A      (--operation_index 69, ~380-400 s)

    SAFETY: the script is a DRY RUN by default. It only scans (read only) and prints the
    resolved plan; it never programs anything. Real programming requires -Execute.

    Everything printed is also appended (with a timestamp) to the log file, default
    work\d2_screen_pnr\v10_burn.log. The result summary is written to
    work\d2_screen_pnr\V10_BURN_RESULT.txt (with -Execute) or
    work\d2_screen_pnr\evidence\V10_DRYRUN_RESULT.txt (dry run).

    NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 decodes a BOM-less
    .ps1 using the ANSI code page, so non-ASCII comments/strings would be garbled.

.PARAMETER Execute
    Actually program the device. Without it the script is a rehearsal only.

.PARAMETER VerifyOnly
    No programming at all: scan + op73 read User Code + compare. Use this after the
    self-boot power cycle (SW2=100001) to confirm the Flash image boots.

.PARAMETER FsPath
    Bitstream to program. Default: <project>\work\d2_screen_pnr\impl\pnr\d2_screen_pnr.fs

.PARAMETER ExpectedUserCode
    Expected UserCode such as 0x0000ABCD. When omitted it is taken from the .fs header
    ("//UserCode: 0x........"), which is the artifact that is actually programmed.

.PARAMETER GatesSummaryPath
    Optional gates_summary.json used to cross-check bitstream.usercode.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\burn_v10.ps1
    Rehearsal: prints the plan, runs --scan, writes evidence\V10_DRYRUN_RESULT.txt.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\burn_v10.ps1 -Execute
    Real burn: scan -> op2 -> op73 check -> op69. Writes V10_BURN_RESULT.txt.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\burn_v10.ps1 -VerifyOnly
    Self-boot check only (SW2=100001 + real DC power cycle first).
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$VerifyOnly,
    [string]$FsPath,
    [string]$ProgrammerExe = 'E:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe',
    [string]$Device = 'GW5AT-60B',
    [int]$CableIndex = 1,
    [string]$CableName = 'Gowin USB Cable(FT2CH)',
    [string]$Frequency = '2.5MHz',
    [string]$ExpectedUserCode,
    [string]$GatesSummaryPath,
    [string]$LogPath,
    [string]$ResultPath,
    [int]$ScanTimeoutSeconds = 90,
    [int]$Op2TimeoutSeconds = 300,
    [int]$Op73TimeoutSeconds = 120,
    [int]$Op69TimeoutSeconds = 1500
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths / globals
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($script:ProjectRoot)) {
    throw "Cannot resolve project root from script path '$PSScriptRoot'."
}

$DefaultFs        = Join-Path $script:ProjectRoot 'work\d2_screen_pnr\impl\pnr\d2_screen_pnr.fs'
$DefaultGates     = Join-Path $script:ProjectRoot 'work\d2_screen_pnr\impl\pnr\gates_summary.json'
$DefaultLog       = Join-Path $script:ProjectRoot 'work\d2_screen_pnr\v10_burn.log'
$DefaultResult    = Join-Path $script:ProjectRoot 'work\d2_screen_pnr\V10_BURN_RESULT.txt'
$DefaultDryResult = Join-Path $script:ProjectRoot 'work\d2_screen_pnr\evidence\V10_DRYRUN_RESULT.txt'

function Resolve-UserPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $script:ProjectRoot $Path)
}

function Ensure-ParentDir {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$FsFile = if ([string]::IsNullOrWhiteSpace($FsPath)) { $DefaultFs } else { Resolve-UserPath $FsPath }
$GatesFile = if ([string]::IsNullOrWhiteSpace($GatesSummaryPath)) { $DefaultGates } else { Resolve-UserPath $GatesSummaryPath }
$script:LogFile = if ([string]::IsNullOrWhiteSpace($LogPath)) { $DefaultLog } else { Resolve-UserPath $LogPath }
$script:ResultFile = if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    Resolve-UserPath $ResultPath
} elseif ($Execute) {
    $DefaultResult
} else {
    $DefaultDryResult
}
Ensure-ParentDir $script:LogFile
Ensure-ParentDir $script:ResultFile

$Mode = if ($VerifyOnly) { 'VERIFY-ONLY' } elseif ($Execute) { 'EXECUTE' } else { 'DRY-RUN' }

# ---------------------------------------------------------------- logging
$script:LogStarted = $false

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = '{0}  [{1,-5}] {2}' -f $stamp, $Level, $Message
    Write-Host $line
    try {
        [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $script:Utf8NoBom)
    } catch {
        Write-Host ("WARN: cannot append to log '{0}': {1}" -f $script:LogFile, $_.Exception.Message)
    }
}

function Write-LogBlock {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    try {
        [System.IO.File]::AppendAllText($script:LogFile, $Text + "`r`n", $script:Utf8NoBom)
    } catch {
        Write-Host ("WARN: cannot append block to log '{0}': {1}" -f $script:LogFile, $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- parsing helpers
function Get-UserCodeFromText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Match($Text, 'User Code is:\s*(0x[0-9A-Fa-f]{8})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return $null
}

function Get-CostSeconds {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Match($Text, 'Cost\s+([0-9]+(?:\.[0-9]+)?)\s+second')
    if ($m.Success) { return [double]$m.Groups[1].Value }
    return $null
}

function Normalize-UserCode {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v -match '^0x([0-9A-Fa-f]{1,8})$') {
        return ('0x' + $Matches[1].ToUpperInvariant().PadLeft(8, '0'))
    }
    if ($v -match '^[0-9A-Fa-f]{1,8}$') {
        return ('0x' + $v.ToUpperInvariant().PadLeft(8, '0'))
    }
    return $null
}

function Get-FsHeaderText {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $buffer = New-Object byte[] 4096
        $read = $stream.Read($buffer, 0, $buffer.Length)
    } finally {
        $stream.Dispose()
    }
    return [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
}

function Get-HeaderField {
    param([string]$HeaderText, [string]$FieldName)
    $m = [regex]::Match($HeaderText, ('//' + [regex]::Escape($FieldName) + ':\s*(.+?)\s*$'), 'Multiline')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Get-TailLines {
    param([string]$Text, [int]$Count = 12)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $lines = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -le $Count) { return ($lines -join "`r`n") }
    return (($lines[($lines.Count - $Count)..($lines.Count - 1)]) -join "`r`n")
}

function Format-Arg {
    param([string]$Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Format-Cell {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '-' }
    return $Value
}

# ---------------------------------------------------------------- programmer runner
function Invoke-Programmer {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [int]$TimeoutSeconds
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ProgrammerExe
    $psi.Arguments = (($Arguments | ForEach-Object { Format-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = Split-Path -Parent $ProgrammerExe
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit(5000) } catch { }
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = $stdoutTask.Result } catch { $stdout = '' }
    try { $stderr = $stderrTask.Result } catch { $stderr = '' }
    $stopwatch.Stop()

    $exitCode = -1
    if ($finished) {
        $exitCode = $proc.ExitCode
    }
    $proc.Dispose()

    [pscustomobject]@{
        Name           = $Name
        CommandLine    = ($psi.FileName + ' ' + $psi.Arguments)
        Arguments      = $Arguments
        ExitCode       = $exitCode
        TimedOut       = (-not $finished)
        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        StandardOutput = $stdout
        StandardError  = $stderr
    }
}

function Write-ProgrammerRun {
    param([object]$Run)

    Write-Log ("{0}: exit={1} timed_out={2} elapsed_s={3}" -f $Run.Name, $Run.ExitCode, $Run.TimedOut, $Run.ElapsedSeconds) 'STEP'
    Write-Log ("{0} cmdline: {1}" -f $Run.Name, $Run.CommandLine)
    Write-LogBlock ('--- ' + $Run.Name + ' output begin ---')
    Write-LogBlock $Run.StandardOutput
    if (-not [string]::IsNullOrWhiteSpace($Run.StandardError)) {
        Write-LogBlock ('--- ' + $Run.Name + ' stderr ---')
        Write-LogBlock $Run.StandardError
    }
    Write-LogBlock ('--- ' + $Run.Name + ' output end ---')
}

# ---------------------------------------------------------------- results
$script:ResultData = [ordered]@{
    mode              = $Mode
    started           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    fs                = $FsFile
    fs_bytes          = $null
    fs_mtime          = $null
    fs_sha256         = $null
    fs_user_code      = $null
    gate_user_code    = $null
    expected_user_code = $null
    expected_source   = $null
    scan              = $null
    op2               = $null
    op2_elapsed_s     = $null
    op2_user_code     = $null
    op73_elapsed_s    = $null
    op73_user_code    = $null
    op73_match        = $null
    op69              = $null
    op69_elapsed_s    = $null
    op69_cost_s       = $null
    verdict           = $null
    reason            = $null
}

function Write-ResultFile {
    param([string]$Verdict, [string]$Reason, [string]$Tail)

    $script:ResultData.verdict = $Verdict
    $script:ResultData.reason = $Reason

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('V10 BURN RESULT: ' + $Verdict))
    [void]$sb.AppendLine(('mode            : ' + $script:ResultData.mode))
    [void]$sb.AppendLine(('started         : ' + $script:ResultData.started))
    [void]$sb.AppendLine(('finished        : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')))
    [void]$sb.AppendLine(('fs              : ' + $script:ResultData.fs))
    [void]$sb.AppendLine(('fs bytes        : ' + $script:ResultData.fs_bytes))
    [void]$sb.AppendLine(('fs mtime        : ' + $script:ResultData.fs_mtime))
    [void]$sb.AppendLine(('fs sha256       : ' + $script:ResultData.fs_sha256))
    [void]$sb.AppendLine(('fs user code    : ' + (Format-Cell $script:ResultData.fs_user_code)))
    [void]$sb.AppendLine(('gate user code  : ' + (Format-Cell $script:ResultData.gate_user_code)))
    [void]$sb.AppendLine(('expected user code: ' + (Format-Cell $script:ResultData.expected_user_code) + ' (' + (Format-Cell $script:ResultData.expected_source) + ')'))
    [void]$sb.AppendLine(('scan            : ' + (Format-Cell $script:ResultData.scan)))
    [void]$sb.AppendLine(('op2 (SRAM)      : ' + (Format-Cell $script:ResultData.op2) + ' elapsed_s=' + (Format-Cell $script:ResultData.op2_elapsed_s) + ' user_code=' + (Format-Cell $script:ResultData.op2_user_code)))
    [void]$sb.AppendLine(('op73 readback   : ' + (Format-Cell $script:ResultData.op73_user_code) + ' match=' + (Format-Cell $script:ResultData.op73_match) + ' elapsed_s=' + (Format-Cell $script:ResultData.op73_elapsed_s)))
    [void]$sb.AppendLine(('op69 (Flash)    : ' + (Format-Cell $script:ResultData.op69) + ' elapsed_s=' + (Format-Cell $script:ResultData.op69_elapsed_s) + ' cost_s=' + (Format-Cell $script:ResultData.op69_cost_s)))
    [void]$sb.AppendLine(('log             : ' + $script:LogFile))
    [void]$sb.AppendLine(('reason          : ' + $Reason))
    if (-not [string]::IsNullOrWhiteSpace($Tail)) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- op69 tail ---')
        [void]$sb.AppendLine($Tail)
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- next steps ---')
    if ($Verdict -eq 'SUCCESS' -and $Mode -eq 'EXECUTE') {
        [void]$sb.AppendLine('Post-program op73 reads 0x00000000 (GAO bridge in SRAM) -- normal, do NOT treat as failure.')
        [void]$sb.AppendLine('Self-boot check: set SW2=100001, real DC power cycle 5 s, then run:')
        [void]$sb.AppendLine('  powershell -NoProfile -ExecutionPolicy Bypass -File work\d2_screen_pnr\burn_v10.ps1 -VerifyOnly')
        [void]$sb.AppendLine('op73 must then read ' + $script:ResultData.expected_user_code + '.')
    } elseif ($Mode -eq 'DRY-RUN') {
        [void]$sb.AppendLine('Rehearsal only: nothing was programmed. Re-run with -Execute to burn.')
        [void]$sb.AppendLine('Before -Execute: SW2=001011 (Flash programming mode) and JTAG cable enumerated.')
    } elseif ($Mode -eq 'VERIFY-ONLY') {
        [void]$sb.AppendLine('Verify-only run: nothing was programmed.')
    }

    [System.IO.File]::WriteAllText($script:ResultFile, $sb.ToString(), $script:Utf8NoBom)
}

function Stop-Burn {
    param([string]$Stage, [string]$Reason, [int]$ExitCode, [string]$Tail)
    Write-Log ('FAILED at ' + $Stage + ': ' + $Reason) 'ERROR'
    Write-ResultFile -Verdict ('FAILED at ' + $Stage) -Reason $Reason -Tail $Tail
    Write-Log ('result file: ' + $script:ResultFile) 'ERROR'
    exit $ExitCode
}

# ---------------------------------------------------------------- plan
Write-Log '=============================================================='
Write-Log ('burn_v10.ps1 starting; mode=' + $Mode)
Write-Log ('project root : ' + $script:ProjectRoot)
Write-Log ('programmer   : ' + $ProgrammerExe)
Write-Log ('log file     : ' + $script:LogFile)
Write-Log ('result file  : ' + $script:ResultFile)

$Problems = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $ProgrammerExe)) {
    $Problems.Add("programmer_cli.exe not found: $ProgrammerExe")
}
if (-not (Test-Path -LiteralPath $FsFile)) {
    $Problems.Add("bitstream not found: $FsFile")
}

$fsUserCode = $null
$gateUserCode = $null
$headerText = ''
if (Test-Path -LiteralPath $FsFile) {
    $fsItem = Get-Item -LiteralPath $FsFile
    $script:ResultData.fs_bytes = $fsItem.Length
    $script:ResultData.fs_mtime = $fsItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    $script:ResultData.fs_sha256 = (Get-FileHash -LiteralPath $FsFile -Algorithm SHA256).Hash.ToLowerInvariant()
    try {
        $headerText = Get-FsHeaderText $FsFile
    } catch {
        $headerText = ''
        Write-Log ('WARN: cannot read .fs header: ' + $_.Exception.Message) 'WARN'
    }
    $fsUserCode = Normalize-UserCode (Get-HeaderField -HeaderText $headerText -FieldName 'UserCode')
    $script:ResultData.fs_user_code = $fsUserCode
}

if (Test-Path -LiteralPath $GatesFile) {
    try {
        $gates = Get-Content -LiteralPath $GatesFile -Raw | ConvertFrom-Json
        if ($gates.bitstream -and $gates.bitstream.usercode) {
            $gateUserCode = Normalize-UserCode $gates.bitstream.usercode
        }
    } catch {
        Write-Log ('WARN: cannot parse gates_summary.json: ' + $_.Exception.Message) 'WARN'
    }
}
$script:ResultData.gate_user_code = $gateUserCode

$paramUserCode = Normalize-UserCode $ExpectedUserCode
$expectedUserCode = $null
$expectedSource = $null
if ($paramUserCode) {
    $expectedUserCode = $paramUserCode
    $expectedSource = '-ExpectedUserCode'
} elseif ($fsUserCode) {
    $expectedUserCode = $fsUserCode
    $expectedSource = '.fs header //UserCode'
} elseif ($gateUserCode) {
    $expectedUserCode = $gateUserCode
    $expectedSource = 'gates_summary.json bitstream.usercode'
}
$script:ResultData.expected_user_code = $expectedUserCode
$script:ResultData.expected_source = $expectedSource

if ($paramUserCode -and $fsUserCode -and ($paramUserCode -ne $fsUserCode)) {
    $Problems.Add("ExpectedUserCode $paramUserCode does not match .fs header UserCode $fsUserCode")
}
if ($fsUserCode -and $gateUserCode -and ($fsUserCode -ne $gateUserCode)) {
    Write-Log ("WARN: .fs header UserCode $fsUserCode != gates_summary.json $gateUserCode (fs header wins; summary may be stale)") 'WARN'
}
if (-not $expectedUserCode) {
    $Problems.Add('Cannot determine expected UserCode (no -ExpectedUserCode, no .fs header UserCode, no gates_summary.json)')
}

$cableArgs = @('--cable-index', [string]$CableIndex, '--cable', $CableName)
$baseArgs = @('--device', $Device, '--frequency', $Frequency) + $cableArgs

$scanArgs = @('--scan')
$op2Args = $baseArgs + @('--operation_index', '2', '--fsFile', $FsFile)
$op73Args = $baseArgs + @('--operation_index', '73')
$op69Args = $baseArgs + @('--operation_index', '69', '--fsFile', $FsFile)

function Show-Command {
    param([string]$Label, [string[]]$Arguments)
    $line = (($Arguments | ForEach-Object { Format-Arg $_ }) -join ' ')
    Write-Log ('  ' + $Label + ': "' + $ProgrammerExe + '" ' + $line)
}

Write-Log '--- resolved plan -------------------------------------------------'
Write-Log ('  fs            : ' + $FsFile)
Write-Log ('  fs bytes      : ' + $script:ResultData.fs_bytes)
Write-Log ('  fs mtime      : ' + $script:ResultData.fs_mtime)
Write-Log ('  fs sha256     : ' + $script:ResultData.fs_sha256)
Write-Log ('  fs user code  : ' + $fsUserCode)
Write-Log ('  gates usercode: ' + $gateUserCode)
Write-Log ('  expected code : ' + $expectedUserCode + ' (' + $expectedSource + ')')
Write-Log ('  device        : ' + $Device + '   cable-index: ' + $CableIndex + '   cable: ' + $CableName + '   freq: ' + $Frequency)
Show-Command 'scan  ' $scanArgs
Show-Command 'op2   ' $op2Args
Show-Command 'op73  ' $op73Args
Show-Command 'op69  ' $op69Args
Write-Log '--- hardware preconditions ----------------------------------------'
Write-Log '  1) SW2 = 001011 (Flash programming mode) before any programming.'
Write-Log '  2) JTAG cable must be enumerated: programmer_cli.exe --scan must report "device(s) found".'
Write-Log '  3) If JTAG is locked by SecurityBit, power the board off, wait 5 s, power on, retry.'
Write-Log '  4) op69 takes ~380-400 s (v7: 388.63 s); never interrupt it.'
Write-Log '  5) After op69: op73 reads 0x00000000 (GAO bridge loaded in SRAM) -- this is normal.'
Write-Log '  6) Self-boot check: SW2=100001 + real DC power cycle 5 s, then re-run this script with -VerifyOnly.'

if ($Problems.Count -gt 0) {
    foreach ($p in $Problems) { Write-Log ('PREFLIGHT PROBLEM: ' + $p) 'ERROR' }
    Stop-Burn -Stage 'preflight' -Reason ($Problems -join '; ') -ExitCode 2
}

# ---------------------------------------------------------------- stage 1: scan (read only)
Write-Log '--- stage 1/4: --scan (read only) ----------------------------------'
$scanRun = Invoke-Programmer -Name 'scan' -Arguments $scanArgs -TimeoutSeconds $ScanTimeoutSeconds
Write-ProgrammerRun $scanRun

$scanText = $scanRun.StandardOutput
$scanOk = $false
if ($scanText -notmatch 'No Gowin devices found' -and $scanText -match '\d+\s+device\(s\)\s+found' -and $scanRun.ExitCode -eq 0) {
    $scanOk = $true
}
$script:ResultData.scan = [string]$scanOk

if (-not $scanOk) {
    $scanReason = 'no Gowin device found (JTAG cable not enumerated or board not powered)'
    if ($scanRun.TimedOut) { $scanReason = 'scan timed out after ' + $ScanTimeoutSeconds + ' s' }
    if ($Mode -eq 'DRY-RUN') {
        Write-Log ('DRY RUN: scan did not find a device (' + $scanReason + '). This is expected while the JTAG cable is unplugged; the plan above is unchanged.') 'WARN'
    } else {
        Stop-Burn -Stage 'scan' -Reason $scanReason -ExitCode 3
    }
} else {
    Write-Log 'scan: Gowin device found' 'INFO'
}

if ($Mode -eq 'DRY-RUN') {
    Write-Log 'DRY RUN: no programming performed (use -Execute to burn).'
    Write-ResultFile -Verdict 'DRY-RUN' -Reason 'rehearsal only; scan performed, nothing programmed' -Tail ''
    Write-Log ('dry-run result file: ' + $script:ResultFile)
    exit 0
}

if ($Mode -eq 'VERIFY-ONLY') {
    Write-Log '--- verify-only: op73 Read User Code -------------------------------'
    $vRun = Invoke-Programmer -Name 'op73' -Arguments $op73Args -TimeoutSeconds $Op73TimeoutSeconds
    Write-ProgrammerRun $vRun
    $vCode = Get-UserCodeFromText $vRun.StandardOutput
    $script:ResultData.op73_user_code = $vCode
    $script:ResultData.op73_elapsed_s = $vRun.ElapsedSeconds
    if ([string]::IsNullOrEmpty($vCode)) {
        Stop-Burn -Stage 'op73' -Reason 'op73 output has no "User Code is: 0x........" line' -ExitCode 5
    }
    $match = ($vCode -eq $expectedUserCode)
    $script:ResultData.op73_match = [string]$match
    Write-ResultFile -Verdict $(if ($match) { 'SUCCESS' } else { 'FAILED at op73' }) -Reason $(if ($match) { 'self-boot UserCode matches expected' } else { "UserCode $vCode != expected $expectedUserCode" }) -Tail ''
    if ($match) { Write-Log 'verify-only: UserCode matches expected' 'INFO'; exit 0 }
    Write-Log ("verify-only: UserCode $vCode != expected $expectedUserCode") 'ERROR'
    exit 5
}

# ---------------------------------------------------------------- stage 2: op2 SRAM program
Write-Log '--- stage 2/4: op2 SRAM Program ------------------------------------'
$op2Run = Invoke-Programmer -Name 'op2-sram-program' -Arguments $op2Args -TimeoutSeconds $Op2TimeoutSeconds
Write-ProgrammerRun $op2Run
$script:ResultData.op2_elapsed_s = $op2Run.ElapsedSeconds
$op2Text = $op2Run.StandardOutput
$op2UserCode = Get-UserCodeFromText $op2Text
$script:ResultData.op2_user_code = $op2UserCode
$op2Cost = Get-CostSeconds $op2Text

$op2Ok = $false
if ($op2Run.ExitCode -eq 0 -and -not $op2Run.TimedOut -and $op2Text -match 'Finished\.' -and $op2Text -notmatch 'Error:') {
    $op2Ok = $true
}
$script:ResultData.op2 = [string]$op2Ok
if (-not $op2Ok) {
    $why = 'exit code ' + $op2Run.ExitCode
    if ($op2Run.TimedOut) { $why = 'timed out after ' + $Op2TimeoutSeconds + ' s' }
    if ($op2Text -match 'Error:[^\r\n]*') { $why = $why + ' / ' + $Matches[0] }
    Stop-Burn -Stage 'op2' -Reason ('SRAM program failed: ' + $why) -ExitCode 4 -Tail (Get-TailLines $op2Text 6)
}
Write-Log ('op2: SRAM program reported success (exit 0, cost_s=' + $op2Cost + ', user_code_in_op2=' + $op2UserCode + ')')

# ---------------------------------------------------------------- stage 3: op73 Read User Code
Write-Log '--- stage 3/4: op73 Read User Code (verify) -------------------------'
$op73Run = Invoke-Programmer -Name 'op73-read-user-code' -Arguments $op73Args -TimeoutSeconds $Op73TimeoutSeconds
Write-ProgrammerRun $op73Run
$script:ResultData.op73_elapsed_s = $op73Run.ElapsedSeconds
$readCode = Get-UserCodeFromText $op73Run.StandardOutput
$script:ResultData.op73_user_code = $readCode
if ([string]::IsNullOrEmpty($readCode)) {
    Stop-Burn -Stage 'op73' -Reason 'op73 output has no "User Code is: 0x........" line' -ExitCode 5
}
$match = ($readCode -eq $expectedUserCode)
$script:ResultData.op73_match = [string]$match
if (-not $match) {
    Stop-Burn -Stage 'op73' -Reason ("UserCode readback $readCode != expected $expectedUserCode (wrong bitstream on device?)") -ExitCode 5
}
Write-Log ('op73: UserCode ' + $readCode + ' matches expected ' + $expectedUserCode)

# ---------------------------------------------------------------- stage 4: op69 external Flash
Write-Log '--- stage 4/4: op69 exFlash Erase,Program,Verify thru GAO-Bridge 5A ---'
Write-Log ('op69 start; this takes ~380-400 s. DO NOT interrupt, do not unplug the cable.')
$op69Run = Invoke-Programmer -Name 'op69-exflash-program' -Arguments $op69Args -TimeoutSeconds $Op69TimeoutSeconds
Write-ProgrammerRun $op69Run
$script:ResultData.op69_elapsed_s = $op69Run.ElapsedSeconds
$op69Text = $op69Run.StandardOutput
$op69Cost = Get-CostSeconds $op69Text
$script:ResultData.op69_cost_s = $op69Cost
$op69Tail = Get-TailLines $op69Text 12

$successMarker = 'Program and Verify flash successfully.'
$op69Ok = $false
if ($op69Run.ExitCode -eq 0 -and -not $op69Run.TimedOut -and $op69Text.Contains($successMarker)) {
    $op69Ok = $true
}
$script:ResultData.op69 = [string]$op69Ok
if (-not $op69Ok) {
    $why = 'flash program failed: exit code ' + $op69Run.ExitCode
    if ($op69Run.TimedOut) { $why = 'flash program timed out after ' + $Op69TimeoutSeconds + ' s' }
    if (-not $op69Text.Contains($successMarker)) { $why = $why + ' / success marker not found' }
    Stop-Burn -Stage 'op69' -Reason $why -ExitCode 6 -Tail $op69Tail
}

Write-Log ('op69: SUCCESS (' + $successMarker + ') cost_s=' + $op69Cost + ' elapsed_s=' + $op69Run.ElapsedSeconds)
Write-ResultFile -Verdict 'SUCCESS' -Reason 'op2 SRAM + op73 UserCode match + op69 Flash all succeeded' -Tail $op69Tail
Write-Log ('RESULT FILE: ' + $script:ResultFile)
Write-Log ('next: SW2=100001 + real DC power cycle 5 s, then -VerifyOnly (expect op73 = ' + $expectedUserCode + ')')
Write-Log 'burn_v10.ps1 finished: SUCCESS'
exit 0
