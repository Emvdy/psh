# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# File-command wrappers intentionally accept their arguments through $args.
# This gives them native-command-like parsing: unsupported switches reach the
# implementation as strings and can be rejected with Psh's stable exit code 2.

function ConvertTo-PshArgumentArray {
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$InputArguments
    )

    $result = @()
    if ($null -ne $InputArguments) {
        foreach ($argument in $InputArguments) {
            if ($null -eq $argument) {
                $result += ''
            }
            else {
                $result += [string]$argument
            }
        }
    }

    return $result
}

function Write-PshCommandFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2, 3, 4, 5)]
        [int]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $kind = 'runtime error'
    switch ($Code) {
        1 { $kind = 'no match' }
        2 { $kind = 'usage error' }
        3 { $kind = 'runtime error' }
        4 { $kind = 'missing dependency' }
        5 { $kind = 'integrity failure' }
    }

    $singleLine = ($Message -replace '[\r\n]+', ' ').Trim()
    Write-Output ('{0}: {1}: {2}' -f $Command, $kind, $singleLine)
    Set-PshLastExitCode -Code $Code
}

function Write-PshCommandHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Usage
    )

    Write-Output $Usage
    Set-PshLastExitCode -Code 0
}

function Test-PshLongHelp {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    return ($Arguments.Count -eq 1 -and [string]::Equals($Arguments[0], '--help', [StringComparison]::Ordinal))
}

function Expand-PshShortOptions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string[]]$Allowed
    )

    if ($Token.Length -lt 2 -or $Token[0] -ne '-' -or $Token.StartsWith('--')) {
        return
    }

    $result = @()
    for ($index = 1; $index -lt $Token.Length; $index++) {
        $option = [string]$Token[$index]
        if ($Allowed -cnotcontains $option) {
            return
        }
        $result += $option
    }

    return $result
}

function Resolve-PshFileSystemPath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,

        [switch]$AllowMissing
    )

    if ([string]::IsNullOrEmpty($Path)) {
        throw 'an empty path is not supported.'
    }

    $provider = $null
    $drive = $null
    try {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $Path,
            [ref]$provider,
            [ref]$drive
        )
    }
    catch {
        throw ('cannot resolve path "{0}": {1}' -f $Path, $_.Exception.Message)
    }

    if ($null -eq $provider -or $provider.Name -ne 'FileSystem') {
        throw ('path "{0}" is not a file-system path.' -f $Path)
    }

    $fullPath = [IO.Path]::GetFullPath([string]$resolved)
    if (-not $AllowMissing -and
        -not [IO.File]::Exists($fullPath) -and
        -not [IO.Directory]::Exists($fullPath)) {
        throw ('path does not exist: {0}' -f $Path)
    }

    return $fullPath
}

function Get-PshLinkTargetText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    $property = $Item.PSObject.Properties['Target']
    if ($null -eq $property) { $property = $Item.PSObject.Properties['LinkTarget'] }
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    $value = $property.Value
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        $value = @($value)[0]
    }
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return $null }
    return [string]$value
}

function ConvertTo-PshRawAbsoluteFileSystemPath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        throw 'an empty path is not supported.'
    }

    $provider = $null
    $drive = $null
    try {
        [void]$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $Path,
            [ref]$provider,
            [ref]$drive
        )
    }
    catch {
        throw ('cannot resolve path "{0}": {1}' -f $Path, $_.Exception.Message)
    }
    if ($null -eq $provider -or $provider.Name -ne 'FileSystem') {
        throw ('path "{0}" is not a file-system path.' -f $Path)
    }

    $rawPath = $Path
    $providerSeparator = $rawPath.IndexOf('::', [StringComparison]::Ordinal)
    if ($providerSeparator -ge 0) {
        $rawPath = $rawPath.Substring($providerSeparator + 2)
    }
    if ($rawPath -eq '~' -or $rawPath.StartsWith('~/') -or $rawPath.StartsWith('~\')) {
        $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($homePath)) { $homePath = $env:HOME }
        if ([string]::IsNullOrWhiteSpace($homePath)) {
            throw 'the home directory is unavailable.'
        }
        $rawPath = $homePath + $rawPath.Substring(1)
    }
    if ([IO.Path]::IsPathRooted($rawPath)) {
        return $rawPath
    }

    $colonIndex = $rawPath.IndexOf(':')
    if ($colonIndex -gt 0) {
        $driveName = $rawPath.Substring(0, $colonIndex)
        $pathDrive = Microsoft.PowerShell.Management\Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        if ($null -ne $pathDrive -and $pathDrive.Provider.Name -eq 'FileSystem') {
            $driveBase = [string]$pathDrive.Root
            $driveTail = $rawPath.Substring($colonIndex + 1)
            if (-not $driveTail.StartsWith('/') -and -not $driveTail.StartsWith('\')) {
                $currentLocationProperty = $pathDrive.PSObject.Properties['CurrentLocation']
                if ($null -ne $currentLocationProperty -and -not [string]::IsNullOrWhiteSpace([string]$currentLocationProperty.Value)) {
                    $driveBase = Join-Path -Path $driveBase -ChildPath ([string]$currentLocationProperty.Value)
                }
            }
            return ($driveBase.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar + $driveTail.TrimStart([char[]]@('\', '/')))
        }
    }

    $location = Get-Location
    if ($null -eq $location.Provider -or $location.Provider.Name -ne 'FileSystem') {
        throw 'the current location is not in the file-system provider.'
    }
    return ([string]$location.ProviderPath).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar + $rawPath
}

function Resolve-PshPhysicalFileSystemPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$AllowMissing,

        [int]$LinkDepth = 0
    )

    if ($LinkDepth -gt 64) {
        throw ('too many symbolic-link levels while resolving: {0}' -f $Path)
    }

    $rawFullPath = ConvertTo-PshRawAbsoluteFileSystemPath -Path $Path
    $root = [IO.Path]::GetPathRoot($rawFullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw ('cannot determine the file-system root for path: {0}' -f $Path)
    }
    $relative = $rawFullPath.Substring($root.Length)
    $components = @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $current = $root
    for ($index = 0; $index -lt $components.Count; $index++) {
        $component = [string]$components[$index]
        if ($component -eq '.') {
            continue
        }
        if ($component -eq '..') {
            $currentRoot = [IO.Path]::GetPathRoot($current)
            if (-not (Test-PshPathEqual -Left $current -Right $currentRoot)) {
                $parent = [IO.Path]::GetDirectoryName($current.TrimEnd([char[]]@('\', '/')))
                if (-not [string]::IsNullOrWhiteSpace($parent)) {
                    $current = $parent
                }
            }
            continue
        }

        $candidate = Join-Path -Path $current -ChildPath $component
        try {
            $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        }
        catch {
            if (-not $AllowMissing) { throw ('path does not exist: {0}' -f $Path) }
            $current = $candidate
            continue
        }

        if ((Get-PshItemTypeName -Item $item) -eq 'link') {
            $targetText = Get-PshLinkTargetText -Item $item
            if ([string]::IsNullOrWhiteSpace($targetText)) {
                throw ('cannot read symbolic-link target: {0}' -f $candidate)
            }
            $nextPath = $targetText
            if (-not [IO.Path]::IsPathRooted($targetText)) {
                $nextPath = $current.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar + $targetText
            }
            for ($remainingIndex = $index + 1; $remainingIndex -lt $components.Count; $remainingIndex++) {
                $nextPath = $nextPath.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar + [string]$components[$remainingIndex]
            }
            return Resolve-PshPhysicalFileSystemPath -Path $nextPath -AllowMissing:$AllowMissing -LinkDepth ($LinkDepth + 1)
        }
        $current = [string]$item.FullName
    }

    return [IO.Path]::GetFullPath($current)
}

function Get-PshPathComparison {
    if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
        return [StringComparison]::OrdinalIgnoreCase
    }

    return [StringComparison]::Ordinal
}

function Test-PshPathEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    $leftValue = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]@('\', '/'))
    $rightValue = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]@('\', '/'))
    if ([string]::IsNullOrEmpty($leftValue)) {
        $leftValue = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Left))
    }
    if ([string]::IsNullOrEmpty($rightValue)) {
        $rightValue = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Right))
    }

    return [string]::Equals($leftValue, $rightValue, (Get-PshPathComparison))
}

function Test-PshPathWithin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Candidate,

        [Parameter(Mandatory = $true)]
        [string]$Parent
    )

    $separator = [IO.Path]::DirectorySeparatorChar
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@('\', '/')) + $separator
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd([char[]]@('\', '/')) + $separator
    return $candidateFull.StartsWith($parentFull, (Get-PshPathComparison))
}

function Test-PshProtectedRemovalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-PshPathEqual -Left $fullPath -Right $root)) {
        return $true
    }

    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($homePath)) {
        $homePath = $env:USERPROFILE
    }
    if ([string]::IsNullOrWhiteSpace($homePath)) {
        $homePath = $env:HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($homePath)) {
        try {
            if (Test-PshPathEqual -Left $fullPath -Right ([IO.Path]::GetFullPath($homePath))) {
                return $true
            }
        }
        catch {
            # An unusable HOME value cannot make arbitrary paths protected.
        }
    }

    return $false
}

function Get-PshRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $baseFull = [IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object Uri($baseFull)
    $targetUri = New-Object Uri([IO.Path]::GetFullPath($TargetPath))
    if ($targetUri.Scheme -ne $baseUri.Scheme) {
        return [IO.Path]::GetFullPath($TargetPath)
    }
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    if ($relativeUri.IsAbsoluteUri) {
        return [IO.Path]::GetFullPath($TargetPath)
    }
    $relative = [Uri]::UnescapeDataString($relativeUri.ToString())

    return $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
}

function Get-PshDisplayPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OriginalPath,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedPath
    )

    if ([IO.Path]::IsPathRooted($OriginalPath)) {
        return $ResolvedPath
    }

    return (Get-PshRelativePath -BasePath (Get-Location).ProviderPath -TargetPath $ResolvedPath)
}

function Get-PshSortedFileSystemEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$IncludeHidden
    )

    $entries = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    $filtered = @()
    foreach ($entry in $entries) {
        if (-not $IncludeHidden -and (Test-PshHiddenItem -Item $entry)) {
            continue
        }
        $filtered += $entry
    }

    return @($filtered | Microsoft.PowerShell.Utility\Sort-Object -Property @{ Expression = { $_.Name }; Ascending = $true })
}

function Test-PshHiddenItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    if ([string]$Item.Name -like '.*') {
        return $true
    }

    try {
        return (([IO.FileAttributes]$Item.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
    }
    catch {
        return $false
    }
}

function Format-PshByteCount {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )

    $units = @('B', 'K', 'M', 'G', 'T', 'P')
    $value = [double]$Bytes
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value = $value / 1024
        $unitIndex++
    }

    if ($unitIndex -eq 0) {
        return ('{0}B' -f $Bytes)
    }
    if ($value -ge 10) {
        return ('{0:0}{1}' -f $value, $units[$unitIndex])
    }
    return ('{0:0.0}{1}' -f $value, $units[$unitIndex])
}

function Get-PshItemTypeName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    try {
        if (([IO.FileAttributes]$Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return 'link'
        }
    }
    catch {
    }

    if ($Item.PSIsContainer) {
        return 'directory'
    }
    return 'file'
}

function ConvertFrom-PshSizeExpression {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Expression
    )

    if ($Expression -notmatch '^(?<sign>[+-]?)(?<number>[0-9]+)(?<unit>[bBkKmMgGtT]?)$') {
        throw ('unsupported size expression "{0}".' -f $Expression)
    }

    $multiplier = [long]1
    switch ($Matches.unit.ToLowerInvariant()) {
        'k' { $multiplier = 1024 }
        'm' { $multiplier = 1024 * 1024 }
        'g' { $multiplier = 1024 * 1024 * 1024 }
        't' { $multiplier = [long]1024 * 1024 * 1024 * 1024 }
    }

    return [PSCustomObject]@{
        Sign = [string]$Matches.sign
        Bytes = [long]$Matches.number * $multiplier
    }
}

function Test-PshSizeMatch {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Length,

        [Parameter(Mandatory = $true)]
        [object]$Constraint
    )

    switch ([string]$Constraint.Sign) {
        '+' { return ($Length -gt [long]$Constraint.Bytes) }
        '-' { return ($Length -lt [long]$Constraint.Bytes) }
        default { return ($Length -eq [long]$Constraint.Bytes) }
    }
}

function ConvertFrom-PshDuration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -notmatch '^(?<number>[0-9]+(?:\.[0-9]+)?)(?<unit>s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|week|weeks)$') {
        throw ('unsupported duration "{0}".' -f $Value)
    }

    $number = [double]::Parse($Matches.number, [Globalization.CultureInfo]::InvariantCulture)
    switch ($Matches.unit.ToLowerInvariant()) {
        { $_ -in @('s', 'sec', 'secs', 'second', 'seconds') } { return [TimeSpan]::FromSeconds($number) }
        { $_ -in @('m', 'min', 'mins', 'minute', 'minutes') } { return [TimeSpan]::FromMinutes($number) }
        { $_ -in @('h', 'hr', 'hrs', 'hour', 'hours') } { return [TimeSpan]::FromHours($number) }
        { $_ -in @('d', 'day', 'days') } { return [TimeSpan]::FromDays($number) }
        { $_ -in @('w', 'week', 'weeks') } { return [TimeSpan]::FromDays($number * 7) }
    }
}

function Get-PshDirectorySize {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $total = [long]0
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($entry in @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            $type = Get-PshItemTypeName -Item $entry
            if ($type -eq 'file') {
                $total += [long]$entry.Length
            }
            elseif ($type -eq 'directory') {
                $pending.Push([string]$entry.FullName)
            }
        }
    }

    return $total
}

$script:PshFileCommandNames = @(
    'pwd', 'cd', 'ls', 'mkdir', 'rmdir', 'cp', 'mv', 'rm', 'touch', 'ln',
    'realpath', 'basename', 'dirname', 'stat', 'file', 'tree', 'find', 'fd',
    'du', 'df', 'mktemp'
)

