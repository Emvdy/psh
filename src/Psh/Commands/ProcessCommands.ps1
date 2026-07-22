# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# Process-command wrappers deliberately receive native-style arguments through
# $args.  This keeps PowerShell's parameter binder from consuming or rewriting
# switches that belong to the compatibility surface.

$script:PshProcessCommandNames = @('ps', 'kill', 'pgrep', 'pkill', 'timeout')

function Get-PshEnabledProcessCommandNames {
    $enabled = @()
    foreach ($name in $script:PshProcessCommandNames) {
        if (-not $script:PshDisabledCommands.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function ConvertTo-PshProcessArgumentArray {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object[]]$InputArguments
    )

    # Use the project helper when it is available; retaining this tiny fallback
    # keeps direct dot-sourcing of this source file useful in focused tests.
    $converter = Get-Command -Name ConvertTo-PshArgumentArray -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $converter) {
        return @(ConvertTo-PshArgumentArray -InputArguments $InputArguments)
    }

    $result = @()
    foreach ($argument in @($InputArguments)) {
        if ($null -eq $argument) { $result += '' }
        else { $result += [string]$argument }
    }
    return $result
}

function Write-PshProcessFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $failure = Get-Command -Name Write-PshCommandFailure -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $failure) {
        Write-PshCommandFailure -Command $Command -Code $Code -Message $Message
        return
    }

    Write-Output ('{0}: {1}' -f $Command, (($Message -replace '[\r\n]+', ' ').Trim()))
    $global:LASTEXITCODE = $Code
}

function Write-PshProcessHelp {
    param(
        [Parameter(Mandatory = $true)][string]$Usage
    )

    $helper = Get-Command -Name Write-PshCommandHelp -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $helper) {
        Write-PshCommandHelp -Usage $Usage
        return
    }

    Write-Output $Usage
    $global:LASTEXITCODE = 0
}

function Test-PshProcessHelp {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments
    )

    return ($Arguments.Count -eq 1 -and $Arguments[0] -ceq '--help')
}

function Get-PshProcessList {
    [Diagnostics.Process[]]$processes = @()
    try {
        $processes = @([Diagnostics.Process]::GetProcesses())
    }
    catch {
        return @()
    }
    return $processes
}

function Get-PshWindowsProcessWmiRecord {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    if ($ProcessId -le 0 -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $null }
    $searcher = $null
    $results = $null
    try {
        Add-Type -AssemblyName System.Management -ErrorAction Stop
        $queryText = 'SELECT CommandLine, ParentProcessId FROM Win32_Process WHERE ProcessId = {0}' -f $ProcessId
        $searcher = New-Object System.Management.ManagementObjectSearcher -ArgumentList @($queryText)
        $results = $searcher.Get()
        foreach ($result in $results) {
            return [pscustomobject]@{
                CommandLine = [string]$result.Properties['CommandLine'].Value
                ParentProcessId = [int]$result.Properties['ParentProcessId'].Value
            }
        }
    }
    catch { return $null }
    finally {
        if ($results -is [IDisposable]) { $results.Dispose() }
        if ($searcher -is [IDisposable]) { $searcher.Dispose() }
    }
    return $null
}

function Get-PshWindowsProcessRecord {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    if ($ProcessId -le 0 -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $null }
    $record = $null
    try { $record = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $ProcessId) -ErrorAction Stop }
    catch { $record = $null }
    if ($null -ne $record) { return $record }
    return Get-PshWindowsProcessWmiRecord -ProcessId $ProcessId
}

function Get-PshProcessText {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [switch]$FullCommand,
        [switch]$Long
    )

    $name = ''
    $path = ''
    $commandLine = ''
    try { $name = [string]$Process.ProcessName } catch { $name = '' }
    if ($FullCommand -or $Long) {
        try {
            $path = [string]$Process.MainModule.FileName
        }
        catch { $path = '' }
    }
    if ($FullCommand) {
        $commandLine = [string](Get-PshProcessCommandLine -Process $Process)
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = '<unknown>' }
    if ($Long) {
        if ([string]::IsNullOrWhiteSpace($path)) { $path = $name }
        return ('{0,6} {1,-24} {2}' -f $Process.Id, $name, $path)
    }
    if ($FullCommand -and -not [string]::IsNullOrWhiteSpace($commandLine)) {
        return ('{0} {1}' -f $Process.Id, $commandLine)
    }
    return ('{0} {1}' -f $Process.Id, $name)
}

function ps {
    $arguments = @(ConvertTo-PshProcessArgumentArray -InputArguments $args)
    $global:LASTEXITCODE = 0
    if (Test-PshProcessHelp -Arguments $arguments) {
        Write-PshProcessHelp -Usage 'Usage: ps [-aefl] [-p PID]'
        return
    }

    $all = $false
    $every = $false
    $full = $false
    $long = $false
    $pids = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $token = [string]$arguments[$index]
        if ($parseOptions -and $token -ceq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $token -ceq '-a') { $all = $true; continue }
        if ($parseOptions -and $token -ceq '-e') { $every = $true; continue }
        if ($parseOptions -and $token -ceq '-f') { $full = $true; continue }
        if ($parseOptions -and $token -ceq '-l') { $long = $true; continue }
        if ($parseOptions -and ($token -ceq '-p' -or $token.StartsWith('-p='))) {
            if ($token.StartsWith('-p=')) { $pidText = $token.Substring(3) }
            else {
                $index++
                if ($index -ge $arguments.Count) {
                    Write-PshProcessFailure -Command 'ps' -Code 2 -Message '-p requires a process id.'
                    return
                }
                $pidText = [string]$arguments[$index]
            }
            foreach ($part in @($pidText -split ',')) {
                $parsedPid = 0
                if (-not [int]::TryParse($part, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedPid) -or $parsedPid -le 0) {
                    Write-PshProcessFailure -Command 'ps' -Code 2 -Message ('invalid process id "{0}".' -f $part)
                    return
                }
                $pids += $parsedPid
            }
            continue
        }
        if ($parseOptions -and $token.Length -gt 1 -and $token[0] -eq '-' -and -not $token.StartsWith('--')) {
            # Accept conventional clusters such as -ef and -al.
            $expanded = $true
            for ($shortIndex = 1; $shortIndex -lt $token.Length; $shortIndex++) {
                switch ([string]$token[$shortIndex]) {
                    'a' { $all = $true }
                    'e' { $every = $true }
                    'f' { $full = $true }
                    'l' { $long = $true }
                    default { $expanded = $false }
                }
            }
            if ($expanded) { continue }
        }
        Write-PshProcessFailure -Command 'ps' -Code 2 -Message ('unsupported argument "{0}".' -f $token)
        return
    }

    $processes = @(Get-PshProcessList)
    if ($pids.Count -gt 0) {
        $selected = @()
        foreach ($requestedPid in $pids) {
            $selected += @($processes | Where-Object { $_.Id -eq $requestedPid })
        }
        $processes = @($selected)
    }
    elseif (-not ($all -or $every)) {
        # The default is the current process and its direct parent where that
        # relationship can be observed.  This is deterministic and avoids
        # exposing unrelated process rows by default.
        $currentId = [Diagnostics.Process]::GetCurrentProcess().Id
        $parentId = Get-PshProcessParentId -ProcessId $currentId
        $processes = @($processes | Where-Object { $_.Id -eq $currentId -or ($parentId -gt 0 -and $_.Id -eq $parentId) })
    }

    $processes = @($processes | Sort-Object -Property Id)
    if ($pids.Count -gt 0 -and $processes.Count -eq 0) {
        $global:LASTEXITCODE = 1
        return
    }
    if ($long) {
        Write-Output '   PID NAME                     PATH'
    }
    foreach ($process in $processes) {
        Write-Output ([string](Get-PshProcessText -Process $process -FullCommand:$full -Long:$long))
        try { $process.Dispose() } catch { }
    }
    $global:LASTEXITCODE = 0
}

