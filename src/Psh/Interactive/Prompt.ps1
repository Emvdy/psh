# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

function Wait-PshPromptProcessStreams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Process,

        [Parameter(Mandatory = $true)]
        [object]$StandardOutputTask,

        [Parameter(Mandatory = $true)]
        [object]$StandardErrorTask,

        [ValidateRange(25, 2000)]
        [int]$TimeoutMilliseconds
    )

    $exited = $false
    $timedOut = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try {
            if ($Process.HasExited) {
                $exited = $true
                break
            }
        }
        catch {
            break
        }
        Start-Sleep -Milliseconds 5
    }

    if (-not $exited) {
        try {
            $exited = [bool]$Process.HasExited
        }
        catch {
            $exited = $false
        }
    }

    if (-not $exited) {
        $timedOut = $true
        try {
            $Process.Kill()
        }
        catch {
            # A raced exit or an already-terminated process is harmless.
        }

        $killWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($killWatch.ElapsedMilliseconds -lt 1000) {
            try {
                if ($Process.HasExited) {
                    $exited = $true
                    break
                }
            }
            catch {
                break
            }
            Start-Sleep -Milliseconds 5
        }
    }

    $stdoutReady = $false
    $stderrReady = $false
    try {
        $stdoutReady = [bool]$StandardOutputTask.Wait(1000)
    }
    catch {
    }
    try {
        $stderrReady = [bool]$StandardErrorTask.Wait(1000)
    }
    catch {
    }

    $stdout = $null
    $stderr = $null
    if ($stdoutReady) {
        try {
            $stdout = [string]$StandardOutputTask.Result
        }
        catch {
            $stdoutReady = $false
        }
    }
    if ($stderrReady) {
        try {
            $stderr = [string]$StandardErrorTask.Result
        }
        catch {
            $stderrReady = $false
        }
    }

    $exitCode = $null
    if ($exited) {
        try {
            $exitCode = [int]$Process.ExitCode
        }
        catch {
        }
    }

    return [PSCustomObject][ordered]@{
        exited      = $exited
        timedOut    = $timedOut
        stdoutReady = $stdoutReady
        stderrReady = $stderrReady
        stdout      = $stdout
        stderr      = $stderr
        exitCode    = $exitCode
    }
}

function Get-PshGitBranch {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$WorkingDirectory,

        [AllowNull()]
        [string]$GitExecutablePath,

        [ValidateRange(25, 2000)]
        [int]$TimeoutMilliseconds = 150
    )

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        try {
            $location = Get-Location -ErrorAction Stop
            if ($null -eq $location.Provider -or $location.Provider.Name -ne 'FileSystem') {
                return $null
            }
            $WorkingDirectory = [string]$location.ProviderPath
            if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
                $WorkingDirectory = [string]$location.Path
            }
        }
        catch {
            return $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($GitExecutablePath)) {
        $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction Ignore |
            Select-Object -First 1
        if ($null -eq $gitCommand) {
            return $null
        }
        $GitExecutablePath = [string]$gitCommand.Source
        if ([string]::IsNullOrWhiteSpace($GitExecutablePath)) {
            $GitExecutablePath = [string]$gitCommand.Path
        }
        if ([string]::IsNullOrWhiteSpace($GitExecutablePath)) {
            return $null
        }
    }

    $process = $null
    $standardOutputTask = $null
    $standardErrorTask = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $GitExecutablePath
        $startInfo.Arguments = 'symbolic-ref --quiet --short HEAD'
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
        $startInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            return $null
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $processResult = Wait-PshPromptProcessStreams `
            -Process $process `
            -StandardOutputTask $standardOutputTask `
            -StandardErrorTask $standardErrorTask `
            -TimeoutMilliseconds $TimeoutMilliseconds
        if ($processResult.timedOut -or -not $processResult.exited -or
            -not $processResult.stdoutReady -or -not $processResult.stderrReady) {
            return $null
        }
        $standardOutput = [string]$processResult.stdout
        [void]$processResult.stderr
        if ($processResult.exitCode -ne 0) {
            return $null
        }

        $branch = ([string]$standardOutput).Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            return $null
        }

        return (($branch -replace '[\r\n\t]+', ' ').Trim())
    }
    catch {
        # Prompt rendering must remain quiet when git is absent or unavailable.
        return $null
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-PshPromptText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$PreviousCommandSucceeded,

        [AllowNull()]
        [string]$Path,

        [switch]$IncludeGit,

        [AllowNull()]
        [string]$GitExecutablePath,

        [ValidateRange(25, 2000)]
        [int]$GitTimeoutMilliseconds = 150,

        [AllowNull()]
        [scriptblock]$GitBranchResolver
    )

    $workingDirectory = $null
    if ([string]::IsNullOrWhiteSpace($Path)) {
        try {
            $location = Get-Location -ErrorAction Stop
            $Path = [string]$location.Path
            if ($null -ne $location.Provider -and $location.Provider.Name -eq 'FileSystem') {
                $workingDirectory = [string]$location.ProviderPath
                if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
                    $workingDirectory = $Path
                }
            }
        }
        catch {
            $Path = '?'
        }
    }
    else {
        $workingDirectory = $Path
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = '?'
    }

    $status = '1'
    if ($PreviousCommandSucceeded) {
        $status = '0'
    }

    $branchText = ''
    if ($IncludeGit) {
        try {
            if ($null -ne $GitBranchResolver) {
                $branch = & $GitBranchResolver -WorkingDirectory $workingDirectory -GitExecutablePath $GitExecutablePath -TimeoutMilliseconds $GitTimeoutMilliseconds
            }
            else {
                $branch = Get-PshGitBranch -WorkingDirectory $workingDirectory -GitExecutablePath $GitExecutablePath -TimeoutMilliseconds $GitTimeoutMilliseconds
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$branch)) {
                $branchText = ' (git:{0})' -f [string]$branch
            }
        }
        catch {
            # The path/status prompt is the guaranteed non-VT and no-git fallback.
        }
    }

    return ('[{0}] {1}{2}> ' -f $status, $Path, $branchText)
}