function Get-PshEnabledFileCommandNames {
    $enabled = @()
    foreach ($name in $script:PshFileCommandNames) {
        if (-not $script:PshDisabledCommands.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function pwd {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: pwd [-L|-P]'
        return
    }

    $physical = $false
    foreach ($argument in $arguments) {
        if ($argument -ceq '-L') {
            $physical = $false
        }
        elseif ($argument -ceq '-P') {
            $physical = $true
        }
        else {
            Write-PshCommandFailure -Command 'pwd' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
            return
        }
    }

    try {
        $location = Get-Location
        if ($null -eq $location.Provider -or $location.Provider.Name -ne 'FileSystem') {
            throw 'the current location is not in the file-system provider.'
        }

        if ($physical) {
            Write-Output (Resolve-PshPhysicalFileSystemPath -Path $location.ProviderPath)
        }
        else {
            Write-Output ([string]$location.ProviderPath)
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'pwd' -Code 3 -Message $_.Exception.Message
    }
}

function cd {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: cd [-L|-P] [directory]'
        return
    }

    $physical = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-L') {
            $physical = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-P') {
            $physical = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'cd' -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
            return
        }
        $paths += $argument
    }

    if ($paths.Count -gt 1) {
        Write-PshCommandFailure -Command 'cd' -Code 2 -Message 'at most one directory is supported.'
        return
    }

    $target = $null
    if ($paths.Count -eq 0) {
        $target = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($target)) {
            $target = $env:HOME
        }
        if ([string]::IsNullOrWhiteSpace($target)) {
            Write-PshCommandFailure -Command 'cd' -Code 3 -Message 'the home directory is unavailable.'
            return
        }
    }
    else {
        $target = $paths[0]
    }

    try {
        if ($target -eq '-') {
            if ([string]::IsNullOrWhiteSpace([string]$script:PshPreviousLocation)) {
                throw 'the previous directory is unavailable.'
            }
            $resolved = Resolve-PshFileSystemPath -Path $script:PshPreviousLocation
        }
        else {
            $resolved = Resolve-PshFileSystemPath -Path $target
        }
        if ($physical) {
            $resolved = Resolve-PshPhysicalFileSystemPath -Path $resolved
        }
        if (-not [IO.Directory]::Exists($resolved)) {
            throw ('not a directory: {0}' -f $target)
        }

        $previous = (Get-Location).ProviderPath
        Microsoft.PowerShell.Management\Set-Location -LiteralPath $resolved -ErrorAction Stop
        $script:PshPreviousLocation = $previous
        if ($target -eq '-') {
            Write-Output ([string](Get-Location).ProviderPath)
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'cd' -Code 3 -Message $_.Exception.Message
    }
}

function Format-PshLsEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item,

        [switch]$Long,

        [switch]$Human,

        [switch]$FullPath
    )

    $name = [string]$Item.Name
    if ($FullPath) {
        $name = [string]$Item.FullName
    }
    if (-not $Long) {
        return $name
    }

    $type = Get-PshItemTypeName -Item $Item
    $prefix = '-'
    if ($type -eq 'directory') {
        $prefix = 'd'
    }
    elseif ($type -eq 'link') {
        $prefix = 'l'
    }
    $length = [long]0
    if ($type -eq 'file') {
        $length = [long]$Item.Length
    }
    $lengthText = [string]$length
    if ($Human) {
        $lengthText = Format-PshByteCount -Bytes $length
    }

    return ("{0}`t{1}`t{2}`t{3}" -f $prefix, $lengthText, $Item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $name)
}

function Write-PshLsDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$IncludeHidden,

        [switch]$Long,

        [switch]$Human,

        [switch]$Recursive,

        [switch]$WriteHeader
    )

    if ($WriteHeader) {
        Write-Output ('{0}:' -f $Path)
    }

    $entries = @(Get-PshSortedFileSystemEntries -Path $Path -IncludeHidden:$IncludeHidden)
    foreach ($entry in $entries) {
        Write-Output (Format-PshLsEntry -Item $entry -Long:$Long -Human:$Human)
    }

    if ($Recursive) {
        foreach ($entry in $entries) {
            if ((Get-PshItemTypeName -Item $entry) -ne 'directory') {
                continue
            }
            Write-Output ''
            Write-PshLsDirectory -Path ([string]$entry.FullName) -IncludeHidden:$IncludeHidden -Long:$Long -Human:$Human -Recursive -WriteHeader
        }
    }
}

function ls {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: ls [-alhR1d] [path ...]'
        return
    }

    $includeHidden = $false
    $long = $false
    $human = $false
    $recursive = $false
    $directoryEntry = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('a', 'l', 'h', 'R', '1', 'd'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'ls' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                switch ($option) {
                    'a' { $includeHidden = $true }
                    'l' { $long = $true }
                    'h' { $human = $true }
                    'R' { $recursive = $true }
                    '1' { }
                    'd' { $directoryEntry = $true }
                }
            }
            continue
        }
        $paths += $argument
    }

    if ($paths.Count -eq 0) {
        $paths = @('.')
    }

    try {
        $resolvedPaths = @()
        foreach ($path in $paths) {
            $resolvedPaths += Resolve-PshFileSystemPath -Path $path
        }

        for ($index = 0; $index -lt $resolvedPaths.Count; $index++) {
            $resolved = $resolvedPaths[$index]
            $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if ($index -gt 0) {
                Write-Output ''
            }
            if ($item.PSIsContainer -and -not $directoryEntry) {
                Write-PshLsDirectory -Path $resolved -IncludeHidden:$includeHidden -Long:$long -Human:$human -Recursive:$recursive -WriteHeader:($resolvedPaths.Count -gt 1 -or $recursive)
            }
            else {
                Write-Output (Format-PshLsEntry -Item $item -Long:$long -Human:$human -FullPath:($paths.Count -gt 1))
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'ls' -Code 3 -Message $_.Exception.Message
    }
}

function mkdir {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: mkdir [-pv] directory ...'
        return
    }

    $parents = $false
    $verbose = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('p', 'v'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'mkdir' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'p') { $parents = $true }
                if ($option -eq 'v') { $verbose = $true }
            }
            continue
        }
        $paths += $argument
    }

    if ($paths.Count -eq 0) {
        Write-PshCommandFailure -Command 'mkdir' -Code 2 -Message 'at least one directory is required.'
        return
    }

    try {
        $plans = @()
        foreach ($path in $paths) {
            $resolved = Resolve-PshFileSystemPath -Path $path -AllowMissing
            $missing = @()
            $cursor = $resolved
            while (-not [IO.Directory]::Exists($cursor) -and -not [IO.File]::Exists($cursor)) {
                $missing = @($cursor) + $missing
                $parent = [IO.Path]::GetDirectoryName($cursor)
                if ([string]::IsNullOrWhiteSpace($parent) -or (Test-PshPathEqual -Left $parent -Right $cursor)) {
                    break
                }
                $cursor = $parent
            }
            if ([IO.File]::Exists($resolved)) {
                throw ('path exists and is not a directory: {0}' -f $path)
            }
            if ([IO.Directory]::Exists($resolved) -and -not $parents) {
                throw ('directory already exists: {0}' -f $path)
            }
            if (-not $parents -and $missing.Count -gt 1) {
                throw ('parent directory does not exist: {0}' -f $path)
            }
            $plans += [PSCustomObject]@{ Original = $path; Resolved = $resolved; Missing = @($missing) }
        }

        foreach ($plan in $plans) {
            foreach ($directory in @($plan.Missing)) {
                [void][IO.Directory]::CreateDirectory([string]$directory)
                if ($verbose) {
                    $display = Get-PshDisplayPath -OriginalPath ([string]$plan.Original) -ResolvedPath ([string]$directory)
                    Write-Output ("mkdir: created directory '{0}'" -f $display)
                }
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'mkdir' -Code 3 -Message $_.Exception.Message
    }
}

function Get-PshRmdirRemovalDepth {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $root = [IO.Path]::GetPathRoot($Path)
    $lexicalPath = $Path
    if (-not [string]::IsNullOrEmpty($root) -and $lexicalPath.StartsWith($root, (Get-PshPathComparison))) {
        $lexicalPath = $lexicalPath.Substring($root.Length)
    }

    $components = @($lexicalPath -split '[\\/]')
    $depth = 0
    for ($index = $components.Count - 1; $index -ge 0; $index--) {
        $component = [string]$components[$index]
        if ([string]::IsNullOrEmpty($component) -or $component -eq '.') {
            continue
        }
        if ($component -eq '..') {
            break
        }
        $depth++
    }

    return [Math]::Max(1, $depth)
}

function rmdir {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: rmdir [-pv] [--ignore-fail-on-non-empty] directory ...'
        return
    }

    $parents = $false
    $verbose = $false
    $ignoreNonEmpty = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '--ignore-fail-on-non-empty') {
            $ignoreNonEmpty = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('p', 'v'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'rmdir' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'p') { $parents = $true }
                if ($option -eq 'v') { $verbose = $true }
            }
            continue
        }
        $paths += $argument
    }

    if ($paths.Count -eq 0) {
        Write-PshCommandFailure -Command 'rmdir' -Code 2 -Message 'at least one directory is required.'
        return
    }

    try {
        $plans = @()
        foreach ($path in $paths) {
            $resolved = Resolve-PshFileSystemPath -Path $path
            if (-not [IO.Directory]::Exists($resolved)) {
                throw ('not a directory: {0}' -f $path)
            }
            if (Test-PshProtectedRemovalPath -Path $resolved) {
                throw ('refusing to remove protected directory: {0}' -f $path)
            }

            $removals = @()
            $removalDepth = 1
            if ($parents) { $removalDepth = Get-PshRmdirRemovalDepth -Path $path }
            $cursor = $resolved
            for ($removalIndex = 0; $removalIndex -lt $removalDepth; $removalIndex++) {
                if (Test-PshProtectedRemovalPath -Path $cursor) {
                    break
                }
                $removals += $cursor
                if ($parents) {
                    $next = [IO.Path]::GetDirectoryName($cursor)
                    if ([string]::IsNullOrWhiteSpace($next) -or (Test-PshPathEqual -Left $next -Right $cursor)) {
                        break
                    }
                    $cursor = $next
                }
                else {
                    break
                }
            }
            $plans += [PSCustomObject]@{ Original = $path; Resolved = $resolved; Removals = @($removals) }
        }

        foreach ($plan in $plans) {
            foreach ($directory in @($plan.Removals)) {
                try {
                    [IO.Directory]::Delete([string]$directory, $false)
                    if ($verbose) {
                        $display = Get-PshDisplayPath -OriginalPath ([string]$plan.Original) -ResolvedPath ([string]$directory)
                        Write-Output ("rmdir: removing directory, '{0}'" -f $display)
                    }
                }
                catch [IO.IOException] {
                    if ($ignoreNonEmpty) {
                        break
                    }
                    throw
                }
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'rmdir' -Code 3 -Message $_.Exception.Message
    }
}

function Copy-PshFileEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$NoClobber,

        [switch]$Update,

        [switch]$Force,

        [switch]$Preserve,

        [switch]$VerboseOutput,

        [Parameter(Mandatory = $true)]
        [string]$SourceDisplay,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDisplay
    )

    if ([IO.Directory]::Exists($Destination)) {
        $Destination = Join-Path -Path $Destination -ChildPath ([IO.Path]::GetFileName($Source))
        $DestinationDisplay = Join-Path -Path $DestinationDisplay -ChildPath ([IO.Path]::GetFileName($Source))
    }

    $destinationExists = [IO.File]::Exists($Destination)
    if ($destinationExists) {
        if ($NoClobber) {
            return
        }
        if ($Update -and [IO.File]::GetLastWriteTimeUtc($Destination) -ge [IO.File]::GetLastWriteTimeUtc($Source)) {
            return
        }
    }

    $parent = [IO.Path]::GetDirectoryName($Destination)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
        throw ('destination parent does not exist: {0}' -f $DestinationDisplay)
    }

    if ($destinationExists -and $Force) {
        $temporaryCopy = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'copy'
        $destinationAttributes = [IO.File]::GetAttributes($Destination)
        try {
            [IO.File]::Copy($Source, $temporaryCopy, $false)
            if (($destinationAttributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                [IO.File]::SetAttributes($Destination, ($destinationAttributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
            }
            Replace-PshFileEntry -Replacement $temporaryCopy -Destination $Destination
        }
        catch {
            if ([IO.File]::Exists($Destination)) {
                [IO.File]::SetAttributes($Destination, $destinationAttributes)
            }
            throw
        }
        finally {
            if ([IO.File]::Exists($temporaryCopy)) {
                [IO.File]::SetAttributes($temporaryCopy, [IO.FileAttributes]::Normal)
                [IO.File]::Delete($temporaryCopy)
            }
        }
    }
    else {
        [IO.File]::Copy($Source, $Destination, $true)
    }
    if ($Preserve) {
        [IO.File]::SetCreationTimeUtc($Destination, [IO.File]::GetCreationTimeUtc($Source))
        [IO.File]::SetLastAccessTimeUtc($Destination, [IO.File]::GetLastAccessTimeUtc($Source))
        [IO.File]::SetLastWriteTimeUtc($Destination, [IO.File]::GetLastWriteTimeUtc($Source))
        [IO.File]::SetAttributes($Destination, [IO.File]::GetAttributes($Source))
    }
    if ($VerboseOutput) {
        Write-Output ("'{0}' -> '{1}'" -f $SourceDisplay, $DestinationDisplay)
    }
}

function Copy-PshLinkEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceItem,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$NoClobber,

        [switch]$VerboseOutput,

        [Parameter(Mandatory = $true)]
        [string]$SourceDisplay,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDisplay
    )

    $targetText = Get-PshLinkTargetText -Item $SourceItem
    if ([string]::IsNullOrWhiteSpace($targetText)) {
        throw ('cannot read link target: {0}' -f $SourceDisplay)
    }
    $linkTypeProperty = $SourceItem.PSObject.Properties['LinkType']
    $itemType = if ($null -eq $linkTypeProperty) { '' } else { [string]$linkTypeProperty.Value }
    if ([string]::Equals($itemType, 'SymbolicLink', [StringComparison]::OrdinalIgnoreCase)) {
        $itemType = 'SymbolicLink'
    }
    elseif ([string]::Equals($itemType, 'Junction', [StringComparison]::OrdinalIgnoreCase)) {
        $itemType = 'Junction'
    }
    else {
        throw ('cannot preserve unsupported link type "{0}": {1}' -f $itemType, $SourceDisplay)
    }
    $parent = [IO.Path]::GetDirectoryName($Destination)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
        throw ('destination parent does not exist: {0}' -f $DestinationDisplay)
    }

    $destinationItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if ($null -ne $destinationItem -and $NoClobber) { return }
    if ($null -ne $destinationItem -and (Get-PshItemTypeName -Item $destinationItem) -eq 'directory') {
        throw ('refusing to replace an existing directory: {0}' -f $DestinationDisplay)
    }

    $temporaryLink = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'copy-link'
    $backup = $null
    $replacementCommitted = $false
    $backupRestored = $false
    try {
        Microsoft.PowerShell.Management\New-Item -Path $temporaryLink -ItemType $itemType -Target $targetText -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
        if ($null -eq $destinationItem) {
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $temporaryLink -Destination $Destination -ErrorAction Stop
        }
        elseif ((Get-PshItemTypeName -Item $destinationItem) -eq 'file') {
            Replace-PshFileEntry -Replacement $temporaryLink -Destination $Destination
        }
        else {
            $backup = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'copy-link-backup'
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $Destination -Destination $backup -ErrorAction Stop
            try {
                Microsoft.PowerShell.Management\Move-Item -LiteralPath $temporaryLink -Destination $Destination -ErrorAction Stop
                $replacementCommitted = $true
            }
            catch {
                $replacementError = $_.Exception.Message
                try {
                    Microsoft.PowerShell.Management\Move-Item -LiteralPath $backup -Destination $Destination -ErrorAction Stop
                    $backupRestored = $true
                }
                catch {
                    throw ('link replacement failed ({0}); rollback failed ({1}); original retained at: {2}' -f $replacementError, $_.Exception.Message, $backup)
                }
                throw $replacementError
            }
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryLink) -or [IO.Directory]::Exists($temporaryLink)) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $temporaryLink -Force -ErrorAction SilentlyContinue
        }
        if (($replacementCommitted -or $backupRestored) -and -not [string]::IsNullOrWhiteSpace($backup) -and ([IO.File]::Exists($backup) -or [IO.Directory]::Exists($backup))) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
    if ($VerboseOutput) {
        Write-Output ("'{0}' -> '{1}'" -f $SourceDisplay, $DestinationDisplay)
    }
}

