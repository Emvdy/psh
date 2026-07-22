# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

function Get-PshGoal6RemainingMilliseconds {
    param([Parameter(Mandatory = $true)][DateTime] $DeadlineUtc)

    $remaining = [Math]::Floor(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -le 0) { return 0 }
    if ($remaining -gt [int]::MaxValue) { return [int]::MaxValue }
    return [int]$remaining
}

function Get-PshGoal6ProcessSnapshot {
    $rows = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 2 -ErrorAction Stop)
    return @($rows | ForEach-Object {
            [pscustomobject][ordered]@{
                ProcessId = [int]$_.ProcessId
                ParentProcessId = [int]$_.ParentProcessId
                CreationDate = [string]$_.CreationDate
            }
        })
}

function Add-PshGoal6ProcessTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary] $KnownProcesses,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]] $Snapshot
    )

    $added = $true
    while ($added) {
        $added = $false
        foreach ($row in @($Snapshot)) {
            $processId = [int]$row.ProcessId
            $parentProcessId = [int]$row.ParentProcessId
            if ($KnownProcesses.Contains($processId)) {
                if ([string]::IsNullOrWhiteSpace([string]$KnownProcesses[$processId].CreationDate)) {
                    $KnownProcesses[$processId].ParentProcessId = $parentProcessId
                    $KnownProcesses[$processId].CreationDate = [string]$row.CreationDate
                }
                continue
            }
            if (-not $KnownProcesses.Contains($parentProcessId)) { continue }
            $KnownProcesses[$processId] = [pscustomobject][ordered]@{
                ProcessId = $processId
                ParentProcessId = $parentProcessId
                CreationDate = [string]$row.CreationDate
                Depth = [int]$KnownProcesses[$parentProcessId].Depth + 1
            }
            $added = $true
        }
    }
}

function Get-PshGoal6LiveKnownProcessIds {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary] $KnownProcesses,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]] $Snapshot
    )

    $live = New-Object System.Collections.Generic.List[int]
    foreach ($row in @($Snapshot)) {
        $processId = [int]$row.ProcessId
        if (-not $KnownProcesses.Contains($processId)) { continue }
        $knownCreationDate = [string]$KnownProcesses[$processId].CreationDate
        if (-not [string]::IsNullOrWhiteSpace($knownCreationDate) -and $knownCreationDate -cne [string]$row.CreationDate) { continue }
        [void]$live.Add($processId)
    }
    return @($live.ToArray() | Sort-Object -Unique)
}

function Test-PshGoal6ProcessStreamConvergence {
    param([Parameter(Mandatory = $true)][string[]] $Path)

    $pending = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($Path)) {
        if (-not [IO.File]::Exists($candidate)) {
            [void]$pending.Add("missing: $candidate")
            continue
        }
        $stream = $null
        try {
            $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            [void]$stream.Seek(0, [IO.SeekOrigin]::End)
        }
        catch [IO.IOException] { [void]$pending.Add("locked: $candidate") }
        catch { [void]$errors.Add("Unable to confirm redirected stream EOF for '$candidate': $($_.Exception.Message)") }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
    return [pscustomobject][ordered]@{
        Converged = $pending.Count -eq 0 -and $errors.Count -eq 0
        Pending = $pending.ToArray()
        Errors = $errors.ToArray()
    }
}

function Start-PshGoal6RedirectedProcess {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Arguments,
        [Parameter()][string] $WorkingDirectory,
        [Parameter()][Management.Automation.PSCredential] $Credential,
        [Parameter()][switch] $LoadUserProfile
    )

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }
    if ($null -ne $Credential) {
        $credentialName = [string]$Credential.UserName
        $separatorIndex = $credentialName.IndexOf('\')
        if ($separatorIndex -ge 0) {
            $startInfo.Domain = $credentialName.Substring(0, $separatorIndex)
            $startInfo.UserName = $credentialName.Substring($separatorIndex + 1)
        }
        else { $startInfo.UserName = $credentialName }
        $startInfo.Password = $Credential.Password
        $startInfo.LoadUserProfile = [bool]$LoadUserProfile
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Process did not start: $FilePath" }
        return [pscustomobject][ordered]@{
            Process = $process
            StdoutTask = $process.StandardOutput.ReadToEndAsync()
            StderrTask = $process.StandardError.ReadToEndAsync()
        }
    }
    catch {
        $process.Dispose()
        throw
    }
}