function Set-PshProcessExitCode {
    param(
        [Parameter(Mandatory = $true)][int]$Code
    )

    # Native children may return arbitrary values.  Psh exposes only the
    # documented 0..5 result space; preserve the common values and classify
    # everything else as a runtime failure.
    $normalized = $Code
    if ($normalized -lt 0 -or $normalized -gt 5) { $normalized = 3 }
    $setter = Get-Command -Name Set-PshLastExitCode -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $setter) { Set-PshLastExitCode -Code $normalized }
    else { $global:LASTEXITCODE = $normalized }
}

function Get-PshProcessCommandLine {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process
    )

    $value = ''
    try {
        $property = $Process.PSObject.Properties['CommandLine']
        if ($null -ne $property -and $null -ne $property.Value) { $value = [string]$property.Value }
    }
    catch { $value = '' }
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }

    # Linux exposes argv without requiring a native helper.  The file is
    # unavailable on Windows and macOS, where the CIM/WMI path below is used.
    try {
        $procCommandLinePath = Join-Path -Path '/proc' -ChildPath ([string]$Process.Id)
        $procCommandLinePath = Join-Path -Path $procCommandLinePath -ChildPath 'cmdline'
        if ([IO.File]::Exists($procCommandLinePath)) {
            $bytes = [IO.File]::ReadAllBytes($procCommandLinePath)
            if ($bytes.Length -gt 0) {
                $value = (New-Object Text.UTF8Encoding($false)).GetString($bytes).Replace([char]0, ' ').Trim()
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
            }
        }
    }
    catch { }

    $query = Get-PshWindowsProcessRecord -ProcessId $Process.Id
    if ($null -ne $query) {
        try {
            $value = [string]$query.CommandLine
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
        catch { }
    }
    return ''
}

function Get-PshProcessUserName {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process
    )

    $value = ''
    try {
        $property = $Process.PSObject.Properties['UserName']
        if ($null -ne $property -and $null -ne $property.Value) { $value = [string]$property.Value }
    }
    catch { $value = '' }
    if ([string]::IsNullOrWhiteSpace($value) -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            $withUser = Get-Process -Id $Process.Id -IncludeUserName -ErrorAction Stop
            $value = [string]$withUser.UserName
        }
        catch { $value = '' }
    }
    if ([string]::IsNullOrWhiteSpace($value) -and $Process.Id -eq $PID) {
        if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) { $value = [string]$env:USERNAME }
        elseif (-not [string]::IsNullOrWhiteSpace($env:USER)) { $value = [string]$env:USER }
    }
    return $value
}

function Get-PshProcessUid {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process
    )

    try {
        $statusPath = Join-Path -Path '/proc' -ChildPath ([string]$Process.Id)
        $statusPath = Join-Path -Path $statusPath -ChildPath 'status'
        if ([IO.File]::Exists($statusPath)) {
            foreach ($line in [IO.File]::ReadAllLines($statusPath)) {
                if ($line -match '^Uid:\s+([0-9]+)') { return [string]$Matches[1] }
            }
        }
    }
    catch { }
    return ''
}

function Get-PshProcessParentId {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    if ($ProcessId -le 0) { return 0 }
    $query = Get-PshWindowsProcessRecord -ProcessId $ProcessId
    if ($null -ne $query) {
        try { return [int]$query.ParentProcessId } catch { }
    }

    # /proc/<pid>/stat field 4 is the parent PID.  The process name may contain
    # spaces and closing parentheses, so locate the final ')' before splitting.
    try {
        $statPath = Join-Path -Path '/proc' -ChildPath ([string]$ProcessId)
        $statPath = Join-Path -Path $statPath -ChildPath 'stat'
        if ([IO.File]::Exists($statPath)) {
            $statText = [IO.File]::ReadAllText($statPath)
            $close = $statText.LastIndexOf(')')
            if ($close -ge 0 -and $close + 2 -lt $statText.Length) {
                $fields = $statText.Substring($close + 2).Split(' ')
                if ($fields.Count -gt 1) {
                    $parent = 0
                    if ([int]::TryParse($fields[1], [ref]$parent)) { return $parent }
                }
            }
        }
    }
    catch { }
    return 0
}

function New-PshProcessRecord {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process
    )

    $id = 0
    try { $id = [int]$Process.Id } catch { return $null }
    $name = ''
    try { $name = [string]$Process.ProcessName } catch { }
    $path = ''
    try {
        $pathProperty = $Process.PSObject.Properties['Path']
        if ($null -ne $pathProperty -and $null -ne $pathProperty.Value) { $path = [string]$pathProperty.Value }
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($path)) {
        try { $path = [string]$Process.MainModule.FileName } catch { }
    }
    $startTime = [DateTime]::MinValue
    try { $startTime = [DateTime]$Process.StartTime.ToUniversalTime() } catch { }
    $sessionId = -1
    try { $sessionId = [int]$Process.SessionId } catch { }
    return [PSCustomObject]@{
        Process     = $Process
        Id          = $id
        Name        = $name
        Path        = $path
        CommandLine = [string](Get-PshProcessCommandLine -Process $Process)
        User        = [string](Get-PshProcessUserName -Process $Process)
        Uid         = [string](Get-PshProcessUid -Process $Process)
        SessionId   = $sessionId
        ParentId    = [int](Get-PshProcessParentId -ProcessId $id)
        StartTime   = $startTime
    }
}

function Get-PshProcessRecords {
    $records = @()
    foreach ($process in @(Get-PshProcessList)) {
        try {
            $record = New-PshProcessRecord -Process $process
            if ($null -ne $record) { $records += $record }
            else { try { $process.Dispose() } catch { } }
        }
        catch {
            try { $process.Dispose() } catch { }
        }
    }
    return $records
}

function Get-PshProtectedProcessIds {
    $protected = @()
    $currentId = 0
    try { $currentId = [Diagnostics.Process]::GetCurrentProcess().Id } catch { $currentId = $PID }
    if ($currentId -gt 0) { $protected += $currentId }
    $next = $currentId
    for ($depth = 0; $depth -lt 32 -and $next -gt 1; $depth++) {
        $parent = Get-PshProcessParentId -ProcessId $next
        if ($parent -le 0 -or $parent -eq $next -or $protected -contains $parent) { break }
        $protected += $parent
        $next = $parent
    }
    # PID 1 is a system supervisor on Unix and a reserved process on Windows.
    if ($protected -notcontains 1) { $protected += 1 }
    return @($protected | Select-Object -Unique)
}