function Copy-PshDirectoryEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$NoClobber,

        [switch]$Update,

        [switch]$Force,

        [switch]$Preserve,

        [switch]$VerboseOutput,

        [Parameter(Mandatory = $true)]
        [string]$SourceDisplay,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDisplay
    )

    if (-not [IO.Directory]::Exists($Destination)) {
        [void][IO.Directory]::CreateDirectory($Destination)
    }

    foreach ($entry in @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        $target = Join-Path -Path $Destination -ChildPath $entry.Name
        $sourceChildDisplay = Join-Path -Path $SourceDisplay -ChildPath $entry.Name
        $targetChildDisplay = Join-Path -Path $DestinationDisplay -ChildPath $entry.Name
        $type = Get-PshItemTypeName -Item $entry
        if ($type -eq 'link') {
            Copy-PshLinkEntry -SourceItem $entry -Destination $target -NoClobber:$NoClobber -VerboseOutput:$VerboseOutput -SourceDisplay $sourceChildDisplay -DestinationDisplay $targetChildDisplay
        }
        elseif ($type -eq 'directory') {
            Copy-PshDirectoryEntry -Source ([string]$entry.FullName) -Destination $target -NoClobber:$NoClobber -Update:$Update -Force:$Force -Preserve:$Preserve -VerboseOutput:$VerboseOutput -SourceDisplay $sourceChildDisplay -DestinationDisplay $targetChildDisplay
        }
        else {
            Copy-PshFileEntry -Source ([string]$entry.FullName) -Destination $target -NoClobber:$NoClobber -Update:$Update -Force:$Force -Preserve:$Preserve -VerboseOutput:$VerboseOutput -SourceDisplay $sourceChildDisplay -DestinationDisplay $targetChildDisplay
        }
    }

    if ($Preserve) {
        [IO.Directory]::SetCreationTimeUtc($Destination, [IO.Directory]::GetCreationTimeUtc($Source))
        [IO.Directory]::SetLastAccessTimeUtc($Destination, [IO.Directory]::GetLastAccessTimeUtc($Source))
        [IO.Directory]::SetLastWriteTimeUtc($Destination, [IO.Directory]::GetLastWriteTimeUtc($Source))
    }
}

function cp {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: cp [-Rrfnuvp] source ... destination'
        return
    }

    $recursive = $false
    $force = $false
    $noClobber = $false
    $update = $false
    $preserve = $false
    $verbose = $false
    $operands = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('R', 'r', 'f', 'n', 'u', 'v', 'p'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'cp' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                switch ($option) {
                    { $_ -eq 'R' -or $_ -eq 'r' } { $recursive = $true }
                    'f' { $noClobber = $false; $force = $true }
                    'n' { $noClobber = $true }
                    'u' { $update = $true }
                    'v' { $verbose = $true }
                    'p' { $preserve = $true }
                }
            }
            continue
        }
        $operands += $argument
    }

    if ($operands.Count -lt 2) {
        Write-PshCommandFailure -Command 'cp' -Code 2 -Message 'source and destination operands are required.'
        return
    }

    try {
        $destinationOriginal = [string]$operands[$operands.Count - 1]
        $destinationResolved = Resolve-PshFileSystemPath -Path $destinationOriginal -AllowMissing
        $sources = @()
        for ($index = 0; $index -lt ($operands.Count - 1); $index++) {
            $sourceOriginal = [string]$operands[$index]
            $sourceResolved = Resolve-PshFileSystemPath -Path $sourceOriginal
            $sources += [PSCustomObject]@{ Original = $sourceOriginal; Resolved = $sourceResolved }
        }
        if ($sources.Count -gt 1 -and -not [IO.Directory]::Exists($destinationResolved)) {
            throw 'the destination must be an existing directory for multiple sources.'
        }

        $plans = @()
        foreach ($source in $sources) {
            $target = $destinationResolved
            if ([IO.Directory]::Exists($destinationResolved)) {
                $target = Join-Path -Path $destinationResolved -ChildPath ([IO.Path]::GetFileName([string]$source.Resolved))
            }
            if (Test-PshPathEqual -Left ([string]$source.Resolved) -Right $target) {
                throw ('source and destination are the same: {0}' -f $source.Original)
            }
            $sourceItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath ([string]$source.Resolved) -Force -ErrorAction Stop
            $sourceType = Get-PshItemTypeName -Item $sourceItem
            if ($sourceType -eq 'directory') {
                if (-not $recursive) {
                    throw ('omitting directory without -R/-r: {0}' -f $source.Original)
                }
                if (Test-PshPathWithin -Candidate $target -Parent ([string]$source.Resolved)) {
                    throw ('refusing to copy a directory into itself: {0}' -f $source.Original)
                }
            }
            $targetDisplay = Get-PshDisplayPath -OriginalPath $destinationOriginal -ResolvedPath $target
            $sourceDisplay = Get-PshDisplayPath -OriginalPath ([string]$source.Original) -ResolvedPath ([string]$source.Resolved)
            $plans += [PSCustomObject]@{ Source = $source.Resolved; SourceItem = $sourceItem; Type = $sourceType; Target = $target; SourceDisplay = $sourceDisplay; TargetDisplay = $targetDisplay }
        }

        foreach ($plan in $plans) {
            if ($plan.Type -eq 'link') {
                Copy-PshLinkEntry -SourceItem $plan.SourceItem -Destination ([string]$plan.Target) -NoClobber:$noClobber -VerboseOutput:$verbose -SourceDisplay ([string]$plan.SourceDisplay) -DestinationDisplay ([string]$plan.TargetDisplay)
            }
            elseif ($plan.Type -eq 'directory') {
                Copy-PshDirectoryEntry -Source ([string]$plan.Source) -Destination ([string]$plan.Target) -NoClobber:$noClobber -Update:$update -Force:$force -Preserve:$preserve -VerboseOutput:$verbose -SourceDisplay ([string]$plan.SourceDisplay) -DestinationDisplay ([string]$plan.TargetDisplay)
            }
            else {
                Copy-PshFileEntry -Source ([string]$plan.Source) -Destination ([string]$plan.Target) -NoClobber:$noClobber -Update:$update -Force:$force -Preserve:$preserve -VerboseOutput:$verbose -SourceDisplay ([string]$plan.SourceDisplay) -DestinationDisplay ([string]$plan.TargetDisplay)
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'cp' -Code 3 -Message $_.Exception.Message
    }
}

function New-PshSiblingTemporaryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $parent = [IO.Path]::GetDirectoryName($Destination)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
        throw ('destination parent directory does not exist: {0}' -f $Destination)
    }
    do {
        $candidate = Join-Path -Path $parent -ChildPath ('.psh-{0}-{1}.tmp' -f $Purpose, [Guid]::NewGuid().ToString('N'))
    } while ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate))
    return $candidate
}

function Install-PshStagedEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$RetainBackup,

        [scriptblock]$BeforeInstall,

        [scriptblock]$BeforeRollback
    )

    $backup = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'replace-backup'
    $installed = $false
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $Destination -Destination $backup -ErrorAction Stop
    try {
        try {
            if ($null -ne $BeforeInstall) { & $BeforeInstall }
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $Stage -Destination $Destination -ErrorAction Stop
            $installed = $true
        }
        catch {
            $installError = $_.Exception.Message
            try {
                if ($null -ne $BeforeRollback) { & $BeforeRollback }
                Microsoft.PowerShell.Management\Move-Item -LiteralPath $backup -Destination $Destination -ErrorAction Stop
            }
            catch {
                throw ('staged install failed ({0}); rollback failed ({1}); original retained at: {2}' -f $installError, $_.Exception.Message, $backup)
            }
            throw $installError
        }
    }
    finally {
        if ($installed -and -not $RetainBackup -and (Test-Path -LiteralPath $backup)) {
            try {
                Remove-PshLiteralEntry -Path $backup
            }
            catch {
                throw ('replacement committed, but the original destination backup remains at: {0} ({1})' -f $backup, $_.Exception.Message)
            }
        }
    }

    if ($RetainBackup) {
        return $backup
    }
}

function Replace-PshFileEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Replacement,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$RetainBackup
    )

    $destinationItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if ($null -eq $destinationItem) {
        throw ('replacement destination does not exist: {0}' -f $Destination)
    }
    $destinationType = Get-PshItemTypeName -Item $destinationItem
    if ($destinationType -eq 'directory') {
        throw ('refusing to replace an existing directory: {0}' -f $Destination)
    }

    if ($destinationType -eq 'link') {
        return Install-PshStagedEntry -Stage $Replacement -Destination $Destination -RetainBackup:$RetainBackup
    }

    $backup = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'replace-backup'
    $replaced = $false
    try {
        try {
            [IO.File]::Replace($Replacement, $Destination, $backup, $true)
            $replaced = $true
        }
        catch [PlatformNotSupportedException] {
            return Install-PshStagedEntry -Stage $Replacement -Destination $Destination -RetainBackup:$RetainBackup
        }
    }
    finally {
        if ($replaced -and -not $RetainBackup -and [IO.File]::Exists($backup)) {
            [IO.File]::Delete($backup)
        }
    }

    if ($replaced -and $RetainBackup) {
        return $backup
    }
}

function Test-PshCrossDeviceMoveError {
    param(
        [Parameter(Mandatory = $true)]
        [Exception]$Exception
    )

    $current = $Exception
    $windows = $env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\'
    while ($null -ne $current) {
        $nativeCode = $current.HResult -band 0xFFFF
        if (($windows -and $nativeCode -eq 17) -or (-not $windows -and $nativeCode -eq 18)) {
            return $true
        }
        if ($current.Message -match '(?i)cross-device|different (?:disk|volume)|not (?:the )?same device|EXDEV') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-PshKnownDifferentWindowsVolume {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if ($env:OS -ne 'Windows_NT' -and [IO.Path]::DirectorySeparatorChar -ne '\') {
        return $false
    }
    $sourceRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Source))
    $destinationRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination))
    return -not [string]::Equals($sourceRoot, $destinationRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Copy-PshMoveStageEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceItem,

        [Parameter(Mandatory = $true)]
        [string]$Stage
    )

    $source = [string]$SourceItem.FullName
    $sourceType = Get-PshItemTypeName -Item $SourceItem
    if ($sourceType -eq 'link') {
        Copy-PshLinkEntry -SourceItem $SourceItem -Destination $Stage -SourceDisplay $source -DestinationDisplay $Stage
    }
    elseif ($sourceType -eq 'directory') {
        Copy-PshDirectoryEntry -Source $source -Destination $Stage -Preserve -SourceDisplay $source -DestinationDisplay $Stage
    }
    else {
        Copy-PshFileEntry -Source $source -Destination $Stage -Preserve -SourceDisplay $source -DestinationDisplay $Stage
    }
}

