# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A5\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z')]
    [string] $PesterVersion,

    [Parameter()]
    [string] $PesterModulePath,

    [Parameter()]
    [string] $RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [Parameter(Mandatory = $true)]
    [string] $GoldenRoot,

    [Parameter(Mandatory = $true)]
    [string] $ReportRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$GoldenRoot = [IO.Path]::GetFullPath($GoldenRoot)
$ReportRoot = [IO.Path]::GetFullPath($ReportRoot)
if (-not [IO.Directory]::Exists($RepositoryRoot)) { throw "RepositoryRoot is missing: $RepositoryRoot" }
if (-not [IO.Directory]::Exists($GoldenRoot)) { throw "GoldenRoot is missing: $GoldenRoot" }
foreach ($name in @('batch1', 'batch2', 'batch4')) {
    $path = Join-Path $GoldenRoot $name
    if (-not [IO.Directory]::Exists($path)) { throw "Required GNU golden directory is missing: $path" }
}
[void][IO.Directory]::CreateDirectory($ReportRoot)

[Version] $requestedVersion = $PesterVersion
$loadedPester = @(Get-Module -Name Pester)
foreach ($loaded in $loadedPester) {
    if ([string]$loaded.Version.ToString() -cne $PesterVersion) {
        throw "A different Pester version is already loaded: $($loaded.Version); requested $PesterVersion."
    }
}
if ($loadedPester.Count -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace($PesterModulePath)) {
        $PesterModulePath = [IO.Path]::GetFullPath($PesterModulePath)
        if (-not [IO.File]::Exists($PesterModulePath)) { throw "PesterModulePath is missing: $PesterModulePath" }
        Import-Module -Name $PesterModulePath -Force -ErrorAction Stop
    }
    else {
        $availablePester = @(Get-Module -Name Pester -ListAvailable | Where-Object { $_.Version -eq $requestedVersion } | Sort-Object Path)
        if ($availablePester.Count -eq 0) {
            throw "Exact Pester $PesterVersion is not installed. The Goal 6 runner never installs or floats test dependencies."
        }
        Import-Module -Name ([string]$availablePester[0].Path) -Force -ErrorAction Stop
    }
}
$activePester = @(Get-Module -Name Pester)
if ($activePester.Count -ne 1 -or [string]$activePester[0].Version.ToString() -cne $PesterVersion) {
    throw "The active Pester module does not exactly match $PesterVersion."
}
foreach ($commandName in @('New-PesterConfiguration', 'Invoke-Pester')) {
    if ($null -eq (Get-Command -Name $commandName -Module Pester -ErrorAction SilentlyContinue)) {
        throw "Pester $PesterVersion does not expose required command $commandName."
    }
}

$testPaths = @(
    (Join-Path $RepositoryRoot 'tests/Goal6.Acceptance.Tests.ps1'),
    (Join-Path $RepositoryRoot 'tests/Goal6.InstallerEdges.Tests.ps1')
)
foreach ($testPath in $testPaths) {
    if (-not [IO.File]::Exists($testPath)) { throw "Required Goal 6 Pester file is missing: $testPath" }
}

