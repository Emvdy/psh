# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$moduleManifest = Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$markerName = '__PshFileCommandProjectionScope_baf0d32a'
$assertionCount = 0

function Assert-PshAliasScope {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:assertionCount++
    if (-not $Condition) { throw $Message }
}

function Get-PshAliasScopeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.AliasInfo]$Alias
    )

    return [PSCustomObject]@{
        Definition = [string]$Alias.Definition
        Description = [string]$Alias.Description
        Options = [System.Management.Automation.ScopedItemOptions]$Alias.Options
        Visibility = [System.Management.Automation.SessionStateEntryVisibility]$Alias.Visibility
    }
}

function Test-PshAliasScopeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.AliasInfo]$Alias,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    return ([string]$Alias.Definition -ceq [string]$Snapshot.Definition -and
        [string]$Alias.Description -ceq [string]$Snapshot.Description -and
        $Alias.Options -eq $Snapshot.Options -and
        $Alias.Visibility -eq $Snapshot.Visibility)
}

$globalBaseline = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Global -ErrorAction Stop)

try {
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue

    $scriptBaseline = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -ErrorAction Stop)
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $scriptProjected = Get-Command -Name cd -ErrorAction Stop
    Assert-PshAliasScope ($scriptProjected.CommandType -eq 'Function' -and $scriptProjected.Source -eq 'Psh') 'Script-scope import did not project Psh cd as a function.'
    Remove-Module -Name Psh -Force -ErrorAction Stop
    Assert-PshAliasScope (Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -ErrorAction Stop) -Snapshot $scriptBaseline) 'Script-scope unload did not restore cd exactly.'
    Assert-PshAliasScope ($null -eq (Get-Variable -Name $markerName -ErrorAction SilentlyContinue)) 'Script-scope unload leaked the projection marker.'

    function Invoke-PshAliasScopeLevelOne {
        function Invoke-PshAliasScopeLevelTwo {
            $before = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -ErrorAction Stop)
            Import-Module -Name $moduleManifest -Force -ErrorAction Stop
            $first = Get-Command -Name cd -ErrorAction Stop
            Import-Module -Name $moduleManifest -Force -ErrorAction Stop
            $second = Get-Command -Name cd -ErrorAction Stop
            Import-Module -Name $moduleManifest -Force -ErrorAction Stop
            $third = Get-Command -Name cd -ErrorAction Stop
            Remove-Module -Name Psh -Force -ErrorAction Stop
            return [PSCustomObject]@{
                First = $first.CommandType -eq 'Function' -and $first.Source -eq 'Psh'
                Second = $second.CommandType -eq 'Function' -and $second.Source -eq 'Psh'
                Third = $third.CommandType -eq 'Function' -and $third.Source -eq 'Psh'
                Restored = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -ErrorAction Stop) -Snapshot $before
                MarkerGone = $null -eq (Get-Variable -Name $markerName -ErrorAction SilentlyContinue)
            }
        }

        return Invoke-PshAliasScopeLevelTwo
    }

    $nested = Invoke-PshAliasScopeLevelOne
    Assert-PshAliasScope ($nested.First -and $nested.Second -and $nested.Third) 'Two-level Force reimport did not keep Psh cd projected.'
    Assert-PshAliasScope ($nested.Restored -and $nested.MarkerGone) 'Two-level unload did not restore cd and remove markers.'

    $latePrivate = & {
        Import-Module -Name $moduleManifest -Force -ErrorAction Stop
        Set-Alias -Name cd -Value Get-Date -Option Private -Scope Local -Force
        Remove-Module -Name Psh -Force -ErrorAction Stop
        $late = Get-Alias -Name cd -Scope Local -ErrorAction Stop
        $result = [PSCustomObject]@{
            Preserved = [string]$late.Definition -ceq 'Get-Date' -and ($late.Options -band [System.Management.Automation.ScopedItemOptions]::Private) -ne 0
            GlobalRestored = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Global -ErrorAction Stop) -Snapshot $globalBaseline
            MarkerGone = $null -eq (Get-Variable -Name $markerName -ErrorAction SilentlyContinue)
        }
        Remove-Item -LiteralPath Alias:cd -Force
        return $result
    }
    Assert-PshAliasScope ($latePrivate.Preserved -and $latePrivate.GlobalRestored -and $latePrivate.MarkerGone) 'Unload overwrote a late private cd alias or failed outer restoration.'

    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    Set-Alias -Name cd -Value Get-Date -Scope Global -Force
    Remove-Module -Name Psh -Force -ErrorAction Stop
    Assert-PshAliasScope ([string](Get-Alias -Name cd -Scope Global -ErrorAction Stop).Definition -ceq 'Get-Date') 'Unload overwrote a late global cd alias.'
    Remove-Item -LiteralPath Alias:cd -Force
    Set-Alias -Name cd -Value $globalBaseline.Definition -Description $globalBaseline.Description -Option $globalBaseline.Options -Scope Global -Force
    (Get-Alias -Name cd -Scope Global -ErrorAction Stop).Visibility = $globalBaseline.Visibility

    Set-Variable -Name $markerName -Value 'caller-marker' -Description 'caller marker' -Scope Script -Force
    $collisionFailed = $false
    try { Import-Module -Name $moduleManifest -Force -ErrorAction Stop }
    catch { $collisionFailed = $true }
    Assert-PshAliasScope $collisionFailed 'A caller marker collision did not fail before projection.'
    $callerMarker = Get-Variable -Name $markerName -Scope Script -ErrorAction Stop
    Assert-PshAliasScope ([string]$callerMarker.Value -ceq 'caller-marker' -and [string]$callerMarker.Description -ceq 'caller marker') 'Marker collision changed the caller variable.'
    Assert-PshAliasScope (Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -ErrorAction Stop) -Snapshot $scriptBaseline) 'Marker collision changed cd.'
    Remove-Variable -Name $markerName -Scope Script -Force

    function Invoke-PshAliasScopeDeadImporter {
        Import-Module -Name $moduleManifest -Force -ErrorAction Stop
        $command = Get-Command -Name cd -ErrorAction Stop
        if ($command.CommandType -ne 'Function' -or $command.Source -ne 'Psh') { throw 'Dead-scope setup did not project cd.' }
    }

    function Invoke-PshAliasScopeReimporter {
        Import-Module -Name $moduleManifest -Force -ErrorAction Stop
        $command = Get-Command -Name cd -ErrorAction Stop
        if ($command.CommandType -ne 'Function' -or $command.Source -ne 'Psh') { throw 'Sibling Force reimport did not project cd.' }
    }

    Invoke-PshAliasScopeDeadImporter
    Invoke-PshAliasScopeReimporter
    Remove-Module -Name Psh -Force -ErrorAction Stop
    Assert-PshAliasScope (Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Global -ErrorAction Stop) -Snapshot $globalBaseline) 'Dead importer and sibling reimport did not restore global cd.'
    Assert-PshAliasScope ($null -eq (Get-Variable -Name $markerName -Scope Global -ErrorAction SilentlyContinue)) 'Dead importer and sibling reimport leaked the global marker.'

    function Invoke-PshAliasScopeUnknownParent {
        Set-Alias -Name cd -Value Get-Date -Option AllScope -Scope Local -Force
        $parentBefore = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Local -ErrorAction Stop)
        function Invoke-PshAliasScopeKnownInner {
            Set-Alias -Name cd -Value Set-Location -Option AllScope -Scope Local -Force
            $innerBefore = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Local -ErrorAction Stop)
            Import-Module -Name $moduleManifest -Force -ErrorAction Stop
            $during = Get-Command -Name cd -ErrorAction Stop
            Remove-Module -Name Psh -Force -ErrorAction Stop
            return [PSCustomObject]@{
                Preserved = $during.CommandType -eq 'Alias' -and [string]$during.Definition -ceq 'Set-Location'
                Restored = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Local -ErrorAction Stop) -Snapshot $innerBefore
            }
        }
        $inner = Invoke-PshAliasScopeKnownInner
        return [PSCustomObject]@{
            Inner = $inner
            ParentRestored = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Local -ErrorAction Stop) -Snapshot $parentBefore
        }
    }

    $unknownParent = Invoke-PshAliasScopeUnknownParent
    Assert-PshAliasScope ($unknownParent.Inner.Preserved -and $unknownParent.Inner.Restored -and $unknownParent.ParentRestored) 'Known inner cd over an unknown parent alias was partially projected.'

    $localKnown = & {
        $globalBefore = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Global -ErrorAction Stop)
        $callerAlias = Get-Alias -Name pwd -Scope Local -ErrorAction SilentlyContinue
        $callerHadLocal = $null -ne $callerAlias
        $callerBefore = if ($callerHadLocal) { Get-PshAliasScopeSnapshot -Alias $callerAlias } else { $null }
        $fixtureCreated = $false
        $result = $null
        try {
            if ($callerHadLocal) {
                # WinPS 5.1 cannot remove AllScope by overwriting the local alias in place.
                Remove-Item -LiteralPath Alias:pwd -Force -ErrorAction Stop
            }
            Set-Alias -Name pwd -Value Get-Location -Description 'caller local known alias' -Option None -Scope Local -Force
            $fixtureCreated = $true
            $localBefore = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Local -ErrorAction Stop)
            Import-Module -Name $moduleManifest -Force -ErrorAction Stop
            $during = Get-Command -Name pwd -ErrorAction Stop
            Remove-Module -Name Psh -Force -ErrorAction Stop
            $result = [PSCustomObject]@{
                Projected = $during.CommandType -eq 'Function' -and $during.Source -eq 'Psh'
                LocalRestored = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Local -ErrorAction Stop) -Snapshot $localBefore
                CallerExact = $false
                GlobalExact = $false
            }
        }
        finally {
            Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
            if ($fixtureCreated -and $null -ne (Get-Alias -Name pwd -Scope Local -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath Alias:pwd -Force -ErrorAction SilentlyContinue
            }
            if ($callerHadLocal) {
                Set-Alias -Name pwd -Value $callerBefore.Definition -Description $callerBefore.Description -Option $callerBefore.Options -Scope Local -Force
                (Get-Alias -Name pwd -Scope Local -ErrorAction Stop).Visibility = $callerBefore.Visibility
            }
        }
        $callerAfter = Get-Alias -Name pwd -Scope Local -ErrorAction SilentlyContinue
        $result.CallerExact = if ($callerHadLocal) {
            $null -ne $callerAfter -and (Test-PshAliasScopeSnapshot -Alias $callerAfter -Snapshot $callerBefore)
        }
        else {
            $null -eq $callerAfter
        }
        $result.GlobalExact = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Global -ErrorAction Stop) -Snapshot $globalBefore
        return $result
    }
    Assert-PshAliasScope ($localKnown.Projected -and $localKnown.LocalRestored -and $localKnown.CallerExact -and $localKnown.GlobalExact) 'A caller-local known alias was not restored locally or polluted global scope.'

    $unknownAndPrivate = & {
        $globalBefore = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Global -ErrorAction Stop)
        $callerAlias = Get-Alias -Name pwd -Scope Local -ErrorAction SilentlyContinue
        $callerHadLocal = $null -ne $callerAlias
        $callerBefore = if ($callerHadLocal) { Get-PshAliasScopeSnapshot -Alias $callerAlias } else { $null }
        $fixtureCreated = $false
        $result = $null
        try {
            if ($callerHadLocal) {
                Remove-Item -LiteralPath Alias:pwd -Force -ErrorAction Stop
            }
            Set-Alias -Name pwd -Value Get-Date -Description 'caller unknown alias' -Option None -Scope Local -Force
            $fixtureCreated = $true
            $unknownBefore = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Local -ErrorAction Stop)
            Import-Module -Name $moduleManifest -Force -ErrorAction Stop
            $unknownDuring = Get-Command -Name pwd -ErrorAction Stop
            Remove-Module -Name Psh -Force -ErrorAction Stop
            $unknownExact = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Local -ErrorAction Stop) -Snapshot $unknownBefore
            Remove-Item -LiteralPath Alias:pwd -Force

            Set-Alias -Name pwd -Value Get-Date -Description 'caller private alias' -Option Private -Scope Local -Force
            $privateBefore = Get-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Local -ErrorAction Stop)
            Import-Module -Name $moduleManifest -Force -ErrorAction Stop
            $privateDuring = Get-Command -Name pwd -ErrorAction Stop
            Remove-Module -Name Psh -Force -ErrorAction Stop
            $privateExact = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Local -ErrorAction Stop) -Snapshot $privateBefore
            $result = [PSCustomObject]@{
                Unknown = $unknownDuring.CommandType -eq 'Alias' -and [string]$unknownDuring.Definition -ceq 'Get-Date' -and $unknownExact
                Private = $privateDuring.CommandType -eq 'Alias' -and [string]$privateDuring.Definition -ceq 'Get-Date' -and $privateExact
                CallerExact = $false
                GlobalExact = $false
            }
        }
        finally {
            Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
            if ($fixtureCreated -and $null -ne (Get-Alias -Name pwd -Scope Local -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath Alias:pwd -Force -ErrorAction SilentlyContinue
            }
            if ($callerHadLocal) {
                Set-Alias -Name pwd -Value $callerBefore.Definition -Description $callerBefore.Description -Option $callerBefore.Options -Scope Local -Force
                (Get-Alias -Name pwd -Scope Local -ErrorAction Stop).Visibility = $callerBefore.Visibility
            }
        }
        $callerAfter = Get-Alias -Name pwd -Scope Local -ErrorAction SilentlyContinue
        $result.CallerExact = if ($callerHadLocal) {
            $null -ne $callerAfter -and (Test-PshAliasScopeSnapshot -Alias $callerAfter -Snapshot $callerBefore)
        }
        else {
            $null -eq $callerAfter
        }
        $result.GlobalExact = Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name pwd -Scope Global -ErrorAction Stop) -Snapshot $globalBefore
        return $result
    }
    Assert-PshAliasScope ($unknownAndPrivate.Unknown -and $unknownAndPrivate.Private -and $unknownAndPrivate.CallerExact -and $unknownAndPrivate.GlobalExact) 'Unknown or private caller aliases were overwritten by projection or leaked fixture state.'

    function Invoke-PshAliasScopeDeep {
        param([int]$Depth)

        if ($Depth -gt 0) { return Invoke-PshAliasScopeDeep -Depth ($Depth - 1) }
        Import-Module -Name $moduleManifest -Force -ErrorAction Stop
        $during = Get-Command -Name cd -ErrorAction Stop
        Remove-Module -Name Psh -Force -ErrorAction Stop
        return [PSCustomObject]@{
            Projected = $during.CommandType -eq 'Function' -and $during.Source -eq 'Psh'
            MarkerGone = $null -eq (Get-Variable -Name $markerName -ErrorAction SilentlyContinue)
        }
    }

    $deepScopeCount = if ($PSVersionTable.PSVersion.Major -ge 7) { 130 } else { 2 }
    $deep = Invoke-PshAliasScopeDeep -Depth $deepScopeCount
    Assert-PshAliasScope ($deep.Projected -and $deep.MarkerGone -and (Test-PshAliasScopeSnapshot -Alias (Get-Alias -Name cd -Scope Global -ErrorAction Stop) -Snapshot $globalBaseline)) ('Projection failed at caller-scope depth {0}.' -f $deepScopeCount)

    Write-Output ('Goal 3 Batch 1 alias-scope acceptance passed: {0} assertions.' -f $assertionCount)
}
finally {
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name $markerName -Scope Script -Force -ErrorAction SilentlyContinue
    $currentGlobal = Get-Alias -Name cd -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $currentGlobal -or -not (Test-PshAliasScopeSnapshot -Alias $currentGlobal -Snapshot $globalBaseline)) {
        Remove-Item -LiteralPath Alias:cd -Force -ErrorAction SilentlyContinue
        Set-Alias -Name cd -Value $globalBaseline.Definition -Description $globalBaseline.Description -Option $globalBaseline.Options -Scope Global -Force
        (Get-Alias -Name cd -Scope Global -ErrorAction Stop).Visibility = $globalBaseline.Visibility
    }
}