function Test-PshProcessNotFoundException {
    param(
        [Parameter(Mandatory = $true)][Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [ArgumentException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function ConvertTo-PshSignalNumber {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    $text = $Value.Trim()
    if ($text.StartsWith('SIG', [StringComparison]::OrdinalIgnoreCase)) { $text = $text.Substring(3) }
    $number = 0
    if ([int]::TryParse($text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        if ($number -ge 0 -and $number -le 64) { return $number }
        return -1
    }
    switch -Regex ($text.ToUpperInvariant()) {
        '^HUP$' { return 1 }
        '^INT$' { return 2 }
        '^QUIT$' { return 3 }
        '^ILL$' { return 4 }
        '^ABRT$' { return 6 }
        '^KILL$' { return 9 }
        '^SEGV$' { return 11 }
        '^PIPE$' { return 13 }
        '^ALRM$' { return 14 }
        '^TERM$' { return 15 }
        '^CHLD$' { return 17 }
        '^CONT$' { return 18 }
        '^STOP$' { return 19 }
        '^TSTP$' { return 20 }
        '^TTIN$' { return 21 }
        '^TTOU$' { return 22 }
        default { return -1 }
    }
}

function Test-PshTerminationSignal {
    param(
        [Parameter(Mandatory = $true)][int]$Signal,
        [switch]$AllowProbe
    )

    if ($Signal -in @(1, 2, 9, 15)) { return $true }
    if ($AllowProbe -and $Signal -eq 0) { return $true }
    return $false
}

function Assert-PshTerminationSignal {
    param(
        [Parameter(Mandatory = $true)][int]$Signal,
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AllowProbe
    )

    if (Test-PshTerminationSignal -Signal $Signal -AllowProbe:$AllowProbe) { return }
    $allowed = 'HUP, INT, KILL, TERM'
    if ($AllowProbe) { $allowed += ', or 0 for a probe' }
    throw ('{0} does not support signal {1}; supported signals are {2}.' -f $Command, $Signal, $allowed)
}

function Get-PshSignalName {
    param(
        [Parameter(Mandatory = $true)][int]$Number
    )

    switch ($Number) {
        0 { return '0' }
        1 { return 'HUP' }
        2 { return 'INT' }
        3 { return 'QUIT' }
        4 { return 'ILL' }
        6 { return 'ABRT' }
        9 { return 'KILL' }
        11 { return 'SEGV' }
        13 { return 'PIPE' }
        14 { return 'ALRM' }
        15 { return 'TERM' }
        17 { return 'CHLD' }
        18 { return 'CONT' }
        19 { return 'STOP' }
        20 { return 'TSTP' }
        21 { return 'TTIN' }
        22 { return 'TTOU' }
        default { return [string]$Number }
    }
}

function Test-PshProcessRecordUser {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Users
    )

    if ($Users.Count -eq 0) { return $true }
    foreach ($requested in $Users) {
        if ([string]::Equals([string]$Record.User, $requested, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals([string]$Record.Uid, $requested, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        # Windows usernames are commonly supplied as DOMAIN\\user while the
        # process API may expose only the final component (or vice versa).
        $recordTail = ([string]$Record.User -split '\\')[-1]
        $requestedTail = ($requested -split '\\')[-1]
        if ([string]::Equals($recordTail, $requestedTail, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-PshProcessRecordPattern {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [switch]$Full,
        [switch]$IgnoreCase
    )

    $text = if ($Full) {
        if ([string]::IsNullOrWhiteSpace([string]$Record.CommandLine)) {
            '{0} {1}' -f [string]$Record.Path, [string]$Record.Name
        }
        else { [string]$Record.CommandLine }
    }
    else { [string]$Record.Name }
    $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($IgnoreCase) { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
    try { return [Text.RegularExpressions.Regex]::IsMatch($text, $Pattern, $options) }
    catch { throw ('invalid process pattern "{0}": {1}' -f $Pattern, $_.Exception.Message) }
}

function Send-PshProcessSignal {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$Signal
    )

    # Never translate an unsupported signal into an unconditional Kill.
    if (-not (Test-PshTerminationSignal -Signal $Signal -AllowProbe)) { return $false }
    if ($Signal -eq 0) {
        try { return (-not $Process.HasExited) } catch { return $false }
    }
    try {
        if ($Process.HasExited) { return $false }
    }
    catch { return $false }

    # Process.Kill is the only portable .NET termination primitive and is
    # available in WinPS 5.1.  For a supported graceful signal, give a
    # console/windowed process a chance to close first, then use Kill as a
    # deterministic fallback.
    if ($Signal -in @(1, 2, 15)) {
        try {
            $closed = $Process.CloseMainWindow()
            if ($closed) {
                if ($Process.WaitForExit(250)) { return $true }
            }
        }
        catch { }
    }
    try {
        $Process.Kill()
        try { $Process.WaitForExit(2000) } catch { }
        return $true
    }
    catch { return $false }
}

function ConvertTo-PshProcessPidList {
    param(
        [Parameter(Mandatory = $true)][string[]]$Values
    )

    $result = @()
    foreach ($value in $Values) {
        foreach ($piece in @(([string]$value -split ','))) {
            $pidValue = 0
            if (-not [int]::TryParse($piece.Trim(), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$pidValue) -or $pidValue -le 0) {
                throw ('invalid process id "{0}".' -f $piece)
            }
            $result += $pidValue
        }
    }
    return @($result | Select-Object -Unique)
}

function ConvertTo-PshProcessDurationMilliseconds {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$OptionName
    )

    $text = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw ('{0} requires a duration.' -f $OptionName) }
    $multiplier = 1000.0
    $numberText = $text
    if ($text -match '(?i)^(.*)ms$') { $multiplier = 1.0; $numberText = $Matches[1] }
    elseif ($text -match '(?i)^(.*)s$') { $multiplier = 1000.0; $numberText = $Matches[1] }
    elseif ($text -match '(?i)^(.*)m$') { $multiplier = 60000.0; $numberText = $Matches[1] }
    elseif ($text -match '(?i)^(.*)h$') { $multiplier = 3600000.0; $numberText = $Matches[1] }
    elseif ($text -match '(?i)^(.*)d$') { $multiplier = 86400000.0; $numberText = $Matches[1] }
    $seconds = 0.0
    if (-not [double]::TryParse($numberText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -or [double]::IsNaN($seconds) -or [double]::IsInfinity($seconds) -or $seconds -lt 0) {
        throw ('{0} requires a non-negative duration.' -f $OptionName)
    }
    $millisecondsDouble = $seconds * $multiplier
    if ($millisecondsDouble -gt [int]::MaxValue) { throw ('{0} is too large.' -f $OptionName) }
    if ($millisecondsDouble -eq 0) { return 0 }
    return [int][Math]::Ceiling($millisecondsDouble)
}

function pgrep {
    $arguments = @(ConvertTo-PshProcessArgumentArray -InputArguments $args)
    Set-PshProcessExitCode -Code 0
    if (Test-PshProcessHelp -Arguments $arguments) {
        Write-PshProcessHelp -Usage 'Usage: pgrep [-filno] [-u USER] pattern'
        return
    }

    $full = $false
    $ignoreCase = $false
    $listName = $false
    $newest = $false
    $oldest = $false
    $users = @()
    $pattern = $null
    $parseOptions = $true
    $index = 0
    try {
        while ($index -lt $arguments.Count) {
            $token = [string]$arguments[$index]
            if ($parseOptions -and $token -ceq '--') {
                $parseOptions = $false
                $index++
                continue
            }
            if ($parseOptions -and $token -ceq '-f') { $full = $true; $index++; continue }
            if ($parseOptions -and $token -ceq '-i') { $ignoreCase = $true; $index++; continue }
            if ($parseOptions -and $token -ceq '-l') { $listName = $true; $index++; continue }
            if ($parseOptions -and $token -ceq '-n') { $newest = $true; $index++; continue }
            if ($parseOptions -and $token -ceq '-o') { $oldest = $true; $index++; continue }
            if ($parseOptions -and ($token -ceq '-u' -or $token.StartsWith('-u='))) {
                if ($token.StartsWith('-u=')) { $userValue = $token.Substring(3) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '-u requires a user name or id.' }
                    $userValue = [string]$arguments[$index]
                }
                if ([string]::IsNullOrWhiteSpace($userValue)) { throw '-u requires a user name or id.' }
                foreach ($user in @($userValue -split ',')) {
                    if (-not [string]::IsNullOrWhiteSpace($user)) { $users += $user.Trim() }
                }
                $index++
                continue
            }
            if ($parseOptions -and $token.Length -gt 1 -and $token[0] -eq '-' -and -not $token.StartsWith('--')) {
                $clusterOk = $true
                $shortIndex = 1
                while ($shortIndex -lt $token.Length) {
                    $short = [string]$token[$shortIndex]
                    switch ($short) {
                        'f' { $full = $true; $shortIndex++ }
                        'i' { $ignoreCase = $true; $shortIndex++ }
                        'l' { $listName = $true; $shortIndex++ }
                        'n' { $newest = $true; $shortIndex++ }
                        'o' { $oldest = $true; $shortIndex++ }
                        'u' {
                            $attached = ''
                            if ($shortIndex + 1 -lt $token.Length) { $attached = $token.Substring($shortIndex + 1); $shortIndex = $token.Length }
                            else {
                                $index++
                                if ($index -ge $arguments.Count) { throw '-u requires a user name or id.' }
                                $attached = [string]$arguments[$index]
                            }
                            if ([string]::IsNullOrWhiteSpace($attached)) { throw '-u requires a user name or id.' }
                            foreach ($user in @($attached -split ',')) {
                                if (-not [string]::IsNullOrWhiteSpace($user)) { $users += $user.Trim() }
                            }
                            $shortIndex = $token.Length
                        }
                        default { $clusterOk = $false; $shortIndex = $token.Length }
                    }
                }
                if ($clusterOk) { $index++; continue }
            }
            if ($parseOptions -and $token.StartsWith('-', [StringComparison]::Ordinal) -and $token -ne '-') {
                throw ('unsupported argument "{0}".' -f $token)
            }
            if ($null -eq $pattern) { $pattern = $token }
            else { throw 'pgrep accepts exactly one pattern.' }
            $parseOptions = $false
            $index++
        }
        if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'a process pattern is required.' }
        if ($newest -and $oldest) { throw '-n and -o cannot be combined.' }
        # Validate before touching the process table so malformed patterns are
        # consistently usage errors even when no process is running.
        $null = [Text.RegularExpressions.Regex]::Match('', $pattern)
    }
    catch {
        Write-PshProcessFailure -Command 'pgrep' -Code 2 -Message $_.Exception.Message
        return
    }

    $records = @(Get-PshProcessRecords)
    try {
        $matches = @()
        foreach ($record in $records) {
            if (-not (Test-PshProcessRecordUser -Record $record -Users $users)) { continue }
            try {
                if (Test-PshProcessRecordPattern -Record $record -Pattern $pattern -Full:$full -IgnoreCase:$ignoreCase) {
                    $matches += $record
                }
            }
            catch {
                Write-PshProcessFailure -Command 'pgrep' -Code 2 -Message $_.Exception.Message
                return
            }
        }
        if ($newest -or $oldest) {
            if ($matches.Count -gt 0) {
                $chosen = $matches[0]
                foreach ($candidate in $matches) {
                    $candidateTime = [DateTime]$candidate.StartTime
                    $chosenTime = [DateTime]$chosen.StartTime
                    if ($newest) {
                        if ($candidateTime -gt $chosenTime -or ($candidateTime -eq $chosenTime -and [int]$candidate.Id -gt [int]$chosen.Id)) { $chosen = $candidate }
                    }
                    else {
                        if ($candidateTime -lt $chosenTime -or ($candidateTime -eq $chosenTime -and [int]$candidate.Id -lt [int]$chosen.Id)) { $chosen = $candidate }
                    }
                }
                $matches = @($chosen)
            }
        }
        else {
            $matches = @($matches | Sort-Object -Property Id)
        }
        if ($matches.Count -eq 0) {
            Set-PshProcessExitCode -Code 1
            return
        }
        foreach ($record in $matches) {
            if ($listName) { Write-Output ('{0} {1}' -f [int]$record.Id, [string]$record.Name) }
            else { Write-Output ([string]$record.Id) }
        }
        Set-PshProcessExitCode -Code 0
    }
    finally {
        foreach ($record in $records) {
            try { $record.Process.Dispose() } catch { }
        }
    }
}

function pkill {
    $arguments = @(ConvertTo-PshProcessArgumentArray -InputArguments $args)
    Set-PshProcessExitCode -Code 0
    if (Test-PshProcessHelp -Arguments $arguments) {
        Write-PshProcessHelp -Usage 'Usage: pkill [-finou] [-s SESSION] [--signal SIGNAL] pattern'
        return
    }

    $full = $false
    $ignoreCase = $false
    $newest = $false
    $oldest = $false
    $users = @()
    $sessions = @()
    $signal = 15
    $pattern = $null
    $parseOptions = $true
    $index = 0
    try {
        while ($index -lt $arguments.Count) {
            $token = [string]$arguments[$index]
            if ($parseOptions -and $token -ceq '--') {
                $parseOptions = $false
                $index++
                continue
            }
            if ($parseOptions -and $token -ceq '-f') { $full = $true; $index++; continue }
            if ($parseOptions -and $token -ceq '-i') { $ignoreCase = $true; $index++; continue }
            if ($parseOptions -and $token -ceq '-n') { $newest = $true; $index++; continue }
            if ($parseOptions -and $token -ceq '-o') { $oldest = $true; $index++; continue }
            if ($parseOptions -and ($token -ceq '-u' -or $token.StartsWith('-u='))) {
                if ($token.StartsWith('-u=')) { $userValue = $token.Substring(3) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '-u requires a user name or id.' }
                    $userValue = [string]$arguments[$index]
                }
                if ([string]::IsNullOrWhiteSpace($userValue)) { throw '-u requires a user name or id.' }
                foreach ($user in @($userValue -split ',')) {
                    if (-not [string]::IsNullOrWhiteSpace($user)) { $users += $user.Trim() }
                }
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '-s' -or $token.StartsWith('-s='))) {
                if ($token.StartsWith('-s=')) { $sessionValue = $token.Substring(3) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '-s requires a session id.' }
                    $sessionValue = [string]$arguments[$index]
                }
                if ([string]::IsNullOrWhiteSpace($sessionValue)) { throw '-s requires a session id.' }
                foreach ($session in @($sessionValue -split ',')) {
                    $sessionId = 0
                    if (-not [int]::TryParse($session.Trim(), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$sessionId) -or $sessionId -lt 0) {
                        throw ('invalid session id "{0}".' -f $session)
                    }
                    $sessions += $sessionId
                }
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '--signal' -or $token.StartsWith('--signal='))) {
                if ($token.StartsWith('--signal=')) { $signalValue = $token.Substring(9) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '--signal requires a signal name or number.' }
                    $signalValue = [string]$arguments[$index]
                }
                $signal = ConvertTo-PshSignalNumber -Value $signalValue
                if ($signal -lt 0) { throw ('unknown signal "{0}".' -f $signalValue) }
                $index++
                continue
            }
            if ($parseOptions -and $token.Length -gt 1 -and $token[0] -eq '-' -and -not $token.StartsWith('--')) {
                $clusterOk = $true
                $shortIndex = 1
                while ($shortIndex -lt $token.Length) {
                    $short = [string]$token[$shortIndex]
                    switch ($short) {
                        'f' { $full = $true; $shortIndex++ }
                        'i' { $ignoreCase = $true; $shortIndex++ }
                        'n' { $newest = $true; $shortIndex++ }
                        'o' { $oldest = $true; $shortIndex++ }
                        'u' {
                            $attached = ''
                            if ($shortIndex + 1 -lt $token.Length) { $attached = $token.Substring($shortIndex + 1); $shortIndex = $token.Length }
                            else {
                                $index++
                                if ($index -ge $arguments.Count) { throw '-u requires a user name or id.' }
                                $attached = [string]$arguments[$index]
                            }
                            foreach ($user in @($attached -split ',')) {
                                if (-not [string]::IsNullOrWhiteSpace($user)) { $users += $user.Trim() }
                            }
                            $shortIndex = $token.Length
                        }
                        's' {
                            $attached = ''
                            if ($shortIndex + 1 -lt $token.Length) { $attached = $token.Substring($shortIndex + 1); $shortIndex = $token.Length }
                            else {
                                $index++
                                if ($index -ge $arguments.Count) { throw '-s requires a session id.' }
                                $attached = [string]$arguments[$index]
                            }
                            $sessionId = 0
                            if (-not [int]::TryParse($attached, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$sessionId) -or $sessionId -lt 0) { throw ('invalid session id "{0}".' -f $attached) }
                            $sessions += $sessionId
                            $shortIndex = $token.Length
                        }
                        default { $clusterOk = $false; $shortIndex = $token.Length }
                    }
                }
                if ($clusterOk) { $index++; continue }
            }
            if ($parseOptions -and $token.StartsWith('-', [StringComparison]::Ordinal) -and $token -ne '-') {
                throw ('unsupported argument "{0}".' -f $token)
            }
            if ($null -eq $pattern) { $pattern = $token }
            else { throw 'pkill accepts exactly one pattern.' }
            $parseOptions = $false
            $index++
        }
        if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'a process pattern is required.' }
        if ($newest -and $oldest) { throw '-n and -o cannot be combined.' }
        Assert-PshTerminationSignal -Signal $signal -Command 'pkill' -AllowProbe
        $null = [Text.RegularExpressions.Regex]::Match('', $pattern)
    }
    catch {
        Write-PshProcessFailure -Command 'pkill' -Code 2 -Message $_.Exception.Message
        return
    }

    $records = @(Get-PshProcessRecords)
    try {
        $protected = @(Get-PshProtectedProcessIds)
        $matches = @()
        foreach ($record in $records) {
            if ($protected -contains [int]$record.Id) { continue }
            if ($sessions.Count -gt 0 -and $sessions -notcontains [int]$record.SessionId) { continue }
            if (-not (Test-PshProcessRecordUser -Record $record -Users $users)) { continue }
            try {
                if (Test-PshProcessRecordPattern -Record $record -Pattern $pattern -Full:$full -IgnoreCase:$ignoreCase) { $matches += $record }
            }
            catch {
                Write-PshProcessFailure -Command 'pkill' -Code 2 -Message $_.Exception.Message
                return
            }
        }
        if ($newest -or $oldest) {
            if ($matches.Count -gt 0) {
                $chosen = $matches[0]
                foreach ($candidate in $matches) {
                    if ($newest) {
                        if ([DateTime]$candidate.StartTime -gt [DateTime]$chosen.StartTime -or ([DateTime]$candidate.StartTime -eq [DateTime]$chosen.StartTime -and [int]$candidate.Id -gt [int]$chosen.Id)) { $chosen = $candidate }
                    }
                    else {
                        if ([DateTime]$candidate.StartTime -lt [DateTime]$chosen.StartTime -or ([DateTime]$candidate.StartTime -eq [DateTime]$chosen.StartTime -and [int]$candidate.Id -lt [int]$chosen.Id)) { $chosen = $candidate }
                    }
                }
                $matches = @($chosen)
            }
        }
        if ($matches.Count -eq 0) {
            Set-PshProcessExitCode -Code 1
            return
        }
        $failed = $false
        foreach ($record in $matches) {
            if (-not (Send-PshProcessSignal -Process $record.Process -Signal $signal)) { $failed = $true }
        }
        if ($failed) { Set-PshProcessExitCode -Code 3 }
        else { Set-PshProcessExitCode -Code 0 }
    }
    finally {
        foreach ($record in $records) {
            try { $record.Process.Dispose() } catch { }
        }
    }
}

function kill {
    $arguments = @(ConvertTo-PshProcessArgumentArray -InputArguments $args)
    Set-PshProcessExitCode -Code 0
    if (Test-PshProcessHelp -Arguments $arguments) {
        Write-PshProcessHelp -Usage 'Usage: kill [-s SIGNAL|--signal SIGNAL] PID [...] | kill -l'
        return
    }

    $signal = 15
    $listSignals = $false
    $listValue = $null
    $pidValues = @()
    $parseOptions = $true
    $index = 0
    try {
        while ($index -lt $arguments.Count) {
            $token = [string]$arguments[$index]
            if ($parseOptions -and $token -ceq '--') {
                $parseOptions = $false
                $index++
                continue
            }
            if ($parseOptions -and $token -ceq '-l') {
                $listSignals = $true
                if ($index + 1 -lt $arguments.Count) {
                    $candidateListValue = [string]$arguments[$index + 1]
                    if (-not $candidateListValue.StartsWith('-', [StringComparison]::Ordinal)) {
                        $listValue = $candidateListValue
                        $index++
                    }
                }
                $index++
                continue
            }
            if ($parseOptions -and $token.StartsWith('-l=')) {
                $listSignals = $true
                $listValue = $token.Substring(3)
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '-s' -or $token.StartsWith('-s='))) {
                if ($token.StartsWith('-s=')) { $signalValue = $token.Substring(3) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '-s requires a signal name or number.' }
                    $signalValue = [string]$arguments[$index]
                }
                $signal = ConvertTo-PshSignalNumber -Value $signalValue
                if ($signal -lt 0) { throw ('unknown signal "{0}".' -f $signalValue) }
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '--signal' -or $token.StartsWith('--signal='))) {
                if ($token.StartsWith('--signal=')) { $signalValue = $token.Substring(9) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '--signal requires a signal name or number.' }
                    $signalValue = [string]$arguments[$index]
                }
                $signal = ConvertTo-PshSignalNumber -Value $signalValue
                if ($signal -lt 0) { throw ('unknown signal "{0}".' -f $signalValue) }
                $index++
                continue
            }
            if ($parseOptions -and $token.Length -gt 2 -and $token.StartsWith('-l')) {
                $listSignals = $true
                $listValue = $token.Substring(2)
                $index++
                continue
            }
            if ($parseOptions -and $token.StartsWith('-', [StringComparison]::Ordinal) -and $token -ne '-') {
                throw ('unsupported argument "{0}".' -f $token)
            }
            $pidValues += $token
            $index++
        }
        Assert-PshTerminationSignal -Signal $signal -Command 'kill' -AllowProbe
        if ($listSignals) {
            if ($pidValues.Count -gt 0) { throw 'kill -l does not accept process ids.' }
            if ([string]::IsNullOrWhiteSpace([string]$listValue)) {
                foreach ($number in @(1, 2, 3, 4, 6, 9, 11, 13, 14, 15, 17, 18, 19, 20, 21, 22)) {
                    Write-Output ([string](Get-PshSignalName -Number $number))
                }
            }
            else {
                $number = ConvertTo-PshSignalNumber -Value ([string]$listValue)
                if ($number -lt 0) { throw ('unknown signal "{0}".' -f $listValue) }
                Write-Output ([string](Get-PshSignalName -Number $number))
            }
            Set-PshProcessExitCode -Code 0
            return
        }
        if ($pidValues.Count -eq 0) { throw 'at least one process id is required.' }
        $pids = @(ConvertTo-PshProcessPidList -Values $pidValues)
    }
    catch {
        Write-PshProcessFailure -Command 'kill' -Code 2 -Message $_.Exception.Message
        return
    }

    $protected = @(Get-PshProtectedProcessIds)
    $failed = $false
    $found = $false
    $notFound = $false
    foreach ($processId in $pids) {
        if ($protected -contains [int]$processId) {
            Write-PshProcessFailure -Command 'kill' -Code 3 -Message ('refusing to signal protected process {0}.' -f $processId)
            $failed = $true
            continue
        }
        $process = $null
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$processId)
            $found = $true
            if (-not (Send-PshProcessSignal -Process $process -Signal $signal)) { $failed = $true }
        }
        catch {
            if (Test-PshProcessNotFoundException -Exception $_.Exception) {
                $notFound = $true
            }
            else {
                $failed = $true
            }
        }
        finally {
            if ($null -ne $process) { try { $process.Dispose() } catch { } }
        }
    }
    if ($failed -or ($found -and $notFound)) { Set-PshProcessExitCode -Code 3 }
    elseif (-not $found) { Set-PshProcessExitCode -Code 1 }
    else { Set-PshProcessExitCode -Code 0 }
}

