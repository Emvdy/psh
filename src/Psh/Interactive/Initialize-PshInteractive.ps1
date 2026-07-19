# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

$script:PshInteractiveSourceDirectory = $PSScriptRoot
$script:PshPromptSourceLoadError = $null
$script:PshGitCompletionSourceLoadError = $null

function Get-PshVirtualTerminalStatus {
    [CmdletBinding()]
    param()

    $outputRedirected = $false
    try {
        $outputRedirected = [Console]::IsOutputRedirected
    }
    catch {
        # Hosts without a real System.Console are treated conservatively.
    }

    if ($outputRedirected) {
        return [PSCustomObject][ordered]@{
            supported        = $false
            reason           = 'OutputRedirected'
            outputRedirected = $true
            hostName         = [string]$Host.Name
        }
    }

    $hostReportsSupport = $false
    try {
        $property = $Host.UI.PSObject.Properties['SupportsVirtualTerminal']
        if ($null -ne $property) {
            $hostReportsSupport = [bool]$property.Value
        }
    }
    catch {
        $hostReportsSupport = $false
    }

    if ($hostReportsSupport) {
        return [PSCustomObject][ordered]@{
            supported        = $true
            reason           = 'HostReportsSupport'
            outputRedirected = $false
            hostName         = [string]$Host.Name
        }
    }

    $term = [string][Environment]::GetEnvironmentVariable('TERM')
    if (-not [string]::IsNullOrWhiteSpace($term) -and
        -not [string]::Equals($term, 'dumb', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject][ordered]@{
            supported        = $true
            reason           = 'TermEnvironment'
            outputRedirected = $false
            hostName         = [string]$Host.Name
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string][Environment]::GetEnvironmentVariable('WT_SESSION')) -or
        [string]::Equals([string][Environment]::GetEnvironmentVariable('TERM_PROGRAM'), 'vscode', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string][Environment]::GetEnvironmentVariable('ConEmuANSI'), 'ON', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::IsNullOrWhiteSpace([string][Environment]::GetEnvironmentVariable('ANSICON'))) {
        return [PSCustomObject][ordered]@{
            supported        = $true
            reason           = 'KnownVirtualTerminalHost'
            outputRedirected = $false
            hostName         = [string]$Host.Name
        }
    }

    return [PSCustomObject][ordered]@{
        supported        = $false
        reason           = 'VirtualTerminalNotDetected'
        outputRedirected = $false
        hostName         = [string]$Host.Name
    }
}

$pshPromptSourcePath = Join-Path -Path $script:PshInteractiveSourceDirectory -ChildPath 'Prompt.ps1'
try {
    if (-not (Test-Path -LiteralPath $pshPromptSourcePath -PathType Leaf)) {
        throw ('Prompt implementation is missing: {0}' -f $pshPromptSourcePath)
    }
    . $pshPromptSourcePath
}
catch {
    $script:PshPromptSourceLoadError = [string]$_.Exception.Message
}

$pshGitCompletionSourcePath = Join-Path -Path $script:PshInteractiveSourceDirectory -ChildPath 'GitCompletion.ps1'
try {
    if (-not (Test-Path -LiteralPath $pshGitCompletionSourcePath -PathType Leaf)) {
        throw ('Git completion implementation is missing: {0}' -f $pshGitCompletionSourcePath)
    }
    . $pshGitCompletionSourcePath
}
catch {
    $script:PshGitCompletionSourceLoadError = [string]$_.Exception.Message
}

function Resolve-PshBundledModuleManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [version]$Version,

        [Parameter(Mandatory = $true)]
        [string]$DependencyRoot,

        [AllowNull()]
        [string]$ExplicitPath
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if ((Test-Path -LiteralPath $ExplicitPath -PathType Leaf) -and
            [string]::Equals([IO.Path]::GetExtension($ExplicitPath), '.psd1', [System.StringComparison]::OrdinalIgnoreCase)) {
            $candidates += $ExplicitPath
        }
        elseif (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            $candidates += (Join-Path -Path $ExplicitPath -ChildPath ('{0}.psd1' -f $Name))
        }
        else {
            $candidates += Join-Path -Path $ExplicitPath -ChildPath ('{0}.psd1' -f $Name)
            $candidates += Join-Path -Path (Join-Path -Path $ExplicitPath -ChildPath $Version.ToString()) -ChildPath ('{0}.psd1' -f $Name)
        }
    }
    else {
        $versionDirectory = Join-Path -Path (Join-Path -Path $DependencyRoot -ChildPath $Name) -ChildPath $Version.ToString()
        $candidates += Join-Path -Path $versionDirectory -ChildPath ('{0}.psd1' -f $Name)
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        try {
            return [string](Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
        }
        catch {
            continue
        }
    }

    if ($candidates.Count -gt 0) {
        return [string]$candidates[0]
    }
    return $null
}

