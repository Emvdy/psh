# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# System-command wrappers use $args so native-style switches reach the
# implementation and unsupported syntax can be rejected with exit code 2.

$script:PshSystemCommandNames = @(
    'which',
    'env',
    'printenv',
    'export',
    'test',
    'sleep',
    'date',
    'whoami',
    'hostname',
    'clear'
)

function Get-PshEnabledSystemCommandNames {
    $enabled = @()
    foreach ($name in $script:PshSystemCommandNames) {
        if (-not $script:PshDisabledCommands.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function Test-PshSystemEnvironmentName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    return $Name -match '\A[A-Za-z_][A-Za-z0-9_]*\z'
}

function Test-PshSystemWindowsPlatform {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-PshSystemEnvironmentEntry {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    $comparison = if (Test-PshSystemWindowsPlatform) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in @($environment.Keys)) {
        $keyName = [string]$key
        if ([string]::Equals($keyName, $Name, $comparison)) {
            return [PSCustomObject]@{
                Exists = $true
                Name = $keyName
                Value = [string]$environment[$key]
            }
        }
    }
    return [PSCustomObject]@{ Exists = $false; Name = $Name; Value = '' }
}

function Initialize-PshSystemEnvironmentNativeMethods {
    if (-not (Test-PshSystemWindowsPlatform) -or $null -ne ('PshSystemEnvironmentNativeMethods' -as [type])) { return }

    $source = @'
using System;
using System.Runtime.InteropServices;

public static class PshSystemEnvironmentNativeMethods
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetEnvironmentVariable(string name, string value);
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
}

function Set-PshSystemEnvironmentVariableValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ((Test-PshSystemWindowsPlatform) -and $Value.Length -eq 0) {
        Initialize-PshSystemEnvironmentNativeMethods
        if (-not [PshSystemEnvironmentNativeMethods]::SetEnvironmentVariable($Name, $Value)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object ComponentModel.Win32Exception($errorCode))
        }
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    }

    $state = Get-PshSystemEnvironmentEntry -Name $Name
    if (-not $state.Exists -or -not [string]::Equals([string]$state.Value, $Value, [StringComparison]::Ordinal)) {
        throw ('failed to set process environment variable {0}.' -f $Name)
    }
}

function Remove-PshSystemEnvironmentVariableValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    Microsoft.PowerShell.Management\Remove-Item -LiteralPath ('Env:\{0}' -f $Name) -Force -ErrorAction SilentlyContinue
    $state = Get-PshSystemEnvironmentEntry -Name $Name
    if ($state.Exists) {
        if (Test-PshSystemWindowsPlatform) {
            Initialize-PshSystemEnvironmentNativeMethods
            if (-not [PshSystemEnvironmentNativeMethods]::SetEnvironmentVariable($Name, $null)) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw (New-Object ComponentModel.Win32Exception($errorCode))
            }
        }
        else {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath ('Env:\{0}' -f $Name) -Force -ErrorAction SilentlyContinue
        }
    }

    if ((Get-PshSystemEnvironmentEntry -Name $Name).Exists) {
        throw ('failed to remove process environment variable {0}.' -f $Name)
    }
}

function Get-PshSystemEnvironmentLines {
    $environment = [Environment]::GetEnvironmentVariables('Process')
    $names = @()
    foreach ($key in $environment.Keys) { $names += [string]$key }
    [string[]]$sortedNames = @($names)
    [Array]::Sort($sortedNames, [StringComparer]::Ordinal)

    $lines = @()
    foreach ($name in $sortedNames) {
        $lines += ('{0}={1}' -f $name, [string]$environment[$name])
    }
    return $lines
}

function Get-PshSystemAssignedEnvironmentLines {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Names
    )

    $comparison = if (Test-PshSystemWindowsPlatform) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $orderedNames = @()
    foreach ($name in $Names) {
        $alreadyOrdered = $false
        foreach ($orderedName in $orderedNames) {
            if ([string]::Equals([string]$orderedName, [string]$name, $comparison)) {
                $alreadyOrdered = $true
                break
            }
        }
        if (-not $alreadyOrdered) { $orderedNames += [string]$name }
    }

    $lines = @()
    foreach ($name in $orderedNames) {
        $state = Get-PshSystemEnvironmentEntry -Name ([string]$name)
        if ($state.Exists) { $lines += ('{0}={1}' -f [string]$name, [string]$state.Value) }
    }
    return $lines
}

