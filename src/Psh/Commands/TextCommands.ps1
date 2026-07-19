# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# Text-command wrappers use $args so unsupported native-style options can be
# rejected explicitly with Psh's stable usage exit code.

$script:PshTextCommandNames = @(
    'cat', 'bat', 'head', 'tail', 'grep', 'rg', 'sed', 'awk', 'jq', 'cut',
    'tr', 'sort', 'uniq', 'wc', 'tee', 'xargs', 'printf', 'echo', 'base64'
)
$script:PshRawByteSink = $null

function Get-PshEnabledTextCommandNames {
    $enabled = @()
    foreach ($name in $script:PshTextCommandNames) {
        if (-not $script:PshDisabledCommands.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function ConvertFrom-PshByteValues {
    param(
        [AllowNull()]
        [byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $characters = New-Object char[] $Bytes.Length
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        $characters[$index] = [char][int]$Bytes[$index]
    }
    return (-join $characters)
}

function ConvertTo-PshDecodedText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $text = ''
    $encodingName = 'utf-8'
    $binary = $false
    try {
        if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255) {
            $encodingName = 'utf-32be'
            $encoding = New-Object Text.UTF32Encoding($true, $true, $true)
            $text = $encoding.GetString($Bytes, 4, $Bytes.Length - 4)
        }
        elseif ($Bytes.Length -ge 4 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
            $encodingName = 'utf-32le'
            $encoding = New-Object Text.UTF32Encoding($false, $true, $true)
            $text = $encoding.GetString($Bytes, 4, $Bytes.Length - 4)
        }
        elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
            $encodingName = 'utf-8-bom'
            $encoding = New-Object Text.UTF8Encoding($false, $true)
            $text = $encoding.GetString($Bytes, 3, $Bytes.Length - 3)
        }
        elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
            $encodingName = 'utf-16le'
            $encoding = New-Object Text.UnicodeEncoding($false, $true, $true)
            $text = $encoding.GetString($Bytes, 2, $Bytes.Length - 2)
        }
        elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
            $encodingName = 'utf-16be'
            $encoding = New-Object Text.UnicodeEncoding($true, $true, $true)
            $text = $encoding.GetString($Bytes, 2, $Bytes.Length - 2)
        }
        else {
            $encoding = New-Object Text.UTF8Encoding($false, $true)
            $text = $encoding.GetString($Bytes)
        }
    }
    catch {
        $binary = $true
        $encodingName = 'binary'
        $text = ConvertFrom-PshByteValues -Bytes $Bytes
    }

    if (-not $binary) {
        foreach ($character in $text.ToCharArray()) {
            $code = [int]$character
            if (($code -lt 32 -and $code -notin @(9, 10, 13)) -or $code -eq 127) {
                $binary = $true
                break
            }
        }
    }
    return [PSCustomObject]@{
        Text = [string]$text
        Encoding = $encodingName
        IsBinary = [bool]$binary
    }
}

function ConvertTo-PshUtf8Bytes {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) { $Text = '' }
    $encoding = New-Object Text.UTF8Encoding($false)
    return $encoding.GetBytes($Text)
}

function Write-PshRawBytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -eq 0) { return }
    $stream = $script:PshRawByteSink
    if ($null -eq $stream) {
        $stream = [Console]::OpenStandardOutput()
    }
    $stream.Write($Bytes, 0, $Bytes.Length)
    $stream.Flush()
}

function Test-PshInvocationHasDownstream {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.InvocationInfo]$Invocation
    )

    return ([int]$Invocation.PipelinePosition -lt [int]$Invocation.PipelineLength)
}

function ConvertFrom-PshStrictUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $encoding = New-Object Text.UTF8Encoding($false, $true)
    return $encoding.GetString($Bytes)
}

function Test-PshBytesRequireRawOutput {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    try { $text = ConvertFrom-PshStrictUtf8Bytes -Bytes $Bytes }
    catch { return $true }
    foreach ($character in $text.ToCharArray()) {
        $code = [int]$character
        if (($code -lt 32 -and $code -notin @(9, 10, 13)) -or $code -eq 127) { return $true }
    }
    return $false
}

function Stop-PshDownstreamUsageFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Set-PshLastExitCode -Code 2
    $exception = New-Object InvalidOperationException(('{0}: usage error: {1}' -f $Command, $Message))
    $exception.Data['PshExitCode'] = 2
    throw $exception
}

function New-PshPipelineTextSource {
    param(
        [AllowNull()]
        [object[]]$Items
    )

    $values = @($Items)
    $byteValues = New-Object 'System.Collections.Generic.List[byte]'
    $hasRawByteInput = $false
    $previousWasByteInput = $false
    for ($index = 0; $index -lt $values.Count; $index++) {
        $value = $values[$index]
        $isByteInput = $value -is [byte[]]
        if ($index -gt 0 -and -not ($previousWasByteInput -and $isByteInput)) { $byteValues.Add([byte]10) }
        if ($null -ne $value) {
            if ($isByteInput) {
                $hasRawByteInput = $true
                foreach ($byteValue in [byte[]]$value) { $byteValues.Add($byteValue) }
            }
            else {
                foreach ($byteValue in [byte[]](ConvertTo-PshUtf8Bytes -Text ([string]$value))) { $byteValues.Add($byteValue) }
            }
        }
        $previousWasByteInput = $isByteInput
    }
    $bytes = $byteValues.ToArray()
    $decoded = ConvertTo-PshDecodedText -Bytes $bytes
    return [PSCustomObject]@{
        Operand = '-'
        Path = $null
        DisplayName = '(standard input)'
        Text = [string]$decoded.Text
        Bytes = [byte[]]$bytes
        Encoding = [string]$decoded.Encoding
        IsBinary = [bool]($decoded.IsBinary -or $hasRawByteInput)
        HasRawByteInput = [bool]$hasRawByteInput
        IsStandardInput = $true
    }
}

function Read-PshTextFileSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operand
    )

    $path = Resolve-PshFileSystemPath -Path $Operand
    if (-not [IO.File]::Exists($path)) {
        throw ('not a regular file: {0}' -f $Operand)
    }
    $bytes = [IO.File]::ReadAllBytes($path)
    $decoded = ConvertTo-PshDecodedText -Bytes $bytes
    return [PSCustomObject]@{
        Operand = $Operand
        Path = $path
        DisplayName = $Operand
        Text = [string]$decoded.Text
        Bytes = [byte[]]$bytes
        Encoding = [string]$decoded.Encoding
        IsBinary = [bool]$decoded.IsBinary
        HasRawByteInput = $false
        IsStandardInput = $false
    }
}

function Get-PshTextSources {
    param(
        [AllowEmptyCollection()]
        [string[]]$Paths = @(),

        [AllowNull()]
        [object[]]$PipelineItems
    )

    $sources = @()
    $operands = @($Paths)
    if ($operands.Count -eq 0) {
        return ,(New-PshPipelineTextSource -Items $PipelineItems)
    }

    $standardInputConsumed = $false
    foreach ($operand in $operands) {
        if ($operand -ceq '-') {
            if ($standardInputConsumed) {
                $sources += New-PshPipelineTextSource -Items @()
            }
            else {
                $sources += New-PshPipelineTextSource -Items $PipelineItems
                $standardInputConsumed = $true
            }
        }
        else {
            $sources += Read-PshTextFileSource -Operand $operand
        }
    }
    return $sources
}

function Split-PshTextLines {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = @()
    $matches = [Text.RegularExpressions.Regex]::Matches($Text, "`r`n|`n|`r")
    $start = 0
    foreach ($match in $matches) {
        $lines += [PSCustomObject]@{
            Text = $Text.Substring($start, $match.Index - $start)
            Terminator = $match.Value
        }
        $start = $match.Index + $match.Length
    }
    if ($start -lt $Text.Length) {
        $lines += [PSCustomObject]@{
            Text = $Text.Substring($start)
            Terminator = ''
        }
    }
    return $lines
}

function Write-PshTextValue {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [switch]$EmitEmpty
    )

    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt 0 -or $EmitEmpty) {
        Microsoft.PowerShell.Utility\Write-Output ([string]$Text)
    }
}

function ConvertTo-PshVisibleText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) { return '' }
    $builder = New-Object Text.StringBuilder
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        if ($code -eq 9) { [void]$builder.Append('^I') }
        elseif ($code -lt 32) {
            [void]$builder.Append('^')
            [void]$builder.Append([char]($code + 64))
        }
        elseif ($code -eq 127) { [void]$builder.Append('^?') }
        else { [void]$builder.Append($character) }
    }
    return $builder.ToString()
}

function Format-PshCatSources {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Sources,

        [switch]$NumberAll,

        [switch]$NumberNonBlank,

        [switch]$SqueezeBlank,

        [switch]$ShowAll
    )

    $builder = New-Object Text.StringBuilder
    $lineNumber = 1
    $previousBlank = $false
    foreach ($source in $Sources) {
        if (-not $NumberAll -and -not $NumberNonBlank -and -not $SqueezeBlank -and -not $ShowAll) {
            [void]$builder.Append([string]$source.Text)
            continue
        }
        foreach ($line in @(Split-PshTextLines -Text ([string]$source.Text))) {
            $blank = ([string]$line.Text).Length -eq 0
            if ($SqueezeBlank -and $blank -and $previousBlank) { continue }
            $previousBlank = $blank
            $value = [string]$line.Text
            if ($ShowAll) { $value = ConvertTo-PshVisibleText -Text $value }
            if ($NumberNonBlank -and -not $blank) {
                $value = ("{0,6}`t{1}" -f $lineNumber, $value)
                $lineNumber++
            }
            elseif ($NumberAll) {
                $value = ("{0,6}`t{1}" -f $lineNumber, $value)
                $lineNumber++
            }
            [void]$builder.Append($value)
            if ($ShowAll -and ([string]$line.Terminator).Length -gt 0) {
                [void]$builder.Append('$')
            }
            [void]$builder.Append([string]$line.Terminator)
        }
    }
    return $builder.ToString()
}

function Resolve-PshPinnedTextTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $moduleRoot = $null
    if ($null -ne $ExecutionContext.SessionState.Module) {
        $moduleRoot = [string]$ExecutionContext.SessionState.Module.ModuleBase
    }
    if ([string]::IsNullOrWhiteSpace($moduleRoot)) {
        $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
    }
    $lockCandidates = @(
        (Join-Path -Path (Join-Path -Path $moduleRoot -ChildPath 'Dependencies') -ChildPath 'native-tools.lock.json'),
        (Join-Path -Path (Join-Path -Path $moduleRoot -ChildPath 'Tools') -ChildPath 'native-tools.lock.json')
    )
    foreach ($lockPath in $lockCandidates) {
        if (-not [IO.File]::Exists($lockPath)) { continue }
        try {
            $lock = [IO.File]::ReadAllText($lockPath, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json -ErrorAction Stop
            $entry = Get-PshNativeToolEntry -Lock $lock -Name $Name
            if ($null -eq $entry) { continue }
            $relativePath = Get-PshPropertyValue -InputObject $entry -Name 'Path'
            if ($null -eq $relativePath) { $relativePath = Get-PshPropertyValue -InputObject $entry -Name 'File' }
            $sha256 = Get-PshPropertyValue -InputObject $entry -Name 'Sha256'
            if ([string]::IsNullOrWhiteSpace([string]$relativePath) -or [string]::IsNullOrWhiteSpace([string]$sha256)) {
                return [PSCustomObject]@{ Code = 5; Message = ('the pinned {0} entry lacks Path or Sha256.' -f $Name); Path = $null }
            }
            $toolPath = [IO.Path]::GetFullPath((Join-Path -Path ([IO.Path]::GetDirectoryName($lockPath)) -ChildPath ([string]$relativePath)))
            if (-not [IO.File]::Exists($toolPath)) {
                return [PSCustomObject]@{ Code = 4; Message = ('the pinned {0} executable is missing.' -f $Name); Path = $null }
            }
            $actual = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $toolPath -Algorithm SHA256 -ErrorAction Stop).Hash
            if (-not [string]::Equals([string]$actual, ([string]$sha256).Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                return [PSCustomObject]@{ Code = 5; Message = ('the pinned {0} executable failed SHA256 verification.' -f $Name); Path = $null }
            }
            return [PSCustomObject]@{ Code = 0; Message = ''; Path = $toolPath }
        }
        catch {
            return [PSCustomObject]@{ Code = 5; Message = ('cannot verify the pinned {0} tool: {1}' -f $Name, $_.Exception.Message); Path = $null }
        }
    }
    return [PSCustomObject]@{ Code = 4; Message = ('the pinned {0} dependency is unavailable.' -f $Name); Path = $null }
}

function ConvertTo-PshWindowsCommandLineArgument {
    param(
        [AllowNull()]
        [string]$Argument
    )

    if ($null -eq $Argument) { $Argument = '' }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            for ($index = 0; $index -lt (($backslashes * 2) + 1); $index++) { [void]$builder.Append('\') }
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        for ($index = 0; $index -lt $backslashes; $index++) { [void]$builder.Append('\') }
        $backslashes = 0
        [void]$builder.Append($character)
    }
    for ($index = 0; $index -lt ($backslashes * 2); $index++) { [void]$builder.Append('\') }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Set-PshProcessArguments {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.ProcessStartInfo]$StartInfo,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )

    $argumentListProperty = $StartInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $Arguments) { [void]$StartInfo.ArgumentList.Add([string]$argument) }
        return
    }
    $quoted = @()
    foreach ($argument in $Arguments) { $quoted += ConvertTo-PshWindowsCommandLineArgument -Argument $argument }
    $StartInfo.Arguments = $quoted -join ' '
}

function ConvertFrom-PshProcessOutputBytes {
    param(
        [AllowNull()]
        [byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @() }
    $text = ConvertFrom-PshStrictUtf8Bytes -Bytes $Bytes
    $lines = New-Object System.Collections.ArrayList
    foreach ($line in @(Split-PshTextLines -Text $text)) { [void]$lines.Add([string]$line.Text) }
    return [object[]]$lines.ToArray()
}

function Invoke-PshCapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [AllowNull()][byte[]]$StandardInputBytes,
        [bool]$RedirectStandardInput = $false,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if ($null -eq $StandardInputBytes) { $StandardInputBytes = [byte[]]@() }
    $launchPath = $FilePath
    $launchArguments = @($Arguments)
    if ([string]::Equals([IO.Path]::GetExtension($FilePath), '.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        $launchPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $launchArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FilePath) + @($Arguments)
    }

    $process = $null
    $stdoutBuffer = New-Object IO.MemoryStream
    $stderrBuffer = New-Object IO.MemoryStream
    $stdoutTask = $null
    $stderrTask = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $launchPath
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $RedirectStandardInput
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        Set-PshProcessArguments -StartInfo $startInfo -Arguments $launchArguments

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw ('failed to start process: {0}' -f $FilePath) }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrBuffer)
        if ($RedirectStandardInput) {
            try {
                if ($StandardInputBytes.Length -gt 0) {
                    $process.StandardInput.BaseStream.Write($StandardInputBytes, 0, $StandardInputBytes.Length)
                    $process.StandardInput.BaseStream.Flush()
                }
            }
            catch [IO.IOException] {
                # A child may exit successfully without consuming all redirected input.
            }
            catch [ObjectDisposedException] {
                # The child closed its input pipe before the parent finished writing.
            }
            finally {
                try { $process.StandardInput.Close() }
                catch [IO.IOException] {}
                catch [ObjectDisposedException] {}
            }
        }

        $process.WaitForExit()
        $stdoutTask.Wait()
        $stderrTask.Wait()
        $stdoutBytes = [byte[]]$stdoutBuffer.ToArray()
        $stderrBytes = [byte[]]$stderrBuffer.ToArray()
        return [PSCustomObject]@{
            ExitCode = [int]$process.ExitCode
            StdOutBytes = $stdoutBytes
            StdErrBytes = $stderrBytes
            StdOut = [object[]]@(ConvertFrom-PshProcessOutputBytes -Bytes $stdoutBytes)
            StdErr = [object[]]@(ConvertFrom-PshProcessOutputBytes -Bytes $stderrBytes)
        }
    }
    finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch {}
            $process.Dispose()
        }
        $stdoutBuffer.Dispose()
        $stderrBuffer.Dispose()
    }
}

function Invoke-PshPinnedTextTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [AllowNull()]
        [object[]]$PipelineItems,

        [bool]$PipelineExpected = $false
    )

    $native = Resolve-PshPinnedTextTool -Name $Name
    if ([int]$native.Code -ne 0) {
        Write-PshCommandFailure -Command $Name -Code ([int]$native.Code) -Message ([string]$native.Message)
        return
    }
    try {
        $inputBytes = [byte[]]@()
        if ($PipelineExpected) { $inputBytes = [byte[]](New-PshPipelineTextSource -Items $PipelineItems).Bytes }
        $location = Get-Location
        if ($null -eq $location.Provider -or -not [string]::Equals([string]$location.Provider.Name, 'FileSystem', [StringComparison]::OrdinalIgnoreCase)) {
            Throw-PshTextUsageError ('{0} requires a FileSystem current location for native process execution.' -f $Name)
        }
        $result = Invoke-PshCapturedProcess -FilePath ([string]$native.Path) -Arguments $Arguments -StandardInputBytes $inputBytes -RedirectStandardInput:$PipelineExpected -WorkingDirectory ([string]$location.ProviderPath)
        foreach ($line in @($result.StdOut)) { Microsoft.PowerShell.Utility\Write-Output ([string]$line) }
        foreach ($line in @($result.StdErr)) { Microsoft.PowerShell.Utility\Write-Output ([string]$line) }
        $nativeExit = [int]$result.ExitCode
        if ($nativeExit -in @(0, 1, 2)) { Set-PshLastExitCode -Code $nativeExit }
        else { Set-PshLastExitCode -Code 3 }
    }
    catch {
        Write-PshCommandFailure -Command $Name -Code 3 -Message $_.Exception.Message
    }
}

function cat {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: cat [-nbsA] [file ...]'
        return
    }

    $numberAll = $false
    $numberNonBlank = $false
    $squeezeBlank = $false
    $showAll = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('n', 'b', 's', 'A'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'cat' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -ceq 'n') { $numberAll = $true }
                elseif ($option -ceq 'b') { $numberNonBlank = $true }
                elseif ($option -ceq 's') { $squeezeBlank = $true }
                elseif ($option -ceq 'A') { $showAll = $true }
            }
            continue
        }
        $paths += $argument
    }
    if ($numberNonBlank) { $numberAll = $false }

    try {
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems)
        if (-not $numberAll -and -not $numberNonBlank -and -not $squeezeBlank -and -not $showAll) {
            $requiresRaw = @($sources | Where-Object { $_.IsBinary -or [string]$_.Encoding -cne 'utf-8' }).Count -gt 0
            if ($requiresRaw) {
                if (Test-PshInvocationHasDownstream -Invocation $MyInvocation) {
                    Write-PshCommandFailure -Command 'cat' -Code 2 -Message 'binary or non-UTF-8 cat output requires raw stdout and cannot enter the PowerShell object pipeline.'
                    return
                }
                foreach ($source in $sources) { Write-PshRawBytes -Bytes ([byte[]]$source.Bytes) }
            }
            else {
                foreach ($source in $sources) { Write-PshTextValue -Text ([string]$source.Text) }
            }
        }
        else {
            if (@($sources | Where-Object { $_.IsBinary }).Count -gt 0) {
                Write-PshCommandFailure -Command 'cat' -Code 2 -Message 'cat text transformations do not accept binary input.'
                return
            }
            $text = Format-PshCatSources -Sources $sources -NumberAll:$numberAll -NumberNonBlank:$numberNonBlank -SqueezeBlank:$squeezeBlank -ShowAll:$showAll
            Write-PshTextValue -Text $text
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'cat' -Code 3 -Message $_.Exception.Message
    }
}

function bat {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if ((Resolve-PshEdition) -eq 'Full') {
        Invoke-PshPinnedTextTool -Name 'bat' -Arguments $arguments -PipelineItems $pipelineItems -PipelineExpected:([bool]$MyInvocation.ExpectingInput)
        return
    }
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: bat [-npA] [-l language] [--style plain|numbers] [--color never|auto] [--paging never] [file ...]'
        return
    }

    $number = $false
    $showAll = $false
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -cin @('--number', '--plain')) {
            if ($argument -ceq '--number') { $number = $true }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and -not $argument.StartsWith('--') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('n', 'p', 'A'))
            if ($expanded.Count -gt 0) {
                foreach ($option in $expanded) {
                    if ($option -ceq 'n') { $number = $true }
                    elseif ($option -ceq 'A') { $showAll = $true }
                }
                continue
            }
        }
        $optionName = $null
        $optionValue = $null
        if ($parseOptions -and $argument -match '\A(--style|--color|--paging)=(.*)\z') {
            $optionName = $matches[1]
            $optionValue = $matches[2]
        }
        elseif ($parseOptions -and $argument -cin @('-l', '--language', '--style', '--color', '--paging')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'bat' -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $optionName = $argument
            $index++
            $optionValue = $arguments[$index]
        }
        if ($null -ne $optionName) {
            if ([string]::IsNullOrWhiteSpace($optionValue)) {
                Write-PshCommandFailure -Command 'bat' -Code 2 -Message ('option {0} requires a non-empty value.' -f $optionName)
                return
            }
            if ($optionName -ceq '--style') {
                if ($optionValue -notin @('plain', 'numbers')) {
                    Write-PshCommandFailure -Command 'bat' -Code 2 -Message ('Core bat supports --style plain or numbers, not "{0}".' -f $optionValue)
                    return
                }
                if ($optionValue -ceq 'numbers') { $number = $true }
            }
            elseif ($optionName -ceq '--color' -and $optionValue -notin @('never', 'auto')) {
                Write-PshCommandFailure -Command 'bat' -Code 2 -Message ('Core bat supports --color never or auto, not "{0}".' -f $optionValue)
                return
            }
            elseif ($optionName -ceq '--paging' -and $optionValue -cne 'never') {
                Write-PshCommandFailure -Command 'bat' -Code 2 -Message ('Core bat supports only --paging never, not "{0}".' -f $optionValue)
                return
            }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'bat' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
            return
        }
        $paths += $argument
    }

    try {
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems)
        $text = Format-PshCatSources -Sources $sources -NumberAll:$number -ShowAll:$showAll
        Write-PshTextValue -Text $text
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'bat' -Code 3 -Message $_.Exception.Message
    }
}

function ConvertTo-PshCountSpecification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('head', 'tail')]
        [string]$Command
    )

    if ($Value -notmatch '\A([+-]?)([0-9]+)\z') {
        throw ('count must be an integer: {0}' -f $Value)
    }
    $count = [long]0
    if (-not [long]::TryParse($matches[2], [ref]$count)) {
        throw ('count is too large: {0}' -f $Value)
    }
    $mode = 'Count'
    if ($matches[1] -ceq '+') { $mode = 'FromStart' }
    elseif ($matches[1] -ceq '-' -and $Command -ceq 'head') { $mode = 'ExcludeEnd' }
    return [PSCustomObject]@{ Mode = $mode; Count = $count }
}

function Select-PshHeadTailText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [ValidateSet('head', 'tail')]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [object]$CountSpecification,

        [switch]$Bytes
    )

    $count = [long]$CountSpecification.Count
    $mode = [string]$CountSpecification.Mode
    if ($Bytes) { throw 'Select-PshHeadTailText does not accept byte mode.' }

    $lines = @(Split-PshTextLines -Text ([string]$Source.Text))
    $selectedLines = @()
    if ($Command -ceq 'head') {
        if ($mode -ceq 'FromStart') {
            $start = [Math]::Max(0, [int]$count - 1)
            if ($start -lt $lines.Count) { $selectedLines = @($lines[$start..($lines.Count - 1)]) }
        }
        elseif ($mode -ceq 'ExcludeEnd') {
            $take = [Math]::Max(0, $lines.Count - [int]$count)
            if ($take -gt 0) { $selectedLines = @($lines[0..($take - 1)]) }
        }
        else {
            $take = [Math]::Min($lines.Count, [int]$count)
            if ($take -gt 0) { $selectedLines = @($lines[0..($take - 1)]) }
        }
    }
    else {
        if ($mode -ceq 'FromStart') {
            $start = [Math]::Max(0, [int]$count - 1)
            if ($start -lt $lines.Count) { $selectedLines = @($lines[$start..($lines.Count - 1)]) }
        }
        else {
            $take = [Math]::Min($lines.Count, [int]$count)
            if ($take -gt 0) { $selectedLines = @($lines[($lines.Count - $take)..($lines.Count - 1)]) }
        }
    }
    $builder = New-Object Text.StringBuilder
    foreach ($line in $selectedLines) {
        [void]$builder.Append([string]$line.Text)
        [void]$builder.Append([string]$line.Terminator)
    }
    return $builder.ToString()
}

function Select-PshHeadTailBytes {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [ValidateSet('head', 'tail')]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [object]$CountSpecification
    )

    $values = [byte[]]$Source.Bytes
    $count = [long]$CountSpecification.Count
    $mode = [string]$CountSpecification.Mode
    $start = 0L
    $length = 0L
    if ($Command -ceq 'head') {
        if ($mode -ceq 'FromStart') {
            $start = [Math]::Max(0L, $count - 1L)
            if ($start -gt $values.LongLength) { $start = $values.LongLength }
            $length = $values.LongLength - $start
        }
        elseif ($mode -ceq 'ExcludeEnd') {
            $length = [Math]::Max(0L, $values.LongLength - $count)
        }
        else { $length = [Math]::Min($values.LongLength, $count) }
    }
    else {
        if ($mode -ceq 'FromStart') {
            $start = [Math]::Max(0L, $count - 1L)
            if ($start -gt $values.LongLength) { $start = $values.LongLength }
            $length = $values.LongLength - $start
        }
        else {
            $length = [Math]::Min($values.LongLength, $count)
            $start = $values.LongLength - $length
        }
    }
    $selected = New-Object byte[] ([int]$length)
    if ($length -gt 0) { [Array]::Copy($values, [int]$start, $selected, 0, [int]$length) }
    return ,$selected
}

function New-PshUtf8FollowDecoder {
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    return $encoding.GetDecoder()
}

function ConvertFrom-PshFollowBytes {
    param(
        [Parameter(Mandatory = $true)]
        [Text.Decoder]$Decoder,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -eq 0) { return '' }
    $characters = New-Object char[] ($Bytes.Length + 1)
    $count = $Decoder.GetChars($Bytes, 0, $Bytes.Length, $characters, 0, $false)
    if ($count -eq 0) { return '' }
    return (-join $characters[0..($count - 1)])
}