function Set-PshTimeoutProcessArguments {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.ProcessStartInfo]$StartInfo,
        [AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @()
    )

    $projectSetter = Get-Command -Name Set-PshProcessArguments -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $projectSetter) {
        Set-PshProcessArguments -StartInfo $StartInfo -Arguments $Arguments
        return
    }
    $argumentList = @()
    foreach ($argument in @($Arguments)) {
        $text = if ($null -eq $argument) { '' } else { [string]$argument }
        if ($text.Length -eq 0) { $argumentList += '""'; continue }
        if ($text -notmatch '[\s"]') { $argumentList += $text; continue }
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in $text.ToCharArray()) {
            if ($character -eq '\') { $slashes++; continue }
            if ($character -eq '"') {
                for ($count = 0; $count -lt (($slashes * 2) + 1); $count++) { [void]$builder.Append('\') }
                [void]$builder.Append('"')
                $slashes = 0
                continue
            }
            for ($count = 0; $count -lt $slashes; $count++) { [void]$builder.Append('\') }
            $slashes = 0
            [void]$builder.Append($character)
        }
        for ($count = 0; $count -lt ($slashes * 2); $count++) { [void]$builder.Append('\') }
        [void]$builder.Append('"')
        $argumentList += $builder.ToString()
    }
    $StartInfo.Arguments = $argumentList -join ' '
}

function Write-PshTimeoutBytes {
    param(
        [AllowNull()][byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return }
    $writer = Get-Command -Name Write-PshRawBytes -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $writer) {
        Write-PshRawBytes -Bytes $Bytes
        return
    }
    $stream = [Console]::OpenStandardOutput()
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush()
    }
    finally { $stream.Dispose() }
}

function Wait-PshTimeoutOutputTasks {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Tasks,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($task in @($Tasks)) {
        if ($null -eq $task -or [bool]$task.IsCompleted) { continue }
        $remaining = [long]$TimeoutMilliseconds - [long]$stopwatch.ElapsedMilliseconds
        if ($remaining -le 0) { return $false }
        try { [void]$task.Wait([int][Math]::Min([long][int]::MaxValue, $remaining)) }
        catch [AggregateException] {
            # A faulted task is complete. The caller decides whether a forced
            # pipe close makes that fault expected.
        }
        if (-not [bool]$task.IsCompleted) { return $false }
    }
    return $true
}

function Assert-PshTimeoutOutputTasksSucceeded {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Tasks
    )

    foreach ($task in @($Tasks)) {
        if ($null -ne $task -and [bool]$task.IsFaulted) {
            throw ($task.Exception.GetBaseException())
        }
    }
}

function Initialize-PshTimeoutPipeNativeMethods {
    if ($null -ne ('PshTimeoutPipeNativeMethods' -as [type])) { return }

    $source = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PshTimeoutPipeNativeMethods
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PeekNamedPipe(
        SafeFileHandle handle,
        IntPtr buffer,
        uint bufferSize,
        IntPtr bytesRead,
        out uint totalBytesAvailable,
        IntPtr bytesLeftThisMessage);
}
'@
    try { [void](Add-Type -TypeDefinition $source -ErrorAction Stop) }
    catch {
        if ($null -eq ('PshTimeoutPipeNativeMethods' -as [type])) { throw }
    }
}

function Get-PshTimeoutAvailablePipeByteCount {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Source
    )

    $safeHandleProperty = $Source.PSObject.Properties['SafeFileHandle']
    if ($null -eq $safeHandleProperty -or $safeHandleProperty.Value -isnot [Microsoft.Win32.SafeHandles.SafeFileHandle]) {
        throw 'redirected process output does not expose a Windows pipe handle.'
    }

    [uint32]$available = 0
    $peeked = [PshTimeoutPipeNativeMethods]::PeekNamedPipe(
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$safeHandleProperty.Value,
        [IntPtr]::Zero,
        [uint32]0,
        [IntPtr]::Zero,
        [ref]$available,
        [IntPtr]::Zero
    )
    if (-not $peeked) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errorCode -in @(109, 232, 233)) { return 0 }
        throw (New-Object ComponentModel.Win32Exception($errorCode, 'failed to inspect redirected process output.'))
    }
    return [long]$available
}