function Remove-PshLiteralEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $itemType = Get-PshItemTypeName -Item $item
    if ($itemType -eq 'link') {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    elseif ($itemType -eq 'directory') {
        Clear-PshReadOnlyRemovalAttributes -Path $Path
        [IO.Directory]::Delete($Path, $true)
    }
    else {
        [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($Path)
    }
}

function Restore-PshMoveDestination {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$Backup
    )

    $installedRecovery = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'move-installed'
    try {
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $Destination -Destination $installedRecovery -ErrorAction Stop
    }
    catch {
        throw ('rollback could not preserve the installed entry ({0}); original retained at: {1}; installed entry remains at: {2}' -f $_.Exception.Message, $Backup, $Destination)
    }

    try {
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $Backup -Destination $Destination -ErrorAction Stop
    }
    catch {
        $restoreError = $_.Exception.Message
        try {
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $installedRecovery -Destination $Destination -ErrorAction Stop
        }
        catch {
            throw ('rollback failed ({0}); reinstall failed ({1}); original retained at: {2}; installed entry retained at: {3}' -f $restoreError, $_.Exception.Message, $Backup, $installedRecovery)
        }
        throw ('rollback failed ({0}); original retained at: {1}; installed entry restored at: {2}' -f $restoreError, $Backup, $Destination)
    }

    try {
        Remove-PshLiteralEntry -Path $installedRecovery
    }
    catch {
        throw ('rollback restored the original destination, but the installed duplicate remains at: {0} ({1})' -f $installedRecovery, $_.Exception.Message)
    }
}

function Move-PshEntryTransactionally {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceItem,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [scriptblock]$BeforeSourceRemoval
    )

    $source = [string]$SourceItem.FullName
    $sourceType = Get-PshItemTypeName -Item $SourceItem
    $stage = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'move-stage'
    $backup = $null
    try {
        Copy-PshMoveStageEntry -SourceItem $SourceItem -Stage $stage
        $backup = Install-PshStagedEntry -Stage $stage -Destination $Destination -RetainBackup
        try {
            if ($null -ne $BeforeSourceRemoval) { & $BeforeSourceRemoval }
            Remove-PshLiteralEntry -Path $source
        }
        catch {
            $sourceRemovalError = $_.Exception.Message
            if ($sourceType -eq 'directory') {
                throw ('directory source cleanup failed ({0}); installed copy retained at: {1}; original destination retained at: {2}; source may be incomplete at: {3}' -f $sourceRemovalError, $Destination, $backup, $source)
            }
            try {
                Restore-PshMoveDestination -Destination $Destination -Backup $backup
                $backup = $null
            }
            catch {
                throw ('source removal failed ({0}); destination rollback failed ({1})' -f $sourceRemovalError, $_.Exception.Message)
            }
            throw ('source removal failed ({0}); original destination restored.' -f $sourceRemovalError)
        }

        try {
            Remove-PshLiteralEntry -Path $backup
            $backup = $null
        }
        catch {
            throw ('move committed, but the original destination backup remains at: {0} ({1})' -f $backup, $_.Exception.Message)
        }
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            try {
                Remove-PshLiteralEntry -Path $stage
            }
            catch {
                throw ('move cleanup failed; staged artifact retained at: {0} ({1})' -f $stage, $_.Exception.Message)
            }
        }
    }
}

function mv {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: mv [-fnuv] source ... destination'
        return
    }

    $noClobber = $false
    $update = $false
    $verbose = $false
    $operands = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('f', 'n', 'u', 'v'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'mv' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                switch ($option) {
                    'f' { $noClobber = $false }
                    'n' { $noClobber = $true }
                    'u' { $update = $true }
                    'v' { $verbose = $true }
                }
            }
            continue
        }
        $operands += $argument
    }

    if ($operands.Count -lt 2) {
        Write-PshCommandFailure -Command 'mv' -Code 2 -Message 'source and destination operands are required.'
        return
    }

    try {
        $destinationOriginal = [string]$operands[$operands.Count - 1]
        $destinationResolved = Resolve-PshFileSystemPath -Path $destinationOriginal -AllowMissing
        $sources = @()
        for ($index = 0; $index -lt ($operands.Count - 1); $index++) {
            $sourceOriginal = [string]$operands[$index]
            $sourceResolved = Resolve-PshFileSystemPath -Path $sourceOriginal
            $sources += [PSCustomObject]@{ Original = $sourceOriginal; Resolved = $sourceResolved }
        }
        if ($sources.Count -gt 1 -and -not [IO.Directory]::Exists($destinationResolved)) {
            throw 'the destination must be an existing directory for multiple sources.'
        }

        $plans = @()
        foreach ($source in $sources) {
            $target = $destinationResolved
            if ([IO.Directory]::Exists($destinationResolved)) {
                $target = Join-Path -Path $destinationResolved -ChildPath ([IO.Path]::GetFileName([string]$source.Resolved))
            }
            if (Test-PshPathEqual -Left ([string]$source.Resolved) -Right $target) {
                throw ('source and destination are the same: {0}' -f $source.Original)
            }
            if ([IO.Directory]::Exists([string]$source.Resolved) -and (Test-PshPathWithin -Candidate $target -Parent ([string]$source.Resolved))) {
                throw ('refusing to move a directory into itself: {0}' -f $source.Original)
            }
            $sourceItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath ([string]$source.Resolved) -Force -ErrorAction Stop
            $plans += [PSCustomObject]@{
                Source = [string]$source.Resolved
                SourceItem = $sourceItem
                SourceType = Get-PshItemTypeName -Item $sourceItem
                Target = $target
                SourceDisplay = Get-PshDisplayPath -OriginalPath ([string]$source.Original) -ResolvedPath ([string]$source.Resolved)
                TargetDisplay = Get-PshDisplayPath -OriginalPath $destinationOriginal -ResolvedPath $target
            }
        }

        foreach ($plan in $plans) {
            $targetItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath ([string]$plan.Target) -Force -ErrorAction SilentlyContinue
            $targetExists = $null -ne $targetItem
            if ($targetExists -and $noClobber) {
                continue
            }
            if ($targetExists -and $update) {
                $sourceTime = (Microsoft.PowerShell.Management\Get-Item -LiteralPath ([string]$plan.Source) -Force).LastWriteTimeUtc
                $targetTime = (Microsoft.PowerShell.Management\Get-Item -LiteralPath ([string]$plan.Target) -Force).LastWriteTimeUtc
                if ($targetTime -ge $sourceTime) {
                    continue
                }
            }
            if ($targetExists) {
                $targetType = Get-PshItemTypeName -Item $targetItem
                if ($targetType -eq 'directory') {
                    if ([string]$plan.SourceType -ne 'directory') {
                        throw ('cannot replace a directory with a non-directory: {0}' -f $plan.TargetDisplay)
                    }
                    if (@(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath ([string]$plan.Target) -Force -ErrorAction Stop).Count -gt 0) {
                        throw ('refusing to replace a non-empty directory: {0}' -f $plan.TargetDisplay)
                    }
                }
                elseif ([string]$plan.SourceType -eq 'directory') {
                    throw ('cannot replace a non-directory with a directory: {0}' -f $plan.TargetDisplay)
                }

                $useTransactionalMove = ([string]$plan.SourceType -ne 'file' -or $targetType -ne 'file')
                if (-not $useTransactionalMove) {
                    $useTransactionalMove = Test-PshKnownDifferentWindowsVolume -Source ([string]$plan.Source) -Destination ([string]$plan.Target)
                }
                if ($useTransactionalMove) {
                    Move-PshEntryTransactionally -SourceItem $plan.SourceItem -Destination ([string]$plan.Target)
                }
                else {
                    try {
                        $backup = Replace-PshFileEntry -Replacement ([string]$plan.Source) -Destination ([string]$plan.Target) -RetainBackup
                        try {
                            Remove-PshLiteralEntry -Path $backup
                        }
                        catch {
                            throw ('move committed, but the original destination backup remains at: {0} ({1})' -f $backup, $_.Exception.Message)
                        }
                    }
                    catch {
                        if (-not (Test-PshCrossDeviceMoveError -Exception $_.Exception)) {
                            throw
                        }
                        Move-PshEntryTransactionally -SourceItem $plan.SourceItem -Destination ([string]$plan.Target)
                    }
                }
            }
            else {
                Microsoft.PowerShell.Management\Move-Item -LiteralPath ([string]$plan.Source) -Destination ([string]$plan.Target) -ErrorAction Stop
            }
            if ($verbose) {
                Write-Output ("renamed '{0}' -> '{1}'" -f $plan.SourceDisplay, $plan.TargetDisplay)
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'mv' -Code 3 -Message $_.Exception.Message
    }
}

function Clear-PshReadOnlyRemovalAttributes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ((Get-PshItemTypeName -Item $item) -eq 'link') {
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            Clear-PshReadOnlyRemovalAttributes -Path ([string]$child.FullName)
        }
        return
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        [IO.File]::SetAttributes([string]$item.FullName, ($item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
    }
}

function rm {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: rm [-Rrfv] path ...'
        return
    }

    $recursive = $false
    $force = $false
    $verbose = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('R', 'r', 'f', 'v'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'rm' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'R' -or $option -eq 'r') { $recursive = $true }
                if ($option -eq 'f') { $force = $true }
                if ($option -eq 'v') { $verbose = $true }
            }
            continue
        }
        $paths += $argument
    }

    if ($paths.Count -eq 0) {
        if ($force) {
            Set-PshLastExitCode -Code 0
            return
        }
        Write-PshCommandFailure -Command 'rm' -Code 2 -Message 'at least one path is required.'
        return
    }

    try {
        $plans = @()
        foreach ($path in $paths) {
            $resolved = Resolve-PshFileSystemPath -Path $path -AllowMissing
            $exists = [IO.File]::Exists($resolved) -or [IO.Directory]::Exists($resolved)
            if (-not $exists) {
                if ($force) {
                    $plans += [PSCustomObject]@{ Original = $path; Resolved = $resolved; Exists = $false; Directory = $false }
                    continue
                }
                throw ('path does not exist: {0}' -f $path)
            }
            if (Test-PshProtectedRemovalPath -Path $resolved) {
                throw ('refusing to remove a drive root or the home directory: {0}' -f $path)
            }
            $isDirectory = [IO.Directory]::Exists($resolved)
            if ($isDirectory -and -not $recursive) {
                throw ('cannot remove directory without -R/-r: {0}' -f $path)
            }
            $plans += [PSCustomObject]@{ Original = $path; Resolved = $resolved; Exists = $true; Directory = $isDirectory }
        }

        foreach ($plan in $plans) {
            if (-not $plan.Exists) {
                continue
            }
            if ($plan.Directory) {
                if ($force) {
                    Clear-PshReadOnlyRemovalAttributes -Path ([string]$plan.Resolved)
                }
                [IO.Directory]::Delete([string]$plan.Resolved, $true)
                if ($verbose) {
                    Write-Output ("removed directory '{0}'" -f (Get-PshDisplayPath -OriginalPath ([string]$plan.Original) -ResolvedPath ([string]$plan.Resolved)))
                }
            }
            else {
                [IO.File]::SetAttributes([string]$plan.Resolved, [IO.FileAttributes]::Normal)
                [IO.File]::Delete([string]$plan.Resolved)
                if ($verbose) {
                    Write-Output ("removed '{0}'" -f (Get-PshDisplayPath -OriginalPath ([string]$plan.Original) -ResolvedPath ([string]$plan.Resolved)))
                }
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'rm' -Code 3 -Message $_.Exception.Message
    }
}

function ConvertFrom-PshTouchTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -notmatch '^(?<digits>[0-9]{8}|[0-9]{10}|[0-9]{12})(?:\.(?<seconds>[0-9]{2}))?$') {
        throw ('unsupported timestamp "{0}"; expected [[CC]YY]MMDDhhmm[.ss].' -f $Value)
    }

    $digits = [string]$Matches.digits
    $seconds = 0
    if (-not [string]::IsNullOrEmpty([string]$Matches.seconds)) {
        $seconds = [int]$Matches.seconds
    }

    $year = 0
    $offset = 0
    if ($digits.Length -eq 12) {
        $year = [int]$digits.Substring(0, 4)
        $offset = 4
    }
    elseif ($digits.Length -eq 10) {
        $twoDigitYear = [int]$digits.Substring(0, 2)
        if ($twoDigitYear -le 68) {
            $year = 2000 + $twoDigitYear
        }
        else {
            $year = 1900 + $twoDigitYear
        }
        $offset = 2
    }
    else {
        $year = (Get-Date).Year
    }

    $month = [int]$digits.Substring($offset, 2)
    $day = [int]$digits.Substring($offset + 2, 2)
    $hour = [int]$digits.Substring($offset + 4, 2)
    $minute = [int]$digits.Substring($offset + 6, 2)
    return New-Object DateTime($year, $month, $day, $hour, $minute, $seconds, [DateTimeKind]::Local)
}

function Set-PshFileTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string[]]$Path,

        [string]$ReferencePath,

        [Nullable[DateTime]]$AccessTime,

        [Nullable[DateTime]]$ModificationTime,

        [switch]$AccessOnly,

        [switch]$ModificationOnly,

        [switch]$NoCreate
    )

    begin {
        if ($AccessOnly -and $ModificationOnly) {
            throw 'AccessOnly and ModificationOnly cannot be used together.'
        }

        $hasAccessTime = $PSBoundParameters.ContainsKey('AccessTime')
        $hasModificationTime = $PSBoundParameters.ContainsKey('ModificationTime')

        $reference = $null
        if (-not [string]::IsNullOrWhiteSpace($ReferencePath)) {
            $referenceResolved = Resolve-PshFileSystemPath -Path $ReferencePath
            $reference = Microsoft.PowerShell.Management\Get-Item -LiteralPath $referenceResolved -Force -ErrorAction Stop
        }
    }

    process {
        $resolvedPaths = @()
        foreach ($pathValue in $Path) {
            $resolvedPaths += Resolve-PshFileSystemPath -Path $pathValue -AllowMissing
        }

        foreach ($resolved in $resolvedPaths) {
            $exists = [IO.File]::Exists($resolved) -or [IO.Directory]::Exists($resolved)
            if (-not $exists) {
                if ($NoCreate) {
                    continue
                }
                $parent = [IO.Path]::GetDirectoryName($resolved)
                if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
                    throw ('parent directory does not exist: {0}' -f $resolved)
                }
                $stream = New-Object IO.FileStream($resolved, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                $stream.Dispose()
            }

            $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            $now = Get-Date
            $accessValue = $now
            $modificationValue = $now
            if ($null -ne $reference) {
                $accessValue = $reference.LastAccessTime
                $modificationValue = $reference.LastWriteTime
            }
            if ($hasAccessTime) {
                $accessValue = [DateTime]$AccessTime
            }
            if ($hasModificationTime) {
                $modificationValue = [DateTime]$ModificationTime
            }

            if (-not $ModificationOnly) {
                $item.LastAccessTime = $accessValue
            }
            if (-not $AccessOnly) {
                $item.LastWriteTime = $modificationValue
            }

            Write-Output (Microsoft.PowerShell.Management\Get-Item -LiteralPath $resolved -Force -ErrorAction Stop)
        }
    }
}