function Write-PshSystemNullTerminatedValues {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    if ($Values.Count -eq 0) { return }
    $text = New-Object Text.StringBuilder
    foreach ($value in $Values) {
        [void]$text.Append($value)
        [void]$text.Append([char]0)
    }
    $bytes = [byte[]](ConvertTo-PshUtf8Bytes -Text $text.ToString())
    Write-PshRawBytes -Bytes $bytes
}

function Get-PshWhichDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.CommandInfo]$Command
    )

    if ($Command.CommandType -in @(
            [System.Management.Automation.CommandTypes]::Application,
            [System.Management.Automation.CommandTypes]::ExternalScript
        )) {
        return [string]$Command.Path
    }
    if ($Command.CommandType -eq [System.Management.Automation.CommandTypes]::Alias) {
        return [string]$Command.Definition
    }
    return [string]$Command.Name
}

function Test-PshSystemFileCondition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operator,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $false }
        switch ($Operator) {
            '-e' { return $true }
            '-f' { return (-not [bool]$item.PSIsContainer) }
            '-d' { return ([bool]$item.PSIsContainer) }
            '-s' {
                if ($item.PSIsContainer) { return $false }
                $lengthProperty = $item.PSObject.Properties['Length']
                return ($null -ne $lengthProperty -and [long]$lengthProperty.Value -gt 0)
            }
            '-L' {
                $attributesProperty = $item.PSObject.Properties['Attributes']
                return ($null -ne $attributesProperty -and (($attributesProperty.Value -band [IO.FileAttributes]::ReparsePoint) -ne 0))
            }
            '-r' {
                if ($item.PSIsContainer) { return $true }
                $stream = $null
                try {
                    $stream = [IO.File]::Open([string]$item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    return $true
                }
                catch { return $false }
                finally { if ($null -ne $stream) { $stream.Dispose() } }
            }
            '-w' {
                $attributesProperty = $item.PSObject.Properties['Attributes']
                if ($null -ne $attributesProperty -and (($attributesProperty.Value -band [IO.FileAttributes]::ReadOnly) -ne 0)) { return $false }
                return $true
            }
            '-x' {
                if ($item.PSIsContainer) { return $true }
                if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
                    $extension = [IO.Path]::GetExtension([string]$item.Name)
                    $pathext = if ([string]::IsNullOrWhiteSpace($env:PATHEXT)) { '.COM;.EXE;.BAT;.CMD' } else { $env:PATHEXT }
                    return @($pathext -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ieq $extension }).Count -gt 0
                }
                $unixMode = $item.PSObject.Properties['UnixMode']
                if ($null -ne $unixMode) { return (([int]$unixMode.Value -band 73) -ne 0) }
                return ([string]$item.Mode -match 'x')
            }
        }
    }
    catch { return $false }
    return $false
}

function which {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) {
        Write-PshCommandHelp -Usage 'Usage: which [-a] name [...]'
        return
    }

    $all = $false
    $names = @()
    $parseOptions = $true
    foreach ($argument in $argsList) {
        if ($parseOptions -and $argument -ceq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-a') {
            $all = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'which' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
            return
        }
        $parseOptions = $false
        $names += $argument
    }
    if ($names.Count -eq 0) {
        Write-PshCommandFailure -Command 'which' -Code 2 -Message 'at least one command name is required.'
        return
    }

    $missing = $false
    foreach ($name in $names) {
        try {
            $commands = @(Get-Command -Name $name -All -ErrorAction SilentlyContinue)
        }
        catch {
            Write-PshCommandFailure -Command 'which' -Code 3 -Message $_.Exception.Message
            return
        }
        if ($commands.Count -eq 0) {
            $missing = $true
            continue
        }
        if (-not $all) { $commands = @($commands[0]) }
        $written = @()
        foreach ($command in $commands) {
            $text = Get-PshWhichDisplayText -Command $command
            if ([string]::IsNullOrWhiteSpace($text) -or $written -ccontains $text) { continue }
            Microsoft.PowerShell.Utility\Write-Output ([string]$text)
            $written += $text
        }
    }
    Set-PshLastExitCode -Code $(if ($missing) { 1 } else { 0 })
}