function Invoke-PshHeadTailCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('head', 'tail')]
        [string]$Command,

        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [AllowNull()]
        [object[]]$PipelineItems,

        [bool]$HasDownstream = $false
    )

    if (Test-PshLongHelp -Arguments $Arguments) {
        $followText = if ($Command -ceq 'tail') { ' [-f]' } else { '' }
        Write-PshCommandHelp -Usage ('Usage: {0} [-n count|-c count] [-qv]{1} [file ...]' -f $Command, $followText)
        return
    }

    $bytes = $false
    $countSpecification = ConvertTo-PshCountSpecification -Value '10' -Command $Command
    $quiet = $false
    $verbose = $false
    $follow = $false
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -cin @('-q', '--quiet', '--silent')) { $quiet = $true; continue }
        if ($parseOptions -and $argument -cin @('-v', '--verbose')) { $verbose = $true; continue }
        if ($parseOptions -and $Command -ceq 'tail' -and $argument -cin @('-f', '--follow')) { $follow = $true; continue }
        if ($parseOptions -and $argument -match '\A--(lines|bytes)=(.+)\z') {
            $bytes = $matches[1] -ceq 'bytes'
            try { $countSpecification = ConvertTo-PshCountSpecification -Value $matches[2] -Command $Command }
            catch { Write-PshCommandFailure -Command $Command -Code 2 -Message $_.Exception.Message; return }
            continue
        }
        if ($parseOptions -and $argument -match '\A-([nc])(.+)\z') {
            $bytes = $matches[1] -ceq 'c'
            try { $countSpecification = ConvertTo-PshCountSpecification -Value $matches[2] -Command $Command }
            catch { Write-PshCommandFailure -Command $Command -Code 2 -Message $_.Exception.Message; return }
            continue
        }
        if ($parseOptions -and $argument -cin @('-n', '--lines', '-c', '--bytes')) {
            if (($index + 1) -ge $Arguments.Count) {
                Write-PshCommandFailure -Command $Command -Code 2 -Message ('option {0} requires a count.' -f $argument)
                return
            }
            $bytes = $argument -cin @('-c', '--bytes')
            $index++
            try { $countSpecification = ConvertTo-PshCountSpecification -Value $Arguments[$index] -Command $Command }
            catch { Write-PshCommandFailure -Command $Command -Code 2 -Message $_.Exception.Message; return }
            continue
        }
        if ($parseOptions -and $argument -match '\A-([0-9]+)\z') {
            $bytes = $false
            $countSpecification = ConvertTo-PshCountSpecification -Value $matches[1] -Command $Command
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command $Command -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
            return
        }
        $paths += $argument
    }
    if ($follow -and ($paths.Count -ne 1 -or $paths[0] -ceq '-')) {
        Write-PshCommandFailure -Command $Command -Code 2 -Message 'follow mode requires exactly one file path.'
        return
    }

    try {
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $PipelineItems)
        $followDecoder = $null
        if ($follow) {
            if ($bytes) {
                if ($HasDownstream) {
                    Write-PshCommandFailure -Command $Command -Code 2 -Message 'byte follow output requires raw stdout and cannot enter the PowerShell object pipeline.'
                    return
                }
            }
            elseif ($sources[0].IsBinary -or [string]$sources[0].Encoding -notin @('utf-8', 'utf-8-bom')) {
                Write-PshCommandFailure -Command $Command -Code 2 -Message 'follow mode supports only UTF-8 text files; use byte mode for other encodings.'
                return
            }
            else {
                $followDecoder = New-PshUtf8FollowDecoder
            }
        }
        $showHeaders = $verbose -or (-not $quiet -and $sources.Count -gt 1)
        $first = $true
        foreach ($source in $sources) {
            if ($showHeaders) {
                if (-not $first) { Write-PshTextValue -Text '' -EmitEmpty }
                Write-PshTextValue -Text ('==> {0} <==' -f [string]$source.DisplayName)
            }
            if ($bytes) {
                $selectedBytes = [byte[]](Select-PshHeadTailBytes -Source $source -Command $Command -CountSpecification $countSpecification)
                if ($HasDownstream) {
                    if (Test-PshBytesRequireRawOutput -Bytes $selectedBytes) {
                        Write-PshCommandFailure -Command $Command -Code 2 -Message 'byte output splits or contains binary data and cannot enter the PowerShell object pipeline.'
                        return
                    }
                    $text = ConvertFrom-PshStrictUtf8Bytes -Bytes $selectedBytes
                    Write-PshTextValue -Text $text
                }
                else { Write-PshRawBytes -Bytes $selectedBytes }
            }
            else {
                $text = Select-PshHeadTailText -Source $source -Command $Command -CountSpecification $countSpecification
                Write-PshTextValue -Text $text
            }
            $first = $false
        }
        Set-PshLastExitCode -Code 0

        if ($follow) {
            $path = [string]$sources[0].Path
            $position = [long]([IO.FileInfo]$path).Length
            $followAtFileStart = $false
            while ($true) {
                Start-Sleep -Milliseconds 500
                $length = [long]([IO.FileInfo]$path).Length
                if ($length -lt $position) {
                    $position = 0
                    $followAtFileStart = $true
                    if ($null -ne $followDecoder) { $followDecoder.Reset() }
                }
                if ($length -le $position) { continue }
                $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    [void]$stream.Seek($position, [IO.SeekOrigin]::Begin)
                    $delta = New-Object byte[] ([int]($length - $position))
                    $read = $stream.Read($delta, 0, $delta.Length)
                    if ($read -gt 0) {
                        if ($read -ne $delta.Length) {
                            $actual = New-Object byte[] $read
                            [Array]::Copy($delta, $actual, $read)
                            $delta = $actual
                        }
                        if ($bytes) {
                            Write-PshRawBytes -Bytes $delta
                        }
                        else {
                            try { $decodedText = ConvertFrom-PshFollowBytes -Decoder $followDecoder -Bytes $delta }
                            catch {
                                Write-PshCommandFailure -Command $Command -Code 2 -Message ('follow data is not valid UTF-8: {0}' -f $_.Exception.Message)
                                return
                            }
                            if ($followAtFileStart -and $decodedText.Length -gt 0) {
                                if ($decodedText[0] -eq [char]0xFEFF) { $decodedText = $decodedText.Substring(1) }
                                $followAtFileStart = $false
                            }
                            Write-PshTextValue -Text $decodedText
                        }
                    }
                    $position += $read
                }
                finally { $stream.Dispose() }
            }
        }
    }
    catch {
        Write-PshCommandFailure -Command $Command -Code 3 -Message $_.Exception.Message
    }
}

function head {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    Invoke-PshHeadTailCommand -Command 'head' -Arguments $arguments -PipelineItems $pipelineItems -HasDownstream:(Test-PshInvocationHasDownstream -Invocation $MyInvocation)
}

function tail {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    Invoke-PshHeadTailCommand -Command 'tail' -Arguments $arguments -PipelineItems $pipelineItems -HasDownstream:(Test-PshInvocationHasDownstream -Invocation $MyInvocation)
}

function Get-PshHead {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject,

        [string[]]$Path = @(),

        [ValidateRange(0, [int]::MaxValue)]
        [int]$Count = 10,

        [switch]$Bytes
    )
    begin { $items = @() }
    process { $items += $InputObject }
    end {
        $specification = [PSCustomObject]@{ Mode = 'Count'; Count = [long]$Count }
        foreach ($source in @(Get-PshTextSources -Paths $Path -PipelineItems $items)) {
            if ($Bytes) {
                ,([byte[]](Select-PshHeadTailBytes -Source $source -Command 'head' -CountSpecification $specification))
            }
            else {
                $value = Select-PshHeadTailText -Source $source -Command 'head' -CountSpecification $specification
                Write-PshTextValue -Text $value
            }
        }
    }
}

function Get-PshTail {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject,

        [string[]]$Path = @(),

        [ValidateRange(0, [int]::MaxValue)]
        [int]$Count = 10,

        [switch]$Bytes
    )
    begin { $items = @() }
    process { $items += $InputObject }
    end {
        $specification = [PSCustomObject]@{ Mode = 'Count'; Count = [long]$Count }
        foreach ($source in @(Get-PshTextSources -Paths $Path -PipelineItems $items)) {
            if ($Bytes) {
                ,([byte[]](Select-PshHeadTailBytes -Source $source -Command 'tail' -CountSpecification $specification))
            }
            else {
                $value = Select-PshHeadTailText -Source $source -Command 'tail' -CountSpecification $specification
                Write-PshTextValue -Text $value
            }
        }
    }
}

function Test-PshSearchHiddenEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item,

        [AllowNull()]
        [string]$RelativePath
    )

    foreach ($component in @(([string]$RelativePath).Replace('\', '/') -split '/')) {
        if ($component.StartsWith('.') -and $component -notin @('.', '..')) { return $true }
    }
    try {
        return (($Item.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
    }
    catch { return $false }
}

function Test-PshWildcardValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    try {
        $wildcard = New-Object System.Management.Automation.WildcardPattern(
            $Pattern,
            [System.Management.Automation.WildcardOptions]::CultureInvariant
        )
        return $wildcard.IsMatch($Value)
    }
    catch {
        throw ('invalid wildcard pattern "{0}": {1}' -f $Pattern, $_.Exception.Message)
    }
}

function Test-PshSearchFileFilter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyCollection()]
        [string[]]$Includes = @(),

        [AllowEmptyCollection()]
        [string[]]$Excludes = @(),

        [AllowEmptyCollection()]
        [string[]]$Globs = @()
    )

    $normalized = $RelativePath.Replace('\', '/')
    if ($Includes.Count -gt 0) {
        $included = $false
        foreach ($pattern in $Includes) {
            if ((Test-PshWildcardValue -Value $Name -Pattern $pattern) -or
                (Test-PshWildcardValue -Value $normalized -Pattern $pattern)) {
                $included = $true
                break
            }
        }
        if (-not $included) { return $false }
    }
    foreach ($pattern in $Excludes) {
        if ((Test-PshWildcardValue -Value $Name -Pattern $pattern) -or
            (Test-PshWildcardValue -Value $normalized -Pattern $pattern)) {
            return $false
        }
    }

    $positiveGlobs = @($Globs | Where-Object { -not ([string]$_).StartsWith('!') })
    if ($positiveGlobs.Count -gt 0) {
        $matchedPositive = $false
        foreach ($pattern in $positiveGlobs) {
            if ((Test-PshWildcardValue -Value $Name -Pattern $pattern) -or
                (Test-PshWildcardValue -Value $normalized -Pattern $pattern)) {
                $matchedPositive = $true
                break
            }
        }
        if (-not $matchedPositive) { return $false }
    }
    foreach ($rawPattern in @($Globs | Where-Object { ([string]$_).StartsWith('!') })) {
        $pattern = ([string]$rawPattern).Substring(1)
        if ([string]::IsNullOrEmpty($pattern)) { throw 'glob exclusion cannot be empty.' }
        if ((Test-PshWildcardValue -Value $Name -Pattern $pattern) -or
            (Test-PshWildcardValue -Value $normalized -Pattern $pattern)) {
            return $false
        }
    }
    return $true
}

function Get-PshSearchFileSources {
    param(
        [AllowEmptyCollection()]
        [string[]]$Paths = @(),

        [switch]$Recursive,

        [switch]$Hidden,

        [AllowEmptyCollection()]
        [string[]]$Includes = @(),

        [AllowEmptyCollection()]
        [string[]]$Excludes = @(),

        [AllowEmptyCollection()]
        [string[]]$Globs = @()
    )

    $sources = @()
    foreach ($operand in @($Paths)) {
        if ($operand -ceq '-') { continue }
        $resolved = Resolve-PshFileSystemPath -Path $operand
        if ([IO.File]::Exists($resolved)) {
            $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if (Test-PshSearchFileFilter -RelativePath ([string]$item.Name) -Name ([string]$item.Name) -Includes $Includes -Excludes $Excludes -Globs $Globs) {
                $source = Read-PshTextFileSource -Operand $operand
                $source.DisplayName = $operand
                $sources += $source
            }
            continue
        }
        if (-not [IO.Directory]::Exists($resolved)) {
            throw ('path does not exist: {0}' -f $operand)
        }
        if (-not $Recursive) {
            throw ('directory requires recursive search: {0}' -f $operand)
        }

        $pending = New-Object 'System.Collections.Generic.Stack[object]'
        $pending.Push([PSCustomObject]@{ Path = $resolved; Relative = '' })
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            $entries = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath ([string]$current.Path) -Force -ErrorAction Stop)
            $entries = @($entries | Microsoft.PowerShell.Utility\Sort-Object -Property Name)
            for ($entryIndex = $entries.Count - 1; $entryIndex -ge 0; $entryIndex--) {
                $entry = $entries[$entryIndex]
                $relative = [string]$entry.Name
                if (-not [string]::IsNullOrEmpty([string]$current.Relative)) {
                    $relative = ([string]$current.Relative).TrimEnd('/', '\') + '/' + [string]$entry.Name
                }
                if (-not $Hidden -and (Test-PshSearchHiddenEntry -Item $entry -RelativePath $relative)) { continue }
                $type = Get-PshItemTypeName -Item $entry
                if ($type -eq 'directory') {
                    $pending.Push([PSCustomObject]@{ Path = [string]$entry.FullName; Relative = $relative })
                    continue
                }
                if ($type -ne 'file') { continue }
                if (-not (Test-PshSearchFileFilter -RelativePath $relative -Name ([string]$entry.Name) -Includes $Includes -Excludes $Excludes -Globs $Globs)) { continue }
                $display = $relative
                if (-not [string]::Equals($operand, '.', [StringComparison]::Ordinal)) {
                    $display = $operand.TrimEnd('/', '\') + [IO.Path]::DirectorySeparatorChar + $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
                }
                $source = Read-PshTextFileSource -Operand ([string]$entry.FullName)
                $source.DisplayName = $display
                $sources += $source
            }
        }
    }
    for ($index = 1; $index -lt $sources.Count; $index++) {
        $current = $sources[$index]
        $position = $index - 1
        while ($position -ge 0 -and [StringComparer]::Ordinal.Compare([string]$sources[$position].DisplayName, [string]$current.DisplayName) -gt 0) {
            $sources[$position + 1] = $sources[$position]
            $position--
        }
        $sources[$position + 1] = $current
    }
    return $sources
}

function ConvertFrom-PshBasicRegexPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $builder = New-Object Text.StringBuilder
    $inCharacterClass = $false
    for ($index = 0; $index -lt $Pattern.Length; $index++) {
        $character = $Pattern[$index]
        if ($character -eq '\' -and ($index + 1) -lt $Pattern.Length) {
            $index++
            $escaped = $Pattern[$index]
            if (-not $inCharacterClass -and $escaped -in @('(', ')', '|', '+', '?', '{', '}')) {
                [void]$builder.Append($escaped)
            }
            else {
                [void]$builder.Append('\')
                [void]$builder.Append($escaped)
            }
            continue
        }
        if ($character -eq '[' -and -not $inCharacterClass) {
            $inCharacterClass = $true
            [void]$builder.Append($character)
            continue
        }
        if ($character -eq ']' -and $inCharacterClass) {
            $inCharacterClass = $false
            [void]$builder.Append($character)
            continue
        }
        if (-not $inCharacterClass -and $character -in @('(', ')', '|', '+', '?', '{', '}')) {
            [void]$builder.Append('\')
        }
        [void]$builder.Append($character)
    }
    return $builder.ToString()
}

function New-PshSearchRegex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [switch]$Literal,

        [switch]$Basic,

        [switch]$IgnoreCase
    )

    $expression = $Pattern
    if ($Literal) { $expression = [Text.RegularExpressions.Regex]::Escape($Pattern) }
    elseif ($Basic) { $expression = ConvertFrom-PshBasicRegexPattern -Pattern $Pattern }
    $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($IgnoreCase) { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
    try {
        return New-Object Text.RegularExpressions.Regex($expression, $options)
    }
    catch {
        throw ('invalid regular expression "{0}": {1}' -f $Pattern, $_.Exception.Message)
    }
}

function Find-PshTextSourceMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [Text.RegularExpressions.Regex]$Regex,

        [switch]$Invert,

        [int]$MaxCount = [int]::MaxValue
    )

    $lines = @(Split-PshTextLines -Text ([string]$Source.Text))
    $matches = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $matched = $Regex.IsMatch([string]$lines[$index].Text)
        if ($Invert) { $matched = -not $matched }
        if (-not $matched) { continue }
        if ($matches.Count -ge $MaxCount) { break }
        $matches += [PSCustomObject]@{
            Path = if ($Source.IsStandardInput) { $null } else { [string]$Source.Path }
            DisplayName = [string]$Source.DisplayName
            LineNumber = $index + 1
            Line = [string]$lines[$index].Text
            Index = $index
        }
    }
    return [PSCustomObject]@{
        Source = $Source
        Lines = $lines
        Matches = $matches
    }
}

function Invoke-PshSearchCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('grep', 'rg')]
        [string]$Command,

        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [AllowNull()]
        [object[]]$PipelineItems,

        [bool]$PipelineExpected = $false
    )

    if ($Command -ceq 'rg' -and (Resolve-PshEdition) -eq 'Full') {
        Invoke-PshPinnedTextTool -Name 'rg' -Arguments $Arguments -PipelineItems $PipelineItems -PipelineExpected:$PipelineExpected
        return
    }
    if (Test-PshLongHelp -Arguments $Arguments) {
        Write-PshCommandHelp -Usage ('Usage: {0} [-ivnrlcqEF] [-m count] [-A count] [-B count] [-C count] [--include glob] [--exclude glob] [--hidden] [--glob glob] pattern [path ...]' -f $Command)
        return
    }

    $ignoreCase = $false
    $invert = $false
    $lineNumber = $false
    $recursive = $Command -ceq 'rg'
    $filesWithMatches = $false
    $countOnly = $false
    $quiet = $false
    $extended = $false
    $literal = $false
    $hidden = $false
    $maxCount = [int]::MaxValue
    $after = 0
    $before = 0
    $includes = @()
    $excludes = @()
    $globs = @()
    $positionals = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -ceq '--hidden') { $hidden = $true; continue }

        $valueOption = $null
        $value = $null
        if ($parseOptions -and $argument -match '\A(--include|--exclude|--glob)=(.*)\z') {
            $valueOption = $matches[1]
            $value = $matches[2]
        }
        elseif ($parseOptions -and $argument -match '\A-([mABC])([0-9]+)\z') {
            $valueOption = '-' + $matches[1]
            $value = $matches[2]
        }
        elseif ($parseOptions -and $argument -cin @('-m', '-A', '-B', '-C', '--include', '--exclude', '--glob')) {
            if (($index + 1) -ge $Arguments.Count) {
                Write-PshCommandFailure -Command $Command -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $valueOption = $argument
            $index++
            $value = $Arguments[$index]
        }
        if ($null -ne $valueOption) {
            if ($valueOption -cin @('-m', '-A', '-B', '-C')) {
                $number = 0
                if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 0) {
                    Write-PshCommandFailure -Command $Command -Code 2 -Message ('option {0} requires a non-negative integer.' -f $valueOption)
                    return
                }
                if ($valueOption -ceq '-m') { $maxCount = $number }
                elseif ($valueOption -ceq '-A') { $after = $number }
                elseif ($valueOption -ceq '-B') { $before = $number }
                else { $after = $number; $before = $number }
            }
            elseif ([string]::IsNullOrEmpty($value)) {
                Write-PshCommandFailure -Command $Command -Code 2 -Message ('option {0} requires a non-empty pattern.' -f $valueOption)
                return
            }
            elseif ($valueOption -ceq '--include') { $includes += $value }
            elseif ($valueOption -ceq '--exclude') { $excludes += $value }
            else { $globs += $value }
            continue
        }

        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('i', 'v', 'n', 'r', 'l', 'c', 'q', 'E', 'F'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command $Command -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -ceq 'i') { $ignoreCase = $true }
                elseif ($option -ceq 'v') { $invert = $true }
                elseif ($option -ceq 'n') { $lineNumber = $true }
                elseif ($option -ceq 'r') { $recursive = $true }
                elseif ($option -ceq 'l') { $filesWithMatches = $true }
                elseif ($option -ceq 'c') { $countOnly = $true }
                elseif ($option -ceq 'q') { $quiet = $true }
                elseif ($option -ceq 'E') { $extended = $true }
                elseif ($option -ceq 'F') { $literal = $true }
            }
            continue
        }
        $positionals += $argument
    }
    if ($positionals.Count -eq 0) {
        Write-PshCommandFailure -Command $Command -Code 2 -Message 'a search pattern is required.'
        return
    }
    if ($extended -and $literal) {
        Write-PshCommandFailure -Command $Command -Code 2 -Message '-E and -F are mutually exclusive.'
        return
    }
    if ($filesWithMatches -and $countOnly) {
        Write-PshCommandFailure -Command $Command -Code 2 -Message '-l and -c are mutually exclusive in the documented subset.'
        return
    }

    $pattern = [string]$positionals[0]
    $paths = @()
    if ($positionals.Count -gt 1) { $paths = @($positionals[1..($positionals.Count - 1)]) }
    if ($paths.Count -eq 0 -and $recursive -and -not $PipelineExpected) { $paths = @('.') }

    try {
        $regex = New-PshSearchRegex -Pattern $pattern -Literal:$literal -Basic:($Command -ceq 'grep' -and -not $extended) -IgnoreCase:$ignoreCase
        $sources = @()
        $searchingDirectory = $false
        if ($paths.Count -eq 0) {
            $sources = @(New-PshPipelineTextSource -Items $PipelineItems)
        }
        else {
            $standardInputConsumed = $false
            foreach ($path in $paths) {
                if ($path -ceq '-') {
                    if ($standardInputConsumed) { $sources += New-PshPipelineTextSource -Items @() }
                    else {
                        $sources += New-PshPipelineTextSource -Items $PipelineItems
                        $standardInputConsumed = $true
                    }
                    continue
                }
                $resolved = Resolve-PshFileSystemPath -Path $path
                if ([IO.Directory]::Exists($resolved)) { $searchingDirectory = $true }
                $sources += @(Get-PshSearchFileSources -Paths @($path) -Recursive:$recursive -Hidden:$hidden -Includes $includes -Excludes $excludes -Globs $globs)
            }
        }

        $showFileName = $searchingDirectory -or $sources.Count -gt 1
        $anyMatch = $false
        foreach ($source in $sources) {
            $result = Find-PshTextSourceMatches -Source $source -Regex $regex -Invert:$invert -MaxCount $maxCount
            $matchesForSource = @($result.Matches)
            if ($matchesForSource.Count -eq 0) {
                if ($countOnly -and -not $quiet) {
                    if ($showFileName) { Write-PshTextValue -Text ('{0}:0' -f [string]$source.DisplayName) }
                    else { Write-PshTextValue -Text '0' }
                }
                continue
            }
            $anyMatch = $true
            if ($quiet) { Set-PshLastExitCode -Code 0; return }
            if ($filesWithMatches) {
                Write-PshTextValue -Text ([string]$source.DisplayName)
                continue
            }
            if ($countOnly) {
                if ($showFileName) { Write-PshTextValue -Text ('{0}:{1}' -f [string]$source.DisplayName, $matchesForSource.Count) }
                else { Write-PshTextValue -Text ([string]$matchesForSource.Count) }
                continue
            }
            if ($source.IsBinary) {
                Write-PshTextValue -Text ('Binary file {0} matches' -f [string]$source.DisplayName)
                continue
            }

            $matchingIndices = @{}
            $selectedIndices = @{}
            foreach ($match in $matchesForSource) {
                $matchingIndices[[int]$match.Index] = $true
                $firstIndex = [Math]::Max(0, [int]$match.Index - $before)
                $lastIndex = [Math]::Min(@($result.Lines).Count - 1, [int]$match.Index + $after)
                for ($lineIndex = $firstIndex; $lineIndex -le $lastIndex; $lineIndex++) {
                    $selectedIndices[$lineIndex] = $true
                }
            }
            $orderedIndices = @($selectedIndices.Keys | Microsoft.PowerShell.Utility\Sort-Object)
            $previousIndex = -2
            foreach ($lineIndex in $orderedIndices) {
                $lineIndex = [int]$lineIndex
                if (($before -gt 0 -or $after -gt 0) -and $previousIndex -ge 0 -and $lineIndex -gt ($previousIndex + 1)) {
                    Write-PshTextValue -Text '--'
                }
                $isMatch = $matchingIndices.ContainsKey($lineIndex)
                $separator = if ($isMatch) { ':' } else { '-' }
                $prefix = ''
                if ($showFileName) { $prefix += [string]$source.DisplayName + $separator }
                if ($lineNumber) { $prefix += [string]($lineIndex + 1) + $separator }
                Write-PshTextValue -Text ($prefix + [string]@($result.Lines)[$lineIndex].Text) -EmitEmpty
                $previousIndex = $lineIndex
            }
        }
        if ($anyMatch) { Set-PshLastExitCode -Code 0 }
        else { Set-PshLastExitCode -Code 1 }
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match '\Ainvalid (regular expression|wildcard pattern)') {
            Write-PshCommandFailure -Command $Command -Code 2 -Message $message
        }
        else {
            Write-PshCommandFailure -Command $Command -Code 3 -Message $message
        }
    }
}

function grep {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    Invoke-PshSearchCommand -Command 'grep' -Arguments $arguments -PipelineItems $pipelineItems -PipelineExpected:([bool]$MyInvocation.ExpectingInput)
}

function rg {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    Invoke-PshSearchCommand -Command 'rg' -Arguments $arguments -PipelineItems $pipelineItems -PipelineExpected:([bool]$MyInvocation.ExpectingInput)
}

function Find-PshText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Pattern,

        [Parameter(Position = 1)]
        [string[]]$Path = @(),

        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject,

        [switch]$Literal,

        [switch]$IgnoreCase,

        [switch]$Invert,

        [switch]$Recurse,

        [switch]$Hidden,

        [string[]]$Include = @(),

        [string[]]$Exclude = @(),

        [string[]]$Glob = @(),

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxCount = [int]::MaxValue
    )
    begin { $items = @() }
    process { $items += $InputObject }
    end {
        $regex = New-PshSearchRegex -Pattern $Pattern -Literal:$Literal -IgnoreCase:$IgnoreCase
        $sources = @()
        if (@($Path).Count -eq 0) {
            $sources = @(New-PshPipelineTextSource -Items $items)
        }
        else {
            $sources = @(Get-PshSearchFileSources -Paths $Path -Recursive:$Recurse -Hidden:$Hidden -Includes $Include -Excludes $Exclude -Globs $Glob)
        }
        foreach ($source in $sources) {
            $result = Find-PshTextSourceMatches -Source $source -Regex $regex -Invert:$Invert -MaxCount $MaxCount
            foreach ($match in @($result.Matches)) {
                [PSCustomObject]@{
                    Path = $match.Path
                    DisplayName = $match.DisplayName
                    LineNumber = [int]$match.LineNumber
                    Line = [string]$match.Line
                }
            }
        }
    }
}

