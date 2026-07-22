# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_REPOSITORY_ROOT', 'Process')
$reportRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_REPORT_ROOT', 'Process')
$goldenRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_GOLDEN_ROOT', 'Process')
if ([string]::IsNullOrWhiteSpace($repositoryRoot)) { throw 'PSH_GOAL6_REPOSITORY_ROOT is required.' }
if ([string]::IsNullOrWhiteSpace($reportRoot)) { throw 'PSH_GOAL6_REPORT_ROOT is required.' }
if ([string]::IsNullOrWhiteSpace($goldenRoot)) { throw 'PSH_GOAL6_GOLDEN_ROOT is required.' }
$repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot)
$reportRoot = [IO.Path]::GetFullPath($reportRoot)
$goldenRoot = [IO.Path]::GetFullPath($goldenRoot)

$batch1GoldenRoot = Join-Path $goldenRoot 'batch1'
$batch2GoldenRoot = Join-Path $goldenRoot 'batch2'
$batch4GoldenRoot = Join-Path $goldenRoot 'batch4'

$goal6AcceptanceCases = @(
    @{ Name = 'goal1-acceptance'; RelativePath = 'tests/Goal1.Acceptance.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal2-acceptance'; RelativePath = 'tests/Goal2.Acceptance.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal3-batch1-config'; RelativePath = 'tests/Goal3.Batch1.Config.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal3-batch1-alias-scope'; RelativePath = 'tests/Goal3.Batch1.AliasScope.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal3-batch1-file-commands'; RelativePath = 'tests/Goal3.Batch1.FileCommands.ps1'; Arguments = @('-GoldenRoot', $batch1GoldenRoot) }
    @{ Name = 'goal3-batch2-text-commands'; RelativePath = 'tests/Goal3.Batch2.TextCommands.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot, '-GoldenRoot', $batch2GoldenRoot) }
    @{ Name = 'goal3-batch3-complex-commands'; RelativePath = 'tests/Goal3.Batch3.ComplexCommands.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal3-batch4-system-process'; RelativePath = 'tests/Goal3.Batch4.SystemProcessCommands.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot, '-GoldenRoot', $batch4GoldenRoot) }
    @{ Name = 'goal3-batch4-network'; RelativePath = 'tests/Goal3.Batch4.NetworkCommands.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal3-batch4-archive'; RelativePath = 'tests/Goal3.Batch4.ArchiveCommands.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot, '-GoldenRoot', $batch4GoldenRoot) }
    @{ Name = 'goal4-acceptance'; RelativePath = 'tests/Goal4.Acceptance.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-workflow-contract'; RelativePath = 'tests/Goal5.WorkflowContract.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-package-lifecycle'; RelativePath = 'tests/Goal5.PackageLifecycle.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-lifecycle-acceptance'; RelativePath = 'tests/Goal5.LifecycleAcceptance.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-uninstall-safety'; RelativePath = 'tests/Goal5.UninstallSafety.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-bootstrapper'; RelativePath = 'tests/Goal5.Bootstrapper.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-release-trust'; RelativePath = 'tests/Goal5.ReleaseTrust.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-acquisition'; RelativePath = 'tests/Goal5.Acquisition.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-online-offline'; RelativePath = 'tests/Goal5.OnlineOffline.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
    @{ Name = 'goal5-package-build'; RelativePath = 'tests/Goal5.PackageBuild.ps1'; Arguments = @('-RepositoryRoot', $repositoryRoot) }
)

Describe 'Goal 6 fixed Goal 1-5 acceptance matrix' {
    BeforeAll {
        $script:Goal6RepositoryRoot = [IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('PSH_GOAL6_REPOSITORY_ROOT', 'Process'))
        $script:Goal6ReportRoot = [IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('PSH_GOAL6_REPORT_ROOT', 'Process'))
        $script:Goal6Batch1GoldenRoot = Join-Path ([IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('PSH_GOAL6_GOLDEN_ROOT', 'Process'))) 'batch1'
        $script:Goal6Batch2GoldenRoot = Join-Path ([IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('PSH_GOAL6_GOLDEN_ROOT', 'Process'))) 'batch2'
        $script:Goal6Batch4GoldenRoot = Join-Path ([IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('PSH_GOAL6_GOLDEN_ROOT', 'Process'))) 'batch4'
        $script:Goal6Utf8 = New-Object Text.UTF8Encoding($false, $true)
        $script:Goal6EnginePath = [string](Get-Process -Id $PID -ErrorAction Stop).Path
        if ([string]::IsNullOrWhiteSpace($script:Goal6EnginePath) -or -not [IO.File]::Exists($script:Goal6EnginePath)) {
            throw 'Unable to resolve the current PowerShell executable.'
        }
        foreach ($requiredGoldenRoot in @($script:Goal6Batch1GoldenRoot, $script:Goal6Batch2GoldenRoot, $script:Goal6Batch4GoldenRoot)) {
            if (-not [IO.Directory]::Exists($requiredGoldenRoot)) {
                throw "Required GNU golden directory is missing: $requiredGoldenRoot"
            }
        }

        function Invoke-PshGoal6AcceptanceScript {
            param(
                [Parameter(Mandatory = $true)][string] $Name,
                [Parameter(Mandatory = $true)][string] $RelativePath,
                [Parameter()][AllowEmptyCollection()][string[]] $Arguments = @()
            )

            $testPath = Join-Path $script:Goal6RepositoryRoot $RelativePath
            if (-not [IO.File]::Exists($testPath)) { throw "Required acceptance script is missing: $RelativePath" }
            $caseRoot = Join-Path $script:Goal6ReportRoot ('acceptance/' + $Name)
            $logPath = Join-Path $caseRoot 'output.log'
            [void][IO.Directory]::CreateDirectory($caseRoot)
            $oldGoal5ReportRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL5_REPORT_ROOT', 'Process')
            $oldGoal5PreSignRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL5_PRE_SIGN_ROOT', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('PSH_GOAL5_REPORT_ROOT', (Join-Path $caseRoot 'goal5-reports'), 'Process')
                [Environment]::SetEnvironmentVariable('PSH_GOAL5_PRE_SIGN_ROOT', (Join-Path $caseRoot 'goal5-reports/pre-sign-build'), 'Process')
                $lines = New-Object System.Collections.Generic.List[string]
                $oldPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & $script:Goal6EnginePath -NoLogo -NoProfile -NonInteractive -File $testPath @Arguments 2>&1 | ForEach-Object {
                        [void]$lines.Add([string]$_)
                    }
                    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
                }
                finally { $ErrorActionPreference = $oldPreference }
                $global:LASTEXITCODE = 0
                $logText = ($lines.ToArray() -join "`n") + "`n"
                [IO.File]::WriteAllText($logPath, $logText, $script:Goal6Utf8)
                return [pscustomobject][ordered]@{
                    ExitCode = $exitCode
                    DeferredOrSkipped = $logText -match '(?i)\b(?:deferred|skipped)\b'
                    LogPath = $logPath
                    Tail = @($lines.ToArray() | Select-Object -Last 30)
                }
            }
            finally {
                [Environment]::SetEnvironmentVariable('PSH_GOAL5_REPORT_ROOT', $oldGoal5ReportRoot, 'Process')
                [Environment]::SetEnvironmentVariable('PSH_GOAL5_PRE_SIGN_ROOT', $oldGoal5PreSignRoot, 'Process')
            }
        }
    }

    It 'runs <Name> without failure, skip, or deferral' -TestCases $goal6AcceptanceCases {
        param($Name, $RelativePath, $Arguments)

        $result = Invoke-PshGoal6AcceptanceScript -Name $Name -RelativePath $RelativePath -Arguments $Arguments
        if ([int]$result.ExitCode -ne 0) {
            throw ('{0} exited {1}; log: {2}; tail: {3}' -f $RelativePath, $result.ExitCode, $result.LogPath, ($result.Tail -join ' | '))
        }
        if ([bool]$result.DeferredOrSkipped) {
            throw ("$RelativePath reported deferred or skipped coverage; log: $($result.LogPath)")
        }
    }
}
