# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Installs the Psh loader in current-user all-host PowerShell profiles.

.DESCRIPTION
Preflights every target before changing any profile. Existing profile bytes are
stored in verified Psh-owned backups, and each profile is then updated through
a same-directory temporary file and atomic replacement.

.PARAMETER ProfilePath
Explicit profile files to manage. When omitted, the Windows PowerShell and
PowerShell 7 CurrentUserAllHosts profile paths are resolved beneath the current
user's redirected Documents directory.

.PARAMETER StateRoot
Psh-owned profile backup state. Defaults to
%LOCALAPPDATA%\Psh\profile-state. This override is intended for isolated tests
and installer staging.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
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

$plans = New-Object System.Collections.Generic.List[object]
$newEntries = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
    $profileId = Get-PshProfileId -ProfilePath $target
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

    if ($markerState.Present) {
        if ($null -eq $entry) {
            throw "A canonical Psh profile block exists without trusted backup metadata; refusing to guess the original content: $target"
        }

        $plans.Add([pscustomobject]@{
            ProfilePath  = $target
            ProfileId    = $profileId
            Existed      = $existed
            OriginalBytes = $originalBytes
            NewBytes     = $originalBytes
            Change       = $false
            Status       = 'AlreadyInstalled'
        })
        continue
    }

    [byte[]] $installedBytes = New-PshInstalledProfileByte -TextInfo $textInfo
    if ($null -eq $entry) {
        $backupFileName = $profileId + '.bin'
        $backupPath = Join-Path -Path $manifest.BackupRoot -ChildPath $backupFileName
        if (-not (Test-PshPathWithinRoot -Path $backupPath -Root $manifest.BackupRoot)) {
            throw "A derived Psh profile backup path escaped the backup root: $target"
        }
        if ([IO.File]::Exists($backupPath) -or [IO.Directory]::Exists($backupPath)) {
            throw "Unreferenced backup state already exists for the profile; refusing to overwrite it: $backupPath"
        }

        $entry = [pscustomobject][ordered]@{
            profileId       = $profileId
            profilePath     = $target
            backupFileName  = $backupFileName
            originalExisted = $existed
            originalLength  = [long] $originalBytes.LongLength
            originalSha256  = Get-PshSha256Hex -Bytes $originalBytes
            installedSha256 = Get-PshSha256Hex -Bytes $installedBytes
        }
        $newEntries.Add($entry)
    }

    $plans.Add([pscustomobject]@{
        ProfilePath   = $target
        ProfileId     = $profileId
        Existed       = $existed
        OriginalBytes = $originalBytes
        NewBytes      = $installedBytes
        Change        = $true
        Status        = 'Installed'
    })
}

# Recheck every input before the first filesystem mutation. This closes the
# preflight-to-backup window for ordinary concurrent profile edits.
foreach ($plan in $plans) {
    Assert-PshFileUnchanged -Path $plan.ProfilePath -ExpectedToExist $plan.Existed -ExpectedBytes $plan.OriginalBytes
    if ($plan.Change) {
        $parent = [IO.Path]::GetDirectoryName($plan.ProfilePath)
        if ([IO.File]::Exists($parent)) {
            throw "A profile parent path is a file: $parent"
        }
    }
}
Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $manifest.Exists -ExpectedBytes $manifest.Bytes

if (-not $PSCmdlet.ShouldProcess(
    ([string]::Join(', ', $targets)),
    'Back up and install the Psh CurrentUserAllHosts loader transaction'
)) {
    return
}

$combinedEntries = New-Object System.Collections.Generic.List[object]
foreach ($entry in @($manifest.Entries)) {
    $combinedEntries.Add($entry)
}
foreach ($entry in $newEntries) {
    $combinedEntries.Add($entry)
}
[byte[]] $newManifestBytes = ConvertTo-PshProfileManifestByte -Entries $combinedEntries.ToArray()

