# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal6-quality-gates-' + [Guid]::NewGuid().ToString('N'))
$assertionCount = 0
. (Join-Path $repositoryRootPath 'scripts/goal6/Goal6.Common.ps1')
. (Join-Path $repositoryRootPath 'scripts/goal6/Goal6.Zip.ps1')

function Assert-PshGoal6Quality {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "Goal 6 quality-gate regression failed: $Message" }
    $script:assertionCount++
}

function Assert-PshGoal6QualityThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $failure = $null
    try { & $Action }
    catch { $failure = [string]$_.Exception.Message }
    Assert-PshGoal6Quality (-not [string]::IsNullOrWhiteSpace($failure)) "$Description did not fail."
    Assert-PshGoal6Quality ($failure -match $MessagePattern) "$Description failed with an unexpected message: $failure"
}

function New-PshGoal6QualityLockCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Mutation
    )

    $sourcePath = Join-Path $repositoryRootPath 'scripts/goal6/ci-dependencies.lock.json'
    $lock = (Get-PshGoal6StrictText -Path $sourcePath) | ConvertFrom-Json -ErrorAction Stop
    & $Mutation $lock
    $path = Join-Path $testRoot ($Name + '.json')
    Write-PshGoal6Json -Path $path -InputObject $lock
    return $path
}

function New-PshGoal6QualityZip {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$EntryNames,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Timestamp,
        [int]$ExternalAttributes = 0
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($entryName in $EntryNames) {
                $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $Timestamp
                $entry.ExternalAttributes = $ExternalAttributes
                $entryStream = $entry.Open()
                try {
                    $content = [Text.Encoding]::UTF8.GetBytes("content:$entryName`n")
                    $entryStream.Write($content, 0, $content.Length)
                }
                finally { $entryStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function New-PshGoal6QualityRepeatedBytes {
    param(
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][byte]$Value
    )

    $bytes = New-Object byte[] $Count
    for ($index = 0; $index -lt $bytes.Length; $index++) { $bytes[$index] = $Value }
    return ,$bytes
}

function Write-PshGoal6QualityExtraField {
    param(
        [Parameter(Mandatory = $true)][IO.BinaryWriter]$Writer,
        [Parameter(Mandatory = $true)][uint16]$HeaderId,
        [Parameter(Mandatory = $true)][byte[]]$Data
    )

    $Writer.Write($HeaderId)
    $Writer.Write([uint16]$Data.Length)
    $Writer.Write($Data)
}

function New-PshGoal6QualityTimestampExtras {
    param(
        [Parameter(Mandatory = $true)][byte]$TimeByte,
        [byte]$NonTimeByte = 0x33,
        [byte]$CentralFlags = 0x07,
        [switch]$MalformedExtendedLength,
        [switch]$MalformedNtfsFileTimeLength
    )

    $localStream = New-Object IO.MemoryStream
    $centralStream = New-Object IO.MemoryStream
    $localWriter = New-Object IO.BinaryWriter($localStream)
    $centralWriter = New-Object IO.BinaryWriter($centralStream)
    try {
        $localExtended = New-Object byte[] 13
        $localExtended[0] = 0x07
        for ($index = 1; $index -lt $localExtended.Length; $index++) { $localExtended[$index] = $TimeByte }
        Write-PshGoal6QualityExtraField -Writer $localWriter -HeaderId 0x5455 -Data $localExtended

        $centralExtended = New-Object byte[] 5
        $centralExtended[0] = $CentralFlags
        for ($index = 1; $index -lt $centralExtended.Length; $index++) { $centralExtended[$index] = $TimeByte }
        Write-PshGoal6QualityExtraField -Writer $centralWriter -HeaderId 0x5455 -Data $centralExtended

        foreach ($writer in @($localWriter, $centralWriter)) {
            $ntfsStream = New-Object IO.MemoryStream
            $ntfsWriter = New-Object IO.BinaryWriter($ntfsStream)
            try {
                $ntfsWriter.Write([byte[]]@(0x10, 0x20, 0x30, 0x40))
                $ntfsWriter.Write([uint16]0x0001)
                $ntfsWriter.Write([uint16]$(if ($MalformedNtfsFileTimeLength) { 23 } else { 24 }))
                $ntfsWriter.Write((New-PshGoal6QualityRepeatedBytes -Count 24 -Value $TimeByte))
                $ntfsWriter.Write([uint16]0x0002)
                $ntfsWriter.Write([uint16]2)
                $ntfsWriter.Write([byte[]]@($NonTimeByte, 0x44))
                $ntfsWriter.Flush()
                Write-PshGoal6QualityExtraField -Writer $writer -HeaderId 0x000A -Data $ntfsStream.ToArray()
            }
            finally { $ntfsWriter.Dispose(); $ntfsStream.Dispose() }
        }

        $localUnix1 = New-Object byte[] 12
        for ($index = 0; $index -lt 8; $index++) { $localUnix1[$index] = $TimeByte }
        [Array]::Copy([byte[]]@(0x34, 0x12, 0x78, 0x56), 0, $localUnix1, 8, 4)
        Write-PshGoal6QualityExtraField -Writer $localWriter -HeaderId 0x5855 -Data $localUnix1
        Write-PshGoal6QualityExtraField -Writer $centralWriter -HeaderId 0x5855 -Data (New-PshGoal6QualityRepeatedBytes -Count 8 -Value $TimeByte)

        $pkwareUnix = New-Object byte[] 14
        for ($index = 0; $index -lt 8; $index++) { $pkwareUnix[$index] = $TimeByte }
        [Array]::Copy([byte[]]@(0x11, 0x11, 0x22, 0x22, 0x55, 0x66), 0, $pkwareUnix, 8, 6)
        Write-PshGoal6QualityExtraField -Writer $localWriter -HeaderId 0x000D -Data $pkwareUnix

        Write-PshGoal6QualityExtraField -Writer $localWriter -HeaderId 0xCAFE -Data ([byte[]]@($NonTimeByte, 0x77, 0x88))
        Write-PshGoal6QualityExtraField -Writer $centralWriter -HeaderId 0xCAFE -Data ([byte[]]@($NonTimeByte, 0x77, 0x88))
        $localWriter.Flush()
        $centralWriter.Flush()
        [byte[]]$localBytes = $localStream.ToArray()
        [byte[]]$centralBytes = $centralStream.ToArray()
        if ($MalformedExtendedLength) {
            $localBytes[2] = 12
            $localBytes[3] = 0
        }
        return [pscustomobject]@{
            local = $localBytes
            central = $centralBytes
        }
    }
    finally {
        $centralWriter.Dispose()
        $localWriter.Dispose()
        $centralStream.Dispose()
        $localStream.Dispose()
    }
}

function Set-PshGoal6QualityUInt16 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][uint16]$Value
    )

    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 2)
}