function Test-PshGoal6OutputTaskConvergence {
    param(
        [Parameter(Mandatory = $true)][Threading.Tasks.Task] $StdoutTask,
        [Parameter(Mandatory = $true)][Threading.Tasks.Task] $StderrTask
    )

    $pending = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(
            [pscustomobject]@{ Name = 'stdout'; Task = $StdoutTask },
            [pscustomobject]@{ Name = 'stderr'; Task = $StderrTask })) {
        if (-not $entry.Task.IsCompleted) { [void]$pending.Add([string]$entry.Name); continue }
        if ($entry.Task.IsCanceled) { [void]$errors.Add("$($entry.Name) output task was canceled."); continue }
        if ($entry.Task.IsFaulted) { [void]$errors.Add("$($entry.Name) output task failed: $($entry.Task.Exception.GetBaseException().Message)") }
    }
    return [pscustomobject][ordered]@{
        Converged = $pending.Count -eq 0 -and $errors.Count -eq 0
        Pending = $pending.ToArray()
        Errors = $errors.ToArray()
    }
}

function Wait-PshGoal6ProcessTreeAndStreams {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary] $KnownProcesses,
        [Parameter(Mandatory = $true)][Threading.Tasks.Task] $StdoutTask,
        [Parameter(Mandatory = $true)][Threading.Tasks.Task] $StderrTask,
        [Parameter(Mandatory = $true)][DateTime] $DeadlineUtc
    )

    $lastLive = @()
    $lastStreamState = [pscustomobject][ordered]@{ Converged = $false; Pending = @('not inspected'); Errors = @() }
    while ((Get-PshGoal6RemainingMilliseconds -DeadlineUtc $DeadlineUtc) -gt 0) {
        $snapshot = Get-PshGoal6ProcessSnapshot
        Add-PshGoal6ProcessTreeSnapshot -KnownProcesses $KnownProcesses -Snapshot $snapshot
        $lastLive = @(Get-PshGoal6LiveKnownProcessIds -KnownProcesses $KnownProcesses -Snapshot $snapshot)
        $lastStreamState = Test-PshGoal6OutputTaskConvergence -StdoutTask $StdoutTask -StderrTask $StderrTask
        if ($lastLive.Count -eq 0 -and [bool]$lastStreamState.Converged) {
            return [pscustomobject][ordered]@{
                Converged = $true
                LiveProcessIds = @()
                PendingStreams = @()
                StreamErrors = @()
            }
        }
        $remaining = Get-PshGoal6RemainingMilliseconds -DeadlineUtc $DeadlineUtc
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min(100, $remaining))
    }
    return [pscustomobject][ordered]@{
        Converged = $false
        LiveProcessIds = @($lastLive)
        PendingStreams = @($lastStreamState.Pending)
        StreamErrors = @($lastStreamState.Errors)
    }
}