function ConvertTo-PshSelectionRanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$List
    )

    if ([string]::IsNullOrWhiteSpace($List)) { throw 'selection list cannot be empty.' }
    $ranges = @()
    foreach ($part in $List.Split(',')) {
        if ($part -match '\A([1-9][0-9]*)\z') {
            $value = [int]0
            if (-not [int]::TryParse($matches[1], [ref]$value)) { throw ('selection value is too large: {0}' -f $part) }
            $ranges += [PSCustomObject]@{ Start = $value; End = $value }
        }
        elseif ($part -match '\A([1-9][0-9]*)-([1-9][0-9]*)\z') {
            $start = [int]0
            $end = [int]0
            if (-not [int]::TryParse($matches[1], [ref]$start) -or -not [int]::TryParse($matches[2], [ref]$end) -or $end -lt $start) {
                throw ('invalid selection range: {0}' -f $part)
            }
            $ranges += [PSCustomObject]@{ Start = $start; End = $end }
        }
        elseif ($part -match '\A-([1-9][0-9]*)\z') {
            $end = [int]0
            if (-not [int]::TryParse($matches[1], [ref]$end)) { throw ('selection value is too large: {0}' -f $part) }
            $ranges += [PSCustomObject]@{ Start = 1; End = $end }
        }
        elseif ($part -match '\A([1-9][0-9]*)-\z') {
            $start = [int]0
            if (-not [int]::TryParse($matches[1], [ref]$start)) { throw ('selection value is too large: {0}' -f $part) }
            $ranges += [PSCustomObject]@{ Start = $start; End = [int]::MaxValue }
        }
        else { throw ('invalid selection list element: {0}' -f $part) }
    }
    return $ranges
}

function Test-PshSelectedPosition {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Position,

        [Parameter(Mandatory = $true)]
        [object[]]$Ranges,

        [switch]$Complement
    )

    $selected = $false
    foreach ($range in $Ranges) {
        if ($Position -ge [int]$range.Start -and $Position -le [int]$range.End) {
            $selected = $true
            break
        }
    }
    if ($Complement) { return -not $selected }
    return $selected
}

function Split-PshByteLines {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $lines = @()
    $start = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -ne 10) { continue }
        $content = New-Object byte[] ($index - $start)
        if ($content.Length -gt 0) { [Array]::Copy($Bytes, $start, $content, 0, $content.Length) }
        $lines += [PSCustomObject]@{ Content = $content; HasNewline = $true }
        $start = $index + 1
    }
    if ($start -lt $Bytes.Length) {
        $content = New-Object byte[] ($Bytes.Length - $start)
        [Array]::Copy($Bytes, $start, $content, 0, $content.Length)
        $lines += [PSCustomObject]@{ Content = $content; HasNewline = $false }
    }
    return $lines
}

function ConvertTo-PshCodePointStrings {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) { return @() }
    $values = @()
    for ($index = 0; $index -lt $Text.Length; $index++) {
        if ([char]::IsHighSurrogate($Text[$index]) -and ($index + 1) -lt $Text.Length -and [char]::IsLowSurrogate($Text[$index + 1])) {
            $values += $Text.Substring($index, 2)
            $index++
        }
        else { $values += [string]$Text[$index] }
    }
    return $values
}

function cut {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: cut (-b list|-c list|-f list) [-d delimiter] [-s] [--complement] [file ...]'
        return
    }

    $mode = $null
    $list = $null
    $delimiter = "`t"
    $delimiterSpecified = $false
    $suppress = $false
    $complement = $false
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -ceq '--complement') { $complement = $true; continue }
        if ($parseOptions -and $argument -ceq '-s') { $suppress = $true; continue }
        $option = $null
        $value = $null
        if ($parseOptions -and $argument -match '\A-([bcfd])(.+)\z') {
            $option = '-' + $matches[1]
            $value = $matches[2]
        }
        elseif ($parseOptions -and $argument -cin @('-b', '-c', '-f', '-d')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'cut' -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $option = $argument
            $index++
            $value = $arguments[$index]
        }
        if ($null -ne $option) {
            if ($option -ceq '-d') {
                if (([string]$value).Length -ne 1) {
                    Write-PshCommandFailure -Command 'cut' -Code 2 -Message 'delimiter must be exactly one character.'
                    return
                }
                $delimiter = $value
                $delimiterSpecified = $true
            }
            else {
                $candidateMode = $option.Substring(1)
                if ($null -ne $mode -and $mode -cne $candidateMode) {
                    Write-PshCommandFailure -Command 'cut' -Code 2 -Message 'exactly one of -b, -c, or -f is required.'
                    return
                }
                $mode = $candidateMode
                $list = $value
            }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'cut' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
            return
        }
        $paths += $argument
    }
    if ($null -eq $mode) {
        Write-PshCommandFailure -Command 'cut' -Code 2 -Message 'one of -b, -c, or -f is required.'
        return
    }
    if ($mode -cne 'f' -and ($delimiterSpecified -or $suppress)) {
        Write-PshCommandFailure -Command 'cut' -Code 2 -Message '-d and -s are supported only with -f.'
        return
    }

    try {
        $ranges = @(ConvertTo-PshSelectionRanges -List $list)
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems)
        if ($mode -ceq 'b') {
            $selectedOutput = New-Object 'System.Collections.Generic.List[byte]'
            foreach ($source in $sources) {
                foreach ($line in @(Split-PshByteLines -Bytes ([byte[]]$source.Bytes))) {
                    $content = [byte[]]$line.Content
                    for ($byteIndex = 0; $byteIndex -lt $content.Length; $byteIndex++) {
                        if (Test-PshSelectedPosition -Position ($byteIndex + 1) -Ranges $ranges -Complement:$complement) {
                            $selectedOutput.Add($content[$byteIndex])
                        }
                    }
                    if ($line.HasNewline) { $selectedOutput.Add([byte]10) }
                }
            }
            $selectedBytes = $selectedOutput.ToArray()
            if (Test-PshInvocationHasDownstream -Invocation $MyInvocation) {
                if (Test-PshBytesRequireRawOutput -Bytes $selectedBytes) {
                    Write-PshCommandFailure -Command 'cut' -Code 2 -Message 'the selected byte range contains binary data and cannot enter the PowerShell object pipeline.'
                    return
                }
                $selectedText = ConvertFrom-PshStrictUtf8Bytes -Bytes $selectedBytes
                Write-PshTextValue -Text $selectedText
            }
            else { Write-PshRawBytes -Bytes $selectedBytes }
            Set-PshLastExitCode -Code 0
            return
        }
        $builder = New-Object Text.StringBuilder
        foreach ($source in $sources) {
            if ($source.IsBinary) {
                Write-PshCommandFailure -Command 'cut' -Code 2 -Message 'character and field selection do not accept binary input.'
                return
            }
            foreach ($line in @(Split-PshTextLines -Text ([string]$source.Text))) {
                $value = ''
                if ($mode -ceq 'f') {
                    $hasDelimiter = ([string]$line.Text).IndexOf($delimiter, [StringComparison]::Ordinal) -ge 0
                    if ($suppress -and -not $hasDelimiter) { continue }
                    if (-not $hasDelimiter) {
                        $value = [string]$line.Text
                    }
                    else {
                        $fields = ([string]$line.Text).Split([char[]]@([char]$delimiter), [StringSplitOptions]::None)
                        $selectedFields = @()
                        for ($fieldIndex = 0; $fieldIndex -lt $fields.Count; $fieldIndex++) {
                            if (Test-PshSelectedPosition -Position ($fieldIndex + 1) -Ranges $ranges -Complement:$complement) {
                                $selectedFields += [string]$fields[$fieldIndex]
                            }
                        }
                        $value = $selectedFields -join $delimiter
                    }
                }
                elseif ($mode -ceq 'c') {
                    $characters = @(ConvertTo-PshCodePointStrings -Text ([string]$line.Text))
                    $selectedCharacters = New-Object Text.StringBuilder
                    for ($characterIndex = 0; $characterIndex -lt $characters.Count; $characterIndex++) {
                        if (Test-PshSelectedPosition -Position ($characterIndex + 1) -Ranges $ranges -Complement:$complement) {
                            [void]$selectedCharacters.Append($characters[$characterIndex])
                        }
                    }
                    $value = $selectedCharacters.ToString()
                }
                [void]$builder.Append($value)
                [void]$builder.Append([string]$line.Terminator)
            }
        }
        Write-PshTextValue -Text $builder.ToString()
        Set-PshLastExitCode -Code 0
    }
    catch {
        $code = if ($_.Exception.Message -match '\A(invalid selection|selection list|selection value)') { 2 } else { 3 }
        Write-PshCommandFailure -Command 'cut' -Code $code -Message $_.Exception.Message
    }
}

function ConvertFrom-PshBackslashText {
    param(
        [AllowNull()]
        [string]$Text,

        [switch]$StopOnC
    )

    if ($null -eq $Text) { $Text = '' }
    $builder = New-Object Text.StringBuilder
    $stopped = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($character -ne '\' -or ($index + 1) -ge $Text.Length) {
            [void]$builder.Append($character)
            continue
        }
        $index++
        $escape = $Text[$index]
        if ($StopOnC -and $escape -ceq 'c') { $stopped = $true; break }
        if ($escape -ceq 'a') { [void]$builder.Append([char]7) }
        elseif ($escape -ceq 'b') { [void]$builder.Append([char]8) }
        elseif ($escape -ceq 'f') { [void]$builder.Append([char]12) }
        elseif ($escape -ceq 'n') { [void]$builder.Append("`n") }
        elseif ($escape -ceq 'r') { [void]$builder.Append("`r") }
        elseif ($escape -ceq 't') { [void]$builder.Append("`t") }
        elseif ($escape -ceq 'v') { [void]$builder.Append([char]11) }
        elseif ($escape -ceq '\') { [void]$builder.Append('\') }
        elseif ($escape -ceq 'x') {
            $digits = ''
            while (($index + 1) -lt $Text.Length -and $digits.Length -lt 2 -and $Text[$index + 1] -match '[0-9A-Fa-f]') {
                $index++
                $digits += [string]$Text[$index]
            }
            if ($digits.Length -eq 0) { [void]$builder.Append('x') }
            else { [void]$builder.Append([char][Convert]::ToInt32($digits, 16)) }
        }
        elseif ($escape -match '[0-7]') {
            $digits = [string]$escape
            while (($index + 1) -lt $Text.Length -and $digits.Length -lt 3 -and $Text[$index + 1] -match '[0-7]') {
                $index++
                $digits += [string]$Text[$index]
            }
            [void]$builder.Append([char][Convert]::ToInt32($digits, 8))
        }
        else { [void]$builder.Append($escape) }
    }
    return [PSCustomObject]@{ Text = $builder.ToString(); Stopped = $stopped }
}

function Expand-PshTrSet {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Set
    )

    $classes = [ordered]@{
        '[:lower:]' = 'abcdefghijklmnopqrstuvwxyz'
        '[:upper:]' = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        '[:alpha:]' = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
        '[:alnum:]' = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        '[:digit:]' = '0123456789'
        '[:blank:]' = " `t"
        '[:space:]' = " `t`r`n" + [char]11 + [char]12
    }
    $expandedClasses = $Set
    foreach ($className in $classes.Keys) {
        $expandedClasses = $expandedClasses.Replace($className, [string]$classes[$className])
    }
    $decoded = [string](ConvertFrom-PshBackslashText -Text $expandedClasses).Text
    $result = New-Object 'System.Collections.Generic.List[char]'
    for ($index = 0; $index -lt $decoded.Length; $index++) {
        if (($index + 2) -lt $decoded.Length -and $decoded[$index + 1] -eq '-' -and [int]$decoded[$index] -le [int]$decoded[$index + 2]) {
            for ($code = [int]$decoded[$index]; $code -le [int]$decoded[$index + 2]; $code++) {
                $result.Add([char]$code)
            }
            $index += 2
        }
        else { $result.Add($decoded[$index]) }
    }
    return ,$result.ToArray()
}

function tr {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: tr [-cds] set1 [set2]'
        return
    }

    $complement = $false
    $delete = $false
    $squeeze = $false
    $sets = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('c', 'd', 's'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'tr' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -ceq 'c') { $complement = $true }
                elseif ($option -ceq 'd') { $delete = $true }
                elseif ($option -ceq 's') { $squeeze = $true }
            }
            continue
        }
        $sets += $argument
    }
    $minimumSets = if ($delete -or ($squeeze -and -not $delete)) { 1 } else { 2 }
    if ($sets.Count -lt $minimumSets -or $sets.Count -gt 2) {
        Write-PshCommandFailure -Command 'tr' -Code 2 -Message 'the documented subset requires one or two character sets for the selected mode.'
        return
    }

    try {
        $set1 = [char[]](Expand-PshTrSet -Set $sets[0])
        $set2 = @()
        if ($sets.Count -gt 1) { $set2 = [char[]](Expand-PshTrSet -Set $sets[1]) }
        if (-not $delete -and $sets.Count -gt 1 -and $set2.Count -eq 0) {
            Write-PshCommandFailure -Command 'tr' -Code 2 -Message 'set2 cannot be empty for translation.'
            return
        }

        $set1Index = @{}
        for ($index = 0; $index -lt $set1.Count; $index++) {
            $key = [string]$set1[$index]
            if (-not $set1Index.ContainsKey($key)) { $set1Index[$key] = $index }
        }
        $squeezeSet = @{}
        $squeezeCharacters = $set1
        if ($sets.Count -gt 1) { $squeezeCharacters = $set2 }
        foreach ($character in $squeezeCharacters) { $squeezeSet[[string]$character] = $true }

        $source = New-PshPipelineTextSource -Items $pipelineItems
        $builder = New-Object Text.StringBuilder
        $previous = $null
        foreach ($character in ([string]$source.Text).ToCharArray()) {
            $key = [string]$character
            $inSet = $set1Index.ContainsKey($key)
            $selected = if ($complement) { -not $inSet } else { $inSet }
            if ($delete -and $selected) { continue }

            $outputCharacter = $character
            if (-not $delete -and $sets.Count -gt 1 -and $selected) {
                $mapIndex = if ($complement) { $set2.Count - 1 } else { 0 }
                if (-not $complement -and $inSet) { $mapIndex = [int]$set1Index[$key] }
                if ($mapIndex -ge $set2.Count) { $mapIndex = $set2.Count - 1 }
                $outputCharacter = $set2[$mapIndex]
            }
            if ($squeeze -and $null -ne $previous -and $outputCharacter -eq $previous -and $squeezeSet.ContainsKey([string]$outputCharacter)) {
                continue
            }
            [void]$builder.Append($outputCharacter)
            $previous = $outputCharacter
        }
        Write-PshTextValue -Text $builder.ToString()
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'tr' -Code 3 -Message $_.Exception.Message
    }
}

function Get-PshSortFieldValues {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,

        [AllowNull()]
        [string]$Delimiter
    )

    if ($null -ne $Delimiter) {
        return ,$Line.Split([char[]]@([char]$Delimiter), [StringSplitOptions]::None)
    }
    $matches = [Text.RegularExpressions.Regex]::Matches($Line, '\S+')
    $fields = @()
    foreach ($match in $matches) { $fields += [string]$match.Value }
    return $fields
}

function ConvertTo-PshSortKeySpecification {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -notmatch '\A([1-9][0-9]*)(?:\.([1-9][0-9]*))?(?:,([1-9][0-9]*)(?:\.([1-9][0-9]*))?)?\z') {
        throw ('invalid sort key: {0}' -f $Value)
    }
    return [PSCustomObject]@{
        StartField = [int]$matches[1]
        StartCharacter = if ([string]::IsNullOrEmpty($matches[2])) { 1 } else { [int]$matches[2] }
        EndField = if ([string]::IsNullOrEmpty($matches[3])) { [int]::MaxValue } else { [int]$matches[3] }
        EndCharacter = if ([string]::IsNullOrEmpty($matches[4])) { [int]::MaxValue } else { [int]$matches[4] }
    }
}

function Get-PshSortKeyValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,

        [AllowNull()]
        [object]$KeySpecification,

        [AllowNull()]
        [string]$Delimiter
    )

    if ($null -eq $KeySpecification) { return $Line }
    $fields = @(Get-PshSortFieldValues -Line $Line -Delimiter $Delimiter)
    $startField = [int]$KeySpecification.StartField - 1
    if ($startField -ge $fields.Count) { return '' }
    $endField = [Math]::Min($fields.Count - 1, [int]$KeySpecification.EndField - 1)
    $selected = @()
    for ($index = $startField; $index -le $endField; $index++) { $selected += [string]$fields[$index] }
    $separator = if ($null -eq $Delimiter) { ' ' } else { $Delimiter }
    $value = $selected -join $separator
    $startCharacter = [int]$KeySpecification.StartCharacter - 1
    if ($startCharacter -ge $value.Length) { return '' }
    $value = $value.Substring($startCharacter)
    if ([int]$KeySpecification.EndCharacter -ne [int]::MaxValue) {
        $length = [Math]::Min($value.Length, [int]$KeySpecification.EndCharacter - [int]$KeySpecification.StartCharacter + 1)
        if ($length -lt 0) { return '' }
        $value = $value.Substring(0, $length)
    }
    return $value
}

function ConvertTo-PshSortNumericValue {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) { return 0.0 }
    $match = [Text.RegularExpressions.Regex]::Match($Value, '\A\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')
    if (-not $match.Success) { return 0.0 }
    $number = 0.0
    if (-not [double]::TryParse($match.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return 0.0
    }
    return $number
}

function Compare-PshSortLineValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right,

        [AllowNull()]
        [object]$KeySpecification,

        [AllowNull()]
        [string]$Delimiter,

        [switch]$IgnoreLeadingBlank,

        [switch]$IgnoreCase,

        [switch]$Numeric,

        [switch]$Reverse,

        [switch]$KeyOnly
    )

    $leftKey = Get-PshSortKeyValue -Line $Left -KeySpecification $KeySpecification -Delimiter $Delimiter
    $rightKey = Get-PshSortKeyValue -Line $Right -KeySpecification $KeySpecification -Delimiter $Delimiter
    if ($IgnoreLeadingBlank) { $leftKey = $leftKey.TrimStart(); $rightKey = $rightKey.TrimStart() }
    if ($IgnoreCase) { $leftKey = $leftKey.ToUpperInvariant(); $rightKey = $rightKey.ToUpperInvariant() }
    $comparison = 0
    if ($Numeric) {
        $leftNumber = ConvertTo-PshSortNumericValue -Value $leftKey
        $rightNumber = ConvertTo-PshSortNumericValue -Value $rightKey
        $comparison = $leftNumber.CompareTo($rightNumber)
    }
    else { $comparison = [StringComparer]::Ordinal.Compare($leftKey, $rightKey) }
    if ($comparison -eq 0 -and -not $KeyOnly -and $null -ne $KeySpecification) {
        $comparison = [StringComparer]::Ordinal.Compare($Left, $Right)
    }
    if ($Reverse) { $comparison = -$comparison }
    return $comparison
}

function Sort-PshLineValues {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @(),

        [AllowNull()]
        [object]$KeySpecification,

        [AllowNull()]
        [string]$Delimiter,

        [switch]$IgnoreLeadingBlank,

        [switch]$IgnoreCase,

        [switch]$Numeric,

        [switch]$Reverse
    )

    $result = @($Lines)
    for ($index = 1; $index -lt $result.Count; $index++) {
        $current = [string]$result[$index]
        $position = $index - 1
        while ($position -ge 0 -and (Compare-PshSortLineValues -Left ([string]$result[$position]) -Right $current -KeySpecification $KeySpecification -Delimiter $Delimiter -IgnoreLeadingBlank:$IgnoreLeadingBlank -IgnoreCase:$IgnoreCase -Numeric:$Numeric -Reverse:$Reverse) -gt 0) {
            $result[$position + 1] = $result[$position]
            $position--
        }
        $result[$position + 1] = $current
    }
    return $result
}

function sort {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: sort [-bfnru] [-k key] [-t delimiter] [file ...]'
        return
    }

    $ignoreLeadingBlank = $false
    $ignoreCase = $false
    $numeric = $false
    $reverse = $false
    $unique = $false
    $keyValue = $null
    $delimiter = $null
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        $option = $null
        $value = $null
        if ($parseOptions -and $argument -match '\A-([kt])(.+)\z') { $option = '-' + $matches[1]; $value = $matches[2] }
        elseif ($parseOptions -and $argument -cin @('-k', '-t')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'sort' -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $option = $argument
            $index++
            $value = $arguments[$index]
        }
        if ($null -ne $option) {
            if ($option -ceq '-k') { $keyValue = $value }
            else {
                if (([string]$value).Length -ne 1) {
                    Write-PshCommandFailure -Command 'sort' -Code 2 -Message 'field separator must be exactly one character.'
                    return
                }
                $delimiter = $value
            }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('b', 'f', 'n', 'r', 'u'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'sort' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($item in $expanded) {
                if ($item -ceq 'b') { $ignoreLeadingBlank = $true }
                elseif ($item -ceq 'f') { $ignoreCase = $true }
                elseif ($item -ceq 'n') { $numeric = $true }
                elseif ($item -ceq 'r') { $reverse = $true }
                elseif ($item -ceq 'u') { $unique = $true }
            }
            continue
        }
        $paths += $argument
    }

    try {
        $keySpecification = ConvertTo-PshSortKeySpecification -Value $keyValue
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems)
        $lines = @()
        foreach ($source in $sources) {
            foreach ($line in @(Split-PshTextLines -Text ([string]$source.Text))) { $lines += [string]$line.Text }
        }
        $sorted = @(Sort-PshLineValues -Lines $lines -KeySpecification $keySpecification -Delimiter $delimiter -IgnoreLeadingBlank:$ignoreLeadingBlank -IgnoreCase:$ignoreCase -Numeric:$numeric -Reverse:$reverse)
        $previous = $null
        $hasPrevious = $false
        foreach ($line in $sorted) {
            if ($unique -and $hasPrevious -and (Compare-PshSortLineValues -Left ([string]$previous) -Right ([string]$line) -KeySpecification $keySpecification -Delimiter $delimiter -IgnoreLeadingBlank:$ignoreLeadingBlank -IgnoreCase:$ignoreCase -Numeric:$numeric -KeyOnly) -eq 0) {
                continue
            }
            Write-PshTextValue -Text ([string]$line) -EmitEmpty
            $previous = [string]$line
            $hasPrevious = $true
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        $code = if ($_.Exception.Message -match '\Ainvalid sort key') { 2 } else { 3 }
        Write-PshCommandFailure -Command 'sort' -Code $code -Message $_.Exception.Message
    }
}

function Get-PshUniqComparisonValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,

        [int]$SkipFields = 0,

        [int]$SkipCharacters = 0,

        [switch]$IgnoreCase
    )

    $value = $Line
    if ($SkipFields -gt 0) {
        $matches = [Text.RegularExpressions.Regex]::Matches($value, '\s*\S+')
        if ($matches.Count -le $SkipFields) { $value = '' }
        else { $value = $value.Substring($matches[$SkipFields].Index) }
    }
    if ($SkipCharacters -gt 0) {
        if ($SkipCharacters -ge $value.Length) { $value = '' }
        else { $value = $value.Substring($SkipCharacters) }
    }
    if ($IgnoreCase) { $value = $value.ToUpperInvariant() }
    return $value
}

function uniq {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: uniq [-cdui] [-f fields] [-s chars] [input [output]]'
        return
    }

    $count = $false
    $repeatedOnly = $false
    $uniqueOnly = $false
    $ignoreCase = $false
    $skipFields = 0
    $skipCharacters = 0
    $positionals = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        $option = $null
        $value = $null
        if ($parseOptions -and $argument -match '\A-([fs])([0-9]+)\z') { $option = '-' + $matches[1]; $value = $matches[2] }
        elseif ($parseOptions -and $argument -cin @('-f', '-s')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'uniq' -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $option = $argument
            $index++
            $value = $arguments[$index]
        }
        if ($null -ne $option) {
            $number = 0
            if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 0) {
                Write-PshCommandFailure -Command 'uniq' -Code 2 -Message ('option {0} requires a non-negative integer.' -f $option)
                return
            }
            if ($option -ceq '-f') { $skipFields = $number } else { $skipCharacters = $number }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('c', 'd', 'u', 'i'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'uniq' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($item in $expanded) {
                if ($item -ceq 'c') { $count = $true }
                elseif ($item -ceq 'd') { $repeatedOnly = $true }
                elseif ($item -ceq 'u') { $uniqueOnly = $true }
                elseif ($item -ceq 'i') { $ignoreCase = $true }
            }
            continue
        }
        $positionals += $argument
    }
    if ($positionals.Count -gt 2) {
        Write-PshCommandFailure -Command 'uniq' -Code 2 -Message 'at most one input and one output file are supported.'
        return
    }
    if ($repeatedOnly -and $uniqueOnly) {
        Write-PshCommandFailure -Command 'uniq' -Code 2 -Message '-d and -u are mutually exclusive in the documented subset.'
        return
    }

    try {
        $inputPaths = @()
        if ($positionals.Count -gt 0) { $inputPaths = @([string]$positionals[0]) }
        $source = (@(Get-PshTextSources -Paths $inputPaths -PipelineItems $pipelineItems))[0]
        $lines = @(Split-PshTextLines -Text ([string]$source.Text) | ForEach-Object { [string]$_.Text })
        $outputLines = @()
        $index = 0
        while ($index -lt $lines.Count) {
            $line = [string]$lines[$index]
            $key = Get-PshUniqComparisonValue -Line $line -SkipFields $skipFields -SkipCharacters $skipCharacters -IgnoreCase:$ignoreCase
            $groupCount = 1
            while (($index + $groupCount) -lt $lines.Count) {
                $nextKey = Get-PshUniqComparisonValue -Line ([string]$lines[$index + $groupCount]) -SkipFields $skipFields -SkipCharacters $skipCharacters -IgnoreCase:$ignoreCase
                if (-not [string]::Equals($key, $nextKey, [StringComparison]::Ordinal)) { break }
                $groupCount++
            }
            $emit = (-not $repeatedOnly -and -not $uniqueOnly) -or ($repeatedOnly -and $groupCount -gt 1) -or ($uniqueOnly -and $groupCount -eq 1)
            if ($emit) {
                if ($count) { $outputLines += ('{0,7} {1}' -f $groupCount, $line) }
                else { $outputLines += $line }
            }
            $index += $groupCount
        }

        if ($positionals.Count -eq 2) {
            $outputPath = Resolve-PshFileSystemPath -Path ([string]$positionals[1]) -AllowMissing
            if ([IO.Directory]::Exists($outputPath)) { throw ('output path is a directory: {0}' -f [string]$positionals[1]) }
            $text = ''
            if ($outputLines.Count -gt 0) { $text = ($outputLines -join [Environment]::NewLine) + [Environment]::NewLine }
            [IO.File]::WriteAllText($outputPath, $text, (New-Object Text.UTF8Encoding($false)))
        }
        else {
            foreach ($line in $outputLines) { Write-PshTextValue -Text ([string]$line) -EmitEmpty }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'uniq' -Code 3 -Message $_.Exception.Message
    }
}

function Get-PshUnicodeCodePointCount {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) { return 0L }
    $count = 0L
    for ($index = 0; $index -lt $Text.Length; $index++) {
        if ([char]::IsHighSurrogate($Text[$index]) -and ($index + 1) -lt $Text.Length -and [char]::IsLowSurrogate($Text[$index + 1])) { $index++ }
        $count++
    }
    return $count
}

