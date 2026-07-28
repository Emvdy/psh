# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CatalogBuilderPath,
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)][string]$ReportRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Goal6CatalogAssertions = 0

function Assert-PshGoal6Catalog {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)

    $script:Goal6CatalogAssertions++
    if (-not $Condition) { throw "Goal 6 catalog builder failed: $Message" }
}

function Write-PshGoal6CatalogText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false, $true)))
}

function Get-PshGoal6CatalogSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ([string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
}

function Get-PshGoal6CatalogOrderedNames {
    param([Parameter(Mandatory = $true)][object]$Dictionary)

    [string[]]$names = @($Dictionary.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return $names
}

function Invoke-PshGoal6CatalogBuilder {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][object[]]$Members,
        [switch]$ExpectFailure
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add($CatalogBuilderPath)
    $arguments.Add('--output')
    $arguments.Add($OutputPath)
    foreach ($member in $Members) {
        $arguments.Add('--member')
        $arguments.Add([string]$member.Name)
        $arguments.Add([string]$member.SourcePath)
    }
    [string[]]$argumentArray = $arguments.ToArray()

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $script:Goal6CatalogHostPath @argumentArray 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        $global:LASTEXITCODE = 0
    }

    $diagnostic = @($output | ForEach-Object { [string]$_ }) -join ' '
    if ($ExpectFailure) {
        Assert-PshGoal6Catalog ($exitCode -ne 0 -and -not [IO.File]::Exists($OutputPath) -and -not [IO.Directory]::Exists($OutputPath)) "Invalid catalog input succeeded or retained output: $diagnostic"
        return
    }

    Assert-PshGoal6Catalog ($exitCode -eq 0) "Catalog builder exited with code ${exitCode}: $diagnostic"
    Assert-PshGoal6Catalog ([IO.File]::Exists($OutputPath) -and ([IO.FileInfo]$OutputPath).Length -gt 0) "Catalog output is missing or empty: $OutputPath"
}

function Get-PshGoal6CatalogInformation {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$CatalogPath)

    return & $script:Goal6CatalogTestCommand -Path $Root -CatalogFilePath $CatalogPath -Detailed -ErrorAction Stop
}