function touch {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: touch [-amc] [-r reference|-t timestamp] file ...'
        return
    }

    $accessOnly = $false
    $modificationOnly = $false
    $noCreate = $false
    $referencePath = $null
    $timestamp = $null
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and ($argument -ceq '-r' -or $argument -ceq '-t')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'touch' -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $index++
            if ($argument -ceq '-r') { $referencePath = $arguments[$index] }
            if ($argument -ceq '-t') { $timestamp = $arguments[$index] }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('a', 'm', 'c'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'touch' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'a') { $accessOnly = $true }
                if ($option -eq 'm') { $modificationOnly = $true }
                if ($option -eq 'c') { $noCreate = $true }
            }
            continue
        }
        $paths += $argument
    }

    if ($paths.Count -eq 0) {
        Write-PshCommandFailure -Command 'touch' -Code 2 -Message 'at least one file is required.'
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($referencePath) -and -not [string]::IsNullOrWhiteSpace($timestamp)) {
        Write-PshCommandFailure -Command 'touch' -Code 2 -Message '-r and -t cannot be used together.'
        return
    }
    if ($accessOnly -and $modificationOnly) {
        $accessOnly = $false
        $modificationOnly = $false
    }

    $timestampValue = $null
    if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
        try {
            $timestampValue = ConvertFrom-PshTouchTimestamp -Value $timestamp
        }
        catch {
            Write-PshCommandFailure -Command 'touch' -Code 2 -Message $_.Exception.Message
            return
        }
    }

    try {
        $parameters = @{
            Path = @($paths)
            NoCreate = $noCreate
        }
        if ($accessOnly) { $parameters['AccessOnly'] = $true }
        if ($modificationOnly) { $parameters['ModificationOnly'] = $true }
        if (-not [string]::IsNullOrWhiteSpace($referencePath)) {
            $parameters['ReferencePath'] = $referencePath
        }
        elseif ($null -ne $timestampValue) {
            $parameters['AccessTime'] = $timestampValue
            $parameters['ModificationTime'] = $timestampValue
        }

        Set-PshFileTime @parameters | Microsoft.PowerShell.Core\Out-Null
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'touch' -Code 3 -Message $_.Exception.Message
    }
}

function ln {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: ln [-sfnv] target link_name'
        return
    }

    $symbolic = $false
    $force = $false
    $noDereference = $false
    $verbose = $false
    $operands = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('s', 'f', 'n', 'v'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'ln' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 's') { $symbolic = $true }
                if ($option -eq 'f') { $force = $true }
                if ($option -eq 'n') { $noDereference = $true }
                if ($option -eq 'v') { $verbose = $true }
            }
            continue
        }
        $operands += $argument
    }

    if ($operands.Count -ne 2) {
        Write-PshCommandFailure -Command 'ln' -Code 2 -Message 'exactly one target and one link name are required.'
        return
    }

    try {
        $sourceOriginal = [string]$operands[0]
        $linkOriginal = [string]$operands[1]
        $sourceResolved = Resolve-PshFileSystemPath -Path $sourceOriginal -AllowMissing
        $linkResolved = Resolve-PshFileSystemPath -Path $linkOriginal -AllowMissing
        if (-not $symbolic -and -not [IO.File]::Exists($sourceResolved)) {
            throw ('hard-link target must be an existing file: {0}' -f $sourceOriginal)
        }
        if (Test-PshPathEqual -Left $sourceResolved -Right $linkResolved) {
            throw ('target and link name are the same path: {0}' -f $linkOriginal)
        }
        $linkItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $linkResolved -Force -ErrorAction SilentlyContinue
        $linkType = $null
        if ($null -ne $linkItem) { $linkType = Get-PshItemTypeName -Item $linkItem }
        if ($linkType -eq 'directory') {
            throw ('refusing to replace an existing directory: {0}' -f $linkOriginal)
        }
        $linkExists = $null -ne $linkItem
        if ($linkExists) {
            if (-not $force) {
                throw ('link name already exists: {0}' -f $linkOriginal)
            }
            if (Test-PshProtectedRemovalPath -Path $linkResolved) {
                throw ('refusing to replace protected path: {0}' -f $linkOriginal)
            }
        }
        $parent = [IO.Path]::GetDirectoryName($linkResolved)
        if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
            throw ('link parent directory does not exist: {0}' -f $linkOriginal)
        }

        $itemType = 'HardLink'
        if ($symbolic) { $itemType = 'SymbolicLink' }
        $temporaryLink = New-PshSiblingTemporaryPath -Destination $linkResolved -Purpose 'link'
        try {
            $linkTargetValue = $sourceResolved
            if ($symbolic) { $linkTargetValue = $sourceOriginal }
            Microsoft.PowerShell.Management\New-Item -Path $temporaryLink -ItemType $itemType -Target $linkTargetValue -ErrorAction Stop | Microsoft.PowerShell.Core\Out-Null
            if ($linkExists) {
                if ($linkType -eq 'link' -and $noDereference) {
                    Install-PshStagedEntry -Stage $temporaryLink -Destination $linkResolved
                }
                else {
                    Replace-PshFileEntry -Replacement $temporaryLink -Destination $linkResolved
                }
            }
            else {
                Microsoft.PowerShell.Management\Move-Item -LiteralPath $temporaryLink -Destination $linkResolved -ErrorAction Stop
            }
        }
        finally {
            if ([IO.File]::Exists($temporaryLink) -or [IO.Directory]::Exists($temporaryLink)) {
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $temporaryLink -Force -ErrorAction SilentlyContinue
            }
        }
        if ($verbose) {
            $sourceDisplay = Get-PshDisplayPath -OriginalPath $sourceOriginal -ResolvedPath $sourceResolved
            $linkDisplay = Get-PshDisplayPath -OriginalPath $linkOriginal -ResolvedPath $linkResolved
            Write-Output ("'{0}' => '{1}'" -f $linkDisplay, $sourceDisplay)
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'ln' -Code 3 -Message $_.Exception.Message
    }
}

function realpath {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: realpath [-e|-m] [--relative-to directory] path ...'
        return
    }

    $allowMissing = $false
    $relativeTo = $null
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-e') {
            $allowMissing = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-m') {
            $allowMissing = $true
            continue
        }
        if ($parseOptions -and $argument -ceq '--relative-to') {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'realpath' -Code 2 -Message '--relative-to requires a directory.'
                return
            }
            $index++
            $relativeTo = $arguments[$index]
            continue
        }
        if ($parseOptions -and $argument.StartsWith('--relative-to=')) {
            $relativeTo = $argument.Substring('--relative-to='.Length)
            if ([string]::IsNullOrEmpty($relativeTo)) {
                Write-PshCommandFailure -Command 'realpath' -Code 2 -Message '--relative-to requires a directory.'
                return
            }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'realpath' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
            return
        }
        $paths += $argument
    }

    if ($paths.Count -eq 0) {
        Write-PshCommandFailure -Command 'realpath' -Code 2 -Message 'at least one path is required.'
        return
    }

    try {
        $base = $null
        if (-not [string]::IsNullOrWhiteSpace($relativeTo)) {
            $base = Resolve-PshFileSystemPath -Path $relativeTo
            if (-not [IO.Directory]::Exists($base)) {
                throw ('relative base is not a directory: {0}' -f $relativeTo)
            }
        }
        foreach ($path in $paths) {
            $resolved = Resolve-PshPhysicalFileSystemPath -Path $path -AllowMissing:$allowMissing
            if ($null -ne $base) {
                Write-Output (Get-PshRelativePath -BasePath $base -TargetPath $resolved)
            }
            else {
                Write-Output $resolved
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'realpath' -Code 3 -Message $_.Exception.Message
    }
}

function Get-PshBaseNameValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        [string]$Suffix
    )

    $trimmed = $Path.TrimEnd([char[]]@('\', '/'))
    if ([string]::IsNullOrEmpty($trimmed)) {
        $trimmed = $Path
    }
    $separator = [Math]::Max($trimmed.LastIndexOf('/'), $trimmed.LastIndexOf('\'))
    $value = $trimmed
    if ($separator -ge 0) {
        $value = $trimmed.Substring($separator + 1)
    }
    if ([string]::IsNullOrEmpty($value) -and ($Path -eq '/' -or $Path -eq '\')) {
        $value = $Path
    }
    if (-not [string]::IsNullOrEmpty($Suffix) -and $value.EndsWith($Suffix, [StringComparison]::Ordinal) -and $value.Length -gt $Suffix.Length) {
        $value = $value.Substring(0, $value.Length - $Suffix.Length)
    }
    return $value
}

function basename {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: basename [-az] [-s suffix] name [suffix]'
        return
    }

    $multiple = $false
    $nullTerminated = $false
    $suffix = $null
    $operands = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-s') {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'basename' -Code 2 -Message '-s requires a suffix.'
                return
            }
            $index++
            $suffix = $arguments[$index]
            $multiple = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('--suffix=')) {
            $suffix = $argument.Substring('--suffix='.Length)
            $multiple = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('a', 'z'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'basename' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'a') { $multiple = $true }
                if ($option -eq 'z') { $nullTerminated = $true }
            }
            continue
        }
        $operands += $argument
    }

    if ($operands.Count -eq 0) {
        Write-PshCommandFailure -Command 'basename' -Code 2 -Message 'a path is required.'
        return
    }
    if (-not $multiple -and $operands.Count -gt 2) {
        Write-PshCommandFailure -Command 'basename' -Code 2 -Message 'too many operands; use -a for multiple paths.'
        return
    }
    if (-not $multiple -and $operands.Count -eq 2 -and $null -eq $suffix) {
        $suffix = $operands[1]
        $operands = @($operands[0])
    }

    foreach ($path in $operands) {
        $value = Get-PshBaseNameValue -Path $path -Suffix $suffix
        if ($nullTerminated) {
            Write-Output ($value + [char]0)
        }
        else {
            Write-Output $value
        }
    }
    Set-PshLastExitCode -Code 0
}

