# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$GoldenRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$moduleManifest = Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-goal3-batch4-archive-{0}' -f [Guid]::NewGuid().ToString('N'))
$configRoot = Join-Path $testRoot 'local app data'
$emptyPathRoot = Join-Path $testRoot 'empty native path'
$originalLocation = (Get-Location).ProviderPath
$originalLocalAppData = $env:LOCALAPPDATA
$originalEdition = $env:PSH_EDITION
$originalPath = $env:PATH
$utf8NoBom = New-Object Text.UTF8Encoding($false, $true)
$assertionCount = 0
$covered = @{}
$archiveCommandNames = @('tar', 'zip', 'unzip', 'gzip', 'gunzip', 'sha256sum', 'md5sum')
$nativeTarPath = $null
$nativeGzipPath = $null

function Assert-PshBatch4Archive {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw ('Goal 3 Batch 4 archive assertion failed: {0}' -f $Message) }
    $script:assertionCount++
}

function Invoke-PshBatch4ArchiveCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [AllowNull()][object[]]$PipelineInput,
        [switch]$UsePipeline
    )

    $module = Get-Module -Name Psh -ErrorAction Stop
    & $module {
        if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
        $script:PshRawByteSink = New-Object IO.MemoryStream
    }
    try {
        $command = Get-Command -Name ('Psh\{0}' -f $Name) -CommandType Function -ErrorAction Stop
        $global:LASTEXITCODE = 0
        if ($UsePipeline) {
            $output = @(
                & {
                    foreach ($item in @($PipelineInput)) { ,$item }
                } | & $command @Arguments
            )
        }
        else {
            $output = @(& $command @Arguments)
        }
        $exitCode = [int]$global:LASTEXITCODE
        $rawBase64 = & $module { [Convert]::ToBase64String($script:PshRawByteSink.ToArray()) }
        $rawBytes = [byte[]][Convert]::FromBase64String([string]$rawBase64)
        foreach ($value in $output) {
            $typeName = if ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
            Assert-PshBatch4Archive ($value -is [string]) ('{0} leaked a non-string object of type {1}.' -f $Name, $typeName)
        }
        $script:covered[$Name] = $true
        return [PSCustomObject]@{
            Output = @($output | ForEach-Object { [string]$_ })
            RawBytes = $rawBytes
            ExitCode = $exitCode
        }
    }
    finally {
        & $module {
            if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
            $script:PshRawByteSink = $null
        }
    }
}

function Assert-PshBatch4ArchiveSuccess {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-PshBatch4Archive ($Result.ExitCode -eq 0) ('{0} exited {1}: {2}' -f $Context, $Result.ExitCode, ($Result.Output -join ' | '))
}

function Test-PshBatch4ByteSequence {
    param(
        [AllowNull()][byte[]]$Left,
        [AllowNull()][byte[]]$Right
    )

    [byte[]]$leftValues = @()
    [byte[]]$rightValues = @()
    if ($null -ne $Left) { $leftValues = [byte[]]$Left }
    if ($null -ne $Right) { $rightValues = [byte[]]$Right }
    if ($leftValues.Length -ne $rightValues.Length) { return $false }
    for ($index = 0; $index -lt $leftValues.Length; $index++) {
        if ($leftValues[$index] -ne $rightValues[$index]) { return $false }
    }
    return $true
}

function Test-PshBatch4StringArray {
    param(
        [AllowNull()][object[]]$Actual,
        [AllowNull()][string[]]$Expected
    )

    $actualValues = @($Actual | ForEach-Object { [string]$_ })
    $expectedValues = @($Expected | ForEach-Object { [string]$_ })
    if ($actualValues.Count -ne $expectedValues.Count) { return $false }
    for ($index = 0; $index -lt $actualValues.Count; $index++) {
        if (-not [string]::Equals($actualValues[$index], $expectedValues[$index], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Get-PshBatch4HashHex {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('SHA256', 'MD5')][string]$Algorithm,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $stream = New-Object IO.MemoryStream(,$Bytes)
    $hasher = if ($Algorithm -ceq 'SHA256') { [Security.Cryptography.SHA256]::Create() } else { [Security.Cryptography.MD5]::Create() }
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Get-PshBatch4TransactionArtifacts {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not [IO.Directory]::Exists($Root)) { return @() }
    return @(
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith('.psh-', [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { [string]$_.FullName }
    )
}

function Assert-PshBatch4NoTransactionArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $artifacts = @(Get-PshBatch4TransactionArtifacts -Root $Root)
    Assert-PshBatch4Archive ($artifacts.Count -eq 0) ('{0} left transaction artifacts: {1}' -f $Context, ($artifacts -join ' | '))
}

function Set-PshBatch4TarBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Destination,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Value
    )

    if ($Value.Length -gt $Length) { throw 'Test TAR field is too long.' }
    if ($Value.Length -gt 0) { [Array]::Copy($Value, 0, $Destination, $Offset, $Value.Length) }
}

function Set-PshBatch4TarOctal {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Header,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][long]$Value
    )

    $text = [Convert]::ToString($Value, 8).PadLeft($Length - 1, '0') + [char]0
    Set-PshBatch4TarBytes -Destination $Header -Offset $Offset -Length $Length -Value ([Text.Encoding]::ASCII.GetBytes($text))
}

function New-PshBatch4TarHeader {
    param([Parameter(Mandatory = $true)][object]$Entry)

    $name = [string]$Entry.Name
    $typeFlag = '0'
    if ($null -ne $Entry.PSObject.Properties['TypeFlag']) { $typeFlag = [string]$Entry.TypeFlag }
    [byte[]]$data = @()
    if ($null -ne $Entry.PSObject.Properties['Data'] -and $null -ne $Entry.Data) { $data = [byte[]]$Entry.Data }
    $size = if ($typeFlag -ceq '5') { 0 } else { $data.Length }

    $header = New-Object byte[] 512
    Set-PshBatch4TarBytes -Destination $header -Offset 0 -Length 100 -Value ($utf8NoBom.GetBytes($name))
    Set-PshBatch4TarOctal -Header $header -Offset 100 -Length 8 -Value 420
    Set-PshBatch4TarOctal -Header $header -Offset 108 -Length 8 -Value 0
    Set-PshBatch4TarOctal -Header $header -Offset 116 -Length 8 -Value 0
    Set-PshBatch4TarOctal -Header $header -Offset 124 -Length 12 -Value $size
    Set-PshBatch4TarOctal -Header $header -Offset 136 -Length 12 -Value 0
    for ($index = 148; $index -lt 156; $index++) { $header[$index] = 32 }
    $header[156] = [byte][char]$typeFlag[0]
    if ($null -ne $Entry.PSObject.Properties['LinkName'] -and -not [string]::IsNullOrEmpty([string]$Entry.LinkName)) {
        Set-PshBatch4TarBytes -Destination $header -Offset 157 -Length 100 -Value ($utf8NoBom.GetBytes([string]$Entry.LinkName))
    }
    Set-PshBatch4TarBytes -Destination $header -Offset 257 -Length 6 -Value ([byte[]](117, 115, 116, 97, 114, 0))
    Set-PshBatch4TarBytes -Destination $header -Offset 263 -Length 2 -Value ([Text.Encoding]::ASCII.GetBytes('00'))

    [long]$checksum = 0
    foreach ($value in $header) { $checksum += $value }
    $checksumText = [Convert]::ToString($checksum, 8).PadLeft(6, '0') + [char]0 + ' '
    Set-PshBatch4TarBytes -Destination $header -Offset 148 -Length 8 -Value ([Text.Encoding]::ASCII.GetBytes($checksumText))
    return ,([byte[]]$header)
}

function New-PshBatch4TarArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Entries
    )

    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        foreach ($entry in $Entries) {
            $header = [byte[]](New-PshBatch4TarHeader -Entry $entry)
            $stream.Write($header, 0, $header.Length)
            [byte[]]$data = @()
            if ($null -ne $entry.PSObject.Properties['Data'] -and $null -ne $entry.Data) { $data = [byte[]]$entry.Data }
            if ($data.Length -gt 0) { $stream.Write($data, 0, $data.Length) }
            $padding = [int]((512 - ($data.Length % 512)) % 512)
            if ($padding -gt 0) {
                $paddingBytes = New-Object byte[] $padding
                $stream.Write($paddingBytes, 0, $paddingBytes.Length)
            }
        }
        $end = New-Object byte[] 1024
        $stream.Write($end, 0, $end.Length)
    }
    finally { $stream.Dispose() }
}