function Measure-PshTextSource {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source
    )

    $lineCount = 0L
    foreach ($value in [byte[]]$Source.Bytes) { if ($value -eq 10) { $lineCount++ } }
    $wordCount = [long][Text.RegularExpressions.Regex]::Matches([string]$Source.Text, '\S+').Count
    return [PSCustomObject]@{
        Path = if ($Source.IsStandardInput) { $null } else { [string]$Source.Path }
        DisplayName = [string]$Source.DisplayName
        Lines = $lineCount
        Words = $wordCount
        Characters = [long](Get-PshUnicodeCodePointCount -Text ([string]$Source.Text))
        Bytes = [long]([byte[]]$Source.Bytes).LongLength
        IsStandardInput = [bool]$Source.IsStandardInput
    }
}

function wc {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: wc [-clmw] [file ...]'
        return
    }

    $countBytes = $false
    $countLines = $false
    $countCharacters = $false
    $countWords = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('c', 'l', 'm', 'w'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'wc' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($item in $expanded) {
                if ($item -ceq 'c') { $countBytes = $true }
                elseif ($item -ceq 'l') { $countLines = $true }
                elseif ($item -ceq 'm') { $countCharacters = $true }
                elseif ($item -ceq 'w') { $countWords = $true }
            }
            continue
        }
        $paths += $argument
    }
    if (-not $countBytes -and -not $countLines -and -not $countCharacters -and -not $countWords) {
        $countLines = $true
        $countWords = $true
        $countBytes = $true
    }

    try {
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems)
        $rows = @()
        foreach ($source in $sources) { $rows += Measure-PshTextSource -Source $source }
        if ($rows.Count -gt 1) {
            $rows += [PSCustomObject]@{
                DisplayName = 'total'
                Lines = [long](($rows | Microsoft.PowerShell.Utility\Measure-Object -Property Lines -Sum).Sum)
                Words = [long](($rows | Microsoft.PowerShell.Utility\Measure-Object -Property Words -Sum).Sum)
                Characters = [long](($rows | Microsoft.PowerShell.Utility\Measure-Object -Property Characters -Sum).Sum)
                Bytes = [long](($rows | Microsoft.PowerShell.Utility\Measure-Object -Property Bytes -Sum).Sum)
                IsStandardInput = $false
            }
        }
        $properties = @()
        if ($countLines) { $properties += 'Lines' }
        if ($countWords) { $properties += 'Words' }
        if ($countCharacters) { $properties += 'Characters' }
        if ($countBytes) { $properties += 'Bytes' }
        $width = if (@($rows | Where-Object { $_.IsStandardInput }).Count -gt 0) { 7 } else { 1 }
        foreach ($row in $rows) {
            foreach ($property in $properties) { $width = [Math]::Max($width, ([string][long]$row.$property).Length) }
        }
        foreach ($row in $rows) {
            $values = @()
            $format = '{0,' + [string]$width + '}'
            foreach ($property in $properties) { $values += ($format -f [long]$row.$property) }
            $line = $values -join ' '
            if (-not $row.IsStandardInput) { $line += ' ' + [string]$row.DisplayName }
            Write-PshTextValue -Text $line
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'wc' -Code 3 -Message $_.Exception.Message
    }
}

function Measure-PshText {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject,

        [string[]]$Path = @()
    )
    begin { $items = @() }
    process { $items += $InputObject }
    end {
        foreach ($source in @(Get-PshTextSources -Paths $Path -PipelineItems $items)) {
            Measure-PshTextSource -Source $source
        }
    }
}

function tee {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: tee [-ai] [file ...]'
        return
    }

    $append = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('a', 'i'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'tee' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($item in $expanded) { if ($item -ceq 'a') { $append = $true } }
            continue
        }
        $paths += $argument
    }

    try {
        $source = New-PshPipelineTextSource -Items $pipelineItems
        $requiresRaw = $source.IsBinary -or [string]$source.Encoding -cne 'utf-8'
        $hasDownstream = Test-PshInvocationHasDownstream -Invocation $MyInvocation
        if ($requiresRaw -and $hasDownstream) {
            Write-PshCommandFailure -Command 'tee' -Code 2 -Message 'binary tee output requires raw stdout and cannot enter the PowerShell object pipeline.'
            return
        }
        foreach ($operand in $paths) {
            $path = Resolve-PshFileSystemPath -Path $operand -AllowMissing
            if ([IO.Directory]::Exists($path)) { throw ('output path is a directory: {0}' -f $operand) }
            if ($append) {
                $stream = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                try { $stream.Write([byte[]]$source.Bytes, 0, ([byte[]]$source.Bytes).Length) }
                finally { $stream.Dispose() }
            }
            else { [IO.File]::WriteAllBytes($path, [byte[]]$source.Bytes) }
        }

        if ($requiresRaw) {
            Write-PshRawBytes -Bytes ([byte[]]$source.Bytes)
        }
        else { Write-PshTextValue -Text ([string]$source.Text) }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'tee' -Code 3 -Message $_.Exception.Message
    }
}

function ConvertTo-PshPrintfInteger {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) { return 0L }
    if ($Value.Length -ge 2 -and ($Value[0] -eq "'" -or $Value[0] -eq '"')) { return [long][int]$Value[1] }
    $number = 0L
    if (-not [long]::TryParse($Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        throw ('invalid integer value "{0}".' -f $Value)
    }
    return $number
}

function ConvertTo-PshUnsignedBaseText {
    param(
        [long]$Value,

        [ValidateSet(8, 16)]
        [int]$Base,

        [switch]$Upper
    )

    $unsigned = [uint64]$Value
    if ($Value -lt 0) { $unsigned = [uint64]([long]::MaxValue) + [uint64]1 + [uint64]([long]::MaxValue + $Value + 1) }
    if ($Base -eq 16) {
        $format = if ($Upper) { 'X' } else { 'x' }
        return $unsigned.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($unsigned -eq 0) { return '0' }
    $characters = New-Object 'System.Collections.Generic.List[char]'
    while ($unsigned -gt 0) {
        $characters.Add([char]([int][char]'0' + [int]($unsigned % [uint64]8)))
        $unsigned = [uint64]($unsigned / [uint64]8)
    }
    $array = $characters.ToArray()
    [Array]::Reverse($array)
    return (-join $array)
}

function Format-PshPrintfConversion {
    param(
        [Parameter(Mandatory = $true)]
        [char]$Type,

        [AllowNull()]
        [string]$Argument,

        [AllowNull()]
        [string]$Flags,

        [AllowNull()]
        [string]$WidthText,

        [AllowNull()]
        [string]$PrecisionText
    )

    $stopped = $false
    $value = ''
    if ($Type -ceq 's') { $value = if ($null -eq $Argument) { '' } else { $Argument } }
    elseif ($Type -ceq 'b') {
        $decoded = ConvertFrom-PshBackslashText -Text $Argument -StopOnC
        $value = [string]$decoded.Text
        $stopped = [bool]$decoded.Stopped
    }
    elseif ($Type -ceq 'c') {
        if (-not [string]::IsNullOrEmpty($Argument)) { $value = [string]$Argument[0] }
    }
    elseif ($Type -ceq 'f') {
        $number = 0.0
        if (-not [double]::TryParse([string]$Argument, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            throw ('invalid floating-point value "{0}".' -f [string]$Argument)
        }
        $precision = 6
        if (-not [string]::IsNullOrEmpty($PrecisionText)) { $precision = [int]$PrecisionText }
        $value = $number.ToString(('F{0}' -f $precision), [Globalization.CultureInfo]::InvariantCulture)
    }
    else {
        $number = ConvertTo-PshPrintfInteger -Value $Argument
        if ($Type -ceq 'o') { $value = ConvertTo-PshUnsignedBaseText -Value $number -Base 8 }
        elseif ($Type -ceq 'x' -or $Type -ceq 'X') { $value = ConvertTo-PshUnsignedBaseText -Value $number -Base 16 -Upper:($Type -ceq 'X') }
        elseif ($Type -ceq 'u') {
            if ($number -lt 0) {
                $unsignedDecimal = [decimal][uint64]::MaxValue + [decimal]$number + [decimal]1
                $value = $unsignedDecimal.ToString('0', [Globalization.CultureInfo]::InvariantCulture)
            }
            else { $value = ([uint64]$number).ToString([Globalization.CultureInfo]::InvariantCulture) }
        }
        else { $value = $number.ToString([Globalization.CultureInfo]::InvariantCulture) }

        if (-not [string]::IsNullOrEmpty($PrecisionText)) {
            $negative = $value.StartsWith('-')
            $digits = if ($negative) { $value.Substring(1) } else { $value }
            $digits = $digits.PadLeft([int]$PrecisionText, '0')
            $value = if ($negative) { '-' + $digits } else { $digits }
        }
        if ($number -ge 0 -and $Type -cin @('d', 'i')) {
            if ($Flags.Contains('+')) { $value = '+' + $value }
            elseif ($Flags.Contains(' ')) { $value = ' ' + $value }
        }
    }

    if (($Type -ceq 's' -or $Type -ceq 'b') -and -not [string]::IsNullOrEmpty($PrecisionText) -and $value.Length -gt [int]$PrecisionText) {
        $value = $value.Substring(0, [int]$PrecisionText)
    }
    if (-not [string]::IsNullOrEmpty($WidthText)) {
        $width = [int]$WidthText
        if ($value.Length -lt $width) {
            if ($Flags.Contains('-')) { $value = $value.PadRight($width, ' ') }
            elseif ($Flags.Contains('0') -and $Type -notin @('s', 'b', 'c')) {
                if ($value.StartsWith('+') -or $value.StartsWith('-') -or $value.StartsWith(' ')) {
                    $value = $value.Substring(0, 1) + $value.Substring(1).PadLeft($width - 1, '0')
                }
                else { $value = $value.PadLeft($width, '0') }
            }
            else { $value = $value.PadLeft($width, ' ') }
        }
    }
    return [PSCustomObject]@{ Text = $value; Stopped = $stopped }
}

function Format-PshPrintfText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Format,

        [AllowEmptyCollection()]
        [string[]]$Values = @()
    )

    $output = New-Object Text.StringBuilder
    $argumentIndex = 0
    $stopped = $false
    do {
        $conversionCount = 0
        for ($index = 0; $index -lt $Format.Length; $index++) {
            $character = $Format[$index]
            if ($character -eq '\') {
                $start = $index
                $index++
                if ($index -ge $Format.Length) { [void]$output.Append('\'); break }
                $escapeText = '\' + [string]$Format[$index]
                if ($Format[$index] -ceq 'x') {
                    while (($index + 1) -lt $Format.Length -and $escapeText.Length -lt 4 -and $Format[$index + 1] -match '[0-9A-Fa-f]') { $index++; $escapeText += [string]$Format[$index] }
                }
                elseif ($Format[$index] -match '[0-7]') {
                    while (($index + 1) -lt $Format.Length -and $escapeText.Length -lt 4 -and $Format[$index + 1] -match '[0-7]') { $index++; $escapeText += [string]$Format[$index] }
                }
                $decoded = ConvertFrom-PshBackslashText -Text $escapeText -StopOnC
                [void]$output.Append([string]$decoded.Text)
                if ($decoded.Stopped) { $stopped = $true; break }
                continue
            }
            if ($character -ne '%') { [void]$output.Append($character); continue }
            $remaining = $Format.Substring($index)
            $match = [Text.RegularExpressions.Regex]::Match($remaining, '\A%([-+ 0#]*)([0-9]*)(?:\.([0-9]+))?([%sbcdiuoxXf])')
            if (-not $match.Success) { throw ('unsupported printf conversion near "{0}".' -f $remaining) }
            $index += $match.Length - 1
            $type = [char]$match.Groups[4].Value[0]
            if ($type -ceq '%') { [void]$output.Append('%'); continue }
            $conversionCount++
            $argument = $null
            if ($argumentIndex -lt $Values.Count) { $argument = [string]$Values[$argumentIndex] }
            elseif ($type -cin @('d', 'i', 'u', 'o', 'x', 'X', 'f')) { $argument = '0' }
            else { $argument = '' }
            $argumentIndex++
            $formatted = Format-PshPrintfConversion -Type $type -Argument $argument -Flags $match.Groups[1].Value -WidthText $match.Groups[2].Value -PrecisionText $match.Groups[3].Value
            [void]$output.Append([string]$formatted.Text)
            if ($formatted.Stopped) { $stopped = $true; break }
        }
        if ($stopped -or $conversionCount -eq 0) { break }
    } while ($argumentIndex -lt $Values.Count)

    return [PSCustomObject]@{ Text = $output.ToString(); Stopped = $stopped }
}

function printf {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: printf [-v variable] format [argument ...]'
        return
    }

    $variableName = $null
    $index = 0
    if ($arguments.Count -gt 0 -and $arguments[0] -ceq '-v') {
        if ($arguments.Count -lt 3) {
            Write-PshCommandFailure -Command 'printf' -Code 2 -Message '-v requires a variable name and format.'
            return
        }
        $variableName = $arguments[1]
        if ($variableName -notmatch '\A[A-Za-z_][A-Za-z0-9_]*\z') {
            Write-PshCommandFailure -Command 'printf' -Code 2 -Message ('invalid variable name "{0}".' -f $variableName)
            return
        }
        $index = 2
    }
    elseif ($arguments.Count -gt 0 -and $arguments[0].StartsWith('-') -and $arguments[0] -ne '-') {
        Write-PshCommandFailure -Command 'printf' -Code 2 -Message ('unsupported argument "{0}".' -f $arguments[0])
        return
    }
    if ($index -ge $arguments.Count) {
        Write-PshCommandFailure -Command 'printf' -Code 2 -Message 'a format string is required.'
        return
    }

    try {
        $format = $arguments[$index]
        $values = @()
        if (($index + 1) -lt $arguments.Count) { $values = @($arguments[($index + 1)..($arguments.Count - 1)]) }
        $result = Format-PshPrintfText -Format $format -Values $values
        if ($null -ne $variableName) {
            Set-Variable -Name $variableName -Value ([string]$result.Text) -Scope Global -Force
        }
        elseif (Test-PshInvocationHasDownstream -Invocation $MyInvocation) {
            Write-PshTextValue -Text ([string]$result.Text) -EmitEmpty
        }
        else { Write-PshRawBytes -Bytes ([byte[]](ConvertTo-PshUtf8Bytes -Text ([string]$result.Text))) }
        Set-PshLastExitCode -Code 0
    }
    catch {
        $code = if ($_.Exception.Message -match '\A(unsupported printf conversion|invalid (integer|floating-point))') { 2 } else { 3 }
        Write-PshCommandFailure -Command 'printf' -Code $code -Message $_.Exception.Message
    }
}

function echo {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: echo [-n] [-e|-E] [argument ...]'
        return
    }

    $noNewline = $false
    $escapes = $false
    $values = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('n', 'e', 'E'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'echo' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($item in $expanded) {
                if ($item -ceq 'n') { $noNewline = $true }
                elseif ($item -ceq 'e') { $escapes = $true }
                elseif ($item -ceq 'E') { $escapes = $false }
            }
            continue
        }
        $parseOptions = $false
        $values += $argument
    }

    $text = $values -join ' '
    if ($escapes) {
        $decoded = ConvertFrom-PshBackslashText -Text $text -StopOnC
        $text = [string]$decoded.Text
        if ($decoded.Stopped) { $noNewline = $true }
    }
    if ($noNewline -and -not (Test-PshInvocationHasDownstream -Invocation $MyInvocation)) {
        Write-PshRawBytes -Bytes ([byte[]](ConvertTo-PshUtf8Bytes -Text $text))
    }
    else { Write-PshTextValue -Text $text -EmitEmpty }
    Set-PshLastExitCode -Code 0
}

function base64 {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: base64 [-d|--decode] [-w columns|--wrap columns] [file]'
        return
    }

    $decode = $false
    $wrap = 76
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -cin @('-d', '--decode')) { $decode = $true; continue }
        $value = $null
        if ($parseOptions -and $argument -match '\A--wrap=(.+)\z') { $value = $matches[1] }
        elseif ($parseOptions -and $argument -match '\A-w([0-9]+)\z') { $value = $matches[1] }
        elseif ($parseOptions -and $argument -cin @('-w', '--wrap')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'base64' -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $index++
            $value = $arguments[$index]
        }
        if ($null -ne $value) {
            if (-not [int]::TryParse($value, [ref]$wrap) -or $wrap -lt 0) {
                Write-PshCommandFailure -Command 'base64' -Code 2 -Message 'wrap width must be a non-negative integer.'
                return
            }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'base64' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
            return
        }
        $paths += $argument
    }
    if ($paths.Count -gt 1) {
        Write-PshCommandFailure -Command 'base64' -Code 2 -Message 'at most one input file is supported.'
        return
    }
    if (-not $decode -and $wrap -eq 0 -and (Test-PshInvocationHasDownstream -Invocation $MyInvocation)) {
        Stop-PshDownstreamUsageFailure -Command 'base64' -Message 'unwrapped Base64 output requires raw stdout and cannot enter a downstream pipeline.'
    }

    try {
        $source = (@(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems))[0]
        $outputBytes = $null
        if ($decode) {
            $payload = [Text.RegularExpressions.Regex]::Replace([string]$source.Text, '\s+', '')
            try { $outputBytes = [Convert]::FromBase64String($payload) }
            catch { throw ('invalid Base64 input: {0}' -f $_.Exception.Message) }
        }
        else {
            $encoded = [Convert]::ToBase64String([byte[]]$source.Bytes)
            if ($wrap -gt 0 -and $encoded.Length -gt 0) {
                $builder = New-Object Text.StringBuilder
                for ($offset = 0; $offset -lt $encoded.Length; $offset += $wrap) {
                    $length = [Math]::Min($wrap, $encoded.Length - $offset)
                    [void]$builder.Append($encoded.Substring($offset, $length))
                    [void]$builder.Append("`n")
                }
                $encoded = $builder.ToString()
            }
            $outputBytes = [byte[]](ConvertTo-PshUtf8Bytes -Text $encoded)
        }

        if (-not $decode) {
            if ($wrap -eq 0) {
                Write-PshRawBytes -Bytes ([byte[]]$outputBytes)
            }
            else {
                $outputText = ConvertFrom-PshStrictUtf8Bytes -Bytes ([byte[]]$outputBytes)
                if ($outputText.EndsWith("`n")) { $outputText = $outputText.Substring(0, $outputText.Length - 1) }
                Write-PshTextValue -Text $outputText
            }
        }
        elseif (Test-PshInvocationHasDownstream -Invocation $MyInvocation) {
            if (Test-PshBytesRequireRawOutput -Bytes ([byte[]]$outputBytes)) {
                Write-PshCommandFailure -Command 'base64' -Code 2 -Message 'decoded binary output requires raw stdout and cannot enter the PowerShell object pipeline.'
                return
            }
            $outputText = ConvertFrom-PshStrictUtf8Bytes -Bytes ([byte[]]$outputBytes)
            Write-PshTextValue -Text $outputText
        }
        else { Write-PshRawBytes -Bytes ([byte[]]$outputBytes) }
        Set-PshLastExitCode -Code 0
    }
    catch {
        $code = if ($_.Exception.Message -match '\Ainvalid Base64 input') { 3 } else { 3 }
        Write-PshCommandFailure -Command 'base64' -Code $code -Message $_.Exception.Message
    }
}

function Throw-PshTextUsageError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $exception = New-Object ArgumentException($Message)
    $exception.Data['PshExitCode'] = 2
    throw $exception
}

function Get-PshTextErrorCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [int]$Default = 3
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('PshExitCode')) {
            $code = 0
            if ([int]::TryParse([string]$exception.Data['PshExitCode'], [ref]$code) -and $code -in @(1, 2, 3, 4, 5)) {
                return $code
            }
        }
        $exception = $exception.InnerException
    }
    return $Default
}

function ConvertTo-PshEncodedTextBytes {
    param(
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$EncodingName
    )

    if ($null -eq $Text) { $Text = '' }
    $encoding = $null
    $includePreamble = $false
    switch ($EncodingName) {
        'utf-8' { $encoding = New-Object Text.UTF8Encoding($false, $true) }
        'utf-8-bom' { $encoding = New-Object Text.UTF8Encoding($true, $true); $includePreamble = $true }
        'utf-16le' { $encoding = New-Object Text.UnicodeEncoding($false, $true, $true); $includePreamble = $true }
        'utf-16be' { $encoding = New-Object Text.UnicodeEncoding($true, $true, $true); $includePreamble = $true }
        'utf-32le' { $encoding = New-Object Text.UTF32Encoding($false, $true, $true); $includePreamble = $true }
        'utf-32be' { $encoding = New-Object Text.UTF32Encoding($true, $true, $true); $includePreamble = $true }
        default { Throw-PshTextUsageError ('unsupported text encoding for an in-place edit: {0}.' -f $EncodingName) }
    }

    $body = [byte[]]$encoding.GetBytes($Text)
    if (-not $includePreamble) { return $body }
    $preamble = [byte[]]$encoding.GetPreamble()
    $result = New-Object byte[] ($preamble.Length + $body.Length)
    if ($preamble.Length -gt 0) { [Array]::Copy($preamble, 0, $result, 0, $preamble.Length) }
    if ($body.Length -gt 0) { [Array]::Copy($body, 0, $result, $preamble.Length, $body.Length) }
    return $result
}

function Test-PshTextByteSequenceEqual {
    param(
        [AllowNull()]
        [byte[]]$Left,

        [AllowNull()]
        [byte[]]$Right
    )

    if ($null -eq $Left) { $Left = [byte[]]@() }
    if ($null -eq $Right) { $Right = [byte[]]@() }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Test-PshTextFileBytesEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$ExpectedBytes
    )

    if (-not [IO.File]::Exists($Path)) { return $false }
    try {
        return (Test-PshTextByteSequenceEqual -Left ([IO.File]::ReadAllBytes($Path)) -Right $ExpectedBytes)
    }
    catch { return $false }
}

function Write-PshWindowsSecuredFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [object]$Acl
    )

    $stream = $null
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, $sharing)
        Microsoft.PowerShell.Security\Set-Acl -LiteralPath $Path -AclObject $Acl -ErrorAction Stop
        if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
        $stream.Flush()
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Set-PshWindowsFileSecurityExactly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Acl,

        [Parameter(Mandatory = $true)]
        [string]$Sddl
    )

    Microsoft.PowerShell.Security\Set-Acl -LiteralPath $Path -AclObject $Acl -ErrorAction Stop
    $actualSddl = [string](Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path -ErrorAction Stop).Sddl
    if (-not [string]::Equals($actualSddl, $Sddl, [StringComparison]::Ordinal)) {
        throw ('Windows security descriptor verification failed for {0}: expected {1}; actual {2}.' -f $Path, $Sddl, $actualSddl)
    }
}

function Assert-PshWindowsTextFileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$ExpectedBytes,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSddl
    )

    if (-not (Test-PshTextFileBytesEqual -Path $Path -ExpectedBytes $ExpectedBytes)) {
        throw ('file content verification failed for: {0}' -f $Path)
    }
    $actualSddl = [string](Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path -ErrorAction Stop).Sddl
    if (-not [string]::Equals($actualSddl, $ExpectedSddl, [StringComparison]::Ordinal)) {
        throw ('Windows security descriptor verification failed for {0}: expected {1}; actual {2}.' -f $Path, $ExpectedSddl, $actualSddl)
    }
}

function Remove-PshTextTransactionArtifact {
    param(
        [AllowNull()]
        [string]$Path,

        [switch]$Required
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) {
        if ($Required) { throw ('required transaction artifact is unavailable: {0}' -f $Path) }
        return
    }
    [IO.File]::Delete($Path)
    if ([IO.File]::Exists($Path)) { throw ('transaction artifact could not be removed: {0}' -f $Path) }
}

function Get-PshTextOriginalContentPaths {
    param(
        [AllowEmptyCollection()]
        [string[]]$Paths = @(),

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$OriginalBytes
    )

    $seen = @{}
    $matches = @()
    foreach ($candidate in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $fullPath = [IO.Path]::GetFullPath($candidate)
        if ($seen.ContainsKey($fullPath)) { continue }
        $seen[$fullPath] = $true
        if (Test-PshTextFileBytesEqual -Path $fullPath -ExpectedBytes $OriginalBytes) { $matches += $fullPath }
    }
    return $matches
}

function Restore-PshWindowsTextFileTransaction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$OriginalBackupPath,

        [Parameter(Mandatory = $true)]
        [string]$FailedVersionBackupPath,

        [AllowNull()]
        [string]$StagePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$OriginalBytes,

        [Parameter(Mandatory = $true)]
        [object]$SourceAcl,

        [Parameter(Mandatory = $true)]
        [string]$SourceSddl
    )

    $rollbackInstallError = $null
    $originalBackupWasPresent = [IO.File]::Exists($OriginalBackupPath) -or [IO.Directory]::Exists($OriginalBackupPath)
    if ($originalBackupWasPresent) {
        if (-not [IO.File]::Exists($OriginalBackupPath)) {
            $rollbackInstallError = 'the original backup path is not a file.'
        }
        else {
            try {
                if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
                    [void](Install-PshStagedEntry -Stage $OriginalBackupPath -Destination $Path -RetainBackup -BackupPath $FailedVersionBackupPath)
                }
                else {
                    Move-PshLiteralEntry -Source $OriginalBackupPath -Destination $Path
                }
            }
            catch { $rollbackInstallError = $_.Exception.Message }
        }
    }

    $verificationError = $null
    if (Test-PshTextFileBytesEqual -Path $Path -ExpectedBytes $OriginalBytes) {
        try {
            Set-PshWindowsFileSecurityExactly -Path $Path -Acl $SourceAcl -Sddl $SourceSddl
            Assert-PshWindowsTextFileState -Path $Path -ExpectedBytes $OriginalBytes -ExpectedSddl $SourceSddl
        }
        catch { $verificationError = $_.Exception.Message }
    }
    else {
        $verificationError = 'the destination does not contain the original bytes.'
    }

    if ($originalBackupWasPresent -and
        ([IO.File]::Exists($OriginalBackupPath) -or [IO.Directory]::Exists($OriginalBackupPath))) {
        $notConsumedError = 'the original backup was not consumed by the rollback.'
        if ([string]::IsNullOrWhiteSpace($verificationError)) { $verificationError = $notConsumedError }
        else { $verificationError = '{0} {1}' -f $verificationError, $notConsumedError }
    }

    if ([string]::IsNullOrWhiteSpace($verificationError)) {
        try {
            Remove-PshTextTransactionArtifact -Path $FailedVersionBackupPath
            Remove-PshTextTransactionArtifact -Path $StagePath
            return
        }
        catch {
            throw ('the original file is restored and verified at {0}, but rollback artifact cleanup failed: {1}' -f $Path, $_.Exception.Message)
        }
    }

    $candidatePaths = @(Get-PshTextOriginalContentPaths -Paths @($Path, $OriginalBackupPath, $FailedVersionBackupPath, $StagePath) -OriginalBytes $OriginalBytes)
    $recoveryError = $null
    if ($candidatePaths.Count -eq 0) {
        $recoveryPath = New-PshSiblingTemporaryPath -Destination $Path -Purpose 'sed-recovery'
        try {
            Write-PshWindowsSecuredFile -Path $recoveryPath -Bytes $OriginalBytes -Acl $SourceAcl
            Assert-PshWindowsTextFileState -Path $recoveryPath -ExpectedBytes $OriginalBytes -ExpectedSddl $SourceSddl
            $candidatePaths = @($recoveryPath)
        }
        catch {
            $recoveryError = $_.Exception.Message
            if (Test-PshTextFileBytesEqual -Path $recoveryPath -ExpectedBytes $OriginalBytes) {
                $candidatePaths = @($recoveryPath)
            }
        }
    }

    $rollbackContext = if ([string]::IsNullOrWhiteSpace($rollbackInstallError)) { '' } else { ' Rollback install error: {0}.' -f $rollbackInstallError }
    $verificationContext = if ([string]::IsNullOrWhiteSpace($verificationError)) { '' } else { ' Verification error: {0}.' -f $verificationError }
    if ($candidatePaths.Count -gt 0) {
        throw ('rollback did not restore and verify the destination.{0}{1} Original content is retained at: {2}' -f $rollbackContext, $verificationContext, ($candidatePaths -join ', '))
    }
    throw ('rollback did not restore and verify the destination.{0}{1} No verified original-content path remains, and recovery copy creation failed: {2}' -f $rollbackContext, $verificationContext, $recoveryError)
}

