# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# Archive commands are deliberately implemented in PowerShell/.NET so the
# command surface behaves the same on Windows PowerShell 5.1 and pwsh 7.

$script:PshArchiveFormatCommandNames = @('zip', 'unzip')

function Get-PshEnabledArchiveFormatCommandNames {
    $enabled = @()
    foreach ($name in $script:PshArchiveFormatCommandNames) {
        if (-not $script:PshDisabledCommands.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function Throw-PshArchiveUsageError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw (New-Object ArgumentException($Message))
}

function Throw-PshArchiveInvalidData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw (New-Object IO.InvalidDataException($Message))
}

function Test-PshArchiveInvalidDataException {
    param(
        [Parameter(Mandatory = $true)]
        [Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [IO.InvalidDataException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Throw-PshZipValidationError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [switch]$ArchiveContent
    )

    if ($ArchiveContent) { Throw-PshArchiveInvalidData -Message $Message }
    throw $Message
}

function Initialize-PshZipArchiveTypes {
    if ($null -ne [Type]::GetType('System.IO.Compression.ZipArchive, System.IO.Compression', $false)) {
        return
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
}

function New-PshZipArchive {
    param(
        [Parameter(Mandatory = $true)]
        [IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [object]$Mode,

        [Parameter(Mandatory = $true)]
        [Text.Encoding]$Encoding
    )

    return [Activator]::CreateInstance(
        [IO.Compression.ZipArchive],
        [object[]]@($Stream, $Mode, $false, $Encoding)
    )
}

function Get-PshZipUtf8Encoding {
    return (New-Object Text.UTF8Encoding($false, $true))
}

function ConvertTo-PshZipExternalAttributesUInt32 {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    return [BitConverter]::ToUInt32([BitConverter]::GetBytes($Value), 0)
}

function Get-PshZipOptions {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $recursive = $false
    $quiet = $false
    $junkPaths = $false
    $update = $false
    $operands = @()
    $parseOptions = $true

    foreach ($argument in $Arguments) {
        if ($parseOptions -and $argument -ceq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-', [StringComparison]::Ordinal) -and $argument -cne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('r', 'q', 'j', 'u'))
            if ($expanded.Count -eq 0) {
                Throw-PshArchiveUsageError -Message ('unsupported option "{0}".' -f $argument)
            }
            foreach ($option in $expanded) {
                switch -CaseSensitive ($option) {
                    'r' { $recursive = $true }
                    'q' { $quiet = $true }
                    'j' { $junkPaths = $true }
                    'u' { $update = $true }
                }
            }
            continue
        }
        $operands += [string]$argument
    }

    if ($operands.Count -lt 2) {
        Throw-PshArchiveUsageError -Message 'an archive path and at least one input path are required.'
    }

    return [PSCustomObject]@{
        Recursive = $recursive
        Quiet = $quiet
        JunkPaths = $junkPaths
        Update = $update
        ArchivePath = [string]$operands[0]
        InputPaths = [string[]]@($operands[1..($operands.Count - 1)])
    }
}

function Test-PshZipItemIsLinkOrReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    if ((Get-PshItemTypeName -Item $Item) -eq 'link') {
        return $true
    }
    try {
        return (([IO.FileAttributes]$Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    catch {
        return $true
    }
}

function Assert-PshZipEntryName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name,

        [switch]$Directory,

        [switch]$ArchiveContent
    )

    if ([string]::IsNullOrEmpty($Name) -or $Name.IndexOf([char]0) -ge 0) {
        Throw-PshZipValidationError -Message 'ZIP entry names cannot be empty or contain NUL characters.' -ArchiveContent:$ArchiveContent
    }
    if ($Name.IndexOf('\') -ge 0) {
        Throw-PshZipValidationError -Message ('ZIP entry name uses a backslash path separator: {0}' -f $Name) -ArchiveContent:$ArchiveContent
    }
    if ($Name.StartsWith('/', [StringComparison]::Ordinal) -or
        $Name.StartsWith('//', [StringComparison]::Ordinal) -or
        $Name -match '^[A-Za-z]:') {
        Throw-PshZipValidationError -Message ('ZIP entry name must be relative: {0}' -f $Name) -ArchiveContent:$ArchiveContent
    }

    $trimmed = $Name.TrimEnd('/')
    if ([string]::IsNullOrEmpty($trimmed)) {
        Throw-PshZipValidationError -Message ('ZIP entry name must identify a relative path: {0}' -f $Name) -ArchiveContent:$ArchiveContent
    }
    foreach ($component in $trimmed.Split('/')) {
        if ([string]::IsNullOrEmpty($component) -or $component -ceq '.' -or $component -ceq '..') {
            Throw-PshZipValidationError -Message ('ZIP entry name contains an unsafe path component: {0}' -f $Name) -ArchiveContent:$ArchiveContent
        }
        if ($component.IndexOf(':') -ge 0) {
            Throw-PshZipValidationError -Message ('ZIP entry name contains an unsafe drive or stream separator: {0}' -f $Name) -ArchiveContent:$ArchiveContent
        }
    }
    if ($Directory -and -not $Name.EndsWith('/', [StringComparison]::Ordinal)) {
        Throw-PshZipValidationError -Message ('ZIP directory entry must end with a slash: {0}' -f $Name) -ArchiveContent:$ArchiveContent
    }

    $encoding = Get-PshZipUtf8Encoding
    if ($encoding.GetByteCount($Name) -gt [UInt16]::MaxValue) {
        Throw-PshZipValidationError -Message ('ZIP entry name is too long when encoded as UTF-8: {0}' -f $Name) -ArchiveContent:$ArchiveContent
    }
}

function Get-PshZipOperandEntryName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OriginalPath,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedPath,

        [switch]$JunkPaths
    )

    $leaf = [IO.Path]::GetFileName($ResolvedPath.TrimEnd([char[]]@('\', '/')))
    if ([string]::IsNullOrEmpty($leaf)) {
        throw ('cannot derive a ZIP entry name from input path: {0}' -f $OriginalPath)
    }
    if ($JunkPaths -or [IO.Path]::IsPathRooted($OriginalPath)) {
        Assert-PshZipEntryName -Name $leaf
        return $leaf
    }

    $candidate = $OriginalPath.Replace('\', '/').TrimEnd('/')
    while ($candidate.StartsWith('./', [StringComparison]::Ordinal)) {
        $candidate = $candidate.Substring(2)
    }
    if ([string]::IsNullOrEmpty($candidate) -or $candidate -ceq '.') {
        $candidate = $leaf
    }
    Assert-PshZipEntryName -Name $candidate
    return $candidate
}

function Add-PshZipPlanEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$EntryNames,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [switch]$Recursive,

        [switch]$JunkPaths,

        [switch]$ExplicitOperand
    )

    if (Test-PshZipItemIsLinkOrReparsePoint -Item $Item) {
        throw ('symbolic links and reparse points are not supported as ZIP input: {0}' -f $Item.FullName)
    }

    $itemPath = [IO.Path]::GetFullPath([string]$Item.FullName)
    if (Test-PshPathEqual -Left $itemPath -Right $ArchivePath) {
        if ($ExplicitOperand) {
            throw ('the archive cannot also be an input file: {0}' -f $Item.FullName)
        }
        return
    }

    $itemType = Get-PshItemTypeName -Item $Item
    if ($itemType -eq 'directory') {
        if (-not $Recursive) {
            throw ('omitting directory without -r: {0}' -f $Item.FullName)
        }

        if (-not $JunkPaths) {
            $directoryName = $EntryName.TrimEnd('/') + '/'
            Assert-PshZipEntryName -Name $directoryName -Directory
            if ($EntryNames.ContainsKey($directoryName)) {
                throw ('duplicate ZIP entry name: {0}' -f $directoryName)
            }
            $EntryNames.Add($directoryName, $true)
            [void]$Plan.Add([PSCustomObject]@{
                SourcePath = $itemPath
                EntryName = $directoryName
                ItemType = 'directory'
                LastWriteTimeUtc = [DateTime]$Item.LastWriteTimeUtc
            })
        }

        foreach ($child in @(Get-PshSortedFileSystemEntries -Path $itemPath -IncludeHidden)) {
            $childName = [string]$child.Name
            if (-not $JunkPaths) {
                $childName = $EntryName.TrimEnd('/') + '/' + $childName
            }
            Add-PshZipPlanEntry `
                -Item $child `
                -EntryName $childName `
                -Plan $Plan `
                -EntryNames $EntryNames `
                -ArchivePath $ArchivePath `
                -Recursive:$Recursive `
                -JunkPaths:$JunkPaths
        }
        return
    }
    if ($itemType -ne 'file') {
        throw ('unsupported ZIP input type: {0}' -f $Item.FullName)
    }

    Assert-PshZipEntryName -Name $EntryName
    if ($EntryNames.ContainsKey($EntryName)) {
        throw ('duplicate ZIP entry name: {0}' -f $EntryName)
    }
    $EntryNames.Add($EntryName, $true)
    [void]$Plan.Add([PSCustomObject]@{
        SourcePath = $itemPath
        EntryName = $EntryName
        ItemType = 'file'
        LastWriteTimeUtc = [DateTime]$Item.LastWriteTimeUtc
    })
}

function Get-PshZipInputPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InputPaths,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [switch]$Recursive,

        [switch]$JunkPaths
    )

    $plan = New-Object 'System.Collections.Generic.List[object]'
    $entryNames = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    foreach ($inputPath in $InputPaths) {
        $resolved = Resolve-PshFileSystemPath -Path $inputPath
        $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        $entryName = Get-PshZipOperandEntryName -OriginalPath $inputPath -ResolvedPath $resolved -JunkPaths:$JunkPaths
        Add-PshZipPlanEntry `
            -Item $item `
            -EntryName $entryName `
            -Plan $plan `
            -EntryNames $entryNames `
            -ArchivePath $ArchivePath `
            -Recursive:$Recursive `
            -JunkPaths:$JunkPaths `
            -ExplicitOperand
    }
    if ($plan.Count -eq 0) {
        throw 'no input entries remain after ZIP input validation.'
    }
    return @($plan.ToArray())
}

function Test-PshZipEntryIsLinkOrReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $attributes = ConvertTo-PshZipExternalAttributesUInt32 -Value ([int]$Entry.ExternalAttributes)
    $unixType = ($attributes -shr 16) -band [uint32]0xF000
    if ($unixType -eq [uint32]0xA000) {
        return $true
    }
    return (($attributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-PshZipSafeDateTimeOffset {
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$LastWriteTimeUtc
    )

    $utc = $LastWriteTimeUtc.ToUniversalTime()
    $minimum = New-Object DateTime(1980, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $maximum = New-Object DateTime(2107, 12, 31, 23, 59, 58, [DateTimeKind]::Utc)
    if ($utc -lt $minimum) { $utc = $minimum }
    if ($utc -gt $maximum) { $utc = $maximum }
    return (New-Object DateTimeOffset($utc))
}

function Read-PshZipEntryToEnd {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $entryStream = $null
    try {
        $entryStream = $Entry.Open()
        $buffer = New-Object byte[] 81920
        while ($entryStream.Read($buffer, 0, $buffer.Length) -gt 0) {
        }
    }
    finally {
        if ($null -ne $entryStream) { $entryStream.Dispose() }
    }
}

function Assert-PshZipArchiveEntries {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive,

        [switch]$ReadContents
    )

    $names = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    foreach ($entry in @($Archive.Entries)) {
        # Some .NET implementations surface one null sentinel for Entries in
        # Create mode before the first entry is added.
        if ($null -eq $entry) { continue }
        $name = [string]$entry.FullName
        $directory = $name.EndsWith('/', [StringComparison]::Ordinal)
        Assert-PshZipEntryName -Name $name -Directory:$directory -ArchiveContent
        if (Test-PshZipEntryIsLinkOrReparsePoint -Entry $entry) {
            Throw-PshArchiveInvalidData -Message ('symbolic-link or reparse-point ZIP entries are not supported: {0}' -f $name)
        }
        if ($names.ContainsKey($name)) {
            Throw-PshArchiveInvalidData -Message ('duplicate ZIP entry name: {0}' -f $name)
        }
        $names.Add($name, $entry)
        if ($ReadContents -and -not $directory) {
            Read-PshZipEntryToEnd -Entry $entry
        }
    }
    return $names
}

function Add-PshZipFileEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive,

        [Parameter(Mandatory = $true)]
        [object]$PlanEntry
    )

    $sourceItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath ([string]$PlanEntry.SourcePath) -Force -ErrorAction Stop
    if (Test-PshZipItemIsLinkOrReparsePoint -Item $sourceItem) {
        throw ('ZIP input became a symbolic link or reparse point: {0}' -f $PlanEntry.SourcePath)
    }
    if ((Get-PshItemTypeName -Item $sourceItem) -ne 'file') {
        throw ('ZIP input type changed before it could be read: {0}' -f $PlanEntry.SourcePath)
    }

    $entry = $Archive.CreateEntry([string]$PlanEntry.EntryName, [IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = Get-PshZipSafeDateTimeOffset -LastWriteTimeUtc ([DateTime]$sourceItem.LastWriteTimeUtc)
    $sourceStream = $null
    $entryStream = $null
    try {
        $sourceStream = New-Object IO.FileStream(
            [string]$PlanEntry.SourcePath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $entryStream = $entry.Open()
        $sourceStream.CopyTo($entryStream)
    }
    finally {
        if ($null -ne $entryStream) { $entryStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
    }
}

function Install-PshZipArchiveStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagePath,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    if ([IO.Directory]::Exists($ArchivePath)) {
        throw ('archive path is an existing directory: {0}' -f $ArchivePath)
    }
    if (-not [IO.File]::Exists($ArchivePath)) {
        [IO.File]::Move($StagePath, $ArchivePath)
        return
    }

    $backupPath = New-PshSiblingTemporaryPath -Destination $ArchivePath -Purpose 'zip-backup'
    $committed = $false
    try {
        [IO.File]::Replace($StagePath, $ArchivePath, $backupPath)
        $committed = $true
    }
    finally {
        if ($committed -and [IO.File]::Exists($backupPath)) {
            try { [IO.File]::Delete($backupPath) }
            catch { }
        }
        elseif (-not [IO.File]::Exists($ArchivePath) -and [IO.File]::Exists($backupPath)) {
            try { [IO.File]::Move($backupPath, $ArchivePath) }
            catch { }
        }
    }
}

function Invoke-PshZipCommand {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Options
    )

    Initialize-PshZipArchiveTypes
    $archivePath = Resolve-PshFileSystemPath -Path ([string]$Options.ArchivePath) -AllowMissing
    $archiveParent = [IO.Path]::GetDirectoryName($archivePath)
    if ([string]::IsNullOrWhiteSpace($archiveParent) -or -not [IO.Directory]::Exists($archiveParent)) {
        throw ('archive parent directory does not exist: {0}' -f $Options.ArchivePath)
    }
    if ([IO.Directory]::Exists($archivePath)) {
        throw ('archive path is an existing directory: {0}' -f $Options.ArchivePath)
    }
    if ([IO.File]::Exists($archivePath)) {
        $archiveItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $archivePath -Force -ErrorAction Stop
        if (Test-PshZipItemIsLinkOrReparsePoint -Item $archiveItem) {
            throw ('archive path cannot be a symbolic link or reparse point: {0}' -f $Options.ArchivePath)
        }
    }

    $plan = @(Get-PshZipInputPlan `
        -InputPaths ([string[]]$Options.InputPaths) `
        -ArchivePath $archivePath `
        -Recursive:([bool]$Options.Recursive) `
        -JunkPaths:([bool]$Options.JunkPaths))
    $stagePath = New-PshSiblingTemporaryPath -Destination $archivePath -Purpose 'zip-stage'
    try {
        $messages = New-Object 'System.Collections.Generic.List[string]'
        $stageStream = $null
        $archive = $null
        try {
        if ([IO.File]::Exists($archivePath)) {
            [IO.File]::Copy($archivePath, $stagePath, $false)
            $stageStream = New-Object IO.FileStream(
                $stagePath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
            $archive = New-PshZipArchive `
                -Stream $stageStream `
                -Mode ([IO.Compression.ZipArchiveMode]::Update) `
                -Encoding (Get-PshZipUtf8Encoding)
        }
        else {
            $stageStream = New-Object IO.FileStream(
                $stagePath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
            $archive = New-PshZipArchive `
                -Stream $stageStream `
                -Mode ([IO.Compression.ZipArchiveMode]::Create) `
                -Encoding (Get-PshZipUtf8Encoding)
        }

        $existing = Assert-PshZipArchiveEntries -Archive $archive -ReadContents
        foreach ($planEntry in $plan) {
            $entryName = [string]$planEntry.EntryName
            $oldEntry = $null
            if ($existing.ContainsKey($entryName)) {
                $oldEntry = $existing[$entryName]
            }

            if ([bool]$Options.Update -and $null -ne $oldEntry -and [string]$planEntry.ItemType -eq 'file') {
                $sourceTime = ([DateTime]$planEntry.LastWriteTimeUtc).ToUniversalTime()
                if ($sourceTime -le $oldEntry.LastWriteTime.UtcDateTime) {
                    continue
                }
            }

            if ($null -ne $oldEntry) {
                $oldEntry.Delete()
                [void]$existing.Remove($entryName)
            }

            if ([string]$planEntry.ItemType -eq 'directory') {
                $newEntry = $archive.CreateEntry($entryName)
                $newEntry.LastWriteTime = Get-PshZipSafeDateTimeOffset -LastWriteTimeUtc ([DateTime]$planEntry.LastWriteTimeUtc)
            }
            else {
                Add-PshZipFileEntry -Archive $archive -PlanEntry $planEntry
            }
            $verb = if ($null -eq $oldEntry) { 'adding' } else { 'updating' }
            [void]$messages.Add(('{0}: {1}' -f $verb, $entryName))
        }
        }
        finally {
            if ($null -ne $archive) { $archive.Dispose() }
            if ($null -ne $stageStream) { $stageStream.Dispose() }
        }

        $verifyStream = $null
        $verifyArchive = $null
        try {
            $verifyStream = New-Object IO.FileStream(
                $stagePath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            $verifyArchive = New-PshZipArchive `
                -Stream $verifyStream `
                -Mode ([IO.Compression.ZipArchiveMode]::Read) `
                -Encoding (Get-PshZipUtf8Encoding)
            [void](Assert-PshZipArchiveEntries -Archive $verifyArchive -ReadContents)
        }
        finally {
            if ($null -ne $verifyArchive) { $verifyArchive.Dispose() }
            if ($null -ne $verifyStream) { $verifyStream.Dispose() }
        }

        Install-PshZipArchiveStage -StagePath $stagePath -ArchivePath $archivePath

        if (-not [bool]$Options.Quiet) {
            foreach ($message in $messages) {
                Write-Output $message
            }
        }
    }
    finally {
        if ([IO.File]::Exists($stagePath)) {
            try { [IO.File]::Delete($stagePath) }
            catch { }
        }
    }
}

function zip {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: zip [-rqju] archive.zip path ...'
        return
    }

    $options = $null
    try { $options = Get-PshZipOptions -Arguments $arguments }
    catch { Write-PshCommandFailure -Command 'zip' -Code 2 -Message $_.Exception.Message; return }

    try {
        Invoke-PshZipCommand -Options $options
        Set-PshLastExitCode -Code 0
    }
    catch {
        $code = if (Test-PshArchiveInvalidDataException -Exception $_.Exception) { 5 } else { 3 }
        Write-PshCommandFailure -Command 'zip' -Code $code -Message $_.Exception.Message
    }
}

function Get-PshUnzipOptions {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $list = $false
    $quiet = $false
    $overwriteMode = 'Default'
    $destination = $null
    $operands = @()
    $parseOptions = $true

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($parseOptions -and $argument -ceq '--') {
            $parseOptions = $false
            continue
        }
        if ($parseOptions -and $argument -ceq '-d') {
            $index++
            if ($index -ge $Arguments.Count) {
                Throw-PshArchiveUsageError -Message '-d requires a destination directory.'
            }
            $destination = [string]$Arguments[$index]
            if ([string]::IsNullOrEmpty($destination)) {
                Throw-PshArchiveUsageError -Message '-d requires a non-empty destination directory.'
            }
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-d', [StringComparison]::Ordinal) -and $argument.Length -gt 2) {
            $destination = $argument.Substring(2)
            continue
        }
        if ($parseOptions -and $argument.StartsWith('-', [StringComparison]::Ordinal) -and $argument -cne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('l', 'o', 'n', 'q'))
            if ($expanded.Count -eq 0) {
                Throw-PshArchiveUsageError -Message ('unsupported option "{0}".' -f $argument)
            }
            foreach ($option in $expanded) {
                switch -CaseSensitive ($option) {
                    'l' { $list = $true }
                    'o' { $overwriteMode = 'Overwrite' }
                    'n' { $overwriteMode = 'Never' }
                    'q' { $quiet = $true }
                }
            }
            continue
        }
        $operands += $argument
    }

    if ($operands.Count -ne 1) {
        Throw-PshArchiveUsageError -Message 'exactly one ZIP archive path is required.'
    }
    return [PSCustomObject]@{
        ArchivePath = [string]$operands[0]
        Destination = $destination
        List = $list
        Quiet = $quiet
        OverwriteMode = $overwriteMode
    }
}

function Get-PshZipEntryKind {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $name = [string]$Entry.FullName
    $attributes = ConvertTo-PshZipExternalAttributesUInt32 -Value ([int]$Entry.ExternalAttributes)
    $unixType = ($attributes -shr 16) -band [uint32]0xF000
    if ($unixType -eq [uint32]0xA000 -or
        ($attributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-PshArchiveInvalidData -Message ('symbolic-link or reparse-point ZIP entries are not supported: {0}' -f $name)
    }
    if ($unixType -ne 0 -and
        $unixType -ne [uint32]0x4000 -and
        $unixType -ne [uint32]0x8000) {
        Throw-PshArchiveInvalidData -Message ('special-device ZIP entries are not supported: {0}' -f $name)
    }

    $nameIsDirectory = $name.EndsWith('/', [StringComparison]::Ordinal)
    $attributeIsDirectory = $unixType -eq [uint32]0x4000 -or
        ($attributes -band [uint32][IO.FileAttributes]::Directory) -ne 0
    if ($attributeIsDirectory -and -not $nameIsDirectory) {
        Throw-PshArchiveInvalidData -Message ('ZIP directory entry does not end with a slash: {0}' -f $name)
    }
    if ($nameIsDirectory) {
        if ([long]$Entry.Length -ne 0) {
            Throw-PshArchiveInvalidData -Message ('ZIP directory entry contains file data: {0}' -f $name)
        }
        return 'directory'
    }
    return 'file'
}

function Get-PshUnzipPathDictionary {
    $comparer = [StringComparer]::Ordinal
    if ($env:OS -eq 'Windows_NT' -or [IO.Path]::DirectorySeparatorChar -eq '\') {
        $comparer = [StringComparer]::OrdinalIgnoreCase
    }
    return [Activator]::CreateInstance(
        [Collections.Generic.Dictionary[string,object]],
        [object[]]@($comparer)
    )
}

function Get-PshUnzipTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [string]$EntryName
    )

    $target = $DestinationRoot
    foreach ($component in $EntryName.TrimEnd('/').Split('/')) {
        $target = [IO.Path]::Combine($target, $component)
    }
    $target = [IO.Path]::GetFullPath($target)
    if (-not (Test-PshPathWithin -Candidate $target -Parent $DestinationRoot)) {
        Throw-PshArchiveInvalidData -Message ('ZIP entry escapes the destination directory: {0}' -f $EntryName)
    }
    return $target
}

function Assert-PshUnzipPathChain {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$LeafMayBeFile
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $relative = $fullPath.Substring($root.Length).Trim([char[]]@('\', '/'))
    $current = $root
    $components = @()
    if (-not [string]::IsNullOrEmpty($relative)) {
        $components = @($relative -split '[\\/]')
    }

    for ($index = 0; $index -lt $components.Count; $index++) {
        $current = [IO.Path]::Combine($current, [string]$components[$index])
        if (-not [IO.File]::Exists($current) -and -not [IO.Directory]::Exists($current)) {
            continue
        }
        $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (Test-PshZipItemIsLinkOrReparsePoint -Item $item) {
            throw ('extraction path contains a symbolic link or reparse point: {0}' -f $current)
        }
        $isLeaf = $index -eq ($components.Count - 1)
        if ((Get-PshItemTypeName -Item $item) -ne 'directory' -and -not ($isLeaf -and $LeafMayBeFile)) {
            throw ('extraction path component is not a directory: {0}' -f $current)
        }
    }
}

function Get-PshUnzipFileFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = $null
    $algorithm = $null
    try {
        $stream = New-Object IO.FileStream(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $algorithm = [Security.Cryptography.SHA256]::Create()
        $hash = $algorithm.ComputeHash($stream)
        return ('{0}:{1}' -f $stream.Length, [Convert]::ToBase64String($hash))
    }
    finally {
        if ($null -ne $algorithm) { $algorithm.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-PshUnzipEntryPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Default', 'Overwrite', 'Never')]
        [string]$OverwriteMode
    )

    Assert-PshUnzipPathChain -Path $DestinationRoot
    if ([IO.File]::Exists($DestinationRoot)) {
        throw ('extraction destination is an existing file: {0}' -f $DestinationRoot)
    }

    $claims = Get-PshUnzipPathDictionary
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Archive.Entries)) {
        $name = [string]$entry.FullName
        $kind = Get-PshZipEntryKind -Entry $entry
        Assert-PshZipEntryName -Name $name -Directory:($kind -eq 'directory') -ArchiveContent
        $target = Get-PshUnzipTargetPath -DestinationRoot $DestinationRoot -EntryName $name
        if (Test-PshPathEqual -Left $target -Right $ArchivePath) {
            Throw-PshArchiveInvalidData -Message ('refusing to overwrite the ZIP archive while extracting entry: {0}' -f $name)
        }

        $relative = $name.TrimEnd('/').Split('/')
        $ancestor = $DestinationRoot
        for ($componentIndex = 0; $componentIndex -lt ($relative.Count - 1); $componentIndex++) {
            $ancestor = [IO.Path]::Combine($ancestor, [string]$relative[$componentIndex])
            $ancestor = [IO.Path]::GetFullPath($ancestor)
            if ($claims.ContainsKey($ancestor)) {
                if ([string]$claims[$ancestor].Kind -eq 'file') {
                    Throw-PshArchiveInvalidData -Message ('ZIP file entry is also used as a parent directory: {0}' -f $claims[$ancestor].Name)
                }
            }
            else {
                $claims.Add($ancestor, [PSCustomObject]@{ Kind = 'directory'; Explicit = $false; Name = $name })
            }
        }

        if ($claims.ContainsKey($target)) {
            $claim = $claims[$target]
            if ([bool]$claim.Explicit -or [string]$claim.Kind -ne $kind -or $kind -eq 'file') {
                Throw-PshArchiveInvalidData -Message ('duplicate or conflicting ZIP output path: {0}' -f $name)
            }
            $claim.Explicit = $true
            $claim.Name = $name
        }
        else {
            $claims.Add($target, [PSCustomObject]@{ Kind = $kind; Explicit = $true; Name = $name })
        }

        Assert-PshUnzipPathChain -Path $target -LeafMayBeFile:($kind -eq 'file')
        $action = if ($kind -eq 'directory') { 'Directory' } else { 'Extract' }
        $fingerprint = $null
        if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) {
            $targetItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $target -Force -ErrorAction Stop
            if (Test-PshZipItemIsLinkOrReparsePoint -Item $targetItem) {
                throw ('refusing to extract through a symbolic link or reparse point: {0}' -f $target)
            }
            $targetType = Get-PshItemTypeName -Item $targetItem
            if ($kind -eq 'directory') {
                if ($targetType -ne 'directory') {
                    throw ('ZIP directory entry conflicts with an existing file: {0}' -f $name)
                }
                $action = 'Directory'
            }
            else {
                if ($targetType -ne 'file') {
                    throw ('ZIP file entry conflicts with an existing directory: {0}' -f $name)
                }
                if ($OverwriteMode -eq 'Never') {
                    $action = 'Skip'
                }
                elseif ($OverwriteMode -eq 'Overwrite') {
                    $fingerprint = Get-PshUnzipFileFingerprint -Path $target
                }
                else {
                    throw ('output file already exists; use -o to overwrite or -n to skip: {0}' -f $target)
                }
            }
        }

        [void]$plan.Add([PSCustomObject]@{
            Entry = $entry
            EntryName = $name
            Kind = $kind
            TargetPath = $target
            Action = $action
            ExistingFingerprint = $fingerprint
            StagePath = $null
        })
    }
    return @($plan.ToArray())
}

function New-PshUnzipStageRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    $candidateParent = if ([IO.Directory]::Exists($DestinationRoot)) {
        [IO.Path]::GetDirectoryName($DestinationRoot.TrimEnd([char[]]@('\', '/')))
    }
    else {
        [IO.Path]::GetDirectoryName($DestinationRoot)
    }
    if ([string]::IsNullOrWhiteSpace($candidateParent)) {
        $candidateParent = [IO.Path]::GetPathRoot($DestinationRoot)
    }
    while (-not [IO.Directory]::Exists($candidateParent)) {
        $next = [IO.Path]::GetDirectoryName($candidateParent.TrimEnd([char[]]@('\', '/')))
        if ([string]::IsNullOrWhiteSpace($next) -or $next -ceq $candidateParent) {
            throw ('cannot locate an existing parent for extraction destination: {0}' -f $DestinationRoot)
        }
        $candidateParent = $next
    }
    Assert-PshUnzipPathChain -Path $candidateParent

    do {
        $stageRoot = Join-Path -Path $candidateParent -ChildPath ('.psh-unzip-stage-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    } while ([IO.File]::Exists($stageRoot) -or [IO.Directory]::Exists($stageRoot))
    [void][IO.Directory]::CreateDirectory($stageRoot)
    return $stageRoot
}

function Expand-PshUnzipEntriesToStage {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Plan,

        [Parameter(Mandatory = $true)]
        [string]$StageRoot
    )

    foreach ($planEntry in $Plan) {
        if ([string]$planEntry.Action -ne 'Extract') {
            continue
        }

        $stagePath = Get-PshUnzipTargetPath -DestinationRoot $StageRoot -EntryName ([string]$planEntry.EntryName)
        $stageParent = [IO.Path]::GetDirectoryName($stagePath)
        [void][IO.Directory]::CreateDirectory($stageParent)
        $entryStream = $null
        $stageStream = $null
        try {
            $entryStream = $planEntry.Entry.Open()
            $stageStream = New-Object IO.FileStream(
                $stagePath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            $entryStream.CopyTo($stageStream)
        }
        finally {
            if ($null -ne $stageStream) { $stageStream.Dispose() }
            if ($null -ne $entryStream) { $entryStream.Dispose() }
        }

        $stagedLength = (New-Object IO.FileInfo($stagePath)).Length
        if ($stagedLength -ne [long]$planEntry.Entry.Length) {
            throw ('extracted ZIP entry length does not match its metadata: {0}' -f $planEntry.EntryName)
        }
        [IO.File]::SetLastWriteTimeUtc($stagePath, $planEntry.Entry.LastWriteTime.UtcDateTime)
        $planEntry.StagePath = $stagePath
    }
}

function Get-PshUnzipCommitDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Plan,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    $directories = Get-PshUnzipPathDictionary
    foreach ($planEntry in $Plan) {
        $directory = if ([string]$planEntry.Kind -eq 'directory') {
            [string]$planEntry.TargetPath
        }
        else {
            [IO.Path]::GetDirectoryName([string]$planEntry.TargetPath)
        }
        while (-not [string]::IsNullOrWhiteSpace($directory) -and
            ((Test-PshPathEqual -Left $directory -Right $DestinationRoot) -or
             (Test-PshPathWithin -Candidate $directory -Parent $DestinationRoot))) {
            if (-not $directories.ContainsKey($directory)) {
                $directories.Add($directory, $true)
            }
            if (Test-PshPathEqual -Left $directory -Right $DestinationRoot) {
                break
            }
            $directory = [IO.Path]::GetDirectoryName($directory)
        }
    }

    $directory = $DestinationRoot
    while (-not [IO.Directory]::Exists($directory)) {
        if (-not $directories.ContainsKey($directory)) {
            $directories.Add($directory, $true)
        }
        $parent = [IO.Path]::GetDirectoryName($directory.TrimEnd([char[]]@('\', '/')))
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $directory) { break }
        $directory = $parent
    }
    return @($directories.Keys | Microsoft.PowerShell.Utility\Sort-Object -Property Length)
}

function Invoke-PshUnzipCommit {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Plan,

        [Parameter(Mandatory = $true)]
        [string[]]$Directories
    )

    $createdDirectories = New-Object 'System.Collections.Generic.List[string]'
    $committedFiles = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($directory in $Directories) {
            if ([IO.Directory]::Exists($directory)) {
                Assert-PshUnzipPathChain -Path $directory
                continue
            }
            if ([IO.File]::Exists($directory)) {
                throw ('cannot create extraction directory over an existing file: {0}' -f $directory)
            }
            [void][IO.Directory]::CreateDirectory($directory)
            [void]$createdDirectories.Add($directory)
        }

        foreach ($planEntry in $Plan) {
            if ([string]$planEntry.Action -ne 'Extract') {
                continue
            }
            $target = [string]$planEntry.TargetPath
            Assert-PshUnzipPathChain -Path $target -LeafMayBeFile
            if ($null -ne $planEntry.ExistingFingerprint) {
                if (-not [IO.File]::Exists($target)) {
                    throw ('an overwrite target disappeared before commit: {0}' -f $target)
                }
                $currentFingerprint = Get-PshUnzipFileFingerprint -Path $target
                if (-not [string]::Equals($currentFingerprint, [string]$planEntry.ExistingFingerprint, [StringComparison]::Ordinal)) {
                    throw ('an overwrite target changed before commit: {0}' -f $target)
                }
                $targetItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $target -Force -ErrorAction Stop
                if (Test-PshZipItemIsLinkOrReparsePoint -Item $targetItem) {
                    throw ('an overwrite target became a symbolic link or reparse point: {0}' -f $target)
                }

                $backup = New-PshSiblingTemporaryPath -Destination $target -Purpose 'unzip-backup'
                [IO.File]::Replace([string]$planEntry.StagePath, $target, $backup)
                [void]$committedFiles.Add([PSCustomObject]@{
                    TargetPath = $target
                    BackupPath = $backup
                    Replaced = $true
                })
            }
            else {
                if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) {
                    throw ('an extraction target appeared before commit: {0}' -f $target)
                }
                [IO.File]::Move([string]$planEntry.StagePath, $target)
                [void]$committedFiles.Add([PSCustomObject]@{
                    TargetPath = $target
                    BackupPath = $null
                    Replaced = $false
                })
            }
        }
    }
    catch {
        $commitError = $_.Exception
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        for ($index = $committedFiles.Count - 1; $index -ge 0; $index--) {
            $record = $committedFiles[$index]
            try {
                if ([bool]$record.Replaced) {
                    if ([IO.File]::Exists([string]$record.TargetPath)) {
                        $discard = New-PshSiblingTemporaryPath -Destination ([string]$record.TargetPath) -Purpose 'unzip-rollback'
                        [IO.File]::Replace([string]$record.BackupPath, [string]$record.TargetPath, $discard)
                        if ([IO.File]::Exists($discard)) { [IO.File]::Delete($discard) }
                    }
                    elseif ([IO.File]::Exists([string]$record.BackupPath)) {
                        [IO.File]::Move([string]$record.BackupPath, [string]$record.TargetPath)
                    }
                }
                elseif ([IO.File]::Exists([string]$record.TargetPath)) {
                    [IO.File]::Delete([string]$record.TargetPath)
                }
            }
            catch {
                [void]$rollbackErrors.Add($_.Exception.Message)
            }
        }
        for ($index = $createdDirectories.Count - 1; $index -ge 0; $index--) {
            try {
                if ([IO.Directory]::Exists($createdDirectories[$index]) -and
                    [IO.Directory]::GetFileSystemEntries($createdDirectories[$index]).Length -eq 0) {
                    [IO.Directory]::Delete($createdDirectories[$index], $false)
                }
            }
            catch {
                [void]$rollbackErrors.Add($_.Exception.Message)
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw (New-Object IO.IOException(
                ('extraction commit failed ({0}); rollback also failed ({1}).' -f $commitError.Message, ($rollbackErrors -join '; ')),
                $commitError
            ))
        }
        throw (New-Object IO.IOException(
            ('extraction commit failed; all committed targets were rolled back: {0}' -f $commitError.Message),
            $commitError
        ))
    }

    foreach ($record in $committedFiles) {
        if ([bool]$record.Replaced -and [IO.File]::Exists([string]$record.BackupPath)) {
            try { [IO.File]::Delete([string]$record.BackupPath) }
            catch { }
        }
    }
}

function Write-PshUnzipListing {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive,

        [Parameter(Mandatory = $true)]
        [string]$DisplayPath,

        [switch]$Quiet
    )

    $rows = New-Object 'System.Collections.Generic.List[string]'
    [long]$totalLength = 0
    foreach ($entry in @($Archive.Entries)) {
        $kind = Get-PshZipEntryKind -Entry $entry
        Assert-PshZipEntryName -Name ([string]$entry.FullName) -Directory:($kind -eq 'directory') -ArchiveContent
        $totalLength += [long]$entry.Length
        if ($Quiet) {
            [void]$rows.Add([string]$entry.FullName)
        }
        else {
            $timestamp = $entry.LastWriteTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            [void]$rows.Add(('{0,9}  {1}   {2}' -f [long]$entry.Length, $timestamp, [string]$entry.FullName))
        }
    }

    if (-not $Quiet) {
        Write-Output ('Archive:  {0}' -f $DisplayPath)
        Write-Output '  Length      Date Time            Name'
        Write-Output '---------  -------------------     ----'
    }
    foreach ($row in $rows) { Write-Output $row }
    if (-not $Quiet) {
        Write-Output '---------                          -------'
        Write-Output ('{0,9}                          {1} files' -f $totalLength, $Archive.Entries.Count)
    }
}

function Invoke-PshUnzipCommand {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Options
    )

    Initialize-PshZipArchiveTypes
    $archivePath = Resolve-PshFileSystemPath -Path ([string]$Options.ArchivePath)
    if (-not [IO.File]::Exists($archivePath)) {
        throw ('ZIP archive is not a file: {0}' -f $Options.ArchivePath)
    }
    $archiveItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $archivePath -Force -ErrorAction Stop
    if (Test-PshZipItemIsLinkOrReparsePoint -Item $archiveItem) {
        throw ('ZIP archive cannot be a symbolic link or reparse point: {0}' -f $Options.ArchivePath)
    }

    $archiveStream = $null
    $archive = $null
    $stageRoot = $null
    try {
        $archiveStream = New-Object IO.FileStream(
            $archivePath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $archive = New-PshZipArchive `
            -Stream $archiveStream `
            -Mode ([IO.Compression.ZipArchiveMode]::Read) `
            -Encoding (Get-PshZipUtf8Encoding)
        [void](Assert-PshZipArchiveEntries -Archive $archive)

        if ([bool]$Options.List) {
            Write-PshUnzipListing -Archive $archive -DisplayPath ([string]$Options.ArchivePath) -Quiet:([bool]$Options.Quiet)
            return
        }

        $requestedDestination = if ([string]::IsNullOrEmpty([string]$Options.Destination)) {
            [IO.Path]::GetFullPath([string](Get-Location).ProviderPath)
        }
        else {
            Resolve-PshFileSystemPath -Path ([string]$Options.Destination) -AllowMissing
        }
        $destinationRoot = Resolve-PshPhysicalFileSystemPath -Path $requestedDestination -AllowMissing
        $plan = @(Get-PshUnzipEntryPlan `
            -Archive $archive `
            -ArchivePath $archivePath `
            -DestinationRoot $destinationRoot `
            -OverwriteMode ([string]$Options.OverwriteMode))
        $stageRoot = New-PshUnzipStageRoot -DestinationRoot $destinationRoot
        Expand-PshUnzipEntriesToStage -Plan $plan -StageRoot $stageRoot
        $directories = @(Get-PshUnzipCommitDirectories -Plan $plan -DestinationRoot $destinationRoot)

        $archive.Dispose()
        $archive = $null
        $archiveStream.Dispose()
        $archiveStream = $null

        Invoke-PshUnzipCommit -Plan $plan -Directories $directories
        if (-not [bool]$Options.Quiet) {
            foreach ($planEntry in $plan) {
                if ([string]$planEntry.Action -eq 'Extract') {
                    Write-Output ('extracting: {0}' -f $planEntry.EntryName)
                }
                elseif ([string]$planEntry.Action -eq 'Skip') {
                    Write-Output ('skipping: {0}' -f $planEntry.EntryName)
                }
            }
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $archiveStream) { $archiveStream.Dispose() }
        if ($null -ne $stageRoot -and [IO.Directory]::Exists($stageRoot)) {
            try { [IO.Directory]::Delete($stageRoot, $true) }
            catch { }
        }
    }
}

function unzip {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: unzip [-lonq] archive.zip [-d directory]'
        return
    }

    $options = $null
    try { $options = Get-PshUnzipOptions -Arguments $arguments }
    catch { Write-PshCommandFailure -Command 'unzip' -Code 2 -Message $_.Exception.Message; return }

    try {
        Invoke-PshUnzipCommand -Options $options
        Set-PshLastExitCode -Code 0
    }
    catch {
        $code = if (Test-PshArchiveInvalidDataException -Exception $_.Exception) { 5 } else { 3 }
        Write-PshCommandFailure -Command 'unzip' -Code $code -Message $_.Exception.Message
    }
}