function Invoke-PshGoal6BoundedTaskKill {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [Parameter(Mandatory = $true)][string] $ArtifactRoot,
        [Parameter(Mandatory = $true)][DateTime] $DeadlineUtc
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $taskKillPath = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { $null } else { Join-Path $env:SystemRoot 'System32/taskkill.exe' }
    $suffix = '{0}-{1}' -f $RootProcessId, [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $ArtifactRoot ("taskkill-$suffix.stdout.log")
    $stderrPath = Join-Path $ArtifactRoot ("taskkill-$suffix.stderr.log")
    $exitCode = $null
    $timedOut = $false
    $process = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdout = ''
    $stderr = ''
    if ([string]::IsNullOrWhiteSpace($taskKillPath) -or -not [IO.File]::Exists($taskKillPath)) {
        [void]$errors.Add("taskkill.exe is missing: $taskKillPath")
    }
    else {
        try {
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $taskKillPath
            $startInfo.Arguments = "/PID $RootProcessId /T /F"
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw 'taskkill.exe did not start.' }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $remaining = Get-PshGoal6RemainingMilliseconds -DeadlineUtc $DeadlineUtc
            $waitMilliseconds = [Math]::Min(5000, $remaining)
            if ($waitMilliseconds -le 0 -or -not $process.WaitForExit($waitMilliseconds)) {
                $timedOut = $true
                [void]$errors.Add("taskkill.exe exceeded its bounded deadline for process $RootProcessId.")
                try { if (-not $process.HasExited) { $process.Kill() } }
                catch { [void]$errors.Add("Unable to terminate timed-out taskkill.exe: $($_.Exception.Message)") }
                $remaining = Get-PshGoal6RemainingMilliseconds -DeadlineUtc $DeadlineUtc
                if ($remaining -gt 0 -and -not $process.WaitForExit([Math]::Min(1000, $remaining))) {
                    [void]$errors.Add('Timed-out taskkill.exe did not exit after best-effort termination.')
                }
            }
            else {
                $exitCode = [int]$process.ExitCode
                if ($exitCode -ne 0) { [void]$errors.Add("taskkill.exe exited $exitCode for process $RootProcessId.") }
            }
            if ($null -ne $stdoutTask -and $null -ne $stderrTask) {
                $remaining = Get-PshGoal6RemainingMilliseconds -DeadlineUtc $DeadlineUtc
                $tasks = [Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
                if ($remaining -le 0 -or -not [Threading.Tasks.Task]::WaitAll($tasks, $remaining)) {
                    [void]$errors.Add('taskkill.exe stdout/stderr did not reach EOF before the bounded deadline.')
                }
                else {
                    $stdout = [string]$stdoutTask.Result
                    $stderr = [string]$stderrTask.Result
                }
            }
        }
        catch { [void]$errors.Add("taskkill.exe failed for process ${RootProcessId}: $($_.Exception.Message)") }
        finally { if ($null -ne $process) { $process.Dispose() } }
    }
    $taskKillUtf8 = New-Object Text.UTF8Encoding($false, $true)
    try { [IO.File]::WriteAllText($stdoutPath, $stdout, $taskKillUtf8) }
    catch { [void]$errors.Add("Unable to retain taskkill stdout '$stdoutPath': $($_.Exception.Message)") }
    try { [IO.File]::WriteAllText($stderrPath, $stderr, $taskKillUtf8) }
    catch { [void]$errors.Add("Unable to retain taskkill stderr '$stderrPath': $($_.Exception.Message)") }
    return [pscustomobject][ordered]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        Stdout = $stdout
        Stderr = $stderr
        Errors = $errors.ToArray()
    }
}

function Stop-PshGoal6KnownProcesses {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary] $KnownProcesses,
        [Parameter(Mandatory = $true)][DateTime] $DeadlineUtc
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $liveIds = $null
    try {
        $snapshot = Get-PshGoal6ProcessSnapshot
        Add-PshGoal6ProcessTreeSnapshot -KnownProcesses $KnownProcesses -Snapshot $snapshot
        $liveIds = @(Get-PshGoal6LiveKnownProcessIds -KnownProcesses $KnownProcesses -Snapshot $snapshot)
    }
    catch { [void]$errors.Add("Unable to refresh process identities before best-effort termination: $($_.Exception.Message)") }
    foreach ($entry in @($KnownProcesses.Values | Sort-Object Depth -Descending)) {
        if ($null -ne $liveIds -and [int]$entry.ProcessId -notin $liveIds) { continue }
        $candidate = $null
        try { $candidate = [Diagnostics.Process]::GetProcessById([int]$entry.ProcessId) }
        catch [ArgumentException] { continue }
        catch {
            [void]$errors.Add("Unable to open process $($entry.ProcessId) for best-effort termination: $($_.Exception.Message)")
            continue
        }
        try {
            if (-not $candidate.HasExited) { $candidate.Kill() }
            $remaining = Get-PshGoal6RemainingMilliseconds -DeadlineUtc $DeadlineUtc
            if ($remaining -le 0 -or -not $candidate.WaitForExit([Math]::Min(1000, $remaining))) {
                [void]$errors.Add("Process $($entry.ProcessId) did not exit after best-effort termination.")
            }
        }
        catch {
            $terminationMessage = [string]$_.Exception.Message
            $stillAlive = $true
            try { $candidate.Refresh(); $stillAlive = -not $candidate.HasExited }
            catch [InvalidOperationException] { $stillAlive = $false }
            catch { [void]$errors.Add("Unable to confirm process $($entry.ProcessId) exit after a termination error: $($_.Exception.Message)") }
            if ($stillAlive) { [void]$errors.Add("Unable to terminate process $($entry.ProcessId): $terminationMessage") }
        }
        finally { $candidate.Dispose() }
    }
    return $errors.ToArray()
}