function Set-PshPrompt {
    [CmdletBinding()]
    param(
        [switch]$DisableGit,

        [AllowNull()]
        [string]$GitExecutablePath,

        [ValidateRange(25, 2000)]
        [int]$GitTimeoutMilliseconds = 150
    )

    $existingPrompt = Get-Command -Name 'prompt' -CommandType Function -ErrorAction Ignore
    $renderer = ${function:Get-PshPromptText}
    $gitBranchResolver = ${function:Get-PshGitBranch}
    $includeGit = -not [bool]$DisableGit
    $timeout = $GitTimeoutMilliseconds
    $gitPath = $GitExecutablePath

    $promptScriptBlock = {
        $previousCommandSucceeded = $?
        $lastExitVariable = Get-Variable -Name 'LASTEXITCODE' -Scope Global -ErrorAction Ignore
        $hadLastExitCode = ($null -ne $lastExitVariable)
        $previousLastExitCode = $null
        if ($hadLastExitCode) {
            $previousLastExitCode = $lastExitVariable.Value
        }
        try {
            & $renderer `
                -PreviousCommandSucceeded $previousCommandSucceeded `
                -IncludeGit:$includeGit `
                -GitExecutablePath $gitPath `
                -GitTimeoutMilliseconds $timeout `
                -GitBranchResolver $gitBranchResolver
        }
        finally {
            if ($hadLastExitCode) {
                $global:LASTEXITCODE = $previousLastExitCode
            }
            else {
                Remove-Variable -Name 'LASTEXITCODE' -Scope Global -ErrorAction Ignore
            }
        }
    }.GetNewClosure()

    try {
        Set-Item -Path 'Function:\global:prompt' -Value $promptScriptBlock -Force -ErrorAction Stop
        return [PSCustomObject][ordered]@{
            requested        = $true
            enabled          = $true
            replacedExisting = ($null -ne $existingPrompt)
            style            = 'PlainAscii'
            gitEnabled       = $includeGit
            gitAvailable     = -not [string]::IsNullOrWhiteSpace($gitPath)
            gitTimeoutMs     = $timeout
            error            = $null
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            requested        = $true
            enabled          = $false
            replacedExisting = $false
            style            = 'PlainAscii'
            gitEnabled       = $includeGit
            gitAvailable     = -not [string]::IsNullOrWhiteSpace($gitPath)
            gitTimeoutMs     = $timeout
            error            = [string]$_.Exception.Message
        }
    }
}