function Read-PshTimeoutAvailablePipeBytes {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Source,
        [Parameter(Mandatory = $true)][IO.Stream]$Destination,
        [Parameter(Mandatory = $true)][byte[]]$Buffer,
        [long]$MaximumBytes = [long]::MaxValue
    )

    $available = Get-PshTimeoutAvailablePipeByteCount -Source $Source
    if ($available -le 0 -or $MaximumBytes -le 0) { return 0 }
    $count = [int][Math]::Min([long]$Buffer.Length, [Math]::Min($available, $MaximumBytes))
    try { $read = $Source.Read($Buffer, 0, $count) }
    catch [IO.IOException] {
        $errorCode = $_.Exception.HResult -band 0xffff
        if ($errorCode -in @(109, 232, 233)) { return 0 }
        throw
    }
    if ($read -le 0) { return 0 }
    $Destination.Write($Buffer, 0, $read)
    return $read
}

function New-PshTimeoutPipeCapture {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][IO.Stream]$StandardOutputDestination,
        [Parameter(Mandatory = $true)][IO.Stream]$StandardErrorDestination
    )

    return [PSCustomObject]@{
        StandardOutput = $Process.StandardOutput.BaseStream
        StandardError = $Process.StandardError.BaseStream
        StandardOutputDestination = $StandardOutputDestination
        StandardErrorDestination = $StandardErrorDestination
        StandardOutputBuffer = New-Object byte[] 65536
        StandardErrorBuffer = New-Object byte[] 65536
    }
}

