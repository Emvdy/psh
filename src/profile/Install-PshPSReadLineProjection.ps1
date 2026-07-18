# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Projects the pinned PSReadLine 2.4.5 tree into current-user module roots.

.DESCRIPTION
Validates the complete seven-file trusted tree and both targets before writing
anything. New targets are published with a same-parent directory rename.
Byte-identical pre-existing targets are reused without taking ownership.

.PARAMETER SourcePath
Pinned PSReadLine 2.4.5 source tree. By default this is resolved through Psh
current.json.

.PARAMETER ModuleRoot
PowerShell module roots to receive PSReadLine\2.4.5. The defaults are the
Windows PowerShell and PowerShell current-user module roots below Documents.

.PARAMETER StateRoot
Psh-owned projection transaction state. Defaults to
%LOCALAPPDATA%\Psh\psreadline-projection-state.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter()]
    [AllowNull()]
    [string] $SourcePath,

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
$projectionLock = Enter-PshPSReadLineProjectionLock -StateRoot $resolvedStateRoot
try {
    $source = Resolve-PshPSReadLineProjectionSource -SourcePath $SourcePath
    $moduleRootWasSpecified = $PSBoundParameters.ContainsKey('ModuleRoot')
    $resolvedModuleRoots = @(Resolve-PshPSReadLineProjectionModuleRoot -ModuleRoot $ModuleRoot -WasSpecified $moduleRootWasSpecified)
    $manifestPath = Get-PshPSReadLineProjectionStatePath -StateRoot $resolvedStateRoot

    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($resolvedModuleRoot in $resolvedModuleRoots) {
        $targetState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $resolvedModuleRoot
        foreach ($protectedRoot in @($source.Path, $resolvedStateRoot)) {
            if ((Test-PshPathWithinRoot -Path $targetState.TargetPath -Root $protectedRoot) -or
                (Test-PshPathWithinRoot -Path $protectedRoot -Root $targetState.TargetPath)) {
                throw "A PSReadLine projection target overlaps protected Psh storage: $($targetState.TargetPath)"
            }
        }

        $createdParentPaths = New-Object System.Collections.Generic.List[string]
        if (-not [IO.Directory]::Exists($targetState.ModuleRoot)) {
            $createdParentPaths.Add([string] $targetState.ModuleRoot)
        }
        if (-not [IO.Directory]::Exists($targetState.ContainerPath)) {
            $createdParentPaths.Add([string] $targetState.ContainerPath)
        }
        $disposition = if ($targetState.Exists) { 'reused' } else { 'created' }
        $plans.Add([pscustomobject][ordered]@{
            ModuleRoot         = [string] $targetState.ModuleRoot
            ContainerPath      = [string] $targetState.ContainerPath
            TargetPath         = [string] $targetState.TargetPath
            Disposition        = $disposition
            CreatedParentPaths = if ($disposition -ceq 'created') { $createdParentPaths.ToArray() } else { @() }
        })
    }
    Assert-PshPSReadLineProjectionTargetsIndependent -Targets $plans.ToArray()
    foreach ($resolvedModuleRoot in $resolvedModuleRoots) {
        if ((Test-PshPathWithinRoot -Path $resolvedModuleRoot -Root $resolvedStateRoot) -or
            (Test-PshPathWithinRoot -Path $resolvedStateRoot -Root $resolvedModuleRoot)) {
            throw "A PSReadLine module root overlaps projection state: $resolvedModuleRoot"
        }
    }

    $manifest = Read-PshPSReadLineProjectionManifest -StateRoot $resolvedStateRoot
    if ($manifest.Exists) {
        if ($manifest.State -cne 'complete' -or $manifest.Operation -cne 'install') {
            throw "An unfinished PSReadLine projection transaction requires recovery before installation: $manifestPath"
        }
        if (-not (Test-PshPSReadLineProjectionTargetSetEqual -ModuleRoots $resolvedModuleRoots -Targets @($manifest.Targets))) {
            throw 'The requested PSReadLine module roots differ from trusted projection state.'
        }
        if ([string] $manifest.Fingerprint.TreeSha256 -cne [string] $source.Fingerprint.TreeSha256) {
            throw 'The current PSReadLine source differs from trusted projection state.'
        }

        foreach ($resolvedModuleRoot in $resolvedModuleRoots) {
            $entry = @($manifest.Targets | Where-Object {
                Test-PshPSReadLineProjectionPathEqual -Left ([string] $_.ModuleRoot) -Right $resolvedModuleRoot
            })[0]
            $liveState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $resolvedModuleRoot
            if (-not $liveState.Exists) {
                throw "A recorded PSReadLine projection target is missing: $($entry.TargetPath)"
            }
            $status = if ($entry.Disposition -ceq 'created') { 'AlreadyCreated' } else { 'Reused' }
            New-PshPSReadLineProjectionResult -SourcePath $source.Path -ModuleRoot $resolvedModuleRoot -TargetPath ([string] $entry.TargetPath) -Disposition ([string] $entry.Disposition) -Status $status -Owned ($entry.Disposition -ceq 'created') -Changed $false -StateRoot $resolvedStateRoot -ManifestPath $manifestPath -ManifestState 'complete'
        }
        return
    }

    $targetDescription = [string]::Join(', ', @($plans | ForEach-Object { [string] $_.TargetPath }))
    if (-not $PSCmdlet.ShouldProcess(
            $targetDescription,
            'Project verified PSReadLine 2.4.5 and record current-user ownership state'
        )) {
        foreach ($plan in $plans) {
            $status = if ($plan.Disposition -ceq 'created') { 'WouldCreate' } else { 'WouldReuse' }
            New-PshPSReadLineProjectionResult -SourcePath $source.Path -ModuleRoot $plan.ModuleRoot -TargetPath $plan.TargetPath -Disposition $plan.Disposition -Status $status -Owned ($plan.Disposition -ceq 'created') -Changed $false -StateRoot $resolvedStateRoot -ManifestPath $manifestPath -ManifestState 'planned'
        }
        return
    }

    $transactionId = ([Guid]::NewGuid()).ToString('N')
    [byte[]] $pendingBytes = ConvertTo-PshPSReadLineProjectionManifestByte -State 'pending' -Operation 'install' -TransactionId $transactionId -SourcePath $source.Path -Fingerprint $source.Fingerprint -Targets $plans.ToArray()
    [byte[]] $completeBytes = ConvertTo-PshPSReadLineProjectionManifestByte -State 'complete' -Operation 'install' -TransactionId $transactionId -SourcePath $source.Path -Fingerprint $source.Fingerprint -Targets $plans.ToArray()

    $stateRootCreated = $false
    $manifestWritten = $false
    [byte[]] $currentManifestBytes = New-Object byte[] 0
    $completedPlans = New-Object System.Collections.Generic.List[object]
    $mutationError = $null
    try {
        if (-not [IO.Directory]::Exists($resolvedStateRoot)) {
            [IO.Directory]::CreateDirectory($resolvedStateRoot) | Out-Null
            $stateRootCreated = $true
        }
        Assert-PshNotReparsePoint -Path $resolvedStateRoot -Description 'The PSReadLine projection state root'
        Assert-PshPSReadLineProjectionStateRootClean -StateRoot $resolvedStateRoot
        Write-PshAtomicFileByte -Path $manifestPath -Bytes $pendingBytes -ExpectedToExist $false -ExpectedBytes (New-Object byte[] 0)
        $manifestWritten = $true
        $currentManifestBytes = $pendingBytes

        foreach ($plan in $plans) {
            if ($plan.Disposition -ceq 'reused') {
                $reusedState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $plan.ModuleRoot
                if (-not $reusedState.Exists) {
                    throw "A reused PSReadLine target changed after preflight: $($plan.TargetPath)"
                }
                continue
            }
            $null = New-PshPSReadLineProjectionTarget -Plan $plan -SourceFingerprint $source.Fingerprint
            $completedPlans.Add($plan)
        }

        foreach ($plan in $plans) {
            $finalState = Get-PshPSReadLineProjectionTargetState -ModuleRoot $plan.ModuleRoot
            if (-not $finalState.Exists) {
                throw "A PSReadLine projection target changed before transaction completion: $($plan.TargetPath)"
            }
        }
        Write-PshAtomicFileByte -Path $manifestPath -Bytes $completeBytes -ExpectedToExist $true -ExpectedBytes $pendingBytes
        $currentManifestBytes = $completeBytes
    }
    catch {
        $mutationError = $_
    }

    if ($null -ne $mutationError) {
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        for ($index = $completedPlans.Count - 1; $index -ge 0; $index--) {
            $plan = $completedPlans[$index]
            try {
                $quarantine = Move-PshPSReadLineProjectionToQuarantine -TargetPath $plan.TargetPath
                Remove-PshPSReadLineProjectionExactTree -Path $quarantine
            }
            catch {
                $rollbackErrors.Add("$($plan.TargetPath): $($_.Exception.Message)")
            }
        }

        if ($rollbackErrors.Count -eq 0 -and $manifestWritten) {
            try {
                $manifestQuarantine = Move-PshFileToQuarantine -Path $manifestPath -ExpectedBytes $currentManifestBytes
                [IO.File]::Delete($manifestQuarantine)
                $manifestWritten = $false
            }
            catch {
                $rollbackErrors.Add(("{0}: {1}" -f $manifestPath, $_.Exception.Message))
            }
        }

        if ($rollbackErrors.Count -eq 0) {
            try {
                $createdParentPaths = @($plans | ForEach-Object { @($_.CreatedParentPaths) })
                Remove-PshPSReadLineProjectionEmptyParent -Paths $createdParentPaths
                if ($stateRootCreated -and [IO.Directory]::Exists($resolvedStateRoot) -and
                    @(Get-ChildItem -LiteralPath $resolvedStateRoot -Force).Count -eq 0) {
                    [IO.Directory]::Delete($resolvedStateRoot, $false)
                }
            }
            catch {
                $rollbackErrors.Add("Projection parent cleanup: $($_.Exception.Message)")
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            throw "PSReadLine projection installation failed and rollback was incomplete. Original error: $($mutationError.Exception.Message). Rollback errors: $([string]::Join('; ', $rollbackErrors.ToArray()))"
        }
        throw $mutationError
    }

    foreach ($plan in $plans) {
        $status = if ($plan.Disposition -ceq 'created') { 'Created' } else { 'Reused' }
        New-PshPSReadLineProjectionResult -SourcePath $source.Path -ModuleRoot $plan.ModuleRoot -TargetPath $plan.TargetPath -Disposition $plan.Disposition -Status $status -Owned ($plan.Disposition -ceq 'created') -Changed ($plan.Disposition -ceq 'created') -StateRoot $resolvedStateRoot -ManifestPath $manifestPath -ManifestState 'complete'
    }
}
finally {
    Exit-PshPSReadLineProjectionLock -Lock $projectionLock
}