function Initialize-PshBatch4ZipTypes {
    if ($null -eq [Type]::GetType('System.IO.Compression.ZipArchive, System.IO.Compression', $false)) {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    }
}

function New-PshBatch4ZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Entries
    )

    Initialize-PshBatch4ZipTypes
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = $null
    try {
        $archive = [Activator]::CreateInstance(
            [IO.Compression.ZipArchive],
            [object[]]@(
                ([IO.Stream]$stream),
                ([object][IO.Compression.ZipArchiveMode]::Create),
                ([bool]$false),
                ([Text.Encoding]$utf8NoBom)
            )
        )
        foreach ($entrySpec in $Entries) {
            $entry = $archive.CreateEntry([string]$entrySpec.Name)
            if ($null -ne $entrySpec.PSObject.Properties['ExternalAttributes']) {
                $entry.ExternalAttributes = [int]$entrySpec.ExternalAttributes
            }
            [byte[]]$data = @()
            if ($null -ne $entrySpec.PSObject.Properties['Data'] -and $null -ne $entrySpec.Data) { $data = [byte[]]$entrySpec.Data }
            if ($data.Length -gt 0) {
                $entryStream = $entry.Open()
                try { $entryStream.Write($data, 0, $data.Length) }
                finally { $entryStream.Dispose() }
            }
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
}

function Compare-PshBatch4Golden {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string[]]$Actual
    )

    $path = Join-Path -Path $GoldenRoot -ChildPath ($Id + '.txt')
    Assert-PshBatch4Archive ([IO.File]::Exists($path)) ('GNU golden is missing: {0}' -f $path)
    $expected = [IO.File]::ReadAllText($path, $utf8NoBom).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($expected.EndsWith("`n")) { $expected = $expected.Substring(0, $expected.Length - 1) }
    $actualText = ($Actual -join "`n").Replace("`r`n", "`n").Replace("`r", "`n")
    Assert-PshBatch4Archive ([string]::Equals($actualText, $expected, [StringComparison]::Ordinal)) ('GNU golden mismatch for {0}. Expected <{1}>, actual <{2}>.' -f $Id, $expected, $actualText)
}

