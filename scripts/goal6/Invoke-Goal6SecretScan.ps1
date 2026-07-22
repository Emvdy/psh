# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DependencyRoot,
    [Parameter(Mandatory = $true)][string]$ReportRoot,
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$LockPath = (Join-Path $PSScriptRoot 'ci-dependencies.lock.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Goal6.Common.ps1')

function Invoke-PshGoal6GitleaksScan {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][ValidateSet('git', 'dir')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $arguments = @(
        $Mode,
        '--no-banner',
        '--redact=100',
        '--ignore-gitleaks-allow',
        '--report-format', 'json',
        '--report-path', $ReportPath,
        $RepositoryRootPath
    )
    $output = @(& $ExecutablePath @arguments 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Write-PshGoal6Text -Path $LogPath -Text ((@($output | ForEach-Object { [string]$_ }) -join "`n") + "`n")
    if (-not [IO.File]::Exists($ReportPath)) { Write-PshGoal6Text -Path $ReportPath -Text "[]`n" }
    $reportText = Get-PshGoal6StrictText -Path $ReportPath
    try { $report = @($reportText | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "gitleaks $Mode report is invalid JSON: $($_.Exception.Message)" }
    return [pscustomobject][ordered]@{
        mode = $Mode
        exitCode = $exitCode
        findingCount = $report.Count
        status = if ($exitCode -eq 0 -and $report.Count -eq 0) { 'passed' } elseif ($exitCode -eq 1 -and $report.Count -gt 0) { 'secrets-detected' } else { 'scanner-error' }
        report = [IO.Path]::GetFileName($ReportPath)
        log = [IO.Path]::GetFileName($LogPath)
    }
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$dependencyRootPath = [IO.Path]::GetFullPath($DependencyRoot)
$reportRootPath = [IO.Path]::GetFullPath($ReportRoot)
$comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
Assert-PshGoal6Condition (-not [string]::Equals($reportRootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $repositoryRootPath, $comparison) -and -not $reportRootPath.StartsWith($repositoryRootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) 'Secret-scan ReportRoot must be outside the repository worktree.'
Assert-PshGoal6Condition (-not [string]::Equals($dependencyRootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $repositoryRootPath, $comparison) -and -not $dependencyRootPath.StartsWith($repositoryRootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) 'Secret-scan DependencyRoot must be outside the repository worktree.'
[void][IO.Directory]::CreateDirectory($reportRootPath)
$summaryPath = Join-Path $reportRootPath 'gitleaks-summary.json'
$failure = $null
$version = $null
$scans = @()

try {
    Assert-PshGoal6Condition (-not [IO.File]::Exists((Join-Path $repositoryRootPath '.gitleaksignore'))) 'Repository .gitleaksignore files are not permitted by the no-suppression secret gate.'
    Assert-PshGoal6Condition (-not [IO.File]::Exists((Join-Path $repositoryRootPath '.gitleaks.toml'))) 'Repository gitleaks configuration is not permitted by the built-in-default secret gate.'
    $lock = Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath ([IO.Path]::GetFullPath($LockPath))
    $dependency = Get-PshGoal6Dependency -Lock $lock -Id 'gitleaks'
    $executablePath = Resolve-PshGoal6RelativePath -Root $dependencyRootPath -RelativePath ([string]$dependency.package.installedRelativePath) -Description 'gitleaks installed executable'
    Assert-PshGoal6Condition ([IO.File]::Exists($executablePath)) "gitleaks executable is missing: $executablePath"
    Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $executablePath) -ceq [string]$dependency.package.installedSha256) 'gitleaks executable SHA256 mismatches.'
    Assert-PshGoal6Condition ((Get-PshGoal6PeMachine -Path $executablePath) -ceq [string]$dependency.package.peMachine) 'gitleaks executable architecture mismatches.'

    $versionOutput = @(& $executablePath version 2>&1)
    $versionExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Assert-PshGoal6Condition ($versionExitCode -eq 0) "gitleaks version probe failed: $($versionOutput -join ' ')"
    $version = (($versionOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
    Assert-PshGoal6Condition ($version -match ('(?m)\b' + [regex]::Escape([string]$dependency.version) + '\b')) "gitleaks version probe did not report $($dependency.version)."

    $shallowOutput = @(& git -C $repositoryRootPath rev-parse --is-shallow-repository 2>&1)
    $shallowExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Assert-PshGoal6Condition ($shallowExitCode -eq 0 -and (($shallowOutput -join '').Trim()) -ceq 'false') 'Secret history scan requires a non-shallow checkout.'

    $historyScan = Invoke-PshGoal6GitleaksScan -ExecutablePath $executablePath -Mode git -RepositoryRootPath $repositoryRootPath -ReportPath (Join-Path $reportRootPath 'gitleaks-history.json') -LogPath (Join-Path $reportRootPath 'gitleaks-history.log')
    $worktreeScan = Invoke-PshGoal6GitleaksScan -ExecutablePath $executablePath -Mode dir -RepositoryRootPath $repositoryRootPath -ReportPath (Join-Path $reportRootPath 'gitleaks-worktree.json') -LogPath (Join-Path $reportRootPath 'gitleaks-worktree.log')
    $scans = @($historyScan, $worktreeScan)
}
catch { $failure = [string]$_.Exception.Message }

$badScans = @($scans | Where-Object { [string]$_.status -cne 'passed' })
$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'secret-scan'
    status = if ($null -eq $failure -and $badScans.Count -eq 0 -and $scans.Count -eq 2) { 'passed' } else { 'failed' }
    scanner = 'gitleaks'
    scannerVersion = $version
    scannerConfiguration = 'built-in defaults; no repository config, ignore file, or gitleaks:allow comments'
    historyCoverage = 'all refs reachable from a non-shallow checkout'
    worktreeCoverage = 'directory scan including tracked and untracked files'
    redactionPercent = 100
    scans = $scans
    error = $failure
}
Write-PshGoal6Json -Path $summaryPath -InputObject $summary
if ($null -ne $failure) { throw "Secret scan failed: $failure" }
if ($badScans.Count -gt 0 -or $scans.Count -ne 2) { throw "Secret scan detected secrets or scanner errors. See $summaryPath" }
Write-Output ('gitleaks {0} passed for full Git history and worktree scans.' -f [string](Get-PshGoal6Dependency -Lock $lock -Id 'gitleaks').version)