function Assert-PshGoal6CatalogValid {
    param(
        [Parameter(Mandatory = $true)][object]$Information,
        [Parameter(Mandatory = $true)][hashtable]$Expected
    )

    Assert-PshGoal6Catalog ([string]$Information.Status -ceq 'Valid') "Catalog status is not Valid: $($Information.Status)"
    Assert-PshGoal6Catalog ([string]$Information.HashAlgorithm -ceq 'SHA256') "Catalog hash algorithm is not SHA256: $($Information.HashAlgorithm)"
    Assert-PshGoal6Catalog ($Information.CatalogItems.Count -eq $Expected.Count -and $Information.PathItems.Count -eq $Expected.Count) 'CatalogItems or PathItems count differs from the expected exact set.'

    [string[]]$expectedNames = @($Expected.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($expectedNames, [StringComparer]::Ordinal)
    [string[]]$catalogNames = @(Get-PshGoal6CatalogOrderedNames -Dictionary $Information.CatalogItems)
    [string[]]$pathNames = @(Get-PshGoal6CatalogOrderedNames -Dictionary $Information.PathItems)
    Assert-PshGoal6Catalog (($catalogNames -join '|') -ceq ($expectedNames -join '|')) 'CatalogItems names differ from the exact logical paths.'
    Assert-PshGoal6Catalog (($pathNames -join '|') -ceq ($expectedNames -join '|')) 'PathItems names differ from the exact logical paths.'
    foreach ($name in $expectedNames) {
        $expectedHash = [string]$Expected[$name]
        Assert-PshGoal6Catalog ([string]$Information.CatalogItems[$name] -ceq $expectedHash) "CatalogItems hash differs for '$name'."
        Assert-PshGoal6Catalog ([string]$Information.PathItems[$name] -ceq $expectedHash) "PathItems hash differs for '$name'."
    }
}

function Copy-PshGoal6CatalogFiles {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)

    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -File -Recurse)) {
        $relativePath = $file.FullName.Substring($Source.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $target = Join-Path $Destination $relativePath
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($file.FullName, $target, $false)
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Goal 6 catalog builder validation requires Windows Test-FileCatalog.'
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$reportRootPath = [IO.Path]::GetFullPath($ReportRoot)
$CatalogBuilderPath = [IO.Path]::GetFullPath($CatalogBuilderPath)
$script:Goal6CatalogHostPath = [string](@(Get-Command -Name dotnet -CommandType Application -ErrorAction Stop)[0].Source)
$script:Goal6CatalogTestCommand = Get-Command -Name Test-FileCatalog -CommandType Cmdlet -ErrorAction Stop
Assert-PshGoal6Catalog ([IO.Directory]::Exists($repositoryRootPath)) "Repository root is missing: $repositoryRootPath"
Assert-PshGoal6Catalog ([IO.File]::Exists($CatalogBuilderPath) -and ([IO.FileInfo]$CatalogBuilderPath).Length -gt 0) "Catalog builder is missing or empty: $CatalogBuilderPath"
[void][IO.Directory]::CreateDirectory($reportRootPath)
$workRoot = Join-Path $reportRootPath 'catalog-builder-work'
Assert-PshGoal6Catalog (-not [IO.File]::Exists($workRoot) -and -not [IO.Directory]::Exists($workRoot)) "Catalog work root already exists: $workRoot"
[void][IO.Directory]::CreateDirectory($workRoot)

$rootOne = Join-Path $workRoot 'absolute root one'
$rootTwo = Join-Path $workRoot 'absolute root two'
$unicodeDirectoryName = -join @([char]0x5B50, [char]0x76EE, [char]0x5F55, [char]0x20, [char]0x4E2D, [char]0x6587)
$unicodeFileName = (-join @([char]0x6587, [char]0x4EF6, [char]0x20, [char]0x7A7A, [char]0x683C)) + '.txt'
$unicodeInputLogicalPath = $unicodeDirectoryName + '/' + $unicodeFileName
$unicodeExpectedLogicalPath = $unicodeDirectoryName + '\' + $unicodeFileName
foreach ($root in @($rootOne, $rootTwo)) {
    [void][IO.Directory]::CreateDirectory((Join-Path $root $unicodeDirectoryName))
    Write-PshGoal6CatalogText -Path (Join-Path $root 'a.txt') -Text "identical-content`n"
    Write-PshGoal6CatalogText -Path (Join-Path (Join-Path $root $unicodeDirectoryName) $unicodeFileName) -Text "identical-content`n"
}

$catalogOne = Join-Path $workRoot 'deterministic-one.cat'
$catalogTwo = Join-Path $workRoot 'deterministic-two.cat'
Invoke-PshGoal6CatalogBuilder -OutputPath $catalogOne -Members @(
    [pscustomobject]@{ Name = 'a.txt'; SourcePath = (Join-Path $rootOne 'a.txt') },
    [pscustomobject]@{ Name = $unicodeInputLogicalPath; SourcePath = (Join-Path (Join-Path $rootOne $unicodeDirectoryName) $unicodeFileName) }
)
Invoke-PshGoal6CatalogBuilder -OutputPath $catalogTwo -Members @(
    [pscustomobject]@{ Name = $unicodeInputLogicalPath; SourcePath = (Join-Path (Join-Path $rootTwo $unicodeDirectoryName) $unicodeFileName) },
    [pscustomobject]@{ Name = 'a.txt'; SourcePath = (Join-Path $rootTwo 'a.txt') }
)
$catalogOneBytes = [IO.File]::ReadAllBytes($catalogOne)
$catalogTwoBytes = [IO.File]::ReadAllBytes($catalogTwo)
Assert-PshGoal6Catalog ($catalogOneBytes.Length -eq $catalogTwoBytes.Length -and [Convert]::ToBase64String($catalogOneBytes) -ceq [Convert]::ToBase64String($catalogTwoBytes)) 'Catalog bytes differ across absolute roots or input order.'
$deterministicSha256 = Get-PshGoal6CatalogSha256 -Path $catalogOne
Assert-PshGoal6Catalog ((Get-PshGoal6CatalogSha256 -Path $catalogTwo) -ceq $deterministicSha256) 'Catalog SHA256 differs across absolute roots.'
$duplicateContentExpected = @{
    'a.txt' = Get-PshGoal6CatalogSha256 -Path (Join-Path $rootOne 'a.txt')
    $unicodeExpectedLogicalPath = Get-PshGoal6CatalogSha256 -Path (Join-Path (Join-Path $rootOne $unicodeDirectoryName) $unicodeFileName)
}
Assert-PshGoal6CatalogValid -Information (Get-PshGoal6CatalogInformation -Root $rootOne -CatalogPath $catalogOne) -Expected $duplicateContentExpected
Assert-PshGoal6CatalogValid -Information (Get-PshGoal6CatalogInformation -Root $rootTwo -CatalogPath $catalogTwo) -Expected $duplicateContentExpected

$packageRoot = Join-Path $workRoot 'package-root'
[void][IO.Directory]::CreateDirectory($packageRoot)
$packageManifestPath = Join-Path $packageRoot 'package.manifest.json'
Write-PshGoal6CatalogText -Path $packageManifestPath -Text "{`"schemaVersion`":1}`n"
$packageCatalog = Join-Path $workRoot 'package.manifest.cat'
Invoke-PshGoal6CatalogBuilder -OutputPath $packageCatalog -Members @([pscustomobject]@{ Name = 'package.manifest.json'; SourcePath = $packageManifestPath })
Assert-PshGoal6CatalogValid -Information (Get-PshGoal6CatalogInformation -Root $packageRoot -CatalogPath $packageCatalog) -Expected @{
    'package.manifest.json' = Get-PshGoal6CatalogSha256 -Path $packageManifestPath
}

$releaseRoot = Join-Path $workRoot 'release-root'
[void][IO.Directory]::CreateDirectory($releaseRoot)
$releaseIndexPath = Join-Path $releaseRoot 'psh-release-1.2.3.json'
$releaseChecksumsPath = Join-Path $releaseRoot 'SHA256SUMS'
Write-PshGoal6CatalogText -Path $releaseIndexPath -Text "{`"version`":`"1.2.3`"}`n"
Write-PshGoal6CatalogText -Path $releaseChecksumsPath -Text "00  fixture`n"
$releaseCatalog = Join-Path $workRoot 'release.cat'
Invoke-PshGoal6CatalogBuilder -OutputPath $releaseCatalog -Members @(
    [pscustomobject]@{ Name = 'psh-release-1.2.3.json'; SourcePath = $releaseIndexPath },
    [pscustomobject]@{ Name = 'SHA256SUMS'; SourcePath = $releaseChecksumsPath }
)
$releaseExpected = @{
    'psh-release-1.2.3.json' = Get-PshGoal6CatalogSha256 -Path $releaseIndexPath
    'SHA256SUMS' = Get-PshGoal6CatalogSha256 -Path $releaseChecksumsPath
}
Assert-PshGoal6CatalogValid -Information (Get-PshGoal6CatalogInformation -Root $releaseRoot -CatalogPath $releaseCatalog) -Expected $releaseExpected

foreach ($negative in @(
        [pscustomobject]@{ Name = 'tampered'; Mutate = { param($root) Write-PshGoal6CatalogText -Path (Join-Path $root 'psh-release-1.2.3.json') -Text "tampered`n" } },
        [pscustomobject]@{ Name = 'extra'; Mutate = { param($root) Write-PshGoal6CatalogText -Path (Join-Path $root 'extra.txt') -Text "extra`n" } },
        [pscustomobject]@{ Name = 'missing'; Mutate = { param($root) [IO.File]::Delete((Join-Path $root 'SHA256SUMS')) } }
    )) {
    $negativeRoot = Join-Path $workRoot ('release-' + [string]$negative.Name)
    Copy-PshGoal6CatalogFiles -Source $releaseRoot -Destination $negativeRoot
    & $negative.Mutate $negativeRoot
    $negativeInformation = Get-PshGoal6CatalogInformation -Root $negativeRoot -CatalogPath $releaseCatalog
    Assert-PshGoal6Catalog ([string]$negativeInformation.Status -ceq 'ValidationFailed') "$($negative.Name) case did not return ValidationFailed."
    Assert-PshGoal6Catalog ([string]$negativeInformation.HashAlgorithm -ceq 'SHA256') "$($negative.Name) case lost the SHA256 catalog algorithm."
}

$emptyPath = Join-Path $workRoot 'empty.txt'
[IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
foreach ($invalid in @(
        [pscustomobject]@{ Name = 'absolute'; Members = @([pscustomobject]@{ Name = $packageManifestPath; SourcePath = $packageManifestPath }) },
        [pscustomobject]@{ Name = 'dotdot'; Members = @([pscustomobject]@{ Name = 'nested/../escape.txt'; SourcePath = $packageManifestPath }) },
        [pscustomobject]@{ Name = 'case-duplicate'; Members = @([pscustomobject]@{ Name = 'Case.txt'; SourcePath = $packageManifestPath }, [pscustomobject]@{ Name = 'case.TXT'; SourcePath = $packageManifestPath }) },
        [pscustomobject]@{ Name = 'empty'; Members = @([pscustomobject]@{ Name = 'empty.txt'; SourcePath = $emptyPath }) }
    )) {
    Invoke-PshGoal6CatalogBuilder -OutputPath (Join-Path $workRoot ("invalid-$([string]$invalid.Name).cat")) -Members @($invalid.Members) -ExpectFailure
}

$summary = [ordered]@{
    schemaVersion = 1
    gate = 'goal6-deterministic-windows-v2-catalog'
    status = 'passed'
    assertions = $script:Goal6CatalogAssertions
    runtime = [ordered]@{
        edition = [string]$PSVersionTable.PSEdition
        version = [string]$PSVersionTable.PSVersion
        architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    catalogSha256 = $deterministicSha256
    deterministicAcrossAbsoluteRoots = $true
    hashAlgorithm = 'SHA256'
    validCases = @('same-content-distinct-paths', 'package-one-file', 'release-two-file', 'chinese-and-space-path')
    invalidMembershipCases = @('tampered', 'extra', 'missing')
    rejectedInputCases = @('absolute', 'dotdot', 'case-duplicate', 'empty')
}
$summaryPath = Join-Path $reportRootPath 'catalog-builder-summary.json'
Write-PshGoal6CatalogText -Path $summaryPath -Text (($summary | ConvertTo-Json -Depth 8) + "`n")
Write-Output ("Goal 6 deterministic Windows V2 catalog passed ({0} assertions); report: {1}" -f $script:Goal6CatalogAssertions, $summaryPath)
