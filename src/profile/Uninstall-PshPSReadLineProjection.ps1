# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Removes Psh-owned current-user PSReadLine 2.4.5 projections.

.DESCRIPTION
Preflights every recorded target before deletion. Only targets recorded as
created by Psh and still matching the trusted seven-file tree are removed.
Targets recorded as reused are validated and retained.

.PARAMETER ModuleRoot
PowerShell module roots whose projection state is being removed. The defaults
are the Windows PowerShell and PowerShell current-user module roots.

.PARAMETER StateRoot
Psh-owned projection transaction state. Defaults to
%LOCALAPPDATA%\Psh\psreadline-projection-state.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [Alias('TargetRoot', 'TargetModuleRoot')]
    [AllowNull()]
    [string[]] $ModuleRoot,

    [Parameter()]
    [AllowNull()]
    [string] $StateRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'PSReadLineProjection.ps1')

$resolvedStateRoot = Get-PshPSReadLineProjectionStateRoot -StateRoot $StateRoot
$moduleRootWasSpecified = $PSBoundParameters.ContainsKey('ModuleRoot')
$resolvedModuleRoots = @(Resolve-PshPSReadLineProjectionModuleRoot -ModuleRoot $ModuleRoot -WasSpecified $moduleRootWasSpecified)
$manifestPath = Get-PshPSReadLineProjectionStatePath -StateRoot $resolvedStateRoot
$projectionLock = Enter-PshPSReadLineProjectionLock -StateRoot $resolvedStateRoot
try {
    $manifest = Read-PshPSReadLineProjectionManifest -StateRoot $resolvedStateRoot
    if (-not $manifest.Exists) {
        foreach ($resolvedModuleRoot in $resolvedModuleRoots) {
            New-PshPSReadLineProjectionResult -SourcePath $null -ModuleRoot $resolvedModuleRoot -TargetPath (Get-PshPSReadLineProjectionTargetPath -ModuleRoot $resolvedModuleRoot) -Disposition 'none' -Status 'NotInstalled' -Owned $false -Changed $false -StateRoot $resolvedStateRoot -ManifestPath $manifestPath -ManifestState $null
        }
        return
    }
    if ($manifest.State -cne 'complete' -or $manifest.Operation -cne 'install') {
        throw "An unfinished PSReadLine projection transaction requires recovery before uninstall: $manifestPath"
    }
    if (-not (Test-PshPSReadLineProjectionTargetSetEqual -ModuleRoots $resolvedModuleRoots -Targets @($manifest.Targets))) {
        throw 'The requested PSReadLine module roots differ from trusted projection state.'
    }

    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($resolvedModuleRoot in $resolvedModuleRoots) {
        $entry = @($manifest.Targets | Where-Object {
            Test-PshPSReadLineProjectionPathEqual -Left ([string] $_.ModuleRoot) -Right $resolvedModuleRoot
        })[0]
        $liveState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $resolvedModuleRoot
        if (-not $liveState.Exists) {
            throw "A recorded PSReadLine projection target is missing or was modified: $($entry.TargetPath)"
        }
        $plans.Add([pscustomobject][ordered]@{
            ModuleRoot         = [string] $entry.ModuleRoot
            TargetPath         = [string] $entry.TargetPath
            Disposition        = [string] $entry.Disposition
            CreatedParentPaths = @($entry.CreatedParentPaths)
        })
    }

    $ownedTargets = @($plans | Where-Object { $_.Disposition -ceq 'created' } | ForEach-Object { [string] $_.TargetPath })
    $operationTarget = if ($ownedTargets.Count -gt 0) {
        [string]::Join(', ', $ownedTargets)
    }
    else {
        $manifestPath
    }
    if (-not $PSCmdlet.ShouldProcess(
            $operationTarget,
            'Remove unchanged Psh-owned PSReadLine projections and projection state'
        )) {
        foreach ($plan in $plans) {
            $status = if ($plan.Disposition -ceq 'created') { 'WouldRemove' } else { 'WouldRetainReused' }
            New-PshPSReadLineProjectionResult -SourcePath $manifest.SourcePath -ModuleRoot $plan.ModuleRoot -TargetPath $plan.TargetPath -Disposition $plan.Disposition -Status $status -Owned ($plan.Disposition -ceq 'created') -Changed $false -StateRoot $resolvedStateRoot -ManifestPath $manifestPath -ManifestState 'planned'
        }
        return
    }

    $transactionId = ([Guid]::NewGuid()).ToString('N')
    [byte[]] $pendingBytes = ConvertTo-PshPSReadLineProjectionManifestByte -State 'pending' -Operation 'uninstall' -TransactionId $transactionId -SourcePath $manifest.SourcePath -Fingerprint $manifest.Fingerprint -Targets $manifest.Targets
    $movedTargets = New-Object System.Collections.Generic.List[object]
    $manifestQuarantine = $null
    $mutationError = $null
    try {
        Write-PshAtomicFileByte -Path $manifestPath -Bytes $pendingBytes -ExpectedToExist $true -ExpectedBytes $manifest.Bytes

        foreach ($plan in $plans) {
            if ($plan.Disposition -ceq 'reused') {
                $retainedState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $plan.ModuleRoot
                if (-not $retainedState.Exists) {
                    throw "A reused PSReadLine target changed after uninstall preflight: $($plan.TargetPath)"
                }
                continue
            }
            $quarantine = Move-PshPSReadLineProjectionToQuarantine -TargetPath $plan.TargetPath
            $movedTargets.Add([pscustomobject][ordered]@{
                Plan           = $plan
                QuarantinePath = $quarantine
            })
        }

        foreach ($plan in @($plans | Where-Object { $_.Disposition -ceq 'reused' })) {
            $retainedState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $plan.ModuleRoot
            if (-not $retainedState.Exists) {
                throw "A reused PSReadLine target changed before uninstall commit: $($plan.TargetPath)"
            }
        }

        $manifestQuarantine = Move-PshFileToQuarantine -Path $manifestPath -ExpectedBytes $pendingBytes
        foreach ($movedTarget in $movedTargets) {
            Remove-PshPSReadLineProjectionExactTree -Path $movedTarget.QuarantinePath
        }
        [IO.File]::Delete($manifestQuarantine)
        $manifestQuarantine = $null
    }
    catch {
        $mutationError = $_
    }

    if ($null -ne $mutationError) {
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        if (-not [IO.File]::Exists($manifestPath) -and
            $null -ne $manifestQuarantine -and
            [IO.File]::Exists($manifestQuarantine)) {
            try {
                [IO.File]::Move($manifestQuarantine, $manifestPath)
                $manifestQuarantine = $null
            }
            catch {
                $rollbackErrors.Add("Projection manifest recovery: $($_.Exception.Message)")
            }
        }

        for ($index = $movedTargets.Count - 1; $index -ge 0; $index--) {
            $movedTarget = $movedTargets[$index]
            try {
                if ([IO.Directory]::Exists($movedTarget.QuarantinePath)) {
                    Restore-PshPSReadLineProjectionQuarantine -QuarantinePath $movedTarget.QuarantinePath -TargetPath $movedTarget.Plan.TargetPath
                }
                elseif (-not [IO.Directory]::Exists($movedTarget.Plan.TargetPath)) {
                    throw 'The rollback image was already removed.'
                }
            }
            catch {
                $rollbackErrors.Add("$($movedTarget.Plan.TargetPath): $($_.Exception.Message)")
            }
        }

        if ($rollbackErrors.Count -eq 0) {
            try {
                Assert-PshFileUnchanged -Path $manifestPath -ExpectedToExist $true -ExpectedBytes $pendingBytes
                Write-PshAtomicFileByte -Path $manifestPath -Bytes $manifest.Bytes -ExpectedToExist $true -ExpectedBytes $pendingBytes
            }
            catch {
                $rollbackErrors.Add("Projection manifest rollback: $($_.Exception.Message)")
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            throw "PSReadLine projection uninstall failed and rollback was incomplete. Original error: $($mutationError.Exception.Message). Rollback errors: $([string]::Join('; ', $rollbackErrors.ToArray()))"
        }
        throw $mutationError
    }

    $createdParentPaths = @(
        $plans |
            Where-Object { $_.Disposition -ceq 'created' } |
            ForEach-Object { @($_.CreatedParentPaths) }
    )
    Remove-PshPSReadLineProjectionEmptyParent -Paths $createdParentPaths
    if ([IO.Directory]::Exists($resolvedStateRoot) -and
        @(Get-ChildItem -LiteralPath $resolvedStateRoot -Force).Count -eq 0) {
        [IO.Directory]::Delete($resolvedStateRoot, $false)
    }

    foreach ($plan in $plans) {
        $status = if ($plan.Disposition -ceq 'created') { 'Removed' } else { 'RetainedReused' }
        New-PshPSReadLineProjectionResult -SourcePath $manifest.SourcePath -ModuleRoot $plan.ModuleRoot -TargetPath $plan.TargetPath -Disposition $plan.Disposition -Status $status -Owned ($plan.Disposition -ceq 'created') -Changed ($plan.Disposition -ceq 'created') -StateRoot $resolvedStateRoot -ManifestPath $manifestPath -ManifestState $null
    }
}
finally {
    Exit-PshPSReadLineProjectionLock -Lock $projectionLock
}