function Set-PshWindowsTextFileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $originalBytes = [byte[]][IO.File]::ReadAllBytes($Path)
    $sourceAcl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sourceSddl = [string]$sourceAcl.Sddl
    $stagePath = New-PshSiblingTemporaryPath -Destination $Path -Purpose 'sed'
    $originalBackupPath = New-PshSiblingTemporaryPath -Destination $Path -Purpose 'sed-original'
    $failedVersionBackupPath = New-PshSiblingTemporaryPath -Destination $Path -Purpose 'sed-failed'
    $replaceAttempted = $false
    $committed = $false
    $rollbackSucceeded = $false
    $primaryError = $null
    $rollbackError = $null
    $cleanupError = $null

    try {
        [IO.File]::WriteAllBytes($stagePath, $Bytes)
        $replaceAttempted = $true
        [void](Replace-PshFileEntry -Replacement $stagePath -Destination $Path -RetainBackup -BackupPath $originalBackupPath)
        if (-not [IO.File]::Exists($originalBackupPath)) { throw ('the retained original backup is unavailable: {0}' -f $originalBackupPath) }
        Set-PshWindowsFileSecurityExactly -Path $Path -Acl $sourceAcl -Sddl $sourceSddl
        Assert-PshWindowsTextFileState -Path $Path -ExpectedBytes $Bytes -ExpectedSddl $sourceSddl
        Remove-PshTextTransactionArtifact -Path $originalBackupPath -Required
        $committed = $true
    }
    catch {
        $primaryError = $_.Exception.Message
        if ($replaceAttempted) {
            try {
                Restore-PshWindowsTextFileTransaction -Path $Path -OriginalBackupPath $originalBackupPath -FailedVersionBackupPath $failedVersionBackupPath -StagePath $stagePath -OriginalBytes $originalBytes -SourceAcl $sourceAcl -SourceSddl $sourceSddl
                $rollbackSucceeded = $true
            }
            catch { $rollbackError = $_.Exception.Message }
        }
    }
    finally {
        if ((-not $replaceAttempted -or $committed -or $rollbackSucceeded) -and [IO.File]::Exists($stagePath)) {
            try { Remove-PshTextTransactionArtifact -Path $stagePath }
            catch { $cleanupError = $_.Exception.Message }
        }
    }

    if ($null -ne $rollbackError) {
        $artifacts = @(@($stagePath, $originalBackupPath, $failedVersionBackupPath) | Where-Object { [IO.File]::Exists($_) })
        $artifactText = if ($artifacts.Count -eq 0) { '<none>' } else { $artifacts -join ', ' }
        throw ('Windows sed transaction failed ({0}); rollback failed ({1}); retained transaction paths: {2}' -f $primaryError, $rollbackError, $artifactText)
    }
    if ($null -ne $primaryError) {
        if ($null -ne $cleanupError) {
            throw ('Windows sed transaction failed ({0}); original content remains or was restored at {1}; cleanup failed ({2})' -f $primaryError, $Path, $cleanupError)
        }
        throw $primaryError
    }
    if ($null -ne $cleanupError) {
        throw ('Windows sed replacement committed, but staging cleanup failed: {0}' -f $cleanupError)
    }
}

function Set-PshTextFileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$EncodingName
    )

    $isWindows = $env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\'
    $encodedBytes = [byte[]](ConvertTo-PshEncodedTextBytes -Text $Text -EncodingName $EncodingName)
    if ($isWindows) {
        Set-PshWindowsTextFileAtomically -Path $Path -Bytes $encodedBytes
        return
    }

    [Reflection.MethodInfo]$getUnixFileMode = $null
    [Reflection.MethodInfo]$setUnixFileMode = $null
    $sourceUnixFileMode = $null
    $getUnixFileMode = [Reflection.MethodInfo]@([IO.File].GetMethods() | Where-Object {
        $_.Name -ceq 'GetUnixFileMode' -and $_.IsStatic -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType -eq [string]
    } | Select-Object -First 1)[0]
    $setUnixFileMode = [Reflection.MethodInfo]@([IO.File].GetMethods() | Where-Object {
        $_.Name -ceq 'SetUnixFileMode' -and $_.IsStatic -and $_.GetParameters().Count -eq 2 -and $_.GetParameters()[0].ParameterType -eq [string]
    } | Select-Object -First 1)[0]
    if ($null -ne $getUnixFileMode -and $null -ne $setUnixFileMode) {
        $sourceUnixFileMode = $getUnixFileMode.Invoke($null, [object[]](,[string]$Path))
    }
    else {
        throw 'cannot preserve Unix file permissions because GetUnixFileMode/SetUnixFileMode is unavailable.'
    }

    $temporaryPath = New-PshSiblingTemporaryPath -Destination $Path -Purpose 'sed'
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $encodedBytes)
        $modeType = $setUnixFileMode.GetParameters()[1].ParameterType
        $typedMode = [Enum]::ToObject($modeType, [int]$sourceUnixFileMode)
        [void]$setUnixFileMode.Invoke($null, [object[]]@([string]$temporaryPath, $typedMode))
        Replace-PshFileEntry -Replacement $temporaryPath -Destination $Path
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Move-PshTextIndexPastWhitespace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [ref]$Index
    )

    while ($Index.Value -lt $Text.Length -and [char]::IsWhiteSpace($Text[$Index.Value])) { $Index.Value++ }
}

function Read-PshSedDelimitedText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $true)]
        [ref]$Index,

        [Parameter(Mandatory = $true)]
        [char]$Delimiter,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $builder = New-Object Text.StringBuilder
    while ($Index.Value -lt $Script.Length) {
        $character = $Script[$Index.Value]
        $Index.Value++
        if ($character -eq $Delimiter) { return $builder.ToString() }
        if ($character -eq '\') {
            if ($Index.Value -ge $Script.Length) {
                Throw-PshTextUsageError ('unterminated escape in sed {0}.' -f $Context)
            }
            $next = $Script[$Index.Value]
            $Index.Value++
            if ($next -eq $Delimiter) { [void]$builder.Append($next) }
            else {
                [void]$builder.Append('\')
                [void]$builder.Append($next)
            }
            continue
        }
        [void]$builder.Append($character)
    }
    Throw-PshTextUsageError ('unterminated sed {0}.' -f $Context)
}

function Read-PshSedAddress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $true)]
        [ref]$Index,

        [switch]$Extended
    )

    if ($Index.Value -ge $Script.Length) { return $null }
    $character = $Script[$Index.Value]
    if ([char]::IsDigit($character)) {
        $start = $Index.Value
        while ($Index.Value -lt $Script.Length -and [char]::IsDigit($Script[$Index.Value])) { $Index.Value++ }
        $number = 0
        if (-not [int]::TryParse($Script.Substring($start, $Index.Value - $start), [ref]$number) -or $number -lt 1) {
            Throw-PshTextUsageError 'sed line addresses must be positive integers.'
        }
        return [PSCustomObject]@{ Kind = 'Number'; Number = $number; Regex = $null }
    }
    if ($character -eq '$') {
        $Index.Value++
        return [PSCustomObject]@{ Kind = 'Last'; Number = 0; Regex = $null }
    }
    if ($character -eq '/') {
        $Index.Value++
        $pattern = Read-PshSedDelimitedText -Script $Script -Index $Index -Delimiter '/' -Context 'address'
        if ([string]::IsNullOrEmpty($pattern)) { Throw-PshTextUsageError 'empty sed address expressions are unsupported.' }
        try {
            $regex = New-PshSearchRegex -Pattern $pattern -Basic:(-not $Extended)
        }
        catch { Throw-PshTextUsageError $_.Exception.Message }
        return [PSCustomObject]@{ Kind = 'Regex'; Number = 0; Regex = $regex }
    }
    return $null
}

function Read-PshSedProgram {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $true)]
        [ref]$Index,

        [switch]$Extended
    )

    Move-PshTextIndexPastWhitespace -Text $Script -Index $Index
    $firstAddress = Read-PshSedAddress -Script $Script -Index $Index -Extended:$Extended
    $secondAddress = $null
    if ($null -ne $firstAddress -and $Index.Value -lt $Script.Length -and $Script[$Index.Value] -eq ',') {
        $Index.Value++
        $secondAddress = Read-PshSedAddress -Script $Script -Index $Index -Extended:$Extended
        if ($null -eq $secondAddress) { Throw-PshTextUsageError 'a sed address range requires an ending address.' }
    }
    Move-PshTextIndexPastWhitespace -Text $Script -Index $Index
    if ($Index.Value -ge $Script.Length) { Throw-PshTextUsageError 'a sed address must be followed by a command.' }

    $command = [string]$Script[$Index.Value]
    $Index.Value++
    $program = [ordered]@{
        AddressStart = $firstAddress
        AddressEnd = $secondAddress
        Command = $command
        Regex = $null
        Replacement = ''
        Global = $false
        PrintOnSubstitution = $false
        RangeActive = $false
    }

    if ($command -ceq 's') {
        if ($Index.Value -ge $Script.Length) { Throw-PshTextUsageError 'sed substitution requires a delimiter.' }
        $delimiter = $Script[$Index.Value]
        if ([char]::IsLetterOrDigit($delimiter) -or [char]::IsWhiteSpace($delimiter) -or $delimiter -eq '\') {
            Throw-PshTextUsageError 'sed substitution uses an invalid delimiter.'
        }
        $Index.Value++
        $pattern = Read-PshSedDelimitedText -Script $Script -Index $Index -Delimiter $delimiter -Context 'substitution pattern'
        $replacement = Read-PshSedDelimitedText -Script $Script -Index $Index -Delimiter $delimiter -Context 'substitution replacement'
        if ([string]::IsNullOrEmpty($pattern)) { Throw-PshTextUsageError 'empty sed substitution patterns are unsupported.' }
        try {
            $program['Regex'] = New-PshSearchRegex -Pattern $pattern -Basic:(-not $Extended)
        }
        catch { Throw-PshTextUsageError $_.Exception.Message }
        $groupNumbers = [int[]]$program['Regex'].GetGroupNumbers()
        for ($replacementIndex = 0; $replacementIndex -lt $replacement.Length; $replacementIndex++) {
            if ($replacement[$replacementIndex] -ne '\' -or ($replacementIndex + 1) -ge $replacement.Length) { continue }
            $replacementIndex++
            $escapedReplacement = $replacement[$replacementIndex]
            if ([char]::IsDigit($escapedReplacement)) {
                $groupNumber = [int]([string]$escapedReplacement)
                if ($groupNumbers -notcontains $groupNumber) {
                    Throw-PshTextUsageError ('sed replacement references missing capture group \{0}.' -f $groupNumber)
                }
            }
        }
        $program['Replacement'] = $replacement
        while ($Index.Value -lt $Script.Length -and $Script[$Index.Value] -ne ';' -and -not [char]::IsWhiteSpace($Script[$Index.Value])) {
            $flag = [string]$Script[$Index.Value]
            $Index.Value++
            if ($flag -ceq 'g' -and -not [bool]$program['Global']) { $program['Global'] = $true }
            elseif ($flag -ceq 'p' -and -not [bool]$program['PrintOnSubstitution']) { $program['PrintOnSubstitution'] = $true }
            else { Throw-PshTextUsageError ('unsupported sed substitution flag "{0}".' -f $flag) }
        }
    }
    elseif ($command -notin @('d', 'p', 'q')) {
        Throw-PshTextUsageError ('unsupported sed command "{0}".' -f $command)
    }
    return [PSCustomObject]$program
}

function ConvertTo-PshSedPrograms {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Expressions,

        [switch]$Extended
    )

    $programs = @()
    foreach ($expression in $Expressions) {
        if ([string]::IsNullOrWhiteSpace($expression)) { Throw-PshTextUsageError 'sed expressions cannot be empty.' }
        $index = 0
        while ($index -lt $expression.Length) {
            Move-PshTextIndexPastWhitespace -Text $expression -Index ([ref]$index)
            while ($index -lt $expression.Length -and $expression[$index] -eq ';') {
                $index++
                Move-PshTextIndexPastWhitespace -Text $expression -Index ([ref]$index)
            }
            if ($index -ge $expression.Length) { break }
            $programs += Read-PshSedProgram -Script $expression -Index ([ref]$index) -Extended:$Extended
            Move-PshTextIndexPastWhitespace -Text $expression -Index ([ref]$index)
            if ($index -lt $expression.Length) {
                if ($expression[$index] -ne ';') {
                    Throw-PshTextUsageError ('unsupported text after sed command near "{0}".' -f $expression.Substring($index))
                }
                $index++
            }
        }
    }
    if ($programs.Count -eq 0) { Throw-PshTextUsageError 'at least one sed expression is required.' }
    return $programs
}

function Test-PshSedAddressMatch {
    param(
        [AllowNull()]
        [object]$Address,

        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$LineNumber,

        [Parameter(Mandatory = $true)]
        [bool]$IsLast
    )

    if ($null -eq $Address) { return $true }
    if ([string]$Address.Kind -ceq 'Number') { return $LineNumber -eq [int]$Address.Number }
    if ([string]$Address.Kind -ceq 'Last') { return $IsLast }
    return $Address.Regex.IsMatch($Text)
}

function Test-PshSedProgramSelected {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Program,

        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$LineNumber,

        [Parameter(Mandatory = $true)]
        [bool]$IsLast
    )

    if ($null -eq $Program.AddressEnd) {
        return (Test-PshSedAddressMatch -Address $Program.AddressStart -Text $Text -LineNumber $LineNumber -IsLast $IsLast)
    }
    if ($Program.RangeActive) {
        if (Test-PshSedAddressMatch -Address $Program.AddressEnd -Text $Text -LineNumber $LineNumber -IsLast $IsLast) {
            $Program.RangeActive = $false
        }
        return $true
    }
    if (-not (Test-PshSedAddressMatch -Address $Program.AddressStart -Text $Text -LineNumber $LineNumber -IsLast $IsLast)) {
        return $false
    }
    $Program.RangeActive = $true
    $numericEndAlreadyReached = [string]$Program.AddressEnd.Kind -ceq 'Number' -and [int]$Program.AddressEnd.Number -le $LineNumber
    if ($numericEndAlreadyReached) { $Program.RangeActive = $false }
    return $true
}

function Expand-PshSedReplacement {
    param(
        [Parameter(Mandatory = $true)]
        [Text.RegularExpressions.Match]$Match,

        [AllowNull()]
        [string]$Replacement
    )

    if ($null -eq $Replacement) { return '' }
    $builder = New-Object Text.StringBuilder
    for ($index = 0; $index -lt $Replacement.Length; $index++) {
        $character = $Replacement[$index]
        if ($character -eq '&') { [void]$builder.Append($Match.Value); continue }
        if ($character -eq '\' -and ($index + 1) -lt $Replacement.Length) {
            $index++
            $next = $Replacement[$index]
            if ([char]::IsDigit($next)) {
                $groupNumber = [int]([string]$next)
                if ($groupNumber -lt $Match.Groups.Count) { [void]$builder.Append($Match.Groups[$groupNumber].Value) }
            }
            else { [void]$builder.Append($next) }
            continue
        }
        [void]$builder.Append($character)
    }
    return $builder.ToString()
}

function Invoke-PshSedSubstitution {
    param(
        [Parameter(Mandatory = $true)]
        [Text.RegularExpressions.Regex]$Regex,

        [AllowNull()]
        [string]$Text,

        [AllowNull()]
        [string]$Replacement,

        [switch]$Global
    )

    if ($null -eq $Text) { $Text = '' }
    $matchCollection = $Regex.Matches($Text)
    if ($matchCollection.Count -eq 0) {
        return [PSCustomObject]@{ Text = $Text; Matched = $false }
    }

    $replacementCount = if ($Global) { $matchCollection.Count } else { 1 }
    $builder = New-Object Text.StringBuilder
    $sourceIndex = 0
    for ($matchIndex = 0; $matchIndex -lt $replacementCount; $matchIndex++) {
        $match = $matchCollection[$matchIndex]
        if ($match.Index -gt $sourceIndex) {
            [void]$builder.Append($Text.Substring($sourceIndex, $match.Index - $sourceIndex))
        }
        [void]$builder.Append((Expand-PshSedReplacement -Match $match -Replacement $Replacement))
        $sourceIndex = $match.Index + $match.Length
    }
    if ($sourceIndex -lt $Text.Length) { [void]$builder.Append($Text.Substring($sourceIndex)) }
    return [PSCustomObject]@{ Text = $builder.ToString(); Matched = $true }
}

function Invoke-PshSedPrograms {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Programs,

        [AllowNull()]
        [string]$Text,

        [AllowNull()]
        [object[]]$Records,

        [switch]$NoAutoPrint
    )

    foreach ($program in $Programs) { $program.RangeActive = $false }
    [object[]]$lines = @()
    if ($PSBoundParameters.ContainsKey('Records')) {
        $lines = [object[]]@($Records)
    }
    else {
        $lines = [object[]]@(Split-PshTextLines -Text $Text)
    }
    $builder = New-Object Text.StringBuilder
    $quit = $false
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $current = [string]$lines[$lineIndex].Text
        $terminator = [string]$lines[$lineIndex].Terminator
        $deleted = $false
        foreach ($program in $Programs) {
            if (-not (Test-PshSedProgramSelected -Program $program -Text $current -LineNumber ($lineIndex + 1) -IsLast:($lineIndex -eq ($lines.Count - 1)))) {
                continue
            }
            if ([string]$program.Command -ceq 's') {
                $substitution = Invoke-PshSedSubstitution -Regex $program.Regex -Text $current -Replacement ([string]$program.Replacement) -Global:([bool]$program.Global)
                $current = [string]$substitution.Text
                if ([bool]$substitution.Matched -and [bool]$program.PrintOnSubstitution) {
                    [void]$builder.Append($current)
                    [void]$builder.Append($terminator)
                }
            }
            elseif ([string]$program.Command -ceq 'd') {
                $deleted = $true
                break
            }
            elseif ([string]$program.Command -ceq 'p') {
                [void]$builder.Append($current)
                [void]$builder.Append($terminator)
            }
            elseif ([string]$program.Command -ceq 'q') {
                $quit = $true
                break
            }
        }
        if (-not $deleted -and -not $NoAutoPrint) {
            [void]$builder.Append($current)
            [void]$builder.Append($terminator)
        }
        if ($quit) { break }
    }
    return [PSCustomObject]@{ Text = $builder.ToString(); Quit = $quit }
}

function sed {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: sed [-nE] [-e script] [-i] [script] [file ...]'
        return
    }

    try {
        $noAutoPrint = $false
        $inPlace = $false
        $extended = $false
        $expressions = @()
        $positionals = @()
        $parseOptions = $true
        for ($index = 0; $index -lt $arguments.Count; $index++) {
            $argument = $arguments[$index]
            if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
            if ($parseOptions -and $argument -ceq '-n') { $noAutoPrint = $true; continue }
            if ($parseOptions -and $argument -ceq '-E') { $extended = $true; continue }
            if ($parseOptions -and $argument -ceq '-i') { $inPlace = $true; continue }
            if ($parseOptions -and $argument -match '\A-e(.+)\z') { $expressions += $matches[1]; continue }
            if ($parseOptions -and $argument -ceq '-e') {
                if (($index + 1) -ge $arguments.Count) { Throw-PshTextUsageError 'sed -e requires an expression.' }
                $index++
                $expressions += $arguments[$index]
                continue
            }
            if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
                $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('n', 'E'))
                if ($expanded.Count -eq 0) { Throw-PshTextUsageError ('unsupported argument "{0}".' -f $argument) }
                foreach ($item in $expanded) {
                    if ($item -ceq 'n') { $noAutoPrint = $true } else { $extended = $true }
                }
                continue
            }
            $parseOptions = $false
            $positionals += $argument
        }
        if ($expressions.Count -eq 0) {
            if ($positionals.Count -eq 0) { Throw-PshTextUsageError 'a sed expression is required.' }
            $expressions += $positionals[0]
            if ($positionals.Count -gt 1) { $positionals = @($positionals[1..($positionals.Count - 1)]) } else { $positionals = @() }
        }
        $programs = @(ConvertTo-PshSedPrograms -Expressions $expressions -Extended:$extended)

        if ($inPlace) {
            if ($positionals.Count -eq 0 -or @($positionals | Where-Object { $_ -ceq '-' }).Count -gt 0) {
                Throw-PshTextUsageError 'sed -i requires one or more file paths and does not accept standard input.'
            }
            foreach ($operand in $positionals) {
                $source = Read-PshTextFileSource -Operand $operand
                if ($source.IsBinary) { Throw-PshTextUsageError ('sed -i does not accept binary input: {0}.' -f $operand) }
                $result = Invoke-PshSedPrograms -Programs $programs -Text ([string]$source.Text) -NoAutoPrint:$noAutoPrint
                Set-PshTextFileAtomically -Path ([string]$source.Path) -Text ([string]$result.Text) -EncodingName ([string]$source.Encoding)
                if ($result.Quit) { break }
            }
        }
        else {
            $sources = @(Get-PshTextSources -Paths $positionals -PipelineItems $pipelineItems)
            $records = New-Object System.Collections.ArrayList
            for ($sourceIndex = 0; $sourceIndex -lt $sources.Count; $sourceIndex++) {
                $source = $sources[$sourceIndex]
                if ($source.IsBinary) { Throw-PshTextUsageError ('sed does not accept binary input: {0}.' -f [string]$source.DisplayName) }
                $sourceRecords = @(Split-PshTextLines -Text ([string]$source.Text))
                for ($recordIndex = 0; $recordIndex -lt $sourceRecords.Count; $recordIndex++) {
                    $terminator = [string]$sourceRecords[$recordIndex].Terminator
                    if ($sourceIndex -lt ($sources.Count - 1) -and $recordIndex -eq ($sourceRecords.Count - 1) -and $terminator.Length -eq 0) {
                        $terminator = "`n"
                    }
                    [void]$records.Add([PSCustomObject]@{ Text = [string]$sourceRecords[$recordIndex].Text; Terminator = $terminator })
                }
            }
            $result = Invoke-PshSedPrograms -Programs $programs -Records ([object[]]$records.ToArray()) -NoAutoPrint:$noAutoPrint
            Write-PshTextValue -Text ([string]$result.Text)
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'sed' -Code (Get-PshTextErrorCode -ErrorRecord $_) -Message $_.Exception.Message
    }
}

function ConvertTo-PshAwkTokens {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Program
    )

    $tokens = @()
    $index = 0
    while ($index -lt $Program.Length) {
        $character = $Program[$index]
        if ($character -eq "`r" -or $character -eq "`n") {
            if ($tokens.Count -eq 0 -or [string]$tokens[$tokens.Count - 1].Kind -cne ';') {
                $tokens += [PSCustomObject]@{ Kind = ';'; Text = ';'; Value = $null }
            }
            $index++
            continue
        }
        if ([char]::IsWhiteSpace($character)) { $index++; continue }
        if ($character -in @('{', '}', '(', ')', ',', ';')) {
            $tokens += [PSCustomObject]@{ Kind = [string]$character; Text = [string]$character; Value = $null }
            $index++
            continue
        }
        if ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            $index++
            $builder = New-Object Text.StringBuilder
            $closed = $false
            while ($index -lt $Program.Length) {
                $current = $Program[$index]
                $index++
                if ($current -eq $quote) { $closed = $true; break }
                if ($current -eq '\') {
                    if ($index -ge $Program.Length) { Throw-PshTextUsageError 'unterminated escape in awk string literal.' }
                    $escape = $Program[$index]
                    $index++
                    if ($escape -eq 'n') { [void]$builder.Append("`n") }
                    elseif ($escape -eq 'r') { [void]$builder.Append("`r") }
                    elseif ($escape -eq 't') { [void]$builder.Append("`t") }
                    else { [void]$builder.Append($escape) }
                }
                else { [void]$builder.Append($current) }
            }
            if (-not $closed) { Throw-PshTextUsageError 'unterminated awk string literal.' }
            $tokens += [PSCustomObject]@{ Kind = 'String'; Text = $builder.ToString(); Value = $builder.ToString() }
            continue
        }
        if ($character -eq '/') {
            $index++
            $builder = New-Object Text.StringBuilder
            $closed = $false
            while ($index -lt $Program.Length) {
                $current = $Program[$index]
                $index++
                if ($current -eq '/') { $closed = $true; break }
                if ($current -eq '\') {
                    if ($index -ge $Program.Length) { Throw-PshTextUsageError 'unterminated escape in awk regular expression.' }
                    $next = $Program[$index]
                    $index++
                    if ($next -eq '/') { [void]$builder.Append('/') }
                    else { [void]$builder.Append('\'); [void]$builder.Append($next) }
                }
                else { [void]$builder.Append($current) }
            }
            if (-not $closed) { Throw-PshTextUsageError 'unterminated awk regular expression.' }
            try { $regex = New-Object Text.RegularExpressions.Regex($builder.ToString(), [Text.RegularExpressions.RegexOptions]::CultureInvariant) }
            catch { Throw-PshTextUsageError ('invalid awk regular expression: {0}' -f $_.Exception.Message) }
            $tokens += [PSCustomObject]@{ Kind = 'Regex'; Text = $builder.ToString(); Value = $regex }
            continue
        }
        if ($character -eq '$') {
            $index++
            $start = $index
            while ($index -lt $Program.Length -and ([char]::IsLetterOrDigit($Program[$index]) -or $Program[$index] -eq '_')) { $index++ }
            if ($index -eq $start) { Throw-PshTextUsageError 'awk field references require a number or variable name after $.' }
            $tokens += [PSCustomObject]@{ Kind = 'Field'; Text = $Program.Substring($start, $index - $start); Value = $null }
            continue
        }
        if ([char]::IsDigit($character) -or ($character -eq '.' -and ($index + 1) -lt $Program.Length -and [char]::IsDigit($Program[$index + 1]))) {
            $start = $index
            $seenDot = $false
            while ($index -lt $Program.Length) {
                $current = $Program[$index]
                if ([char]::IsDigit($current)) { $index++; continue }
                if ($current -eq '.' -and -not $seenDot) { $seenDot = $true; $index++; continue }
                break
            }
            $text = $Program.Substring($start, $index - $start)
            $number = 0.0
            if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                Throw-PshTextUsageError ('invalid awk number "{0}".' -f $text)
            }
            $tokens += [PSCustomObject]@{ Kind = 'Number'; Text = $text; Value = $number }
            continue
        }
        if ([char]::IsLetter($character) -or $character -eq '_') {
            $start = $index
            $index++
            while ($index -lt $Program.Length -and ([char]::IsLetterOrDigit($Program[$index]) -or $Program[$index] -eq '_')) { $index++ }
            $text = $Program.Substring($start, $index - $start)
            $tokens += [PSCustomObject]@{ Kind = 'Identifier'; Text = $text; Value = $text }
            continue
        }

        $operator = $null
        if (($index + 1) -lt $Program.Length) {
            $pair = $Program.Substring($index, 2)
            if ($pair -in @('==', '!=', '<=', '>=', '!~', '+=', '++')) { $operator = $pair }
        }
        if ($null -ne $operator) {
            $tokens += [PSCustomObject]@{ Kind = 'Operator'; Text = $operator; Value = $operator }
            $index += 2
            continue
        }
        if ($character -in @('=', '<', '>', '~', '+', '-', '*')) {
            $tokens += [PSCustomObject]@{ Kind = 'Operator'; Text = [string]$character; Value = [string]$character }
            $index++
            continue
        }
        Throw-PshTextUsageError ('unsupported awk token near "{0}".' -f $Program.Substring($index))
    }
    $tokens += [PSCustomObject]@{ Kind = 'End'; Text = ''; Value = $null }
    return $tokens
}