function env {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) {
        Write-PshCommandHelp -Usage 'Usage: env [-i] [-u NAME] [-0] [NAME=VALUE ...] [COMMAND [ARG ...]]'
        return
    }

    $ignoreEnvironment = $false
    $nullOutput = $false
    $unsetNames = @()
    $assignmentNames = @()
    $assignmentValues = @()
    $index = 0
    $parseOptions = $true
    while ($index -lt $argsList.Count) {
        $argument = $argsList[$index]
        if ($parseOptions -and $argument -ceq '--') {
            $parseOptions = $false
            $index++
            break
        }
        if ($parseOptions -and $argument -in @('-i', '--ignore-environment')) {
            $ignoreEnvironment = $true
            $index++
            continue
        }
        if ($parseOptions -and $argument -eq '-0') {
            $nullOutput = $true
            $index++
            continue
        }
        if ($parseOptions -and ($argument -eq '-u' -or $argument -eq '--unset')) {
            $index++
            if ($index -ge $argsList.Count -or -not (Test-PshSystemEnvironmentName -Name $argsList[$index])) {
                Write-PshCommandFailure -Command 'env' -Code 2 -Message '-u requires a valid variable name.'
                return
            }
            $unsetNames += $argsList[$index]
            $index++
            continue
        }
        if ($parseOptions -and $argument.StartsWith('--unset=')) {
            $unsetName = $argument.Substring(8)
            if (-not (Test-PshSystemEnvironmentName -Name $unsetName)) {
                Write-PshCommandFailure -Command 'env' -Code 2 -Message 'invalid variable name for --unset.'
                return
            }
            $unsetNames += $unsetName
            $index++
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'env' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
            return
        }
        break
    }

    while ($index -lt $argsList.Count) {
        $argument = $argsList[$index]
        if ($argument -notmatch '\A([^=]+)=(.*)\z') {
            if ($argument -like '*=*') {
                Write-PshCommandFailure -Command 'env' -Code 2 -Message ('invalid assignment: {0}' -f $argument)
                return
            }
            break
        }
        $assignmentName = [string]$Matches[1]
        $assignmentValue = [string]$Matches[2]
        if (-not (Test-PshSystemEnvironmentName -Name $assignmentName)) {
            break
        }
        $assignmentNames += $assignmentName
        $assignmentValues += $assignmentValue
        $index++
    }

    $commandName = $null
    $commandArgs = @()
    if ($index -lt $argsList.Count) {
        $commandName = [string]$argsList[$index]
        if (($index + 1) -lt $argsList.Count) {
            for ($argumentIndex = $index + 1; $argumentIndex -lt $argsList.Count; $argumentIndex++) {
                $commandArgs += [string]$argsList[$argumentIndex]
            }
        }
    }

    $savedNames = @()
    $savedValues = @()
    $savedExists = @()
    $fullEnvironment = $null
    try {
        if ($ignoreEnvironment) {
            $fullEnvironment = [Environment]::GetEnvironmentVariables('Process')
            if (Test-PshSystemWindowsPlatform) { Initialize-PshSystemEnvironmentNativeMethods }
            foreach ($key in @($fullEnvironment.Keys)) {
                Remove-PshSystemEnvironmentVariableValue -Name ([string]$key)
            }
        }
        else {
            $touchedNames = @($unsetNames + $assignmentNames)
            foreach ($name in $touchedNames) {
                $alreadySaved = $false
                foreach ($savedName in $savedNames) {
                    $comparison = if (Test-PshSystemWindowsPlatform) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
                    if ([string]::Equals([string]$savedName, $name, $comparison)) { $alreadySaved = $true; break }
                }
                if ($alreadySaved) { continue }
                $state = Get-PshSystemEnvironmentEntry -Name $name
                $savedNames += [string]$state.Name
                $savedValues += [string]$state.Value
                $savedExists += [bool]$state.Exists
            }
        }

        foreach ($name in $unsetNames) { Remove-PshSystemEnvironmentVariableValue -Name $name }
        for ($assignmentIndex = 0; $assignmentIndex -lt $assignmentNames.Count; $assignmentIndex++) {
            Set-PshSystemEnvironmentVariableValue -Name $assignmentNames[$assignmentIndex] -Value $assignmentValues[$assignmentIndex]
        }

        if ($null -eq $commandName) {
            $lines = if ($ignoreEnvironment) {
                @(Get-PshSystemAssignedEnvironmentLines -Names ([string[]]$assignmentNames))
            }
            else { @(Get-PshSystemEnvironmentLines) }
            if ($nullOutput) { Write-PshSystemNullTerminatedValues -Values $lines }
            else { foreach ($line in $lines) { Microsoft.PowerShell.Utility\Write-Output ([string]$line) } }
            Set-PshLastExitCode -Code 0
            return
        }

        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            Write-PshCommandFailure -Command 'env' -Code 4 -Message ('command not found: {0}' -f $commandName)
            return
        }
        Set-PshLastExitCode -Code 0
        $commandOutput = @(& $command @commandArgs)
        $invocationSucceeded = [bool]$?
        foreach ($value in $commandOutput) {
            if ($null -ne $value) { Microsoft.PowerShell.Utility\Write-Output ([string]$value) }
        }
        $childCode = [int]$global:LASTEXITCODE
        if (-not $invocationSucceeded -and $childCode -eq 0) { $childCode = 3 }
        if ($childCode -notin @(0, 1, 2, 3, 4, 5)) { $childCode = 3 }
        Set-PshLastExitCode -Code $childCode
    }
    catch {
        Write-PshCommandFailure -Command 'env' -Code 3 -Message $_.Exception.Message
    }
    finally {
        if ($null -ne $fullEnvironment) {
            $currentEnvironment = [Environment]::GetEnvironmentVariables('Process')
            foreach ($key in @($currentEnvironment.Keys)) {
                Remove-PshSystemEnvironmentVariableValue -Name ([string]$key)
            }
            foreach ($key in @($fullEnvironment.Keys)) {
                Set-PshSystemEnvironmentVariableValue -Name ([string]$key) -Value ([string]$fullEnvironment[$key])
            }
        }
        else {
            for ($savedIndex = 0; $savedIndex -lt $savedNames.Count; $savedIndex++) {
                if ($savedExists[$savedIndex]) {
                    Set-PshSystemEnvironmentVariableValue -Name $savedNames[$savedIndex] -Value ([string]$savedValues[$savedIndex])
                }
                else {
                    Remove-PshSystemEnvironmentVariableValue -Name $savedNames[$savedIndex]
                }
            }
        }
    }
}

