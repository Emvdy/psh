# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CandidateAssetsRoot,
    [Parameter(Mandatory = $true)][string]$ReportRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Goal6.Common.ps1')

function Find-PshGoal6DefenderScanner {
    $candidates = New-Object System.Collections.Generic.List[string]
    $command = Get-Command MpCmdRun.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { $candidates.Add([string]$command.Source) }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'))
        $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft Defender\MpCmdRun.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $platformRoot = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
        if ([IO.Directory]::Exists($platformRoot)) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $platformRoot -Directory | Sort-Object Name -Descending)) {
                $candidates.Add((Join-Path $directory.FullName 'MpCmdRun.exe'))
            }
        }
    }
    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function Get-PshGoal6AssetRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    Assert-PshGoal6Condition ($pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)) "Asset path escapes candidate root: $Path"
    return $pathFull.Substring($rootFull.Length + 1).Replace('\', '/')
}

$candidateRootPath = [IO.Path]::GetFullPath($CandidateAssetsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$reportRootPath = [IO.Path]::GetFullPath($ReportRoot)
$comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
Assert-PshGoal6Condition ([IO.Directory]::Exists($candidateRootPath)) "Candidate assets root is missing: $candidateRootPath"
Assert-PshGoal6Condition (-not [string]::Equals($reportRootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $candidateRootPath, $comparison) -and -not $reportRootPath.StartsWith($candidateRootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) 'Defender ReportRoot must be outside CandidateAssetsRoot.'
[void][IO.Directory]::CreateDirectory($reportRootPath)
$inventoryPath = Join-Path $reportRootPath 'defender-asset-inventory.json'
$summaryPath = Join-Path $reportRootPath 'defender-summary.json'
$failure = $null
$scannerPath = $null
$scanExitCode = $null
$mode = 'hash-only'
$status = 'passed'
$inventory = @()

try {
    $rootEntry = Get-Item -LiteralPath $candidateRootPath -Force
    Assert-PshGoal6Condition (($rootEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Candidate assets root is a reparse point.'
    $entries = @(Get-ChildItem -LiteralPath $candidateRootPath -Recurse -Force)
    foreach ($entry in $entries) {
        Assert-PshGoal6Condition (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Candidate asset tree contains a reparse point: $($entry.FullName)"
    }
    $files = @($entries | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)
    Assert-PshGoal6Condition ($files.Count -gt 0) 'Candidate assets root contains no files.'
    $inventory = @($files | ForEach-Object {
            [pscustomobject][ordered]@{
                path = Get-PshGoal6AssetRelativePath -Root $candidateRootPath -Path $_.FullName
                length = [int64]$_.Length
                sha256 = Get-PshGoal6Sha256 -Path $_.FullName
            }
        })
    Write-PshGoal6Json -Path $inventoryPath -InputObject $inventory

    $scannerPath = Find-PshGoal6DefenderScanner
    if ($null -ne $scannerPath) {
        $mode = 'microsoft-defender-custom-scan'
        $scanOutput = @(& $scannerPath '-Scan' '-ScanType' '3' '-File' $candidateRootPath '-DisableRemediation' 2>&1)
        $scanExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        Write-PshGoal6Text -Path (Join-Path $reportRootPath 'defender-scan.log') -Text ((@($scanOutput | ForEach-Object { [string]$_ }) -join "`n") + "`n")
        if ($scanExitCode -eq 2) { $status = 'malware-detected' }
        elseif ($scanExitCode -ne 0) { $status = 'scan-error' }
    }
}
catch { $failure = [string]$_.Exception.Message; $status = 'scan-error' }

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'defender-scan'
    status = if ($status -ceq 'passed' -and $null -eq $failure) { 'passed' } else { 'failed' }
    mode = $mode
    defenderAvailable = ($null -ne $scannerPath)
    scannerPath = $scannerPath
    scanExitCode = $scanExitCode
    assetCount = $inventory.Count
    inventory = 'defender-asset-inventory.json'
    unavailablePolicy = 'Defender unavailability is non-failing; the SHA256 inventory remains mandatory.'
    error = $failure
}
Write-PshGoal6Json -Path $summaryPath -InputObject $summary
if ($null -ne $failure) { throw "Defender gate failed: $failure" }
if ($status -ceq 'malware-detected') { throw "Microsoft Defender detected malware in candidate assets. See $summaryPath" }
if ($status -ceq 'scan-error') { throw "Microsoft Defender was available but its scan failed. See $summaryPath" }
if ($null -eq $scannerPath) { Write-Output ('Microsoft Defender is unavailable; retained hash-only inventory for {0} candidate assets.' -f $inventory.Count) }
else { Write-Output ('Microsoft Defender scan passed for {0} candidate assets.' -f $inventory.Count) }