function Get-PshAwkToken {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Parser,

        [int]$Offset = 0
    )

    $position = [int]$Parser.Index + $Offset
    if ($position -ge @($Parser.Tokens).Count) { return @($Parser.Tokens)[@($Parser.Tokens).Count - 1] }
    return @($Parser.Tokens)[$position]
}

function Move-PshAwkToken {
    param([Parameter(Mandatory = $true)][object]$Parser)
    $token = Get-PshAwkToken -Parser $Parser
    $Parser.Index = [int]$Parser.Index + 1
    return $token
}

function Test-PshAwkToken {
    param(
        [Parameter(Mandatory = $true)][object]$Parser,
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowNull()][string]$Text
    )
    $token = Get-PshAwkToken -Parser $Parser
    if ([string]$token.Kind -cne $Kind) { return $false }
    if ($PSBoundParameters.ContainsKey('Text') -and [string]$token.Text -cne $Text) { return $false }
    return $true
}

function Assert-PshAwkToken {
    param(
        [Parameter(Mandatory = $true)][object]$Parser,
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $matches = if ($PSBoundParameters.ContainsKey('Text')) {
        Test-PshAwkToken -Parser $Parser -Kind $Kind -Text $Text
    }
    else { Test-PshAwkToken -Parser $Parser -Kind $Kind }
    if (-not $matches) { Throw-PshTextUsageError $Message }
    return (Move-PshAwkToken -Parser $Parser)
}

function Read-PshAwkPrimaryExpression {
    param([Parameter(Mandatory = $true)][object]$Parser)

    $token = Get-PshAwkToken -Parser $Parser
    if ([string]$token.Kind -in @('Number', 'String', 'Regex')) {
        [void](Move-PshAwkToken -Parser $Parser)
        return [PSCustomObject]@{ Type = [string]$token.Kind; Value = $token.Value; Left = $null; Right = $null }
    }
    if ([string]$token.Kind -ceq 'Identifier') {
        [void](Move-PshAwkToken -Parser $Parser)
        return [PSCustomObject]@{ Type = 'Variable'; Value = [string]$token.Text; Left = $null; Right = $null }
    }
    if ([string]$token.Kind -ceq 'Field') {
        [void](Move-PshAwkToken -Parser $Parser)
        return [PSCustomObject]@{ Type = 'Field'; Value = [string]$token.Text; Left = $null; Right = $null }
    }
    if ([string]$token.Kind -ceq '(') {
        [void](Move-PshAwkToken -Parser $Parser)
        $expression = Read-PshAwkExpression -Parser $Parser
        [void](Assert-PshAwkToken -Parser $Parser -Kind ')' -Message 'awk expression is missing a closing parenthesis.')
        return $expression
    }
    if ([string]$token.Kind -ceq 'Operator' -and [string]$token.Text -in @('+', '-')) {
        [void](Move-PshAwkToken -Parser $Parser)
        return [PSCustomObject]@{ Type = 'Unary'; Value = [string]$token.Text; Left = (Read-PshAwkPrimaryExpression -Parser $Parser); Right = $null }
    }
    Throw-PshTextUsageError ('unsupported awk expression near "{0}".' -f [string]$token.Text)
}

function Read-PshAwkMultiplicativeExpression {
    param([Parameter(Mandatory = $true)][object]$Parser)
    $left = Read-PshAwkPrimaryExpression -Parser $Parser
    while (Test-PshAwkToken -Parser $Parser -Kind 'Operator' -Text '*') {
        $operator = [string](Move-PshAwkToken -Parser $Parser).Text
        $right = Read-PshAwkPrimaryExpression -Parser $Parser
        $left = [PSCustomObject]@{ Type = 'Binary'; Value = $operator; Left = $left; Right = $right }
    }
    return $left
}

function Read-PshAwkAdditiveExpression {
    param([Parameter(Mandatory = $true)][object]$Parser)
    $left = Read-PshAwkMultiplicativeExpression -Parser $Parser
    while ((Test-PshAwkToken -Parser $Parser -Kind 'Operator' -Text '+') -or (Test-PshAwkToken -Parser $Parser -Kind 'Operator' -Text '-')) {
        $operator = [string](Move-PshAwkToken -Parser $Parser).Text
        $right = Read-PshAwkMultiplicativeExpression -Parser $Parser
        $left = [PSCustomObject]@{ Type = 'Binary'; Value = $operator; Left = $left; Right = $right }
    }
    return $left
}

function Read-PshAwkExpression {
    param([Parameter(Mandatory = $true)][object]$Parser)
    $left = Read-PshAwkAdditiveExpression -Parser $Parser
    $token = Get-PshAwkToken -Parser $Parser
    if ([string]$token.Kind -ceq 'Operator' -and [string]$token.Text -in @('==', '!=', '<', '<=', '>', '>=', '~', '!~')) {
        [void](Move-PshAwkToken -Parser $Parser)
        $right = Read-PshAwkAdditiveExpression -Parser $Parser
        return [PSCustomObject]@{ Type = 'Binary'; Value = [string]$token.Text; Left = $left; Right = $right }
    }
    return $left
}

function Read-PshAwkStatement {
    param([Parameter(Mandatory = $true)][object]$Parser)

    $token = Get-PshAwkToken -Parser $Parser
    if ([string]$token.Kind -cne 'Identifier') { Throw-PshTextUsageError ('unsupported awk statement near "{0}".' -f [string]$token.Text) }
    $name = [string]$token.Text
    [void](Move-PshAwkToken -Parser $Parser)

    if ($name -cin @('print', 'printf')) {
        $expressions = @()
        if (-not (Test-PshAwkToken -Parser $Parser -Kind ';') -and -not (Test-PshAwkToken -Parser $Parser -Kind '}')) {
            $expressions += Read-PshAwkExpression -Parser $Parser
            while (Test-PshAwkToken -Parser $Parser -Kind ',') {
                [void](Move-PshAwkToken -Parser $Parser)
                $expressions += Read-PshAwkExpression -Parser $Parser
            }
        }
        if ($name -ceq 'printf' -and $expressions.Count -eq 0) { Throw-PshTextUsageError 'awk printf requires a format expression.' }
        return [PSCustomObject]@{ Type = if ($name -ceq 'print') { 'Print' } else { 'Printf' }; Name = ''; Expressions = $expressions; Expression = $null }
    }

    if ($name -in @('BEGIN', 'END')) { Throw-PshTextUsageError ('awk {0} is valid only before an action block.' -f $name) }
    $operator = Assert-PshAwkToken -Parser $Parser -Kind 'Operator' -Message ('awk variable "{0}" must be assigned with =, +=, or ++.' -f $name)
    if ([string]$operator.Text -ceq '++') {
        return [PSCustomObject]@{ Type = 'Increment'; Name = $name; Expressions = @(); Expression = $null }
    }
    if ([string]$operator.Text -notin @('=', '+=')) { Throw-PshTextUsageError ('unsupported awk assignment operator "{0}".' -f [string]$operator.Text) }
    $expression = Read-PshAwkExpression -Parser $Parser
    return [PSCustomObject]@{ Type = if ([string]$operator.Text -ceq '=') { 'Assign' } else { 'AddAssign' }; Name = $name; Expressions = @(); Expression = $expression }
}

function Read-PshAwkActionBlock {
    param([Parameter(Mandatory = $true)][object]$Parser)
    [void](Assert-PshAwkToken -Parser $Parser -Kind '{' -Message 'awk action is missing an opening brace.')
    $statements = @()
    while (-not (Test-PshAwkToken -Parser $Parser -Kind '}')) {
        if (Test-PshAwkToken -Parser $Parser -Kind 'End') { Throw-PshTextUsageError 'awk action is missing a closing brace.' }
        if (Test-PshAwkToken -Parser $Parser -Kind ';') { [void](Move-PshAwkToken -Parser $Parser); continue }
        $statements += Read-PshAwkStatement -Parser $Parser
        if (Test-PshAwkToken -Parser $Parser -Kind ';') { [void](Move-PshAwkToken -Parser $Parser) }
        elseif (-not (Test-PshAwkToken -Parser $Parser -Kind '}')) { Throw-PshTextUsageError 'awk statements must be separated by semicolons.' }
    }
    [void](Move-PshAwkToken -Parser $Parser)
    return $statements
}

function ConvertTo-PshAwkProgram {
    param([Parameter(Mandatory = $true)][string]$Program)

    $parser = [PSCustomObject]@{ Tokens = @(ConvertTo-PshAwkTokens -Program $Program); Index = 0 }
    $actions = @()
    while (-not (Test-PshAwkToken -Parser $parser -Kind 'End')) {
        if (Test-PshAwkToken -Parser $parser -Kind ';') { [void](Move-PshAwkToken -Parser $parser); continue }
        $phase = 'Record'
        $pattern = $null
        if ((Test-PshAwkToken -Parser $parser -Kind 'Identifier' -Text 'BEGIN') -or (Test-PshAwkToken -Parser $parser -Kind 'Identifier' -Text 'END')) {
            $phase = [string](Move-PshAwkToken -Parser $parser).Text
        }
        elseif (-not (Test-PshAwkToken -Parser $parser -Kind '{')) {
            $pattern = Read-PshAwkExpression -Parser $parser
        }
        if (-not (Test-PshAwkToken -Parser $parser -Kind '{')) {
            if ($phase -cne 'Record' -or ((-not (Test-PshAwkToken -Parser $parser -Kind ';')) -and (-not (Test-PshAwkToken -Parser $parser -Kind 'End')))) {
                Throw-PshTextUsageError 'awk patterns without action blocks must end at a statement boundary.'
            }
            $actions += [PSCustomObject]@{
                Phase = 'Record'
                Pattern = $pattern
                Statements = @([PSCustomObject]@{ Type = 'Print'; Name = ''; Expressions = @(); Expression = $null })
            }
            if (Test-PshAwkToken -Parser $parser -Kind ';') { [void](Move-PshAwkToken -Parser $parser) }
            continue
        }
        $statements = @(Read-PshAwkActionBlock -Parser $parser)
        $actions += [PSCustomObject]@{ Phase = $phase; Pattern = $pattern; Statements = $statements }
    }
    if ($actions.Count -eq 0) { Throw-PshTextUsageError 'an awk program must contain at least one action.' }
    return $actions
}

function ConvertTo-PshAwkNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 0.0 }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [double]$Value
    }
    $number = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
    return 0.0
}

function Test-PshAwkNumericValue {
    param([AllowNull()][object]$Value)
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $true }
    $number = 0.0
    return [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
}

function ConvertTo-PshAwkText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $(if ([bool]$Value) { '1' } else { '0' }) }
    if ($Value -is [double]) { return ([double]$Value).ToString('0.###############', [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function Test-PshAwkTruth {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if (Test-PshAwkNumericValue -Value $Value) { return (ConvertTo-PshAwkNumber -Value $Value) -ne 0 }
    return -not [string]::IsNullOrEmpty([string]$Value)
}

function Get-PshAwkVariableValue {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Name -ceq 'NR') { return [double]$Context.NR }
    if ($Name -ceq 'NF') { return [double]$Context.NF }
    if ($Name -ceq 'FS') { return [string]$Context.FS }
    if ($Name -ceq 'OFS') { return [string]$Context.OFS }
    if ($Name -ceq 'ORS') { return [string]$Context.ORS }
    if ($Context.Variables.ContainsKey($Name)) { return $Context.Variables[$Name] }
    return 0.0
}

function Get-PshAwkExpressionValue {
    param(
        [Parameter(Mandatory = $true)][object]$Expression,
        [Parameter(Mandatory = $true)][object]$Context
    )

    switch ([string]$Expression.Type) {
        'Number' { return [double]$Expression.Value }
        'String' { return [string]$Expression.Value }
        'Regex' { return $Expression.Value }
        'Variable' { return (Get-PshAwkVariableValue -Context $Context -Name ([string]$Expression.Value)) }
        'Field' {
            $fieldText = [string]$Expression.Value
            $fieldNumber = 0
            if (-not [int]::TryParse($fieldText, [ref]$fieldNumber)) {
                $fieldNumber = [int](ConvertTo-PshAwkNumber -Value (Get-PshAwkVariableValue -Context $Context -Name $fieldText))
            }
            if ($fieldNumber -eq 0) { return [string]$Context.Record }
            if ($fieldNumber -lt 0 -or $fieldNumber -gt @($Context.Fields).Count) { return '' }
            return [string]@($Context.Fields)[$fieldNumber - 1]
        }
        'Unary' {
            $number = ConvertTo-PshAwkNumber -Value (Get-PshAwkExpressionValue -Expression $Expression.Left -Context $Context)
            if ([string]$Expression.Value -ceq '-') { return -$number }
            return $number
        }
        'Binary' {
            $left = Get-PshAwkExpressionValue -Expression $Expression.Left -Context $Context
            $right = Get-PshAwkExpressionValue -Expression $Expression.Right -Context $Context
            $operator = [string]$Expression.Value
            if ($operator -ceq '+') { return (ConvertTo-PshAwkNumber $left) + (ConvertTo-PshAwkNumber $right) }
            if ($operator -ceq '-') { return (ConvertTo-PshAwkNumber $left) - (ConvertTo-PshAwkNumber $right) }
            if ($operator -ceq '*') { return (ConvertTo-PshAwkNumber $left) * (ConvertTo-PshAwkNumber $right) }
            if ($operator -in @('~', '!~')) {
                $regex = $right
                if ($regex -isnot [Text.RegularExpressions.Regex]) {
                    try { $regex = New-Object Text.RegularExpressions.Regex([string]$right, [Text.RegularExpressions.RegexOptions]::CultureInvariant) }
                    catch { Throw-PshTextUsageError ('invalid awk matching expression: {0}' -f $_.Exception.Message) }
                }
                $matched = $regex.IsMatch([string]$left)
                if ($operator -ceq '!~') { $matched = -not $matched }
                return $matched
            }
            $comparison = 0
            if ((Test-PshAwkNumericValue $left) -and (Test-PshAwkNumericValue $right)) {
                $leftNumber = ConvertTo-PshAwkNumber $left
                $rightNumber = ConvertTo-PshAwkNumber $right
                if ($leftNumber -lt $rightNumber) { $comparison = -1 } elseif ($leftNumber -gt $rightNumber) { $comparison = 1 }
            }
            else { $comparison = [string]::Compare([string]$left, [string]$right, [StringComparison]::Ordinal) }
            if ($operator -ceq '==') { return $comparison -eq 0 }
            if ($operator -ceq '!=') { return $comparison -ne 0 }
            if ($operator -ceq '<') { return $comparison -lt 0 }
            if ($operator -ceq '<=') { return $comparison -le 0 }
            if ($operator -ceq '>') { return $comparison -gt 0 }
            if ($operator -ceq '>=') { return $comparison -ge 0 }
        }
    }
    Throw-PshTextUsageError ('unsupported awk expression type "{0}".' -f [string]$Expression.Type)
}

function Set-PshAwkVariableValue {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )
    if ($Name -ceq 'NR' -or $Name -ceq 'NF') { Throw-PshTextUsageError ('awk variable {0} is read-only.' -f $Name) }
    if ($Name -ceq 'FS') { $Context.FS = [string]$Value; return }
    if ($Name -ceq 'OFS') { $Context.OFS = [string]$Value; return }
    if ($Name -ceq 'ORS') { $Context.ORS = [string]$Value; return }
    $Context.Variables[$Name] = $Value
}

function Invoke-PshAwkStatements {
    param(
        [Parameter(Mandatory = $true)][object[]]$Statements,
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][Text.StringBuilder]$Output
    )
    foreach ($statement in $Statements) {
        if ([string]$statement.Type -ceq 'Print') {
            $values = @()
            if (@($statement.Expressions).Count -eq 0) { $values = @([string]$Context.Record) }
            else {
                foreach ($expression in @($statement.Expressions)) { $values += ConvertTo-PshAwkText (Get-PshAwkExpressionValue -Expression $expression -Context $Context) }
            }
            [void]$Output.Append(($values -join [string]$Context.OFS))
            [void]$Output.Append([string]$Context.ORS)
        }
        elseif ([string]$statement.Type -ceq 'Printf') {
            $values = @()
            foreach ($expression in @($statement.Expressions)) { $values += ConvertTo-PshAwkText (Get-PshAwkExpressionValue -Expression $expression -Context $Context) }
            $format = [string]$values[0]
            $arguments = @()
            if ($values.Count -gt 1) { $arguments = @($values[1..($values.Count - 1)]) }
            $formatted = Format-PshPrintfText -Format $format -Values $arguments
            [void]$Output.Append([string]$formatted.Text)
        }
        elseif ([string]$statement.Type -ceq 'Assign') {
            Set-PshAwkVariableValue -Context $Context -Name ([string]$statement.Name) -Value (Get-PshAwkExpressionValue -Expression $statement.Expression -Context $Context)
        }
        elseif ([string]$statement.Type -ceq 'AddAssign') {
            $value = (ConvertTo-PshAwkNumber (Get-PshAwkVariableValue -Context $Context -Name ([string]$statement.Name))) + (ConvertTo-PshAwkNumber (Get-PshAwkExpressionValue -Expression $statement.Expression -Context $Context))
            Set-PshAwkVariableValue -Context $Context -Name ([string]$statement.Name) -Value $value
        }
        elseif ([string]$statement.Type -ceq 'Increment') {
            $value = (ConvertTo-PshAwkNumber (Get-PshAwkVariableValue -Context $Context -Name ([string]$statement.Name))) + 1
            Set-PshAwkVariableValue -Context $Context -Name ([string]$statement.Name) -Value $value
        }
    }
}

function Set-PshAwkRecordContext {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Record,
        [Parameter(Mandatory = $true)][int]$RecordNumber
    )

    $fields = @()
    if ([string]$Context.FS -ceq ' ') {
        $trimmed = $Record.Trim()
        if ($trimmed.Length -gt 0) { $fields = @([Text.RegularExpressions.Regex]::Split($trimmed, '\s+')) }
    }
    else {
        try { $fields = @([Text.RegularExpressions.Regex]::Split($Record, [string]$Context.FS)) }
        catch { Throw-PshTextUsageError ('invalid awk field separator: {0}' -f $_.Exception.Message) }
    }
    $Context.Record = $Record
    $Context.Fields = $fields
    $Context.NR = $RecordNumber
    $Context.NF = $fields.Count
}

function Invoke-PshAwkProgram {
    param(
        [Parameter(Mandatory = $true)][object[]]$Actions,
        [Parameter(Mandatory = $true)][object[]]$Sources,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Variables,
        [Parameter(Mandatory = $true)][string]$FieldSeparator
    )

    $context = [PSCustomObject]@{
        Variables = $Variables
        FS = $FieldSeparator
        OFS = ' '
        ORS = "`n"
        Record = ''
        Fields = @()
        NR = 0
        NF = 0
    }
    if ($Variables.ContainsKey('FS')) { $context.FS = [string]$Variables['FS'] }
    if ($Variables.ContainsKey('OFS')) { $context.OFS = [string]$Variables['OFS'] }
    if ($Variables.ContainsKey('ORS')) { $context.ORS = [string]$Variables['ORS'] }
    $output = New-Object Text.StringBuilder
    foreach ($action in @($Actions | Where-Object { [string]$_.Phase -ceq 'BEGIN' })) {
        Invoke-PshAwkStatements -Statements @($action.Statements) -Context $context -Output $output
    }
    $recordNumber = 0
    foreach ($source in $Sources) {
        if ($source.IsBinary) { Throw-PshTextUsageError ('awk does not accept binary input: {0}.' -f [string]$source.DisplayName) }
        foreach ($line in @(Split-PshTextLines -Text ([string]$source.Text))) {
            $recordNumber++
            Set-PshAwkRecordContext -Context $context -Record ([string]$line.Text) -RecordNumber $recordNumber
            foreach ($action in @($Actions | Where-Object { [string]$_.Phase -ceq 'Record' })) {
                $selected = $true
                if ($null -ne $action.Pattern) {
                    if ([string]$action.Pattern.Type -ceq 'Regex') { $selected = $action.Pattern.Value.IsMatch([string]$context.Record) }
                    else { $selected = Test-PshAwkTruth (Get-PshAwkExpressionValue -Expression $action.Pattern -Context $context) }
                }
                if ($selected) { Invoke-PshAwkStatements -Statements @($action.Statements) -Context $context -Output $output }
            }
        }
    }
    foreach ($action in @($Actions | Where-Object { [string]$_.Phase -ceq 'END' })) {
        Invoke-PshAwkStatements -Statements @($action.Statements) -Context $context -Output $output
    }
    return $output.ToString()
}

function awk {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: awk [-F separator] [-v name=value] program [file ...]'
        return
    }

    try {
        $fieldSeparator = ' '
        $variables = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        $positionals = @()
        $parseOptions = $true
        for ($index = 0; $index -lt $arguments.Count; $index++) {
            $argument = $arguments[$index]
            if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
            $option = $null
            $value = $null
            if ($parseOptions -and $argument -match '\A-F(.+)\z') { $option = '-F'; $value = $matches[1] }
            elseif ($parseOptions -and $argument -match '\A-v(.+)\z') { $option = '-v'; $value = $matches[1] }
            elseif ($parseOptions -and $argument -in @('-F', '-v')) {
                if (($index + 1) -ge $arguments.Count) { Throw-PshTextUsageError ('awk {0} requires a value.' -f $argument) }
                $option = $argument
                $index++
                $value = $arguments[$index]
            }
            if ($null -ne $option) {
                if ($option -ceq '-F') {
                    if ([string]::IsNullOrEmpty($value)) { Throw-PshTextUsageError 'awk -F requires a nonempty separator.' }
                    try { [void](New-Object Text.RegularExpressions.Regex($value, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) }
                    catch { Throw-PshTextUsageError ('invalid awk field separator: {0}' -f $_.Exception.Message) }
                    $fieldSeparator = $value
                }
                else {
                    if ($value -notmatch '\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z') { Throw-PshTextUsageError 'awk -v requires name=value.' }
                    $variables[$matches[1]] = $matches[2]
                }
                continue
            }
            if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') { Throw-PshTextUsageError ('unsupported argument "{0}".' -f $argument) }
            $parseOptions = $false
            $positionals += $argument
        }
        if ($positionals.Count -eq 0) { Throw-PshTextUsageError 'an awk program is required.' }
        $program = $positionals[0]
        $paths = @()
        if ($positionals.Count -gt 1) { $paths = @($positionals[1..($positionals.Count - 1)]) }
        $actions = @(ConvertTo-PshAwkProgram -Program $program)
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems)
        $output = Invoke-PshAwkProgram -Actions $actions -Sources $sources -Variables $variables -FieldSeparator $fieldSeparator
        Write-PshTextValue -Text $output
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'awk' -Code (Get-PshTextErrorCode -ErrorRecord $_) -Message $_.Exception.Message
    }
}

function New-PshJsonValueEnvelope {
    param([AllowNull()][object]$Value)
    return [PSCustomObject]@{ Value = $Value }
}

function Split-PshJqTopLevel {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][char]$Delimiter
    )

    $parts = @()
    $start = 0
    $parentheses = 0
    $brackets = 0
    $inString = $false
    $escaped = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; continue }
        if ($character -eq '(') { $parentheses++; continue }
        if ($character -eq ')') { $parentheses--; if ($parentheses -lt 0) { Throw-PshTextUsageError 'jq filter has an unmatched closing parenthesis.' }; continue }
        if ($character -eq '[') { $brackets++; continue }
        if ($character -eq ']') { $brackets--; if ($brackets -lt 0) { Throw-PshTextUsageError 'jq filter has an unmatched closing bracket.' }; continue }
        if ($character -eq $Delimiter -and $parentheses -eq 0 -and $brackets -eq 0) {
            $parts += $Text.Substring($start, $index - $start).Trim()
            $start = $index + 1
        }
    }
    if ($inString -or $parentheses -ne 0 -or $brackets -ne 0) { Throw-PshTextUsageError 'jq filter contains an unterminated string or grouping.' }
    $parts += $Text.Substring($start).Trim()
    if (@($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { Throw-PshTextUsageError 'jq pipes cannot contain an empty stage.' }
    return $parts
}

function ConvertTo-PshJqPathComponents {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $Path.StartsWith('.')) { Throw-PshTextUsageError ('jq path must start with a dot: {0}.' -f $Path) }
    $components = @()
    $index = 1
    while ($index -lt $Path.Length) {
        if ($Path[$index] -eq '.') { $index++; if ($index -ge $Path.Length) { Throw-PshTextUsageError 'jq path cannot end with a dot.' } }
        if ($Path[$index] -eq '[') {
            $index++
            if ($index -lt $Path.Length -and $Path[$index] -eq ']') {
                $index++
                $components += [PSCustomObject]@{ Kind = 'Iterate'; Value = $null }
                continue
            }
            if ($index -lt $Path.Length -and $Path[$index] -eq '"') {
                $start = $index
                $index++
                $escaped = $false
                while ($index -lt $Path.Length) {
                    $current = $Path[$index]
                    if ($escaped) { $escaped = $false; $index++; continue }
                    if ($current -eq '\') { $escaped = $true; $index++; continue }
                    if ($current -eq '"') { $index++; break }
                    $index++
                }
                if ($index -gt $Path.Length -or $Path[$index - 1] -ne '"') { Throw-PshTextUsageError 'jq quoted path property is unterminated.' }
                $jsonText = $Path.Substring($start, $index - $start)
                try { $property = $jsonText | ConvertFrom-Json -ErrorAction Stop }
                catch { Throw-PshTextUsageError ('invalid jq quoted property: {0}' -f $_.Exception.Message) }
                if ($index -ge $Path.Length -or $Path[$index] -ne ']') { Throw-PshTextUsageError 'jq quoted path property is missing ].' }
                $index++
                $components += [PSCustomObject]@{ Kind = 'Property'; Value = [string]$property }
                continue
            }
            $start = $index
            if ($index -lt $Path.Length -and $Path[$index] -eq '-') { $index++ }
            while ($index -lt $Path.Length -and [char]::IsDigit($Path[$index])) { $index++ }
            if ($index -eq $start -or ($Path[$start] -eq '-' -and $index -eq ($start + 1))) { Throw-PshTextUsageError 'jq array index must be an integer.' }
            $number = 0
            if (-not [int]::TryParse($Path.Substring($start, $index - $start), [ref]$number)) { Throw-PshTextUsageError 'jq array index is out of range.' }
            if ($index -ge $Path.Length -or $Path[$index] -ne ']') { Throw-PshTextUsageError 'jq array index is missing ].' }
            $index++
            $components += [PSCustomObject]@{ Kind = 'Index'; Value = $number }
            continue
        }

        $start = $index
        while ($index -lt $Path.Length -and ([char]::IsLetterOrDigit($Path[$index]) -or $Path[$index] -in @('_', '-'))) { $index++ }
        if ($index -eq $start) { Throw-PshTextUsageError ('unsupported jq path syntax near "{0}".' -f $Path.Substring($index)) }
        $components += [PSCustomObject]@{ Kind = 'Property'; Value = $Path.Substring($start, $index - $start) }
    }
    return $components
}

function Get-PshJsonObjectProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ref]$Found
    )
    $Found.Value = $false
    if ($null -eq $InputObject) { return (New-PshJsonValueEnvelope -Value $null) }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::Ordinal)) {
                $Found.Value = $true
                return (New-PshJsonValueEnvelope -Value $InputObject[$key])
            }
        }
        return (New-PshJsonValueEnvelope -Value $null)
    }
    if ($InputObject -isnot [PSCustomObject]) {
        $typeName = $InputObject.GetType().Name
        throw ('cannot index JSON {0} with property "{1}".' -f $typeName, $Name)
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]::Equals([string]$property.Name, $Name, [StringComparison]::Ordinal)) {
            $Found.Value = $true
            return (New-PshJsonValueEnvelope -Value $property.Value)
        }
    }
    return (New-PshJsonValueEnvelope -Value $null)
}