function Get-PshDirNameValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return '.'
    }
    $root = [IO.Path]::GetPathRoot($Path)
    if (-not [string]::IsNullOrEmpty($root) -and
        [string]::Equals($Path.TrimEnd([char[]]@('\', '/')), $root.TrimEnd([char[]]@('\', '/')), (Get-PshPathComparison))) {
        return $root
    }
    $trimmed = $Path.TrimEnd([char[]]@('\', '/'))
    if ([string]::IsNullOrEmpty($trimmed)) {
        return $Path.Substring(0, 1)
    }
    $separator = [Math]::Max($trimmed.LastIndexOf('/'), $trimmed.LastIndexOf('\'))
    if ($separator -lt 0) {
        return '.'
    }
    if ($separator -eq 0) {
        return $trimmed.Substring(0, 1)
    }
    $result = $trimmed.Substring(0, $separator).TrimEnd([char[]]@('\', '/'))
    if (-not [string]::IsNullOrEmpty($root) -and
        [string]::Equals($result, $root.TrimEnd([char[]]@('\', '/')), (Get-PshPathComparison))) {
        return $root
    }
    return $result
}

function dirname {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: dirname [-z] name ...'
        return
    }

    $nullTerminated = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-z') {
            $nullTerminated = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'dirname' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
            return
        }
        $paths += $argument
    }
    if ($paths.Count -eq 0) {
        Write-PshCommandFailure -Command 'dirname' -Code 2 -Message 'at least one path is required.'
        return
    }

    foreach ($path in $paths) {
        $value = Get-PshDirNameValue -Path $path
        if ($nullTerminated) {
            Write-Output ($value + [char]0)
        }
        else {
            Write-Output $value
        }
    }
    Set-PshLastExitCode -Code 0
}

function ConvertTo-PshStatFormat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Format,

        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    $supported = @('%', 'n', 's', 'F', 'y', 'Y', 'a')
    for ($index = 0; $index -lt $Format.Length; $index++) {
        if ($Format[$index] -ne '%') {
            continue
        }
        if (($index + 1) -ge $Format.Length) {
            throw 'a trailing % is not supported in the stat format.'
        }
        $token = [string]$Format[$index + 1]
        if ($supported -notcontains $token) {
            throw ('unsupported stat format token "%{0}".' -f $token)
        }
        $index++
    }

    $type = Get-PshItemTypeName -Item $Item
    $length = [long]0
    if ($type -eq 'file') { $length = [long]$Item.Length }
    $epoch = [long](New-TimeSpan -Start ([DateTime]'1970-01-01T00:00:00Z') -End $Item.LastWriteTimeUtc).TotalSeconds
    $attributes = [string]$Item.Attributes
    $result = $Format
    $result = $result.Replace([string]'%%', [string][char]1)
    $result = $result.Replace('%n', [string]$Item.FullName)
    $result = $result.Replace('%s', [string]$length)
    $result = $result.Replace('%F', $type)
    $result = $result.Replace('%y', $Item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))
    $result = $result.Replace('%Y', [string]$epoch)
    $result = $result.Replace('%a', $attributes)
    return $result.Replace([string][char]1, [string]'%')
}

function stat {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: stat [-fLt] [-c format] path ...'
        return
    }

    $format = $null
    $fileSystem = $false
    $followLinks = $false
    $terse = $false
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-c') {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'stat' -Code 2 -Message '-c requires a format string.'
                return
            }
            $index++
            $format = $arguments[$index]
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-c') -and $argument.Length -gt 2) {
            $format = $argument.Substring(2)
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('f', 'L', 't'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'stat' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'f') { $fileSystem = $true }
                if ($option -eq 'L') { $followLinks = $true }
                if ($option -eq 't') { $terse = $true }
            }
            continue
        }
        $paths += $argument
    }

    if ($paths.Count -eq 0) {
        Write-PshCommandFailure -Command 'stat' -Code 2 -Message 'at least one path is required.'
        return
    }
    if ($fileSystem -and $null -ne $format) {
        Write-PshCommandFailure -Command 'stat' -Code 2 -Message '-c with -f is outside the supported subset.'
        return
    }

    try {
        $resolvedPaths = @()
        foreach ($path in $paths) {
            if ($followLinks) {
                $resolvedPaths += Resolve-PshPhysicalFileSystemPath -Path $path
            }
            else {
                $resolvedPaths += Resolve-PshFileSystemPath -Path $path
            }
        }
        foreach ($resolved in $resolvedPaths) {
            $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if ($fileSystem) {
                $root = [IO.Path]::GetPathRoot($resolved)
                $drive = New-Object IO.DriveInfo($root)
                if ($terse) {
                    Write-Output ("{0}`t{1}`t{2}`t{3}" -f $drive.Name, $drive.DriveFormat, $drive.TotalSize, $drive.AvailableFreeSpace)
                }
                else {
                    Write-Output ('File system: {0}' -f $drive.Name)
                    Write-Output ('Type: {0}' -f $drive.DriveFormat)
                    Write-Output ('Total: {0}' -f $drive.TotalSize)
                    Write-Output ('Available: {0}' -f $drive.AvailableFreeSpace)
                }
                continue
            }

            if ($null -ne $format) {
                Write-Output (ConvertTo-PshStatFormat -Format $format -Item $item)
                continue
            }

            $type = Get-PshItemTypeName -Item $item
            $length = [long]0
            if ($type -eq 'file') { $length = [long]$item.Length }
            if ($terse) {
                Write-Output ("{0}`t{1}`t{2}`t{3}" -f $item.FullName, $type, $length, $item.LastWriteTimeUtc.ToString('o'))
            }
            else {
                Write-Output ('Path: {0}' -f $item.FullName)
                Write-Output ('Type: {0}' -f $type)
                Write-Output ('Size: {0}' -f $length)
                Write-Output ('Modified: {0}' -f $item.LastWriteTimeUtc.ToString('o'))
                Write-Output ('Attributes: {0}' -f $item.Attributes)
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        $message = $_.Exception.Message
        if ($message -like 'unsupported stat format*' -or $message -like 'a trailing %*') {
            Write-PshCommandFailure -Command 'stat' -Code 2 -Message $message
        }
        else {
            Write-PshCommandFailure -Command 'stat' -Code 3 -Message $message
        }
    }
}

function Get-PshFileClassification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Mime,

        [switch]$InspectCompressed
    )

    $pathItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ((Get-PshItemTypeName -Item $pathItem) -eq 'link') {
        if ($Mime) { return 'inode/symlink' }
        $linkTarget = Get-PshLinkTargetText -Item $pathItem
        if ([string]::IsNullOrWhiteSpace($linkTarget)) { return 'symbolic link' }
        return ('symbolic link to {0}' -f $linkTarget)
    }
    if ([IO.Directory]::Exists($Path)) {
        if ($Mime) { return 'inode/directory' }
        return 'directory'
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        if ($Mime) { return 'application/x-empty' }
        return 'empty'
    }

    $contentBytes = $bytes
    $compressedPrefix = $null
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b) {
        if (-not $InspectCompressed) {
            if ($Mime) { return 'application/gzip' }
            return 'gzip compressed data'
        }
        try {
            $input = New-Object IO.MemoryStream(,$bytes)
            $gzip = New-Object IO.Compression.GZipStream($input, [IO.Compression.CompressionMode]::Decompress)
            $output = New-Object IO.MemoryStream
            $buffer = New-Object byte[] 8192
            while (($count = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0 -and $output.Length -lt 1048576) {
                $output.Write($buffer, 0, $count)
            }
            $gzip.Dispose()
            $input.Dispose()
            $contentBytes = $output.ToArray()
            $output.Dispose()
            $compressedPrefix = 'gzip compressed data, containing '
        }
        catch {
            if ($Mime) { return 'application/gzip' }
            return 'gzip compressed data'
        }
    }

    if ($contentBytes.Length -ge 4 -and $contentBytes[0] -eq 0x50 -and $contentBytes[1] -eq 0x4b -and $contentBytes[2] -in @(0x03, 0x05, 0x07) -and $contentBytes[3] -in @(0x04, 0x06, 0x08)) {
        if ($Mime) { return 'application/zip' }
        return 'Zip archive data'
    }
    if ($contentBytes.Length -ge 5 -and [Text.Encoding]::ASCII.GetString($contentBytes, 0, 5) -eq '%PDF-') {
        if ($Mime) { return 'application/pdf' }
        return 'PDF document'
    }
    if ($contentBytes.Length -ge 8 -and $contentBytes[0] -eq 0x89 -and [Text.Encoding]::ASCII.GetString($contentBytes, 1, 3) -eq 'PNG') {
        if ($Mime) { return 'image/png' }
        return 'PNG image data'
    }

    $sampleLength = [Math]::Min($contentBytes.Length, 65536)
    $encodingName = 'UTF-8 Unicode text'
    $mimeCharset = 'utf-8'
    $textEncoding = New-Object Text.UTF8Encoding($false, $true)
    $utf16Bom = $false
    if ($contentBytes.Length -ge 2 -and $contentBytes[0] -eq 0xff -and $contentBytes[1] -eq 0xfe) {
        $encodingName = 'UTF-16 little-endian Unicode text'
        $mimeCharset = 'utf-16le'
        $textEncoding = New-Object Text.UnicodeEncoding($false, $true, $true)
        $utf16Bom = $true
    }
    elseif ($contentBytes.Length -ge 2 -and $contentBytes[0] -eq 0xfe -and $contentBytes[1] -eq 0xff) {
        $encodingName = 'UTF-16 big-endian Unicode text'
        $mimeCharset = 'utf-16be'
        $textEncoding = New-Object Text.UnicodeEncoding($true, $true, $true)
        $utf16Bom = $true
    }
    if (-not $utf16Bom) {
        for ($index = 0; $index -lt $sampleLength; $index++) {
            if ($contentBytes[$index] -eq 0) {
                if ($Mime) { return 'application/octet-stream' }
                if ($null -ne $compressedPrefix) { return ($compressedPrefix + 'binary data') }
                return 'data'
            }
        }
        try {
            [void]$textEncoding.GetString($contentBytes, 0, $sampleLength)
        }
        catch {
            if ($Mime) { return 'application/octet-stream' }
            if ($null -ne $compressedPrefix) { return ($compressedPrefix + 'data') }
            return 'data'
        }
    }
    else {
        try {
            [void]$textEncoding.GetString($contentBytes, 0, $sampleLength)
        }
        catch {
            if ($Mime) { return 'application/octet-stream' }
            if ($null -ne $compressedPrefix) { return ($compressedPrefix + 'data') }
            return 'data'
        }
    }

    if ($Mime) { return ('text/plain; charset={0}' -f $mimeCharset) }
    $lineEnding = ''
    $textSample = $textEncoding.GetString($contentBytes, 0, $sampleLength)
    if ($textSample.Contains("`r`n")) { $lineEnding = ', with CRLF line terminators' }
    elseif ($textSample.Contains("`n")) { $lineEnding = ', with LF line terminators' }
    if ($null -ne $compressedPrefix) {
        return ($compressedPrefix + $encodingName + $lineEnding)
    }
    return ($encodingName + $lineEnding)
}

function file {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: file [-biLz] path ...'
        return
    }

    $brief = $false
    $mime = $false
    $followLinks = $false
    $inspectCompressed = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('b', 'i', 'L', 'z'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'file' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'b') { $brief = $true }
                if ($option -eq 'i') { $mime = $true }
                if ($option -eq 'L') { $followLinks = $true }
                if ($option -eq 'z') { $inspectCompressed = $true }
            }
            continue
        }
        $paths += $argument
    }
    if ($paths.Count -eq 0) {
        Write-PshCommandFailure -Command 'file' -Code 2 -Message 'at least one path is required.'
        return
    }

    try {
        $resolvedPaths = @()
        foreach ($path in $paths) {
            if ($followLinks) {
                $resolvedPaths += Resolve-PshPhysicalFileSystemPath -Path $path
            }
            else {
                $resolvedPaths += Resolve-PshFileSystemPath -Path $path
            }
        }
        for ($index = 0; $index -lt $resolvedPaths.Count; $index++) {
            $classification = Get-PshFileClassification -Path $resolvedPaths[$index] -Mime:$mime -InspectCompressed:$inspectCompressed
            if ($brief) {
                Write-Output $classification
            }
            else {
                Write-Output ('{0}: {1}' -f $paths[$index], $classification)
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'file' -Code 3 -Message $_.Exception.Message
    }
}

function Write-PshTreeChildren {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [int]$Depth,

        [Parameter(Mandatory = $true)]
        [int]$MaximumDepth,

        [switch]$IncludeHidden,

        [switch]$DirectoriesOnly,

        [switch]$FullPath
    )

    if ($Depth -gt $MaximumDepth) {
        return
    }

    $entries = @(Get-PshSortedFileSystemEntries -Path $Path -IncludeHidden:$IncludeHidden)
    if ($DirectoriesOnly) {
        $entries = @($entries | Where-Object { (Get-PshItemTypeName -Item $_) -eq 'directory' })
    }
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        $last = ($index -eq ($entries.Count - 1))
        $branch = '|-- '
        $childPrefix = $Prefix + '|   '
        if ($last) {
            $branch = '`-- '
            $childPrefix = $Prefix + '    '
        }
        $label = [string]$entry.Name
        if ($FullPath) { $label = [string]$entry.FullName }
        Write-Output ($Prefix + $branch + $label)
        if ((Get-PshItemTypeName -Item $entry) -eq 'directory') {
            Write-PshTreeChildren -Path ([string]$entry.FullName) -Prefix $childPrefix -Depth ($Depth + 1) -MaximumDepth $MaximumDepth -IncludeHidden:$IncludeHidden -DirectoriesOnly:$DirectoriesOnly -FullPath:$FullPath
        }
    }
}

function tree {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: tree [-adf] [-L depth] [directory]'
        return
    }

    $includeHidden = $false
    $directoriesOnly = $false
    $fullPath = $false
    $maximumDepth = [int]::MaxValue
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -eq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-L') {
            if (($index + 1) -ge $arguments.Count -or -not [int]::TryParse($arguments[$index + 1], [ref]$maximumDepth) -or $maximumDepth -lt 1) {
                Write-PshCommandFailure -Command 'tree' -Code 2 -Message '-L requires a positive integer.'
                return
            }
            $index++
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('a', 'd', 'f'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'tree' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'a') { $includeHidden = $true }
                if ($option -eq 'd') { $directoriesOnly = $true }
                if ($option -eq 'f') { $fullPath = $true }
            }
            continue
        }
        $paths += $argument
    }
    if ($paths.Count -gt 1) {
        Write-PshCommandFailure -Command 'tree' -Code 2 -Message 'at most one directory is supported.'
        return
    }
    if ($paths.Count -eq 0) { $paths = @('.') }

    try {
        $resolved = Resolve-PshFileSystemPath -Path $paths[0]
        if (-not [IO.Directory]::Exists($resolved)) {
            throw ('not a directory: {0}' -f $paths[0])
        }
        $rootLabel = $paths[0]
        if ($fullPath) { $rootLabel = $resolved }
        Write-Output $rootLabel
        Write-PshTreeChildren -Path $resolved -Prefix '' -Depth 1 -MaximumDepth $maximumDepth -IncludeHidden:$includeHidden -DirectoriesOnly:$directoriesOnly -FullPath:$fullPath
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'tree' -Code 3 -Message $_.Exception.Message
    }
}

