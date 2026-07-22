# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-f]{40}\z')][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$ReleaseNotesPath,
    [Parameter(Mandatory = $true)][string]$ReleaseNotesZhCnPath,
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$MSBuildPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Goal6.Common.ps1')
. (Join-Path $PSScriptRoot 'Goal6.Zip.ps1')

function Throw-PshGoal6ReproducibilityError {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$ErrorId,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][Exception]$InnerException
    )

    $exception = if ($null -eq $InnerException) { New-Object Exception($Message) } else { New-Object Exception($Message, $InnerException) }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorId'] = $ErrorId
    throw $exception
}

function Get-PshGoal6FailureMetadata {
    param([AllowNull()][object]$ErrorRecord)

    $exitCode = 5
    $errorId = 'PshGoal6ReproducibilityFailure'
    $message = $null
    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) {
        $ErrorRecord.Exception
    }
    elseif ($ErrorRecord -is [Exception]) {
        $ErrorRecord
    }
    else {
        $null
    }
    if ($null -ne $ErrorRecord) { $message = if ($null -eq $exception) { [string]$ErrorRecord } else { [string]$exception.Message } }
    while ($null -ne $exception -and $exception -is [Exception]) {
        if ($exception.Data.Contains('PshExitCode')) {
            $exitCode = [int]$exception.Data['PshExitCode']
            if ($exception.Data.Contains('PshErrorId')) { $errorId = [string]$exception.Data['PshErrorId'] }
            $message = [string]$exception.Message
            break
        }
        $exception = $exception.InnerException
    }
    return [pscustomobject][ordered]@{
        exitCode = $exitCode
        errorId = $errorId
        message = $message
    }
}

function Get-PshGoal6OrderedString {
    param([Parameter(Mandatory = $true)][object[]]$Values)

    [string[]]$ordered = @($Values | ForEach-Object { [string]$_ })
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    return $ordered
}

function Get-PshGoal6ExpectedCandidateNames {
    param([Parameter(Mandatory = $true)][string]$PackageVersion)

    return @(
        'install.ps1',
        'install.sh',
        'psh-installer.exe',
        "psh-$PackageVersion-core.zip",
        "psh-$PackageVersion-full-win-x64.zip",
        "psh-$PackageVersion-full-win-arm64.zip",
        'sbom.spdx.json',
        'THIRD_PARTY_NOTICES.md',
        'RELEASE_NOTES.md',
        'RELEASE_NOTES.zh-CN.md',
        "psh-release-$PackageVersion.json",
        'SHA256SUMS',
        "psh-release-$PackageVersion.cat"
    )
}

function Assert-PshGoal6CandidateReport {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][string]$PackageVersion
    )

    Assert-PshGoal6Condition ([string]$Report.phase -ceq 'candidate-verified' -and [int]$Report.code -eq 0) 'Candidate report did not return candidate-verified/code 0.'
    Assert-PshGoal6Condition ([int]$Report.assetCount -eq 13 -and [int]$Report.packageCount -eq 3 -and [bool]$Report.catalogMembershipVerified) 'Candidate report did not verify the exact 13-asset/3-package catalog contract.'
    Assert-PshGoal6Condition ([string]$Report.assetContract -ceq 'exact-13-public-assets-before-provenance-attestation') 'Candidate report asset contract changed.'
    Assert-PshGoal6Condition ([string]$Report.provenanceAttestation -ceq 'external-workflow-gate') 'Candidate report provenance boundary changed.'
    Assert-PshGoal6Condition ([string]$Report.phases.preSignBuild -ceq 'pre-sign') 'Candidate pre-sign phase changed.'
    Assert-PshGoal6Condition ([string]$Report.phases.finalPackageBuild -ceq 'finalized-with-verified-catalog-membership') 'Candidate final package phase changed.'
    Assert-PshGoal6Condition ([string]$Report.phases.initialIndex -ceq 'catalog-deferred') 'Candidate initial index phase changed.'
    Assert-PshGoal6Condition ([string]$Report.phases.finalIndex -ceq 'finalized-with-verified-catalog-membership') 'Candidate final index phase changed.'
    Assert-PshGoal6Condition ([string]$Report.phases.releaseVerification -ceq 'release-catalog-membership-verified') 'Candidate release verification phase changed.'

    $expectedNames = @(Get-PshGoal6ExpectedCandidateNames -PackageVersion $PackageVersion)
    $reportAssets = @($Report.assets)
    Assert-PshGoal6Condition ($reportAssets.Count -eq $expectedNames.Count) 'Candidate report does not contain exactly 13 asset records.'
    foreach ($expectedName in $expectedNames) {
        $matches = @($reportAssets | Where-Object { [string]$_.name -ceq $expectedName })
        Assert-PshGoal6Condition ($matches.Count -eq 1) "Candidate report is missing exact asset record '$expectedName'."
        $path = Join-Path $CandidateRoot $expectedName
        Assert-PshGoal6Condition ([IO.File]::Exists($path)) "Candidate asset is missing: $path"
        Assert-PshGoal6Condition ([int64]$matches[0].length -eq [int64](Get-Item -LiteralPath $path).Length) "Candidate report length mismatches for '$expectedName'."
        Assert-PshGoal6Condition ([string]$matches[0].sha256 -ceq (Get-PshGoal6Sha256 -Path $path)) "Candidate report SHA256 mismatches for '$expectedName'."
    }
}