function Complete-PshGoal6BoundedProcess {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int] $TimeoutMilliseconds,
        [Parameter(Mandatory = $true)][string] $StdoutPath,
        [Parameter(Mandatory = $true)][string] $StderrPath,
        [Parameter(Mandatory = $true)][Threading.Tasks.Task] $StdoutTask,
        [Parameter(Mandatory = $true)][Threading.Tasks.Task] $StderrTask,
        [Parameter(Mandatory = $true)][string] $ArtifactRoot,
        [Parameter(Mandatory = $true)][string] $Label,
        [Parameter()][ValidateRange(1000, 60000)][int] $DrainTimeoutMilliseconds = 5000,
        [Parameter()][ValidateRange(1000, 60000)][int] $CleanupTimeoutMilliseconds = 15000
    )

    [void][IO.Directory]::CreateDirectory($ArtifactRoot)
    $rootProcessId = [int]$Process.Id
    $knownProcesses = @{}
    $knownProcesses[$rootProcessId] = [pscustomobject][ordered]@{
        ProcessId = $rootProcessId
        ParentProcessId = $null
        CreationDate = $null
        Depth = 0
    }
    $errors = New-Object System.Collections.Generic.List[string]
    $timedOut = $false
    $exitCode = $null
    try {
        if (-not $Process.WaitForExit($TimeoutMilliseconds)) { $timedOut = $true }
        else { $exitCode = [int]$Process.ExitCode }
    }
    catch {
        $timedOut = $true
        [void]$errors.Add("$Label bounded process wait failed: $($_.Exception.Message)")
    }

    if (-not $timedOut) {
        $drainDeadline = [DateTime]::UtcNow.AddMilliseconds($DrainTimeoutMilliseconds)
        $drain = $null
        try { $drain = Wait-PshGoal6ProcessTreeAndStreams -KnownProcesses $knownProcesses -StdoutTask $StdoutTask -StderrTask $StderrTask -DeadlineUtc $drainDeadline }
        catch { [void]$errors.Add("$Label process-tree/stream drain inspection failed: $($_.Exception.Message)") }
        if ($null -eq $drain -or -not [bool]$drain.Converged) {
            $liveText = if ($null -eq $drain) { 'unknown' } else { @($drain.LiveProcessIds) -join ',' }
            $streamText = if ($null -eq $drain) { 'unknown' } else { @($drain.PendingStreams) -join ', ' }
            [void]$errors.Add("$Label left descendants or redirected streams after normal exit (pids=$liveText; streams=$streamText).")
        }
    }

    if ($timedOut -or $errors.Count -ne 0) {
        $cleanupDeadline = [DateTime]::UtcNow.AddMilliseconds($CleanupTimeoutMilliseconds)
        try {
            $snapshot = Get-PshGoal6ProcessSnapshot
            Add-PshGoal6ProcessTreeSnapshot -KnownProcesses $knownProcesses -Snapshot $snapshot
        }
        catch { [void]$errors.Add("$Label could not capture the parent/descendant process tree: $($_.Exception.Message)") }

        if ($timedOut) {
            $taskKill = Invoke-PshGoal6BoundedTaskKill -RootProcessId $rootProcessId -ArtifactRoot $ArtifactRoot -DeadlineUtc $cleanupDeadline
            foreach ($taskKillError in @($taskKill.Errors)) {
                [void]$errors.Add("$taskKillError stdout=$($taskKill.StdoutPath); stderr=$($taskKill.StderrPath); output=$($taskKill.Stdout.Trim()); error=$($taskKill.Stderr.Trim())")
            }
        }
        foreach ($terminationError in @(Stop-PshGoal6KnownProcesses -KnownProcesses $knownProcesses -DeadlineUtc $cleanupDeadline)) {
            [void]$errors.Add($terminationError)
        }
        $convergence = $null
        try { $convergence = Wait-PshGoal6ProcessTreeAndStreams -KnownProcesses $knownProcesses -StdoutTask $StdoutTask -StderrTask $StderrTask -DeadlineUtc $cleanupDeadline }
        catch { [void]$errors.Add("$Label final process-tree/stream convergence check failed: $($_.Exception.Message)") }
        if ($null -eq $convergence -or -not [bool]$convergence.Converged) {
            $liveText = if ($null -eq $convergence) { 'unknown' } else { @($convergence.LiveProcessIds) -join ',' }
            $streamText = if ($null -eq $convergence) { 'unknown' } else { @($convergence.PendingStreams) -join ', ' }
            $streamErrors = if ($null -eq $convergence) { 'unknown' } else { @($convergence.StreamErrors) -join ', ' }
            [void]$errors.Add("$Label cleanup did not converge before its deadline (pids=$liveText; streams=$streamText; streamErrors=$streamErrors).")
        }
    }

    $remainingProcessIds = @()
    try {
        $finalSnapshot = Get-PshGoal6ProcessSnapshot
        Add-PshGoal6ProcessTreeSnapshot -KnownProcesses $knownProcesses -Snapshot $finalSnapshot
        $remainingProcessIds = @(Get-PshGoal6LiveKnownProcessIds -KnownProcesses $knownProcesses -Snapshot $finalSnapshot)
    }
    catch { [void]$errors.Add("$Label final process-tree verification failed: $($_.Exception.Message)") }
    if ($remainingProcessIds.Count -ne 0) {
        [void]$errors.Add("$Label retained process ids after cleanup: $($remainingProcessIds -join ',').")
    }

    $stdout = '[stdout did not reach EOF before the Goal 6 process deadline]'
    $stderr = '[stderr did not reach EOF before the Goal 6 process deadline]'
    $outputState = Test-PshGoal6OutputTaskConvergence -StdoutTask $StdoutTask -StderrTask $StderrTask
    if ([bool]$outputState.Converged) {
        try {
            $stdout = [string]$StdoutTask.Result
            $stderr = [string]$StderrTask.Result
        }
        catch { [void]$errors.Add("$Label redirected output could not be collected after EOF: $($_.Exception.Message)") }
    }
    else {
        foreach ($outputError in @($outputState.Errors)) { [void]$errors.Add("$Label $outputError") }
        if (@($outputState.Pending).Count -ne 0) { [void]$errors.Add("$Label redirected output did not reach EOF: $(@($outputState.Pending) -join ',').") }
    }
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try { [IO.File]::WriteAllText($StdoutPath, $stdout, $utf8) }
    catch { [void]$errors.Add("$Label stdout log could not be retained at '$StdoutPath': $($_.Exception.Message)") }
    try { [IO.File]::WriteAllText($StderrPath, $stderr, $utf8) }
    catch { [void]$errors.Add("$Label stderr log could not be retained at '$StderrPath': $($_.Exception.Message)") }
    $fileState = Test-PshGoal6ProcessStreamConvergence -Path @($StdoutPath, $StderrPath)
    if (-not [bool]$fileState.Converged) {
        [void]$errors.Add("$Label retained stdout/stderr files did not converge: $(@($fileState.Pending + $fileState.Errors) -join ', ').")
    }
    try { $Process.Dispose() }
    catch { [void]$errors.Add("$Label process handle disposal failed: $($_.Exception.Message)") }

    return [pscustomobject][ordered]@{
        TimedOut = $timedOut
        ExitCode = if ($timedOut) { 124 } else { $exitCode }
        CleanupSucceeded = $errors.Count -eq 0
        CleanupErrors = $errors.ToArray()
        CapturedProcessIds = @($knownProcesses.Keys | ForEach-Object { [int]$_ } | Sort-Object)
        RemainingProcessIds = @($remainingProcessIds)
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
    }
}