function Read-PshTimeoutAvailableOutput {
    param(
        [Parameter(Mandatory = $true)][object]$Capture
    )

    $stdoutRead = Read-PshTimeoutAvailablePipeBytes `
        -Source ([IO.Stream]$Capture.StandardOutput) `
        -Destination ([IO.Stream]$Capture.StandardOutputDestination) `
        -Buffer ([byte[]]$Capture.StandardOutputBuffer)
    $stderrRead = Read-PshTimeoutAvailablePipeBytes `
        -Source ([IO.Stream]$Capture.StandardError) `
        -Destination ([IO.Stream]$Capture.StandardErrorDestination) `
        -Buffer ([byte[]]$Capture.StandardErrorBuffer)
    return $stdoutRead + $stderrRead
}

function Read-PshTimeoutPipeSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Capture
    )

    $stdoutRemaining = Get-PshTimeoutAvailablePipeByteCount -Source ([IO.Stream]$Capture.StandardOutput)
    $stderrRemaining = Get-PshTimeoutAvailablePipeByteCount -Source ([IO.Stream]$Capture.StandardError)
    $totalRead = 0L
    while ($stdoutRemaining -gt 0 -or $stderrRemaining -gt 0) {
        if ($stdoutRemaining -gt 0) {
            $read = Read-PshTimeoutAvailablePipeBytes `
                -Source ([IO.Stream]$Capture.StandardOutput) `
                -Destination ([IO.Stream]$Capture.StandardOutputDestination) `
                -Buffer ([byte[]]$Capture.StandardOutputBuffer) `
                -MaximumBytes $stdoutRemaining
            if ($read -le 0) { $stdoutRemaining = 0 }
            else { $stdoutRemaining -= $read; $totalRead += $read }
        }
        if ($stderrRemaining -gt 0) {
            $read = Read-PshTimeoutAvailablePipeBytes `
                -Source ([IO.Stream]$Capture.StandardError) `
                -Destination ([IO.Stream]$Capture.StandardErrorDestination) `
                -Buffer ([byte[]]$Capture.StandardErrorBuffer) `
                -MaximumBytes $stderrRemaining
            if ($read -le 0) { $stderrRemaining = 0 }
            else { $stderrRemaining -= $read; $totalRead += $read }
        }
    }
    return $totalRead
}