function Invoke-PshGoal6IndependentCandidateBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string]$PackageVersion,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$EnglishReleaseNotes,
        [Parameter(Mandatory = $true)][string]$ChineseReleaseNotes,
        [Parameter(Mandatory = $true)][string]$CandidateScriptPath,
        [AllowNull()][string]$RequestedMSBuildPath
    )

    Assert-PshGoal6Condition (-not [IO.File]::Exists($RunRoot) -and -not [IO.Directory]::Exists($RunRoot)) "Independent candidate run root already exists: $RunRoot"
    [void][IO.Directory]::CreateDirectory($RunRoot)
    $bootstrapperRoot = Join-Path $RunRoot 'bootstrapper'
    [void][IO.Directory]::CreateDirectory($bootstrapperRoot)
    $onlineInstaller = Join-Path $RepositoryRootPath 'src/install/install.ps1'
    $offlineInstaller = Join-Path $RepositoryRootPath 'src/install/install-offline.ps1'
    $bootstrapperPath = Join-Path $bootstrapperRoot 'psh-installer.exe'
    $hashSourcePath = Join-Path $bootstrapperRoot 'EmbeddedScriptHashes.g.cs'
    $bootstrapperScript = Join-Path $RepositoryRootPath 'scripts/Build-PshBootstrapper.ps1'
    $bootstrapperParameters = @{
        OnlineScriptPath = $onlineInstaller
        OfflineScriptPath = $offlineInstaller
        OutputPath = $bootstrapperPath
        HashSourcePath = $hashSourcePath
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedMSBuildPath)) { $bootstrapperParameters['MSBuildPath'] = $RequestedMSBuildPath }
    $bootstrapperOutput = @()
    $script:PshGoal6ReproBootstrapperInvocations++
    try { $bootstrapperOutput = @(& $bootstrapperScript @bootstrapperParameters 2>&1) }
    catch {
        $bootstrapperOutput += $_
        Write-PshGoal6Text -Path (Join-Path $RunRoot 'bootstrapper-build.log') -Text ((@($bootstrapperOutput | ForEach-Object { [string]$_ }) -join "`n") + "`n")
        throw
    }
    Write-PshGoal6Text -Path (Join-Path $RunRoot 'bootstrapper-build.log') -Text ((@($bootstrapperOutput | ForEach-Object { [string]$_ }) -join "`n") + "`n")
    Assert-PshGoal6Condition ([IO.File]::Exists($bootstrapperPath) -and [int64](Get-Item -LiteralPath $bootstrapperPath).Length -gt 0) 'Independent bootstrapper build produced no executable.'
    $script:PshGoal6ReproBootstrapperBuilds++

    $candidateRoot = Join-Path $RunRoot 'candidate'
    $candidateReportPath = Join-Path $RunRoot 'candidate-report.json'
    $candidateWorkingRoot = Join-Path $RunRoot 'candidate-working'
    $candidateParameters = @{
        CandidateRoot = $candidateRoot
        ReportPath = $candidateReportPath
        Version = $PackageVersion
        SourceCommit = $Commit
        BootstrapperPath = $bootstrapperPath
        ReleaseNotesPath = $EnglishReleaseNotes
        ReleaseNotesZhCnPath = $ChineseReleaseNotes
        RepositoryRoot = $RepositoryRootPath
        WorkingRoot = $candidateWorkingRoot
    }
    $candidateOutput = @()
    $script:PshGoal6ReproCandidateDriverInvocations++
    try { $candidateOutput = @(& $CandidateScriptPath @candidateParameters 2>&1) }
    catch {
        $candidateOutput += $_
        Write-PshGoal6Text -Path (Join-Path $RunRoot 'candidate-build.log') -Text ((@($candidateOutput | ForEach-Object { [string]$_ }) -join "`n") + "`n")
        throw
    }
    Write-PshGoal6Text -Path (Join-Path $RunRoot 'candidate-build.log') -Text ((@($candidateOutput | ForEach-Object { [string]$_ }) -join "`n") + "`n")
    $candidateResults = @($candidateOutput | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties['phase'] -and [string]$_.phase -ceq 'candidate-verified'
        })
    Assert-PshGoal6Condition ($candidateResults.Count -eq 1 -and [int]$candidateResults[0].code -eq 0) 'Candidate driver did not return exactly one candidate-verified/code 0 result.'
    Assert-PshGoal6Condition ([IO.Directory]::Exists($candidateRoot)) 'Candidate driver produced no candidate directory.'
    Assert-PshGoal6Condition ([IO.File]::Exists($candidateReportPath)) 'Candidate driver produced no candidate report.'
    Assert-PshGoal6Condition (-not [IO.File]::Exists($candidateWorkingRoot) -and -not [IO.Directory]::Exists($candidateWorkingRoot)) 'Candidate driver retained its controlled working root.'
    $candidateReport = (Get-PshGoal6StrictText -Path $candidateReportPath) | ConvertFrom-Json -ErrorAction Stop
    Assert-PshGoal6CandidateReport -Report $candidateReport -CandidateRoot $candidateRoot -PackageVersion $PackageVersion
    $script:PshGoal6ReproCandidateVerifiedBuilds++
    return [pscustomobject][ordered]@{
        runRoot = $RunRoot
        candidateRoot = $candidateRoot
        candidateReportPath = $candidateReportPath
        candidateReport = $candidateReport
    }
}