$createdBackupPaths = New-Object System.Collections.Generic.List[string]
$completedPlans = New-Object System.Collections.Generic.List[object]
$manifestWasWritten = $false
$mutationError = $null
try {
    Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $manifest.Exists -ExpectedBytes $manifest.Bytes
    [IO.Directory]::CreateDirectory($resolvedStateRoot) | Out-Null
    Assert-PshNotReparsePoint -Path $resolvedStateRoot -Description 'The profile state root'
    [IO.Directory]::CreateDirectory($manifest.BackupRoot) | Out-Null
    Assert-PshNotReparsePoint -Path $manifest.BackupRoot -Description 'The profile backup directory'

    foreach ($plan in $plans) {
        if ($plan.Change) {
            $parent = [IO.Path]::GetDirectoryName($plan.ProfilePath)
            [IO.Directory]::CreateDirectory($parent) | Out-Null
        }
    }

    foreach ($entry in $newEntries) {
        $plan = $plans | Where-Object { $_.ProfileId -ceq $entry.profileId } | Select-Object -First 1
        if ($null -eq $plan) {
            throw "Internal profile backup plan is missing for: $($entry.profilePath)"
        }
        $backupPath = Join-Path -Path $manifest.BackupRoot -ChildPath $entry.backupFileName
        Write-PshNewFileByte -Path $backupPath -Bytes $plan.OriginalBytes
        $createdBackupPaths.Add($backupPath)
        [byte[]] $verifiedBackupBytes = [IO.File]::ReadAllBytes($backupPath)
        if ($verifiedBackupBytes.LongLength -ne $entry.originalLength -or
            (Get-PshSha256Hex -Bytes $verifiedBackupBytes) -cne $entry.originalSha256) {
            throw "The new profile backup failed byte-for-byte verification: $backupPath"
        }
    }

    if ($newEntries.Count -gt 0) {
        Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $manifest.Exists -ExpectedBytes $manifest.Bytes
        Write-PshAtomicFileByte `
            -Path $manifest.ManifestPath `
            -Bytes $newManifestBytes `
            -ExpectedToExist $manifest.Exists `
            -ExpectedBytes $manifest.Bytes
        $manifestWasWritten = $true
    }

    foreach ($plan in $plans) {
        if (-not $plan.Change) {
            continue
        }
        if ($manifestWasWritten) {
            Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $true -ExpectedBytes $newManifestBytes
        }
        else {
            Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $manifest.Exists -ExpectedBytes $manifest.Bytes
        }
        Assert-PshFileUnchanged -Path $plan.ProfilePath -ExpectedToExist $plan.Existed -ExpectedBytes $plan.OriginalBytes
        Write-PshAtomicFileByte `
            -Path $plan.ProfilePath `
            -Bytes $plan.NewBytes `
            -ExpectedToExist $plan.Existed `
            -ExpectedBytes $plan.OriginalBytes
        $completedPlans.Add($plan)
    }
}
catch {
    $mutationError = $_
}

if ($null -ne $mutationError) {
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    for ($index = $completedPlans.Count - 1; $index -ge 0; $index--) {
        $plan = $completedPlans[$index]
        try {
            Assert-PshFileUnchanged -Path $plan.ProfilePath -ExpectedToExist $true -ExpectedBytes $plan.NewBytes
            if ($plan.Existed) {
                Write-PshAtomicFileByte `
                    -Path $plan.ProfilePath `
                    -Bytes $plan.OriginalBytes `
                    -ExpectedToExist $true `
                    -ExpectedBytes $plan.NewBytes
            }
            else {
                $rollbackQuarantine = Move-PshFileToQuarantine `
                    -Path $plan.ProfilePath `
                    -ExpectedBytes $plan.NewBytes
                [IO.File]::Delete($rollbackQuarantine)
            }
        }
        catch {
            $rollbackErrors.Add("$($plan.ProfilePath): $($_.Exception.Message)")
        }
    }

    if ($manifestWasWritten) {
        try {
            Assert-PshFileUnchanged -Path $manifest.ManifestPath -ExpectedToExist $true -ExpectedBytes $newManifestBytes
            if ($manifest.Exists) {
                Write-PshAtomicFileByte `
                    -Path $manifest.ManifestPath `
                    -Bytes $manifest.Bytes `
                    -ExpectedToExist $true `
                    -ExpectedBytes $newManifestBytes
            }
            else {
                $manifestQuarantine = Move-PshFileToQuarantine `
                    -Path $manifest.ManifestPath `
                    -ExpectedBytes $newManifestBytes
                [IO.File]::Delete($manifestQuarantine)
            }
        }
        catch {
            $rollbackErrors.Add("$($manifest.ManifestPath): $($_.Exception.Message)")
        }
    }

    # If any profile or manifest rollback failed, retain the verified backups as
    # recovery evidence. Deleting them could turn a recoverable partial state
    # into profile data loss.
    if ($rollbackErrors.Count -eq 0) {
        foreach ($backupPath in $createdBackupPaths) {
            try {
                if ([IO.File]::Exists($backupPath)) {
                    [IO.File]::Delete($backupPath)
                }
            }
            catch {
                $rollbackErrors.Add("${backupPath}: $($_.Exception.Message)")
            }
        }
    }

    if ($rollbackErrors.Count -gt 0) {
        throw "Psh profile installation failed and rollback was incomplete. Original error: $($mutationError.Exception.Message). Rollback errors: $([string]::Join('; ', $rollbackErrors.ToArray()))"
    }
    throw $mutationError
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