function printenv {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) {
        Write-PshCommandHelp -Usage 'Usage: printenv [-0|--null] [NAME ...]'
        return
    }

    $nullOutput = $false
    $names = @()
    $parseOptions = $true
    foreach ($argument in $argsList) {
        if ($parseOptions -and $argument -ceq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -in @('-0', '--null')) {
            $nullOutput = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'printenv' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
            return
        }
        $parseOptions = $false
        $names += $argument
    }

    if ($names.Count -eq 0) {
        $lines = @(Get-PshSystemEnvironmentLines)
        if ($nullOutput) { Write-PshSystemNullTerminatedValues -Values $lines }
        else { foreach ($line in $lines) { Microsoft.PowerShell.Utility\Write-Output ([string]$line) } }
        Set-PshLastExitCode -Code 0
        return
    }

    $missing = $false
    $values = @()
    foreach ($name in $names) {
        $state = Get-PshSystemEnvironmentEntry -Name $name
        if (-not $state.Exists) { $missing = $true }
        else { $values += [string]$state.Value }
    }
    if ($nullOutput) { Write-PshSystemNullTerminatedValues -Values $values }
    else { foreach ($value in $values) { Microsoft.PowerShell.Utility\Write-Output ([string]$value) } }
    Set-PshLastExitCode -Code $(if ($missing) { 1 } else { 0 })
}

