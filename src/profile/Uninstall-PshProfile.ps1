# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Removes the Psh loader from current-user all-host PowerShell profiles.

.DESCRIPTION
Preflights every target and trusted backup before changing any profile. An
unchanged Psh-installed image is restored directly from its verified original
bytes. If a user edited content outside the canonical block after installation,
only that exact Psh-owned block is removed and the other current bytes remain.

.PARAMETER ProfilePath
Explicit profile files to manage. When omitted, the Windows PowerShell and
PowerShell 7 CurrentUserAllHosts profile paths are resolved beneath the current
user's redirected Documents directory.

.PARAMETER StateRoot
Psh-owned profile backup state. Defaults to
%LOCALAPPDATA%\Psh\profile-state. This override is intended for isolated tests
and installer staging.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [AllowNull()]
    [string[]] $ProfilePath,

    [Parameter()]
    [AllowNull()]
    [string] $StateRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'ProfileBlock.ps1')

$resolvedStateRoot = Get-PshProfileStateRoot -StateRoot $StateRoot
$profileTransactionLock = Enter-PshProfileTransactionLock -StateRoot $resolvedStateRoot
try {
$profilePathWasSpecified = $PSBoundParameters.ContainsKey('ProfilePath')
$targets = @(Resolve-PshProfileTarget -ProfilePath $ProfilePath -ProfilePathWasSpecified $profilePathWasSpecified -StateRoot $resolvedStateRoot)
$manifest = Read-PshProfileManifest -StateRoot $resolvedStateRoot

$targetIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$plans = New-Object System.Collections.Generic.List[object]
$removedEntries = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
    $profileId = Get-PshProfileId -ProfilePath $target
    $null = $targetIds.Add($profileId)
    $entry = Find-PshManifestEntry -Entries @($manifest.Entries) -ProfileId $profileId
    if ($null -ne $entry -and -not [string]::Equals($entry.profilePath, $target, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Trusted Psh profile metadata resolves to a different target: $target"
    }

    $existed = [IO.File]::Exists($target)
    if ($existed) {
        [byte[]] $originalBytes = [IO.File]::ReadAllBytes($target)
    }
    else {
        [byte[]] $originalBytes = New-Object byte[] 0
    }
    $textInfo = Get-PshProfileTextInfo -Bytes $originalBytes -Path $target
    $markerState = Get-PshProfileMarkerState -Text $textInfo.Text -Path $target

    if ($markerState.Present -and $null -eq $entry) {
        throw "A canonical Psh profile block exists without trusted backup metadata; refusing to guess the original content: $target"
    }

    $action = 'None'
    [byte[]] $newBytes = $originalBytes
    $status = 'NotInstalled'
    if ($markerState.Present) {
        $currentSha256 = Get-PshSha256Hex -Bytes $originalBytes
        if ($currentSha256 -ceq $entry.installedSha256) {
            if (-not $manifest.BackupBytesById.ContainsKey($entry.profileId)) {
                throw "Trusted in-memory profile backup bytes are missing: $target"
            }
            [byte[]] $backupBytes = $manifest.BackupBytesById[$entry.profileId]
            if ($entry.originalExisted) {
                $action = 'Restore'
                $newBytes = $backupBytes
                $status = 'RestoredOriginalBytes'
            }
            else {
                $action = 'Delete'
                $newBytes = New-Object byte[] 0
                $status = 'RemovedPshCreatedProfile'
            }
        }
        else {
            $action = 'RemoveBlock'
            $newBytes = Remove-PshProfileBlockByte -TextInfo $textInfo -MarkerState $markerState
            $status = 'RemovedBlockPreservedUserEdits'
        }
    }
    elseif ($null -ne $entry) {
        $status = 'BlockAlreadyAbsent'
    }

    if ($null -ne $entry) {
        $removedEntries.Add($entry)
    }
    $plans.Add([pscustomobject]@{
        ProfilePath   = $target
        ProfileId     = $profileId
        Existed       = $existed
        OriginalBytes = $originalBytes
        NewBytes      = $newBytes
        Action        = $action
        Status        = $status
        Quarantine    = $null
    })
}

# No write is allowed until every target and every referenced backup has passed
# validation and each profile is unchanged from preflight.
foreach ($plan in $plans) {
    Assert-PshFileUnchanged -Path $plan.ProfilePath -ExpectedToExist $plan.Existed -ExpectedBytes $plan.OriginalBytes
}
Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $manifest.Exists -ExpectedBytes $manifest.Bytes

$hasProfileChanges = @($plans | Where-Object { $_.Action -cne 'None' }).Count -gt 0
$hasStateChanges = $removedEntries.Count -gt 0
if (-not $hasProfileChanges -and -not $hasStateChanges) {
    foreach ($plan in $plans) {
        [pscustomobject]@{
            ProfilePath = $plan.ProfilePath
            Status      = $plan.Status
            BackupState = $resolvedStateRoot
        }
    }
    return
}

if (-not $PSCmdlet.ShouldProcess(
    ([string]::Join(', ', $targets)),
    'Remove the Psh CurrentUserAllHosts loader and restore trusted profile state'
)) {
    return
}

$remainingEntries = New-Object System.Collections.Generic.List[object]
foreach ($entry in @($manifest.Entries)) {
    if (-not $targetIds.Contains($entry.profileId)) {
        $remainingEntries.Add($entry)
    }
}
[byte[]] $newManifestBytes = ConvertTo-PshProfileManifestByte -Entries $remainingEntries.ToArray()

$completedPlans = New-Object System.Collections.Generic.List[object]
$manifestWasWritten = $false
$mutationError = $null
try {
    foreach ($plan in $plans) {
        if ($plan.Action -ceq 'None') {
            continue
        }

        Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $manifest.Exists -ExpectedBytes $manifest.Bytes
        Assert-PshFileUnchanged -Path $plan.ProfilePath -ExpectedToExist $true -ExpectedBytes $plan.OriginalBytes
        if ($plan.Action -ceq 'Delete') {
            $plan.Quarantine = Move-PshFileToQuarantine `
                -Path $plan.ProfilePath `
                -ExpectedBytes $plan.OriginalBytes
        }
        else {
            Write-PshAtomicFileByte `
                -Path $plan.ProfilePath `
                -Bytes $plan.NewBytes `
                -ExpectedToExist $true `
                -ExpectedBytes $plan.OriginalBytes
        }
        $completedPlans.Add($plan)
    }

    if ($hasStateChanges) {
        if (-not $manifest.Exists) {
            throw 'Trusted Psh profile entries were selected, but their manifest disappeared before update.'
        }
        Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $true -ExpectedBytes $manifest.Bytes
        Write-PshAtomicFileByte `
            -Path $manifest.ManifestPath `
            -Bytes $newManifestBytes `
            -ExpectedToExist $true `
            -ExpectedBytes $manifest.Bytes
        $manifestWasWritten = $true
    }
}
catch {
    $mutationError = $_
}

if ($null -ne $mutationError) {
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    if ($manifestWasWritten) {
        try {
            Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $true -ExpectedBytes $newManifestBytes
            Write-PshAtomicFileByte `
                -Path $manifest.ManifestPath `
                -Bytes $manifest.Bytes `
                -ExpectedToExist $true `
                -ExpectedBytes $newManifestBytes
        }
        catch {
            $rollbackErrors.Add("$($manifest.ManifestPath): $($_.Exception.Message)")
        }
    }

    for ($index = $completedPlans.Count - 1; $index -ge 0; $index--) {
        $plan = $completedPlans[$index]
        try {
            if ($plan.Action -ceq 'Delete') {
                if ([IO.File]::Exists($plan.ProfilePath)) {
                    throw 'The deleted-profile target was recreated concurrently.'
                }
                if (-not [IO.File]::Exists($plan.Quarantine)) {
                    throw 'The Psh rollback quarantine is missing.'
                }
                [IO.File]::Move($plan.Quarantine, $plan.ProfilePath)
                $plan.Quarantine = $null
            }
            else {
                Assert-PshFileUnchanged -Path $plan.ProfilePath -ExpectedToExist $true -ExpectedBytes $plan.NewBytes
                Write-PshAtomicFileByte `
                    -Path $plan.ProfilePath `
                    -Bytes $plan.OriginalBytes `
                    -ExpectedToExist $true `
                    -ExpectedBytes $plan.NewBytes
            }
        }
        catch {
            $rollbackErrors.Add("$($plan.ProfilePath): $($_.Exception.Message)")
        }
    }

    if ($rollbackErrors.Count -gt 0) {
        throw "Psh profile uninstall failed and rollback was incomplete. Original error: $($mutationError.Exception.Message). Rollback errors: $([string]::Join('; ', $rollbackErrors.ToArray()))"
    }
    throw $mutationError
}

foreach ($plan in $completedPlans) {
    if ($plan.Action -ceq 'Delete' -and $null -ne $plan.Quarantine -and [IO.File]::Exists($plan.Quarantine)) {
        try {
            [IO.File]::Delete($plan.Quarantine)
            $plan.Quarantine = $null
        }
        catch {
            Write-Warning "The profile was safely removed, but its Psh-owned quarantine could not be deleted: $($plan.Quarantine)"
        }
    }
}

foreach ($entry in $removedEntries) {
    $backupPath = Join-Path -Path $manifest.BackupRoot -ChildPath $entry.backupFileName
    if ([IO.File]::Exists($backupPath)) {
        try {
            [IO.File]::Delete($backupPath)
        }
        catch {
            Write-Warning "The profile was restored, but its verified Psh-owned backup could not be deleted: $backupPath"
        }
    }
}

foreach ($plan in $plans) {
    [pscustomobject]@{
        ProfilePath = $plan.ProfilePath
        Status      = $plan.Status
        BackupState = $resolvedStateRoot
    }
}
}
finally {
    Exit-PshProfileTransactionLock -Lock $profileTransactionLock
}