function Test-PshBatch4RecognizedLinkCreationFailure {
    param([AllowNull()][string]$Message)

    return -not [string]::IsNullOrWhiteSpace($Message) -and
        $Message -match '(?i)privilege|operation not permitted|not supported|symbolic links?.*disabled|itemtype.*not valid|junction.*not supported'
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    [void][IO.Directory]::CreateDirectory($configRoot)
    [void][IO.Directory]::CreateDirectory($emptyPathRoot)
    $env:LOCALAPPDATA = $configRoot

    if ($env:OS -ne 'Windows_NT' -and [IO.Path]::DirectorySeparatorChar -ne '\') {
        $nativeTar = Get-Command -Name tar -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $nativeGzip = Get-Command -Name gzip -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $nativeTar) { $nativeTarPath = [string]$nativeTar.Source }
        if ($null -ne $nativeGzip) { $nativeGzipPath = [string]$nativeGzip.Source }
    }

    # No archive command may need a native executable in either edition.
    $env:PATH = $emptyPathRoot
    $env:PSH_EDITION = 'Core'
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $coreDefinitions = @{}
    foreach ($name in $archiveCommandNames) {
        $commands = @(Get-Command -Name ('Psh\{0}' -f $name) -CommandType Function -All -ErrorAction Stop)
        Assert-PshBatch4Archive ($commands.Count -eq 1 -and $commands[0].Source -ceq 'Psh') ('Core did not expose exactly one Psh PowerShell function for {0}.' -f $name)
        $coreDefinitions[$name] = [string]$commands[0].Definition

        $help = Invoke-PshBatch4ArchiveCommand -Name $name -Arguments @('--help')
        Assert-PshBatch4Archive ($help.ExitCode -eq 0 -and $help.Output.Count -eq 1 -and $help.Output[0].StartsWith('Usage:', [StringComparison]::Ordinal) -and $help.RawBytes.Length -eq 0) ('{0} --help did not return one text usage line.' -f $name)
        $unsupported = Invoke-PshBatch4ArchiveCommand -Name $name -Arguments @('--definitely-unsupported')
        Assert-PshBatch4Archive ($unsupported.ExitCode -eq 2 -and $unsupported.Output.Count -eq 1 -and $unsupported.RawBytes.Length -eq 0) ('{0} did not reject unsupported syntax with exit 2.' -f $name)
    }

    $fixtureRoot = Join-Path $testRoot 'fixtures with spaces'
    $sourceRoot = Join-Path $fixtureRoot '资料 source'
    $nestedRoot = Join-Path $sourceRoot 'nested folder'
    [void][IO.Directory]::CreateDirectory($nestedRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'empty folder'))
    $unicodePath = Join-Path $nestedRoot '中文 file.txt'
    $binaryPath = Join-Path $sourceRoot 'binary data.bin'
    $unicodeText = "alpha 中文`nsecond line`n"
    [IO.File]::WriteAllText($unicodePath, $unicodeText, $utf8NoBom)
    $binaryBytes = New-Object byte[] 513
    for ($index = 0; $index -lt $binaryBytes.Length; $index++) { $binaryBytes[$index] = [byte]($index % 256) }
    [IO.File]::WriteAllBytes($binaryPath, $binaryBytes)

    # TAR create/list/extract supports -C, -v, -z, Unicode paths, and binary data.
    $tarRoot = Join-Path $testRoot 'tar cases'
    $tarExtract = Join-Path $tarRoot 'extract plain'
    $tarGzipExtract = Join-Path $tarRoot 'extract gzip'
    [void][IO.Directory]::CreateDirectory($tarRoot)
    [void][IO.Directory]::CreateDirectory($tarExtract)
    [void][IO.Directory]::CreateDirectory($tarGzipExtract)
    Set-Location -LiteralPath $tarRoot
    $plainTar = Join-Path $tarRoot 'bundle plain.tar'
    $tarCreate = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-cvf', $plainTar, '-C', $fixtureRoot, '资料 source')
    Assert-PshBatch4ArchiveSuccess $tarCreate 'tar -cvf -C'
    Assert-PshBatch4Archive (($tarCreate.Output -join "`n") -match '资料 source/' -and ($tarCreate.Output -join "`n") -match '中文 file\.txt') 'tar -v create did not list Unicode archive members.'
    $tarList = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tf', $plainTar)
    Assert-PshBatch4Archive ($tarList.ExitCode -eq 0 -and $tarList.Output -contains '资料 source/' -and $tarList.Output -contains '资料 source/nested folder/中文 file.txt') 'tar -t did not list the expected portable member names.'
    $tarLongList = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tvf', $plainTar)
    Assert-PshBatch4Archive ($tarLongList.ExitCode -eq 0 -and ($tarLongList.Output -join "`n") -match '513\s+资料 source/binary data\.bin') 'tar -tv did not return the expected long text listing.'
    $tarExtractResult = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-xvf', $plainTar, '-C', $tarExtract)
    Assert-PshBatch4ArchiveSuccess $tarExtractResult 'tar -xvf -C'
    Assert-PshBatch4Archive ([IO.File]::ReadAllText((Join-Path $tarExtract '资料 source/nested folder/中文 file.txt'), $utf8NoBom) -ceq $unicodeText) 'tar extraction changed UTF-8 text.'
    Assert-PshBatch4Archive (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes((Join-Path $tarExtract '资料 source/binary data.bin'))) $binaryBytes) 'tar extraction changed binary data.'

    $gzipTar = Join-Path $tarRoot 'bundle gzip.tar.gz'
    $tarGzipCreate = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-czf', $gzipTar, '-C', $fixtureRoot, '资料 source')
    Assert-PshBatch4ArchiveSuccess $tarGzipCreate 'tar -czf -C'
    Assert-PshBatch4Archive ([IO.File]::ReadAllBytes($gzipTar)[0] -eq 0x1f -and [IO.File]::ReadAllBytes($gzipTar)[1] -eq 0x8b) 'tar -z did not create a gzip stream.'
    $tarGzipList = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tzf', $gzipTar)
    Assert-PshBatch4Archive ($tarGzipList.ExitCode -eq 0 -and (Test-PshBatch4StringArray $tarGzipList.Output $tarList.Output)) 'tar -tz did not match the plain TAR member list.'
    $tarGzipExpand = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-xzf', $gzipTar, '-C', $tarGzipExtract)
    Assert-PshBatch4Archive ($tarGzipExpand.ExitCode -eq 0 -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes((Join-Path $tarGzipExtract '资料 source/binary data.bin'))) $binaryBytes)) 'tar -xz did not round-trip binary data.'

    $missingTar = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tf', (Join-Path $tarRoot 'missing.tar'))
    Assert-PshBatch4Archive ($missingTar.ExitCode -eq 3) 'tar classified a missing archive as integrity failure instead of runtime failure.'
    $missingTarInput = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-cf', (Join-Path $tarRoot 'missing-input.tar'), '-C', $fixtureRoot, 'missing input')
    Assert-PshBatch4Archive ($missingTarInput.ExitCode -eq 3 -and -not [IO.File]::Exists((Join-Path $tarRoot 'missing-input.tar'))) 'tar did not fail missing create input transactionally with exit 3.'

    $createTransactionRoot = Join-Path $tarRoot 'create transaction failures'
    $createTransactionTarget = Join-Path $createTransactionRoot 'existing archive.tar'
    $createTransactionInput = Join-Path $createTransactionRoot 'replacement.txt'
    [void][IO.Directory]::CreateDirectory($createTransactionRoot)
    New-PshBatch4TarArchive -Path $createTransactionTarget -Entries @([PSCustomObject]@{
        Name = 'old.txt'
        Data = $utf8NoBom.GetBytes('old archive payload')
    })
    [IO.File]::WriteAllText($createTransactionInput, 'replacement payload', $utf8NoBom)
    $oldArchiveBytes = [IO.File]::ReadAllBytes($createTransactionTarget)
    $module = Get-Module -Name Psh -ErrorAction Stop
    $originalArchiveCommitMove = & $module { (Get-Item -LiteralPath Function:Move-PshTarArchiveCommitFile -ErrorAction Stop).ScriptBlock }
    $failingArchiveCommitMove = {
        param(
            [Parameter(Mandatory = $true)][string]$SourcePath,
            [Parameter(Mandatory = $true)][string]$DestinationPath
        )

        $sourceName = [IO.Path]::GetFileName($SourcePath)
        if ($sourceName.StartsWith('.psh-tar-stage-', [StringComparison]::Ordinal)) { throw 'injected tar archive install failure' }
        if ($sourceName.StartsWith('.psh-tar-backup-', [StringComparison]::Ordinal)) { throw 'injected tar archive restore failure' }
        [IO.File]::Move($SourcePath, $DestinationPath)
    }
    & $module {
        param([Parameter(Mandatory = $true)][scriptblock]$Replacement)
        Set-Item -LiteralPath Function:script:Move-PshTarArchiveCommitFile -Value $Replacement -Force
    } $failingArchiveCommitMove
    Set-Location -LiteralPath $createTransactionRoot
    try {
        $archiveRollbackFailure = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-cf', $createTransactionTarget, 'replacement.txt')
    }
    finally {
        & $module {
            param([Parameter(Mandatory = $true)][scriptblock]$Original)
            Set-Item -LiteralPath Function:script:Move-PshTarArchiveCommitFile -Value $Original -Force
        } $originalArchiveCommitMove
    }

    $archiveRollbackOutput = $archiveRollbackFailure.Output -join "`n"
    $archiveRollbackBackups = @([IO.Directory]::GetFiles($createTransactionRoot, '.psh-tar-backup-*', [IO.SearchOption]::TopDirectoryOnly))
    $archiveRollbackStages = @([IO.Directory]::GetFiles($createTransactionRoot, '.psh-tar-stage-*', [IO.SearchOption]::TopDirectoryOnly))
    Assert-PshBatch4Archive ($archiveRollbackFailure.ExitCode -eq 3 -and $archiveRollbackOutput -match 'injected tar archive install failure' -and $archiveRollbackOutput -match 'injected tar archive restore failure') 'tar archive replacement did not report both commit and rollback failures.'
    Assert-PshBatch4Archive ($archiveRollbackBackups.Count -eq 1 -and -not [IO.File]::Exists($createTransactionTarget) -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes($archiveRollbackBackups[0])) $oldArchiveBytes)) 'tar archive replacement lost or changed the previous archive after rollback failure.'
    Assert-PshBatch4Archive ($archiveRollbackOutput.Contains($archiveRollbackBackups[0]) -and $archiveRollbackStages.Count -eq 0) 'tar archive replacement did not report the retained backup path or clean only the disposable stage.'
    [IO.File]::Move($archiveRollbackBackups[0], $createTransactionTarget)
    Assert-PshBatch4Archive (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes($createTransactionTarget)) $oldArchiveBytes) 'the retained tar archive backup could not restore the previous archive.'
    Assert-PshBatch4NoTransactionArtifacts -Root $createTransactionRoot -Context 'tar archive rollback failure recovery'

    $originalArchiveCommitRemove = & $module { (Get-Item -LiteralPath Function:Remove-PshTarArchiveCommitFile -ErrorAction Stop).ScriptBlock }
    $failingArchiveCommitRemove = {
        param([Parameter(Mandatory = $true)][string]$Path)

        if ([IO.Path]::GetFileName($Path).StartsWith('.psh-tar-backup-', [StringComparison]::Ordinal)) {
            throw 'injected tar archive backup cleanup failure'
        }
        [IO.File]::Delete($Path)
    }
    & $module {
        param([Parameter(Mandatory = $true)][scriptblock]$Replacement)
        Set-Item -LiteralPath Function:script:Remove-PshTarArchiveCommitFile -Value $Replacement -Force
    } $failingArchiveCommitRemove
    try {
        $archiveCleanupFailure = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-cf', $createTransactionTarget, 'replacement.txt')
    }
    finally {
        & $module {
            param([Parameter(Mandatory = $true)][scriptblock]$Original)
            Set-Item -LiteralPath Function:script:Remove-PshTarArchiveCommitFile -Value $Original -Force
        } $originalArchiveCommitRemove
    }

    $archiveCleanupOutput = $archiveCleanupFailure.Output -join "`n"
    $archiveCleanupBackups = @([IO.Directory]::GetFiles($createTransactionRoot, '.psh-tar-backup-*', [IO.SearchOption]::TopDirectoryOnly))
    $archiveCleanupList = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tf', $createTransactionTarget)
    Assert-PshBatch4Archive ($archiveCleanupFailure.ExitCode -eq 3 -and $archiveCleanupOutput -match 'replacement committed' -and $archiveCleanupOutput -match 'injected tar archive backup cleanup failure') 'tar silently reported success after committed archive backup cleanup failed.'
    Assert-PshBatch4Archive ($archiveCleanupBackups.Count -eq 1 -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes($archiveCleanupBackups[0])) $oldArchiveBytes) -and $archiveCleanupOutput.Contains($archiveCleanupBackups[0])) 'tar did not preserve and report the previous archive after backup cleanup failure.'
    Assert-PshBatch4Archive ($archiveCleanupList.ExitCode -eq 0 -and (Test-PshBatch4StringArray $archiveCleanupList.Output @('replacement.txt'))) 'tar backup cleanup failure left an invalid or ambiguous committed archive.'
    [IO.File]::Delete($createTransactionTarget)
    [IO.File]::Move($archiveCleanupBackups[0], $createTransactionTarget)
    Assert-PshBatch4Archive (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes($createTransactionTarget)) $oldArchiveBytes) 'the cleanup-failure backup could not recover the previous archive.'
    Assert-PshBatch4NoTransactionArtifacts -Root $createTransactionRoot -Context 'tar archive cleanup failure recovery'
    Set-Location -LiteralPath $tarRoot

    $badChecksumTar = Join-Path $tarRoot 'bad checksum.tar'
    New-PshBatch4TarArchive -Path $badChecksumTar -Entries @([PSCustomObject]@{ Name = 'safe.txt'; Data = $utf8NoBom.GetBytes('safe') })
    $badTarBytes = [IO.File]::ReadAllBytes($badChecksumTar)
    $badTarBytes[0] = $badTarBytes[0] -bxor 1
    [IO.File]::WriteAllBytes($badChecksumTar, $badTarBytes)
    $badChecksumResult = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tf', $badChecksumTar)
    Assert-PshBatch4Archive ($badChecksumResult.ExitCode -eq 5) 'tar did not classify a header checksum mismatch as integrity failure.'
    $truncatedTar = Join-Path $tarRoot 'truncated.tar'
    [IO.File]::WriteAllBytes($truncatedTar, [byte[]]$badTarBytes[0..599])
    $truncatedTarResult = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tf', $truncatedTar)
    Assert-PshBatch4Archive ($truncatedTarResult.ExitCode -eq 5) 'tar did not classify truncation as integrity failure.'

    $tarOutsideSentinel = Join-Path $testRoot 'tar outside sentinel.txt'
    [IO.File]::WriteAllText($tarOutsideSentinel, 'outside-safe', $utf8NoBom)
    $unsafeTarNames = @('/absolute.txt', '../escape.txt', 'C:/drive.txt', '//server/share.txt')
    for ($index = 0; $index -lt $unsafeTarNames.Count; $index++) {
        $unsafeArchive = Join-Path $tarRoot ('unsafe-{0}.tar' -f $index)
        $unsafeDestination = Join-Path $tarRoot ('unsafe destination {0}' -f $index)
        [void][IO.Directory]::CreateDirectory($unsafeDestination)
        New-PshBatch4TarArchive -Path $unsafeArchive -Entries @(
            [PSCustomObject]@{ Name = 'existing.txt'; Data = $utf8NoBom.GetBytes('replacement') },
            [PSCustomObject]@{ Name = $unsafeTarNames[$index]; Data = $utf8NoBom.GetBytes('escape') }
        )
        $existingTarTarget = Join-Path $unsafeDestination 'existing.txt'
        [IO.File]::WriteAllText($existingTarTarget, 'original', $utf8NoBom)
        $unsafeResult = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-xf', $unsafeArchive, '-C', $unsafeDestination)
        Assert-PshBatch4Archive ($unsafeResult.ExitCode -eq 5) ('tar accepted unsafe archive member {0}.' -f $unsafeTarNames[$index])
        Assert-PshBatch4Archive ([IO.File]::ReadAllText($existingTarTarget, $utf8NoBom) -ceq 'original') ('tar changed an existing target before rejecting {0}.' -f $unsafeTarNames[$index])
        Assert-PshBatch4Archive ([IO.File]::ReadAllText($tarOutsideSentinel, $utf8NoBom) -ceq 'outside-safe') ('tar escaped its extraction root for {0}.' -f $unsafeTarNames[$index])
        Assert-PshBatch4NoTransactionArtifacts -Root $unsafeDestination -Context ('tar unsafe member {0}' -f $unsafeTarNames[$index])
    }

    foreach ($tarTypeCase in @(
        [PSCustomObject]@{ Id = 'link'; TypeFlag = '2'; LinkName = 'target.txt' },
        [PSCustomObject]@{ Id = 'unknown'; TypeFlag = '3'; LinkName = '' }
    )) {
        $typeArchive = Join-Path $tarRoot ('type-{0}.tar' -f $tarTypeCase.Id)
        $typeDestination = Join-Path $tarRoot ('type destination {0}' -f $tarTypeCase.Id)
        [void][IO.Directory]::CreateDirectory($typeDestination)
        New-PshBatch4TarArchive -Path $typeArchive -Entries @([PSCustomObject]@{
            Name = 'entry.txt'
            TypeFlag = $tarTypeCase.TypeFlag
            LinkName = $tarTypeCase.LinkName
            Data = [byte[]]@()
        })
        $typeResult = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-xf', $typeArchive, '-C', $typeDestination)
        Assert-PshBatch4Archive ($typeResult.ExitCode -eq 5 -and [IO.Directory]::GetFileSystemEntries($typeDestination).Length -eq 0) ('tar accepted archive type {0}.' -f $tarTypeCase.Id)
    }

    $tarConflictDestination = Join-Path $tarRoot 'conflict destination'
    [void][IO.Directory]::CreateDirectory((Join-Path $tarConflictDestination '资料 source/binary data.bin'))
    $tarConflict = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-xf', $plainTar, '-C', $tarConflictDestination)
    Assert-PshBatch4Archive ($tarConflict.ExitCode -eq 3 -and [IO.Directory]::Exists((Join-Path $tarConflictDestination '资料 source/binary data.bin'))) 'tar classified an extraction target conflict as archive corruption or changed the target.'
    Assert-PshBatch4NoTransactionArtifacts -Root $tarConflictDestination -Context 'tar target conflict'

    $rollbackArchive = Join-Path $tarRoot 'rollback failure.tar'
    $rollbackDestination = Join-Path $tarRoot 'rollback failure destination'
    $rollbackTarget = Join-Path $rollbackDestination 'preserve.txt'
    [void][IO.Directory]::CreateDirectory($rollbackDestination)
    New-PshBatch4TarArchive -Path $rollbackArchive -Entries @([PSCustomObject]@{
        Name = 'preserve.txt'
        Data = $utf8NoBom.GetBytes('replacement')
    })
    [IO.File]::WriteAllText($rollbackTarget, 'original', $utf8NoBom)
    $module = Get-Module -Name Psh -ErrorAction Stop
    $originalTarMove = & $module { (Get-Item -LiteralPath Function:Move-PshTarExtractionFile -ErrorAction Stop).ScriptBlock }
    $failingTarMove = {
        param(
            [Parameter(Mandatory = $true)][string]$SourcePath,
            [Parameter(Mandatory = $true)][string]$DestinationPath
        )

        $sourceParentName = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($SourcePath))
        if ($sourceParentName -ceq 'payload') { throw 'injected tar install failure' }
        if ($sourceParentName -ceq 'rollback') { throw 'injected tar rollback failure' }
        [IO.File]::Move($SourcePath, $DestinationPath)
    }
    & $module {
        param([Parameter(Mandatory = $true)][scriptblock]$Replacement)
        Set-Item -LiteralPath Function:script:Move-PshTarExtractionFile -Value $Replacement -Force
    } $failingTarMove
    try {
        $rollbackFailure = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-xf', $rollbackArchive, '-C', $rollbackDestination)
    }
    finally {
        & $module {
            param([Parameter(Mandatory = $true)][scriptblock]$Original)
            Set-Item -LiteralPath Function:script:Move-PshTarExtractionFile -Value $Original -Force
        } $originalTarMove
    }

    $rollbackStages = @([IO.Directory]::GetDirectories($rollbackDestination, '.psh-tar-extract-*', [IO.SearchOption]::TopDirectoryOnly))
    $rollbackOutput = $rollbackFailure.Output -join "`n"
    Assert-PshBatch4Archive ($rollbackFailure.ExitCode -eq 3 -and $rollbackOutput -match 'injected tar install failure' -and $rollbackOutput -match 'injected tar rollback failure') 'tar did not report both the extraction commit and rollback failures.'
    Assert-PshBatch4Archive ($rollbackStages.Count -eq 1 -and $rollbackOutput.Contains($rollbackStages[0])) 'tar did not diagnose the preserved extraction staging directory.'
    $preservedBackups = @([IO.Directory]::GetFiles((Join-Path $rollbackStages[0] 'rollback'), '*.bak', [IO.SearchOption]::TopDirectoryOnly))
    Assert-PshBatch4Archive ($preservedBackups.Count -eq 1 -and -not [IO.File]::Exists($rollbackTarget) -and [IO.File]::ReadAllText($preservedBackups[0], $utf8NoBom) -ceq 'original') 'tar cleanup deleted or changed the only remaining original-file backup after rollback failure.'
    [IO.File]::Move($preservedBackups[0], $rollbackTarget)
    [IO.Directory]::Delete($rollbackStages[0], $true)
    Assert-PshBatch4Archive ([IO.File]::ReadAllText($rollbackTarget, $utf8NoBom) -ceq 'original') 'the preserved tar rollback backup could not restore the original file.'
    Assert-PshBatch4NoTransactionArtifacts -Root $rollbackDestination -Context 'tar rollback failure recovery'

    # ZIP create/update/list/extract covers -r, -j, -u, -q and unzip modes.
    $zipRoot = Join-Path $testRoot 'zip cases'
    [void][IO.Directory]::CreateDirectory($zipRoot)
    Set-Location -LiteralPath $fixtureRoot
    $zipArchive = Join-Path $zipRoot 'bundle archive.zip'
    $zipCreate = Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-r', $zipArchive, '资料 source')
    Assert-PshBatch4Archive ($zipCreate.ExitCode -eq 0 -and ($zipCreate.Output -join "`n") -match 'adding: 资料 source/' -and [IO.File]::Exists($zipArchive)) 'zip -r did not create and report the expected archive.'
    $zipList = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-l', $zipArchive)
    Assert-PshBatch4Archive ($zipList.ExitCode -eq 0 -and $zipList.Output[0].StartsWith('Archive:', [StringComparison]::Ordinal) -and ($zipList.Output -join "`n") -match '资料 source/nested folder/中文 file\.txt') 'unzip -l did not produce the expected text listing.'
    $zipQuietList = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-lq', $zipArchive)
    Assert-PshBatch4Archive ($zipQuietList.ExitCode -eq 0 -and $zipQuietList.Output -contains '资料 source/binary data.bin' -and @($zipQuietList.Output | Where-Object { $_.StartsWith('Archive:', [StringComparison]::Ordinal) }).Count -eq 0) 'unzip -lq did not return names-only output.'

    $zipExtract = Join-Path $zipRoot 'extract quiet'
    $zipExtractResult = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-q', $zipArchive, '-d', $zipExtract)
    Assert-PshBatch4Archive ($zipExtractResult.ExitCode -eq 0 -and $zipExtractResult.Output.Count -eq 0 -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes((Join-Path $zipExtract '资料 source/binary data.bin'))) $binaryBytes)) 'unzip -q/-d did not quietly round-trip binary data.'
    $zipExisting = Join-Path $zipExtract '资料 source/nested folder/中文 file.txt'
    [IO.File]::WriteAllText($zipExisting, 'keep-existing', $utf8NoBom)
    $zipNever = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-n', $zipArchive, '-d', $zipExtract)
    Assert-PshBatch4Archive ($zipNever.ExitCode -eq 0 -and ($zipNever.Output -join "`n") -match 'skipping:' -and [IO.File]::ReadAllText($zipExisting, $utf8NoBom) -ceq 'keep-existing') 'unzip -n did not preserve and report an existing target.'
    $zipOverwrite = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-oq', $zipArchive, '-d', $zipExtract)
    Assert-PshBatch4Archive ($zipOverwrite.ExitCode -eq 0 -and $zipOverwrite.Output.Count -eq 0 -and [IO.File]::ReadAllText($zipExisting, $utf8NoBom) -ceq $unicodeText) 'unzip -o/-q did not overwrite quietly.'
    [IO.File]::WriteAllText($zipExisting, 'default-preserve', $utf8NoBom)
    $zipDefault = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @($zipArchive, '-d', $zipExtract)
    Assert-PshBatch4Archive ($zipDefault.ExitCode -eq 3 -and [IO.File]::ReadAllText($zipExisting, $utf8NoBom) -ceq 'default-preserve') 'unzip default overwrite mode did not refuse and preserve an existing target.'

    $junkArchive = Join-Path $zipRoot 'junk paths.zip'
    $zipJunk = Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-jq', $junkArchive, '资料 source/nested folder/中文 file.txt')
    Assert-PshBatch4Archive ($zipJunk.ExitCode -eq 0 -and $zipJunk.Output.Count -eq 0) 'zip -j/-q did not create quietly.'
    $junkList = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-lq', $junkArchive)
    Assert-PshBatch4Archive (Test-PshBatch4StringArray $junkList.Output @('中文 file.txt')) 'zip -j retained parent paths.'

    $updateRoot = Join-Path $zipRoot 'update source'
    [void][IO.Directory]::CreateDirectory($updateRoot)
    $updateFile = Join-Path $updateRoot 'update.txt'
    $updateArchive = Join-Path $zipRoot 'update.zip'
    [IO.File]::WriteAllText($updateFile, 'version-one', $utf8NoBom)
    [IO.File]::SetLastWriteTimeUtc($updateFile, [DateTime]'2020-01-01T00:00:00Z')
    Set-Location -LiteralPath $updateRoot
    Assert-PshBatch4ArchiveSuccess (Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-q', $updateArchive, 'update.txt')) 'zip initial update fixture'
    [IO.File]::WriteAllText($updateFile, 'older-change', $utf8NoBom)
    [IO.File]::SetLastWriteTimeUtc($updateFile, [DateTime]'2019-01-01T00:00:00Z')
    $zipUpdateSkip = Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-u', $updateArchive, 'update.txt')
    Assert-PshBatch4Archive ($zipUpdateSkip.ExitCode -eq 0 -and $zipUpdateSkip.Output.Count -eq 0) 'zip -u did not skip an older input.'
    $updateExtract = Join-Path $zipRoot 'update extract'
    Assert-PshBatch4ArchiveSuccess (Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-q', $updateArchive, '-d', $updateExtract)) 'unzip skipped update archive'
    Assert-PshBatch4Archive ([IO.File]::ReadAllText((Join-Path $updateExtract 'update.txt'), $utf8NoBom) -ceq 'version-one') 'zip -u replaced an entry with an older source.'
    [IO.File]::WriteAllText($updateFile, 'version-two', $utf8NoBom)
    [IO.File]::SetLastWriteTimeUtc($updateFile, [DateTime]'2022-01-01T00:00:00Z')
    $zipUpdate = Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-u', $updateArchive, 'update.txt')
    Assert-PshBatch4Archive ($zipUpdate.ExitCode -eq 0 -and $zipUpdate.Output -contains 'updating: update.txt') 'zip -u did not update a newer input.'
    Assert-PshBatch4ArchiveSuccess (Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-oq', $updateArchive, '-d', $updateExtract)) 'unzip updated archive'
    Assert-PshBatch4Archive ([IO.File]::ReadAllText((Join-Path $updateExtract 'update.txt'), $utf8NoBom) -ceq 'version-two') 'zip -u did not store newer file bytes.'

    $corruptZip = Join-Path $zipRoot 'truncated.zip'
    $validZipBytes = [IO.File]::ReadAllBytes($zipArchive)
    [IO.File]::WriteAllBytes($corruptZip, [byte[]]$validZipBytes[0..([Math]::Max(8, [int]($validZipBytes.Length / 2)))])
    $corruptZipList = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-l', $corruptZip)
    Assert-PshBatch4Archive ($corruptZipList.ExitCode -eq 5) 'unzip did not classify a truncated ZIP as integrity failure.'
    $corruptZipUpdate = Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-u', $corruptZip, $updateFile)
    Assert-PshBatch4Archive ($corruptZipUpdate.ExitCode -eq 5) 'zip did not classify an invalid existing archive as integrity failure.'

    $zipOutsideSentinel = Join-Path $testRoot 'zip outside sentinel.txt'
    [IO.File]::WriteAllText($zipOutsideSentinel, 'outside-safe', $utf8NoBom)
    $unsafeZipCases = @(
        [PSCustomObject]@{ Id = 'absolute'; Name = '/absolute.txt'; ExternalAttributes = 0 },
        [PSCustomObject]@{ Id = 'traversal'; Name = '../escape.txt'; ExternalAttributes = 0 },
        [PSCustomObject]@{ Id = 'drive'; Name = 'C:/drive.txt'; ExternalAttributes = 0 },
        [PSCustomObject]@{ Id = 'unc'; Name = '//server/share.txt'; ExternalAttributes = 0 },
        [PSCustomObject]@{ Id = 'backslash'; Name = 'folder\escape.txt'; ExternalAttributes = 0 },
        [PSCustomObject]@{ Id = 'link'; Name = 'link.txt'; ExternalAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]2684354560), 0) },
        [PSCustomObject]@{ Id = 'reparse'; Name = 'reparse.txt'; ExternalAttributes = [int][IO.FileAttributes]::ReparsePoint }
    )
    foreach ($unsafeZipCase in $unsafeZipCases) {
        $unsafeZip = Join-Path $zipRoot ('unsafe-{0}.zip' -f $unsafeZipCase.Id)
        $unsafeZipDestination = Join-Path $zipRoot ('unsafe destination {0}' -f $unsafeZipCase.Id)
        [void][IO.Directory]::CreateDirectory($unsafeZipDestination)
        New-PshBatch4ZipArchive -Path $unsafeZip -Entries @(
            [PSCustomObject]@{ Name = 'existing.txt'; Data = $utf8NoBom.GetBytes('replacement'); ExternalAttributes = 0 },
            [PSCustomObject]@{ Name = $unsafeZipCase.Name; Data = $utf8NoBom.GetBytes('escape'); ExternalAttributes = $unsafeZipCase.ExternalAttributes }
        )
        $unsafeZipExisting = Join-Path $unsafeZipDestination 'existing.txt'
        [IO.File]::WriteAllText($unsafeZipExisting, 'original', $utf8NoBom)
        $unsafeZipResult = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-o', $unsafeZip, '-d', $unsafeZipDestination)
        Assert-PshBatch4Archive ($unsafeZipResult.ExitCode -eq 5) ('unzip accepted unsafe ZIP entry {0}.' -f $unsafeZipCase.Id)
        Assert-PshBatch4Archive ([IO.File]::ReadAllText($unsafeZipExisting, $utf8NoBom) -ceq 'original') ('unzip changed an existing target before rejecting {0}.' -f $unsafeZipCase.Id)
        Assert-PshBatch4Archive ([IO.File]::ReadAllText($zipOutsideSentinel, $utf8NoBom) -ceq 'outside-safe') ('unzip escaped its destination for {0}.' -f $unsafeZipCase.Id)
        Assert-PshBatch4NoTransactionArtifacts -Root $zipRoot -Context ('unzip unsafe entry {0}' -f $unsafeZipCase.Id)
    }

    # Filesystem links/reparse points are tested when the current host permits creation.
    $linkTargetRoot = Join-Path $testRoot 'link target'
    $linkInput = Join-Path $fixtureRoot 'archive link'
    [void][IO.Directory]::CreateDirectory($linkTargetRoot)
    [IO.File]::WriteAllText((Join-Path $linkTargetRoot 'outside.txt'), 'outside-link-safe', $utf8NoBom)
    $linkCreated = $false
    try {
        [void](Microsoft.PowerShell.Management\New-Item -ItemType SymbolicLink -Path $linkInput -Target $linkTargetRoot -ErrorAction Stop)
        $linkCreated = $true
    }
    catch {
        if (-not (Test-PshBatch4RecognizedLinkCreationFailure -Message $_.Exception.Message)) { throw }
    }
    if ($linkCreated) {
        $tarLinkInput = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-cf', (Join-Path $tarRoot 'link-input.tar'), '-C', $fixtureRoot, 'archive link')
        $zipLinkInput = Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-r', (Join-Path $zipRoot 'link-input.zip'), $linkInput)
        Assert-PshBatch4Archive ($tarLinkInput.ExitCode -eq 3 -and $zipLinkInput.ExitCode -eq 3) 'tar/zip accepted a symbolic-link input.'

        $tarLinkDestination = Join-Path $tarRoot 'link extraction destination'
        $zipLinkDestination = Join-Path $zipRoot 'link extraction destination'
        [void][IO.Directory]::CreateDirectory($tarLinkDestination)
        [void][IO.Directory]::CreateDirectory($zipLinkDestination)
        [void](Microsoft.PowerShell.Management\New-Item -ItemType SymbolicLink -Path (Join-Path $tarLinkDestination 'linked') -Target $linkTargetRoot -ErrorAction Stop)
        [void](Microsoft.PowerShell.Management\New-Item -ItemType SymbolicLink -Path (Join-Path $zipLinkDestination 'linked') -Target $linkTargetRoot -ErrorAction Stop)
        $tarLinkArchive = Join-Path $tarRoot 'link-target.tar'
        $zipLinkArchive = Join-Path $zipRoot 'link-target.zip'
        New-PshBatch4TarArchive -Path $tarLinkArchive -Entries @([PSCustomObject]@{ Name = 'linked/escaped.txt'; Data = $utf8NoBom.GetBytes('escape') })
        New-PshBatch4ZipArchive -Path $zipLinkArchive -Entries @([PSCustomObject]@{ Name = 'linked/escaped.txt'; Data = $utf8NoBom.GetBytes('escape'); ExternalAttributes = 0 })
        $tarLinkExtract = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-xf', $tarLinkArchive, '-C', $tarLinkDestination)
        $zipLinkExtract = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @($zipLinkArchive, '-d', $zipLinkDestination)
        Assert-PshBatch4Archive ($tarLinkExtract.ExitCode -eq 3 -and $zipLinkExtract.ExitCode -eq 3 -and -not [IO.File]::Exists((Join-Path $linkTargetRoot 'escaped.txt'))) 'archive extraction followed a symbolic-link/reparse path or misclassified it.'
    }

    # GZIP/GUNZIP cover raw stdout, deterministic -n, headers, and file transactions.
    $gzipRoot = Join-Path $testRoot 'gzip cases'
    [void][IO.Directory]::CreateDirectory($gzipRoot)
    $gzipSource = Join-Path $gzipRoot 'payload 中文.bin'
    [IO.File]::WriteAllBytes($gzipSource, $binaryBytes)
    [IO.File]::SetLastWriteTimeUtc($gzipSource, [DateTime]'2023-11-14T22:13:20Z')
    $gzipKeep = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @('-k', $gzipSource)
    $gzipPath = $gzipSource + '.gz'
    Assert-PshBatch4Archive ($gzipKeep.ExitCode -eq 0 -and $gzipKeep.Output.Count -eq 0 -and $gzipKeep.RawBytes.Length -eq 0 -and [IO.File]::Exists($gzipSource) -and [IO.File]::Exists($gzipPath)) 'gzip -k did not preserve input and create output quietly.'
    $gzipHeader = [IO.File]::ReadAllBytes($gzipPath)
    Assert-PshBatch4Archive ($gzipHeader.Length -gt 18 -and $gzipHeader[0] -eq 0x1f -and $gzipHeader[1] -eq 0x8b -and $gzipHeader[2] -eq 8 -and ($gzipHeader[3] -band 8) -ne 0 -and $gzipHeader[9] -eq 255) 'gzip did not write the expected portable header and filename flag.'
    $gzipRawOne = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @('-nc', $gzipSource)
    $gzipRawTwo = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @('-nc', $gzipSource)
    Assert-PshBatch4Archive ($gzipRawOne.ExitCode -eq 0 -and $gzipRawOne.Output.Count -eq 0 -and (Test-PshBatch4ByteSequence $gzipRawOne.RawBytes $gzipRawTwo.RawBytes) -and $gzipRawOne.RawBytes[3] -eq 0 -and $gzipRawOne.RawBytes[4] -eq 0 -and $gzipRawOne.RawBytes[5] -eq 0 -and $gzipRawOne.RawBytes[6] -eq 0 -and $gzipRawOne.RawBytes[7] -eq 0) 'gzip -n -c was not deterministic or retained name/time header fields.'
    $gunzipRaw = Invoke-PshBatch4ArchiveCommand -Name gunzip -Arguments @('-c', $gzipPath)
    Assert-PshBatch4Archive ($gunzipRaw.ExitCode -eq 0 -and $gunzipRaw.Output.Count -eq 0 -and (Test-PshBatch4ByteSequence $gunzipRaw.RawBytes $binaryBytes) -and [IO.File]::Exists($gzipPath)) 'gunzip -c did not return exact raw bytes while preserving input.'

    $pipelineItems = New-Object object[] 1
    $pipelineItems[0] = [byte[]]$binaryBytes
    $gzipPipeline = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @('-n', '-') -PipelineInput $pipelineItems -UsePipeline
    $compressedPipelineItems = New-Object object[] 1
    $compressedPipelineItems[0] = [byte[]]$gzipPipeline.RawBytes
    $gunzipPipeline = Invoke-PshBatch4ArchiveCommand -Name gunzip -Arguments @('-c', '-') -PipelineInput $compressedPipelineItems -UsePipeline
    Assert-PshBatch4Archive ($gzipPipeline.ExitCode -eq 0 -and $gzipPipeline.Output.Count -eq 0 -and $gunzipPipeline.ExitCode -eq 0 -and (Test-PshBatch4ByteSequence $gunzipPipeline.RawBytes $binaryBytes)) 'gzip/gunzip pipeline raw-byte round-trip failed.'

    $gzipDecompressCopy = Join-Path $gzipRoot 'decompress copy.bin.gz'
    [IO.File]::Copy($gzipPath, $gzipDecompressCopy)
    $gzipDashD = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @('-dk', $gzipDecompressCopy)
    Assert-PshBatch4Archive ($gzipDashD.ExitCode -eq 0 -and [IO.File]::Exists($gzipDecompressCopy) -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes((Join-Path $gzipRoot 'decompress copy.bin'))) $binaryBytes)) 'gzip -d -k failed to preserve and decompress.'

    $forceSource = Join-Path $gzipRoot 'force.bin'
    $forceGzip = $forceSource + '.gz'
    [IO.File]::WriteAllBytes($forceSource, $binaryBytes)
    [IO.File]::WriteAllText($forceGzip, 'old gzip', $utf8NoBom)
    $gzipForce = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @('-fk', $forceSource)
    $forceExpand = Invoke-PshBatch4ArchiveCommand -Name gunzip -Arguments @('-c', $forceGzip)
    Assert-PshBatch4Archive ($gzipForce.ExitCode -eq 0 -and [IO.File]::Exists($forceSource) -and (Test-PshBatch4ByteSequence $forceExpand.RawBytes $binaryBytes)) 'gzip -f/-k did not atomically replace an existing output.'

    $removeSource = Join-Path $gzipRoot 'remove source.bin'
    [IO.File]::WriteAllBytes($removeSource, $binaryBytes)
    $gzipRemove = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @($removeSource)
    $removeGzip = $removeSource + '.gz'
    Assert-PshBatch4Archive ($gzipRemove.ExitCode -eq 0 -and -not [IO.File]::Exists($removeSource) -and [IO.File]::Exists($removeGzip)) 'gzip default mode did not replace its input with .gz.'
    $gunzipRemove = Invoke-PshBatch4ArchiveCommand -Name gunzip -Arguments @($removeGzip)
    Assert-PshBatch4Archive ($gunzipRemove.ExitCode -eq 0 -and [IO.File]::Exists($removeSource) -and -not [IO.File]::Exists($removeGzip) -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes($removeSource)) $binaryBytes)) 'gunzip default mode did not restore bytes and remove .gz.'

    $forceGunzipPath = Join-Path $gzipRoot 'force gunzip.bin.gz'
    [IO.File]::Copy($gzipPath, $forceGunzipPath)
    $forceGunzipTarget = Join-Path $gzipRoot 'force gunzip.bin'
    [IO.File]::WriteAllText($forceGunzipTarget, 'old output', $utf8NoBom)
    $gunzipForce = Invoke-PshBatch4ArchiveCommand -Name gunzip -Arguments @('-fk', $forceGunzipPath)
    Assert-PshBatch4Archive ($gunzipForce.ExitCode -eq 0 -and [IO.File]::Exists($forceGunzipPath) -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes($forceGunzipTarget)) $binaryBytes)) 'gunzip -f/-k did not overwrite and preserve its input.'

    $corruptGzip = Join-Path $gzipRoot 'corrupt.bin.gz'
    $corruptTarget = Join-Path $gzipRoot 'corrupt.bin'
    [IO.File]::WriteAllBytes($corruptGzip, [byte[]](31, 139, 8, 0, 0, 0, 0, 0, 0, 255, 1, 2, 3))
    [IO.File]::WriteAllText($corruptTarget, 'preserve-existing', $utf8NoBom)
    $corruptGunzip = Invoke-PshBatch4ArchiveCommand -Name gunzip -Arguments @('-f', $corruptGzip)
    Assert-PshBatch4Archive ($corruptGunzip.ExitCode -eq 5 -and [IO.File]::ReadAllText($corruptTarget, $utf8NoBom) -ceq 'preserve-existing' -and [IO.File]::Exists($corruptGzip)) 'gunzip did not classify corruption as integrity failure while preserving existing files.'
    Assert-PshBatch4NoTransactionArtifacts -Root $gzipRoot -Context 'corrupt gzip recovery'
    $missingGzip = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @((Join-Path $gzipRoot 'missing.bin'))
    Assert-PshBatch4Archive ($missingGzip.ExitCode -eq 3) 'gzip did not classify a missing input as runtime failure.'

    # Tier 1 checksum behavior includes stdin, -b/-t/-z, check mode, and failures.
    $checksumRoot = Join-Path $testRoot 'checksum cases'
    [void][IO.Directory]::CreateDirectory($checksumRoot)
    $checksumPath = Join-Path $checksumRoot 'checksum payload.bin'
    $checksumBytes = [byte[]](0, 1, 2, 3, 10, 13, 127, 128, 255)
    [IO.File]::WriteAllBytes($checksumPath, $checksumBytes)
    $shaHex = Get-PshBatch4HashHex -Algorithm SHA256 -Bytes $checksumBytes
    $md5Hex = Get-PshBatch4HashHex -Algorithm MD5 -Bytes $checksumBytes
    $shaText = Invoke-PshBatch4ArchiveCommand -Name sha256sum -Arguments @($checksumPath)
    $md5Binary = Invoke-PshBatch4ArchiveCommand -Name md5sum -Arguments @('-b', $checksumPath)
    $md5Text = Invoke-PshBatch4ArchiveCommand -Name md5sum -Arguments @('-t', $checksumPath)
    Assert-PshBatch4Archive (Test-PshBatch4StringArray $shaText.Output @(('{0}  {1}' -f $shaHex, $checksumPath))) 'sha256sum file output was not GNU-compatible text.'
    Assert-PshBatch4Archive (Test-PshBatch4StringArray $md5Binary.Output @(('{0} *{1}' -f $md5Hex, $checksumPath))) 'md5sum -b did not use the binary marker.'
    Assert-PshBatch4Archive (Test-PshBatch4StringArray $md5Text.Output @(('{0}  {1}' -f $md5Hex, $checksumPath))) 'md5sum -t did not use the text marker.'
    $shaNull = Invoke-PshBatch4ArchiveCommand -Name sha256sum -Arguments @('-z', $checksumPath)
    $expectedShaNull = $utf8NoBom.GetBytes(('{0}  {1}{2}' -f $shaHex, $checksumPath, [char]0))
    Assert-PshBatch4Archive ($shaNull.ExitCode -eq 0 -and $shaNull.Output.Count -eq 0 -and (Test-PshBatch4ByteSequence $shaNull.RawBytes $expectedShaNull)) 'sha256sum -z did not emit one exact NUL-delimited raw record.'

    $checksumPipelineItems = New-Object object[] 1
    $checksumPipelineItems[0] = [byte[]]$checksumBytes
    $shaPipeline = Invoke-PshBatch4ArchiveCommand -Name sha256sum -PipelineInput $checksumPipelineItems -UsePipeline
    Assert-PshBatch4Archive ($shaPipeline.ExitCode -eq 0 -and (Test-PshBatch4StringArray $shaPipeline.Output @(('{0}  -' -f $shaHex)))) 'sha256sum stdin changed raw byte input.'

    Set-Location -LiteralPath $checksumRoot
    $shaList = Join-Path $checksumRoot 'SHA256SUMS'
    $md5List = Join-Path $checksumRoot 'MD5SUMS'
    [IO.File]::WriteAllText($shaList, ('{0}  checksum payload.bin{1}' -f $shaHex, "`n"), $utf8NoBom)
    [IO.File]::WriteAllText($md5List, ('{0} *checksum payload.bin{1}' -f $md5Hex, "`n"), $utf8NoBom)
    $shaCheck = Invoke-PshBatch4ArchiveCommand -Name sha256sum -Arguments @('-c', 'SHA256SUMS')
    $md5Check = Invoke-PshBatch4ArchiveCommand -Name md5sum -Arguments @('-c', 'MD5SUMS')
    Assert-PshBatch4Archive ($shaCheck.ExitCode -eq 0 -and (Test-PshBatch4StringArray $shaCheck.Output @('checksum payload.bin: OK'))) 'sha256sum -c did not verify a valid list.'
    Assert-PshBatch4Archive ($md5Check.ExitCode -eq 0 -and (Test-PshBatch4StringArray $md5Check.Output @('checksum payload.bin: OK'))) 'md5sum -c did not verify a valid binary-marker list.'
    [IO.File]::WriteAllBytes($checksumPath, [byte[]](9, 8, 7))
    $shaFailedCheck = Invoke-PshBatch4ArchiveCommand -Name sha256sum -Arguments @('-c', 'SHA256SUMS')
    Assert-PshBatch4Archive ($shaFailedCheck.ExitCode -eq 1 -and (Test-PshBatch4StringArray $shaFailedCheck.Output @('checksum payload.bin: FAILED'))) 'sha256sum -c did not report checksum mismatch with exit 1.'
    [IO.File]::WriteAllBytes($checksumPath, $checksumBytes)
    $malformedList = Join-Path $checksumRoot 'MALFORMED'
    [IO.File]::WriteAllText($malformedList, "not-a-checksum`n", $utf8NoBom)
    $malformedCheck = Invoke-PshBatch4ArchiveCommand -Name md5sum -Arguments @('-c', 'MALFORMED')
    Assert-PshBatch4Archive ($malformedCheck.ExitCode -eq 1 -and ($malformedCheck.Output -join '') -match 'malformed') 'md5sum -c did not reject a malformed record with exit 1.'
    $missingChecksum = Invoke-PshBatch4ArchiveCommand -Name sha256sum -Arguments @('missing.bin')
    Assert-PshBatch4Archive ($missingChecksum.ExitCode -eq 3) 'sha256sum did not classify a missing operand as runtime failure.'

    if (-not [string]::IsNullOrWhiteSpace($GoldenRoot)) {
        $goldenFull = [IO.Path]::GetFullPath($GoldenRoot)
        Assert-PshBatch4Archive ([IO.Directory]::Exists($goldenFull)) ('GNU golden root does not exist: {0}' -f $goldenFull)
        Set-Location -LiteralPath $checksumRoot
        Compare-PshBatch4Golden -Id sha256sum -Actual (Invoke-PshBatch4ArchiveCommand -Name sha256sum -Arguments @('checksum payload.bin')).Output
        Compare-PshBatch4Golden -Id md5sum -Actual (Invoke-PshBatch4ArchiveCommand -Name md5sum -Arguments @('checksum payload.bin')).Output
    }

    # Optional non-Windows native tools are local format oracles only. Windows
    # acceptance and all command behavior above run with an empty PATH.
    if (-not [string]::IsNullOrWhiteSpace($nativeTarPath)) {
        $nativeTarOutput = @(& $nativeTarPath -tf $plainTar)
        Assert-PshBatch4Archive ($LASTEXITCODE -eq 0 -and @($nativeTarOutput | Where-Object { [string]$_ -ceq '资料 source/nested folder/中文 file.txt' }).Count -eq 1) 'The optional local tar oracle could not read the Psh USTAR archive.'
    }
    if (-not [string]::IsNullOrWhiteSpace($nativeGzipPath)) {
        & $nativeGzipPath -t $gzipPath
        Assert-PshBatch4Archive ($LASTEXITCODE -eq 0) 'The optional local gzip oracle rejected Psh gzip output.'
    }

    # Full must expose byte-identical PowerShell functions and the same behavior.
    $coreParity = [PSCustomObject]@{
        TarList = [string[]]$tarList.Output
        ZipList = [string[]]$zipQuietList.Output
        Sha = [string[]]$shaText.Output
        Md5 = [string[]]$md5Text.Output
        Gzip = [byte[]]$gzipRawOne.RawBytes
        Gunzip = [byte[]]$gunzipRaw.RawBytes
    }
    Remove-Module -Name Psh -ErrorAction Stop
    $env:PSH_EDITION = 'Full'
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    foreach ($name in $archiveCommandNames) {
        $commands = @(Get-Command -Name ('Psh\{0}' -f $name) -CommandType Function -All -ErrorAction Stop)
        Assert-PshBatch4Archive ($commands.Count -eq 1 -and $commands[0].Source -ceq 'Psh' -and [string]$commands[0].Definition -ceq [string]$coreDefinitions[$name]) ('Full did not reuse the Core PowerShell backend for {0}.' -f $name)
    }
    Set-Location -LiteralPath $checksumRoot
    $fullTarList = Invoke-PshBatch4ArchiveCommand -Name tar -Arguments @('-tf', $plainTar)
    $fullZipList = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-lq', $zipArchive)
    $fullSha = Invoke-PshBatch4ArchiveCommand -Name sha256sum -Arguments @($checksumPath)
    $fullMd5 = Invoke-PshBatch4ArchiveCommand -Name md5sum -Arguments @('-t', $checksumPath)
    $fullGzip = Invoke-PshBatch4ArchiveCommand -Name gzip -Arguments @('-nc', $gzipSource)
    $fullGunzip = Invoke-PshBatch4ArchiveCommand -Name gunzip -Arguments @('-c', $gzipPath)
    Assert-PshBatch4Archive ((Test-PshBatch4StringArray $fullTarList.Output $coreParity.TarList) -and (Test-PshBatch4StringArray $fullZipList.Output $coreParity.ZipList)) 'Full archive listing behavior differs from Core.'
    Assert-PshBatch4Archive ((Test-PshBatch4StringArray $fullSha.Output $coreParity.Sha) -and (Test-PshBatch4StringArray $fullMd5.Output $coreParity.Md5)) 'Full checksum behavior differs from Core.'
    Assert-PshBatch4Archive ((Test-PshBatch4ByteSequence $fullGzip.RawBytes $coreParity.Gzip) -and (Test-PshBatch4ByteSequence $fullGunzip.RawBytes $coreParity.Gunzip)) 'Full gzip/gunzip raw-byte behavior differs from Core.'
    $fullZipArchive = Join-Path $zipRoot 'full parity.zip'
    Set-Location -LiteralPath $fixtureRoot
    $fullZipCreate = Invoke-PshBatch4ArchiveCommand -Name zip -Arguments @('-rq', $fullZipArchive, '资料 source')
    $fullZipExtract = Join-Path $zipRoot 'full parity extract'
    $fullUnzip = Invoke-PshBatch4ArchiveCommand -Name unzip -Arguments @('-q', $fullZipArchive, '-d', $fullZipExtract)
    Assert-PshBatch4Archive ($fullZipCreate.ExitCode -eq 0 -and $fullUnzip.ExitCode -eq 0 -and (Test-PshBatch4ByteSequence ([IO.File]::ReadAllBytes((Join-Path $fullZipExtract '资料 source/binary data.bin'))) $binaryBytes)) 'Full zip/unzip did not use the same PowerShell round-trip behavior.'

    foreach ($name in $archiveCommandNames) {
        Assert-PshBatch4Archive ($covered.ContainsKey($name)) ('No behavior test covered {0}.' -f $name)
    }
    Assert-PshBatch4NoTransactionArtifacts -Root $testRoot -Context 'completed archive suite'

    Write-Output ('Goal 3 Batch 4 archive acceptance passed: 7 commands, {0} assertions, Core/Full PowerShell parity, Unicode/binary archives, raw gzip/checksum output, transactional extraction safety, and integrity/runtime classification{1}.' -f $assertionCount, $(if ([string]::IsNullOrWhiteSpace($GoldenRoot)) { '' } else { ', with GNU checksum goldens' }))
}
finally {
    Set-Location -LiteralPath $originalLocation
    Remove-Module -Name Psh -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = $originalEdition
    $env:PATH = $originalPath
    if ([IO.Directory]::Exists($testRoot)) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