function Test-PshExcludedItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [string[]]$Exclude
    )

    foreach ($pattern in @($Exclude)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }
        $wildcard = New-Object System.Management.Automation.WildcardPattern($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if ($wildcard.IsMatch([string]$Item.Name) -or $wildcard.IsMatch($RelativePath.Replace('\', '/'))) {
            return $true
        }
    }
    return $false
}

function Find-PshItem {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string[]]$Path = @('.'),

        [string]$Name = '*',

        [ValidateSet('Wildcard', 'Regex')]
        [string]$PatternMode = 'Wildcard',

        [switch]$IgnoreCase,

        [ValidateSet('Any', 'File', 'Directory', 'Link')]
        [string]$Type = 'Any',

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MinDepth = 0,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxDepth = [int]::MaxValue,

        [string]$Size,

        [Nullable[DateTime]]$ModifiedAfter,

        [Nullable[DateTime]]$ModifiedBefore,

        [switch]$Hidden,

        [string[]]$Exclude = @(),

        [switch]$IncludeRoot
    )

    if ($MinDepth -gt $MaxDepth) {
        throw 'MinDepth cannot be greater than MaxDepth.'
    }

    $hasModifiedAfter = $PSBoundParameters.ContainsKey('ModifiedAfter')
    $hasModifiedBefore = $PSBoundParameters.ContainsKey('ModifiedBefore')

    $sizeConstraint = $null
    if (-not [string]::IsNullOrWhiteSpace($Size)) {
        $sizeConstraint = ConvertFrom-PshSizeExpression -Expression $Size
    }

    $regex = $null
    $wildcard = $null
    if ($PatternMode -eq 'Regex') {
        $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
        if ($IgnoreCase) { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
        $regex = New-Object Text.RegularExpressions.Regex($Name, $options)
    }
    else {
        $options = [System.Management.Automation.WildcardOptions]::CultureInvariant
        if ($IgnoreCase) { $options = $options -bor [System.Management.Automation.WildcardOptions]::IgnoreCase }
        $wildcard = New-Object System.Management.Automation.WildcardPattern($Name, $options)
    }

    $roots = @()
    foreach ($pathValue in $Path) {
        $resolved = Resolve-PshFileSystemPath -Path $pathValue
        if (-not [IO.Directory]::Exists($resolved) -and -not [IO.File]::Exists($resolved)) {
            throw ('search root does not exist: {0}' -f $pathValue)
        }
        $roots += [PSCustomObject]@{ Original = $pathValue; Resolved = $resolved }
    }

    foreach ($root in $roots) {
        $queue = New-Object System.Collections.Queue
        $rootItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath ([string]$root.Resolved) -Force -ErrorAction Stop
        $queue.Enqueue([PSCustomObject]@{ Item = $rootItem; Depth = 0; Relative = '.'; IsRoot = $true })
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $item = $current.Item
            $depth = [int]$current.Depth
            $relative = [string]$current.Relative
            $itemType = Get-PshItemTypeName -Item $item

            $excluded = $false
            if (-not $current.IsRoot) {
                if (-not $Hidden -and (Test-PshHiddenItem -Item $item)) {
                    $excluded = $true
                }
                elseif (Test-PshExcludedItem -Item $item -RelativePath $relative -Exclude $Exclude) {
                    $excluded = $true
                }
            }

            if (-not $excluded -and $depth -lt $MaxDepth -and $itemType -eq 'directory') {
                foreach ($child in @(Get-PshSortedFileSystemEntries -Path ([string]$item.FullName) -IncludeHidden)) {
                    $childRelative = [string]$child.Name
                    if ($relative -ne '.') {
                        $childRelative = Join-Path -Path $relative -ChildPath $child.Name
                    }
                    $queue.Enqueue([PSCustomObject]@{ Item = $child; Depth = ($depth + 1); Relative = $childRelative; IsRoot = $false })
                }
            }

            if ($excluded -or ($current.IsRoot -and -not $IncludeRoot) -or $depth -lt $MinDepth -or $depth -gt $MaxDepth) {
                continue
            }

            $nameMatches = $false
            if ($PatternMode -eq 'Regex') {
                $nameMatches = $regex.IsMatch([string]$item.Name)
            }
            else {
                $nameMatches = $wildcard.IsMatch([string]$item.Name)
            }
            if (-not $nameMatches) {
                continue
            }

            if ($Type -ne 'Any') {
                $expectedType = $Type.ToLowerInvariant()
                if ($itemType -ne $expectedType) {
                    continue
                }
            }

            $length = [long]0
            if ($itemType -eq 'file') { $length = [long]$item.Length }
            if ($null -ne $sizeConstraint -and -not (Test-PshSizeMatch -Length $length -Constraint $sizeConstraint)) {
                continue
            }
            if ($hasModifiedAfter -and $item.LastWriteTime -le [DateTime]$ModifiedAfter) {
                continue
            }
            if ($hasModifiedBefore -and $item.LastWriteTime -ge [DateTime]$ModifiedBefore) {
                continue
            }

            Write-Output ([PSCustomObject][ordered]@{
                Path = [string]$relative
                FullName = [string]$item.FullName
                Name = [string]$item.Name
                ItemType = $itemType
                Length = $length
                LastWriteTimeUtc = [DateTime]$item.LastWriteTimeUtc
                Depth = $depth
                Hidden = [bool](Test-PshHiddenItem -Item $item)
            })
        }
    }
}

function ConvertFrom-PshFindTimeConstraint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Days', 'Minutes')]
        [string]$Unit
    )

    if ($Value -notmatch '^(?<sign>[+-]?)(?<number>[0-9]+)$') {
        throw ('unsupported time constraint "{0}".' -f $Value)
    }
    $count = [double]$Matches.number
    $span = [TimeSpan]::FromDays($count)
    $nextSpan = [TimeSpan]::FromDays($count + 1)
    if ($Unit -eq 'Minutes') {
        $span = [TimeSpan]::FromMinutes($count)
        $nextSpan = [TimeSpan]::FromMinutes($count + 1)
    }

    $now = Get-Date
    switch ([string]$Matches.sign) {
        '+' { return [PSCustomObject]@{ Before = $now.Subtract($nextSpan); After = $null } }
        '-' { return [PSCustomObject]@{ Before = $null; After = $now.Subtract($span) } }
        default { return [PSCustomObject]@{ Before = $now.Subtract($span); After = $now.Subtract($nextSpan) } }
    }
}

function find {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: find [path ...] [-name pattern|-iname pattern] [-type f|d|l] [-mindepth n] [-maxdepth n] [-size n] [-mtime n|-mmin n] [--hidden] [--exclude pattern] [-print|-print0]'
        return
    }

    $predicateNames = @('-name', '-iname', '-type', '-mindepth', '-maxdepth', '-size', '-mtime', '-mmin', '--hidden', '--exclude', '-print', '-print0')
    $paths = @()
    $index = 0
    while ($index -lt $arguments.Count -and $predicateNames -cnotcontains $arguments[$index]) {
        if ($arguments[$index].StartsWith('-')) {
            Write-PshCommandFailure -Command 'find' -Code 2 -Message ('unsupported predicate "{0}".' -f $arguments[$index])
            return
        }
        $paths += $arguments[$index]
        $index++
    }
    if ($paths.Count -eq 0) { $paths = @('.') }

    $name = '*'
    $ignoreCase = $false
    $type = 'Any'
    $minDepth = 0
    $maxDepth = [int]::MaxValue
    $size = $null
    $modifiedAfter = $null
    $modifiedBefore = $null
    $hidden = $false
    $exclude = @()
    $print0 = $false
    while ($index -lt $arguments.Count) {
        $predicate = $arguments[$index]
        $index++
        switch -CaseSensitive ($predicate) {
            { $_ -eq '-name' -or $_ -eq '-iname' } {
                if ($index -ge $arguments.Count) {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message ('{0} requires a pattern.' -f $predicate)
                    return
                }
                $name = $arguments[$index]
                $ignoreCase = ($predicate -eq '-iname')
                $index++
            }
            '-type' {
                if ($index -ge $arguments.Count) {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message '-type requires f, d, or l.'
                    return
                }
                switch ($arguments[$index]) {
                    'f' { $type = 'File' }
                    'd' { $type = 'Directory' }
                    'l' { $type = 'Link' }
                    default {
                        Write-PshCommandFailure -Command 'find' -Code 2 -Message ('unsupported type "{0}".' -f $arguments[$index])
                        return
                    }
                }
                $index++
            }
            { $_ -eq '-mindepth' -or $_ -eq '-maxdepth' } {
                if ($index -ge $arguments.Count) {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message ('{0} requires a non-negative integer.' -f $predicate)
                    return
                }
                $parsedDepth = 0
                if (-not [int]::TryParse($arguments[$index], [ref]$parsedDepth) -or $parsedDepth -lt 0) {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message ('{0} requires a non-negative integer.' -f $predicate)
                    return
                }
                if ($predicate -eq '-mindepth') { $minDepth = $parsedDepth }
                else { $maxDepth = $parsedDepth }
                $index++
            }
            '-size' {
                if ($index -ge $arguments.Count) {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message '-size requires a size expression.'
                    return
                }
                $size = $arguments[$index]
                try { [void](ConvertFrom-PshSizeExpression -Expression $size) }
                catch {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message $_.Exception.Message
                    return
                }
                $index++
            }
            { $_ -eq '-mtime' -or $_ -eq '-mmin' } {
                if ($index -ge $arguments.Count) {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message ('{0} requires an integer constraint.' -f $predicate)
                    return
                }
                try {
                    $unit = 'Days'
                    if ($predicate -eq '-mmin') { $unit = 'Minutes' }
                    $constraint = ConvertFrom-PshFindTimeConstraint -Value $arguments[$index] -Unit $unit
                    if ($null -ne $constraint.After) { $modifiedAfter = [DateTime]$constraint.After }
                    if ($null -ne $constraint.Before) { $modifiedBefore = [DateTime]$constraint.Before }
                }
                catch {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message $_.Exception.Message
                    return
                }
                $index++
            }
            '--hidden' { $hidden = $true }
            '--exclude' {
                if ($index -ge $arguments.Count) {
                    Write-PshCommandFailure -Command 'find' -Code 2 -Message '--exclude requires a pattern.'
                    return
                }
                $exclude += $arguments[$index]
                $index++
            }
            '-print' { }
            '-print0' { $print0 = $true }
            default {
                Write-PshCommandFailure -Command 'find' -Code 2 -Message ('unsupported predicate "{0}".' -f $predicate)
                return
            }
        }
    }

    if ($minDepth -gt $maxDepth) {
        Write-PshCommandFailure -Command 'find' -Code 2 -Message '-mindepth cannot exceed -maxdepth.'
        return
    }

    try {
        $parameters = @{
            Path = @($paths)
            Name = $name
            PatternMode = 'Wildcard'
            Type = $type
            MinDepth = $minDepth
            MaxDepth = $maxDepth
            Hidden = $hidden
            Exclude = @($exclude)
            IncludeRoot = $true
        }
        if ($ignoreCase) { $parameters['IgnoreCase'] = $true }
        if ($null -ne $size) { $parameters['Size'] = $size }
        if ($null -ne $modifiedAfter) { $parameters['ModifiedAfter'] = $modifiedAfter }
        if ($null -ne $modifiedBefore) { $parameters['ModifiedBefore'] = $modifiedBefore }
        $matches = @(Find-PshItem @parameters)
        foreach ($match in $matches) {
            $value = [string]$match.FullName
            if ($print0) { $value += [char]0 }
            Write-Output $value
        }
        if ($matches.Count -eq 0) { Set-PshLastExitCode -Code 1 }
        else { Set-PshLastExitCode -Code 0 }
    }
    catch {
        Write-PshCommandFailure -Command 'find' -Code 3 -Message $_.Exception.Message
    }
}

function Get-PshNativeToolEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $direct = Get-PshPropertyValue -InputObject $Lock -Name $Name
    if ($null -ne $direct) { return $direct }
    $tools = Get-PshPropertyValue -InputObject $Lock -Name 'Tools'
    if ($tools -is [System.Collections.IDictionary]) {
        return (Get-PshPropertyValue -InputObject $tools -Name $Name)
    }
    foreach ($entry in @($tools)) {
        $entryName = Get-PshPropertyValue -InputObject $entry -Name 'Name'
        if ([string]::Equals([string]$entryName, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            return $entry
        }
    }
    return $null
}

function Resolve-PshPinnedNativeTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $lockCandidates = @(
        (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Dependencies') -ChildPath 'native-tools.lock.json'),
        (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Tools') -ChildPath 'native-tools.lock.json')
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

function fd {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0

    if ((Resolve-PshEdition) -eq 'Full') {
        $native = Resolve-PshPinnedNativeTool -Name 'fd'
        if ([int]$native.Code -ne 0) {
            Write-PshCommandFailure -Command 'fd' -Code ([int]$native.Code) -Message ([string]$native.Message)
            return
        }
        try {
            & ([string]$native.Path) @arguments
            $nativeExit = [int]$LASTEXITCODE
            if ($nativeExit -in @(0, 1, 2)) { Set-PshLastExitCode -Code $nativeExit }
            else { Set-PshLastExitCode -Code 3 }
        }
        catch {
            Write-PshCommandFailure -Command 'fd' -Code 3 -Message $_.Exception.Message
        }
        return
    }

    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: fd [-gH0] [-e extension] [-t type] [-d depth] [--min-depth depth] [-S size] [--changed-before duration] [--changed-within duration] [-E pattern] [pattern] [path ...]'
        return
    }

    $glob = $false
    $hidden = $false
    $print0 = $false
    $extension = $null
    $type = 'Any'
    $minDepth = 1
    $maxDepth = [int]::MaxValue
    $size = $null
    $modifiedAfter = $null
    $modifiedBefore = $null
    $exclude = @()
    $positionals = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -cin @('-g', '--glob')) { $glob = $true; continue }
        if ($parseOptions -and $argument -cin @('-H', '--hidden')) { $hidden = $true; continue }
        if ($parseOptions -and $argument -cin @('-0', '--print0')) { $print0 = $true; continue }
        if ($parseOptions -and $argument -cin @('-e', '-t', '--type', '-d', '--max-depth', '--min-depth', '-S', '--size', '--changed-before', '--changed-within', '-E', '--exclude')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'fd' -Code 2 -Message ('option {0} requires a value.' -f $argument)
                return
            }
            $index++
            $value = $arguments[$index]
            if ($argument -ceq '-e') {
                $extension = $value.TrimStart('.')
            }
            elseif ($argument -ceq '-t' -or $argument -ceq '--type') {
                $normalizedType = $value.ToLowerInvariant()
                if ($normalizedType -eq 'f' -or $normalizedType -eq 'file') { $type = 'File' }
                elseif ($normalizedType -eq 'd' -or $normalizedType -eq 'directory') { $type = 'Directory' }
                elseif ($normalizedType -eq 'l' -or $normalizedType -eq 'link') { $type = 'Link' }
                else {
                    Write-PshCommandFailure -Command 'fd' -Code 2 -Message ('unsupported type "{0}".' -f $value)
                    return
                }
            }
            elseif ($argument -ceq '-d' -or $argument -ceq '--max-depth' -or $argument -ceq '--min-depth') {
                $depth = 0
                if (-not [int]::TryParse($value, [ref]$depth) -or $depth -lt 0) {
                    Write-PshCommandFailure -Command 'fd' -Code 2 -Message ('option {0} requires a non-negative integer.' -f $argument)
                    return
                }
                if ($argument -ceq '--min-depth') { $minDepth = $depth }
                else { $maxDepth = $depth }
            }
            elseif ($argument -ceq '-S' -or $argument -ceq '--size') {
                try { [void](ConvertFrom-PshSizeExpression -Expression $value); $size = $value }
                catch {
                    Write-PshCommandFailure -Command 'fd' -Code 2 -Message $_.Exception.Message
                    return
                }
            }
            elseif ($argument -ceq '--changed-before') {
                try { $modifiedBefore = (Get-Date).Subtract((ConvertFrom-PshDuration -Value $value)) }
                catch { Write-PshCommandFailure -Command 'fd' -Code 2 -Message $_.Exception.Message; return }
            }
            elseif ($argument -ceq '--changed-within') {
                try { $modifiedAfter = (Get-Date).Subtract((ConvertFrom-PshDuration -Value $value)) }
                catch { Write-PshCommandFailure -Command 'fd' -Code 2 -Message $_.Exception.Message; return }
            }
            elseif ($argument -ceq '-E' -or $argument -ceq '--exclude') {
                $exclude += $value
            }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            Write-PshCommandFailure -Command 'fd' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
            return
        }
        $positionals += $argument
    }

    if ($minDepth -gt $maxDepth) {
        Write-PshCommandFailure -Command 'fd' -Code 2 -Message '--min-depth cannot exceed --max-depth.'
        return
    }

    $pattern = '.*'
    $paths = @('.')
    if ($positionals.Count -gt 0) {
        $extensionOnlyPathForm = $false
        if (-not [string]::IsNullOrWhiteSpace($extension) -and $positionals.Count -eq 1) {
            try {
                $possibleRoot = Resolve-PshFileSystemPath -Path $positionals[0]
                $extensionOnlyPathForm = [IO.Directory]::Exists($possibleRoot)
            }
            catch {
                $extensionOnlyPathForm = $false
            }
        }
        if ($extensionOnlyPathForm) {
            $paths = @($positionals[0])
        }
        else {
            $pattern = $positionals[0]
            if ($positionals.Count -gt 1) { $paths = @($positionals[1..($positionals.Count - 1)]) }
        }
    }
    $patternMode = 'Regex'
    if ($glob) {
        $patternMode = 'Wildcard'
        if ($pattern -eq '.*') { $pattern = '*' }
    }

    try {
        $parameters = @{
            Path = @($paths)
            Name = $pattern
            PatternMode = $patternMode
            IgnoreCase = $true
            Type = $type
            MinDepth = $minDepth
            MaxDepth = $maxDepth
            Hidden = $hidden
            Exclude = @($exclude)
        }
        if ($null -ne $size) { $parameters['Size'] = $size }
        if ($null -ne $modifiedAfter) { $parameters['ModifiedAfter'] = $modifiedAfter }
        if ($null -ne $modifiedBefore) { $parameters['ModifiedBefore'] = $modifiedBefore }
        $matches = @(Find-PshItem @parameters)
        if (-not [string]::IsNullOrWhiteSpace($extension)) {
            $matches = @($matches | Where-Object {
                [string]::Equals([IO.Path]::GetExtension([string]$_.Name).TrimStart('.'), $extension, [StringComparison]::OrdinalIgnoreCase)
            })
        }
        foreach ($match in $matches) {
            $value = [string]$match.FullName
            if ($print0) { $value += [char]0 }
            Write-Output $value
        }
        if ($matches.Count -eq 0) { Set-PshLastExitCode -Code 1 }
        else { Set-PshLastExitCode -Code 0 }
    }
    catch [ArgumentException] {
        Write-PshCommandFailure -Command 'fd' -Code 2 -Message $_.Exception.Message
    }
    catch {
        Write-PshCommandFailure -Command 'fd' -Code 3 -Message $_.Exception.Message
    }
}

