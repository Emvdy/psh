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

function Invoke-PshGoal6GitCapture {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $output = @(& git -C $RepositoryRootPath @Arguments 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Assert-PshGoal6Condition ($exitCode -eq 0) "$Description failed: $($output -join ' ')"
    return @($output | ForEach-Object { [string]$_ })
}

function Assert-PshGoal6GitleaksEnvironment {
    foreach ($name in @('GITLEAKS_CONFIG', 'GITLEAKS_CONFIG_TOML')) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        Assert-PshGoal6Condition ($null -eq $value) "Secret scan requires environment variable $name to be unset so gitleaks uses the fixed built-in configuration."
    }
}

function Invoke-PshGoal6GitleaksScan {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][ValidateSet('git', 'dir')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string]$IgnoreRootPath,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $ignoreRootPathFull = [IO.Path]::GetFullPath($IgnoreRootPath)
    Assert-PshGoal6Condition ([IO.Directory]::Exists($ignoreRootPathFull)) "Controlled gitleaks ignore root is missing: $ignoreRootPathFull"
    Assert-PshGoal6Condition (@([IO.Directory]::EnumerateFileSystemEntries($ignoreRootPathFull)).Count -eq 0) "Controlled gitleaks ignore root is not empty: $ignoreRootPathFull"
    $arguments = @(
        $Mode,
        '--no-banner',
        '--redact=100',
        '--ignore-gitleaks-allow',
        '--gitleaks-ignore-path', $ignoreRootPathFull,
        '--report-format', 'json',
        '--report-path', $ReportPath
    )
    if ($Mode -ceq 'git') { $arguments += '--log-opts=--all' }
    $arguments += $RepositoryRootPath
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
$ignoreRootPath = Join-Path $reportRootPath 'controlled-empty-ignore-root'
Assert-PshGoal6Condition (-not [IO.File]::Exists($ignoreRootPath)) "Controlled gitleaks ignore root is a file: $ignoreRootPath"
if (-not [IO.Directory]::Exists($ignoreRootPath)) { [void][IO.Directory]::CreateDirectory($ignoreRootPath) }
Assert-PshGoal6Condition (@([IO.Directory]::EnumerateFileSystemEntries($ignoreRootPath)).Count -eq 0) "Controlled gitleaks ignore root is not empty: $ignoreRootPath"
$summaryPath = Join-Path $reportRootPath 'gitleaks-summary.json'
$failure = $null
$version = $null
$scans = @()
$remoteRefCoverage = $null

try {
    Assert-PshGoal6GitleaksEnvironment
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

    $remoteUrlOutput = @(Invoke-PshGoal6GitCapture -RepositoryRootPath $repositoryRootPath -Arguments @('remote', 'get-url', 'origin') -Description 'Resolve origin URL')
    Assert-PshGoal6Condition ($remoteUrlOutput.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$remoteUrlOutput[0])) 'Secret history scan requires exactly one configured origin URL.'
    $remoteLines = @()
    $remoteFailure = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $remoteOutput = @(& git -C $repositoryRootPath ls-remote --heads --tags --refs origin 2>&1)
        $remoteExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        if ($remoteExitCode -eq 0) {
            $remoteLines = @($remoteOutput | ForEach-Object { [string]$_ })
            $remoteFailure = $null
            break
        }
        $remoteFailure = ($remoteOutput -join ' ')
        if ($attempt -lt 4) { Start-Sleep -Seconds 2 }
    }
    Assert-PshGoal6Condition ($null -eq $remoteFailure) "Unable to enumerate origin heads/tags after four attempts: $remoteFailure"
    $localBranchLines = @(Invoke-PshGoal6GitCapture -RepositoryRootPath $repositoryRootPath -Arguments @('for-each-ref', '--format=%(objectname) %(refname)', 'refs/remotes/origin') -Description 'Enumerate local origin branch refs')
    $localTagLines = @(Invoke-PshGoal6GitCapture -RepositoryRootPath $repositoryRootPath -Arguments @('for-each-ref', '--format=%(objectname) %(refname)', 'refs/tags') -Description 'Enumerate local tag refs')
    $remoteRefCoverage = Assert-PshGoal6RemoteRefCoverage -RemoteLines $remoteLines -LocalBranchLines $localBranchLines -LocalTagLines $localTagLines

    $historyScan = Invoke-PshGoal6GitleaksScan -ExecutablePath $executablePath -Mode git -RepositoryRootPath $repositoryRootPath -IgnoreRootPath $ignoreRootPath -ReportPath (Join-Path $reportRootPath 'gitleaks-history.json') -LogPath (Join-Path $reportRootPath 'gitleaks-history.log')
    $worktreeScan = Invoke-PshGoal6GitleaksScan -ExecutablePath $executablePath -Mode dir -RepositoryRootPath $repositoryRootPath -IgnoreRootPath $ignoreRootPath -ReportPath (Join-Path $reportRootPath 'gitleaks-worktree.json') -LogPath (Join-Path $reportRootPath 'gitleaks-worktree.log')
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
    scannerConfiguration = 'built-in defaults; GITLEAKS_CONFIG and GITLEAKS_CONFIG_TOML unset; controlled empty ignore root; no repository config, ignore file, or gitleaks:allow comments'
    historyCoverage = 'gitleaks git --log-opts=--all after exact origin heads/tags parity verification'
    remoteRefCoverage = $remoteRefCoverage
    worktreeCoverage = 'directory scan including tracked and untracked files'
    redactionPercent = 100
    scans = $scans
    error = $failure
}
Write-PshGoal6Json -Path $summaryPath -InputObject $summary
if ($null -ne $failure) { throw "Secret scan failed: $failure" }
if ($badScans.Count -gt 0 -or $scans.Count -ne 2) { throw "Secret scan detected secrets or scanner errors. See $summaryPath" }
Write-Output ('gitleaks {0} passed for full Git history and worktree scans.' -f [string](Get-PshGoal6Dependency -Lock $lock -Id 'gitleaks').version)