function Get-PshGoal6CandidateManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RunName,
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][object]$CandidateReport,
        [Parameter(Mandatory = $true)][string]$PackageVersion
    )

    $expectedNames = @(Get-PshGoal6ExpectedCandidateNames -PackageVersion $PackageVersion)
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $expectedNames) { [void]$expected.Add($name) }
    $rootEntry = Get-Item -LiteralPath $CandidateRoot -Force
    Assert-PshGoal6Condition (($rootEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Candidate root is a reparse point: $CandidateRoot"
    $entries = @(Get-ChildItem -LiteralPath $CandidateRoot -Force)
    Assert-PshGoal6Condition ($entries.Count -eq $expected.Count) "Candidate root does not contain exactly $($expected.Count) assets: $CandidateRoot"
    foreach ($entry in $entries) {
        Assert-PshGoal6Condition (-not $entry.PSIsContainer -and (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) "Candidate contains a non-file or reparse entry: $($entry.FullName)"
        Assert-PshGoal6Condition ($expected.Contains([string]$entry.Name)) "Candidate contains an unexpected asset: $($entry.Name)"
    }

    $assetFiles = New-Object System.Collections.Generic.List[object]
    $stableFiles = New-Object System.Collections.Generic.List[object]
    $archives = New-Object System.Collections.Generic.List[object]
    [string[]]$orderedNames = @($entries | ForEach-Object { [string]$_.Name })
    [Array]::Sort($orderedNames, [StringComparer]::Ordinal)
    foreach ($name in $orderedNames) {
        $path = Join-Path $CandidateRoot $name
        $file = Get-Item -LiteralPath $path -Force
        $sha256 = Get-PshGoal6Sha256 -Path $path
        if ([IO.Path]::GetExtension($name) -ieq '.zip') {
            $archive = Get-PshGoal6ZipArchiveManifest -ArchivePath $path -DisplayPath $name
            $archives.Add($archive)
            $assetFiles.Add([pscustomobject][ordered]@{
                    path = $name
                    length = [int64]$file.Length
                    sha256 = $sha256
                    comparison = 'timestamp-normalized-zip'
                    timestampNormalizedContainerSha256 = [string]$archive.timestampNormalizedContainerSha256
                    entryCount = @($archive.entries).Count
                })
        }
        else {
            $record = [pscustomobject][ordered]@{
                path = $name
                length = [int64]$file.Length
                sha256 = $sha256
            }
            $stableFiles.Add($record)
            $assetFiles.Add([pscustomobject][ordered]@{
                    path = $name
                    length = [int64]$file.Length
                    sha256 = $sha256
                    comparison = 'exact-file-sha256'
                    timestampNormalizedContainerSha256 = $null
                    entryCount = $null
                })
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        run = $RunName
        scope = 'verified-goal6-candidate-exact-13-assets'
        candidatePhase = [string]$CandidateReport.phase
        assetCount = $assetFiles.Count
        packageCount = [int]$CandidateReport.packageCount
        catalogMembershipVerified = [bool]$CandidateReport.catalogMembershipVerified
        assetFiles = $assetFiles.ToArray()
        stableFiles = $stableFiles.ToArray()
        normalizedArchives = $archives.ToArray()
        archiveComparisonPolicy = 'Exclude DOS modification fields and only the timestamp payload bytes in standard 0x5455, 0x000A/0x0001, 0x5855, and 0x000D extra fields. Compare entry order, paths, content SHA256, compression data, flags, methods, attributes, comments, extra-field structure, flags, lengths, tags, and all non-time bytes.'
    }
}

function Compare-PshGoal6CandidateManifest {
    param(
        [Parameter(Mandatory = $true)][object]$First,
        [Parameter(Mandatory = $true)][object]$Second
    )

    $differences = New-Object System.Collections.Generic.List[object]
    foreach ($field in @('candidatePhase', 'assetCount', 'packageCount', 'catalogMembershipVerified')) {
        $firstValue = Get-PshGoal6Property -InputObject $First -Name $field
        $secondValue = Get-PshGoal6Property -InputObject $Second -Name $field
        if ([string]$firstValue -cne [string]$secondValue) {
            $differences.Add([pscustomobject][ordered]@{ kind = 'candidate-' + $field; path = $null; first = $firstValue; second = $secondValue })
        }
    }

    $firstAssets = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $secondAssets = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($asset in @($First.assetFiles)) { $firstAssets[[string]$asset.path] = $asset }
    foreach ($asset in @($Second.assetFiles)) { $secondAssets[[string]$asset.path] = $asset }
    $assetPaths = Get-PshGoal6OrderedString -Values @((@($firstAssets.Keys) + @($secondAssets.Keys)) | Sort-Object -Unique)
    foreach ($path in $assetPaths) {
        if (-not $firstAssets.ContainsKey($path)) { $differences.Add([pscustomobject][ordered]@{ kind = 'candidate-asset-missing-first'; path = $path; first = $null; second = 'present' }); continue }
        if (-not $secondAssets.ContainsKey($path)) { $differences.Add([pscustomobject][ordered]@{ kind = 'candidate-asset-missing-second'; path = $path; first = 'present'; second = $null }); continue }
        $firstAsset = $firstAssets[$path]
        $secondAsset = $secondAssets[$path]
        if ([string]$firstAsset.comparison -cne [string]$secondAsset.comparison) {
            $differences.Add([pscustomobject][ordered]@{ kind = 'candidate-asset-comparison-mode'; path = $path; first = [string]$firstAsset.comparison; second = [string]$secondAsset.comparison })
            continue
        }
        if ([string]$firstAsset.comparison -ceq 'exact-file-sha256' -and
            ([int64]$firstAsset.length -ne [int64]$secondAsset.length -or [string]$firstAsset.sha256 -cne [string]$secondAsset.sha256)) {
            $differences.Add([pscustomobject][ordered]@{ kind = 'candidate-exact-file'; path = $path; first = ('{0}:{1}' -f [int64]$firstAsset.length, [string]$firstAsset.sha256); second = ('{0}:{1}' -f [int64]$secondAsset.length, [string]$secondAsset.sha256) })
        }
    }

    $firstArchives = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $secondArchives = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($archive in @($First.normalizedArchives)) { $firstArchives[[string]$archive.path] = $archive }
    foreach ($archive in @($Second.normalizedArchives)) { $secondArchives[[string]$archive.path] = $archive }
    $archivePaths = Get-PshGoal6OrderedString -Values @((@($firstArchives.Keys) + @($secondArchives.Keys)) | Sort-Object -Unique)
    foreach ($archivePath in $archivePaths) {
        if (-not $firstArchives.ContainsKey($archivePath)) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-missing-first'; path = $archivePath; first = $null; second = 'present' }); continue }
        if (-not $secondArchives.ContainsKey($archivePath)) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-missing-second'; path = $archivePath; first = 'present'; second = $null }); continue }
        foreach ($archiveDifference in @(Compare-PshGoal6ZipArchiveManifest -First $firstArchives[$archivePath] -Second $secondArchives[$archivePath])) { $differences.Add($archiveDifference) }
    }
    return $differences.ToArray()
}

function Invoke-PshGoal6NonWindowsBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRootPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string]$CandidateScriptPath,
        [Parameter(Mandatory = $true)][string]$PackageVersion,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$EnglishReleaseNotes,
        [Parameter(Mandatory = $true)][string]$ChineseReleaseNotes
    )

    [void][IO.Directory]::CreateDirectory($OutputRootPath)
    $candidateRoot = Join-Path $OutputRootPath 'boundary-candidate'
    $candidateReportPath = Join-Path $OutputRootPath 'boundary-candidate-report.json'
    $candidateWorkingRoot = Join-Path $OutputRootPath 'boundary-candidate-working'
    $boundaryFailure = $null
    try {
        $null = & $CandidateScriptPath `
            -CandidateRoot $candidateRoot `
            -ReportPath $candidateReportPath `
            -Version $PackageVersion `
            -SourceCommit $Commit `
            -BootstrapperPath (Join-Path $RepositoryRootPath 'src/install/install.ps1') `
            -ReleaseNotesPath $EnglishReleaseNotes `
            -ReleaseNotesZhCnPath $ChineseReleaseNotes `
            -RepositoryRoot $RepositoryRootPath `
            -WorkingRoot $candidateWorkingRoot
    }
    catch { $boundaryFailure = $_ }
    $metadata = Get-PshGoal6FailureMetadata -ErrorRecord $boundaryFailure
    $boundaryVerified = $null -ne $boundaryFailure -and [int]$metadata.exitCode -eq 4 -and [string]$metadata.errorId -ceq 'PshGoal6CandidateCatalogUnavailable'
    $outputsAbsent = -not [IO.File]::Exists($candidateRoot) -and -not [IO.Directory]::Exists($candidateRoot) -and
        -not [IO.File]::Exists($candidateReportPath) -and -not [IO.Directory]::Exists($candidateReportPath) -and
        -not [IO.File]::Exists($candidateWorkingRoot) -and -not [IO.Directory]::Exists($candidateWorkingRoot)
    Write-PshGoal6Json -Path (Join-Path $OutputRootPath 'reproducibility-diff.json') -InputObject @()
    $summary = [pscustomobject][ordered]@{
        schemaVersion = 2
        gate = 'reproducibility'
        status = if ($boundaryVerified -and $outputsAbsent) { 'unsupported' } else { 'failed' }
        phase = if ($boundaryVerified -and $outputsAbsent) { 'candidate-catalog-unavailable' } else { 'candidate-boundary-failed' }
        code = if ($boundaryVerified -and $outputsAbsent) { 4 } else { 5 }
        platform = [string][Environment]::OSVersion.Platform
        buildCount = 0
        bootstrapperBuildInvocations = 0
        bootstrapperBuildCount = 0
        candidateDriverInvocations = 1
        candidateVerifiedBuildCount = 0
        candidatePhase = $null
        bootstrapperBuiltIndependentlyTwice = $false
        candidateDriverInvokedIndependentlyTwice = $false
        candidateBoundaryVerified = $boundaryVerified
        candidateOutputsAbsent = $outputsAbsent
        boundaryErrorId = [string]$metadata.errorId
        boundaryError = [string]$metadata.message
        differenceCount = 0
        archivePolicy = 'Windows-only candidate builds exclude DOS modification fields and only standard extra-field timestamp payload bytes; all non-time ZIP bytes and semantics remain gated.'
    }
    $summaryPath = Join-Path $OutputRootPath 'reproducibility-summary.json'
    Write-PshGoal6Json -Path $summaryPath -InputObject $summary
    if (-not $boundaryVerified -or -not $outputsAbsent) {
        Throw-PshGoal6ReproducibilityError -ExitCode 5 -ErrorId 'PshGoal6ReproducibilityBoundary' -Message "Non-Windows candidate boundary did not return clean code 4 evidence. See $summaryPath" -InnerException $(if ($null -eq $boundaryFailure) { $null } else { $boundaryFailure.Exception })
    }
    Throw-PshGoal6ReproducibilityError -ExitCode 4 -ErrorId 'PshGoal6ReproducibilityCatalogUnavailable' -Message "Reproducibility candidate builds require Windows New-FileCatalog/Test-FileCatalog APIs. Boundary evidence: $summaryPath" -InnerException $boundaryFailure.Exception
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$outputRootPath = [IO.Path]::GetFullPath($OutputRoot)
$comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
Assert-PshGoal6Condition (-not [string]::Equals($outputRootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $repositoryRootPath, $comparison) -and -not $outputRootPath.StartsWith($repositoryRootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) 'Reproducibility OutputRoot must be outside the repository worktree.'
Assert-PshGoal6Condition (-not [IO.File]::Exists($outputRootPath) -and -not [IO.Directory]::Exists($outputRootPath)) "Reproducibility output root already exists: $outputRootPath"
$candidateScriptPath = Join-Path $repositoryRootPath 'scripts/goal6/New-Goal6Candidate.ps1'
Assert-PshGoal6Condition ([IO.File]::Exists($candidateScriptPath)) "Goal 6 candidate driver is missing: $candidateScriptPath"
foreach ($inputPath in @($ReleaseNotesPath, $ReleaseNotesZhCnPath)) { Assert-PshGoal6Condition ([IO.File]::Exists([IO.Path]::GetFullPath($inputPath))) "Release notes input is missing: $inputPath" }
$releaseNotesPathFull = [IO.Path]::GetFullPath($ReleaseNotesPath)
$releaseNotesZhCnPathFull = [IO.Path]::GetFullPath($ReleaseNotesZhCnPath)

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Invoke-PshGoal6NonWindowsBoundary -OutputRootPath $outputRootPath -RepositoryRootPath $repositoryRootPath -CandidateScriptPath $candidateScriptPath -PackageVersion $Version -Commit $SourceCommit -EnglishReleaseNotes $releaseNotesPathFull -ChineseReleaseNotes $releaseNotesZhCnPathFull
}

[void][IO.Directory]::CreateDirectory($outputRootPath)
$manifestOne = $null
$manifestTwo = $null
$differences = @()
$failureRecord = $null
$script:PshGoal6ReproBootstrapperInvocations = 0
$script:PshGoal6ReproBootstrapperBuilds = 0
$script:PshGoal6ReproCandidateDriverInvocations = 0
$script:PshGoal6ReproCandidateVerifiedBuilds = 0

try {
    $firstRun = Invoke-PshGoal6IndependentCandidateBuild -RunRoot (Join-Path $outputRootPath 'run-1') -RepositoryRootPath $repositoryRootPath -PackageVersion $Version -Commit $SourceCommit -EnglishReleaseNotes $releaseNotesPathFull -ChineseReleaseNotes $releaseNotesZhCnPathFull -CandidateScriptPath $candidateScriptPath -RequestedMSBuildPath $MSBuildPath
    $manifestOne = Get-PshGoal6CandidateManifest -RunName 'run-1' -CandidateRoot ([string]$firstRun.candidateRoot) -CandidateReport $firstRun.candidateReport -PackageVersion $Version
    Write-PshGoal6Json -Path (Join-Path $outputRootPath 'build-1.manifest.json') -InputObject $manifestOne

    $secondRun = Invoke-PshGoal6IndependentCandidateBuild -RunRoot (Join-Path $outputRootPath 'run-2') -RepositoryRootPath $repositoryRootPath -PackageVersion $Version -Commit $SourceCommit -EnglishReleaseNotes $releaseNotesPathFull -ChineseReleaseNotes $releaseNotesZhCnPathFull -CandidateScriptPath $candidateScriptPath -RequestedMSBuildPath $MSBuildPath
    $manifestTwo = Get-PshGoal6CandidateManifest -RunName 'run-2' -CandidateRoot ([string]$secondRun.candidateRoot) -CandidateReport $secondRun.candidateReport -PackageVersion $Version
    Write-PshGoal6Json -Path (Join-Path $outputRootPath 'build-2.manifest.json') -InputObject $manifestTwo
    $differences = @(Compare-PshGoal6CandidateManifest -First $manifestOne -Second $manifestTwo)
}
catch { $failureRecord = $_ }

Write-PshGoal6Json -Path (Join-Path $outputRootPath 'reproducibility-diff.json') -InputObject $differences
$failureMetadata = Get-PshGoal6FailureMetadata -ErrorRecord $failureRecord
$passed = $null -eq $failureRecord -and $differences.Count -eq 0 -and $null -ne $manifestOne -and $null -ne $manifestTwo
$manifestPaths = @(
    if ([IO.File]::Exists((Join-Path $outputRootPath 'build-1.manifest.json'))) { 'build-1.manifest.json' }
    if ([IO.File]::Exists((Join-Path $outputRootPath 'build-2.manifest.json'))) { 'build-2.manifest.json' }
)
$candidateReportPaths = @(
    if ([IO.File]::Exists((Join-Path (Join-Path $outputRootPath 'run-1') 'candidate-report.json'))) { 'run-1/candidate-report.json' }
    if ([IO.File]::Exists((Join-Path (Join-Path $outputRootPath 'run-2') 'candidate-report.json'))) { 'run-2/candidate-report.json' }
)
$summary = [pscustomobject][ordered]@{
    schemaVersion = 2
    gate = 'reproducibility'
    status = if ($passed) { 'passed' } else { 'failed' }
    phase = if ($passed) { 'candidate-reproducibility-verified' } else { 'candidate-reproducibility-failed' }
    code = if ($passed) { 0 } elseif ($null -ne $failureRecord) { [int]$failureMetadata.exitCode } else { 5 }
    buildCount = $script:PshGoal6ReproCandidateVerifiedBuilds
    bootstrapperBuildInvocations = $script:PshGoal6ReproBootstrapperInvocations
    bootstrapperBuildCount = $script:PshGoal6ReproBootstrapperBuilds
    candidateDriverInvocations = $script:PshGoal6ReproCandidateDriverInvocations
    candidateVerifiedBuildCount = $script:PshGoal6ReproCandidateVerifiedBuilds
    candidateDriver = 'scripts/goal6/New-Goal6Candidate.ps1'
    candidatePhase = if ($script:PshGoal6ReproCandidateVerifiedBuilds -gt 0) { 'candidate-verified' } else { $null }
    candidateAssetContract = 'exact-13-public-assets-before-provenance-attestation'
    bootstrapperBuiltIndependentlyTwice = $script:PshGoal6ReproBootstrapperBuilds -eq 2
    candidateDriverInvokedIndependentlyTwice = $script:PshGoal6ReproCandidateDriverInvocations -eq 2
    stableFilePolicy = 'Compare the exact candidate asset path set and exact length/SHA256 for every non-ZIP asset. Each ZIP raw SHA256 is recorded but its container comparison excludes only approved timestamp bytes.'
    archivePolicy = 'Zero DOS modification fields and only timestamp payload bytes in standard 0x5455, 0x000A/0x0001, 0x5855, and 0x000D extra fields. Hard-compare entry order, paths, uncompressed SHA256, compressed data, flags, methods, attributes, comments, extra-field structure, flags, lengths, tags, and all non-time bytes.'
    firstAssetCount = if ($null -eq $manifestOne) { 0 } else { @($manifestOne.assetFiles).Count }
    secondAssetCount = if ($null -eq $manifestTwo) { 0 } else { @($manifestTwo.assetFiles).Count }
    firstArchiveCount = if ($null -eq $manifestOne) { 0 } else { @($manifestOne.normalizedArchives).Count }
    secondArchiveCount = if ($null -eq $manifestTwo) { 0 } else { @($manifestTwo.normalizedArchives).Count }
    differenceCount = $differences.Count
    manifests = $manifestPaths
    candidateReports = $candidateReportPaths
    diff = 'reproducibility-diff.json'
    errorId = if ($null -eq $failureRecord) { $null } else { [string]$failureMetadata.errorId }
    error = if ($null -eq $failureRecord) { $null } else { [string]$failureMetadata.message }
}
$summaryPath = Join-Path $outputRootPath 'reproducibility-summary.json'
Write-PshGoal6Json -Path $summaryPath -InputObject $summary
if ($null -ne $failureRecord) { $PSCmdlet.ThrowTerminatingError($failureRecord) }
if ($differences.Count -gt 0) {
    Throw-PshGoal6ReproducibilityError -ExitCode 5 -ErrorId 'PshGoal6ReproducibilityMismatch' -Message "Reproducibility gate found $($differences.Count) candidate difference(s). See $summaryPath"
}
Write-Output ('Reproducibility gate passed: two independent candidate-verified builds matched across 13 assets after excluding only approved ZIP timestamp bytes.')