function Get-PshJsonSequenceValues {
    param([AllowNull()][object]$Value)

    $values = New-Object System.Collections.ArrayList
    if ($null -eq $Value -or $Value -is [string]) { return $values }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { [void]$values.Add($Value[$key]) }
        return $values
    }
    if ($Value -isnot [ValueType] -and @($Value.PSObject.Properties).Count -gt 0 -and $Value -isnot [System.Collections.IEnumerable]) {
        foreach ($property in $Value.PSObject.Properties) { [void]$values.Add($property.Value) }
        return $values
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { [void]$values.Add($item) }
        return $values
    }
    return $values
}

function Test-PshJsonArrayValue {
    param([AllowNull()][object]$Value)
    return ($null -ne $Value -and $Value -isnot [string] -and
        $Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary])
}

function Test-PshJsonObjectValue {
    param([AllowNull()][object]$Value)
    return ($Value -is [System.Collections.IDictionary] -or $Value -is [PSCustomObject])
}

function Test-PshJsonIterableValue {
    param([AllowNull()][object]$Value)
    return ((Test-PshJsonArrayValue -Value $Value) -or (Test-PshJsonObjectValue -Value $Value))
}

function Invoke-PshJqPath {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Components,
        [AllowNull()][object]$InputValue
    )

    $current = New-Object System.Collections.ArrayList
    [void]$current.Add((New-PshJsonValueEnvelope -Value $InputValue))
    foreach ($component in $Components) {
        $next = New-Object System.Collections.ArrayList
        foreach ($envelope in $current) {
            $value = $envelope.Value
            if ([string]$component.Kind -ceq 'Property') {
                $found = $false
                $propertyValue = Get-PshJsonObjectProperty -InputObject $value -Name ([string]$component.Value) -Found ([ref]$found)
                if ($found) { [void]$next.Add($propertyValue) }
                else { [void]$next.Add((New-PshJsonValueEnvelope -Value $null)) }
            }
            elseif ([string]$component.Kind -ceq 'Index') {
                if (-not (Test-PshJsonArrayValue -Value $value)) {
                    throw 'jq array indexing requires an array input.'
                }
                $sequence = @(Get-PshJsonSequenceValues -Value $value)
                $position = [int]$component.Value
                if ($position -lt 0) { $position = $sequence.Count + $position }
                $indexed = $null
                if ($position -ge 0 -and $position -lt $sequence.Count) { $indexed = $sequence[$position] }
                [void]$next.Add((New-PshJsonValueEnvelope -Value $indexed))
            }
            else {
                if (-not (Test-PshJsonIterableValue -Value $value)) {
                    throw 'jq iteration requires an array or object input.'
                }
                foreach ($item in @(Get-PshJsonSequenceValues -Value $value)) {
                    [void]$next.Add((New-PshJsonValueEnvelope -Value $item))
                }
            }
        }
        $current = $next
    }
    return @($current)
}

function Get-PshJsonKeys {
    param([AllowNull()][object]$Value)

    if ($Value -is [System.Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object) }
    if ($null -ne $Value -and $Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        $sequence = @(Get-PshJsonSequenceValues -Value $Value)
        $indices = @()
        for ($index = 0; $index -lt $sequence.Count; $index++) { $indices += $index }
        return $indices
    }
    if ($null -ne $Value -and $Value -isnot [ValueType] -and $Value -isnot [string]) {
        return @($Value.PSObject.Properties.Name | Sort-Object)
    }
    Throw-PshTextUsageError 'jq keys requires an object or array.'
}

function Get-PshJsonLength {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [string]) { return ([string]$Value).Length }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Count }
    if ($Value -is [System.Collections.IEnumerable]) { return @(Get-PshJsonSequenceValues -Value $Value).Count }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -gt 0 -and $Value -isnot [ValueType]) { return $properties.Count }
    Throw-PshTextUsageError 'jq length does not accept numeric or Boolean input in the documented subset.'
}

function Find-PshJqComparison {
    param([Parameter(Mandatory = $true)][string]$Expression)

    $operators = @('==', '!=', '<=', '>=', '<', '>')
    $inString = $false
    $escaped = $false
    $parentheses = 0
    $brackets = 0
    for ($index = 0; $index -lt $Expression.Length; $index++) {
        $character = $Expression[$index]
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; continue }
        if ($character -eq '(') { $parentheses++; continue }
        if ($character -eq ')') { $parentheses--; continue }
        if ($character -eq '[') { $brackets++; continue }
        if ($character -eq ']') { $brackets--; continue }
        if ($parentheses -ne 0 -or $brackets -ne 0) { continue }
        foreach ($operator in $operators) {
            if (($index + $operator.Length) -le $Expression.Length -and $Expression.Substring($index, $operator.Length) -ceq $operator) {
                return [PSCustomObject]@{ Index = $index; Operator = $operator }
            }
        }
    }
    return $null
}

function ConvertFrom-PshJqLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][ref]$IsLiteral
    )
    $IsLiteral.Value = $false
    $trimmed = $Text.Trim()
    if ($trimmed -match '\A(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?)\z' -or ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"'))) {
        try {
            $value = $trimmed | ConvertFrom-Json -ErrorAction Stop
            $IsLiteral.Value = $true
            return $value
        }
        catch { Throw-PshTextUsageError ('invalid jq literal: {0}' -f $_.Exception.Message) }
    }
    return $null
}

function Compare-PshJqValues {
    param(
        [AllowNull()][object]$Left,
        [AllowNull()][object]$Right,
        [Parameter(Mandatory = $true)][string]$Operator
    )
    $leftKind = if ($null -eq $Left) { 0 } elseif ($Left -is [bool]) { 1 } elseif ($Left -is [byte] -or $Left -is [int16] -or $Left -is [int32] -or $Left -is [int64] -or $Left -is [single] -or $Left -is [double] -or $Left -is [decimal]) { 2 } elseif ($Left -is [string]) { 3 } elseif ($Left -is [System.Collections.IEnumerable] -and $Left -isnot [System.Collections.IDictionary]) { 4 } else { 5 }
    $rightKind = if ($null -eq $Right) { 0 } elseif ($Right -is [bool]) { 1 } elseif ($Right -is [byte] -or $Right -is [int16] -or $Right -is [int32] -or $Right -is [int64] -or $Right -is [single] -or $Right -is [double] -or $Right -is [decimal]) { 2 } elseif ($Right -is [string]) { 3 } elseif ($Right -is [System.Collections.IEnumerable] -and $Right -isnot [System.Collections.IDictionary]) { 4 } else { 5 }
    $comparison = 0
    if ($leftKind -ne $rightKind) {
        $comparison = if ($leftKind -lt $rightKind) { -1 } else { 1 }
    }
    elseif ($leftKind -eq 0) { $comparison = 0 }
    elseif ($leftKind -eq 1) {
        if ([bool]$Left -ne [bool]$Right) { $comparison = if ([bool]$Left) { 1 } else { -1 } }
    }
    elseif ($leftKind -eq 2) {
        $leftNumber = [double]$Left
        $rightNumber = [double]$Right
        if ($leftNumber -lt $rightNumber) { $comparison = -1 } elseif ($leftNumber -gt $rightNumber) { $comparison = 1 }
    }
    elseif ($leftKind -eq 3) { $comparison = [string]::Compare([string]$Left, [string]$Right, [StringComparison]::Ordinal) }
    elseif ($leftKind -eq 4) {
        $leftItems = @(Get-PshJsonSequenceValues -Value $Left)
        $rightItems = @(Get-PshJsonSequenceValues -Value $Right)
        $sharedCount = [Math]::Min($leftItems.Count, $rightItems.Count)
        for ($index = 0; $index -lt $sharedCount; $index++) {
            if (Compare-PshJqValues -Left $leftItems[$index] -Right $rightItems[$index] -Operator '<') { $comparison = -1; break }
            if (Compare-PshJqValues -Left $leftItems[$index] -Right $rightItems[$index] -Operator '>') { $comparison = 1; break }
        }
        if ($comparison -eq 0 -and $leftItems.Count -ne $rightItems.Count) { $comparison = if ($leftItems.Count -lt $rightItems.Count) { -1 } else { 1 } }
    }
    else {
        $leftKeys = [string[]]@(Get-PshJsonKeys -Value $Left)
        $rightKeys = [string[]]@(Get-PshJsonKeys -Value $Right)
        [Array]::Sort($leftKeys, [StringComparer]::Ordinal)
        [Array]::Sort($rightKeys, [StringComparer]::Ordinal)
        $sharedCount = [Math]::Min($leftKeys.Count, $rightKeys.Count)
        for ($index = 0; $index -lt $sharedCount; $index++) {
            $keyComparison = [string]::Compare($leftKeys[$index], $rightKeys[$index], [StringComparison]::Ordinal)
            if ($keyComparison -lt 0) { $comparison = -1; break }
            if ($keyComparison -gt 0) { $comparison = 1; break }
        }
        if ($comparison -eq 0 -and $leftKeys.Count -ne $rightKeys.Count) {
            $comparison = if ($leftKeys.Count -lt $rightKeys.Count) { -1 } else { 1 }
        }
        if ($comparison -eq 0) {
            for ($index = 0; $index -lt $leftKeys.Count; $index++) {
                $leftFound = $false
                $rightFound = $false
                $leftValue = Get-PshJsonObjectProperty -InputObject $Left -Name $leftKeys[$index] -Found ([ref]$leftFound)
                $rightValue = Get-PshJsonObjectProperty -InputObject $Right -Name $rightKeys[$index] -Found ([ref]$rightFound)
                if (Compare-PshJqValues -Left $leftValue.Value -Right $rightValue.Value -Operator '<') { $comparison = -1; break }
                if (Compare-PshJqValues -Left $leftValue.Value -Right $rightValue.Value -Operator '>') { $comparison = 1; break }
            }
        }
    }
    if ($Operator -ceq '==') { return $comparison -eq 0 }
    if ($Operator -ceq '!=') { return $comparison -ne 0 }
    if ($Operator -ceq '<') { return $comparison -lt 0 }
    if ($Operator -ceq '<=') { return $comparison -le 0 }
    if ($Operator -ceq '>') { return $comparison -gt 0 }
    if ($Operator -ceq '>=') { return $comparison -ge 0 }
    return $false
}

function Test-PshJqTruth {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    return $true
}

function Get-PshJqExpressionValues {
    param(
        [Parameter(Mandatory = $true)][string]$Expression,
        [AllowNull()][object]$InputValue
    )
    $isLiteral = $false
    $literal = ConvertFrom-PshJqLiteral -Text $Expression -IsLiteral ([ref]$isLiteral)
    if ($isLiteral) { return @((New-PshJsonValueEnvelope -Value $literal)) }
    return @(Invoke-PshJqFilterValue -Filter $Expression -InputValue $InputValue)
}

function Test-PshJqCondition {
    param(
        [Parameter(Mandatory = $true)][string]$Condition,
        [AllowNull()][object]$InputValue
    )
    $comparison = Find-PshJqComparison -Expression $Condition
    if ($null -eq $comparison) {
        $values = @(Get-PshJqExpressionValues -Expression $Condition -InputValue $InputValue)
        if ($values.Count -eq 0) { return $false }
        return (Test-PshJqTruth -Value $values[$values.Count - 1].Value)
    }
    $leftText = $Condition.Substring(0, [int]$comparison.Index).Trim()
    $rightStart = [int]$comparison.Index + ([string]$comparison.Operator).Length
    $rightText = $Condition.Substring($rightStart).Trim()
    if ([string]::IsNullOrEmpty($leftText) -or [string]::IsNullOrEmpty($rightText)) { Throw-PshTextUsageError 'jq comparison requires expressions on both sides.' }
    $leftValues = @(Get-PshJqExpressionValues -Expression $leftText -InputValue $InputValue)
    $rightValues = @(Get-PshJqExpressionValues -Expression $rightText -InputValue $InputValue)
    if ($leftValues.Count -eq 0 -or $rightValues.Count -eq 0) { return $false }
    return (Compare-PshJqValues -Left $leftValues[$leftValues.Count - 1].Value -Right $rightValues[$rightValues.Count - 1].Value -Operator ([string]$comparison.Operator))
}

function Invoke-PshJqStage {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [AllowNull()][object]$InputValue
    )
    $trimmed = $Stage.Trim()
    if ($trimmed.StartsWith('.')) {
        return @(Invoke-PshJqPath -Components @(ConvertTo-PshJqPathComponents -Path $trimmed) -InputValue $InputValue)
    }
    if ($trimmed -ceq 'length') { return @((New-PshJsonValueEnvelope -Value (Get-PshJsonLength -Value $InputValue))) }
    if ($trimmed -ceq 'keys') {
        $keys = [object[]](Get-PshJsonKeys -Value $InputValue)
        return @((New-PshJsonValueEnvelope -Value $keys))
    }
    if ($trimmed -match '\Amap\((.*)\)\z') {
        $inner = $matches[1].Trim()
        if ([string]::IsNullOrEmpty($inner)) { Throw-PshTextUsageError 'jq map requires a filter.' }
        if (-not (Test-PshJsonIterableValue -Value $InputValue)) { throw 'jq map requires an array or object input.' }
        $mapped = New-Object System.Collections.ArrayList
        foreach ($item in @(Get-PshJsonSequenceValues -Value $InputValue)) {
            foreach ($result in @(Invoke-PshJqFilterValue -Filter $inner -InputValue $item)) { [void]$mapped.Add($result.Value) }
        }
        return @((New-PshJsonValueEnvelope -Value ([object[]]$mapped.ToArray())))
    }
    if ($trimmed -match '\Aselect\((.*)\)\z') {
        $condition = $matches[1].Trim()
        if ([string]::IsNullOrEmpty($condition)) { Throw-PshTextUsageError 'jq select requires a condition.' }
        if (Test-PshJqCondition -Condition $condition -InputValue $InputValue) { return @((New-PshJsonValueEnvelope -Value $InputValue)) }
        return @()
    }
    $isLiteral = $false
    $literal = ConvertFrom-PshJqLiteral -Text $trimmed -IsLiteral ([ref]$isLiteral)
    if ($isLiteral) { return @((New-PshJsonValueEnvelope -Value $literal)) }
    Throw-PshTextUsageError ('unsupported jq filter stage "{0}".' -f $trimmed)
}

function Invoke-PshJqFilterValue {
    param(
        [Parameter(Mandatory = $true)][string]$Filter,
        [AllowNull()][object]$InputValue
    )
    $current = New-Object System.Collections.ArrayList
    [void]$current.Add((New-PshJsonValueEnvelope -Value $InputValue))
    foreach ($stage in @(Split-PshJqTopLevel -Text $Filter -Delimiter '|')) {
        $next = New-Object System.Collections.ArrayList
        foreach ($envelope in $current) {
            foreach ($result in @(Invoke-PshJqStage -Stage $stage -InputValue $envelope.Value)) { [void]$next.Add($result) }
        }
        $current = $next
    }
    return @($current)
}

function Move-PshJsonPastWhitespace {
    param([Parameter(Mandatory = $true)][object]$Parser)
    while ($Parser.Index -lt $Parser.Text.Length) {
        $codePoint = [int]$Parser.Text[$Parser.Index]
        if ($codePoint -ne 9 -and $codePoint -ne 10 -and $codePoint -ne 13 -and $codePoint -ne 32) { break }
        $Parser.Index++
    }
}

function Read-PshJsonStringValue {
    param([Parameter(Mandatory = $true)][object]$Parser)

    if ($Parser.Index -ge $Parser.Text.Length -or $Parser.Text[$Parser.Index] -ne '"') { throw 'JSON string must start with a quotation mark.' }
    $Parser.Index++
    $builder = New-Object Text.StringBuilder
    while ($Parser.Index -lt $Parser.Text.Length) {
        $character = $Parser.Text[$Parser.Index]
        $Parser.Index++
        if ($character -eq '"') { return $builder.ToString() }
        if ([int]$character -lt 32) { throw 'JSON strings cannot contain unescaped control characters.' }
        if ($character -ne '\') {
            if ([char]::IsHighSurrogate($character)) {
                if ($Parser.Index -ge $Parser.Text.Length -or -not [char]::IsLowSurrogate($Parser.Text[$Parser.Index])) {
                    throw 'JSON strings contain an unpaired high surrogate.'
                }
                [void]$builder.Append($character)
                [void]$builder.Append($Parser.Text[$Parser.Index])
                $Parser.Index++
                continue
            }
            if ([char]::IsLowSurrogate($character)) { throw 'JSON strings contain an unpaired low surrogate.' }
            [void]$builder.Append($character)
            continue
        }
        if ($Parser.Index -ge $Parser.Text.Length) { throw 'JSON string ends with an incomplete escape.' }
        $escape = $Parser.Text[$Parser.Index]
        $Parser.Index++
        if ($escape -eq '"' -or $escape -eq '\' -or $escape -eq '/') { [void]$builder.Append($escape); continue }
        if ($escape -eq 'b') { [void]$builder.Append([char]8); continue }
        if ($escape -eq 'f') { [void]$builder.Append([char]12); continue }
        if ($escape -eq 'n') { [void]$builder.Append([char]10); continue }
        if ($escape -eq 'r') { [void]$builder.Append([char]13); continue }
        if ($escape -eq 't') { [void]$builder.Append([char]9); continue }
        if ($escape -ne 'u' -or ($Parser.Index + 4) -gt $Parser.Text.Length) { throw 'JSON string contains an unsupported escape.' }
        $hex = $Parser.Text.Substring($Parser.Index, 4)
        $Parser.Index += 4
        $codePoint = 0
        if (-not [int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$codePoint)) {
            throw 'JSON string contains an invalid Unicode escape.'
        }
        $unicodeCharacter = [char]$codePoint
        if ([char]::IsHighSurrogate($unicodeCharacter)) {
            if (($Parser.Index + 6) -gt $Parser.Text.Length -or $Parser.Text[$Parser.Index] -ne '\' -or $Parser.Text[$Parser.Index + 1] -ne 'u') {
                throw 'JSON string contains an unpaired high surrogate.'
            }
            $lowHex = $Parser.Text.Substring($Parser.Index + 2, 4)
            $lowCodePoint = 0
            if (-not [int]::TryParse($lowHex, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$lowCodePoint) -or
                -not [char]::IsLowSurrogate([char]$lowCodePoint)) {
                throw 'JSON string contains an invalid low surrogate.'
            }
            $Parser.Index += 6
            [void]$builder.Append($unicodeCharacter)
            [void]$builder.Append([char]$lowCodePoint)
            continue
        }
        if ([char]::IsLowSurrogate($unicodeCharacter)) { throw 'JSON string contains an unpaired low surrogate.' }
        [void]$builder.Append($unicodeCharacter)
    }
    throw 'JSON string is unterminated.'
}

function Read-PshJsonNumberEnvelope {
    param([Parameter(Mandatory = $true)][object]$Parser)

    $remaining = $Parser.Text.Substring($Parser.Index)
    $match = [Text.RegularExpressions.Regex]::Match($remaining, '\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
    if (-not $match.Success) { throw 'JSON contains an invalid number.' }
    $text = $match.Value
    $Parser.Index += $text.Length
    if ($text.IndexOfAny([char[]]@('.', 'e', 'E')) -lt 0) {
        $integer = 0L
        if ([long]::TryParse($text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$integer)) {
            return (New-PshJsonValueEnvelope -Value $integer)
        }
    }

    $exponentIndex = $text.IndexOfAny([char[]]@('e', 'E'))
    $mantissa = if ($exponentIndex -ge 0) { $text.Substring(0, $exponentIndex) } else { $text }
    $hasNonzeroMantissa = $mantissa -match '[1-9]'
    if ($exponentIndex -ge 0) {
        $doubleValue = 0.0
        if ([double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue) -and
            -not [double]::IsInfinity($doubleValue) -and -not [double]::IsNaN($doubleValue)) {
            if ($doubleValue -eq 0.0 -and $hasNonzeroMantissa) { throw 'JSON number underflows the supported finite range.' }
            return (New-PshJsonValueEnvelope -Value $doubleValue)
        }
        throw 'JSON number is outside the supported finite range.'
    }

    $decimalValue = 0D
    if ([decimal]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$decimalValue)) {
        if ($decimalValue -ne 0D -or -not $hasNonzeroMantissa) {
            return (New-PshJsonValueEnvelope -Value $decimalValue)
        }
    }
    $doubleValue = 0.0
    if ([double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue) -and
        -not [double]::IsInfinity($doubleValue) -and -not [double]::IsNaN($doubleValue)) {
        if ($doubleValue -eq 0.0 -and $hasNonzeroMantissa) { throw 'JSON number underflows the supported finite range.' }
        return (New-PshJsonValueEnvelope -Value $doubleValue)
    }
    throw 'JSON number is outside the supported finite range.'
}

function Read-PshJsonArrayEnvelope {
    param([Parameter(Mandatory = $true)][object]$Parser)

    $Parser.Index++
    Move-PshJsonPastWhitespace -Parser $Parser
    $items = New-Object System.Collections.ArrayList
    if ($Parser.Index -lt $Parser.Text.Length -and $Parser.Text[$Parser.Index] -eq ']') {
        $Parser.Index++
        return (New-PshJsonValueEnvelope -Value ([object[]]$items.ToArray()))
    }
    while ($true) {
        $item = Read-PshJsonValueEnvelope -Parser $Parser
        [void]$items.Add($item.Value)
        Move-PshJsonPastWhitespace -Parser $Parser
        if ($Parser.Index -ge $Parser.Text.Length) { throw 'JSON array is unterminated.' }
        $delimiter = $Parser.Text[$Parser.Index]
        $Parser.Index++
        if ($delimiter -eq ']') { break }
        if ($delimiter -ne ',') { throw 'JSON array items must be separated by commas.' }
        Move-PshJsonPastWhitespace -Parser $Parser
    }
    return (New-PshJsonValueEnvelope -Value ([object[]]$items.ToArray()))
}

function Read-PshJsonObjectEnvelope {
    param([Parameter(Mandatory = $true)][object]$Parser)

    $Parser.Index++
    Move-PshJsonPastWhitespace -Parser $Parser
    $values = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $caseInsensitiveNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $hasCaseCollision = $false
    if ($Parser.Index -lt $Parser.Text.Length -and $Parser.Text[$Parser.Index] -eq '}') {
        $Parser.Index++
        return (New-PshJsonValueEnvelope -Value ([PSCustomObject][ordered]@{}))
    }
    while ($true) {
        Move-PshJsonPastWhitespace -Parser $Parser
        $name = Read-PshJsonStringValue -Parser $Parser
        $isDuplicate = $values.ContainsKey($name)
        if (-not $isDuplicate -and -not $caseInsensitiveNames.Add($name)) { $hasCaseCollision = $true }
        Move-PshJsonPastWhitespace -Parser $Parser
        if ($Parser.Index -ge $Parser.Text.Length -or $Parser.Text[$Parser.Index] -ne ':') { throw 'JSON object property is missing a colon.' }
        $Parser.Index++
        Move-PshJsonPastWhitespace -Parser $Parser
        $value = Read-PshJsonValueEnvelope -Parser $Parser
        if ($isDuplicate) { $values[$name] = $value.Value }
        else { $values.Add($name, $value.Value) }
        Move-PshJsonPastWhitespace -Parser $Parser
        if ($Parser.Index -ge $Parser.Text.Length) { throw 'JSON object is unterminated.' }
        $delimiter = $Parser.Text[$Parser.Index]
        $Parser.Index++
        if ($delimiter -eq '}') { break }
        if ($delimiter -ne ',') { throw 'JSON object properties must be separated by commas.' }
    }
    if ($hasCaseCollision) { return (New-PshJsonValueEnvelope -Value $values) }
    $ordered = [ordered]@{}
    foreach ($name in $values.Keys) { $ordered[$name] = $values[$name] }
    return (New-PshJsonValueEnvelope -Value ([PSCustomObject]$ordered))
}

function Read-PshJsonValueEnvelope {
    param([Parameter(Mandatory = $true)][object]$Parser)

    Move-PshJsonPastWhitespace -Parser $Parser
    if ($Parser.Index -ge $Parser.Text.Length) { throw 'JSON input is empty or incomplete.' }
    $character = $Parser.Text[$Parser.Index]
    if ($character -eq '"') { return (New-PshJsonValueEnvelope -Value (Read-PshJsonStringValue -Parser $Parser)) }
    if ($character -eq '{') { return (Read-PshJsonObjectEnvelope -Parser $Parser) }
    if ($character -eq '[') { return (Read-PshJsonArrayEnvelope -Parser $Parser) }
    if ($character -eq '-' -or [char]::IsDigit($character)) { return (Read-PshJsonNumberEnvelope -Parser $Parser) }
    foreach ($literal in @(
        [PSCustomObject]@{ Text = 'true'; Value = $true },
        [PSCustomObject]@{ Text = 'false'; Value = $false },
        [PSCustomObject]@{ Text = 'null'; Value = $null }
    )) {
        if (($Parser.Index + $literal.Text.Length) -le $Parser.Text.Length -and
            [string]::Equals($Parser.Text.Substring($Parser.Index, $literal.Text.Length), $literal.Text, [StringComparison]::Ordinal)) {
            $Parser.Index += $literal.Text.Length
            return (New-PshJsonValueEnvelope -Value $literal.Value)
        }
    }
    throw ('JSON contains an unexpected token near "{0}".' -f $Parser.Text.Substring($Parser.Index, [Math]::Min(16, $Parser.Text.Length - $Parser.Index)))
}

function ConvertFrom-PshJsonTextEnvelope {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $parser = [PSCustomObject]@{ Text = $Text; Index = 0 }
    $value = Read-PshJsonValueEnvelope -Parser $parser
    Move-PshJsonPastWhitespace -Parser $parser
    if ($parser.Index -ne $parser.Text.Length) { throw 'JSON input contains trailing content.' }
    return $value
}

function ConvertFrom-PshJsonTextStream {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $parser = [PSCustomObject]@{ Text = $Text; Index = 0 }
    $values = New-Object System.Collections.ArrayList
    Move-PshJsonPastWhitespace -Parser $parser
    while ($parser.Index -lt $parser.Text.Length) {
        $value = Read-PshJsonValueEnvelope -Parser $parser
        [void]$values.Add($value)
        $valueEnd = $parser.Index
        Move-PshJsonPastWhitespace -Parser $parser
        if ($parser.Index -lt $parser.Text.Length -and $parser.Index -eq $valueEnd) {
            throw 'top-level JSON values must be separated by JSON whitespace.'
        }
    }
    return [object[]]$values.ToArray()
}

function ConvertFrom-PshJsonSource {
    param([Parameter(Mandatory = $true)][object]$Source)

    if ($Source.IsBinary) { Throw-PshTextUsageError ('jq does not accept binary input: {0}.' -f [string]$Source.DisplayName) }
    $text = [string]$Source.Text
    try {
        return @(ConvertFrom-PshJsonTextStream -Text $text)
    }
    catch { throw ('invalid JSON input: {0}' -f $_.Exception.Message) }
}

function ConvertTo-PshJqJsonText {
    param(
        [AllowNull()][object]$Value,
        [switch]$Raw,
        [switch]$Compact
    )
    if ($Raw -and $Value -is [string]) { return [string]$Value }
    if ($Raw -and $null -eq $Value) { return 'null' }
    if ($Raw -and ($Value -is [ValueType])) {
        if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Compact) { return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress) }
    return (ConvertTo-Json -InputObject $Value -Depth 100)
}