function du {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: du [-ahs] [-d depth|--max-depth depth] [path ...]'
        return
    }

    $all = $false
    $human = $false
    $summarize = $false
    $maximumDepth = [int]::MaxValue
    $maximumDepthSpecified = $false
    $paths = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -eq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -cin @('-d', '--max-depth')) {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'du' -Code 2 -Message ('{0} requires a non-negative integer.' -f $argument)
                return
            }
            $index++
            if (-not [int]::TryParse($arguments[$index], [ref]$maximumDepth) -or $maximumDepth -lt 0) {
                Write-PshCommandFailure -Command 'du' -Code 2 -Message ('{0} requires a non-negative integer.' -f $argument)
                return
            }
            $maximumDepthSpecified = $true
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('a', 'h', 's'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'du' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'a') { $all = $true }
                if ($option -eq 'h') { $human = $true }
                if ($option -eq 's') { $summarize = $true }
            }
            continue
        }
        $paths += $argument
    }
    if (($all -and $summarize) -or
        ($all -and $maximumDepthSpecified) -or
        ($summarize -and $maximumDepthSpecified)) {
        Write-PshCommandFailure -Command 'du' -Code 2 -Message '-a, -s, and --max-depth/-d are mutually exclusive.'
        return
    }
    if ($paths.Count -eq 0) { $paths = @('.') }

    try {
        $resolvedPaths = @()
        foreach ($path in $paths) {
            $resolvedPaths += Resolve-PshFileSystemPath -Path $path
        }
        for ($rootIndex = 0; $rootIndex -lt $resolvedPaths.Count; $rootIndex++) {
            $root = $resolvedPaths[$rootIndex]
            if ([IO.File]::Exists($root)) {
                $length = (New-Object IO.FileInfo($root)).Length
                $sizeText = [string]$length
                if ($human) { $sizeText = Format-PshByteCount -Bytes $length }
                Write-Output ("{0}`t{1}" -f $sizeText, $paths[$rootIndex])
                continue
            }

            if (-not $summarize) {
                $items = @(Find-PshItem -Path $root -Name '*' -PatternMode Wildcard -Type Any -MinDepth 1 -MaxDepth $maximumDepth -Hidden -IncludeRoot:$false)
                foreach ($item in $items) {
                    if ($item.ItemType -eq 'file' -and -not $all) { continue }
                    $length = [long]$item.Length
                    if ($item.ItemType -eq 'directory') { $length = Get-PshDirectorySize -Path ([string]$item.FullName) }
                    $sizeText = [string]$length
                    if ($human) { $sizeText = Format-PshByteCount -Bytes $length }
                    Write-Output ("{0}`t{1}" -f $sizeText, $item.FullName)
                }
            }
            $rootLength = Get-PshDirectorySize -Path $root
            $rootSizeText = [string]$rootLength
            if ($human) { $rootSizeText = Format-PshByteCount -Bytes $rootLength }
            Write-Output ("{0}`t{1}" -f $rootSizeText, $paths[$rootIndex])
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'du' -Code 3 -Message $_.Exception.Message
    }
}

function df {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: df [-hT] [--total] [path ...]'
        return
    }

    $human = $false
    $showType = $false
    $showTotal = $false
    $paths = @()
    $parseOptions = $true
    foreach ($argument in $arguments) {
        if ($parseOptions -and $argument -eq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -ceq '--total') { $showTotal = $true; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('h', 'T'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'df' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'h') { $human = $true }
                if ($option -eq 'T') { $showType = $true }
            }
            continue
        }
        $paths += $argument
    }

    try {
        $drives = @()
        if ($paths.Count -eq 0) {
            foreach ($drive in [IO.DriveInfo]::GetDrives()) {
                try {
                    if ($drive.IsReady) { $drives += $drive }
                }
                catch {
                }
            }
        }
        else {
            $seen = @{}
            foreach ($path in $paths) {
                $resolved = Resolve-PshFileSystemPath -Path $path
                $root = [IO.Path]::GetPathRoot($resolved)
                if ($seen.ContainsKey($root)) { continue }
                $drive = New-Object IO.DriveInfo($root)
                if (-not $drive.IsReady) { throw ('drive is not ready: {0}' -f $root) }
                $drives += $drive
                $seen[$root] = $true
            }
        }

        if ($showType) {
            Write-Output "Filesystem`tType`tSize`tUsed`tAvail`tUse%"
        }
        else {
            Write-Output "Filesystem`tSize`tUsed`tAvail`tUse%"
        }
        $totalSize = [long]0
        $totalUsed = [long]0
        $totalAvailable = [long]0
        foreach ($drive in $drives) {
            $size = [long]$drive.TotalSize
            $available = [long]$drive.AvailableFreeSpace
            $used = $size - $available
            $percent = 0
            if ($size -gt 0) { $percent = [Math]::Round(($used * 100.0) / $size) }
            $sizeText = [string]$size
            $usedText = [string]$used
            $availableText = [string]$available
            if ($human) {
                $sizeText = Format-PshByteCount -Bytes $size
                $usedText = Format-PshByteCount -Bytes $used
                $availableText = Format-PshByteCount -Bytes $available
            }
            if ($showType) {
                Write-Output ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}%" -f $drive.Name, $drive.DriveFormat, $sizeText, $usedText, $availableText, $percent)
            }
            else {
                Write-Output ("{0}`t{1}`t{2}`t{3}`t{4}%" -f $drive.Name, $sizeText, $usedText, $availableText, $percent)
            }
            $totalSize += $size
            $totalUsed += $used
            $totalAvailable += $available
        }
        if ($showTotal) {
            $sizeText = [string]$totalSize
            $usedText = [string]$totalUsed
            $availableText = [string]$totalAvailable
            if ($human) {
                $sizeText = Format-PshByteCount -Bytes $totalSize
                $usedText = Format-PshByteCount -Bytes $totalUsed
                $availableText = Format-PshByteCount -Bytes $totalAvailable
            }
            $percent = 0
            if ($totalSize -gt 0) { $percent = [Math]::Round(($totalUsed * 100.0) / $totalSize) }
            if ($showType) {
                Write-Output ("total`t-`t{0}`t{1}`t{2}`t{3}%" -f $sizeText, $usedText, $availableText, $percent)
            }
            else {
                Write-Output ("total`t{0}`t{1}`t{2}`t{3}%" -f $sizeText, $usedText, $availableText, $percent)
            }
        }
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshCommandFailure -Command 'df' -Code 3 -Message $_.Exception.Message
    }
}

function New-PshRandomName {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Length
    )

    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $bytes = New-Object byte[] $Length
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }
    $builder = New-Object Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.Append($alphabet[[int]$byte % $alphabet.Length])
    }
    return $builder.ToString()
}

function mktemp {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: mktemp [-du] [-p directory|--tmpdir[=directory]] [template]'
        return
    }

    $directoryMode = $false
    $dryRun = $false
    $parentOption = $null
    $operands = @()
    $parseOptions = $true
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($parseOptions -and $argument -eq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument -ceq '-p') {
            if (($index + 1) -ge $arguments.Count) {
                Write-PshCommandFailure -Command 'mktemp' -Code 2 -Message '-p requires a directory.'
                return
            }
            $index++
            $parentOption = $arguments[$index]
            continue
        }
        if ($parseOptions -and $argument -ceq '--tmpdir') {
            $parentOption = [IO.Path]::GetTempPath()
            continue
        }
        if ($parseOptions -and $argument.StartsWith('--tmpdir=')) {
            $parentOption = $argument.Substring('--tmpdir='.Length)
            if ([string]::IsNullOrWhiteSpace($parentOption)) { $parentOption = [IO.Path]::GetTempPath() }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('d', 'u'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command 'mktemp' -Code 2 -Message ('unsupported option "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -eq 'd') { $directoryMode = $true }
                if ($option -eq 'u') { $dryRun = $true }
            }
            continue
        }
        $operands += $argument
    }
    if ($operands.Count -gt 1) {
        Write-PshCommandFailure -Command 'mktemp' -Code 2 -Message 'at most one template is supported.'
        return
    }

    try {
        $template = 'tmp.XXXXXXXXXX'
        if ($operands.Count -eq 1) { $template = $operands[0] }
        $parent = $null
        $leafTemplate = $template
        $returnRelative = $false
        if (-not [string]::IsNullOrWhiteSpace($parentOption)) {
            if ([IO.Path]::IsPathRooted($template) -or -not [string]::IsNullOrEmpty([IO.Path]::GetDirectoryName($template))) {
                throw 'a template used with -p/--tmpdir must not contain a directory.'
            }
            $parent = Resolve-PshFileSystemPath -Path $parentOption
        }
        else {
            $templateResolved = Resolve-PshFileSystemPath -Path $template -AllowMissing
            $parent = [IO.Path]::GetDirectoryName($templateResolved)
            $leafTemplate = [IO.Path]::GetFileName($templateResolved)
            $returnRelative = $operands.Count -eq 1 -and -not [IO.Path]::IsPathRooted($template)
            if ($operands.Count -eq 0) {
                $parent = [IO.Path]::GetTempPath()
            }
        }
        if (-not [IO.Directory]::Exists($parent)) {
            throw ('temporary parent directory does not exist: {0}' -f $parent)
        }
        if ($leafTemplate -notmatch 'X{3,}$') {
            throw 'the template must end with at least three X characters.'
        }
        $placeholderLength = $Matches[0].Length
        $prefix = $leafTemplate.Substring(0, $leafTemplate.Length - $placeholderLength)

        for ($attempt = 0; $attempt -lt 128; $attempt++) {
            $candidate = Join-Path -Path $parent -ChildPath ($prefix + (New-PshRandomName -Length $placeholderLength))
            if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) { continue }
            $displayCandidate = $candidate
            if ($returnRelative) {
                $displayCandidate = Get-PshDisplayPath -OriginalPath $template -ResolvedPath $candidate
            }
            if ($dryRun) {
                Write-Output $displayCandidate
                Set-PshLastExitCode -Code 0
                return
            }
            if ($directoryMode) {
                [void][IO.Directory]::CreateDirectory($candidate)
            }
            else {
                $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                $stream.Dispose()
            }
            Write-Output $displayCandidate
            Set-PshLastExitCode -Code 0
            return
        }
        throw 'could not allocate a unique temporary name after 128 attempts.'
    }
    catch {
        $message = $_.Exception.Message
        if ($message -like 'the template must*' -or $message -like 'a template used*') {
            Write-PshCommandFailure -Command 'mktemp' -Code 2 -Message $message
        }
        else {
            Write-PshCommandFailure -Command 'mktemp' -Code 3 -Message $message
        }
    }
}
