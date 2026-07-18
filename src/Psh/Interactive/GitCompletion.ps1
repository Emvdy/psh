# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

$script:PshGitCompletionRegistered = $false
$script:PshGitCompletionExecutablePath = $null
$script:PshGitCompletionRegistrar = $null
$script:PshGitCompletionRegistrationSyntax = $null

function Get-PshGitCompletionCommands {
    [CmdletBinding()]
    param()

    return @(
        'add', 'am', 'bisect', 'blame', 'branch', 'bundle', 'checkout',
        'cherry-pick', 'clean', 'clone', 'commit', 'config', 'describe',
        'diff', 'fetch', 'format-patch', 'gc', 'grep', 'help', 'init', 'log',
        'merge', 'mergetool', 'mv', 'notes', 'pull', 'push', 'range-diff',
        'rebase', 'reflog', 'remote', 'reset', 'restore', 'revert', 'rm',
        'shortlog', 'show', 'show-branch', 'sparse-checkout', 'stash',
        'status', 'submodule', 'switch', 'tag', 'worktree'
    )
}

function Get-PshGitCompletionAstText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$CommandElement
    )

    $valueProperty = $CommandElement.PSObject.Properties['Value']
    if ($null -ne $valueProperty -and $null -ne $valueProperty.Value) {
        return [string]$valueProperty.Value
    }

    $text = [string]$CommandElement.Extent.Text
    if ($text.Length -ge 2) {
        if (($text[0] -eq "'" -and $text[$text.Length - 1] -eq "'") -or
            ($text[0] -eq '"' -and $text[$text.Length - 1] -eq '"')) {
            return $text.Substring(1, $text.Length - 2)
        }
    }
    return $text
}

function New-PshGitCompletionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CompletionText,

        [Parameter(Mandatory = $true)]
        [string]$ToolTip
    )

    # PowerShell 5.1 can bind New-Object's generic constructor arguments to a
    # PSObject wrapper instead of the CompletionResult overload. Invoke the
    # reflected constructor with a concrete object[] to keep the result type.
    $constructor = @(
        [System.Management.Automation.CompletionResult].GetConstructors() |
            Where-Object {
                $parameters = $_.GetParameters()
                $parameters.Count -eq 4 -and
                    $parameters[0].ParameterType -eq [string] -and
                    $parameters[1].ParameterType -eq [string] -and
                    $parameters[2].ParameterType -eq [System.Management.Automation.CompletionResultType] -and
                    $parameters[3].ParameterType -eq [string]
            }
    ) | Select-Object -First 1
    if ($null -eq $constructor) {
        throw 'The required CompletionResult constructor is unavailable.'
    }
    $arguments = New-Object object[] 4
    $arguments[0] = $CompletionText
    $arguments[1] = $CompletionText
    $arguments[2] = [System.Management.Automation.CompletionResultType]::ParameterValue
    $arguments[3] = $ToolTip
    return $constructor.Invoke($arguments)
}