function Get-PshFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('Assembly file was not found: {0}' -f $Path)
    }
    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-PshDirectoryTreeFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not [IO.Directory]::Exists($rootPath) -or [IO.File]::Exists($rootPath)) {
        throw ('{0} is not a directory: {1}' -f $Description, $rootPath)
    }
    $rootAttributes = [IO.File]::GetAttributes($rootPath)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('{0} must not be a reparse point: {1}' -f $Description, $rootPath)
    }

    $fingerprint = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force -ErrorAction Stop)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('{0} contains a reparse point: {1}' -f $Description, $entry.FullName)
        }
        if ($entry.PSIsContainer) {
            continue
        }

        $relativePath = $entry.FullName.Substring($rootPath.Length).TrimStart('\', '/').Replace('\', '/')
        $fingerprint.Add(('{0}|{1}|{2}' -f $relativePath, [long]$entry.Length, (Get-PshFileSha256 -Path $entry.FullName)))
    }
    return @($fingerprint.ToArray() | Sort-Object)
}

function Test-PshDirectoryTreeFingerprintEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Left,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if (-not [string]::Equals($Left[$index], $Right[$index], [System.StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Get-PshCommandImplementationAssembly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Command
    )

    $implementingTypeProperty = $Command.PSObject.Properties['ImplementingType']
    if ($null -eq $implementingTypeProperty -or $null -eq $implementingTypeProperty.Value) {
        throw ('{0} does not expose an implementing type.' -f [string]$Command.Name)
    }

    $assembly = $implementingTypeProperty.Value.Assembly
    if ($null -eq $assembly -or [string]::IsNullOrWhiteSpace([string]$assembly.Location)) {
        throw ('{0} does not expose an implementation assembly location.' -f [string]$Command.Name)
    }

    $assemblyPath = [IO.Path]::GetFullPath([string]$assembly.Location)
    return [PSCustomObject][ordered]@{
        path = $assemblyPath
        hash = Get-PshFileSha256 -Path $assemblyPath
    }
}

function Get-PshLoadedAssemblyEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return @(
        foreach ($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if (-not [string]::Equals(
                    [string]$assembly.GetName().Name,
                    $Name,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                continue
            }

            $location = $null
            $hash = $null
            $inspectionError = $null
            try {
                $location = [string]$assembly.Location
                if ([string]::IsNullOrWhiteSpace($location)) {
                    throw ('Loaded assembly {0} has no inspectable location.' -f $Name)
                }
                $location = [IO.Path]::GetFullPath($location)
                $hash = Get-PshFileSha256 -Path $location
            }
            catch {
                $inspectionError = [string]$_.Exception.Message
            }

            [PSCustomObject][ordered]@{
                fullName        = [string]$assembly.FullName
                location        = $location
                sha256          = $hash
                inspectionError = $inspectionError
            }
        }
    )
}

function Import-PshBundledModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [version]$Version,

        [Parameter(Mandatory = $true)]
        [string]$DependencyRoot,

        [AllowNull()]
        [string]$ExplicitPath,

        [switch]$ReplaceLoadedConflicts
    )

    $result = [ordered]@{
        name            = $Name
        expectedVersion = $Version.ToString()
        requestedPath   = $null
        resolvedPath    = $null
        manifestVersion = $null
        validated       = $false
        imported        = $false
        loadedVersion   = $null
        loadedPath      = $null
        loadedModuleBase = $null
        loadAction      = $null
        expectedAssemblyPath = $null
        expectedAssemblyHash = $null
        actualAssemblyPath = $null
        actualAssemblyHash = $null
        assemblyVerified = $false
        assemblyVerificationState = 'not-applicable'
        expectedTreeFileCount = 0
        expectedTreeFingerprint = @()
        actualTreeFileCount = 0
        actualTreeFingerprint = @()
        treeVerified    = $false
        treeVerificationState = 'not-applicable'
        preloadedAssemblies = @()
        restartRequired = $false
        mutationSuppressed = $false
        importScope     = 'Global'
        removedConflicts = @()
        restoredConflicts = @()
        restorationErrors = @()
        error           = $null
    }

    $removedModules = New-Object System.Collections.Generic.List[object]
    $preexistingModules = @()
    $introducedExpectedModule = $false
    $expectedBase = $null
    $pathComparison = [System.StringComparison]::Ordinal

    try {
        $resolvedPath = Resolve-PshBundledModuleManifest `
            -Name $Name `
            -Version $Version `
            -DependencyRoot $DependencyRoot `
            -ExplicitPath $ExplicitPath
        $result.requestedPath = $resolvedPath
        if ([string]::IsNullOrWhiteSpace($resolvedPath) -or
            -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw 'Bundled module manifest was not found at the fixed path.'
        }

        $resolvedPath = [string](Get-Item -LiteralPath $resolvedPath -ErrorAction Stop).FullName
        $result.resolvedPath = $resolvedPath

        $manifest = Test-ModuleManifest -Path $resolvedPath -ErrorAction Stop -WarningAction SilentlyContinue
        $result.manifestVersion = [string]$manifest.Version
        if (-not [string]::Equals([string]$manifest.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('Expected module {0}, but the manifest identifies {1}.' -f $Name, [string]$manifest.Name)
        }
        if ($manifest.Version -ne $Version) {
            throw ('Expected {0} {1}, but the manifest declares {2}.' -f $Name, $Version, $manifest.Version)
        }
        $result.validated = $true

        $expectedBase = [IO.Path]::GetFullPath((Split-Path -Path $resolvedPath -Parent)).TrimEnd('\', '/')
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $pathComparison = [System.StringComparison]::OrdinalIgnoreCase
        }

        if ([string]::Equals($Name, 'PSReadLine', [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.assemblyVerificationState = 'pending'
            $result.treeVerificationState = 'pending'
            $result.expectedAssemblyPath = Join-Path -Path $expectedBase -ChildPath 'Microsoft.PowerShell.PSReadLine.dll'
            $result.expectedAssemblyHash = Get-PshFileSha256 -Path $result.expectedAssemblyPath
            $expectedTreeFingerprint = @(Get-PshDirectoryTreeFingerprint -Root $expectedBase -Description 'The fixed PSReadLine module tree')
            if ($expectedTreeFingerprint.Count -ne 7) {
                throw ('The fixed PSReadLine module tree contains {0} files instead of 7.' -f $expectedTreeFingerprint.Count)
            }
            $result.expectedTreeFileCount = $expectedTreeFingerprint.Count
            $result.expectedTreeFingerprint = @($expectedTreeFingerprint)
        }

        $preexistingModules = @(Get-Module -Name $Name)

        if ([string]::Equals($Name, 'PSReadLine', [System.StringComparison]::OrdinalIgnoreCase)) {
            $loadedAssemblyEvidence = @(Get-PshLoadedAssemblyEvidence -Name 'Microsoft.PowerShell.PSReadLine')
            $result.preloadedAssemblies = @($loadedAssemblyEvidence)

            if ($preexistingModules.Count -gt 0 -or $loadedAssemblyEvidence.Count -gt 0) {
                $result.mutationSuppressed = $true
                $result.restartRequired = $true
                if ($preexistingModules.Count -ne 1) {
                    throw ('A fresh process is required because {0} PSReadLine modules are loaded.' -f $preexistingModules.Count)
                }
                if ($loadedAssemblyEvidence.Count -ne 1) {
                    throw ('A fresh process is required because {0} PSReadLine implementation assemblies are loaded.' -f $loadedAssemblyEvidence.Count)
                }

                $preloadedModule = $preexistingModules[0]
                $preloadedAssembly = $loadedAssemblyEvidence[0]
                $result.actualAssemblyPath = [string]$preloadedAssembly.location
                $result.actualAssemblyHash = [string]$preloadedAssembly.sha256
                if (-not [string]::IsNullOrWhiteSpace([string]$preloadedAssembly.inspectionError)) {
                    throw ('A fresh process is required because the loaded PSReadLine assembly cannot be verified: {0}' -f $preloadedAssembly.inspectionError)
                }
                if ($preloadedModule.Version -ne $Version) {
                    throw ('A fresh process is required because PSReadLine {0} is already loaded instead of {1}.' -f $preloadedModule.Version, $Version)
                }
                if (-not [string]::Equals(
                        [string]$result.expectedAssemblyHash,
                        [string]$result.actualAssemblyHash,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    throw ('A fresh process is required because the loaded PSReadLine implementation uses different bytes: {0}' -f $result.actualAssemblyPath)
                }

                $preloadedBase = [IO.Path]::GetFullPath([string]$preloadedModule.ModuleBase).TrimEnd('\', '/')
                $preloadedTreeFingerprint = @(Get-PshDirectoryTreeFingerprint -Root $preloadedBase -Description 'The preloaded PSReadLine module tree')
                $result.actualTreeFileCount = $preloadedTreeFingerprint.Count
                $result.actualTreeFingerprint = @($preloadedTreeFingerprint)
                if (-not (Test-PshDirectoryTreeFingerprintEqual -Left $expectedTreeFingerprint -Right $preloadedTreeFingerprint)) {
                    throw ('A fresh process is required because the preloaded PSReadLine module tree differs from the fixed seven-file tree: {0}' -f $preloadedBase)
                }
                $preloadedCommand = Get-Command -Name 'Set-PSReadLineOption' -All -ErrorAction Stop |
                    Where-Object {
                        $null -ne $_.Module -and
                            [string]::Equals(
                                [IO.Path]::GetFullPath([string]$_.Module.ModuleBase).TrimEnd('\', '/'),
                                $preloadedBase,
                                $pathComparison
                            )
                    } |
                    Select-Object -First 1
                if ($null -eq $preloadedCommand) {
                    throw 'A fresh process is required because the preloaded PSReadLine module does not expose Set-PSReadLineOption.'
                }

                $preloadedCommandAssembly = Get-PshCommandImplementationAssembly -Command $preloadedCommand
                if (-not [string]::Equals(
                        [string]$result.expectedAssemblyHash,
                        [string]$preloadedCommandAssembly.hash,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    $result.actualAssemblyPath = [string]$preloadedCommandAssembly.path
                    $result.actualAssemblyHash = [string]$preloadedCommandAssembly.hash
                    throw ('A fresh process is required because Set-PSReadLineOption uses different implementation bytes: {0}' -f $result.actualAssemblyPath)
                }

                $result.imported = $true
                $result.loadedVersion = [string]$preloadedModule.Version
                $result.loadedPath = [string]$preloadedModule.Path
                $result.loadedModuleBase = $preloadedBase
                $result.loadAction = 'reused-preloaded-identical'
                $result.actualAssemblyPath = [string]$preloadedCommandAssembly.path
                $result.actualAssemblyHash = [string]$preloadedCommandAssembly.hash
                $result.assemblyVerified = $true
                $result.treeVerified = $true
                $result.restartRequired = $false
                if ([string]::Equals(
                        [IO.Path]::GetFullPath([string]$result.expectedAssemblyPath),
                        [IO.Path]::GetFullPath([string]$result.actualAssemblyPath),
                        $pathComparison
                    )) {
                    $result.assemblyVerificationState = 'fixed-path'
                    $result.treeVerificationState = 'fixed-path'
                }
                else {
                    $result.assemblyVerificationState = 'reused-identical'
                    $result.treeVerificationState = 'reused-identical'
                }
                return [PSCustomObject]$result
            }
        }

        $preexistingExpectedModules = @(
            $preexistingModules |
                Where-Object {
                    $candidateBase = [IO.Path]::GetFullPath([string]$_.ModuleBase).TrimEnd('\', '/')
                    [string]::Equals($expectedBase, $candidateBase, $pathComparison)
                }
        )

        if ($ReplaceLoadedConflicts) {
            foreach ($existingModule in $preexistingModules) {
                $existingBase = [IO.Path]::GetFullPath([string]$existingModule.ModuleBase).TrimEnd('\', '/')
                if ([string]::Equals($expectedBase, $existingBase, $pathComparison)) {
                    continue
                }

                $restorePath = Join-Path -Path $existingBase -ChildPath ('{0}.psd1' -f $Name)
                if (-not (Test-Path -LiteralPath $restorePath -PathType Leaf)) {
                    $restorePath = [string]$existingModule.Path
                }
                $record = [PSCustomObject][ordered]@{
                    version    = [string]$existingModule.Version
                    moduleBase = $existingBase
                    path       = $restorePath
                    moduleInfo = $existingModule
                }
                Remove-Module -ModuleInfo $existingModule -Force -ErrorAction Stop
                $removedModules.Add($record)
            }
            $result.removedConflicts = @(
                $removedModules |
                    ForEach-Object {
                        [PSCustomObject][ordered]@{
                            version    = $_.version
                            moduleBase = $_.moduleBase
                            path       = $_.path
                        }
                    }
            )
        }

        $loadedModule = $null
        if ($preexistingExpectedModules.Count -gt 0) {
            foreach ($candidate in $preexistingExpectedModules) {
                if ($candidate.Version -eq $Version) {
                    $loadedModule = $candidate
                    break
                }
            }
            $result.loadAction = 'reused'
        }
        else {
            $importedModules = @(Import-Module `
                -Name $resolvedPath `
                -RequiredVersion $Version `
                -Global `
                -Force `
                -PassThru `
                -ErrorAction Stop `
                -WarningAction SilentlyContinue)
            $introducedExpectedModule = $true
            foreach ($candidate in $importedModules) {
                if ([string]::Equals([string]$candidate.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase) -and
                    $candidate.Version -eq $Version) {
                    $loadedModule = $candidate
                    break
                }
            }
            $result.loadAction = 'imported'
        }
        if ($null -eq $loadedModule) {
            throw ('The fixed {0} {1} manifest did not load the expected module.' -f $Name, $Version)
        }

        $loadedBase = [IO.Path]::GetFullPath([string]$loadedModule.ModuleBase).TrimEnd('\', '/')
        if (-not [string]::Equals($expectedBase, $loadedBase, $pathComparison)) {
            throw ('{0} loaded from an unexpected path: {1}' -f $Name, $loadedBase)
        }

        if ($ReplaceLoadedConflicts) {
            $unexpectedModules = @(
                Get-Module -Name $Name |
                    Where-Object {
                        $candidateBase = [IO.Path]::GetFullPath([string]$_.ModuleBase).TrimEnd('\', '/')
                        -not [string]::Equals($expectedBase, $candidateBase, $pathComparison)
                    }
            )
            if ($unexpectedModules.Count -gt 0) {
                throw ('A conflicting loaded {0} module remained after fixed-path import.' -f $Name)
            }
        }

        if ([string]::Equals($Name, 'PSReadLine', [System.StringComparison]::OrdinalIgnoreCase)) {
            $implementationCommand = Get-Command -Name 'Set-PSReadLineOption' -All -ErrorAction Stop |
                Where-Object {
                    $null -ne $_.Module -and
                        [string]::Equals(
                            [IO.Path]::GetFullPath([string]$_.Module.ModuleBase).TrimEnd('\', '/'),
                            $expectedBase,
                            $pathComparison
                        )
                } |
                Select-Object -First 1
            if ($null -eq $implementationCommand) {
                throw 'Set-PSReadLineOption is unavailable from the fixed PSReadLine module.'
            }

            $implementationAssembly = Get-PshCommandImplementationAssembly -Command $implementationCommand
            $result.actualAssemblyPath = [string]$implementationAssembly.path
            $result.actualAssemblyHash = [string]$implementationAssembly.hash
            if (-not [string]::Equals(
                    [string]$result.expectedAssemblyHash,
                    [string]$result.actualAssemblyHash,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                $result.assemblyVerificationState = 'failed'
                throw ('Set-PSReadLineOption uses different implementation bytes: {0}' -f $result.actualAssemblyPath)
            }

            if ([string]::Equals(
                    [IO.Path]::GetFullPath([string]$result.expectedAssemblyPath),
                    [IO.Path]::GetFullPath([string]$result.actualAssemblyPath),
                    $pathComparison
                )) {
                $result.assemblyVerificationState = 'fixed-path'
            }
            else {
                $result.assemblyVerificationState = 'reused-identical'
            }
            $result.assemblyVerified = $true
            $loadedTreeFingerprint = @(Get-PshDirectoryTreeFingerprint -Root $loadedBase -Description 'The active PSReadLine module tree')
            $result.actualTreeFileCount = $loadedTreeFingerprint.Count
            $result.actualTreeFingerprint = @($loadedTreeFingerprint)
            if (-not (Test-PshDirectoryTreeFingerprintEqual -Left $expectedTreeFingerprint -Right $loadedTreeFingerprint)) {
                throw ('The active PSReadLine module tree changed during fixed-path import: {0}' -f $loadedBase)
            }
            $result.treeVerified = $true
            $result.treeVerificationState = 'fixed-path'
        }

        $result.imported = $true
        $result.loadedVersion = [string]$loadedModule.Version
        $result.loadedPath = [string]$loadedModule.Path
        $result.loadedModuleBase = $loadedBase
    }
    catch {
        $result.error = [string]$_.Exception.Message
        if ($result.assemblyVerificationState -eq 'pending') {
            $result.assemblyVerificationState = 'failed'
        }
        if ($result.treeVerificationState -eq 'pending') {
            $result.treeVerificationState = 'failed'
        }
        if (-not $result.imported -and
            ($introducedExpectedModule -or $removedModules.Count -gt 0)) {
            $restored = New-Object System.Collections.Generic.List[object]
            $restoreErrors = New-Object System.Collections.Generic.List[string]
            if ($introducedExpectedModule) {
                foreach ($fixedModule in @(Get-Module -Name $Name)) {
                    try {
                        $fixedBase = [IO.Path]::GetFullPath([string]$fixedModule.ModuleBase).TrimEnd('\', '/')
                        if ([string]::Equals($expectedBase, $fixedBase, $pathComparison)) {
                            Remove-Module -ModuleInfo $fixedModule -Force -ErrorAction Stop
                        }
                    }
                    catch {
                        $restoreErrors.Add([string]$_.Exception.Message)
                    }
                }
            }
            foreach ($removedModule in $removedModules) {
                try {
                    Import-Module `
                        -ModuleInfo $removedModule.moduleInfo `
                        -Global `
                        -Force `
                        -ErrorAction Stop `
                        -WarningAction SilentlyContinue
                    $restored.Add([PSCustomObject][ordered]@{
                        version    = $removedModule.version
                        moduleBase = $removedModule.moduleBase
                        path       = $removedModule.path
                    })
                }
                catch {
                    $restoreErrors.Add(('{0}: {1}' -f $removedModule.path, [string]$_.Exception.Message))
                }
            }
            $result.restoredConflicts = @($restored.ToArray())
            $result.restorationErrors = @($restoreErrors.ToArray())
        }
    }

    return [PSCustomObject]$result
}

function Set-PshReadLineBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Chord,

        [Parameter(Mandatory = $true)]
        [string]$Function,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedModuleBase,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAssemblyHash
    )

    $result = [ordered]@{
        chord      = $Chord
        'function' = $Function
        configured = $false
        implementationAssemblyPath = $null
        implementationAssemblyHash = $null
        error      = $null
    }

    try {
        $pathComparison = [System.StringComparison]::Ordinal
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $pathComparison = [System.StringComparison]::OrdinalIgnoreCase
        }
        $command = $null
        $assemblyInfo = $null
        foreach ($candidate in @(Get-Command -Name 'Set-PSReadLineKeyHandler' -All -ErrorAction Stop)) {
            if ($null -eq $candidate.Module -or
                -not [string]::Equals(
                    [IO.Path]::GetFullPath([string]$candidate.Module.ModuleBase).TrimEnd('\', '/'),
                    [IO.Path]::GetFullPath($ExpectedModuleBase).TrimEnd('\', '/'),
                    $pathComparison
                )) {
                continue
            }
            try {
                $candidateAssembly = Get-PshCommandImplementationAssembly -Command $candidate
                if ([string]::Equals(
                        [string]$candidateAssembly.hash,
                        $ExpectedAssemblyHash,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    $command = $candidate
                    $assemblyInfo = $candidateAssembly
                    break
                }
            }
            catch {
                continue
            }
        }
        if ($null -eq $command) {
            throw 'Set-PSReadLineKeyHandler is unavailable from the verified PSReadLine assembly.'
        }

        & $command -Chord $Chord -Function $Function -ErrorAction Stop
        $result.configured = $true
        $result.implementationAssemblyPath = [string]$assemblyInfo.path
        $result.implementationAssemblyHash = [string]$assemblyInfo.hash
    }
    catch {
        $result.error = [string]$_.Exception.Message
    }

    return [PSCustomObject]$result
}

function Set-PshReadLinePrediction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$TerminalStatus,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedModuleBase,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAssemblyHash
    )

    $result = [ordered]@{
        requested = $true
        enabled   = $false
        source    = $null
        viewStyle = $null
        reason    = $null
        implementationAssemblyPath = $null
        implementationAssemblyHash = $null
        error     = $null
    }

    if (-not [bool]$TerminalStatus.supported) {
        $result.reason = 'VirtualTerminalUnavailable'
        return [PSCustomObject]$result
    }

    try {
        $pathComparison = [System.StringComparison]::Ordinal
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $pathComparison = [System.StringComparison]::OrdinalIgnoreCase
        }
        $command = $null
        $assemblyInfo = $null
        foreach ($candidate in @(Get-Command -Name 'Set-PSReadLineOption' -All -ErrorAction Stop)) {
            if ($null -eq $candidate.Module -or
                -not [string]::Equals(
                    [IO.Path]::GetFullPath([string]$candidate.Module.ModuleBase).TrimEnd('\', '/'),
                    [IO.Path]::GetFullPath($ExpectedModuleBase).TrimEnd('\', '/'),
                    $pathComparison
                )) {
                continue
            }
            try {
                $candidateAssembly = Get-PshCommandImplementationAssembly -Command $candidate
                if ([string]::Equals(
                        [string]$candidateAssembly.hash,
                        $ExpectedAssemblyHash,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    $command = $candidate
                    $assemblyInfo = $candidateAssembly
                    break
                }
            }
            catch {
                continue
            }
        }
        if ($null -eq $command -or
            -not $command.Parameters.ContainsKey('PredictionSource') -or
            -not $command.Parameters.ContainsKey('PredictionViewStyle')) {
            $result.reason = 'PredictionApiUnavailable'
            return [PSCustomObject]$result
        }

        & $command `
            -PredictionSource History `
            -PredictionViewStyle ListView `
            -ErrorAction Stop `
            -WarningAction SilentlyContinue
        $result.enabled = $true
        $result.source = 'History'
        $result.viewStyle = 'ListView'
        $result.reason = 'Configured'
        $result.implementationAssemblyPath = [string]$assemblyInfo.path
        $result.implementationAssemblyHash = [string]$assemblyInfo.hash
    }
    catch {
        $result.reason = 'ConfigurationFailed'
        $result.error = [string]$_.Exception.Message
    }

    return [PSCustomObject]$result
}

function Initialize-PshInteractive {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$DependencyRoot,

        [AllowNull()]
        [string]$PSReadLinePath,

        [switch]$EnablePrompt,

        [switch]$DisableGitPrompt,

        [ValidateRange(25, 2000)]
        [int]$GitTimeoutMilliseconds = 150
    )

    $errors = @()
    $warnings = @()

    if ([string]::IsNullOrWhiteSpace($DependencyRoot)) {
        $moduleRoot = Split-Path -Path $script:PshInteractiveSourceDirectory -Parent
        $DependencyRoot = Join-Path -Path $moduleRoot -ChildPath 'Dependencies'
    }
    try {
        $DependencyRoot = [IO.Path]::GetFullPath($DependencyRoot)
    }
    catch {
        $errors += ('Dependency root is invalid: {0}' -f $_.Exception.Message)
    }

    $terminalStatus = Get-PshVirtualTerminalStatus
    $psReadLine = Import-PshBundledModule `
        -Name 'PSReadLine' `
        -Version ([version]'2.4.5') `
        -DependencyRoot $DependencyRoot `
        -ExplicitPath $PSReadLinePath `
        -ReplaceLoadedConflicts
    if (-not $psReadLine.imported) {
        $errors += ('PSReadLine: {0}' -f [string]$psReadLine.error)
    }

    $bindings = @()
    $dependenciesReady = [bool]$psReadLine.imported
    if ($dependenciesReady) {
        $bindingSpecifications = @(
            [PSCustomObject]@{ Chord = 'Tab';       Function = 'MenuComplete' }
            [PSCustomObject]@{ Chord = 'Ctrl+r';    Function = 'ReverseSearchHistory' }
            [PSCustomObject]@{ Chord = 'UpArrow';   Function = 'HistorySearchBackward' }
            [PSCustomObject]@{ Chord = 'DownArrow'; Function = 'HistorySearchForward' }
        )
        foreach ($bindingSpecification in $bindingSpecifications) {
            $binding = Set-PshReadLineBinding `
                -Chord $bindingSpecification.Chord `
                -Function $bindingSpecification.Function `
                -ExpectedModuleBase ([string]$psReadLine.loadedModuleBase) `
                -ExpectedAssemblyHash ([string]$psReadLine.expectedAssemblyHash)
            $bindings += $binding
            if (-not $binding.configured) {
                $errors += ('PSReadLine binding {0}: {1}' -f $binding.chord, $binding.error)
            }
        }
        $prediction = Set-PshReadLinePrediction `
            -TerminalStatus $terminalStatus `
            -ExpectedModuleBase ([string]$psReadLine.loadedModuleBase) `
            -ExpectedAssemblyHash ([string]$psReadLine.expectedAssemblyHash)
        if (-not $prediction.enabled) {
            $warning = 'PSReadLine prediction safely degraded: {0}' -f $prediction.reason
            if (-not [string]::IsNullOrWhiteSpace([string]$prediction.error)) {
                $warning = '{0}: {1}' -f $warning, $prediction.error
            }
            $warnings += $warning
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$script:PshGitCompletionSourceLoadError)) {
            $gitCompletion = [PSCustomObject][ordered]@{
                registered        = $false
                alreadyRegistered = $false
                mode              = 'PshOfflineNativeCompleter'
                commandNames      = @('git', 'git.exe')
                gitAvailable      = $false
                gitPath           = $null
                registrar         = $null
                registrationSyntax = $null
                timeoutMs         = $GitTimeoutMilliseconds
                error             = [string]$script:PshGitCompletionSourceLoadError
            }
        }
        else {
            $gitCompletion = Register-PshGitCompletion -TimeoutMilliseconds $GitTimeoutMilliseconds
        }
        if (-not $gitCompletion.registered) {
            $errors += ('Git completion: {0}' -f [string]$gitCompletion.error)
        }

        if ($EnablePrompt) {
            if (-not [string]::IsNullOrWhiteSpace([string]$script:PshPromptSourceLoadError)) {
                $prompt = [PSCustomObject][ordered]@{
                    requested        = $true
                    enabled          = $false
                    replacedExisting = $false
                    style            = 'PlainAscii'
                    gitEnabled       = (-not [bool]$DisableGitPrompt)
                    gitTimeoutMs     = $GitTimeoutMilliseconds
                    error            = [string]$script:PshPromptSourceLoadError
                }
            }
            else {
                $prompt = Set-PshPrompt `
                    -DisableGit:$DisableGitPrompt `
                    -GitExecutablePath ([string]$gitCompletion.gitPath) `
                    -GitTimeoutMilliseconds $GitTimeoutMilliseconds
            }
            if (-not $prompt.enabled) {
                $errors += ('Prompt: {0}' -f [string]$prompt.error)
            }
        }
        else {
            $prompt = [PSCustomObject][ordered]@{
                requested        = $false
                enabled          = $false
                replacedExisting = $false
                style            = 'PlainAscii'
                gitEnabled       = (-not [bool]$DisableGitPrompt)
                gitAvailable     = [bool]$gitCompletion.gitAvailable
                gitTimeoutMs     = $GitTimeoutMilliseconds
                error            = $null
            }
        }
    }
    else {
        $prediction = [PSCustomObject][ordered]@{
            requested = $true
            enabled   = $false
            source    = $null
            viewStyle = $null
            reason    = 'DependencyValidationFailed'
            implementationAssemblyPath = $null
            implementationAssemblyHash = $null
            error     = $null
        }
        $gitCompletion = [PSCustomObject][ordered]@{
            registered        = $false
            alreadyRegistered = $false
            mode              = 'PshOfflineNativeCompleter'
            commandNames      = @('git', 'git.exe')
            gitAvailable      = $false
            gitPath           = $null
            registrar         = $null
            registrationSyntax = $null
            timeoutMs         = $GitTimeoutMilliseconds
            error             = $null
        }
        $prompt = [PSCustomObject][ordered]@{
            requested        = [bool]$EnablePrompt
            enabled          = $false
            replacedExisting = $false
            style            = 'PlainAscii'
            gitEnabled       = (-not [bool]$DisableGitPrompt)
            gitAvailable     = $false
            gitTimeoutMs     = $GitTimeoutMilliseconds
            error            = $null
        }
    }

    $success = ($errors.Count -eq 0)
    return [PSCustomObject][ordered]@{
        schemaVersion  = 1
        component      = 'interactive'
        success        = $success
        dependencyRoot = $DependencyRoot
        powershell     = [PSCustomObject][ordered]@{
            version = [string]$PSVersionTable.PSVersion
            edition = [string]$PSVersionTable.PSEdition
        }
        terminal       = $terminalStatus
        dependencies   = [PSCustomObject][ordered]@{
            psReadLine = $psReadLine
        }
        keyBindings    = @($bindings)
        prediction     = $prediction
        gitCompletion  = $gitCompletion
        prompt         = $prompt
        errors         = @($errors)
        warnings       = @($warnings)
    }
}
