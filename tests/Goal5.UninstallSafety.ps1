# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param([string] $RepositoryRoot)

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $scriptPath = [string]$MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'Goal 5 uninstall safety acceptance could not resolve its script path.'
    }
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $scriptPath)
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Assertions = 0
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

$lifecycleHelpers = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
$installScript = Join-Path $RepositoryRoot 'src/install/Install-PshPackage.ps1'
$uninstallScript = Join-Path $RepositoryRoot 'src/install/Uninstall-Psh.ps1'
$profileUninstallScript = Join-Path $RepositoryRoot 'src/profile/Uninstall-PshProfile.ps1'
. $lifecycleHelpers

function Assert-PshUninstallSafety {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
    $script:Assertions++
    if (-not $Condition) { throw "Goal 5 uninstall safety failed: $Message" }
}

function Test-PshUninstallSafetyBytesEqual {
    param([Parameter(Mandatory = $true)][byte[]] $Left, [Parameter(Mandatory = $true)][byte[]] $Right)
    return [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

function Write-PshUninstallSafetyText {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Get-PshUninstallSafetyHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-PshUninstallSafetyRelativePath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Path)
    $rootUri = New-Object Uri(([IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar))
    $pathUri = New-Object Uri([IO.Path]::GetFullPath($Path))
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('\', '/')
}

function Get-PshUninstallSafetyTreeSnapshot {
    param([Parameter(Mandatory = $true)][string] $Root)
    if (-not [IO.Directory]::Exists($Root)) { return '<absent>' }
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName)) {
        $relative = Get-PshUninstallSafetyRelativePath -Root $Root -Path $item.FullName
        if ($item.PSIsContainer) { $entries.Add('D ' + $relative) }
        else { $entries.Add(('F {0} {1} {2}' -f $relative, [long]$item.Length, (Get-PshUninstallSafetyHash -Path $item.FullName))) }
    }
    return [string]::Join("`n", $entries.ToArray())
}

function New-PshUninstallSafetyPackage {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Version)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    Write-PshUninstallSafetyText -Path (Join-Path $Root 'install-offline.ps1') -Text "# offline test entrypoint`n"
    Write-PshUninstallSafetyText -Path (Join-Path $Root 'uninstall.ps1') -Text "# uninstall test entrypoint`n"
    Write-PshUninstallSafetyText -Path (Join-Path $Root 'install.sh') -Text "#!/bin/sh`n# offline test entrypoint`n"
    Write-PshUninstallSafetyText -Path (Join-Path $Root 'psh-installer.exe') -Text "MZ synthetic AnyCPU bootstrapper`n"

    $moduleRoot = Join-Path $Root 'payload/Psh'
    Write-PshUninstallSafetyText -Path (Join-Path $moduleRoot 'Psh.psd1') -Text @"
@{
    RootModule = 'Psh.psm1'
    ModuleVersion = '0.0.1'
    GUID = '11111111-2222-3333-4444-555555555555'
    FunctionsToExport = @()
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
"@
    Write-PshUninstallSafetyText -Path (Join-Path $moduleRoot 'Psh.psm1') -Text "# synthetic $Version`n"

    $payloadInstall = Join-Path $Root 'payload/install'
    [IO.Directory]::CreateDirectory($payloadInstall) | Out-Null
    foreach ($name in @('bootstrap.ps1', 'config.psd1', 'Set-PshCurrentVersion.ps1')) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot ('src/install/' + $name)) -Destination (Join-Path $payloadInstall $name)
    }
    $payloadProfile = Join-Path $Root 'payload/profile'
    [IO.Directory]::CreateDirectory($payloadProfile) | Out-Null
    foreach ($name in @('ProfileBlock.ps1', 'Install-PshProfile.ps1', 'Uninstall-PshProfile.ps1', 'PSReadLineProjection.ps1', 'Install-PshPSReadLineProjection.ps1', 'Uninstall-PshPSReadLineProjection.ps1')) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot ('src/profile/' + $name)) -Destination (Join-Path $payloadProfile $name)
    }
    $projectionSource = Join-Path $Root 'payload/Psh/Dependencies/PSReadLine'
    [IO.Directory]::CreateDirectory($projectionSource) | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh/Dependencies/PSReadLine/2.4.5') -Destination $projectionSource -Recurse
    # The rollback-safety fixture records an installer invocation only when the
    # test supplies PSH_UNINSTALL_TEST_INSTALLER_MARKER; normal fixture setup is
    # therefore unaffected.
    $profileInstallerPath = Join-Path $payloadProfile 'Install-PshProfile.ps1'
    $profileInstallerText = [IO.File]::ReadAllText($profileInstallerPath, $script:Utf8)
    $profileInstallerHook = @'
if (-not [string]::IsNullOrWhiteSpace($env:PSH_UNINSTALL_TEST_INSTALLER_MARKER)) {
    [IO.File]::AppendAllText($env:PSH_UNINSTALL_TEST_INSTALLER_MARKER, "profile-installer`n", (New-Object System.Text.UTF8Encoding($false)))
}
'@
    $profileInstallerText = $profileInstallerText.Replace("`$ErrorActionPreference = 'Stop'", "`$ErrorActionPreference = 'Stop'`n$profileInstallerHook")
    [IO.File]::WriteAllText($profileInstallerPath, $profileInstallerText, $script:Utf8)

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)) {
        if ($file.Name -ceq 'package.manifest.json' -and [string]::Equals($file.DirectoryName, [IO.Path]::GetFullPath($Root), [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = Get-PshUninstallSafetyRelativePath -Root $Root -Path $file.FullName
        $role = if ($relative -ceq 'psh-installer.exe') { 'bootstrapper' } elseif ($relative -in @('install-offline.ps1', 'uninstall.ps1', 'install.sh')) { 'entrypoint' } else { 'payload' }
        $files.Add([pscustomobject][ordered]@{ relativePath = $relative; length = [long]$file.Length; sha256 = Get-PshUninstallSafetyHash -Path $file.FullName; role = $role })
    }
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        version = $Version
        edition = 'Core'
        architecture = 'any'
        payloadRoot = 'payload'
        files = $files.ToArray()
        treeSha256 = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $files.ToArray() })
        entrypoints = [pscustomobject][ordered]@{ offlinePowerShell = 'install-offline.ps1'; uninstallPowerShell = 'uninstall.ps1'; shell = 'install.sh'; bootstrapper = 'psh-installer.exe' }
        testOnly = $true
        source = [pscustomobject][ordered]@{ repository = 'https://github.com/Emvdy/psh'; commit = ('1' * 40) }
        bootstrapper = [pscustomobject][ordered]@{ relativePath = 'psh-installer.exe'; sha256 = Get-PshUninstallSafetyHash -Path (Join-Path $Root 'psh-installer.exe'); anyCpu = $true }
        nativeToolsLockSha256 = $null
    }
    [IO.File]::WriteAllText((Join-Path $Root 'package.manifest.json'), (($manifest | ConvertTo-Json -Depth 20) + "`n"), $script:Utf8)
    return $Root
}

function Install-PshUninstallSafetyFixture {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string[]] $ProfilePath,
        [AllowEmptyCollection()][string[]] $ModuleRoot = @()
    )
    $result = @(& $installScript -PackageRoot $PackageRoot -InstallRoot $InstallRoot -ProfilePath @($ProfilePath) -ModuleRoot @($ModuleRoot) -Offline -Confirm:$false)
    if ($result.Count -eq 0 -or -not [bool]$result[-1].success) { throw "Fixture installation failed: $InstallRoot" }
    return $result[-1]
}

function Invoke-PshUninstallSafetyFailure {
    param([Parameter(Mandatory = $true)][scriptblock] $Action)
    try { & $Action | Out-Null }
    catch { return $_ }
    throw 'Expected uninstall to throw.'
}

function Start-PshUninstallSafetyProcess {
    param(
        [Parameter(Mandatory = $true)][string] $DriverPath,
        [Parameter(Mandatory = $true)][string] $ConfigPath,
        [Parameter(Mandatory = $true)][string] $StandardOutputPath,
        [Parameter(Mandatory = $true)][string] $StandardErrorPath
    )
    $executable = (Get-Process -Id $PID -ErrorAction Stop).Path
    $escapedDriver = $DriverPath.Replace("'", "''")
    $escapedConfig = $ConfigPath.Replace("'", "''")
    $command = "& '$escapedDriver' -ConfigPath '$escapedConfig'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return Start-Process -FilePath $executable -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) -RedirectStandardOutput $StandardOutputPath -RedirectStandardError $StandardErrorPath -PassThru
}