function Wait-PshTimeoutProcessWithPipePolling {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][object]$Capture,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {
            $bytesRead = Read-PshTimeoutAvailableOutput -Capture $Capture
            if ($Process.HasExited) { return $true }
            if ($TimeoutMilliseconds -ge 0 -and $stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) { return $false }
            if ($bytesRead -gt 0) { continue }

            if ($TimeoutMilliseconds -lt 0) {
                if ($Process.WaitForExit(10)) { return $true }
                continue
            }
            $remaining = [long]$TimeoutMilliseconds - [long]$stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) { return $false }
            $slice = [int][Math]::Min(10L, $remaining)
            if ($Process.WaitForExit($slice)) { return $true }
        }
    }
    finally { $stopwatch.Stop() }
}

function Complete-PshTimeoutPipeDrain {
    param(
        [Parameter(Mandatory = $true)][object]$Capture,
        [int]$QuietMilliseconds = 25,
        [int]$MaximumMilliseconds = 250
    )

    $total = [Diagnostics.Stopwatch]::StartNew()
    $quiet = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {
            $bytesRead = Read-PshTimeoutAvailableOutput -Capture $Capture
            if ($bytesRead -gt 0) {
                $quiet.Restart()
            }
            if ($total.ElapsedMilliseconds -ge $MaximumMilliseconds) {
                [void](Read-PshTimeoutPipeSnapshot -Capture $Capture)
                return
            }
            if ($bytesRead -gt 0) { continue }
            if ($quiet.ElapsedMilliseconds -ge $QuietMilliseconds) { return }
            [Threading.Thread]::Sleep(5)
        }
    }
    finally {
        $quiet.Stop()
        $total.Stop()
    }
}

function Close-PshTimeoutOutputPipes {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process
    )

    try { $Process.StandardOutput.Dispose() } catch {}
    try { $Process.StandardError.Dispose() } catch {}
}

function Resolve-PshTimeoutCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @()
    )

    $launchPath = $Command
    $launchArguments = @($Arguments)
    if ([string]::Equals([IO.Path]::GetExtension($Command), '.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        $scriptPath = $Command
        try {
            $resolver = Get-Command -Name Resolve-PshFileSystemPath -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $resolver) { $scriptPath = [string](Resolve-PshFileSystemPath -Path $Command) }
            elseif (-not [IO.Path]::IsPathRooted($scriptPath)) { $scriptPath = [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $scriptPath)) }
        }
        catch { }
        $launchPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $launchArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath) + @($Arguments)
        return [PSCustomObject]@{ Path = [string]$launchPath; Arguments = [string[]]$launchArguments }
    }

    # Resolve only applications/scripts.  This prevents timeout from invoking
    # a same-named PowerShell function or alias and keeps argv opaque.
    try {
        $commands = @(Get-Command -Name $Command -CommandType Application,ExternalScript -All -ErrorAction SilentlyContinue)
        if ($commands.Count -gt 0) {
            $candidate = $commands[0]
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate.Path)) { $launchPath = [string]$candidate.Path }
        }
    }
    catch { }
    return [PSCustomObject]@{ Path = [string]$launchPath; Arguments = [string[]]$launchArguments }
}

function Test-PshTimeoutMissingCommandException {
    param(
        [Parameter(Mandatory = $true)][Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [ComponentModel.Win32Exception] -and $current.NativeErrorCode -in @(2, 3)) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Invoke-PshTimeoutChild {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory = $true)][int]$Signal,
        [Parameter(Mandatory = $true)][int]$KillAfterMilliseconds
    )

    Assert-PshTerminationSignal -Signal $Signal -Command 'timeout'

    $workingDirectory = ''
    try { $workingDirectory = [string](Get-Location).ProviderPath } catch { $workingDirectory = [string][Environment]::CurrentDirectory }
    if ([string]::IsNullOrWhiteSpace($workingDirectory) -or -not [IO.Directory]::Exists($workingDirectory)) {
        throw 'timeout requires a FileSystem working directory.'
    }

    $useWindowsPipePolling = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object Text.UTF8Encoding($false)
    $stdoutEncodingProperty = $startInfo.PSObject.Properties['StandardOutputEncoding']
    if ($null -ne $stdoutEncodingProperty) { $startInfo.StandardOutputEncoding = $utf8 }
    $stderrEncodingProperty = $startInfo.PSObject.Properties['StandardErrorEncoding']
    if ($null -ne $stderrEncodingProperty) { $startInfo.StandardErrorEncoding = $utf8 }
    Set-PshTimeoutProcessArguments -StartInfo $startInfo -Arguments $Arguments

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutBuffer = New-Object IO.MemoryStream
    $stderrBuffer = New-Object IO.MemoryStream
    $stdoutStream = $null
    $stderrStream = $null
    $pipeCapture = $null
    $stdoutTask = $null
    $stderrTask = $null
    $timedOut = $false
    try {
        if ($useWindowsPipePolling) {
            Initialize-PshTimeoutPipeNativeMethods
        }
        if (-not $process.Start()) { throw ('failed to start process: {0}' -f $FilePath) }
        if ($useWindowsPipePolling) {
            $pipeCapture = New-PshTimeoutPipeCapture `
                -Process $process `
                -StandardOutputDestination $stdoutBuffer `
                -StandardErrorDestination $stderrBuffer
            $completed = Wait-PshTimeoutProcessWithPipePolling `
                -Process $process `
                -Capture $pipeCapture `
                -TimeoutMilliseconds $TimeoutMilliseconds
        }
        else {
            $stdoutStream = $process.StandardOutput.BaseStream
            $stderrStream = $process.StandardError.BaseStream
            $stdoutTask = $stdoutStream.CopyToAsync($stdoutBuffer)
            $stderrTask = $stderrStream.CopyToAsync($stderrBuffer)
            $completed = $process.WaitForExit($TimeoutMilliseconds)
        }
        if (-not $completed) {
            $timedOut = $true
            if ($Signal -in @(1, 2, 15)) {
                try { [void]$process.CloseMainWindow() } catch { }
            }
            if ($Signal -eq 9) {
                try { if (-not $process.HasExited) { [void]$process.Kill() } } catch { }
            }
            $waitMilliseconds = $KillAfterMilliseconds
            if ($waitMilliseconds -lt 0) { $waitMilliseconds = 250 }
            $exitedAfterSignal = $false
            if ($useWindowsPipePolling) {
                $exitedAfterSignal = Wait-PshTimeoutProcessWithPipePolling `
                    -Process $process `
                    -Capture $pipeCapture `
                    -TimeoutMilliseconds $waitMilliseconds
            }
            else {
                try { $exitedAfterSignal = $process.WaitForExit($waitMilliseconds) } catch { $exitedAfterSignal = $false }
            }
            if (-not $exitedAfterSignal) {
                try { if (-not $process.HasExited) { [void]$process.Kill() } } catch { }
                if ($useWindowsPipePolling) {
                    [void](Wait-PshTimeoutProcessWithPipePolling `
                        -Process $process `
                        -Capture $pipeCapture `
                        -TimeoutMilliseconds 2000)
                }
                else {
                    try { $process.WaitForExit(2000) } catch { }
                }
            }
        }
        else {
            try { $process.WaitForExit() } catch { }
        }
        $exitCode = if ($process.HasExited) { [int]$process.ExitCode } else { 3 }
        if ($useWindowsPipePolling) {
            # Read only bytes already available from the direct child or an
            # inheriting descendant; never wait for a descendant-held EOF.
            Complete-PshTimeoutPipeDrain -Capture $pipeCapture
            Close-PshTimeoutOutputPipes -Process $process
        }
        else {
            $outputTasks = @($stdoutTask, $stderrTask)
            $outputTasksCompleted = Wait-PshTimeoutOutputTasks -Tasks $outputTasks -TimeoutMilliseconds 500
            $forcedPipeClose = -not $outputTasksCompleted
            if ($forcedPipeClose) {
                Close-PshTimeoutOutputPipes -Process $process
                $outputTasksCompleted = Wait-PshTimeoutOutputTasks -Tasks $outputTasks -TimeoutMilliseconds 1000
                if (-not $outputTasksCompleted) {
                    throw (New-Object IO.IOException('timed out while closing redirected process output.'))
                }
            }
            else {
                Assert-PshTimeoutOutputTasksSucceeded -Tasks $outputTasks
            }
        }
        return [PSCustomObject]@{
            ExitCode = $exitCode
            TimedOut = [bool]$timedOut
            StdOutBytes = [byte[]]$stdoutBuffer.ToArray()
            StdErrBytes = [byte[]]$stderrBuffer.ToArray()
        }
    }
    finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch { }
            $process.Dispose()
        }
        $stdoutBuffer.Dispose()
        $stderrBuffer.Dispose()
    }
}