function Get-PshGitCompletionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$CommandAst,

        [Parameter(Mandatory = $true)]
        [int]$CursorPosition
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    $commandElements = $CommandAst.CommandElements
    if ($null -ne $commandElements -and $null -ne $commandElements.PSObject.BaseObject) {
        # Windows PowerShell 5.1 sometimes exposes ReadOnlyCollection through a
        # PSObject wrapper; unwrap it before enumeration.
        $commandElements = $commandElements.PSObject.BaseObject
    }
    foreach ($element in @($commandElements)) {
        if ($element.Extent.StartOffset -ge $CursorPosition) {
            continue
        }
        $tokens.Add((Get-PshGitCompletionAstText -CommandElement $element))
    }

    $subcommand = $null
    $subcommandIndex = -1
    $workingDirectory = $null
    for ($index = 1; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        if ($token -ceq '-C' -and ($index + 1) -lt $tokens.Count) {
            $index++
            $workingDirectory = [string]$tokens[$index]
            continue
        }
        if ($token -like '-C*' -and $token.Length -gt 2) {
            $workingDirectory = $token.Substring(2)
            continue
        }
        if ($token.StartsWith('-')) {
            continue
        }
        $subcommand = $token
        $subcommandIndex = $index
        break
    }

    if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
        try {
            $location = Get-Location -ErrorAction Stop
            if ($null -ne $location.Provider -and $location.Provider.Name -eq 'FileSystem') {
                $workingDirectory = [string]$location.ProviderPath
                if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
                    $workingDirectory = [string]$location.Path
                }
            }
        }
        catch {
            $workingDirectory = $null
        }
    }
    elseif (-not [IO.Path]::IsPathRooted($workingDirectory)) {
        try {
            $workingDirectory = [IO.Path]::GetFullPath((Join-Path -Path ([string](Get-Location)) -ChildPath $workingDirectory))
        }
        catch {
            $workingDirectory = $null
        }
    }

    return [PSCustomObject][ordered]@{
        tokens           = $tokens.ToArray()
        subcommand       = $subcommand
        subcommandIndex  = $subcommandIndex
        workingDirectory = $workingDirectory
    }
}

function Wait-PshGitProcessStreams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Process,

        [Parameter(Mandatory = $true)]
        [object]$StandardOutputTask,

        [Parameter(Mandatory = $true)]
        [object]$StandardErrorTask,

        [ValidateRange(25, 2000)]
        [int]$TimeoutMilliseconds = 250
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

        # Keep this wait bounded. The async readers were started before the
        # process wait, so killing a producer cannot leave a full pipe blocked.
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