$nunitPath = Join-Path $ReportRoot 'goal6-pester.nunit.xml'
$summaryPath = Join-Path $ReportRoot 'goal6-pester-summary.json'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$oldRepositoryRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_REPOSITORY_ROOT', 'Process')
$oldGoldenRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_GOLDEN_ROOT', 'Process')
$oldReportRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_REPORT_ROOT', 'Process')
$startedUtc = [DateTime]::UtcNow
$result = $null
$invocationFailure = $null
try {
    [Environment]::SetEnvironmentVariable('PSH_GOAL6_REPOSITORY_ROOT', $RepositoryRoot, 'Process')
    [Environment]::SetEnvironmentVariable('PSH_GOAL6_GOLDEN_ROOT', $GoldenRoot, 'Process')
    [Environment]::SetEnvironmentVariable('PSH_GOAL6_REPORT_ROOT', $ReportRoot, 'Process')

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $testPaths
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = $nunitPath
    try { $result = Invoke-Pester -Configuration $configuration }
    catch { $invocationFailure = $_ }
}
finally {
    $finishedUtc = [DateTime]::UtcNow
    $testRecords = New-Object System.Collections.Generic.List[object]
    if ($null -ne $result) {
        foreach ($test in @($result.Tests)) {
            $errors = @()
            foreach ($errorRecord in @($test.ErrorRecord)) {
                if ($null -ne $errorRecord -and $null -ne $errorRecord.Exception) { $errors += [string]$errorRecord.Exception.Message }
                elseif ($null -ne $errorRecord) { $errors += [string]$errorRecord }
            }
            [void]$testRecords.Add([pscustomobject][ordered]@{
                    name = [string]$test.ExpandedName
                    path = @($test.Path | ForEach-Object { [string]$_ })
                    result = [string]$test.Result
                    durationMilliseconds = [Math]::Round(([TimeSpan]$test.Duration).TotalMilliseconds, 3)
                    errors = $errors
                })
        }
    }
    $summary = [pscustomobject][ordered]@{
        schemaVersion = 1
        pesterVersion = $PesterVersion
        runtime = [pscustomobject][ordered]@{
            version = [string]$PSVersionTable.PSVersion
            edition = if ($null -ne $PSVersionTable.PSObject.Properties['PSEdition']) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
            processArchitecture = if ([string]::IsNullOrWhiteSpace([string]$env:PROCESSOR_ARCHITEW6432)) { [string]$env:PROCESSOR_ARCHITECTURE } else { [string]$env:PROCESSOR_ARCHITEW6432 }
        }
        startedUtc = $startedUtc.ToString('o')
        finishedUtc = $finishedUtc.ToString('o')
        durationMilliseconds = [Math]::Round(($finishedUtc - $startedUtc).TotalMilliseconds, 3)
        result = if ($null -eq $result) { 'InvocationFailed' } else { [string]$result.Result }
        totalCount = if ($null -eq $result) { 0 } else { [int]$result.TotalCount }
        passedCount = if ($null -eq $result) { 0 } else { [int]$result.PassedCount }
        failedCount = if ($null -eq $result) { 1 } else { [int]$result.FailedCount }
        skippedCount = if ($null -eq $result) { 0 } else { [int]$result.SkippedCount }
        notRunCount = if ($null -eq $result) { 0 } else { [int]$result.NotRunCount }
        invocationError = if ($null -eq $invocationFailure) { $null } else { [string]$invocationFailure.Exception.Message }
        nunitXml = [IO.Path]::GetFileName($nunitPath)
        tests = $testRecords.ToArray()
    }
    [IO.File]::WriteAllText($summaryPath, (($summary | ConvertTo-Json -Depth 8) + "`n"), $utf8)
    [Environment]::SetEnvironmentVariable('PSH_GOAL6_REPOSITORY_ROOT', $oldRepositoryRoot, 'Process')
    [Environment]::SetEnvironmentVariable('PSH_GOAL6_GOLDEN_ROOT', $oldGoldenRoot, 'Process')
    [Environment]::SetEnvironmentVariable('PSH_GOAL6_REPORT_ROOT', $oldReportRoot, 'Process')
}

if ($null -ne $invocationFailure) { throw $invocationFailure }
if ($null -eq $result) { throw "Pester returned no result; summary: $summaryPath" }
if (-not [IO.File]::Exists($nunitPath) -or (Get-Item -LiteralPath $nunitPath).Length -le 0) {
    throw "Pester did not produce a non-empty NUnit XML report: $nunitPath"
}
try { [void][xml]([IO.File]::ReadAllText($nunitPath, $utf8)) }
catch { throw "Pester produced invalid NUnit XML: $nunitPath" }
if ([int]$result.TotalCount -ne 27) { throw "Goal 6 expected exactly 27 fixed Pester cases, found $($result.TotalCount)." }
if ([int]$result.FailedCount -ne 0 -or [int]$result.SkippedCount -ne 0 -or [int]$result.NotRunCount -ne 0 -or [string]$result.Result -cne 'Passed') {
    throw "Goal 6 Pester matrix failed or was incomplete; summary: $summaryPath; NUnit: $nunitPath"
}

Write-Output "Goal 6 Pester matrix passed: $($result.PassedCount) tests; summary: $summaryPath; NUnit: $nunitPath"