function timeout {
    $arguments = @(ConvertTo-PshProcessArgumentArray -InputArguments $args)
    Set-PshProcessExitCode -Code 0
    if (Test-PshProcessHelp -Arguments $arguments) {
        Write-PshProcessHelp -Usage 'Usage: timeout [-s SIGNAL] [-k DURATION] [--preserve-status] DURATION COMMAND [ARG ...]'
        return
    }

    $signal = 15
    $killAfterMilliseconds = -1
    $preserveStatus = $false
    $durationText = $null
    $command = $null
    $commandArguments = @()
    $parseOptions = $true
    $index = 0
    try {
        while ($index -lt $arguments.Count) {
            $token = [string]$arguments[$index]
            if ($parseOptions -and $token -ceq '--') {
                $parseOptions = $false
                $index++
                continue
            }
            if ($parseOptions -and $token -ceq '--preserve-status') {
                $preserveStatus = $true
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '-s' -or $token.StartsWith('-s='))) {
                if ($token.StartsWith('-s=')) { $signalValue = $token.Substring(3) }
                elseif ($token.Length -gt 2) { $signalValue = $token.Substring(2) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '-s requires a signal name or number.' }
                    $signalValue = [string]$arguments[$index]
                }
                $signal = ConvertTo-PshSignalNumber -Value $signalValue
                if ($signal -lt 0) { throw ('unknown signal "{0}".' -f $signalValue) }
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '--signal' -or $token.StartsWith('--signal='))) {
                if ($token.StartsWith('--signal=')) { $signalValue = $token.Substring(9) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '--signal requires a signal name or number.' }
                    $signalValue = [string]$arguments[$index]
                }
                $signal = ConvertTo-PshSignalNumber -Value $signalValue
                if ($signal -lt 0) { throw ('unknown signal "{0}".' -f $signalValue) }
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '-k' -or $token.StartsWith('-k='))) {
                if ($token.StartsWith('-k=')) { $durationValue = $token.Substring(3) }
                elseif ($token.Length -gt 2) { $durationValue = $token.Substring(2) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '-k requires a duration.' }
                    $durationValue = [string]$arguments[$index]
                }
                $killAfterMilliseconds = ConvertTo-PshProcessDurationMilliseconds -Value $durationValue -OptionName '--kill-after'
                $index++
                continue
            }
            if ($parseOptions -and ($token -ceq '--kill-after' -or $token.StartsWith('--kill-after='))) {
                if ($token.StartsWith('--kill-after=')) { $durationValue = $token.Substring(13) }
                else {
                    $index++
                    if ($index -ge $arguments.Count) { throw '--kill-after requires a duration.' }
                    $durationValue = [string]$arguments[$index]
                }
                $killAfterMilliseconds = ConvertTo-PshProcessDurationMilliseconds -Value $durationValue -OptionName '--kill-after'
                $index++
                continue
            }
            if ($parseOptions -and $token.StartsWith('-', [StringComparison]::Ordinal) -and $token -ne '-') {
                throw ('unsupported argument "{0}".' -f $token)
            }
            if ($null -eq $durationText) {
                $durationText = $token
                $index++
                if ($index -ge $arguments.Count) { throw 'a command is required after the duration.' }
                $command = [string]$arguments[$index]
                $index++
                while ($index -lt $arguments.Count) {
                    $commandArguments += [string]$arguments[$index]
                    $index++
                }
                $parseOptions = $false
                continue
            }
            throw 'timeout accepts exactly one duration and one command.'
        }
        if ([string]::IsNullOrWhiteSpace($durationText)) { throw 'a duration is required.' }
        if ([string]::IsNullOrWhiteSpace($command)) { throw 'a command is required.' }
        Assert-PshTerminationSignal -Signal $signal -Command 'timeout'
        # "inf" is useful for callers that only want argv-safe capture and
        # also exercises the project's Invoke-PshCapturedProcess path.
        if ($durationText -match '^(?i:inf|infinity)$') { $timeoutMilliseconds = -1 }
        else { $timeoutMilliseconds = ConvertTo-PshProcessDurationMilliseconds -Value $durationText -OptionName 'timeout' }
    }
    catch {
        Write-PshProcessFailure -Command 'timeout' -Code 2 -Message $_.Exception.Message
        return
    }

    try {
        $resolved = Resolve-PshTimeoutCommand -Command $command -Arguments $commandArguments
        $result = Invoke-PshTimeoutChild -FilePath ([string]$resolved.Path) -Arguments ([string[]]$resolved.Arguments) -TimeoutMilliseconds $timeoutMilliseconds -Signal $signal -KillAfterMilliseconds $killAfterMilliseconds
        Write-PshTimeoutBytes -Bytes ([byte[]]$result.StdOutBytes)
        Write-PshTimeoutBytes -Bytes ([byte[]]$result.StdErrBytes)
        if ([bool]$result.TimedOut) {
            # A timeout is a runtime failure in Psh's normalized result space.
            Set-PshProcessExitCode -Code 3
        }
        else {
            $childCode = [int]$result.ExitCode
            if ($preserveStatus) { Set-PshProcessExitCode -Code $childCode }
            elseif ($childCode -eq 0) { Set-PshProcessExitCode -Code 0 }
            elseif ($childCode -in @(1, 2)) { Set-PshProcessExitCode -Code $childCode }
            else { Set-PshProcessExitCode -Code 3 }
        }
    }
    catch {
        $code = if (Test-PshTimeoutMissingCommandException -Exception $_.Exception) { 4 } else { 3 }
        Write-PshProcessFailure -Command 'timeout' -Code $code -Message $_.Exception.Message
    }
}