function Select-PshJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Filter,

        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject,

        [string[]]$Path = @()
    )
    begin { $items = @() }
    process { $items += ,$InputObject }
    end {
        $documents = @()
        if (@($Path).Count -gt 0) {
            foreach ($source in @(Get-PshTextSources -Paths $Path -PipelineItems @())) { $documents += ConvertFrom-PshJsonSource -Source $source }
        }
        else {
            foreach ($item in $items) {
                if ($item -is [string] -or $item -is [byte[]]) {
                    $source = New-PshPipelineTextSource -Items ([object[]](,$item))
                    $documents += ConvertFrom-PshJsonSource -Source $source
                }
                else { $documents += New-PshJsonValueEnvelope -Value $item }
            }
        }
        foreach ($document in $documents) {
            foreach ($result in @(Invoke-PshJqFilterValue -Filter $Filter -InputValue $document.Value)) {
                if ($result.Value -is [Array]) { Microsoft.PowerShell.Utility\Write-Output (, $result.Value) }
                else { Microsoft.PowerShell.Utility\Write-Output $result.Value }
            }
        }
    }
}

function jq {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if ((Resolve-PshEdition) -eq 'Full') {
        Invoke-PshPinnedTextTool -Name 'jq' -Arguments $arguments -PipelineItems $pipelineItems -PipelineExpected:([bool]$MyInvocation.ExpectingInput)
        return
    }
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: jq [-rce] filter [file ...]'
        return
    }

    try {
        $raw = $false
        $compact = $false
        $exitStatus = $false
        $positionals = @()
        $parseOptions = $true
        foreach ($argument in $arguments) {
            if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
            if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
                $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('r', 'c', 'e'))
                if ($expanded.Count -eq 0) { Throw-PshTextUsageError ('unsupported argument "{0}".' -f $argument) }
                foreach ($item in $expanded) {
                    if ($item -ceq 'r') { $raw = $true }
                    elseif ($item -ceq 'c') { $compact = $true }
                    else { $exitStatus = $true }
                }
                continue
            }
            $parseOptions = $false
            $positionals += $argument
        }
        if ($positionals.Count -eq 0) { Throw-PshTextUsageError 'a jq filter is required.' }
        $filter = $positionals[0]
        $paths = @()
        if ($positionals.Count -gt 1) { $paths = @($positionals[1..($positionals.Count - 1)]) }
        $sources = @(Get-PshTextSources -Paths $paths -PipelineItems $pipelineItems)
        $results = @()
        foreach ($source in $sources) {
            foreach ($document in @(ConvertFrom-PshJsonSource -Source $source)) {
                $results += Invoke-PshJqFilterValue -Filter $filter -InputValue $document.Value
            }
        }
        foreach ($result in $results) {
            Write-PshTextValue -Text (ConvertTo-PshJqJsonText -Value $result.Value -Raw:$raw -Compact:$compact) -EmitEmpty
        }
        if ($exitStatus -and ($results.Count -eq 0 -or -not (Test-PshJqTruth -Value $results[$results.Count - 1].Value))) {
            Set-PshLastExitCode -Code 1
        }
        else { Set-PshLastExitCode -Code 0 }
    }
    catch {
        $code = Get-PshTextErrorCode -ErrorRecord $_
        if ($code -eq 3 -and $_.Exception.Message -match '\Ainvalid JSON input') { $code = 3 }
        Write-PshCommandFailure -Command 'jq' -Code $code -Message $_.Exception.Message
    }
}

function ConvertFrom-PshXArgsWhitespaceText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) { return @() }
    $items = New-Object System.Collections.ArrayList
    $builder = New-Object Text.StringBuilder
    $quote = [char]0
    $escaped = $false
    $started = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($character -eq $quote) { $quote = [char]0 }
            else { [void]$builder.Append($character) }
            $started = $true
            continue
        }
        if ($escaped) {
            [void]$builder.Append($character)
            $escaped = $false
            $started = $true
            continue
        }
        if ($character -eq '\') {
            $escaped = $true
            $started = $true
            continue
        }
        if ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            $started = $true
            continue
        }
        if ([char]::IsWhiteSpace($character)) {
            if ($started) {
                [void]$items.Add($builder.ToString())
                [void]$builder.Clear()
                $started = $false
            }
            continue
        }
        [void]$builder.Append($character)
        $started = $true
    }
    if ($escaped) { Throw-PshTextUsageError 'xargs input ends with an incomplete backslash escape.' }
    if ($quote -ne [char]0) { Throw-PshTextUsageError 'xargs input contains an unterminated quoted item.' }
    if ($started) { [void]$items.Add($builder.ToString()) }
    return [object[]]$items.ToArray()
}

function ConvertFrom-PshXArgsNullText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $parts = $Text.Split([char[]]@([char]0), [StringSplitOptions]::None)
    $count = $parts.Count
    if ($Text[$Text.Length - 1] -eq [char]0) { $count-- }
    $items = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $count; $index++) { [void]$items.Add([string]$parts[$index]) }
    return [object[]]$items.ToArray()
}

function ConvertFrom-PshXArgsLogicalLines {
    param(
        [AllowNull()]
        [string]$Text
    )

    $items = New-Object System.Collections.ArrayList
    foreach ($line in @(Split-PshTextLines -Text $Text)) {
        $value = ([string]$line.Text).Trim()
        if ($value.Length -gt 0) { [void]$items.Add($value) }
    }
    return [object[]]$items.ToArray()
}

function New-PshXArgsException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][ValidateSet(2, 3, 4, 5)][int]$Code
    )

    $exception = New-Object InvalidOperationException($Message)
    $exception.Data['PshExitCode'] = $Code
    return $exception
}

function Resolve-PshXArgsCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) { throw (New-PshXArgsException -Message 'xargs requires a nonempty command name.' -Code 2) }
    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Command)) {
        throw (New-PshXArgsException -Message ('wildcard command names are unsupported: {0}' -f $Command) -Code 2)
    }
    $module = $ExecutionContext.SessionState.Module
    $moduleName = if ($null -ne $module) { [string]$module.Name } else { 'Psh' }
    $moduleRoot = if ($null -ne $module) { [string]$module.ModuleBase } else { Split-Path -Path $PSScriptRoot -Parent }
    $moduleManifest = Join-Path -Path $moduleRoot -ChildPath 'Psh.psd1'

    $resolved = $null
    if ([string]::Equals($Command, 'echo', [StringComparison]::Ordinal)) {
        $resolved = Get-Command -Name ('{0}\echo' -f $moduleName) -CommandType Function -ErrorAction SilentlyContinue
    }
    if ($null -eq $resolved) {
        try { $resolved = Get-Command -Name $Command -ErrorAction Stop | Select-Object -First 1 }
        catch { throw (New-PshXArgsException -Message ('command not found: {0}' -f $Command) -Code 4) }
    }
    if ($null -eq $resolved) { throw (New-PshXArgsException -Message ('command not found: {0}' -f $Command) -Code 4) }

    $commandType = [string]$resolved.CommandType
    if ($commandType -ceq 'Alias') {
        throw (New-PshXArgsException -Message ('aliases cannot be projected into xargs worker runspaces: {0}' -f $Command) -Code 2)
    }
    if ($commandType -in @('Function', 'Filter')) {
        if (-not ([string]::Equals([string]$resolved.Source, $moduleName, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals([string]$resolved.ModuleName, $moduleName, [StringComparison]::OrdinalIgnoreCase))) {
            throw (New-PshXArgsException -Message ('caller-local functions cannot be projected into xargs worker runspaces: {0}' -f $Command) -Code 2)
        }
        return [PSCustomObject]@{
            DisplayName = $Command
            Target = ('{0}\{1}' -f $moduleName, [string]$resolved.Name)
            Kind = 'PshFunction'
            ModuleManifest = $moduleManifest
        }
    }
    if ($commandType -ceq 'Application' -or $commandType -ceq 'ExternalScript') {
        $target = [string]$resolved.Path
        if ([string]::IsNullOrWhiteSpace($target)) { $target = [string]$resolved.Source }
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw (New-PshXArgsException -Message ('cannot resolve command path: {0}' -f $Command) -Code 4)
        }
        return [PSCustomObject]@{ DisplayName = $Command; Target = $target; Kind = 'External'; ModuleManifest = $moduleManifest }
    }
    if ($commandType -ceq 'Cmdlet') {
        return [PSCustomObject]@{ DisplayName = $Command; Target = [string]$resolved.Name; Kind = 'Cmdlet'; ModuleManifest = $moduleManifest }
    }
    throw (New-PshXArgsException -Message ('unsupported xargs command type {0}: {1}' -f $commandType, $Command) -Code 2)
}

function New-PshXArgsInvocationPlans {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [AllowNull()][AllowEmptyCollection()][string[]]$Items = @(),
        [int]$MaxArguments = 0,
        [AllowNull()][string]$ReplaceString,
        [bool]$HasReplaceString = $false
    )

    $plans = New-Object System.Collections.ArrayList
    $itemCount = if ($null -eq $Items) { 0 } else { $Items.Count }
    if ($itemCount -eq 0) { return @() }
    if ($HasReplaceString) {
        foreach ($item in $Items) {
            $invocationArguments = New-Object System.Collections.ArrayList
            foreach ($argument in $ArgumentList) {
                [void]$invocationArguments.Add(([string]$argument).Replace($ReplaceString, [string]$item))
            }
            [void]$plans.Add([PSCustomObject]@{
                Index = $plans.Count
                Command = $Command
                Arguments = [object[]]$invocationArguments.ToArray()
            })
        }
        return [object[]]$plans.ToArray()
    }

    $batchSize = if ($MaxArguments -gt 0) { $MaxArguments } else { $itemCount }
    for ($start = 0; $start -lt $itemCount; $start += $batchSize) {
        $invocationArguments = New-Object System.Collections.ArrayList
        foreach ($argument in @($ArgumentList)) { [void]$invocationArguments.Add([string]$argument) }
        $end = [Math]::Min($start + $batchSize, $itemCount)
        for ($index = $start; $index -lt $end; $index++) { [void]$invocationArguments.Add([string]$Items[$index]) }
        [void]$plans.Add([PSCustomObject]@{
            Index = $plans.Count
            Command = $Command
            Arguments = [object[]]$invocationArguments.ToArray()
        })
    }
    return [object[]]$plans.ToArray()
}

function ConvertTo-PshXArgsAggregateExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    $aggregate = 0
    foreach ($row in $Rows) {
        $childCode = [int]$row.ExitCode
        $normalized = if ($childCode -eq 0) { 0 } elseif ($childCode -eq 5) { 5 } elseif ($childCode -eq 4) { 4 } else { 3 }
        if ($normalized -gt $aggregate) { $aggregate = $normalized }
    }
    return $aggregate
}

function Invoke-PshXArgsInvocationPlans {
    param(
        [Parameter(Mandatory = $true)][object]$ResolvedCommand,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Plans,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$MaxParallelism,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if ($null -eq $Plans -or $Plans.Count -eq 0) { return @() }
    $workerScript = {
        param($Target, $InvocationArguments, $Kind, $ModuleManifest, $WorkingDirectory)
        Set-StrictMode -Version 2.0
        $ErrorActionPreference = 'Stop'
        $captured = New-Object System.Collections.ArrayList
        $rawOutput = [byte[]]@()
        $rawStream = $null
        $pshModule = $null
        try {
            Set-Location -LiteralPath $WorkingDirectory -ErrorAction Stop
            $commandTarget = $Target
            if ([string]$Kind -ceq 'External') {
                $moduleName = [IO.Path]::GetFileNameWithoutExtension($ModuleManifest)
                $importedModules = @(Import-Module -Name $ModuleManifest -Force -PassThru -ErrorAction Stop)
                $pshModule = @($importedModules | Where-Object { [string]::Equals([string]$_.Name, $moduleName, [StringComparison]::OrdinalIgnoreCase) })[-1]
                $processResult = & $pshModule {
                    param($ProcessPath, $ProcessArguments, $ProcessWorkingDirectory)
                    Invoke-PshCapturedProcess -FilePath ([string]$ProcessPath) -Arguments ([string[]]$ProcessArguments) -StandardInputBytes ([byte[]]@()) -RedirectStandardInput:$true -WorkingDirectory ([string]$ProcessWorkingDirectory)
                } $Target ([string[]]$InvocationArguments) $WorkingDirectory
                foreach ($value in @($processResult.StdOut)) { [void]$captured.Add([string]$value) }
                foreach ($value in @($processResult.StdErr)) { [void]$captured.Add([string]$value) }
                return [PSCustomObject]@{ Output = [object[]]$captured.ToArray(); RawOutput = [byte[]]@(); ExitCode = [int]$processResult.ExitCode; ErrorMessage = '' }
            }
            if ([string]$Kind -ceq 'PshFunction') {
                $moduleName = [IO.Path]::GetFileNameWithoutExtension($ModuleManifest)
                $importedModules = @(Import-Module -Name $ModuleManifest -Force -PassThru -ErrorAction Stop)
                $pshModule = @($importedModules | Where-Object { [string]::Equals([string]$_.Name, $moduleName, [StringComparison]::OrdinalIgnoreCase) })[-1]
                $commandTarget = Get-Command -Name $Target -CommandType Function -ErrorAction Stop
                $rawStream = New-Object IO.MemoryStream
                & $pshModule { param($Sink) $script:PshRawByteSink = $Sink } $rawStream
            }
            elseif ([string]$Kind -ceq 'Cmdlet') {
                $commandTarget = Get-Command -Name $Target -CommandType Cmdlet -ErrorAction Stop
            }
            $global:LASTEXITCODE = 0
            try { $values = @(& $commandTarget @InvocationArguments 2>&1) }
            finally {
                if ($null -ne $rawStream) {
                    & $pshModule { $script:PshRawByteSink = $null }
                    $rawOutput = [byte[]]$rawStream.ToArray()
                }
            }
            foreach ($value in $values) { [void]$captured.Add([string]$value) }
            $exitCode = if ([string]$Kind -ceq 'PshFunction') { [int]$global:LASTEXITCODE } else { 0 }
            [PSCustomObject]@{ Output = [object[]]$captured.ToArray(); RawOutput = $rawOutput; ExitCode = $exitCode; ErrorMessage = '' }
        }
        catch {
            if ($null -ne $pshModule -and $null -ne $rawStream) {
                try { & $pshModule { $script:PshRawByteSink = $null } } catch {}
                try { $rawOutput = [byte[]]$rawStream.ToArray() } catch {}
            }
            [void]$captured.Add([string]$_.Exception.Message)
            [PSCustomObject]@{ Output = [object[]]$captured.ToArray(); RawOutput = $rawOutput; ExitCode = 3; ErrorMessage = [string]$_.Exception.Message }
        }
        finally { if ($null -ne $rawStream) { $rawStream.Dispose() } }
    }

    $pool = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($MaxParallelism, $Plans.Count))
    $activeTasks = New-Object System.Collections.ArrayList
    try {
        $pool.Open()
        $rows = New-Object object[] $Plans.Count
        $nextPlanIndex = 0
        while ($nextPlanIndex -lt $Plans.Count -or $activeTasks.Count -gt 0) {
            while ($nextPlanIndex -lt $Plans.Count -and $activeTasks.Count -lt $MaxParallelism) {
                $plan = $Plans[$nextPlanIndex]
                $powershell = $null
                $asyncResult = $null
                try {
                    $powershell = [Management.Automation.PowerShell]::Create()
                    $powershell.RunspacePool = $pool
                    [void]$powershell.AddScript($workerScript.ToString()).AddArgument([string]$ResolvedCommand.Target).AddArgument([string[]]$plan.Arguments).AddArgument([string]$ResolvedCommand.Kind).AddArgument([string]$ResolvedCommand.ModuleManifest).AddArgument($WorkingDirectory)
                    $asyncResult = $powershell.BeginInvoke()
                    [void]$activeTasks.Add([PSCustomObject]@{ Plan = $plan; PowerShell = $powershell; AsyncResult = $asyncResult })
                    $nextPlanIndex++
                }
                catch {
                    if ($null -ne $powershell) {
                        if ($null -ne $asyncResult) {
                            try { if (-not $asyncResult.IsCompleted) { $powershell.Stop() } } catch {}
                            try { [void]$powershell.EndInvoke($asyncResult) } catch {}
                        }
                        $powershell.Dispose()
                    }
                    throw
                }
            }

            $task = $null
            while ($null -eq $task) {
                foreach ($candidate in $activeTasks) {
                    if ($candidate.AsyncResult.IsCompleted) { $task = $candidate; break }
                }
                if ($null -eq $task) { [Threading.Thread]::Sleep(10) }
            }

            try {
                $workerResults = @($task.PowerShell.EndInvoke($task.AsyncResult))
                if ($workerResults.Count -eq 0) { throw 'xargs worker returned no invocation result.' }
                $workerResult = $workerResults[$workerResults.Count - 1]
                $output = @($workerResult.Output | ForEach-Object { [string]$_ })
                $rawOutput = if ($null -eq $workerResult.RawOutput) { [byte[]]@() } else { [byte[]]$workerResult.RawOutput }
                $rows[[int]$task.Plan.Index] = [PSCustomObject]@{
                    Index = [int]$task.Plan.Index
                    Command = [string]$task.Plan.Command
                    Arguments = [object[]]@($task.Plan.Arguments)
                    Output = [object[]]$output
                    RawOutput = $rawOutput
                    ExitCode = [int]$workerResult.ExitCode
                }
            }
            catch {
                $message = [string]$_.Exception.Message
                $rows[[int]$task.Plan.Index] = [PSCustomObject]@{
                    Index = [int]$task.Plan.Index
                    Command = [string]$task.Plan.Command
                    Arguments = [object[]]@($task.Plan.Arguments)
                    Output = [object[]]@($message)
                    RawOutput = [byte[]]@()
                    ExitCode = 3
                }
            }
            finally {
                try { $task.PowerShell.Dispose() } catch {}
                [void]$activeTasks.Remove($task)
            }
        }
        return [object[]]$rows
    }
    finally {
        foreach ($task in @($activeTasks)) {
            if ($null -ne $task.PowerShell) {
                try { if (-not $task.AsyncResult.IsCompleted) { $task.PowerShell.Stop() } } catch {}
                try { [void]$task.PowerShell.EndInvoke($task.AsyncResult) } catch {}
                try { $task.PowerShell.Dispose() } catch {}
            }
        }
        if ($null -ne $pool) {
            try { $pool.Close() } catch {}
            finally { try { $pool.Dispose() } catch {} }
        }
    }
}

function Invoke-PshXArgsCore {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [AllowNull()][object[]]$InputItems,
        [ValidateRange(0, 2147483647)][int]$MaxArguments = 0,
        [ValidateRange(1, 2147483647)][int]$MaxParallelism = 1,
        [switch]$NullDelimited,
        [AllowNull()][string]$ReplaceString,
        [bool]$HasReplaceString = $false
    )

    $location = Get-Location
    if ($null -eq $location.Provider -or -not [string]::Equals([string]$location.Provider.Name, 'FileSystem', [StringComparison]::OrdinalIgnoreCase)) {
        Throw-PshTextUsageError 'xargs requires a FileSystem current location for worker projection.'
    }
    $workingDirectory = [string]$location.ProviderPath
    $source = New-PshPipelineTextSource -Items $InputItems
    if ($NullDelimited -or $source.HasRawByteInput) {
        try { $inputText = ConvertFrom-PshStrictUtf8Bytes -Bytes ([byte[]]$source.Bytes) }
        catch { Throw-PshTextUsageError ('xargs input is not valid UTF-8: {0}' -f $_.Exception.Message) }
    }
    else { $inputText = [string]$source.Text }
    $items = if ($HasReplaceString) {
        if ($NullDelimited) { @(ConvertFrom-PshXArgsNullText -Text $inputText) }
        else { @(ConvertFrom-PshXArgsLogicalLines -Text $inputText) }
    }
    elseif ($NullDelimited) {
        @(ConvertFrom-PshXArgsNullText -Text $inputText)
    }
    else {
        @(ConvertFrom-PshXArgsWhitespaceText -Text $inputText)
    }
    if ($null -eq $items -or @($items).Count -eq 0) { return @() }
    $resolved = Resolve-PshXArgsCommand -Command $Command
    $plans = @(New-PshXArgsInvocationPlans -Command $Command -ArgumentList $ArgumentList -Items $items -MaxArguments $MaxArguments -ReplaceString $ReplaceString -HasReplaceString:$HasReplaceString)
    return @(Invoke-PshXArgsInvocationPlans -ResolvedCommand $resolved -Plans $plans -MaxParallelism $MaxParallelism -WorkingDirectory $workingDirectory)
}

function Invoke-PshXArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Command,

        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject,

        [ValidateRange(0, 2147483647)]
        [int]$MaxArguments = 0,

        [ValidateRange(1, 2147483647)]
        [int]$MaxParallelism = 1,

        [switch]$NullDelimited,

        [AllowNull()]
        [string]$ReplaceString
    )
    begin { $inputItems = New-Object System.Collections.ArrayList }
    process {
        if ($PSBoundParameters.ContainsKey('InputObject')) { [void]$inputItems.Add($InputObject) }
    }
    end {
        $hasReplaceString = $PSBoundParameters.ContainsKey('ReplaceString')
        $rows = @(Invoke-PshXArgsCore -Command $Command -ArgumentList $ArgumentList -InputItems ([object[]]$inputItems.ToArray()) -MaxArguments $MaxArguments -MaxParallelism $MaxParallelism -NullDelimited:$NullDelimited -ReplaceString $ReplaceString -HasReplaceString:$hasReplaceString)
        Set-PshLastExitCode -Code (ConvertTo-PshXArgsAggregateExitCode -Rows $rows)
        foreach ($row in $rows) { Microsoft.PowerShell.Utility\Write-Output $row }
    }
}

function xargs {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: xargs [-0] [-n count] [-I replacement] [-P count] [command [argument ...]]'
        return
    }

    try {
        $nullDelimited = $false
        $maxArguments = 0
        $maxParallelism = 1
        $replaceString = $null
        $hasReplaceString = $false
        $positionals = @()
        $parseOptions = $true
        for ($index = 0; $index -lt $arguments.Count; $index++) {
            $argument = $arguments[$index]
            if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
            if ($parseOptions -and $argument -ceq '-0') { $nullDelimited = $true; continue }
            $option = $null
            $value = $null
            if ($parseOptions -and $argument -match '\A(-n|-P|-I)(.+)\z') { $option = $matches[1]; $value = $matches[2] }
            elseif ($parseOptions -and $argument -in @('-n', '-P', '-I')) {
                if (($index + 1) -ge $arguments.Count) { Throw-PshTextUsageError ('xargs {0} requires a value.' -f $argument) }
                $option = $argument
                $index++
                $value = $arguments[$index]
            }
            if ($null -ne $option) {
                if ($option -ceq '-I') {
                    if ([string]::IsNullOrEmpty($value)) { Throw-PshTextUsageError 'xargs -I requires a nonempty replacement string.' }
                    $replaceString = $value
                    $hasReplaceString = $true
                }
                else {
                    $number = 0
                    if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1) { Throw-PshTextUsageError ('xargs {0} requires a positive integer.' -f $option) }
                    if ($option -ceq '-n') { $maxArguments = $number } else { $maxParallelism = $number }
                }
                continue
            }
            if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') { Throw-PshTextUsageError ('unsupported argument "{0}".' -f $argument) }
            $parseOptions = $false
            $positionals += $argument
        }

        $command = 'Psh\echo'
        $commandArguments = @()
        if ($positionals.Count -gt 0) {
            $command = $positionals[0]
            if ($positionals.Count -gt 1) { $commandArguments = @($positionals[1..($positionals.Count - 1)]) }
        }
        $rows = @(Invoke-PshXArgsCore -Command $command -ArgumentList $commandArguments -InputItems $pipelineItems -MaxArguments $maxArguments -MaxParallelism $maxParallelism -NullDelimited:$nullDelimited -ReplaceString $replaceString -HasReplaceString:$hasReplaceString)
        foreach ($row in $rows) {
            foreach ($value in @($row.Output)) { Microsoft.PowerShell.Utility\Write-Output ([string]$value) }
            if ($null -ne $row.RawOutput -and ([byte[]]$row.RawOutput).Length -gt 0) { Write-PshRawBytes -Bytes ([byte[]]$row.RawOutput) }
        }
        Set-PshLastExitCode -Code (ConvertTo-PshXArgsAggregateExitCode -Rows $rows)
    }
    catch {
        Write-PshCommandFailure -Command 'xargs' -Code (Get-PshTextErrorCode -ErrorRecord $_) -Message $_.Exception.Message
    }
}