function Get-PshGitRefNames {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$WorkingDirectory,

        [AllowNull()]
        [string]$GitExecutablePath,

        [ValidateRange(25, 2000)]
        [int]$TimeoutMilliseconds = 250
    )

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or
        -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($GitExecutablePath)) {
        $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction Ignore |
            Select-Object -First 1
        if ($null -eq $gitCommand) {
            return @()
        }
        $GitExecutablePath = [string]$gitCommand.Source
        if ([string]::IsNullOrWhiteSpace($GitExecutablePath)) {
            $GitExecutablePath = [string]$gitCommand.Path
        }
        if ([string]::IsNullOrWhiteSpace($GitExecutablePath)) {
            return @()
        }
    }

    $process = $null
    $standardOutputTask = $null
    $standardErrorTask = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $GitExecutablePath
        $startInfo.Arguments = 'for-each-ref --format=%(refname:short) refs/heads refs/remotes refs/tags'
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
            return @()
        }
        # Start both asynchronous readers before polling the process. Waiting
        # for exit first can deadlock when either redirected pipe fills.
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $processResult = Wait-PshGitProcessStreams `
            -Process $process `
            -StandardOutputTask $standardOutputTask `
            -StandardErrorTask $standardErrorTask `
            -TimeoutMilliseconds $TimeoutMilliseconds
        if ($processResult.timedOut -or -not $processResult.exited -or
            -not $processResult.stdoutReady -or -not $processResult.stderrReady) {
            return @()
        }
        $standardOutput = [string]$processResult.stdout
        [void]$processResult.stderr
        if ($processResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($standardOutput)) {
            return @()
        }

        return @(
            $standardOutput -split '[\r\n]+' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique |
                Select-Object -First 4096
        )
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Register-PshGitCompletion {
    [CmdletBinding()]
    param(
        [ValidateRange(25, 2000)]
        [int]$TimeoutMilliseconds = 250
    )

    $result = [ordered]@{
        registered        = $false
        alreadyRegistered = $script:PshGitCompletionRegistered
        mode              = 'PshOfflineNativeCompleter'
        commandNames      = @('git', 'git.exe')
        gitAvailable      = $false
        gitPath           = $script:PshGitCompletionExecutablePath
        registrar         = $script:PshGitCompletionRegistrar
        registrationSyntax = $script:PshGitCompletionRegistrationSyntax
        timeoutMs         = $TimeoutMilliseconds
        error             = $null
    }

    try {
        $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction Ignore | Select-Object -First 1
        if ($null -ne $gitCommand) {
            $script:PshGitCompletionExecutablePath = [string]$gitCommand.Source
            if ([string]::IsNullOrWhiteSpace($script:PshGitCompletionExecutablePath)) {
                $script:PshGitCompletionExecutablePath = [string]$gitCommand.Path
            }
        }
        $result.gitPath = $script:PshGitCompletionExecutablePath
        $result.gitAvailable = -not [string]::IsNullOrWhiteSpace($script:PshGitCompletionExecutablePath)
        $registrarCommand = Get-Command `
            -Name 'Register-ArgumentCompleter' `
            -CommandType Cmdlet `
            -ErrorAction Stop

        $staticCommands = @(Get-PshGitCompletionCommands)
        $contextResolver = ${function:Get-PshGitCompletionContext}
        $refResolver = ${function:Get-PshGitRefNames}
        $resultFactory = ${function:New-PshGitCompletionResult}
        $timeout = $TimeoutMilliseconds
        $gitPath = $script:PshGitCompletionExecutablePath
        $refCommands = @(
            'branch', 'checkout', 'cherry-pick', 'diff', 'log', 'merge',
            'rebase', 'reset', 'revert', 'show', 'switch', 'tag'
        )

        $completer = {
            param($wordToComplete, $commandAst, $cursorPosition)

            $word = [string]$wordToComplete
            $context = & $contextResolver -CommandAst $commandAst -CursorPosition $cursorPosition
            $candidates = @()
            $toolTipPrefix = 'git command'
            $completingSubcommand = [string]::IsNullOrWhiteSpace([string]$context.subcommand) -or
                ($context.subcommandIndex -eq ($context.tokens.Count - 1) -and
                    -not [string]::IsNullOrEmpty($word))
            if ($completingSubcommand) {
                $candidates = $staticCommands
            }
            elseif ($refCommands -contains [string]$context.subcommand) {
                $candidates = @(& $refResolver -WorkingDirectory $context.workingDirectory -GitExecutablePath $gitPath -TimeoutMilliseconds $timeout)
                $toolTipPrefix = 'git ref'
            }

            $pattern = [System.Management.Automation.WildcardPattern]::Escape($word) + '*'
            foreach ($candidate in @($candidates | Sort-Object -Unique)) {
                $candidateText = [string]$candidate
                if ($candidateText -notlike $pattern) {
                    continue
                }
                & $resultFactory `
                    -CompletionText $candidateText `
                    -ToolTip ("{0}: {1}" -f $toolTipPrefix, $candidateText)
            }
        }.GetNewClosure()

        # Engine registration replaces the two command-name entries. Repeating
        # it is idempotent, repairs later overwrites, and refreshes the timeout.
        if ($registrarCommand.Parameters.ContainsKey('Native')) {
            & $registrarCommand `
                -Native `
                -CommandName @('git', 'git.exe') `
                -ScriptBlock $completer
            $script:PshGitCompletionRegistrationSyntax = 'ExplicitNativeSwitch'
        }
        else {
            # `CommandName` plus `ScriptBlock`, with no `ParameterName`, selects
            # the native parameter set on Windows PowerShell 5.1 runtimes that
            # do not expose the optional `Native` switch.
            & $registrarCommand `
                -CommandName @('git', 'git.exe') `
                -ScriptBlock $completer
            $script:PshGitCompletionRegistrationSyntax = 'ImplicitNativeParameterSet'
        }
        $script:PshGitCompletionRegistrar = 'NativeArgumentCompleter'
        $script:PshGitCompletionRegistered = $true
        $result.registered = $true
        $result.registrar = $script:PshGitCompletionRegistrar
        $result.registrationSyntax = $script:PshGitCompletionRegistrationSyntax
    }
    catch {
        $result.error = [string]$_.Exception.Message
    }

    return [PSCustomObject]$result
}
