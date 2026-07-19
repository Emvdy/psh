# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# Text-command wrappers use $args so unsupported native-style options can be
# rejected explicitly with Psh's stable usage exit code.

$script:PshTextCommandNames = @(
    'cat', 'bat', 'head', 'tail', 'grep', 'rg', 'cut', 'tr', 'sort', 'uniq',
    'wc', 'tee', 'printf', 'echo', 'base64'
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
        if ($PipelineExpected) {
            & {
                foreach ($item in @($PipelineItems)) { ,$item }
            } | & ([string]$native.Path) @Arguments
        }
        else {
            & ([string]$native.Path) @Arguments
        }
        $nativeExit = [int]$LASTEXITCODE
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