function export {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) {
        Write-PshCommandHelp -Usage 'Usage: export [-p] [-n] [NAME[=VALUE] ...]'
        return
    }

    $print = $false
    $remove = $false
    $operands = @()
    $parseOptions = $true
    foreach ($argument in $argsList) {
        if ($parseOptions -and $argument -ceq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -eq '-p') { $print = $true; continue }
        if ($parseOptions -and $argument -eq '-n') { $remove = $true; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'export' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
            return
        }
        $parseOptions = $false
        $operands += $argument
    }

    if ($remove -and $operands.Count -eq 0) {
        Write-PshCommandFailure -Command 'export' -Code 2 -Message '-n requires at least one variable name.'
        return
    }

    $operationNames = @()
    $operationValues = @()
    $operationHasValue = @()
    foreach ($argument in $operands) {
        if ($argument -match '\A([^=]+)=(.*)\z') {
            $operationName = [string]$Matches[1]
            $operationValue = [string]$Matches[2]
            if (-not (Test-PshSystemEnvironmentName -Name $operationName)) {
                Write-PshCommandFailure -Command 'export' -Code 2 -Message ("invalid variable name: {0}" -f $operationName)
                return
            }
            $operationNames += $operationName
            $operationValues += $operationValue
            $operationHasValue += $true
        }
        elseif (Test-PshSystemEnvironmentName -Name $argument) {
            $operationNames += $argument
            $operationValues += ''
            $operationHasValue += $false
        }
        else {
            Write-PshCommandFailure -Command 'export' -Code 2 -Message ("invalid variable name: {0}" -f $argument)
            return
        }
    }

    for ($operationIndex = 0; $operationIndex -lt $operationNames.Count; $operationIndex++) {
        $name = $operationNames[$operationIndex]
        if ($remove) {
            Remove-PshSystemEnvironmentVariableValue -Name $name
        }
        elseif ($operationHasValue[$operationIndex] -or -not (Get-PshSystemEnvironmentEntry -Name $name).Exists) {
            Set-PshSystemEnvironmentVariableValue -Name $name -Value $operationValues[$operationIndex]
        }
    }

    if ($print -or $operands.Count -eq 0) {
        foreach ($line in @(Get-PshSystemEnvironmentLines)) {
            Microsoft.PowerShell.Utility\Write-Output ([string]('export {0}' -f $line))
        }
    }
    Set-PshLastExitCode -Code 0
}

function test {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) {
        Write-PshCommandHelp -Usage 'Usage: test EXPRESSION'
        return
    }
    if ($argsList.Count -eq 0) { Set-PshLastExitCode -Code 1; return }

    $negate = $false
    while ($argsList.Count -gt 1 -and $argsList[0] -ceq '!') {
        $negate = -not $negate
        if ($argsList.Count -eq 2) { $argsList = @($argsList[1]) }
        else { $argsList = @($argsList[1..($argsList.Count - 1)]) }
    }
    if ($argsList.Count -gt 0 -and $argsList[0] -ceq '--') {
        if ($argsList.Count -eq 1) { Set-PshLastExitCode -Code 1; return }
        if ($argsList.Count -eq 2) { $argsList = @($argsList[1]) }
        else { $argsList = @($argsList[1..($argsList.Count - 1)]) }
    }

    $result = $false
    if ($argsList.Count -eq 1) {
        $result = -not [string]::IsNullOrEmpty($argsList[0])
    }
    elseif ($argsList.Count -eq 2) {
        $operator = $argsList[0]
        $operand = $argsList[1]
        switch ($operator) {
            '-e' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-f' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-d' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-r' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-w' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-x' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-s' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-L' { $result = Test-PshSystemFileCondition -Operator $operator -Path $operand }
            '-n' { $result = -not [string]::IsNullOrEmpty($operand) }
            '-z' { $result = [string]::IsNullOrEmpty($operand) }
            default { Write-PshCommandFailure -Command 'test' -Code 2 -Message ("unsupported operator: {0}" -f $operator); return }
        }
    }
    elseif ($argsList.Count -eq 3) {
        $left = $argsList[0]; $operator = $argsList[1]; $right = $argsList[2]
        switch ($operator) {
            '=' { $result = $left -ceq $right }
            '==' { $result = $left -ceq $right }
            '!=' { $result = $left -cne $right }
            '<' { $result = [string]::CompareOrdinal($left, $right) -lt 0 }
            '>' { $result = [string]::CompareOrdinal($left, $right) -gt 0 }
            '-eq' { $ln = 0L; $rn = 0L; if (-not [long]::TryParse($left, [ref]$ln) -or -not [long]::TryParse($right, [ref]$rn)) { Write-PshCommandFailure -Command 'test' -Code 2 -Message 'integer expression expected'; return }; $result = $ln -eq $rn }
            '-ne' { $ln = 0L; $rn = 0L; if (-not [long]::TryParse($left, [ref]$ln) -or -not [long]::TryParse($right, [ref]$rn)) { Write-PshCommandFailure -Command 'test' -Code 2 -Message 'integer expression expected'; return }; $result = $ln -ne $rn }
            '-lt' { $ln = 0L; $rn = 0L; if (-not [long]::TryParse($left, [ref]$ln) -or -not [long]::TryParse($right, [ref]$rn)) { Write-PshCommandFailure -Command 'test' -Code 2 -Message 'integer expression expected'; return }; $result = $ln -lt $rn }
            '-le' { $ln = 0L; $rn = 0L; if (-not [long]::TryParse($left, [ref]$ln) -or -not [long]::TryParse($right, [ref]$rn)) { Write-PshCommandFailure -Command 'test' -Code 2 -Message 'integer expression expected'; return }; $result = $ln -le $rn }
            '-gt' { $ln = 0L; $rn = 0L; if (-not [long]::TryParse($left, [ref]$ln) -or -not [long]::TryParse($right, [ref]$rn)) { Write-PshCommandFailure -Command 'test' -Code 2 -Message 'integer expression expected'; return }; $result = $ln -gt $rn }
            '-ge' { $ln = 0L; $rn = 0L; if (-not [long]::TryParse($left, [ref]$ln) -or -not [long]::TryParse($right, [ref]$rn)) { Write-PshCommandFailure -Command 'test' -Code 2 -Message 'integer expression expected'; return }; $result = $ln -ge $rn }
            default { Write-PshCommandFailure -Command 'test' -Code 2 -Message ("unsupported operator: {0}" -f $operator); return }
        }
    }
    else {
        Write-PshCommandFailure -Command 'test' -Code 2 -Message 'unsupported expression'
        return
    }
    if ($negate) { $result = -not $result }
    Set-PshLastExitCode -Code $(if ($result) { 0 } else { 1 })
}