function Set-PshGoal6QualityUInt32 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][uint32]$Value
    )

    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 4)
}

function Add-PshGoal6QualityZipExtras {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][byte[]]$LocalExtra,
        [Parameter(Mandatory = $true)][byte[]]$CentralExtra
    )

    [byte[]]$source = [IO.File]::ReadAllBytes($SourcePath)
    $eocdOffset = $source.Length - 22
    Assert-PshGoal6Quality ([BitConverter]::ToUInt32($source, $eocdOffset) -eq 0x06054B50) 'Raw ZIP fixture is missing its expected EOCD record.'
    $centralOffset = [int][BitConverter]::ToUInt32($source, $eocdOffset + 16)
    $centralSize = [int][BitConverter]::ToUInt32($source, $eocdOffset + 12)
    Assert-PshGoal6Quality ([BitConverter]::ToUInt32($source, $centralOffset) -eq 0x02014B50) 'Raw ZIP fixture is missing its expected central header.'
    $localOffset = [int][BitConverter]::ToUInt32($source, $centralOffset + 42)
    $localNameLength = [int][BitConverter]::ToUInt16($source, $localOffset + 26)
    $localExtraLength = [int][BitConverter]::ToUInt16($source, $localOffset + 28)
    $centralNameLength = [int][BitConverter]::ToUInt16($source, $centralOffset + 28)
    $centralExtraLength = [int][BitConverter]::ToUInt16($source, $centralOffset + 30)
    $localInsertOffset = $localOffset + 30 + $localNameLength + $localExtraLength
    $centralInsertOffset = $centralOffset + 46 + $centralNameLength + $centralExtraLength

    $stream = New-Object IO.MemoryStream
    try {
        $stream.Write($source, 0, $localInsertOffset)
        $stream.Write($LocalExtra, 0, $LocalExtra.Length)
        $stream.Write($source, $localInsertOffset, $centralInsertOffset - $localInsertOffset)
        $stream.Write($CentralExtra, 0, $CentralExtra.Length)
        $stream.Write($source, $centralInsertOffset, $source.Length - $centralInsertOffset)
        [byte[]]$patched = $stream.ToArray()
    }
    finally { $stream.Dispose() }

    Set-PshGoal6QualityUInt16 -Bytes $patched -Offset ($localOffset + 28) -Value ([uint16]($localExtraLength + $LocalExtra.Length))
    $newCentralOffset = $centralOffset + $LocalExtra.Length
    Set-PshGoal6QualityUInt16 -Bytes $patched -Offset ($newCentralOffset + 30) -Value ([uint16]($centralExtraLength + $CentralExtra.Length))
    $newEocdOffset = $eocdOffset + $LocalExtra.Length + $CentralExtra.Length
    Set-PshGoal6QualityUInt32 -Bytes $patched -Offset ($newEocdOffset + 12) -Value ([uint32]($centralSize + $CentralExtra.Length))
    Set-PshGoal6QualityUInt32 -Bytes $patched -Offset ($newEocdOffset + 16) -Value ([uint32]$newCentralOffset)
    [IO.File]::WriteAllBytes($DestinationPath, $patched)
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $lockPath = Join-Path $repositoryRootPath 'scripts/goal6/ci-dependencies.lock.json'
    $lock = Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $lockPath
    Assert-PshGoal6Quality (@($lock.dependencies).Count -eq 3) 'The CI dependency lock does not contain exactly three dependencies.'
    Assert-PshGoal6Quality ((@($lock.dependencies | ForEach-Object { [string]$_.id }) -join '|') -ceq 'gitleaks|pester|psscriptanalyzer') 'The CI dependency order is not gitleaks, pester, psscriptanalyzer.'
    $pester = Get-PshGoal6Dependency -Lock $lock -Id pester
    Assert-PshGoal6Quality ([string]$pester.version -ceq '5.9.0' -and [string]$pester.license.spdxId -ceq 'Apache-2.0' -and -not [bool]$pester.license.packageContainsLicense) 'The pinned Pester package/license contract changed.'
    Assert-PshGoal6Quality ($null -eq $pester.license.archivePath -and [string]$pester.package.galleryHashAlgorithm -ceq 'SHA512') 'The Pester source-license or Gallery-hash policy changed.'

    $attributesText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath '.gitattributes')
    Assert-PshGoal6Quality ([regex]::Matches($attributesText, '(?m)^scripts/goal6/licenses/\*\* binary\r?$').Count -eq 1) 'Goal 6 retained licenses are not covered by exactly one binary Git attribute rule.'
    $gitCommand = @(Get-Command -Name git -CommandType Application -ErrorAction Stop)[0]
    foreach ($dependency in @($lock.dependencies)) {
        $licenseRelativePath = [string]$dependency.license.retainedPath
        $attributeOutput = @(& $gitCommand.Source -C $repositoryRootPath check-attr text binary -- $licenseRelativePath 2>&1)
        $attributeExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $global:LASTEXITCODE = 0
        $attributeLines = @($attributeOutput | ForEach-Object { [string]$_ })
        Assert-PshGoal6Quality ($attributeExitCode -eq 0) "Git attribute inspection failed for $licenseRelativePath."
        Assert-PshGoal6Quality ($attributeLines -ccontains ('{0}: text: unset' -f $licenseRelativePath)) "$licenseRelativePath is still eligible for checkout line-ending conversion."
        Assert-PshGoal6Quality ($attributeLines -ccontains ('{0}: binary: set' -f $licenseRelativePath)) "$licenseRelativePath is not marked binary."

        $workingTreeHashOutput = @(& $gitCommand.Source -C $repositoryRootPath hash-object --no-filters -- $licenseRelativePath 2>&1)
        $workingTreeHashExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $global:LASTEXITCODE = 0
        $workingTreeHashLines = @($workingTreeHashOutput | ForEach-Object { [string]$_ })
        Assert-PshGoal6Quality ($workingTreeHashExitCode -eq 0 -and $workingTreeHashLines.Count -eq 1 -and $workingTreeHashLines[0] -match '\A[0-9a-f]{40}\z') "Raw working-tree blob hashing failed for $licenseRelativePath."

        $committedHashOutput = @(& $gitCommand.Source -C $repositoryRootPath rev-parse ("HEAD:$licenseRelativePath") 2>&1)
        $committedHashExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $global:LASTEXITCODE = 0
        $committedHashLines = @($committedHashOutput | ForEach-Object { [string]$_ })
        Assert-PshGoal6Quality ($committedHashExitCode -eq 0 -and $committedHashLines.Count -eq 1 -and $committedHashLines[0] -match '\A[0-9a-f]{40}\z') "Committed blob lookup failed for $licenseRelativePath."
        Assert-PshGoal6Quality ($workingTreeHashLines[0] -ceq $committedHashLines[0]) "$licenseRelativePath working-tree bytes differ from the committed blob."
    }

    $analyzerGateText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'scripts/goal6/Invoke-Goal6PSScriptAnalyzer.ps1')
    Assert-PshGoal6Quality ($analyzerGateText -match '\bIncludeSuppressed\b' -and $analyzerGateText -match '\bIsSuppressed\b' -and $analyzerGateText -match '\bSuppressMessage(Attribute)?\b') 'The analyzer gate no longer includes and audits suppressed diagnostics and attributes.'
    $secretGateText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'scripts/goal6/Invoke-Goal6SecretScan.ps1')
    Assert-PshGoal6Quality ($secretGateText -match [regex]::Escape('--log-opts=--all') -and $secretGateText -match '\bAssert-PshGoal6RemoteRefCoverage\b') 'The secret gate no longer explicitly scans all refs after remote parity validation.'
    Assert-PshGoal6Quality ($secretGateText -match '\bGITLEAKS_CONFIG\b' -and $secretGateText -match '\bGITLEAKS_CONFIG_TOML\b' -and $secretGateText -match [regex]::Escape('--gitleaks-ignore-path')) 'The secret gate no longer rejects inherited gitleaks configuration or fixes the ignore root.'

    $secretScriptPath = Join-Path $repositoryRootPath 'scripts/goal6/Invoke-Goal6SecretScan.ps1'
    $zeroRuleConfigPath = Join-Path $testRoot 'zero-rule-gitleaks.toml'
    Write-PshGoal6Text -Path $zeroRuleConfigPath -Text "title = 'zero rules'`n"
    $gitleaksEnvironmentNames = @('GITLEAKS_CONFIG', 'GITLEAKS_CONFIG_TOML')
    $originalGitleaksEnvironment = @{}
    foreach ($name in $gitleaksEnvironmentNames) { $originalGitleaksEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process) }
    try {
        foreach ($name in $gitleaksEnvironmentNames) {
            foreach ($clearName in $gitleaksEnvironmentNames) { Remove-Item -LiteralPath ("Env:$clearName") -ErrorAction SilentlyContinue }
            $value = if ($name -ceq 'GITLEAKS_CONFIG') { $zeroRuleConfigPath } else { "title = 'zero rules'`n" }
            [Environment]::SetEnvironmentVariable($name, $value, [EnvironmentVariableTarget]::Process)
            $secretReportRoot = Join-Path $testRoot ('secret-env-' + $name.ToLowerInvariant())
            $secretFailure = $null
            try { $null = & $secretScriptPath -DependencyRoot (Join-Path $testRoot 'missing-secret-dependencies') -ReportRoot $secretReportRoot -RepositoryRoot $repositoryRootPath }
            catch { $secretFailure = [string]$_.Exception.Message }
            Assert-PshGoal6Quality ($secretFailure -match [regex]::Escape($name) -and $secretFailure -match 'unset') "Secret scan did not reject inherited $name before dependency probing."
            $secretSummary = (Get-PshGoal6StrictText -Path (Join-Path $secretReportRoot 'gitleaks-summary.json')) | ConvertFrom-Json -ErrorAction Stop
            Assert-PshGoal6Quality ([string]$secretSummary.status -ceq 'failed' -and [string]$secretSummary.error -match [regex]::Escape($name)) "Secret scan summary did not record inherited $name as a failed gate."
        }
    }
    finally {
        foreach ($name in $gitleaksEnvironmentNames) {
            if ($null -eq $originalGitleaksEnvironment[$name]) { Remove-Item -LiteralPath ("Env:$name") -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, [string]$originalGitleaksEnvironment[$name], [EnvironmentVariableTarget]::Process) }
        }
    }

    $secretCaptureRoot = Join-Path $testRoot 'secret-capture-cardinality'
    $secretFixtureRoot = Join-Path $secretCaptureRoot 'fixture'
    $secretDependencyRoot = Join-Path $secretCaptureRoot 'dependencies'
    $secretRemoteRoot = Join-Path $secretCaptureRoot 'origin.git'
    $secretSeedRoot = Join-Path $secretCaptureRoot 'seed'
    $secretWorktreeRoot = Join-Path $secretCaptureRoot 'worktree'
    $secretCaptureReportRoot = Join-Path $secretCaptureRoot 'reports'
    foreach ($path in @($secretFixtureRoot, $secretDependencyRoot)) { [void][IO.Directory]::CreateDirectory($path) }
    [IO.File]::Copy($secretScriptPath, (Join-Path $secretFixtureRoot 'Invoke-Goal6SecretScan.ps1'))
    Write-PshGoal6Text -Path (Join-Path $secretFixtureRoot 'Goal6.Common.ps1') -Text @'