function Assert-PshGoal6ProcessHarnessTimeoutRegression {
    param(
        [Parameter(Mandatory = $true)][string] $EnginePath,
        [Parameter(Mandatory = $true)][string] $ArtifactRoot,
        [Parameter(Mandatory = $true)][Text.Encoding] $Utf8
    )

    [void][IO.Directory]::CreateDirectory($ArtifactRoot)
    $stdoutPath = Join-Path $ArtifactRoot 'stdout.log'
    $stderrPath = Join-Path $ArtifactRoot 'stderr.log'
    $configPath = Join-Path $ArtifactRoot 'config.json'
    $grandchildCommand = @'
[Console]::Out.WriteLine('goal6-grandchild-stdout')
[Console]::Out.Flush()
[Console]::Error.WriteLine('goal6-grandchild-stderr')
[Console]::Error.Flush()
Start-Sleep -Seconds 60
'@
    $config = [pscustomobject][ordered]@{
        enginePath = $EnginePath
        grandchildEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($grandchildCommand))
    }
    [IO.File]::WriteAllText($configPath, (($config | ConvertTo-Json -Depth 3) + "`n"), $Utf8)
    $parentCommand = @'
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$configPath = [Environment]::GetEnvironmentVariable('PSH_GOAL6_HARNESS_CONFIG', 'Process')
$config = [IO.File]::ReadAllText($configPath, $utf8) | ConvertFrom-Json -ErrorAction Stop
[Console]::Out.WriteLine('goal6-parent-stdout')
[Console]::Out.Flush()
[Console]::Error.WriteLine('goal6-parent-stderr')
[Console]::Error.Flush()
$ErrorActionPreference = 'Continue'
& ([string]$config.enginePath) -NoLogo -NoProfile -NonInteractive -EncodedCommand ([string]$config.grandchildEncodedCommand)
exit $LASTEXITCODE
'@
    $encodedParentCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCommand))
    $oldConfig = [Environment]::GetEnvironmentVariable('PSH_GOAL6_HARNESS_CONFIG', 'Process')
    $process = $null
    $result = $null
    try {
        [Environment]::SetEnvironmentVariable('PSH_GOAL6_HARNESS_CONFIG', $configPath, 'Process')
        foreach ($streamPath in @($stdoutPath, $stderrPath)) {
            if ([IO.File]::Exists($streamPath)) { [IO.File]::Delete($streamPath) }
        }
        $started = Start-PshGoal6RedirectedProcess -FilePath $EnginePath -Arguments ("-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedParentCommand")
        $process = $started.Process
        $result = Complete-PshGoal6BoundedProcess -Process $process -TimeoutMilliseconds 5000 -StdoutPath $stdoutPath -StderrPath $stderrPath -StdoutTask $started.StdoutTask -StderrTask $started.StderrTask -ArtifactRoot $ArtifactRoot -Label 'Goal 6 process harness timeout regression' -DrainTimeoutMilliseconds 2000 -CleanupTimeoutMilliseconds 15000
    }
    finally {
        [Environment]::SetEnvironmentVariable('PSH_GOAL6_HARNESS_CONFIG', $oldConfig, 'Process')
        if ($null -ne $process) { $process.Dispose() }
    }
    if ($null -eq $result) { throw 'Goal 6 process harness timeout regression returned no bounded process result.' }
    if (-not [bool]$result.TimedOut) { throw 'Goal 6 process harness timeout regression did not exercise its timeout path.' }
    if (-not [bool]$result.CleanupSucceeded) { throw ('Goal 6 process harness timeout regression cleanup failed: ' + (@($result.CleanupErrors) -join '; ')) }
    if (@($result.CapturedProcessIds).Count -lt 2) { throw 'Goal 6 process harness timeout regression did not capture both parent and grandchild processes.' }
    if (@($result.RemainingProcessIds).Count -ne 0) { throw 'Goal 6 process harness timeout regression retained a child process.' }
    $stdout = [IO.File]::ReadAllText($stdoutPath, $Utf8)
    $stderr = [IO.File]::ReadAllText($stderrPath, $Utf8)
    foreach ($marker in @('goal6-parent-stdout', 'goal6-grandchild-stdout')) {
        if (-not $stdout.Contains($marker)) { throw "Goal 6 process harness stdout did not retain marker '$marker'." }
    }
    foreach ($marker in @('goal6-parent-stderr', 'goal6-grandchild-stderr')) {
        if (-not $stderr.Contains($marker)) { throw "Goal 6 process harness stderr did not retain marker '$marker'." }
    }
}