function sleep {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) {
        Write-PshCommandHelp -Usage 'Usage: sleep NUMBER[ms|s|m|h|d]'
        return
    }
    if ($argsList.Count -ne 1 -or $argsList[0] -notmatch '\A([0-9]+(?:\.[0-9]+)?)(ms|s|m|h|d)?\z') {
        Write-PshCommandFailure -Command 'sleep' -Code 2 -Message 'invalid duration'
        return
    }

    $numberText = [string]$Matches[1]
    $unit = [string]$Matches[2]
    if ([string]::IsNullOrEmpty($unit)) { $unit = 's' }
    $number = [decimal]0
    if (-not [decimal]::TryParse(
            $numberText,
            [Globalization.NumberStyles]::AllowDecimalPoint,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )) {
        Write-PshCommandFailure -Command 'sleep' -Code 2 -Message 'invalid duration'
        return
    }

    try {
        $multiplier = switch -CaseSensitive ($unit) {
            'ms' { [decimal]1 }
            's' { [decimal]1000 }
            'm' { [decimal]60000 }
            'h' { [decimal]3600000 }
            'd' { [decimal]86400000 }
        }
        $milliseconds = $number * $multiplier
    }
    catch {
        Write-PshCommandFailure -Command 'sleep' -Code 2 -Message 'duration is too large'
        return
    }
    if ($milliseconds -gt [int]::MaxValue) {
        Write-PshCommandFailure -Command 'sleep' -Code 2 -Message 'duration is too large'
        return
    }

    $roundedMilliseconds = [int][decimal]::Round($milliseconds, 0, [MidpointRounding]::AwayFromZero)
    try {
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $roundedMilliseconds
    }
    catch {
        Write-PshCommandFailure -Command 'sleep' -Code 3 -Message $_.Exception.Message
        return
    }
    Set-PshLastExitCode -Code 0
}