function Invoke-PshUninstallSafetyInjected {
    param(
        [AllowNull()][string] $Point,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string[]] $ProfilePath,
        [AllowEmptyCollection()][string[]] $ModuleRoot = @(),
        [AllowNull()][string] $MetadataRestoreFailure,
        [AllowNull()][string] $RollbackCleanupFailure,
        [AllowNull()][string] $UnknownQuarantine,
        [AllowNull()][string] $CasReplacementPath,
        [AllowNull()][string] $InstallerMarker,
        [AllowNull()][string] $ChildFailure,
        [AllowNull()][string] $QuarantineTamper,
        [AllowNull()][string] $QuarantineTamperName,
        [AllowNull()][string] $ProfileManifestReplacement,
        [AllowNull()][string] $ProfileTargetReplacement,
        [AllowNull()][string] $PostChildManifestReplacement,
        [AllowNull()][string] $PostChildTargetReplacement,
        [AllowNull()][string] $PartialChildFailure,
        [AllowNull()][string] $PreChildBackupReplacement,
        [AllowNull()][string] $PreLockProfileAddTarget,
        [AllowNull()][string] $ProfileRestorePostWriteFailure,
        [AllowNull()][string] $PostChildProjectionManifestReplacement,
        [AllowNull()][string] $PostChildProjectionTargetReplacement,
        [AllowNull()][string] $PostChildProjectionStateRootFile,
        [AllowNull()][string] $ProjectionPrecommitManifestReplacement,
        [AllowNull()][string] $ProjectionPrecommitTargetReplacement,
        [AllowNull()][string] $ProjectionPrecommitStateRootFile,
        [AllowNull()][string] $ProfileStateRootFileFailure,
        [AllowNull()][string] $PostChildProfileStateRootReparseTarget,
        [AllowNull()][string] $PostChildProjectionStateRootReparseTarget,
        [AllowNull()][string] $ProjectionRestorePostWriteFailure,
        [AllowNull()][string] $ProjectionRestoreParentConflict,
        [AllowNull()][string] $ProjectionRestorePrecommitFailure,
        [AllowNull()][string] $PostChildProjectionEmptyStateRoot
    )
    $before = $env:PSH_UNINSTALL_TEST_FAILURE_POINT
    $beforeMetadata = $env:PSH_UNINSTALL_TEST_METADATA_RESTORE_FAILURE
    $beforeRollbackCleanup = $env:PSH_UNINSTALL_TEST_ROLLBACK_CLEANUP_FAILURE
    $beforeUnknown = $env:PSH_UNINSTALL_TEST_UNKNOWN_QUARANTINE
    $beforeCas = $env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH
    $beforeMarker = $env:PSH_UNINSTALL_TEST_INSTALLER_MARKER
    $beforeChildFailure = $env:PSH_UNINSTALL_TEST_CHILD_FAILURE
    $beforeTamper = $env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE
    $beforeTamperName = $env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME
    $beforeManifestReplacement = $env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT
    $beforeTargetReplacement = $env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT
    $beforePostChildReplacement = $env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT
    $beforePostChildTargetReplacement = $env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT
    $beforePartialChildFailure = $env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE
    $beforePreChildBackupReplacement = $env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT
    $beforePreLockProfileAddTarget = $env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET
    $beforeProfileRestorePostWriteFailure = $env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE
    $beforePostChildProjectionManifestReplacement = $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT
    $beforePostChildProjectionTargetReplacement = $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT
    $beforePostChildProjectionStateRootFile = $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE
    $beforeProjectionPrecommitManifestReplacement = $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT
    $beforeProjectionPrecommitTargetReplacement = $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT
    $beforeProjectionPrecommitStateRootFile = $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE
    $beforeProfileStateRootFileFailure = $env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE
    $beforePostChildProfileStateRootReparseTarget = $env:PSH_UNINSTALL_TEST_POST_CHILD_PROFILE_STATE_ROOT_REPARSE_TARGET
    $beforePostChildProjectionStateRootReparseTarget = $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_REPARSE_TARGET
    $beforeProjectionRestorePostWriteFailure = $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE
    $beforeProjectionRestoreParentConflict = $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT
    $beforeProjectionRestorePrecommitFailure = $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE
    $beforePostChildProjectionEmptyStateRoot = $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT
    try {
        if ($null -eq $Point) { Remove-Item Env:PSH_UNINSTALL_TEST_FAILURE_POINT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_FAILURE_POINT = $Point }
        if ($null -eq $MetadataRestoreFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_METADATA_RESTORE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_METADATA_RESTORE_FAILURE = $MetadataRestoreFailure }
        if ($null -eq $RollbackCleanupFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_ROLLBACK_CLEANUP_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_ROLLBACK_CLEANUP_FAILURE = $RollbackCleanupFailure }
        if ($null -eq $UnknownQuarantine) { Remove-Item Env:PSH_UNINSTALL_TEST_UNKNOWN_QUARANTINE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_UNKNOWN_QUARANTINE = $UnknownQuarantine }
        if ($null -eq $CasReplacementPath) { Remove-Item Env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH = $CasReplacementPath }
        if ($null -eq $InstallerMarker) { Remove-Item Env:PSH_UNINSTALL_TEST_INSTALLER_MARKER -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_INSTALLER_MARKER = $InstallerMarker }
        if ($null -eq $ChildFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_CHILD_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_CHILD_FAILURE = $ChildFailure }
        if ($null -eq $QuarantineTamper) { Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE = $QuarantineTamper }
        if ($null -eq $QuarantineTamperName) { Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME = $QuarantineTamperName }
        if ($null -eq $ProfileManifestReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT = $ProfileManifestReplacement }
        if ($null -eq $ProfileTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT = $ProfileTargetReplacement }
        if ($null -eq $PostChildManifestReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT = $PostChildManifestReplacement }
        if ($null -eq $PostChildTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT = $PostChildTargetReplacement }
        if ($null -eq $PartialChildFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE = $PartialChildFailure }
        if ($null -eq $PreChildBackupReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT = $PreChildBackupReplacement }
        if ($null -eq $PreLockProfileAddTarget) { Remove-Item Env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET = $PreLockProfileAddTarget }
        if ($null -eq $ProfileRestorePostWriteFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE = $ProfileRestorePostWriteFailure }
        if ($null -eq $PostChildProjectionManifestReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT = $PostChildProjectionManifestReplacement }
        if ($null -eq $PostChildProjectionTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT = $PostChildProjectionTargetReplacement }
        if ($null -eq $PostChildProjectionStateRootFile) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE = $PostChildProjectionStateRootFile }
        if ($null -eq $ProjectionPrecommitManifestReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT = $ProjectionPrecommitManifestReplacement }
        if ($null -eq $ProjectionPrecommitTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT = $ProjectionPrecommitTargetReplacement }
        if ($null -eq $ProjectionPrecommitStateRootFile) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE = $ProjectionPrecommitStateRootFile }
        if ($null -eq $ProfileStateRootFileFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE = $ProfileStateRootFileFailure }
        if ($null -eq $PostChildProfileStateRootReparseTarget) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROFILE_STATE_ROOT_REPARSE_TARGET -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROFILE_STATE_ROOT_REPARSE_TARGET = $PostChildProfileStateRootReparseTarget }
        if ($null -eq $PostChildProjectionStateRootReparseTarget) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_REPARSE_TARGET -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_REPARSE_TARGET = $PostChildProjectionStateRootReparseTarget }
        if ($null -eq $ProjectionRestorePostWriteFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE = $ProjectionRestorePostWriteFailure }
        if ($null -eq $ProjectionRestoreParentConflict) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT = $ProjectionRestoreParentConflict }
        if ($null -eq $ProjectionRestorePrecommitFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE = $ProjectionRestorePrecommitFailure }
        if ($null -eq $PostChildProjectionEmptyStateRoot) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT = $PostChildProjectionEmptyStateRoot }
        $output = @(& $uninstallScript -InstallRoot $InstallRoot -ProfilePath @($ProfilePath) -ModuleRoot @($ModuleRoot) -Confirm:$false)
        return $output[-1]
    }
    finally {
        if ($null -eq $before) { Remove-Item Env:PSH_UNINSTALL_TEST_FAILURE_POINT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_FAILURE_POINT = $before }
        if ($null -eq $beforeMetadata) { Remove-Item Env:PSH_UNINSTALL_TEST_METADATA_RESTORE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_METADATA_RESTORE_FAILURE = $beforeMetadata }
        if ($null -eq $beforeRollbackCleanup) { Remove-Item Env:PSH_UNINSTALL_TEST_ROLLBACK_CLEANUP_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_ROLLBACK_CLEANUP_FAILURE = $beforeRollbackCleanup }
        if ($null -eq $beforeUnknown) { Remove-Item Env:PSH_UNINSTALL_TEST_UNKNOWN_QUARANTINE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_UNKNOWN_QUARANTINE = $beforeUnknown }
        if ($null -eq $beforeCas) { Remove-Item Env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH = $beforeCas }
        if ($null -eq $beforeMarker) { Remove-Item Env:PSH_UNINSTALL_TEST_INSTALLER_MARKER -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_INSTALLER_MARKER = $beforeMarker }
        if ($null -eq $beforeChildFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_CHILD_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_CHILD_FAILURE = $beforeChildFailure }
        if ($null -eq $beforeTamper) { Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE = $beforeTamper }
        if ($null -eq $beforeTamperName) { Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME = $beforeTamperName }
        if ($null -eq $beforeManifestReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT = $beforeManifestReplacement }
        if ($null -eq $beforeTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT = $beforeTargetReplacement }
        if ($null -eq $beforePostChildReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT = $beforePostChildReplacement }
        if ($null -eq $beforePostChildTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT = $beforePostChildTargetReplacement }
        if ($null -eq $beforePartialChildFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE = $beforePartialChildFailure }
        if ($null -eq $beforePreChildBackupReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT = $beforePreChildBackupReplacement }
        if ($null -eq $beforePreLockProfileAddTarget) { Remove-Item Env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET = $beforePreLockProfileAddTarget }
        if ($null -eq $beforeProfileRestorePostWriteFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE = $beforeProfileRestorePostWriteFailure }
        if ($null -eq $beforePostChildProjectionManifestReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT = $beforePostChildProjectionManifestReplacement }
        if ($null -eq $beforePostChildProjectionTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT = $beforePostChildProjectionTargetReplacement }
        if ($null -eq $beforePostChildProjectionStateRootFile) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE = $beforePostChildProjectionStateRootFile }
        if ($null -eq $beforeProjectionPrecommitManifestReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT = $beforeProjectionPrecommitManifestReplacement }
        if ($null -eq $beforeProjectionPrecommitTargetReplacement) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT = $beforeProjectionPrecommitTargetReplacement }
        if ($null -eq $beforeProjectionPrecommitStateRootFile) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE = $beforeProjectionPrecommitStateRootFile }
        if ($null -eq $beforeProfileStateRootFileFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE = $beforeProfileStateRootFileFailure }
        if ($null -eq $beforePostChildProfileStateRootReparseTarget) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROFILE_STATE_ROOT_REPARSE_TARGET -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROFILE_STATE_ROOT_REPARSE_TARGET = $beforePostChildProfileStateRootReparseTarget }
        if ($null -eq $beforePostChildProjectionStateRootReparseTarget) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_REPARSE_TARGET -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_REPARSE_TARGET = $beforePostChildProjectionStateRootReparseTarget }
        if ($null -eq $beforeProjectionRestorePostWriteFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE = $beforeProjectionRestorePostWriteFailure }
        if ($null -eq $beforeProjectionRestoreParentConflict) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT = $beforeProjectionRestoreParentConflict }
        if ($null -eq $beforeProjectionRestorePrecommitFailure) { Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE = $beforeProjectionRestorePrecommitFailure }
        if ($null -eq $beforePostChildProjectionEmptyStateRoot) { Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT -ErrorAction SilentlyContinue }
        else { $env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT = $beforePostChildProjectionEmptyStateRoot }
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal5-uninstall-safety-' + [Guid]::NewGuid().ToString('N'))
$version = '0.0.1-test'

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $packageRoot = New-PshUninstallSafetyPackage -Root (Join-Path $testRoot 'package') -Version $version

    $gateRoot = Join-Path $testRoot 'gate/Psh'
    $gateProfile = Join-Path $testRoot 'gate/profile.ps1'
    $gateOriginal = "# gate profile`r`n`$global:GateValue = 1`r`n"
    Write-PshUninstallSafetyText -Path $gateProfile -Text $gateOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $gateRoot -ProfilePath $gateProfile
    [byte[]]$gateOwnership = [IO.File]::ReadAllBytes((Join-Path $gateRoot 'ownership.json'))
    [byte[]]$gateProfileInstalled = [IO.File]::ReadAllBytes($gateProfile)
    $currentPath = Join-Path $gateRoot 'current.json'
    [IO.File]::WriteAllText($currentPath, "{`n  `"schemaVersion`": 1,`n  `"version`": `"$version`"`n}`n", $script:Utf8)
    $canonicalFailure = Invoke-PshUninstallSafetyFailure { & $uninstallScript -InstallRoot $gateRoot -ProfilePath @($gateProfile) -ModuleRoot @() -Confirm:$false }
    $canonicalStateUnchanged = Test-PshUninstallSafetyBytesEqual $gateOwnership ([IO.File]::ReadAllBytes((Join-Path $gateRoot 'ownership.json')))
    $canonicalProfileUnchanged = Test-PshUninstallSafetyBytesEqual $gateProfileInstalled ([IO.File]::ReadAllBytes($gateProfile))
    Assert-PshUninstallSafety ([int]$canonicalFailure.Exception.Data['PshExitCode'] -eq 5 -and $canonicalStateUnchanged -and $canonicalProfileUnchanged) 'Valid but non-canonical current.json was not rejected before mutation.'
    [IO.File]::WriteAllText($currentPath, "{`"schemaVersion`":1,`"version`":`"$version`"}" + [Environment]::NewLine, $script:Utf8)

    $helperPath = Join-Path $gateRoot "versions/$version/profile/Uninstall-PshProfile.ps1"
    [byte[]]$helperBytes = [IO.File]::ReadAllBytes($helperPath)
    [IO.File]::AppendAllText($helperPath, "# helper tamper`n", $script:Utf8)
    $helperFailure = Invoke-PshUninstallSafetyFailure { & $uninstallScript -InstallRoot $gateRoot -ProfilePath @($gateProfile) -ModuleRoot @() -Confirm:$false }
    Assert-PshUninstallSafety ([int]$helperFailure.Exception.Data['PshExitCode'] -eq 5 -and (Test-PshUninstallSafetyBytesEqual $gateProfileInstalled ([IO.File]::ReadAllBytes($gateProfile))) -and -not [IO.File]::Exists((Join-Path $gateRoot 'transaction.json'))) 'Tampered active helper/tree was not rejected before script execution.'
    [IO.File]::WriteAllBytes($helperPath, $helperBytes)

    foreach ($point in @('AfterContentMove', 'BeforeOwnershipRemoval')) {
        [byte[]]$currentBefore = [IO.File]::ReadAllBytes($currentPath)
        [byte[]]$ownershipBefore = [IO.File]::ReadAllBytes((Join-Path $gateRoot 'ownership.json'))
        [byte[]]$profileBefore = [IO.File]::ReadAllBytes($gateProfile)
        $injected = Invoke-PshUninstallSafetyInjected -Point $point -InstallRoot $gateRoot -ProfilePath $gateProfile
        Assert-PshUninstallSafety (-not [bool]$injected.success -and [int]$injected.code -eq 3 -and [bool]$injected.rollbackRestored -and -not [bool]$injected.recoveryRequired) ("Injected {0} failure did not report a complete rollback: {1}" -f $point, (($injected | ConvertTo-Json -Depth 8 -Compress)))
        $currentRestored = Test-PshUninstallSafetyBytesEqual $currentBefore ([IO.File]::ReadAllBytes($currentPath))
        $ownershipRestored = Test-PshUninstallSafetyBytesEqual $ownershipBefore ([IO.File]::ReadAllBytes((Join-Path $gateRoot 'ownership.json')))
        $profileRestored = Test-PshUninstallSafetyBytesEqual $profileBefore ([IO.File]::ReadAllBytes($gateProfile))
        Assert-PshUninstallSafety ($currentRestored -and $ownershipRestored -and $profileRestored -and -not [IO.File]::Exists((Join-Path $gateRoot 'transaction.json'))) "Injected $point failure did not restore exact live bytes."
    }
    [byte[]]$childFailureCurrent = [IO.File]::ReadAllBytes($currentPath)
    [byte[]]$childFailureOwnership = [IO.File]::ReadAllBytes((Join-Path $gateRoot 'ownership.json'))
    [byte[]]$childFailureProfile = [IO.File]::ReadAllBytes($gateProfile)
    $childFailureResult = Invoke-PshUninstallSafetyInjected -InstallRoot $gateRoot -ProfilePath $gateProfile -ChildFailure 'profile'
    Assert-PshUninstallSafety (-not [bool]$childFailureResult.success -and [int]$childFailureResult.code -eq 3 -and [bool]$childFailureResult.rollbackRestored -and -not [bool]$childFailureResult.recoveryRequired) 'Mutation-before profile child failure was misclassified or not fully rolled back.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $childFailureCurrent ([IO.File]::ReadAllBytes($currentPath))) -and (Test-PshUninstallSafetyBytesEqual $childFailureOwnership ([IO.File]::ReadAllBytes((Join-Path $gateRoot 'ownership.json'))) ) -and (Test-PshUninstallSafetyBytesEqual $childFailureProfile ([IO.File]::ReadAllBytes($gateProfile))) -and -not [IO.File]::Exists((Join-Path $gateRoot 'transaction.json'))) 'Pre-state profile child failure invoked installer compensation or changed exact live bytes.'
    $gateSuccess = @(& $uninstallScript -InstallRoot $gateRoot -ProfilePath @($gateProfile) -ModuleRoot @() -Confirm:$false)[-1]
    Assert-PshUninstallSafety ([bool]$gateSuccess.success -and [IO.File]::ReadAllText($gateProfile, $script:Utf8) -ceq $gateOriginal -and -not [IO.File]::Exists((Join-Path $gateRoot 'ownership.json'))) 'Successful uninstall did not restore exact original profile bytes.'

    $cleanupRoot = Join-Path $testRoot 'cleanup/Psh'
    $cleanupProfile = Join-Path $testRoot 'cleanup/profile.ps1'
    $cleanupOriginal = "# cleanup profile`n"
    Write-PshUninstallSafetyText -Path $cleanupProfile -Text $cleanupOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $cleanupRoot -ProfilePath $cleanupProfile
    $cleanupPending = Invoke-PshUninstallSafetyInjected -Point 'BeforeQuarantineCleanup' -InstallRoot $cleanupRoot -ProfilePath $cleanupProfile
    Assert-PshUninstallSafety (-not [bool]$cleanupPending.success -and [string]$cleanupPending.status -ceq 'committedCleanupPending' -and [bool]$cleanupPending.metadataCommitted -and [IO.Directory]::Exists([string]$cleanupPending.quarantinePath)) 'Post-commit cleanup failure did not retain structured recovery evidence.'
    Assert-PshUninstallSafety (-not [IO.File]::Exists((Join-Path $cleanupRoot 'current.json')) -and -not [IO.File]::Exists((Join-Path $cleanupRoot 'ownership.json')) -and -not [IO.File]::Exists((Join-Path $cleanupRoot 'transaction.json')) -and [IO.File]::ReadAllText($cleanupProfile, $script:Utf8) -ceq $cleanupOriginal) 'Post-commit cleanup failure incorrectly rolled back metadata or profile removal.'

    $successJournalRoot = Join-Path $testRoot 'success-journal/Psh'
    $successJournalProfile = Join-Path $testRoot 'success-journal/profile.ps1'
    Write-PshUninstallSafetyText -Path $successJournalProfile -Text "# success journal profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $successJournalRoot -ProfilePath $successJournalProfile
    $successJournalPending = Invoke-PshUninstallSafetyInjected -Point 'BeforeTransactionMarkerRemoval' -InstallRoot $successJournalRoot -ProfilePath $successJournalProfile
    Assert-PshUninstallSafety (-not [bool]$successJournalPending.success -and [string]$successJournalPending.status -ceq 'committedCleanupPending' -and [string]::IsNullOrEmpty([string]$successJournalPending.quarantinePath) -and [IO.File]::Exists((Join-Path $successJournalRoot 'transaction.json'))) 'Committed cleanup did not retain the live transaction marker until after quarantine deletion.'
    Assert-PshUninstallSafety (-not [IO.File]::Exists((Join-Path $successJournalRoot 'current.json')) -and -not [IO.File]::Exists((Join-Path $successJournalRoot 'ownership.json')) -and -not [IO.Directory]::Exists((Join-Path $successJournalRoot "versions/$version"))) 'Transaction-marker-last injection occurred before owned content and metadata cleanup completed.'

    $rollbackJournalRoot = Join-Path $testRoot 'rollback-journal/Psh'
    $rollbackJournalProfile = Join-Path $testRoot 'rollback-journal/profile.ps1'
    Write-PshUninstallSafetyText -Path $rollbackJournalProfile -Text "# rollback journal profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $rollbackJournalRoot -ProfilePath $rollbackJournalProfile
    $rollbackJournalPending = Invoke-PshUninstallSafetyInjected -Point 'AfterContentMove' -InstallRoot $rollbackJournalRoot -ProfilePath $rollbackJournalProfile -RollbackCleanupFailure 'BeforeQuarantineDelete'
    Assert-PshUninstallSafety (-not [bool]$rollbackJournalPending.success -and [bool]$rollbackJournalPending.recoveryRequired -and -not [bool]$rollbackJournalPending.rollbackRestored -and [IO.File]::Exists((Join-Path $rollbackJournalRoot 'transaction.json'))) 'Rollback cleanup failure removed the transaction journal before quarantine cleanup completed.'
    Assert-PshUninstallSafety (-not [string]::IsNullOrWhiteSpace([string]$rollbackJournalPending.quarantinePath) -and [IO.Directory]::Exists([string]$rollbackJournalPending.quarantinePath) -and @(Get-ChildItem -LiteralPath ([string]$rollbackJournalPending.quarantinePath) -Force).Count -eq 0) 'Rollback cleanup failure did not retain its empty quarantine directory as recovery evidence.'

    $unknownCleanupRoot = Join-Path $testRoot 'unknown-cleanup/Psh'
    $unknownCleanupProfile = Join-Path $testRoot 'unknown-cleanup/profile.ps1'
    Write-PshUninstallSafetyText -Path $unknownCleanupProfile -Text "# unknown cleanup profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $unknownCleanupRoot -ProfilePath $unknownCleanupProfile
    $unknownCleanupPending = Invoke-PshUninstallSafetyInjected -InstallRoot $unknownCleanupRoot -ProfilePath $unknownCleanupProfile -UnknownQuarantine '1'
    $unknownCleanupEvidence = Join-Path ([string]$unknownCleanupPending.quarantinePath) 'unknown-test-content.bin'
    Assert-PshUninstallSafety (-not [bool]$unknownCleanupPending.success -and [int]$unknownCleanupPending.code -eq 5 -and [string]$unknownCleanupPending.status -ceq 'committedCleanupPending' -and [IO.File]::Exists($unknownCleanupEvidence)) 'Unknown quarantine content was deleted instead of being retained as integrity evidence.'
    Assert-PshUninstallSafety ([IO.File]::Exists((Join-Path ([string]$unknownCleanupPending.quarantinePath) 'metadata-transaction.json')) -and -not [IO.File]::Exists((Join-Path $unknownCleanupRoot 'transaction.json'))) 'Unknown-content cleanup failure lost its quarantined transaction evidence.'

    $metadataFailureRoot = Join-Path $testRoot 'metadata-failure/Psh'
    $metadataFailureProfile = Join-Path $testRoot 'metadata-failure/profile.ps1'
    $metadataFailureOriginal = "# metadata failure profile`n"
    $metadataInstallerMarker = Join-Path $testRoot 'metadata-failure/profile-installer.marker'
    Write-PshUninstallSafetyText -Path $metadataFailureProfile -Text $metadataFailureOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $metadataFailureRoot -ProfilePath $metadataFailureProfile
    $metadataFailureResult = Invoke-PshUninstallSafetyInjected -InstallRoot $metadataFailureRoot -ProfilePath $metadataFailureProfile -MetadataRestoreFailure '1' -InstallerMarker $metadataInstallerMarker
    $metadataSkipIssue = @($metadataFailureResult.issues | Where-Object { [string]$_ -like '*component and content compensation were skipped*' }).Count -eq 1
    Assert-PshUninstallSafety (-not [bool]$metadataFailureResult.success -and [int]$metadataFailureResult.code -eq 5 -and [bool]$metadataFailureResult.recoveryRequired -and -not [bool]$metadataFailureResult.rollbackRestored -and $metadataSkipIssue) 'Metadata restore failure was not reported as a fail-closed integrity recovery state.'
    Assert-PshUninstallSafety (-not [IO.File]::Exists($metadataInstallerMarker) -and [IO.File]::ReadAllText($metadataFailureProfile, $script:Utf8) -ceq $metadataFailureOriginal -and -not [IO.Directory]::Exists((Join-Path $metadataFailureRoot "versions/$version"))) 'Metadata restore failure invoked component or content compensation after the metadata gate failed.'
    Assert-PshUninstallSafety ([IO.Directory]::Exists([string]$metadataFailureResult.quarantinePath) -and [IO.File]::Exists((Join-Path $metadataFailureRoot 'transaction.json')) -and [IO.File]::Exists((Join-Path ([string]$metadataFailureResult.quarantinePath) 'metadata-current.json'))) 'Metadata restore failure did not retain both journal and quarantine recovery evidence.'

    $tamperRoot = Join-Path $testRoot 'tamper-child/Psh'
    $tamperProfile = Join-Path $testRoot 'tamper-child/profile.ps1'
    $tamperOriginal = "# tamper child profile`n"
    Write-PshUninstallSafetyText -Path $tamperProfile -Text $tamperOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $tamperRoot -ProfilePath $tamperProfile
    $tamperResult = Invoke-PshUninstallSafetyInjected -InstallRoot $tamperRoot -ProfilePath $tamperProfile -ChildFailure 'profile' -QuarantineTamper '1' -QuarantineTamperName 'Psh.psm1'
    $tamperedQuarantineFiles = @(Get-ChildItem -LiteralPath ([string]$tamperResult.quarantinePath) -Recurse -Force -File -Filter 'Psh.psm1' | Where-Object { [IO.File]::ReadAllText($_.FullName, $script:Utf8) -like '*quarantine tamper*' })
    Assert-PshUninstallSafety (-not [bool]$tamperResult.success -and [int]$tamperResult.code -eq 5 -and [bool]$tamperResult.recoveryRequired -and -not [bool]$tamperResult.rollbackRestored) 'Tampered quarantine content during child failure was not classified as integrity recovery.'
    Assert-PshUninstallSafety ($tamperedQuarantineFiles.Count -gt 0 -and [IO.Directory]::Exists([string]$tamperResult.quarantinePath) -and [IO.File]::Exists((Join-Path $tamperRoot 'transaction.json')) -and -not [IO.Directory]::Exists((Join-Path $tamperRoot "versions/$version"))) 'Tampered quarantine content was blindly restored into the live version tree or its recovery evidence was lost.'

    $postChildConflictRoot = Join-Path $testRoot 'post-child-manifest-conflict/Psh'
    $postChildConflictProfile = Join-Path $testRoot 'post-child-manifest-conflict/profile.ps1'
    $postChildConflictOriginal = "# post child manifest conflict profile`n"
    $postChildConflictMarker = Join-Path $testRoot 'post-child-manifest-conflict/profile-installer.marker'
    $postChildConflictBytes = $script:Utf8.GetBytes('{"schemaVersion":1,"product":"Psh","profiles":[]}' + "`n")
    Write-PshUninstallSafetyText -Path $postChildConflictProfile -Text $postChildConflictOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $postChildConflictRoot -ProfilePath $postChildConflictProfile
    $postChildConflictResult = Invoke-PshUninstallSafetyInjected -InstallRoot $postChildConflictRoot -ProfilePath $postChildConflictProfile -InstallerMarker $postChildConflictMarker -PostChildManifestReplacement '1'
    $postChildConflictPath = Join-Path $postChildConflictRoot 'profile-state/manifest.json'
    Assert-PshUninstallSafety (-not [bool]$postChildConflictResult.success -and [int]$postChildConflictResult.code -eq 5 -and [bool]$postChildConflictResult.recoveryRequired -and -not [bool]$postChildConflictResult.rollbackRestored) 'Post-child pre-verification manifest replacement was not classified as integrity recovery.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $postChildConflictBytes ([IO.File]::ReadAllBytes($postChildConflictPath))) -and -not [IO.File]::Exists($postChildConflictMarker) -and [IO.File]::ReadAllText($postChildConflictProfile, $script:Utf8) -ceq $postChildConflictOriginal) 'Post-child pre-verification manifest replacement was moved, deleted, or overwritten by rollback.'
    Assert-PshUninstallSafety ([IO.File]::Exists((Join-Path $postChildConflictRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$postChildConflictResult.quarantinePath)) 'Post-child manifest replacement did not retain journal and quarantine recovery evidence.'

    $postTargetConflictRoot = Join-Path $testRoot 'post-child-target-conflict/Psh'
    $postTargetConflictProfile = Join-Path $testRoot 'post-child-target-conflict/profile.ps1'
    $postTargetConflictMarker = Join-Path $testRoot 'post-child-target-conflict/profile-installer.marker'
    $postTargetConflictBytes = $script:Utf8.GetBytes("post-child concurrent target`n")
    Write-PshUninstallSafetyText -Path $postTargetConflictProfile -Text "# post child target conflict profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $postTargetConflictRoot -ProfilePath $postTargetConflictProfile
    $postTargetConflictResult = Invoke-PshUninstallSafetyInjected -InstallRoot $postTargetConflictRoot -ProfilePath $postTargetConflictProfile -InstallerMarker $postTargetConflictMarker -PostChildTargetReplacement '1'
    Assert-PshUninstallSafety (-not [bool]$postTargetConflictResult.success -and [int]$postTargetConflictResult.code -eq 5 -and [bool]$postTargetConflictResult.recoveryRequired -and -not [bool]$postTargetConflictResult.rollbackRestored) 'Post-child pre-verification profile target replacement was not classified as integrity recovery.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $postTargetConflictBytes ([IO.File]::ReadAllBytes($postTargetConflictProfile))) -and -not [IO.File]::Exists($postTargetConflictMarker) -and [IO.File]::Exists((Join-Path $postTargetConflictRoot 'transaction.json'))) 'Post-child profile target replacement was learned as expected state or overwritten by installer rollback.'

    $partialChildRoot = Join-Path $testRoot 'partial-child/Psh'
    $partialChildProfile = Join-Path $testRoot 'partial-child/profile.ps1'
    $partialChildMarker = Join-Path $testRoot 'partial-child/profile-installer.marker'
    $partialChildBytes = $script:Utf8.GetBytes("partial child mutation`n")
    Write-PshUninstallSafetyText -Path $partialChildProfile -Text "# partial child profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $partialChildRoot -ProfilePath $partialChildProfile
    $partialChildResult = Invoke-PshUninstallSafetyInjected -InstallRoot $partialChildRoot -ProfilePath $partialChildProfile -InstallerMarker $partialChildMarker -PartialChildFailure 'profile'
    Assert-PshUninstallSafety (-not [bool]$partialChildResult.success -and [int]$partialChildResult.code -eq 5 -and [bool]$partialChildResult.recoveryRequired -and -not [bool]$partialChildResult.rollbackRestored) 'Partial profile child failure with a pre-state manifest was incorrectly reported as a complete rollback.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $partialChildBytes ([IO.File]::ReadAllBytes($partialChildProfile))) -and -not [IO.File]::Exists($partialChildMarker) -and [IO.File]::Exists((Join-Path $partialChildRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$partialChildResult.quarantinePath)) 'Partial profile child bytes were overwritten or recovery evidence was removed.'

    $backupConflictRoot = Join-Path $testRoot 'pre-child-backup-conflict/Psh'
    $backupConflictProfile = Join-Path $testRoot 'pre-child-backup-conflict/profile.ps1'
    Write-PshUninstallSafetyText -Path $backupConflictProfile -Text "# pre child backup conflict profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $backupConflictRoot -ProfilePath $backupConflictProfile
    $backupConflictManifest = ([IO.File]::ReadAllText((Join-Path $backupConflictRoot 'profile-state/manifest.json'), $script:Utf8) | ConvertFrom-Json)
    $backupConflictPath = Join-Path $backupConflictRoot ('profile-state/backups/' + [string]$backupConflictManifest.profiles[0].backupFileName)
    $backupConflictBytes = $script:Utf8.GetBytes("concurrent backup replacement`n")
    $backupConflictResult = Invoke-PshUninstallSafetyInjected -InstallRoot $backupConflictRoot -ProfilePath $backupConflictProfile -ChildFailure 'profile' -PreChildBackupReplacement '1'
    Assert-PshUninstallSafety (-not [bool]$backupConflictResult.success -and [int]$backupConflictResult.code -eq 5 -and -not [bool]$backupConflictResult.rollbackRestored -and [bool]$backupConflictResult.recoveryRequired) 'A pre-child backup replacement was not classified as an exact-state integrity conflict.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $backupConflictBytes ([IO.File]::ReadAllBytes($backupConflictPath))) -and [IO.File]::Exists((Join-Path $backupConflictRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$backupConflictResult.quarantinePath)) 'Profile rollback overwrote a concurrent backup replacement or removed its recovery evidence.'

    $subsetRoot = Join-Path $testRoot 'profile-subset/Psh'
    $subsetProfileA = Join-Path $testRoot 'profile-subset/profile-a.ps1'
    $subsetProfileB = Join-Path $testRoot 'profile-subset/profile-b.ps1'
    Write-PshUninstallSafetyText -Path $subsetProfileA -Text "# profile subset a`n"
    Write-PshUninstallSafetyText -Path $subsetProfileB -Text "# profile subset b`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $subsetRoot -ProfilePath @($subsetProfileA, $subsetProfileB)
    $subsetProfileABytes = [IO.File]::ReadAllBytes($subsetProfileA)
    $subsetProfileBBytes = [IO.File]::ReadAllBytes($subsetProfileB)
    $subsetProfileState = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $subsetRoot 'profile-state')
    $subsetCurrentBytes = [IO.File]::ReadAllBytes((Join-Path $subsetRoot 'current.json'))
    $subsetOwnershipBytes = [IO.File]::ReadAllBytes((Join-Path $subsetRoot 'ownership.json'))
    $subsetVersionTree = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $subsetRoot "versions/$version")
    $subsetFailure = Invoke-PshUninstallSafetyFailure -Action { & $uninstallScript -InstallRoot $subsetRoot -ProfilePath @($subsetProfileA) -ModuleRoot @() -Confirm:$false }
    $subsetQuarantine = Join-Path $subsetRoot '.lifecycle/quarantine'
    $subsetQuarantineCount = if ([IO.Directory]::Exists($subsetQuarantine)) { @(Get-ChildItem -LiteralPath $subsetQuarantine -Force).Count } else { 0 }
    Assert-PshUninstallSafety ([int]$subsetFailure.Exception.Data['PshExitCode'] -eq 5 -and -not [IO.File]::Exists((Join-Path $subsetRoot 'transaction.json')) -and $subsetQuarantineCount -eq 0) 'A profile target subset was not rejected before transaction or quarantine mutation.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $subsetProfileABytes ([IO.File]::ReadAllBytes($subsetProfileA))) -and (Test-PshUninstallSafetyBytesEqual $subsetProfileBBytes ([IO.File]::ReadAllBytes($subsetProfileB))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $subsetRoot 'profile-state')) -ceq $subsetProfileState) 'Profile subset rejection changed a target, manifest, or backup.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $subsetCurrentBytes ([IO.File]::ReadAllBytes((Join-Path $subsetRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $subsetOwnershipBytes ([IO.File]::ReadAllBytes((Join-Path $subsetRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $subsetRoot "versions/$version")) -ceq $subsetVersionTree) 'Profile subset rejection changed lifecycle metadata or the active version tree.'

    $extraRoot = Join-Path $testRoot 'profile-safe-superset/Psh'
    $extraProfileA = Join-Path $testRoot 'profile-safe-superset/profile-a.ps1'
    $extraProfileB = Join-Path $testRoot 'profile-safe-superset/profile-b.ps1'
    $extraOriginalA = "# profile safe superset a`n"
    $extraOriginalB = "# profile safe superset b`n"
    $extraInstallerMarker = Join-Path $testRoot 'profile-safe-superset/profile-installer.marker'
    Write-PshUninstallSafetyText -Path $extraProfileA -Text $extraOriginalA
    Write-PshUninstallSafetyText -Path $extraProfileB -Text $extraOriginalB
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $extraRoot -ProfilePath @($extraProfileA, $extraProfileB)
    $null = @(& $profileUninstallScript -ProfilePath @($extraProfileA) -StateRoot (Join-Path $extraRoot 'profile-state') -Confirm:$false)
    $extraProfileABytes = [IO.File]::ReadAllBytes($extraProfileA)
    $extraProfileBBytes = [IO.File]::ReadAllBytes($extraProfileB)
    $extraProfileState = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $extraRoot 'profile-state')
    $extraCurrentBytes = [IO.File]::ReadAllBytes((Join-Path $extraRoot 'current.json'))
    $extraOwnershipBytes = [IO.File]::ReadAllBytes((Join-Path $extraRoot 'ownership.json'))
    $extraVersionTree = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $extraRoot "versions/$version")
    $extraResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $extraRoot -ProfilePath @($extraProfileA, $extraProfileB) -InstallerMarker $extraInstallerMarker
    Assert-PshUninstallSafety (-not [bool]$extraResult.success -and [int]$extraResult.code -eq 3 -and [bool]$extraResult.rollbackRestored -and -not [bool]$extraResult.recoveryRequired) 'A safe profile target superset did not complete an exact parent rollback.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $extraProfileABytes ([IO.File]::ReadAllBytes($extraProfileA))) -and (Test-PshUninstallSafetyBytesEqual $extraProfileBBytes ([IO.File]::ReadAllBytes($extraProfileB))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $extraRoot 'profile-state')) -ceq $extraProfileState -and -not [IO.File]::Exists($extraInstallerMarker)) 'Exact rollback reinstalled a block into an independently uninstalled extra target or changed trusted profile state.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $extraCurrentBytes ([IO.File]::ReadAllBytes((Join-Path $extraRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $extraOwnershipBytes ([IO.File]::ReadAllBytes((Join-Path $extraRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $extraRoot "versions/$version")) -ceq $extraVersionTree -and -not [IO.File]::Exists((Join-Path $extraRoot 'transaction.json'))) 'Safe-superset rollback did not restore package metadata and content exactly.'

    $absentBlockRoot = Join-Path $testRoot 'profile-block-already-absent/Psh'
    $absentBlockProfile = Join-Path $testRoot 'profile-block-already-absent/profile.ps1'
    $absentBlockOriginal = "# profile block already absent`n"
    $absentBlockMarker = Join-Path $testRoot 'profile-block-already-absent/profile-installer.marker'
    Write-PshUninstallSafetyText -Path $absentBlockProfile -Text $absentBlockOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $absentBlockRoot -ProfilePath $absentBlockProfile
    Write-PshUninstallSafetyText -Path $absentBlockProfile -Text $absentBlockOriginal
    $absentBlockProfileBytes = [IO.File]::ReadAllBytes($absentBlockProfile)
    $absentBlockState = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $absentBlockRoot 'profile-state')
    $absentBlockCurrent = [IO.File]::ReadAllBytes((Join-Path $absentBlockRoot 'current.json'))
    $absentBlockOwnership = [IO.File]::ReadAllBytes((Join-Path $absentBlockRoot 'ownership.json'))
    $absentBlockVersion = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $absentBlockRoot "versions/$version")
    $absentBlockResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $absentBlockRoot -ProfilePath $absentBlockProfile -InstallerMarker $absentBlockMarker
    Assert-PshUninstallSafety (-not [bool]$absentBlockResult.success -and [int]$absentBlockResult.code -eq 3 -and [bool]$absentBlockResult.rollbackRestored -and -not [bool]$absentBlockResult.recoveryRequired) 'A BlockAlreadyAbsent child state did not roll back exactly.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $absentBlockProfileBytes ([IO.File]::ReadAllBytes($absentBlockProfile))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $absentBlockRoot 'profile-state')) -ceq $absentBlockState -and -not [IO.File]::Exists($absentBlockMarker)) 'Exact rollback inserted a new loader block into a profile that lacked one before the child transaction.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $absentBlockCurrent ([IO.File]::ReadAllBytes((Join-Path $absentBlockRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $absentBlockOwnership ([IO.File]::ReadAllBytes((Join-Path $absentBlockRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $absentBlockRoot "versions/$version")) -ceq $absentBlockVersion -and -not [IO.File]::Exists((Join-Path $absentBlockRoot 'transaction.json'))) 'BlockAlreadyAbsent rollback did not restore lifecycle metadata and package content exactly.'

    $preLockRoot = Join-Path $testRoot 'profile-pre-lock-addition/Psh'
    $preLockProfile = Join-Path $testRoot 'profile-pre-lock-addition/profile.ps1'
    $preLockAddedProfile = Join-Path $testRoot 'profile-pre-lock-addition/concurrent-profile.ps1'
    Write-PshUninstallSafetyText -Path $preLockProfile -Text "# profile pre-lock primary`n"
    Write-PshUninstallSafetyText -Path $preLockAddedProfile -Text "# profile pre-lock concurrent`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $preLockRoot -ProfilePath $preLockProfile
    $preLockPrimaryBytes = [IO.File]::ReadAllBytes($preLockProfile)
    $preLockCurrent = [IO.File]::ReadAllBytes((Join-Path $preLockRoot 'current.json'))
    $preLockOwnership = [IO.File]::ReadAllBytes((Join-Path $preLockRoot 'ownership.json'))
    $preLockVersion = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $preLockRoot "versions/$version")
    $preLockFailure = Invoke-PshUninstallSafetyFailure -Action { Invoke-PshUninstallSafetyInjected -InstallRoot $preLockRoot -ProfilePath $preLockProfile -PreLockProfileAddTarget $preLockAddedProfile }
    $preLockManifest = ([IO.File]::ReadAllText((Join-Path $preLockRoot 'profile-state/manifest.json'), $script:Utf8) | ConvertFrom-Json)
    $preLockQuarantine = Join-Path $preLockRoot '.lifecycle/quarantine'
    $preLockQuarantineCount = if ([IO.Directory]::Exists($preLockQuarantine)) { @(Get-ChildItem -LiteralPath $preLockQuarantine -Force).Count } else { 0 }
    Assert-PshUninstallSafety ([int]$preLockFailure.Exception.Data['PshExitCode'] -eq 5 -and -not [IO.File]::Exists((Join-Path $preLockRoot 'transaction.json')) -and $preLockQuarantineCount -eq 0) 'A profile added between initial preflight and lock acquisition was not rejected before transaction mutation.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $preLockPrimaryBytes ([IO.File]::ReadAllBytes($preLockProfile))) -and @($preLockManifest.profiles).Count -eq 2 -and [IO.File]::ReadAllText($preLockAddedProfile, $script:Utf8) -like '*# >>> Psh managed profile >>>*') 'Locked re-preflight overwrote or discarded the concurrent valid profile addition.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $preLockCurrent ([IO.File]::ReadAllBytes((Join-Path $preLockRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $preLockOwnership ([IO.File]::ReadAllBytes((Join-Path $preLockRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $preLockRoot "versions/$version")) -ceq $preLockVersion) 'Pre-lock profile addition rejection changed lifecycle metadata or version content.'

    $midRestoreRoot = Join-Path $testRoot 'profile-mid-restore/Psh'
    $midRestoreProfile = Join-Path $testRoot 'profile-mid-restore/profile.ps1'
    $midRestoreOriginal = "# profile mid restore`n"
    Write-PshUninstallSafetyText -Path $midRestoreProfile -Text $midRestoreOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $midRestoreRoot -ProfilePath $midRestoreProfile
    $midRestoreManifestDocument = ([IO.File]::ReadAllText((Join-Path $midRestoreRoot 'profile-state/manifest.json'), $script:Utf8) | ConvertFrom-Json)
    $midRestoreBackupPath = Join-Path $midRestoreRoot ('profile-state/backups/' + [string]$midRestoreManifestDocument.profiles[0].backupFileName)
    $midRestoreEmptyManifestBytes = $script:Utf8.GetBytes((([ordered]@{ schemaVersion = 1; product = 'Psh'; profiles = @() }) | ConvertTo-Json -Depth 5) + "`r`n")
    $midRestoreResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $midRestoreRoot -ProfilePath $midRestoreProfile -ProfileRestorePostWriteFailure 'profile target'
    Assert-PshUninstallSafety (-not [bool]$midRestoreResult.success -and [int]$midRestoreResult.code -eq 5 -and -not [bool]$midRestoreResult.rollbackRestored -and [bool]$midRestoreResult.recoveryRequired) 'A post-write profile observation failure was not classified as an integrity recovery state.'
    $midRestorePostManifestPath = Join-Path $midRestoreRoot 'profile-state/manifest.json'
    $midRestorePostManifest = ([IO.File]::ReadAllText($midRestorePostManifestPath, $script:Utf8) | ConvertFrom-Json)
    Assert-PshUninstallSafety ([IO.File]::ReadAllText($midRestoreProfile, $script:Utf8) -ceq $midRestoreOriginal -and (Test-PshUninstallSafetyBytesEqual $midRestoreEmptyManifestBytes ([IO.File]::ReadAllBytes($midRestorePostManifestPath))) -and @($midRestorePostManifest.profiles).Count -eq 0 -and -not [IO.File]::Exists($midRestoreBackupPath)) 'Profile currentPair compensation left a mixed Pre/Post component state after post-write failure.'
    Assert-PshUninstallSafety ([IO.File]::Exists((Join-Path $midRestoreRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$midRestoreResult.quarantinePath) -and [IO.File]::Exists((Join-Path $midRestoreRoot 'current.json')) -and [IO.File]::Exists((Join-Path $midRestoreRoot 'ownership.json'))) 'Mid-profile-restore failure did not retain package and recovery evidence.'

    $idempotentRoot = Join-Path $testRoot 'profile-idempotent-success/Psh'
    $idempotentProfileA = Join-Path $testRoot 'profile-idempotent-success/profile-a.ps1'
    $idempotentProfileB = Join-Path $testRoot 'profile-idempotent-success/profile-b.ps1'
    $idempotentOriginalA = "# profile idempotent a`n"
    $idempotentOriginalB = "# profile idempotent b`n"
    $idempotentMarker = Join-Path $testRoot 'profile-idempotent-success/profile-installer.marker'
    Write-PshUninstallSafetyText -Path $idempotentProfileA -Text $idempotentOriginalA
    Write-PshUninstallSafetyText -Path $idempotentProfileB -Text $idempotentOriginalB
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $idempotentRoot -ProfilePath @($idempotentProfileA, $idempotentProfileB)
    $null = @(& $profileUninstallScript -ProfilePath @($idempotentProfileA) -StateRoot (Join-Path $idempotentRoot 'profile-state') -Confirm:$false)
    $idempotentResult = Invoke-PshUninstallSafetyInjected -InstallRoot $idempotentRoot -ProfilePath @($idempotentProfileA, $idempotentProfileB) -InstallerMarker $idempotentMarker
    Assert-PshUninstallSafety ([bool]$idempotentResult.success -and [int]$idempotentResult.code -eq 0 -and -not [bool]$idempotentResult.recoveryRequired) 'Top-level uninstall did not accept a normal idempotent profile target superset.'
    Assert-PshUninstallSafety ([IO.File]::ReadAllText($idempotentProfileA, $script:Utf8) -ceq $idempotentOriginalA -and [IO.File]::ReadAllText($idempotentProfileB, $script:Utf8) -ceq $idempotentOriginalB -and -not [IO.File]::Exists($idempotentMarker)) 'Idempotent top-level success reinserted or retained a profile loader block.'
    Assert-PshUninstallSafety (-not [IO.File]::Exists((Join-Path $idempotentRoot 'current.json')) -and -not [IO.File]::Exists((Join-Path $idempotentRoot 'ownership.json')) -and -not [IO.Directory]::Exists((Join-Path $idempotentRoot "versions/$version")) -and -not [IO.File]::Exists((Join-Path $idempotentRoot 'transaction.json'))) 'Idempotent profile success did not complete package cleanup.'

    $editedMarkerRoot = Join-Path $testRoot 'profile-edited-marker/Psh'
    $editedMarkerProfile = Join-Path $testRoot 'profile-edited-marker/profile.ps1'
    $editedMarkerStateRoot = Join-Path $editedMarkerRoot 'profile-state'
    $editedMarkerInstallerMarker = Join-Path $testRoot 'profile-edited-marker/profile-installer.marker'
    Write-PshUninstallSafetyText -Path $editedMarkerProfile -Text "# profile edited marker`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $editedMarkerRoot -ProfilePath $editedMarkerProfile
    [IO.File]::AppendAllText($editedMarkerProfile, "# user edit after installed block`n", $script:Utf8)
    $editedMarkerBytes = [IO.File]::ReadAllBytes($editedMarkerProfile)
    $editedMarkerState = Get-PshUninstallSafetyTreeSnapshot -Root $editedMarkerStateRoot
    $editedMarkerResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $editedMarkerRoot -ProfilePath $editedMarkerProfile -InstallerMarker $editedMarkerInstallerMarker
    Assert-PshUninstallSafety (-not [bool]$editedMarkerResult.success -and [int]$editedMarkerResult.code -eq 3 -and [bool]$editedMarkerResult.rollbackRestored -and -not [bool]$editedMarkerResult.recoveryRequired) 'A user-edited marker-present profile did not roll back exactly.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $editedMarkerBytes ([IO.File]::ReadAllBytes($editedMarkerProfile))) -and (Get-PshUninstallSafetyTreeSnapshot -Root $editedMarkerStateRoot) -ceq $editedMarkerState -and -not [IO.File]::Exists($editedMarkerInstallerMarker)) 'Exact rollback changed user-edited marker-present profile bytes or invoked the broad installer.'

    $profileRootFileRoot = Join-Path $testRoot 'profile-state-root-file/Psh'
    $profileRootFileProfile = Join-Path $testRoot 'profile-state-root-file/profile.ps1'
    $profileRootFileBytes = $script:Utf8.GetBytes("concurrent profile state-root file`n")
    Write-PshUninstallSafetyText -Path $profileRootFileProfile -Text "# profile state root file`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $profileRootFileRoot -ProfilePath $profileRootFileProfile
    $profileRootFileResult = Invoke-PshUninstallSafetyInjected -InstallRoot $profileRootFileRoot -ProfilePath $profileRootFileProfile -ProfileStateRootFileFailure '1'
    $profileRootFilePath = Join-Path $profileRootFileRoot 'profile-state'
    Assert-PshUninstallSafety (-not [bool]$profileRootFileResult.success -and [int]$profileRootFileResult.code -eq 5 -and -not [bool]$profileRootFileResult.rollbackRestored -and [bool]$profileRootFileResult.recoveryRequired) 'A profile state root replaced by a file was misclassified as exact Pre or Post.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $profileRootFileBytes ([IO.File]::ReadAllBytes($profileRootFilePath))) -and [IO.Directory]::Exists($profileRootFilePath + '.concurrent-evidence') -and [IO.File]::Exists((Join-Path $profileRootFileRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$profileRootFileResult.quarantinePath)) 'Profile state-root file bytes or displaced trusted state evidence were overwritten or removed.'

    $profileReparseRoot = Join-Path $testRoot 'profile-state-root-reparse/Psh'
    $profileReparseProfile = Join-Path $testRoot 'profile-state-root-reparse/profile.ps1'
    $profileReparseExternalRoot = Join-Path $testRoot 'profile-state-root-reparse/external-state'
    $profileReparseExternalManifest = Join-Path $profileReparseExternalRoot 'manifest.json'
    $profileReparseExternalSentinel = Join-Path $profileReparseExternalRoot 'sentinel.bin'
    $profileReparseExpectedPostRoot = Join-Path $testRoot 'profile-state-root-reparse/expected-post-state'
    $profileReparseExternalManifestBytes = $script:Utf8.GetBytes((([ordered]@{ schemaVersion = 1; product = 'Psh'; profiles = @() }) | ConvertTo-Json -Depth 5) + "`r`n")
    $profileReparseExternalSentinelBytes = $script:Utf8.GetBytes("external profile sentinel`n")
    Write-PshUninstallSafetyText -Path $profileReparseProfile -Text "# profile state root reparse`n"
    [IO.Directory]::CreateDirectory($profileReparseExternalRoot) | Out-Null
    [IO.File]::WriteAllBytes($profileReparseExternalManifest, $profileReparseExternalManifestBytes)
    [IO.File]::WriteAllBytes($profileReparseExternalSentinel, $profileReparseExternalSentinelBytes)
    [IO.Directory]::CreateDirectory((Join-Path $profileReparseExpectedPostRoot 'backups')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $profileReparseExpectedPostRoot 'manifest.json'), $profileReparseExternalManifestBytes)
    $profileReparseExpectedPostTree = Get-PshUninstallSafetyTreeSnapshot -Root $profileReparseExpectedPostRoot
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $profileReparseRoot -ProfilePath $profileReparseProfile
    $profileReparseCurrent = [IO.File]::ReadAllBytes((Join-Path $profileReparseRoot 'current.json'))
    $profileReparseOwnership = [IO.File]::ReadAllBytes((Join-Path $profileReparseRoot 'ownership.json'))
    $profileReparseVersion = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $profileReparseRoot "versions/$version")
    $profileReparseResult = Invoke-PshUninstallSafetyInjected -InstallRoot $profileReparseRoot -ProfilePath $profileReparseProfile -PostChildProfileStateRootReparseTarget $profileReparseExternalRoot
    $profileReparseStateRoot = Join-Path $profileReparseRoot 'profile-state'
    $profileReparseAttributes = [IO.File]::GetAttributes($profileReparseStateRoot)
    Assert-PshUninstallSafety (-not [bool]$profileReparseResult.success -and [int]$profileReparseResult.code -eq 5 -and -not [bool]$profileReparseResult.rollbackRestored -and [bool]$profileReparseResult.recoveryRequired -and ($profileReparseAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'A profile state-root reparse point was not rejected as an integrity recovery state.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $profileReparseExternalManifestBytes ([IO.File]::ReadAllBytes($profileReparseExternalManifest))) -and (Test-PshUninstallSafetyBytesEqual $profileReparseExternalSentinelBytes ([IO.File]::ReadAllBytes($profileReparseExternalSentinel)))) 'Profile state-root observation or rollback read through and changed external manifest/sentinel bytes.'
    Assert-PshUninstallSafety ((Get-PshUninstallSafetyTreeSnapshot -Root ($profileReparseStateRoot + '.reparse-evidence')) -ceq $profileReparseExpectedPostTree -and (Test-PshUninstallSafetyBytesEqual $profileReparseCurrent ([IO.File]::ReadAllBytes((Join-Path $profileReparseRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $profileReparseOwnership ([IO.File]::ReadAllBytes((Join-Path $profileReparseRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $profileReparseRoot "versions/$version")) -ceq $profileReparseVersion -and [IO.File]::Exists((Join-Path $profileReparseRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$profileReparseResult.quarantinePath)) 'Profile reparse rejection changed displaced trusted state, committed lifecycle content, or lost recovery evidence.'

    $manifestConflictRoot = Join-Path $testRoot 'manifest-conflict/Psh'
    $manifestConflictProfile = Join-Path $testRoot 'manifest-conflict/profile.ps1'
    $manifestConflictOriginal = "# manifest conflict profile`n"
    $manifestConflictMarker = Join-Path $testRoot 'manifest-conflict/profile-installer.marker'
    $manifestConflictBytes = $script:Utf8.GetBytes('{"schemaVersion":1,"product":"Psh","profiles":[]}' + "`n")
    Write-PshUninstallSafetyText -Path $manifestConflictProfile -Text $manifestConflictOriginal
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $manifestConflictRoot -ProfilePath $manifestConflictProfile
    $manifestConflictResult = Invoke-PshUninstallSafetyInjected -InstallRoot $manifestConflictRoot -ProfilePath $manifestConflictProfile -InstallerMarker $manifestConflictMarker -ProfileManifestReplacement '1'
    $manifestConflictPath = Join-Path $manifestConflictRoot 'profile-state/manifest.json'
    Assert-PshUninstallSafety (-not [bool]$manifestConflictResult.success -and [int]$manifestConflictResult.code -eq 5 -and [bool]$manifestConflictResult.recoveryRequired -and -not [bool]$manifestConflictResult.rollbackRestored) 'Concurrent valid empty profile manifest replacement was not classified as an integrity recovery state.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $manifestConflictBytes ([IO.File]::ReadAllBytes($manifestConflictPath))) -and -not [IO.File]::Exists($manifestConflictMarker) -and [IO.File]::ReadAllText($manifestConflictProfile, $script:Utf8) -ceq $manifestConflictOriginal) 'Profile rollback moved, deleted, or overwrote a concurrent valid empty manifest byte image.'
    Assert-PshUninstallSafety ([IO.File]::Exists((Join-Path $manifestConflictRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$manifestConflictResult.quarantinePath)) 'Profile manifest conflict did not retain journal and quarantine recovery evidence.'

    $precommitTargetRoot = Join-Path $testRoot 'precommit-target-conflict/Psh'
    $precommitTargetProfile = Join-Path $testRoot 'precommit-target-conflict/profile.ps1'
    $precommitTargetMarker = Join-Path $testRoot 'precommit-target-conflict/profile-installer.marker'
    $precommitTargetBytes = $script:Utf8.GetBytes("precommit concurrent target`n")
    Write-PshUninstallSafetyText -Path $precommitTargetProfile -Text "# precommit target conflict profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $precommitTargetRoot -ProfilePath $precommitTargetProfile
    $precommitTargetResult = Invoke-PshUninstallSafetyInjected -InstallRoot $precommitTargetRoot -ProfilePath $precommitTargetProfile -InstallerMarker $precommitTargetMarker -ProfileTargetReplacement '1'
    Assert-PshUninstallSafety (-not [bool]$precommitTargetResult.success -and [int]$precommitTargetResult.code -eq 5 -and -not [bool]$precommitTargetResult.rollbackRestored -and [bool]$precommitTargetResult.recoveryRequired) 'A success-path precommit profile target replacement was not rejected as an integrity conflict.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $precommitTargetBytes ([IO.File]::ReadAllBytes($precommitTargetProfile))) -and -not [IO.File]::Exists($precommitTargetMarker) -and [IO.File]::Exists((Join-Path $precommitTargetRoot 'current.json')) -and [IO.File]::Exists((Join-Path $precommitTargetRoot 'ownership.json'))) 'Precommit profile target replacement was overwritten or package metadata was committed incorrectly.'
    Assert-PshUninstallSafety ([IO.File]::Exists((Join-Path $precommitTargetRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$precommitTargetResult.quarantinePath)) 'Precommit profile target conflict did not retain journal and quarantine evidence.'

    $projectionRollbackRoot = Join-Path $testRoot 'projection-real-upgrade-rollback/Psh'
    $projectionRollbackProfile = Join-Path $testRoot 'projection-real-upgrade-rollback/profile.ps1'
    $projectionRollbackModule = Join-Path $testRoot 'projection-real-upgrade-rollback/modules'
    $projectionRollbackUpgradeVersion = '0.0.2-test'
    $projectionRollbackUpgradePackage = New-PshUninstallSafetyPackage -Root (Join-Path $testRoot 'projection-real-upgrade-rollback/package-v2') -Version $projectionRollbackUpgradeVersion
    Write-PshUninstallSafetyText -Path $projectionRollbackProfile -Text "# projection real upgrade rollback profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionRollbackRoot -ProfilePath $projectionRollbackProfile -ModuleRoot $projectionRollbackModule
    $projectionRollbackStateRoot = Join-Path $projectionRollbackRoot 'psreadline-projection-state'
    $projectionRollbackManifestPath = Join-Path $projectionRollbackStateRoot 'manifest.json'
    $projectionRollbackV1Manifest = [IO.File]::ReadAllText($projectionRollbackManifestPath, $script:Utf8) | ConvertFrom-Json
    $projectionRollbackV1SourcePath = [IO.Path]::GetFullPath([string]$projectionRollbackV1Manifest.sourcePath)
    $null = Install-PshUninstallSafetyFixture -PackageRoot $projectionRollbackUpgradePackage -InstallRoot $projectionRollbackRoot -ProfilePath $projectionRollbackProfile -ModuleRoot $projectionRollbackModule
    $projectionRollbackManifest = [IO.File]::ReadAllText($projectionRollbackManifestPath, $script:Utf8) | ConvertFrom-Json
    $projectionRollbackCurrentDocument = [IO.File]::ReadAllText((Join-Path $projectionRollbackRoot 'current.json'), $script:Utf8) | ConvertFrom-Json
    $projectionRollbackActiveSource = Join-Path $projectionRollbackRoot "versions/$projectionRollbackUpgradeVersion/Psh/Dependencies/PSReadLine/2.4.5"
    Assert-PshUninstallSafety ([string]$projectionRollbackManifest.sourcePath -ceq $projectionRollbackV1SourcePath -and [string]$projectionRollbackCurrentDocument.version -ceq $projectionRollbackUpgradeVersion -and [IO.Directory]::Exists($projectionRollbackV1SourcePath) -and [IO.Directory]::Exists($projectionRollbackActiveSource)) ("A real v1-to-v2 upgrade did not retain a trusted non-active projection sourcePath. manifest={0}; v1={1}; current={2}; v1Exists={3}; v2Exists={4}" -f [string]$projectionRollbackManifest.sourcePath, $projectionRollbackV1SourcePath, [string]$projectionRollbackCurrentDocument.version, [IO.Directory]::Exists($projectionRollbackV1SourcePath), [IO.Directory]::Exists($projectionRollbackActiveSource))
    $projectionRollbackManifestBytes = [IO.File]::ReadAllBytes($projectionRollbackManifestPath)
    $projectionRollbackTarget = Join-Path $projectionRollbackModule 'PSReadLine/2.4.5'
    $projectionRollbackTargetTree = Get-PshUninstallSafetyTreeSnapshot -Root $projectionRollbackTarget
    $projectionRollbackCurrent = [IO.File]::ReadAllBytes((Join-Path $projectionRollbackRoot 'current.json'))
    $projectionRollbackOwnership = [IO.File]::ReadAllBytes((Join-Path $projectionRollbackRoot 'ownership.json'))
    $projectionRollbackV1SourceTree = Get-PshUninstallSafetyTreeSnapshot -Root $projectionRollbackV1SourcePath
    $projectionRollbackV2SourceTree = Get-PshUninstallSafetyTreeSnapshot -Root $projectionRollbackActiveSource
    $projectionRollbackResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $projectionRollbackRoot -ProfilePath $projectionRollbackProfile -ModuleRoot $projectionRollbackModule
    Assert-PshUninstallSafety (-not [bool]$projectionRollbackResult.success -and [int]$projectionRollbackResult.code -eq 3 -and [bool]$projectionRollbackResult.rollbackRestored -and -not [bool]$projectionRollbackResult.recoveryRequired) 'Projection exact rollback did not accept a real upgraded manifest with a retained non-active sourcePath.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionRollbackManifestBytes ([IO.File]::ReadAllBytes($projectionRollbackManifestPath))) -and (Get-PshUninstallSafetyTreeSnapshot -Root $projectionRollbackTarget) -ceq $projectionRollbackTargetTree) 'Projection exact rollback did not restore the upgraded manifest bytes and created target tree.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionRollbackCurrent ([IO.File]::ReadAllBytes((Join-Path $projectionRollbackRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $projectionRollbackOwnership ([IO.File]::ReadAllBytes((Join-Path $projectionRollbackRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root $projectionRollbackV1SourcePath) -ceq $projectionRollbackV1SourceTree -and (Get-PshUninstallSafetyTreeSnapshot -Root $projectionRollbackActiveSource) -ceq $projectionRollbackV2SourceTree -and -not [IO.File]::Exists((Join-Path $projectionRollbackRoot 'transaction.json'))) 'Projection exact rollback did not restore upgraded lifecycle metadata/content exactly.'

    $projectionChildFailureRoot = Join-Path $testRoot 'projection-child-failure/Psh'
    $projectionChildFailureProfile = Join-Path $testRoot 'projection-child-failure/profile.ps1'
    $projectionChildFailureModule = Join-Path $testRoot 'projection-child-failure/modules'
    Write-PshUninstallSafetyText -Path $projectionChildFailureProfile -Text "# projection child failure profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionChildFailureRoot -ProfilePath $projectionChildFailureProfile -ModuleRoot $projectionChildFailureModule
    $projectionChildFailureState = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionChildFailureRoot 'psreadline-projection-state')
    $projectionChildFailureTarget = Join-Path $projectionChildFailureModule 'PSReadLine/2.4.5'
    $projectionChildFailureTree = Get-PshUninstallSafetyTreeSnapshot -Root $projectionChildFailureTarget
    $projectionChildFailureResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionChildFailureRoot -ProfilePath $projectionChildFailureProfile -ModuleRoot $projectionChildFailureModule -ChildFailure 'projection'
    Assert-PshUninstallSafety (-not [bool]$projectionChildFailureResult.success -and [int]$projectionChildFailureResult.code -eq 3 -and [bool]$projectionChildFailureResult.rollbackRestored -and -not [bool]$projectionChildFailureResult.recoveryRequired) 'Projection child Pre state was not skipped during parent rollback.'
    Assert-PshUninstallSafety ((Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionChildFailureRoot 'psreadline-projection-state')) -ceq $projectionChildFailureState -and (Get-PshUninstallSafetyTreeSnapshot -Root $projectionChildFailureTarget) -ceq $projectionChildFailureTree -and -not [IO.File]::Exists((Join-Path $projectionChildFailureRoot 'transaction.json'))) 'Projection child Pre-skip rollback changed projection state or retained a completed journal.'

    $projectionPartialRoot = Join-Path $testRoot 'projection-partial-child/Psh'
    $projectionPartialProfile = Join-Path $testRoot 'projection-partial-child/profile.ps1'
    $projectionPartialModule = Join-Path $testRoot 'projection-partial-child/modules'
    Write-PshUninstallSafetyText -Path $projectionPartialProfile -Text "# projection partial child profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPartialRoot -ProfilePath $projectionPartialProfile -ModuleRoot $projectionPartialModule
    $projectionPartialManifestBytes = [IO.File]::ReadAllBytes((Join-Path $projectionPartialRoot 'psreadline-projection-state/manifest.json'))
    $projectionPartialTarget = Join-Path $projectionPartialModule 'PSReadLine/2.4.5'
    $projectionPartialTree = Get-PshUninstallSafetyTreeSnapshot -Root $projectionPartialTarget
    $projectionPartialResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionPartialRoot -ProfilePath $projectionPartialProfile -ModuleRoot $projectionPartialModule -PartialChildFailure 'projection'
    $projectionPartialEvidence = $projectionPartialTarget + '.partial-test'
    Assert-PshUninstallSafety (-not [bool]$projectionPartialResult.success -and [int]$projectionPartialResult.code -eq 5 -and -not [bool]$projectionPartialResult.rollbackRestored -and [bool]$projectionPartialResult.recoveryRequired) 'A partial projection target move was not classified as Other/integrity recovery.'
    Assert-PshUninstallSafety (-not [IO.Directory]::Exists($projectionPartialTarget) -and (Get-PshUninstallSafetyTreeSnapshot -Root $projectionPartialEvidence) -ceq $projectionPartialTree -and (Test-PshUninstallSafetyBytesEqual $projectionPartialManifestBytes ([IO.File]::ReadAllBytes((Join-Path $projectionPartialRoot 'psreadline-projection-state/manifest.json')))) -and [IO.File]::Exists((Join-Path $projectionPartialRoot 'transaction.json'))) 'Partial projection evidence was overwritten, deleted, or mislearned as exact state.'

    $projectionPostManifestRoot = Join-Path $testRoot 'projection-post-manifest/Psh'
    $projectionPostManifestProfile = Join-Path $testRoot 'projection-post-manifest/profile.ps1'
    $projectionPostManifestModule = Join-Path $testRoot 'projection-post-manifest/modules'
    $projectionPostManifestBytes = $script:Utf8.GetBytes('{"concurrent":"projection-post-child"}' + "`n")
    Write-PshUninstallSafetyText -Path $projectionPostManifestProfile -Text "# projection post manifest profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPostManifestRoot -ProfilePath $projectionPostManifestProfile -ModuleRoot $projectionPostManifestModule
    $projectionPostManifestResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionPostManifestRoot -ProfilePath $projectionPostManifestProfile -ModuleRoot $projectionPostManifestModule -PostChildProjectionManifestReplacement '1'
    $projectionPostManifestPath = Join-Path $projectionPostManifestRoot 'psreadline-projection-state/manifest.json'
    Assert-PshUninstallSafety (-not [bool]$projectionPostManifestResult.success -and [int]$projectionPostManifestResult.code -eq 5 -and -not [bool]$projectionPostManifestResult.rollbackRestored -and [bool]$projectionPostManifestResult.recoveryRequired) 'Post-child projection manifest recreation was not rejected as an integrity conflict.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionPostManifestBytes ([IO.File]::ReadAllBytes($projectionPostManifestPath))) -and -not [IO.Directory]::Exists((Join-Path $projectionPostManifestModule 'PSReadLine/2.4.5')) -and [IO.File]::Exists((Join-Path $projectionPostManifestRoot 'transaction.json'))) 'Post-child projection manifest bytes were overwritten or the removed target was recreated blindly.'

    $projectionPostTargetRoot = Join-Path $testRoot 'projection-post-target/Psh'
    $projectionPostTargetProfile = Join-Path $testRoot 'projection-post-target/profile.ps1'
    $projectionPostTargetModule = Join-Path $testRoot 'projection-post-target/modules'
    Write-PshUninstallSafetyText -Path $projectionPostTargetProfile -Text "# projection post target profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPostTargetRoot -ProfilePath $projectionPostTargetProfile -ModuleRoot $projectionPostTargetModule
    $projectionPostTargetResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionPostTargetRoot -ProfilePath $projectionPostTargetProfile -ModuleRoot $projectionPostTargetModule -PostChildProjectionTargetReplacement '1'
    $projectionPostTargetEvidence = Join-Path $projectionPostTargetModule 'PSReadLine/2.4.5/concurrent.bin'
    Assert-PshUninstallSafety (-not [bool]$projectionPostTargetResult.success -and [int]$projectionPostTargetResult.code -eq 5 -and -not [bool]$projectionPostTargetResult.rollbackRestored -and [bool]$projectionPostTargetResult.recoveryRequired) 'Post-child projection target recreation was not rejected as an integrity conflict.'
    Assert-PshUninstallSafety ([IO.File]::ReadAllText($projectionPostTargetEvidence, $script:Utf8) -ceq "projection post-child concurrent target`n" -and -not [IO.File]::Exists((Join-Path $projectionPostTargetRoot 'psreadline-projection-state/manifest.json')) -and [IO.File]::Exists((Join-Path $projectionPostTargetRoot 'transaction.json'))) 'Post-child concurrent projection target bytes were overwritten or a manifest was recreated blindly.'

    $projectionPostRootFileRoot = Join-Path $testRoot 'projection-post-root-file/Psh'
    $projectionPostRootFileProfile = Join-Path $testRoot 'projection-post-root-file/profile.ps1'
    $projectionPostRootFileModule = Join-Path $testRoot 'projection-post-root-file/modules'
    $projectionPostRootFileBytes = $script:Utf8.GetBytes("projection post-child state-root file`n")
    Write-PshUninstallSafetyText -Path $projectionPostRootFileProfile -Text "# projection post root file profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPostRootFileRoot -ProfilePath $projectionPostRootFileProfile -ModuleRoot $projectionPostRootFileModule
    $projectionPostRootFileResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionPostRootFileRoot -ProfilePath $projectionPostRootFileProfile -ModuleRoot $projectionPostRootFileModule -PostChildProjectionStateRootFile '1'
    $projectionPostRootFilePath = Join-Path $projectionPostRootFileRoot 'psreadline-projection-state'
    Assert-PshUninstallSafety (-not [bool]$projectionPostRootFileResult.success -and [int]$projectionPostRootFileResult.code -eq 5 -and -not [bool]$projectionPostRootFileResult.rollbackRestored -and [bool]$projectionPostRootFileResult.recoveryRequired) 'Post-child projection state-root file replacement was misclassified as exact Post.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionPostRootFileBytes ([IO.File]::ReadAllBytes($projectionPostRootFilePath))) -and [IO.File]::Exists((Join-Path $projectionPostRootFileRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionPostRootFileResult.quarantinePath)) 'Post-child projection state-root file bytes or recovery evidence were removed.'

    $projectionReparseRoot = Join-Path $testRoot 'projection-state-root-reparse/Psh'
    $projectionReparseProfile = Join-Path $testRoot 'projection-state-root-reparse/profile.ps1'
    $projectionReparseModule = Join-Path $testRoot 'projection-state-root-reparse/modules'
    $projectionReparseExternalRoot = Join-Path $testRoot 'projection-state-root-reparse/external-state'
    $projectionReparseExternalSentinel = Join-Path $projectionReparseExternalRoot 'sentinel.bin'
    $projectionReparseExternalSentinelBytes = $script:Utf8.GetBytes("external projection sentinel`n")
    Write-PshUninstallSafetyText -Path $projectionReparseProfile -Text "# projection state root reparse`n"
    [IO.Directory]::CreateDirectory($projectionReparseExternalRoot) | Out-Null
    [IO.File]::WriteAllBytes($projectionReparseExternalSentinel, $projectionReparseExternalSentinelBytes)
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionReparseRoot -ProfilePath $projectionReparseProfile -ModuleRoot $projectionReparseModule
    $projectionReparseCurrent = [IO.File]::ReadAllBytes((Join-Path $projectionReparseRoot 'current.json'))
    $projectionReparseOwnership = [IO.File]::ReadAllBytes((Join-Path $projectionReparseRoot 'ownership.json'))
    $projectionReparseVersion = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionReparseRoot "versions/$version")
    $projectionReparseResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionReparseRoot -ProfilePath $projectionReparseProfile -ModuleRoot $projectionReparseModule -PostChildProjectionStateRootReparseTarget $projectionReparseExternalRoot
    $projectionReparseStateRoot = Join-Path $projectionReparseRoot 'psreadline-projection-state'
    $projectionReparseAttributes = [IO.File]::GetAttributes($projectionReparseStateRoot)
    Assert-PshUninstallSafety (-not [bool]$projectionReparseResult.success -and [int]$projectionReparseResult.code -eq 5 -and -not [bool]$projectionReparseResult.rollbackRestored -and [bool]$projectionReparseResult.recoveryRequired -and ($projectionReparseAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and [IO.File]::Exists((Join-Path $projectionReparseStateRoot 'sentinel.bin'))) 'A projection state-root reparse point was not rejected as an integrity recovery state or did not resolve to the external fixture.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionReparseExternalSentinelBytes ([IO.File]::ReadAllBytes($projectionReparseExternalSentinel))) -and -not [IO.File]::Exists((Join-Path $projectionReparseExternalRoot 'manifest.json'))) 'Projection state-root observation or rollback wrote through the reparse point into external state.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionReparseCurrent ([IO.File]::ReadAllBytes((Join-Path $projectionReparseRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $projectionReparseOwnership ([IO.File]::ReadAllBytes((Join-Path $projectionReparseRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionReparseRoot "versions/$version")) -ceq $projectionReparseVersion -and [IO.File]::Exists((Join-Path $projectionReparseRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionReparseResult.quarantinePath)) 'Projection reparse rejection committed lifecycle metadata/content or lost recovery evidence.'

    $projectionEmptyRoot = Join-Path $testRoot 'projection-empty-state-root/Psh'
    $projectionEmptyRootProfile = Join-Path $testRoot 'projection-empty-state-root/profile.ps1'
    $projectionEmptyRootModule = Join-Path $testRoot 'projection-empty-state-root/modules'
    Write-PshUninstallSafetyText -Path $projectionEmptyRootProfile -Text "# projection empty state root`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionEmptyRoot -ProfilePath $projectionEmptyRootProfile -ModuleRoot $projectionEmptyRootModule
    $projectionEmptyRootResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionEmptyRoot -ProfilePath $projectionEmptyRootProfile -ModuleRoot $projectionEmptyRootModule -PostChildProjectionEmptyStateRoot '1'
    $projectionEmptyStatePath = Join-Path $projectionEmptyRoot 'psreadline-projection-state'
    Assert-PshUninstallSafety (-not [bool]$projectionEmptyRootResult.success -and [int]$projectionEmptyRootResult.code -eq 5 -and -not [bool]$projectionEmptyRootResult.rollbackRestored -and [bool]$projectionEmptyRootResult.recoveryRequired) 'An empty recreated projection state root was misclassified as exact Post.'
    Assert-PshUninstallSafety ([IO.Directory]::Exists($projectionEmptyStatePath) -and @(Get-ChildItem -LiteralPath $projectionEmptyStatePath -Force).Count -eq 0 -and -not [IO.Directory]::Exists($projectionEmptyRootModule) -and [IO.File]::Exists((Join-Path $projectionEmptyRoot 'current.json')) -and [IO.File]::Exists((Join-Path $projectionEmptyRoot 'ownership.json')) -and [IO.File]::Exists((Join-Path $projectionEmptyRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionEmptyRootResult.quarantinePath)) 'Empty projection state-root conflict was occupied, removed, or committed as successful metadata.'

    $projectionPrecommitRootFileRoot = Join-Path $testRoot 'projection-precommit-root-file/Psh'
    $projectionPrecommitRootFileProfile = Join-Path $testRoot 'projection-precommit-root-file/profile.ps1'
    $projectionPrecommitRootFileModule = Join-Path $testRoot 'projection-precommit-root-file/modules'
    $projectionPrecommitRootFileBytes = $script:Utf8.GetBytes("projection precommit state-root file`n")
    Write-PshUninstallSafetyText -Path $projectionPrecommitRootFileProfile -Text "# projection precommit root file profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPrecommitRootFileRoot -ProfilePath $projectionPrecommitRootFileProfile -ModuleRoot $projectionPrecommitRootFileModule
    $projectionPrecommitRootFileResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionPrecommitRootFileRoot -ProfilePath $projectionPrecommitRootFileProfile -ModuleRoot $projectionPrecommitRootFileModule -ProjectionPrecommitStateRootFile '1'
    $projectionPrecommitRootFilePath = Join-Path $projectionPrecommitRootFileRoot 'psreadline-projection-state'
    Assert-PshUninstallSafety (-not [bool]$projectionPrecommitRootFileResult.success -and [int]$projectionPrecommitRootFileResult.code -eq 5 -and -not [bool]$projectionPrecommitRootFileResult.rollbackRestored -and [bool]$projectionPrecommitRootFileResult.recoveryRequired) 'Precommit projection state-root file replacement was not rejected before metadata commit.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionPrecommitRootFileBytes ([IO.File]::ReadAllBytes($projectionPrecommitRootFilePath))) -and [IO.File]::Exists((Join-Path $projectionPrecommitRootFileRoot 'current.json')) -and [IO.File]::Exists((Join-Path $projectionPrecommitRootFileRoot 'ownership.json')) -and [IO.File]::Exists((Join-Path $projectionPrecommitRootFileRoot 'transaction.json'))) 'Precommit projection state-root file bytes were overwritten or lifecycle metadata was committed.'

    $projectionPrecommitManifestRoot = Join-Path $testRoot 'projection-precommit-manifest/Psh'
    $projectionPrecommitManifestProfile = Join-Path $testRoot 'projection-precommit-manifest/profile.ps1'
    $projectionPrecommitManifestModule = Join-Path $testRoot 'projection-precommit-manifest/modules'
    $projectionPrecommitManifestBytes = $script:Utf8.GetBytes('{"concurrent":"projection-precommit"}' + "`n")
    Write-PshUninstallSafetyText -Path $projectionPrecommitManifestProfile -Text "# projection precommit manifest`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPrecommitManifestRoot -ProfilePath $projectionPrecommitManifestProfile -ModuleRoot $projectionPrecommitManifestModule
    $projectionPrecommitManifestResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionPrecommitManifestRoot -ProfilePath $projectionPrecommitManifestProfile -ModuleRoot $projectionPrecommitManifestModule -ProjectionPrecommitManifestReplacement '1'
    $projectionPrecommitManifestPath = Join-Path $projectionPrecommitManifestRoot 'psreadline-projection-state/manifest.json'
    Assert-PshUninstallSafety (-not [bool]$projectionPrecommitManifestResult.success -and [int]$projectionPrecommitManifestResult.code -eq 5 -and -not [bool]$projectionPrecommitManifestResult.rollbackRestored -and [bool]$projectionPrecommitManifestResult.recoveryRequired) 'A precommit projection manifest replacement was not rejected as an integrity recovery state.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionPrecommitManifestBytes ([IO.File]::ReadAllBytes($projectionPrecommitManifestPath))) -and -not [IO.Directory]::Exists($projectionPrecommitManifestModule) -and [IO.File]::Exists((Join-Path $projectionPrecommitManifestRoot 'current.json')) -and [IO.File]::Exists((Join-Path $projectionPrecommitManifestRoot 'ownership.json')) -and [IO.File]::Exists((Join-Path $projectionPrecommitManifestRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionPrecommitManifestResult.quarantinePath)) 'Precommit projection manifest bytes were overwritten or lifecycle metadata/evidence was lost.'

    $projectionPrecommitTargetRoot = Join-Path $testRoot 'projection-precommit-target/Psh'
    $projectionPrecommitTargetProfile = Join-Path $testRoot 'projection-precommit-target/profile.ps1'
    $projectionPrecommitTargetModule = Join-Path $testRoot 'projection-precommit-target/modules'
    $projectionPrecommitTargetBytes = $script:Utf8.GetBytes("projection precommit concurrent target`n")
    Write-PshUninstallSafetyText -Path $projectionPrecommitTargetProfile -Text "# projection precommit target`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPrecommitTargetRoot -ProfilePath $projectionPrecommitTargetProfile -ModuleRoot $projectionPrecommitTargetModule
    $projectionPrecommitTargetResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionPrecommitTargetRoot -ProfilePath $projectionPrecommitTargetProfile -ModuleRoot $projectionPrecommitTargetModule -ProjectionPrecommitTargetReplacement '1'
    $projectionPrecommitTargetEvidence = Join-Path $projectionPrecommitTargetModule 'PSReadLine/2.4.5/concurrent.bin'
    Assert-PshUninstallSafety (-not [bool]$projectionPrecommitTargetResult.success -and [int]$projectionPrecommitTargetResult.code -eq 5 -and -not [bool]$projectionPrecommitTargetResult.rollbackRestored -and [bool]$projectionPrecommitTargetResult.recoveryRequired) 'A precommit projection target replacement was not rejected as an integrity recovery state.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionPrecommitTargetBytes ([IO.File]::ReadAllBytes($projectionPrecommitTargetEvidence))) -and -not [IO.File]::Exists((Join-Path $projectionPrecommitTargetRoot 'psreadline-projection-state/manifest.json')) -and [IO.File]::Exists((Join-Path $projectionPrecommitTargetRoot 'current.json')) -and [IO.File]::Exists((Join-Path $projectionPrecommitTargetRoot 'ownership.json')) -and [IO.File]::Exists((Join-Path $projectionPrecommitTargetRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionPrecommitTargetResult.quarantinePath)) 'Precommit projection target bytes were overwritten or lifecycle metadata/evidence was lost.'

    $projectionPrecommitRestoreRoot = Join-Path $testRoot 'projection-restore-precommit-failure/Psh'
    $projectionPrecommitRestoreProfile = Join-Path $testRoot 'projection-restore-precommit-failure/profile.ps1'
    $projectionPrecommitRestoreModule = Join-Path $testRoot 'projection-restore-precommit-failure/modules'
    Write-PshUninstallSafetyText -Path $projectionPrecommitRestoreProfile -Text "# projection restore precommit failure`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionPrecommitRestoreRoot -ProfilePath $projectionPrecommitRestoreProfile -ModuleRoot $projectionPrecommitRestoreModule
    $projectionPrecommitRestoreResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $projectionPrecommitRestoreRoot -ProfilePath $projectionPrecommitRestoreProfile -ModuleRoot $projectionPrecommitRestoreModule -ProjectionRestorePrecommitFailure '1'
    $projectionPrecommitRestoreCompensated = @($projectionPrecommitRestoreResult.issues | Where-Object { [string]$_ -like '*compensated to exact Post*' }).Count -eq 1
    Assert-PshUninstallSafety (-not [bool]$projectionPrecommitRestoreResult.success -and [int]$projectionPrecommitRestoreResult.code -eq 5 -and -not [bool]$projectionPrecommitRestoreResult.rollbackRestored -and [bool]$projectionPrecommitRestoreResult.recoveryRequired -and $projectionPrecommitRestoreCompensated) 'A projection restore failure before target commit was not compensated to exact Post.'
    Assert-PshUninstallSafety (-not [IO.Directory]::Exists($projectionPrecommitRestoreModule) -and -not [IO.Directory]::Exists((Join-Path $projectionPrecommitRestoreRoot 'psreadline-projection-state')) -and [IO.File]::Exists((Join-Path $projectionPrecommitRestoreRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionPrecommitRestoreResult.quarantinePath)) 'Pre-target-commit projection restore failure leaked attempted parents/state root or lost evidence.'

    $projectionMidRestoreRoot = Join-Path $testRoot 'projection-mid-restore/Psh'
    $projectionMidRestoreProfile = Join-Path $testRoot 'projection-mid-restore/profile.ps1'
    $projectionMidRestoreModuleA = Join-Path $testRoot 'projection-mid-restore/modules-a'
    $projectionMidRestoreModuleB = Join-Path $testRoot 'projection-mid-restore/modules-b'
    Write-PshUninstallSafetyText -Path $projectionMidRestoreProfile -Text "# projection mid restore`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionMidRestoreRoot -ProfilePath $projectionMidRestoreProfile -ModuleRoot @($projectionMidRestoreModuleA, $projectionMidRestoreModuleB)
    $projectionMidRestoreCurrent = [IO.File]::ReadAllBytes((Join-Path $projectionMidRestoreRoot 'current.json'))
    $projectionMidRestoreOwnership = [IO.File]::ReadAllBytes((Join-Path $projectionMidRestoreRoot 'ownership.json'))
    $projectionMidRestoreVersion = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionMidRestoreRoot "versions/$version")
    $projectionMidRestoreResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $projectionMidRestoreRoot -ProfilePath $projectionMidRestoreProfile -ModuleRoot @($projectionMidRestoreModuleA, $projectionMidRestoreModuleB) -ProjectionRestorePostWriteFailure '2'
    $projectionMidRestoreCompensated = @($projectionMidRestoreResult.issues | Where-Object { [string]$_ -like '*compensated to exact Post*' }).Count -eq 1
    Assert-PshUninstallSafety (-not [bool]$projectionMidRestoreResult.success -and [int]$projectionMidRestoreResult.code -eq 5 -and -not [bool]$projectionMidRestoreResult.rollbackRestored -and [bool]$projectionMidRestoreResult.recoveryRequired -and $projectionMidRestoreCompensated) 'A second-target projection restore failure was not reported with exact Post compensation.'
    Assert-PshUninstallSafety (-not [IO.Directory]::Exists($projectionMidRestoreModuleA) -and -not [IO.Directory]::Exists($projectionMidRestoreModuleB) -and -not [IO.Directory]::Exists((Join-Path $projectionMidRestoreRoot 'psreadline-projection-state'))) 'Second-target projection restore compensation left a target, created parent, or state root.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionMidRestoreCurrent ([IO.File]::ReadAllBytes((Join-Path $projectionMidRestoreRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $projectionMidRestoreOwnership ([IO.File]::ReadAllBytes((Join-Path $projectionMidRestoreRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionMidRestoreRoot "versions/$version")) -ceq $projectionMidRestoreVersion -and [IO.File]::Exists((Join-Path $projectionMidRestoreRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionMidRestoreResult.quarantinePath)) 'Second-target projection restore failure changed package bytes or lost recovery evidence.'

    $projectionParentConflictRoot = Join-Path $testRoot 'projection-parent-conflict/Psh'
    $projectionParentConflictProfile = Join-Path $testRoot 'projection-parent-conflict/profile.ps1'
    $projectionParentConflictModule = Join-Path $testRoot 'projection-parent-conflict/modules'
    $projectionParentConflictBytes = $script:Utf8.GetBytes("projection concurrent parent content`n")
    Write-PshUninstallSafetyText -Path $projectionParentConflictProfile -Text "# projection parent conflict`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionParentConflictRoot -ProfilePath $projectionParentConflictProfile -ModuleRoot $projectionParentConflictModule
    $projectionParentConflictResult = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $projectionParentConflictRoot -ProfilePath $projectionParentConflictProfile -ModuleRoot $projectionParentConflictModule -ProjectionRestorePostWriteFailure '1' -ProjectionRestoreParentConflict '1'
    $projectionParentConflictPath = Join-Path $projectionParentConflictModule 'concurrent-parent.bin'
    Assert-PshUninstallSafety (-not [bool]$projectionParentConflictResult.success -and [int]$projectionParentConflictResult.code -eq 5 -and -not [bool]$projectionParentConflictResult.rollbackRestored -and [bool]$projectionParentConflictResult.recoveryRequired) 'Concurrent projection parent content was not reported as an integrity recovery conflict.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $projectionParentConflictBytes ([IO.File]::ReadAllBytes($projectionParentConflictPath))) -and -not [IO.Directory]::Exists((Join-Path $projectionParentConflictModule 'PSReadLine')) -and -not [IO.Directory]::Exists((Join-Path $projectionParentConflictRoot 'psreadline-projection-state')) -and [IO.File]::Exists((Join-Path $projectionParentConflictRoot 'transaction.json')) -and [IO.Directory]::Exists([string]$projectionParentConflictResult.quarantinePath)) 'Projection compensation deleted concurrent parent bytes or retained unrelated empty parents/state.'

    $projectionEmptyResidualRoot = Join-Path $testRoot 'projection-empty-residual-success/Psh'
    $projectionEmptyResidualProfile = Join-Path $testRoot 'projection-empty-residual-success/profile.ps1'
    $projectionEmptyResidualModule = Join-Path $testRoot 'projection-empty-residual-success/modules'
    Write-PshUninstallSafetyText -Path $projectionEmptyResidualProfile -Text "# projection empty residual success`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionEmptyResidualRoot -ProfilePath $projectionEmptyResidualProfile -ModuleRoot $projectionEmptyResidualModule
    $projectionEmptyResidualResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionEmptyResidualRoot -ProfilePath $projectionEmptyResidualProfile -ModuleRoot $projectionEmptyResidualModule
    Assert-PshUninstallSafety ([bool]$projectionEmptyResidualResult.success -and [int]$projectionEmptyResidualResult.code -eq 0 -and -not [bool]$projectionEmptyResidualResult.recoveryRequired) 'A created projection did not complete normal top-level uninstall.'
    Assert-PshUninstallSafety (-not [IO.Directory]::Exists($projectionEmptyResidualModule) -and -not [IO.Directory]::Exists((Join-Path $projectionEmptyResidualRoot 'psreadline-projection-state')) -and -not [IO.File]::Exists((Join-Path $projectionEmptyResidualRoot 'current.json')) -and -not [IO.File]::Exists((Join-Path $projectionEmptyResidualRoot 'ownership.json')) -and -not [IO.File]::Exists((Join-Path $projectionEmptyResidualRoot 'transaction.json'))) 'Successful created projection uninstall left a target parent, state root, or lifecycle metadata.'

    $projectionMutexRoot = Join-Path $testRoot 'projection-standalone-mutex/Psh'
    $projectionMutexProfile = Join-Path $testRoot 'projection-standalone-mutex/profile.ps1'
    $projectionMutexModule = Join-Path $testRoot 'projection-standalone-mutex/modules'
    $projectionMutexStateRoot = Join-Path $projectionMutexRoot 'psreadline-projection-state'
    $projectionMutexDirectory = Join-Path $testRoot 'projection-standalone-mutex/process'
    $projectionMutexReady = Join-Path $projectionMutexDirectory 'parent.ready'
    $projectionMutexRelease = Join-Path $projectionMutexDirectory 'parent.release'
    $projectionMutexParentResult = Join-Path $projectionMutexDirectory 'parent-result.json'
    $projectionMutexParentError = Join-Path $projectionMutexDirectory 'parent-error.txt'
    $projectionMutexParentDriver = Join-Path $projectionMutexDirectory 'parent-driver.ps1'
    $projectionMutexProbeDriver = Join-Path $projectionMutexDirectory 'probe-driver.ps1'
    $projectionMutexStandaloneDriver = Join-Path $projectionMutexDirectory 'standalone-driver.ps1'
    $projectionMutexProbeResult = Join-Path $projectionMutexDirectory 'probe-result.json'
    $projectionMutexAcquireResult = Join-Path $projectionMutexDirectory 'acquire-result.json'
    $projectionMutexStandaloneStarted = Join-Path $projectionMutexDirectory 'standalone.started'
    $projectionMutexStandaloneResult = Join-Path $projectionMutexDirectory 'standalone-result.json'
    Write-PshUninstallSafetyText -Path $projectionMutexProfile -Text "# projection standalone mutex`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionMutexRoot -ProfilePath $projectionMutexProfile -ModuleRoot $projectionMutexModule
    Write-PshUninstallSafetyText -Path $projectionMutexParentDriver -Text @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ConfigPath)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$config = [IO.File]::ReadAllText($ConfigPath, $utf8) | ConvertFrom-Json
try {
    $env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_READY_PATH = [string]$config.ReadyPath
    $env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_RELEASE_PATH = [string]$config.ReleasePath
    $result = @(& ([string]$config.UninstallPath) -InstallRoot ([string]$config.InstallRoot) -ProfilePath @([string]$config.ProfilePath) -ModuleRoot @([string]$config.ModuleRoot) -Confirm:$false)[-1]
    [IO.File]::WriteAllText([string]$config.ResultPath, (([pscustomobject][ordered]@{ result = $result }) | ConvertTo-Json -Depth 12), $utf8)
    if (-not [bool]$result.success -or [int]$result.code -ne 0) { exit 41 }
    exit 0
}
catch {
    [IO.File]::WriteAllText([string]$config.ErrorPath, ($_ | Out-String), $utf8)
    exit 42
}
'@
    Write-PshUninstallSafetyText -Path $projectionMutexProbeDriver -Text @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ConfigPath)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$config = [IO.File]::ReadAllText($ConfigPath, $utf8) | ConvertFrom-Json
. ([string]$config.HelperPath)
$lock = $null
$exitCode = 0
try {
    $stateRootWithTrailingSeparator = ([string]$config.StateRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $lock = Enter-PshPSReadLineProjectionLock -StateRoot $stateRootWithTrailingSeparator -TimeoutMilliseconds 500
    [IO.File]::WriteAllText([string]$config.ResultPath, '{"status":"acquired"}', $utf8)
    if ([bool]$config.ExpectBlocked) { $exitCode = 51 }
}
catch {
    [IO.File]::WriteAllText([string]$config.ResultPath, (([pscustomobject][ordered]@{ status = 'error'; message = $_.Exception.Message }) | ConvertTo-Json -Compress), $utf8)
    if (-not [bool]$config.ExpectBlocked -or $_.Exception.Message -notlike '*Timed out waiting for another PSReadLine projection transaction*') { $exitCode = 52 }
}
finally {
    if ($null -ne $lock) { Exit-PshPSReadLineProjectionLock -Lock $lock }
}
exit $exitCode
'@
    Write-PshUninstallSafetyText -Path $projectionMutexStandaloneDriver -Text @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ConfigPath)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$config = [IO.File]::ReadAllText($ConfigPath, $utf8) | ConvertFrom-Json
try {
    [IO.File]::WriteAllText([string]$config.StartedPath, "started`n", $utf8)
    $results = @(& ([string]$config.UninstallPath) -ModuleRoot @([string]$config.ModuleRoot) -StateRoot ([string]$config.StateRoot) -Confirm:$false)
    [IO.File]::WriteAllText([string]$config.ResultPath, (([pscustomobject][ordered]@{ results = @($results) }) | ConvertTo-Json -Depth 12), $utf8)
    exit 0
}
catch {
    [IO.File]::WriteAllText([string]$config.ErrorPath, ($_ | Out-String), $utf8)
    exit 61
}
'@
    $projectionMutexParentConfig = Join-Path $projectionMutexDirectory 'parent-config.json'
    $projectionMutexProbeConfig = Join-Path $projectionMutexDirectory 'probe-config.json'
    $projectionMutexStandaloneConfig = Join-Path $projectionMutexDirectory 'standalone-config.json'
    $projectionMutexAcquireConfig = Join-Path $projectionMutexDirectory 'acquire-config.json'
    [IO.File]::WriteAllText($projectionMutexParentConfig, (([pscustomobject][ordered]@{ UninstallPath = $uninstallScript; InstallRoot = $projectionMutexRoot; ProfilePath = $projectionMutexProfile; ModuleRoot = $projectionMutexModule; ReadyPath = $projectionMutexReady; ReleasePath = $projectionMutexRelease; ResultPath = $projectionMutexParentResult; ErrorPath = $projectionMutexParentError }) | ConvertTo-Json -Compress), $script:Utf8)
    [IO.File]::WriteAllText($projectionMutexProbeConfig, (([pscustomobject][ordered]@{ HelperPath = (Join-Path $packageRoot 'payload/profile/PSReadLineProjection.ps1'); StateRoot = $projectionMutexStateRoot; ResultPath = $projectionMutexProbeResult; ExpectBlocked = $true }) | ConvertTo-Json -Compress), $script:Utf8)
    [IO.File]::WriteAllText($projectionMutexStandaloneConfig, (([pscustomobject][ordered]@{ UninstallPath = (Join-Path $packageRoot 'payload/profile/Uninstall-PshPSReadLineProjection.ps1'); ModuleRoot = $projectionMutexModule; StateRoot = $projectionMutexStateRoot; StartedPath = $projectionMutexStandaloneStarted; ResultPath = $projectionMutexStandaloneResult; ErrorPath = (Join-Path $projectionMutexDirectory 'standalone-error.txt') }) | ConvertTo-Json -Compress), $script:Utf8)
    [IO.File]::WriteAllText($projectionMutexAcquireConfig, (([pscustomobject][ordered]@{ HelperPath = (Join-Path $packageRoot 'payload/profile/PSReadLineProjection.ps1'); StateRoot = $projectionMutexStateRoot; ResultPath = $projectionMutexAcquireResult; ExpectBlocked = $false }) | ConvertTo-Json -Compress), $script:Utf8)
    $projectionMutexParentProcess = $null
    $projectionMutexProbeProcess = $null
    $projectionMutexStandaloneProcess = $null
    $projectionMutexAcquireProcess = $null
    try {
        $projectionMutexParentProcess = Start-PshUninstallSafetyProcess -DriverPath $projectionMutexParentDriver -ConfigPath $projectionMutexParentConfig -StandardOutputPath (Join-Path $projectionMutexDirectory 'parent.stdout') -StandardErrorPath (Join-Path $projectionMutexDirectory 'parent.stderr')
        $projectionMutexReadyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not [IO.File]::Exists($projectionMutexReady) -and -not $projectionMutexParentProcess.HasExited -and [DateTime]::UtcNow -lt $projectionMutexReadyDeadline) { Start-Sleep -Milliseconds 25 }
        Assert-PshUninstallSafety ([IO.File]::Exists($projectionMutexReady) -and -not $projectionMutexParentProcess.HasExited) 'Top-level uninstall did not reach the exact-Post projection lock hold point.'

        $projectionMutexProbeProcess = Start-PshUninstallSafetyProcess -DriverPath $projectionMutexProbeDriver -ConfigPath $projectionMutexProbeConfig -StandardOutputPath (Join-Path $projectionMutexDirectory 'probe.stdout') -StandardErrorPath (Join-Path $projectionMutexDirectory 'probe.stderr')
        if (-not $projectionMutexProbeProcess.WaitForExit(5000)) { throw 'Projection mutex timeout probe did not exit.' }
        $projectionMutexProbeDocument = [IO.File]::ReadAllText($projectionMutexProbeResult, $script:Utf8) | ConvertFrom-Json
        Assert-PshUninstallSafety ($projectionMutexProbeProcess.ExitCode -eq 0 -and [string]$projectionMutexProbeDocument.status -ceq 'error' -and [string]$projectionMutexProbeDocument.message -like '*Timed out waiting for another PSReadLine projection transaction*') 'A canonical trailing-separator mutex probe overlapped the retained top-level projection lock.'

        $projectionMutexStandaloneProcess = Start-PshUninstallSafetyProcess -DriverPath $projectionMutexStandaloneDriver -ConfigPath $projectionMutexStandaloneConfig -StandardOutputPath (Join-Path $projectionMutexDirectory 'standalone.stdout') -StandardErrorPath (Join-Path $projectionMutexDirectory 'standalone.stderr')
        $projectionMutexStartedDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [IO.File]::Exists($projectionMutexStandaloneStarted) -and -not $projectionMutexStandaloneProcess.HasExited -and [DateTime]::UtcNow -lt $projectionMutexStartedDeadline) { Start-Sleep -Milliseconds 25 }
        $projectionMutexStandaloneBlocked = [IO.File]::Exists($projectionMutexStandaloneStarted) -and -not $projectionMutexStandaloneProcess.WaitForExit(500)
        Assert-PshUninstallSafety ($projectionMutexStandaloneBlocked) 'The real standalone projection uninstaller did not block behind the retained top-level mutex.'

        [IO.File]::WriteAllText($projectionMutexRelease, "release`n", $script:Utf8)
        if (-not $projectionMutexParentProcess.WaitForExit(15000)) { throw 'Top-level projection mutex fixture did not exit after release.' }
        if (-not $projectionMutexStandaloneProcess.WaitForExit(15000)) { throw 'Standalone projection uninstaller did not exit after top-level release.' }
        $projectionMutexParentDocument = [IO.File]::ReadAllText($projectionMutexParentResult, $script:Utf8) | ConvertFrom-Json
        $projectionMutexStandaloneDocument = [IO.File]::ReadAllText($projectionMutexStandaloneResult, $script:Utf8) | ConvertFrom-Json
        $projectionMutexStandaloneResults = @($projectionMutexStandaloneDocument.results)
        Assert-PshUninstallSafety ($projectionMutexParentProcess.ExitCode -eq 0 -and [bool]$projectionMutexParentDocument.result.success -and [int]$projectionMutexParentDocument.result.code -eq 0) 'Top-level uninstall did not complete successfully after releasing its projection hold hook.'
        Assert-PshUninstallSafety ($projectionMutexStandaloneProcess.ExitCode -eq 0 -and $projectionMutexStandaloneResults.Count -eq 1 -and [string]$projectionMutexStandaloneResults[0].Status -ceq 'NotInstalled' -and -not [bool]$projectionMutexStandaloneResults[0].Changed) 'Standalone projection uninstaller did not continue to a no-change NotInstalled result after mutex release.'

        $projectionMutexAcquireProcess = Start-PshUninstallSafetyProcess -DriverPath $projectionMutexProbeDriver -ConfigPath $projectionMutexAcquireConfig -StandardOutputPath (Join-Path $projectionMutexDirectory 'acquire.stdout') -StandardErrorPath (Join-Path $projectionMutexDirectory 'acquire.stderr')
        if (-not $projectionMutexAcquireProcess.WaitForExit(5000)) { throw 'Projection mutex post-release acquire probe did not exit.' }
        $projectionMutexAcquireDocument = [IO.File]::ReadAllText($projectionMutexAcquireResult, $script:Utf8) | ConvertFrom-Json
        Assert-PshUninstallSafety ($projectionMutexAcquireProcess.ExitCode -eq 0 -and [string]$projectionMutexAcquireDocument.status -ceq 'acquired' -and -not [IO.Directory]::Exists($projectionMutexModule) -and -not [IO.Directory]::Exists($projectionMutexStateRoot) -and -not [IO.File]::Exists((Join-Path $projectionMutexRoot 'current.json'))) 'Projection mutex leaked after completion or top-level cleanup left managed state.'
    }
    finally {
        if (-not [IO.File]::Exists($projectionMutexRelease)) {
            try { [IO.File]::WriteAllText($projectionMutexRelease, "release`n", $script:Utf8) } catch {}
        }
        foreach ($process in @($projectionMutexParentProcess, $projectionMutexProbeProcess, $projectionMutexStandaloneProcess, $projectionMutexAcquireProcess)) {
            if ($null -eq $process) { continue }
            try {
                if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(5000) }
            }
            catch {}
            finally { $process.Dispose() }
        }
    }

    $projectionReusedRoot = Join-Path $testRoot 'projection-reused-success/Psh'
    $projectionReusedProfile = Join-Path $testRoot 'projection-reused-success/profile.ps1'
    $projectionReusedModule = Join-Path $testRoot 'projection-reused-success/modules'
    $projectionReusedContainer = Join-Path $projectionReusedModule 'PSReadLine'
    [IO.Directory]::CreateDirectory($projectionReusedContainer) | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh/Dependencies/PSReadLine/2.4.5') -Destination $projectionReusedContainer -Recurse
    Write-PshUninstallSafetyText -Path $projectionReusedProfile -Text "# projection reused success profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $projectionReusedRoot -ProfilePath $projectionReusedProfile -ModuleRoot $projectionReusedModule
    $projectionReusedTarget = Join-Path $projectionReusedContainer '2.4.5'
    $projectionReusedTree = Get-PshUninstallSafetyTreeSnapshot -Root $projectionReusedTarget
    $projectionReusedManifestPath = Join-Path $projectionReusedRoot 'psreadline-projection-state/manifest.json'
    $projectionReusedManifestBytes = [IO.File]::ReadAllBytes($projectionReusedManifestPath)
    $projectionReusedCurrent = [IO.File]::ReadAllBytes((Join-Path $projectionReusedRoot 'current.json'))
    $projectionReusedOwnership = [IO.File]::ReadAllBytes((Join-Path $projectionReusedRoot 'ownership.json'))
    $projectionReusedVersion = Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionReusedRoot "versions/$version")
    $projectionReusedRollback = Invoke-PshUninstallSafetyInjected -Point 'BeforeOwnershipRemoval' -InstallRoot $projectionReusedRoot -ProfilePath $projectionReusedProfile -ModuleRoot $projectionReusedModule
    Assert-PshUninstallSafety (-not [bool]$projectionReusedRollback.success -and [int]$projectionReusedRollback.code -eq 3 -and [bool]$projectionReusedRollback.rollbackRestored -and -not [bool]$projectionReusedRollback.recoveryRequired) 'A reused projection target did not complete exact parent rollback.'
    Assert-PshUninstallSafety ((Get-PshUninstallSafetyTreeSnapshot -Root $projectionReusedTarget) -ceq $projectionReusedTree -and (Test-PshUninstallSafetyBytesEqual $projectionReusedManifestBytes ([IO.File]::ReadAllBytes($projectionReusedManifestPath))) -and (Test-PshUninstallSafetyBytesEqual $projectionReusedCurrent ([IO.File]::ReadAllBytes((Join-Path $projectionReusedRoot 'current.json')))) -and (Test-PshUninstallSafetyBytesEqual $projectionReusedOwnership ([IO.File]::ReadAllBytes((Join-Path $projectionReusedRoot 'ownership.json')))) -and (Get-PshUninstallSafetyTreeSnapshot -Root (Join-Path $projectionReusedRoot "versions/$version")) -ceq $projectionReusedVersion -and -not [IO.File]::Exists((Join-Path $projectionReusedRoot 'transaction.json'))) 'Reused projection rollback changed target/manifest/package bytes or retained a completed journal.'
    $projectionReusedResult = Invoke-PshUninstallSafetyInjected -InstallRoot $projectionReusedRoot -ProfilePath $projectionReusedProfile -ModuleRoot $projectionReusedModule
    Assert-PshUninstallSafety ([bool]$projectionReusedResult.success -and [int]$projectionReusedResult.code -eq 0 -and -not [bool]$projectionReusedResult.recoveryRequired) 'A reused projection target did not complete normal top-level uninstall.'
    Assert-PshUninstallSafety ((Get-PshUninstallSafetyTreeSnapshot -Root $projectionReusedTarget) -ceq $projectionReusedTree -and -not [IO.File]::Exists((Join-Path $projectionReusedRoot 'psreadline-projection-state/manifest.json'))) 'Normal uninstall changed or removed a reused projection target.'
    Assert-PshUninstallSafety (-not [IO.File]::Exists((Join-Path $projectionReusedRoot 'current.json')) -and -not [IO.File]::Exists((Join-Path $projectionReusedRoot 'ownership.json')) -and -not [IO.Directory]::Exists((Join-Path $projectionReusedRoot "versions/$version")) -and -not [IO.File]::Exists((Join-Path $projectionReusedRoot 'transaction.json'))) 'Reused projection success did not complete package cleanup.'

    $casRoot = Join-Path $testRoot 'cas/Psh'
    $casProfile = Join-Path $testRoot 'cas/profile.ps1'
    $casBootstrapPath = Join-Path $casRoot 'bootstrap.ps1'
    $casOriginalBootstrap = "# user bootstrap bytes`n"
    Write-PshUninstallSafetyText -Path $casProfile -Text "# cas profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $casRoot -ProfilePath $casProfile
    # Mark the synthetic stable file as a verified replacement so uninstall
    # creates a Restored=true move without relying on an unsafe first install.
    $casOwnershipPath = Join-Path $casRoot 'ownership.json'
    $casOwnership = ([IO.File]::ReadAllText($casOwnershipPath, $script:Utf8) | ConvertFrom-Json)
    $casStable = @($casOwnership.stableFiles | Where-Object { [string]$_.relativePath -ceq 'bootstrap.ps1' })[0]
    $casBackupName = 'fixture-original-bootstrap.bin'
    $casBackupPath = Join-Path $casRoot ('.lifecycle/backups/' + $casBackupName)
    Write-PshUninstallSafetyText -Path $casBackupPath -Text $casOriginalBootstrap
    $casOriginalBytes = [IO.File]::ReadAllBytes($casBackupPath)
    $casStable.disposition = 'replaced'
    $casStable.originalExisted = $true
    $casStable.originalLength = [long]$casOriginalBytes.LongLength
    $casStable.originalSha256 = Get-PshUninstallSafetyHash -Path $casBackupPath
    $casStable.backupFileName = $casBackupName
    $casOwnershipJson = (ConvertTo-PshCanonicalJson -InputObject $casOwnership) + "`n"
    [IO.File]::WriteAllText($casOwnershipPath, $casOwnershipJson, $script:Utf8)
    $casInstalledHash = Get-PshUninstallSafetyHash -Path $casBootstrapPath
    $casResult = Invoke-PshUninstallSafetyInjected -Point 'AfterContentMove' -InstallRoot $casRoot -ProfilePath $casProfile -CasReplacementPath $casBootstrapPath
    $casReplacementBytes = $script:Utf8.GetBytes("concurrent replacement`n")
    $casEvidence = @(Get-ChildItem -LiteralPath ([string]$casResult.quarantinePath) -Force -File | Where-Object { (Get-PshUninstallSafetyHash -Path $_.FullName) -ceq $casInstalledHash })
    Assert-PshUninstallSafety (-not [bool]$casResult.success -and [int]$casResult.code -eq 5 -and [bool]$casResult.recoveryRequired -and -not [bool]$casResult.rollbackRestored) 'Restored-file CAS replacement was not reported as an integrity recovery state.'
    Assert-PshUninstallSafety ((Test-PshUninstallSafetyBytesEqual $casReplacementBytes ([IO.File]::ReadAllBytes($casBootstrapPath))) -and $casEvidence.Count -gt 0 -and [IO.File]::Exists((Join-Path $casRoot 'transaction.json'))) 'Restored-file CAS deleted or overwrote concurrent bytes instead of retaining both sides of the evidence.'

    $unknownRoot = Join-Path $testRoot 'unknown/Psh'
    $unknownProfile = Join-Path $testRoot 'unknown/profile.ps1'
    Write-PshUninstallSafetyText -Path $unknownProfile -Text "# unknown profile`n"
    $null = Install-PshUninstallSafetyFixture -PackageRoot $packageRoot -InstallRoot $unknownRoot -ProfilePath $unknownProfile
    $configPath = Join-Path $unknownRoot 'config.psd1'
    $modifiedConfig = [IO.File]::ReadAllText($configPath, $script:Utf8) + "# user modification`n"
    [IO.File]::WriteAllText($configPath, $modifiedConfig, $script:Utf8)
    $unknownResult = @(& $uninstallScript -InstallRoot $unknownRoot -ProfilePath @($unknownProfile) -ModuleRoot @() -Confirm:$false)[-1]
    Assert-PshUninstallSafety ([bool]$unknownResult.success -and [IO.File]::Exists($configPath) -and [IO.File]::ReadAllText($configPath, $script:Utf8) -ceq $modifiedConfig -and @($unknownResult.retainedUnknown).Count -gt 0) 'User-modified config content was not retained exactly.'

    Write-Output ("Goal 5 uninstall safety passed: {0} assertions; synthetic packages only; no network." -f $script:Assertions)
}
finally {
    Remove-Item Env:PSH_UNINSTALL_TEST_FAILURE_POINT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_METADATA_RESTORE_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_ROLLBACK_CLEANUP_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_UNKNOWN_QUARANTINE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_INSTALLER_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_CHILD_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROFILE_STATE_ROOT_REPARSE_TARGET -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_REPARSE_TARGET -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_READY_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_RELEASE_PATH -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