function Assert-PshGoal6Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Write-PshGoal6Text {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Get-PshGoal6StrictText {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
}
function Write-PshGoal6Json {
    param([string]$Path, $InputObject)
    Write-PshGoal6Text -Path $Path -Text (($InputObject | ConvertTo-Json -Depth 20) + "`n")
}
function Read-PshGoal6DependencyLock {
    return [pscustomobject]@{
        dependencies = @([pscustomobject]@{
            id = 'gitleaks'
            version = '8.30.1'
            package = [pscustomobject]@{
                installedRelativePath = 'gitleaks-stub.ps1'
                installedSha256 = 'fixture-sha256'
                peMachine = 'fixture-machine'
            }
        })
    }
}
function Get-PshGoal6Dependency {
    param($Lock, [string]$Id)
    return @($Lock.dependencies | Where-Object { [string]$_.id -ceq $Id })[0]
}
function Resolve-PshGoal6RelativePath {
    param([string]$Root, [string]$RelativePath, [string]$Description)
    return Join-Path $Root $RelativePath
}
function Get-PshGoal6Sha256 { return 'fixture-sha256' }
function Get-PshGoal6PeMachine { return 'fixture-machine' }
function Assert-PshGoal6RemoteRefCoverage {
    param(
        [AllowEmptyCollection()][string[]]$RemoteLines,
        [AllowEmptyCollection()][string[]]$LocalBranchLines,
        [AllowEmptyCollection()][string[]]$LocalTagLines
    )
    $remoteBranches = @($RemoteLines | Where-Object { $_ -match '\srefs/heads/' })
    $remoteTags = @($RemoteLines | Where-Object { $_ -match '\srefs/tags/' })
    $localBranches = @($LocalBranchLines | Where-Object { $_ -match '\srefs/remotes/origin/' -and $_ -notmatch '\srefs/remotes/origin/HEAD$' })
    if ($remoteBranches.Count -ne $localBranches.Count -or $remoteTags.Count -ne $LocalTagLines.Count) { throw 'fixture remote-ref parity failed' }
    return [pscustomobject][ordered]@{
        remoteRefCount = $RemoteLines.Count
        branchCount = $remoteBranches.Count
        tagCount = $remoteTags.Count
        parity = 'exact'
    }
}
'@
    Write-PshGoal6Text -Path (Join-Path $secretDependencyRoot 'gitleaks-stub.ps1') -Text @'
$arguments = @($args | ForEach-Object { [string]$_ })
if ($arguments.Count -eq 1 -and $arguments[0] -ceq 'version') {
    Write-Output 'gitleaks version 8.30.1'
    $global:LASTEXITCODE = 0
    return
}
$reportIndex = [Array]::IndexOf($arguments, '--report-path')
if ($reportIndex -lt 0 -or $reportIndex + 1 -ge $arguments.Count) { throw 'fixture gitleaks invocation omitted --report-path' }
[IO.File]::WriteAllText($arguments[$reportIndex + 1], "[]`n", (New-Object Text.UTF8Encoding($false)))
$global:LASTEXITCODE = 0
'@

    $gitFixtureCommands = @(
        @('init', '--bare', $secretRemoteRoot),
        @('init', '-b', 'main', $secretSeedRoot),
        @('-C', $secretSeedRoot, 'config', 'user.name', 'Goal 6 Fixture'),
        @('-C', $secretSeedRoot, 'config', 'user.email', 'goal6@example.invalid')
    )
    foreach ($arguments in $gitFixtureCommands) {
        $gitFixtureOutput = @(& $gitCommand.Source @arguments 2>&1)
        $gitFixtureExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $global:LASTEXITCODE = 0
        Assert-PshGoal6Quality ($gitFixtureExitCode -eq 0) "Git secret-capture fixture setup failed: $($gitFixtureOutput -join ' ')"
    }
    Write-PshGoal6Text -Path (Join-Path $secretSeedRoot 'fixture.txt') -Text "secret capture fixture`n"
    foreach ($arguments in @(
        @('-C', $secretSeedRoot, 'add', 'fixture.txt'),
        @('-C', $secretSeedRoot, 'commit', '-m', 'fixture'),
        @('-C', $secretSeedRoot, 'remote', 'add', 'origin', $secretRemoteRoot),
        @('-C', $secretSeedRoot, 'push', '-u', 'origin', 'main'),
        @('-C', $secretSeedRoot, 'branch', 'release'),
        @('-C', $secretSeedRoot, 'push', 'origin', 'release'),
        @('--git-dir', $secretRemoteRoot, 'symbolic-ref', 'HEAD', 'refs/heads/main'),
        @('clone', $secretRemoteRoot, $secretWorktreeRoot),
        @('-C', $secretWorktreeRoot, 'fetch', 'origin', '+refs/heads/*:refs/remotes/origin/*', '--prune')
    )) {
        $gitFixtureOutput = @(& $gitCommand.Source @arguments 2>&1)
        $gitFixtureExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $global:LASTEXITCODE = 0
        Assert-PshGoal6Quality ($gitFixtureExitCode -eq 0) "Git secret-capture fixture setup failed: $($gitFixtureOutput -join ' ')"
    }

    $secretFixtureScriptPath = Join-Path $secretFixtureRoot 'Invoke-Goal6SecretScan.ps1'
    $secretFixtureOutput = @(& $secretFixtureScriptPath -DependencyRoot $secretDependencyRoot -ReportRoot $secretCaptureReportRoot -RepositoryRoot $secretWorktreeRoot -LockPath (Join-Path $secretFixtureRoot 'fixture.lock.json'))
    $secretFixtureExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $global:LASTEXITCODE = 0
    Assert-PshGoal6Quality ($secretFixtureExitCode -eq 0 -and ($secretFixtureOutput -join "`n") -match 'passed for full Git history and worktree scans') 'Secret scan did not survive singleton, empty, and multi-line Git capture output.'
    $secretCaptureSummary = (Get-PshGoal6StrictText -Path (Join-Path $secretCaptureReportRoot 'gitleaks-summary.json')) | ConvertFrom-Json -ErrorAction Stop
    Assert-PshGoal6Quality ([string]$secretCaptureSummary.status -ceq 'passed' -and $null -eq $secretCaptureSummary.error) 'Secret scan cardinality regression did not produce a passing summary.'
    Assert-PshGoal6Quality ([int]$secretCaptureSummary.remoteRefCoverage.remoteRefCount -eq 2 -and [int]$secretCaptureSummary.remoteRefCoverage.branchCount -eq 2 -and [int]$secretCaptureSummary.remoteRefCoverage.tagCount -eq 0 -and [string]$secretCaptureSummary.remoteRefCoverage.parity -ceq 'exact') 'Secret scan did not preserve exact remote-ref coverage for multi-line branches and empty tags.'
    $secretCaptureScans = @($secretCaptureSummary.scans)
    Assert-PshGoal6Quality ($secretCaptureScans.Count -eq 2 -and (@($secretCaptureScans | ForEach-Object { [string]$_.mode }) -join '|') -ceq 'git|dir' -and @($secretCaptureScans | Where-Object { [string]$_.status -cne 'passed' -or [int]$_.findingCount -ne 0 }).Count -eq 0) 'Secret scan cardinality regression did not preserve both zero-finding gitleaks scans.'

    $leafTraversalLock = New-PshGoal6QualityLockCopy -Name 'package-file-name-traversal' -Mutation {
        param($value)
        $value.dependencies[0].package.fileName = '../escape.zip'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $leafTraversalLock } -MessagePattern 'single file leaf name' -Description 'Package fileName traversal'

    $licenseTraversalLock = New-PshGoal6QualityLockCopy -Name 'license-archive-path-traversal' -Mutation {
        param($value)
        $value.dependencies[0].license.archivePath = '../LICENSE'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $licenseTraversalLock } -MessagePattern 'traversal segment' -Description 'License archivePath traversal'

    $repositoryLock = New-PshGoal6QualityLockCopy -Name 'untrusted-repository' -Mutation {
        param($value)
        $value.dependencies[0].source.repository = 'https://example.invalid/gitleaks'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $repositoryLock } -MessagePattern 'repository is not trusted' -Description 'Untrusted dependency repository'

    $tagLock = New-PshGoal6QualityLockCopy -Name 'untrusted-tag' -Mutation {
        param($value)
        $value.dependencies[1].source.tag = '5.9.1'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $tagLock } -MessagePattern 'source tag changed' -Description 'Untrusted dependency tag'

    $urlLock = New-PshGoal6QualityLockCopy -Name 'untrusted-package-url' -Mutation {
        param($value)
        $value.dependencies[2].package.url = 'https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/1.25.0?alternate=1'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $urlLock } -MessagePattern 'package URL changed' -Description 'Untrusted dependency package URL'

    $remoteRefs = @(
        '1111111111111111111111111111111111111111 refs/heads/main',
        '2222222222222222222222222222222222222222 refs/heads/release',
        '3333333333333333333333333333333333333333 refs/tags/v0.1.0'
    )
    $localBranches = @(
        '1111111111111111111111111111111111111111 refs/remotes/origin/main',
        '2222222222222222222222222222222222222222 refs/remotes/origin/release'
    )
    $localTags = @('3333333333333333333333333333333333333333 refs/tags/v0.1.0')
    $coverage = Assert-PshGoal6RemoteRefCoverage -RemoteLines $remoteRefs -LocalBranchLines $localBranches -LocalTagLines $localTags
    Assert-PshGoal6Quality ([int]$coverage.branchCount -eq 2 -and [int]$coverage.tagCount -eq 1 -and [string]$coverage.parity -ceq 'exact') 'Exact remote-ref coverage did not pass.'
    Assert-PshGoal6QualityThrows -Action { Assert-PshGoal6RemoteRefCoverage -RemoteLines $remoteRefs -LocalBranchLines @($localBranches[0]) -LocalTagLines $localTags } -MessagePattern 'missing-local:refs/heads/release' -Description 'Missing remote branch coverage'
    Assert-PshGoal6QualityThrows -Action { Assert-PshGoal6RemoteRefCoverage -RemoteLines $remoteRefs -LocalBranchLines $localBranches -LocalTagLines @() } -MessagePattern 'missing-local:refs/tags/v0.1.0' -Description 'Missing remote tag coverage'

    $stagingRoot = Join-Path $testRoot 'dependency.staging'
    $destinationRoot = Join-Path $testRoot 'dependency.committed'
    $invalidSummaryPath = Join-Path $testRoot 'summary-as-directory'
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    [void][IO.File]::WriteAllText((Join-Path $stagingRoot 'marker.txt'), 'committed bytes')
    [void][IO.Directory]::CreateDirectory($invalidSummaryPath)
    Assert-PshGoal6QualityThrows -Action { Complete-PshGoal6DependencyInstall -StagingRoot $stagingRoot -DestinationRoot $destinationRoot -SummaryPath $invalidSummaryPath -Summary ([pscustomobject]@{ status = 'passed' }) } -MessagePattern 'committed dependency directory was rolled back' -Description 'Dependency summary transaction'
    Assert-PshGoal6Quality (-not [IO.Directory]::Exists($stagingRoot) -and -not [IO.Directory]::Exists($destinationRoot)) 'Dependency summary failure left staging or committed dependency bytes behind.'

    $rewriteStagingRoot = Join-Path $testRoot 'rewrite.staging'
    $rewriteDestinationRoot = Join-Path $testRoot 'rewrite.committed'
    $rewriteSummaryPath = Join-Path $testRoot 'rewrite-summary.json'
    [void][IO.Directory]::CreateDirectory($rewriteStagingRoot)
    [void][IO.File]::WriteAllText((Join-Path $rewriteStagingRoot 'marker.txt'), 'committed bytes')
    $rewriteSummary = [pscustomobject][ordered]@{ status = 'passed'; error = $null; rollback = $null }
    $originalJsonWriter = (Get-Command -Name Write-PshGoal6Json -CommandType Function -ErrorAction Stop).ScriptBlock
    $script:PshGoal6QualityOriginalJsonWriter = $originalJsonWriter
    $script:PshGoal6QualityJsonWriteCalls = 0
    try {
        Set-Item -LiteralPath Function:Write-PshGoal6Json -Value {
            param([string]$Path, [object]$InputObject)
            $script:PshGoal6QualityJsonWriteCalls++
            if ($script:PshGoal6QualityJsonWriteCalls -eq 1) { throw 'controlled first summary write failure' }
            & $script:PshGoal6QualityOriginalJsonWriter -Path $Path -InputObject $InputObject
        }
        Assert-PshGoal6QualityThrows -Action { Complete-PshGoal6DependencyInstall -StagingRoot $rewriteStagingRoot -DestinationRoot $rewriteDestinationRoot -SummaryPath $rewriteSummaryPath -Summary $rewriteSummary } -MessagePattern 'committed dependency directory was rolled back' -Description 'Dependency failed-summary rewrite transaction'
    }
    finally {
        Set-Item -LiteralPath Function:Write-PshGoal6Json -Value $originalJsonWriter
        Remove-Variable -Name PshGoal6QualityOriginalJsonWriter, PshGoal6QualityJsonWriteCalls -Scope Script -ErrorAction SilentlyContinue
    }
    $rewrittenSummary = (Get-PshGoal6StrictText -Path $rewriteSummaryPath) | ConvertFrom-Json -ErrorAction Stop
    Assert-PshGoal6Quality (-not [IO.Directory]::Exists($rewriteStagingRoot) -and -not [IO.Directory]::Exists($rewriteDestinationRoot)) 'Failed summary rewrite left staging or committed dependency bytes behind.'
    Assert-PshGoal6Quality ([string]$rewrittenSummary.status -ceq 'failed' -and [string]$rewrittenSummary.error -match 'controlled first summary write failure') 'Rewritten dependency failure summary still claims success or lost the original error.'
    Assert-PshGoal6Quality ([bool]$rewrittenSummary.rollback.attempted -and [bool]$rewrittenSummary.rollback.succeeded -and $null -eq $rewrittenSummary.rollback.error) 'Rewritten dependency failure summary lost successful rollback facts.'

    $firstZip = Join-Path $testRoot 'first.zip'
    $timestampZip = Join-Path $testRoot 'timestamp-only.zip'
    $reorderedZip = Join-Path $testRoot 'reordered.zip'
    New-PshGoal6QualityZip -Path $firstZip -EntryNames @('alpha.txt', 'nested/beta.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero))
    New-PshGoal6QualityZip -Path $timestampZip -EntryNames @('alpha.txt', 'nested/beta.txt') -Timestamp (New-Object DateTimeOffset(2026, 2, 3, 4, 5, 8, [TimeSpan]::Zero))
    New-PshGoal6QualityZip -Path $reorderedZip -EntryNames @('nested/beta.txt', 'alpha.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero))
    $firstManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $firstZip -DisplayPath 'fixture.zip'
    $timestampManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $timestampZip -DisplayPath 'fixture.zip'
    $reorderedManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $reorderedZip -DisplayPath 'fixture.zip'
    Assert-PshGoal6Quality ([string]$firstManifest.containerSha256Informational -cne [string]$timestampManifest.containerSha256Informational) 'Timestamp fixture did not change raw ZIP bytes.'
    Assert-PshGoal6Quality ([string]$firstManifest.timestampNormalizedContainerSha256 -ceq [string]$timestampManifest.timestampNormalizedContainerSha256) 'Timestamp-only ZIP differences were not normalized.'
    Assert-PshGoal6Quality (@(Compare-PshGoal6ZipArchiveManifest -First $firstManifest -Second $timestampManifest).Count -eq 0) 'Timestamp-only ZIP differences reached the reproducibility diff.'
    $orderDifferences = @(Compare-PshGoal6ZipArchiveManifest -First $firstManifest -Second $reorderedManifest)
    Assert-PshGoal6Quality (@($orderDifferences | Where-Object { [string]$_.kind -ceq 'archive-entry-order' }).Count -gt 0) 'ZIP entry order was not hard-compared.'

    $extraBaseZip = Join-Path $testRoot 'extra-base.zip'
    $extraFirstZip = Join-Path $testRoot 'extra-first.zip'
    $extraTimestampZip = Join-Path $testRoot 'extra-timestamp-only.zip'
    $extraNonTimeZip = Join-Path $testRoot 'extra-nontime.zip'
    $extraFlagsZip = Join-Path $testRoot 'extra-flags.zip'
    $extraMalformedZip = Join-Path $testRoot 'extra-malformed.zip'
    $extraMalformedNtfsZip = Join-Path $testRoot 'extra-malformed-ntfs.zip'
    New-PshGoal6QualityZip -Path $extraBaseZip -EntryNames @('extra.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero))
    $extraFirst = New-PshGoal6QualityTimestampExtras -TimeByte 0x11
    $extraTimestamp = New-PshGoal6QualityTimestampExtras -TimeByte 0x22
    $extraNonTime = New-PshGoal6QualityTimestampExtras -TimeByte 0x11 -NonTimeByte 0x99
    $extraFlags = New-PshGoal6QualityTimestampExtras -TimeByte 0x11 -CentralFlags 0x05
    $extraMalformed = New-PshGoal6QualityTimestampExtras -TimeByte 0x11 -MalformedExtendedLength
    $extraMalformedNtfs = New-PshGoal6QualityTimestampExtras -TimeByte 0x11 -MalformedNtfsFileTimeLength
    Add-PshGoal6QualityZipExtras -SourcePath $extraBaseZip -DestinationPath $extraFirstZip -LocalExtra $extraFirst.local -CentralExtra $extraFirst.central
    Add-PshGoal6QualityZipExtras -SourcePath $extraBaseZip -DestinationPath $extraTimestampZip -LocalExtra $extraTimestamp.local -CentralExtra $extraTimestamp.central
    Add-PshGoal6QualityZipExtras -SourcePath $extraBaseZip -DestinationPath $extraNonTimeZip -LocalExtra $extraNonTime.local -CentralExtra $extraNonTime.central
    Add-PshGoal6QualityZipExtras -SourcePath $extraBaseZip -DestinationPath $extraFlagsZip -LocalExtra $extraFlags.local -CentralExtra $extraFlags.central
    Add-PshGoal6QualityZipExtras -SourcePath $extraBaseZip -DestinationPath $extraMalformedZip -LocalExtra $extraMalformed.local -CentralExtra $extraMalformed.central
    Add-PshGoal6QualityZipExtras -SourcePath $extraBaseZip -DestinationPath $extraMalformedNtfsZip -LocalExtra $extraMalformedNtfs.local -CentralExtra $extraMalformedNtfs.central
    $extraFirstManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $extraFirstZip -DisplayPath 'extra.zip'
    $extraTimestampManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $extraTimestampZip -DisplayPath 'extra.zip'
    $extraNonTimeManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $extraNonTimeZip -DisplayPath 'extra.zip'
    $extraFlagsManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $extraFlagsZip -DisplayPath 'extra.zip'
    Assert-PshGoal6Quality ([string]$extraFirstManifest.containerSha256Informational -cne [string]$extraTimestampManifest.containerSha256Informational) 'Extra-field timestamp fixture did not change raw ZIP bytes.'
    Assert-PshGoal6Quality ([string]$extraFirstManifest.timestampNormalizedContainerSha256 -ceq [string]$extraTimestampManifest.timestampNormalizedContainerSha256 -and @(Compare-PshGoal6ZipArchiveManifest -First $extraFirstManifest -Second $extraTimestampManifest).Count -eq 0) 'Standard ZIP extra-field timestamp payloads were not exclusively normalized.'
    Assert-PshGoal6Quality (@(Compare-PshGoal6ZipArchiveManifest -First $extraFirstManifest -Second $extraNonTimeManifest).Count -gt 0) 'Non-time ZIP extra-field bytes were incorrectly normalized.'
    Assert-PshGoal6Quality (@(Compare-PshGoal6ZipArchiveManifest -First $extraFirstManifest -Second $extraFlagsManifest).Count -gt 0) 'ZIP extra-field flags were incorrectly normalized.'
    Assert-PshGoal6QualityThrows -Action { Get-PshGoal6ZipArchiveManifest -ArchivePath $extraMalformedZip -DisplayPath 'extra-malformed.zip' } -MessagePattern 'extended-timestamp extra-field length' -Description 'Malformed ZIP extended-timestamp extra length'
    Assert-PshGoal6QualityThrows -Action { Get-PshGoal6ZipArchiveManifest -ArchivePath $extraMalformedNtfsZip -DisplayPath 'extra-malformed-ntfs.zip' } -MessagePattern 'NTFS FILETIME attribute length' -Description 'Malformed ZIP NTFS FILETIME length'

    $metadataMutation = (($firstManifest | ConvertTo-Json -Depth 20) | ConvertFrom-Json -ErrorAction Stop)
    $metadataMutation.archiveCommentBase64 = 'Y29tbWVudA=='
    $metadataMutation.entries[0].flags = '0x0808'
    $metadataMutation.entries[0].compressionMethod = 0
    $metadataMutation.entries[0].centralExtraBase64 = 'AQID'
    $metadataMutation.entries[0].entryCommentBase64 = 'BAUG'
    $metadataMutation.entries[0].localExtraBase64 = 'BwgJ'
    $metadataMutation.entries[0].externalAttributes = '0x00000020'
    $metadataDifferences = @(Compare-PshGoal6ZipArchiveManifest -First $firstManifest -Second $metadataMutation)
    $metadataKinds = @($metadataDifferences | ForEach-Object { [string]$_.kind })
    foreach ($requiredKind in @('archive-comment', 'archive-entry-flags', 'archive-entry-compressionMethod', 'archive-entry-centralExtraBase64', 'archive-entry-entryCommentBase64', 'archive-entry-localExtraBase64', 'archive-entry-externalAttributes')) {
        Assert-PshGoal6Quality ($metadataKinds -ccontains $requiredKind) "ZIP metadata comparison omitted $requiredKind."
    }

    $reparseZip = Join-Path $testRoot 'reparse.zip'
    New-PshGoal6QualityZip -Path $reparseZip -EntryNames @('reparse.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero)) -ExternalAttributes 0x400
    Assert-PshGoal6QualityThrows -Action { Get-PshGoal6ZipArchiveManifest -ArchivePath $reparseZip -DisplayPath 'reparse.zip' } -MessagePattern 'reparse-point entry' -Description 'ZIP reparse-point semantics'

    $symlinkZip = Join-Path $testRoot 'symlink.zip'
    $symlinkAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([Convert]::ToUInt32('A1FF0000', 16)), 0)
    New-PshGoal6QualityZip -Path $symlinkZip -EntryNames @('link.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero)) -ExternalAttributes $symlinkAttributes
    Assert-PshGoal6QualityThrows -Action { Get-PshGoal6ZipArchiveManifest -ArchivePath $symlinkZip -DisplayPath 'symlink.zip' } -MessagePattern 'symbolic-link entry' -Description 'ZIP symbolic-link semantics'

    Write-Output "Goal 6 quality-gate regression passed: $assertionCount assertions."
    $global:LASTEXITCODE = 0
}
finally {
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

$global:LASTEXITCODE = 0