function date {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    if (Test-PshLongHelp -Arguments $argsList) {
        Write-PshCommandHelp -Usage 'Usage: date [-u] [-R|-I[=SPEC]|+FORMAT] [-d STRING|--date=STRING]'
        return
    }
    $utc = $false; $format = $null; $dateValue = Get-Date; $index = 0
    while ($index -lt $argsList.Count) {
        $argument = $argsList[$index]
        if ($argument -eq '-u') { $utc = $true }
        elseif ($argument -eq '-R') { if ($null -ne $format) { Write-PshCommandFailure -Command 'date' -Code 2 -Message 'multiple output formats'; return }; $format = 'R' }
        elseif ($argument -eq '-I' -or $argument -like '-I=*') { if ($null -ne $format) { Write-PshCommandFailure -Command 'date' -Code 2 -Message 'multiple output formats'; return }; $format = $argument }
        elseif ($argument -eq '-d' -or $argument -eq '--date') {
            $index++; if ($index -ge $argsList.Count) { Write-PshCommandFailure -Command 'date' -Code 2 -Message 'missing date value'; return }
            try { $dateValue = [DateTimeOffset]::Parse($argsList[$index], [Globalization.CultureInfo]::InvariantCulture) } catch { Write-PshCommandFailure -Command 'date' -Code 2 -Message 'invalid date'; return }
        }
        elseif ($argument -like '--date=*') {
            try { $dateValue = [DateTimeOffset]::Parse($argument.Substring(7), [Globalization.CultureInfo]::InvariantCulture) } catch { Write-PshCommandFailure -Command 'date' -Code 2 -Message 'invalid date'; return }
        }
        elseif ($argument.StartsWith('+')) { if ($null -ne $format) { Write-PshCommandFailure -Command 'date' -Code 2 -Message 'multiple output formats'; return }; $format = $argument }
        else { Write-PshCommandFailure -Command 'date' -Code 2 -Message ("unsupported argument: {0}" -f $argument); return }
        $index++
    }
    $dto = [DateTimeOffset]$dateValue
    if ($utc) { $dto = $dto.ToUniversalTime() }
    if ($format -eq 'R') {
        $rfcText = $dto.ToString('ddd, dd MMM yyyy HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
        $rfcText = [Text.RegularExpressions.Regex]::Replace($rfcText, '([+-]\d\d):(\d\d)\z', '$1$2')
        Microsoft.PowerShell.Utility\Write-Output ([string]$rfcText)
    }
    elseif ($format -like '-I*') {
        $spec = if ($format -match '^-I=(.+)$') { $matches[1] } else { 'date' }
        $netFormat = switch ($spec) { 'date' { 'yyyy-MM-dd' }; 'hours' { 'yyyy-MM-ddTHHzzz' }; 'minutes' { 'yyyy-MM-ddTHH:mmzzz' }; 'seconds' { 'yyyy-MM-ddTHH:mm:sszzz' }; 'ns' { 'yyyy-MM-ddTHH:mm:ss.fffffffzzz' }; default { $null } }
        if ($null -eq $netFormat) { Write-PshCommandFailure -Command 'date' -Code 2 -Message ("unsupported precision: {0}" -f $spec); return }
        Microsoft.PowerShell.Utility\Write-Output ([string]$dto.ToString($netFormat, [Globalization.CultureInfo]::InvariantCulture))
    }
    elseif ($format -and $format.StartsWith('+')) {
        $formatText = $format.Substring(1)
        $output = New-Object Text.StringBuilder
        for ($formatIndex = 0; $formatIndex -lt $formatText.Length; $formatIndex++) {
            $character = [string]$formatText[$formatIndex]
            if ($character -cne '%') {
                [void]$output.Append($character)
                continue
            }
            $formatIndex++
            if ($formatIndex -ge $formatText.Length) {
                Write-PshCommandFailure -Command 'date' -Code 2 -Message 'incomplete format directive'
                return
            }
            $directive = [string]$formatText[$formatIndex]
            $replacement = switch -CaseSensitive ($directive) {
                '%' { '%' }
                'Y' { $dto.ToString('yyyy', [Globalization.CultureInfo]::InvariantCulture) }
                'm' { $dto.ToString('MM', [Globalization.CultureInfo]::InvariantCulture) }
                'd' { $dto.ToString('dd', [Globalization.CultureInfo]::InvariantCulture) }
                'H' { $dto.ToString('HH', [Globalization.CultureInfo]::InvariantCulture) }
                'M' { $dto.ToString('mm', [Globalization.CultureInfo]::InvariantCulture) }
                'S' { $dto.ToString('ss', [Globalization.CultureInfo]::InvariantCulture) }
                'z' { $dto.ToString('zzz', [Globalization.CultureInfo]::InvariantCulture).Replace(':', '') }
                default { $null }
            }
            if ($null -eq $replacement) {
                Write-PshCommandFailure -Command 'date' -Code 2 -Message ('unsupported format directive "%{0}"' -f $directive)
                return
            }
            [void]$output.Append([string]$replacement)
        }
        Microsoft.PowerShell.Utility\Write-Output ([string]$output.ToString())
    }
    else { Microsoft.PowerShell.Utility\Write-Output ([string]$dto.ToString('ddd MMM dd HH:mm:ss zzz yyyy', [Globalization.CultureInfo]::InvariantCulture)) }
    Set-PshLastExitCode -Code 0
}

function whoami {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    if (Test-PshLongHelp -Arguments $argsList) { Write-PshCommandHelp -Usage 'Usage: whoami'; return }
    if ($argsList.Count -ne 0) { Write-PshCommandFailure -Command 'whoami' -Code 2 -Message 'unsupported argument'; return }
    Microsoft.PowerShell.Utility\Write-Output ([string][Environment]::UserName)
    Set-PshLastExitCode -Code 0
}

function hostname {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) { Write-PshCommandHelp -Usage 'Usage: hostname [-s|-f|-i]'; return }
    if ($argsList.Count -gt 1 -or ($argsList.Count -eq 1 -and $argsList[0] -notin @('-s', '-f', '-i'))) {
        Write-PshCommandFailure -Command 'hostname' -Code 2 -Message 'exactly one of -s, -f, or -i is supported'
        return
    }

    try {
        $hostName = [string][Net.Dns]::GetHostName()
        if ([string]::IsNullOrWhiteSpace($hostName)) { throw 'the host name is unavailable.' }
        if ($argsList.Count -eq 0) {
            Microsoft.PowerShell.Utility\Write-Output $hostName
        }
        elseif ($argsList[0] -ceq '-s') {
            $separatorIndex = $hostName.IndexOf('.')
            $shortName = if ($separatorIndex -gt 0) { $hostName.Substring(0, $separatorIndex) } else { $hostName }
            Microsoft.PowerShell.Utility\Write-Output ([string]$shortName)
        }
        elseif ($argsList[0] -ceq '-f') {
            $fullName = $hostName
            try {
                $resolvedName = [string][Net.Dns]::GetHostEntry($hostName).HostName
                if (-not [string]::IsNullOrWhiteSpace($resolvedName)) { $fullName = $resolvedName }
            }
            catch {
                # DNS suffix/search configuration is optional; the local host
                # name is the conservative cross-platform fallback.
            }
            Microsoft.PowerShell.Utility\Write-Output ([string]$fullName)
        }
        else {
            $addresses = @()
            try {
                foreach ($address in @([Net.Dns]::GetHostAddresses($hostName))) {
                    $text = [string]$address.ToString()
                    if (-not [string]::IsNullOrWhiteSpace($text) -and $addresses -cnotcontains $text) { $addresses += $text }
                }
            }
            catch {
                # A valid local host name is not necessarily registered in DNS.
            }
            if ($addresses.Count -eq 0) {
                foreach ($networkInterface in @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces())) {
                    if ($networkInterface.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
                    foreach ($unicast in @($networkInterface.GetIPProperties().UnicastAddresses)) {
                        $text = [string]$unicast.Address.ToString()
                        if (-not [string]::IsNullOrWhiteSpace($text) -and $addresses -cnotcontains $text) { $addresses += $text }
                    }
                }
            }
            if ($addresses.Count -eq 0) { $addresses += [string][Net.IPAddress]::Loopback.ToString() }
            Microsoft.PowerShell.Utility\Write-Output ([string]($addresses -join ' '))
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'hostname' -Code 3 -Message $_.Exception.Message
    }
}

function clear {
    $argsList = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $argsList) { Write-PshCommandHelp -Usage 'Usage: clear [-x]'; return }
    if ($argsList.Count -gt 1 -or ($argsList.Count -eq 1 -and $argsList[0] -cne '-x')) {
        Write-PshCommandFailure -Command 'clear' -Code 2 -Message 'only -x is supported'
        return
    }
    if ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
        try { [Console]::Clear() }
        catch {
            $escape = [string][char]27
            [Console]::Out.Write($escape + '[2J' + $escape + '[H')
        }
    }
    Set-PshLastExitCode -Code 0
}
