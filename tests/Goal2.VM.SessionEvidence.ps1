# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')]
    [string]$EvidenceId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedVersion,

    [Parameter(Mandatory = $true)]
    [string]$FixturePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-PshVmSessionCondition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Goal 2 VM session evidence failed: $Message"
    }
}

function Get-PshVmSessionNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        return $fullPath.TrimEnd([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ))
    }
    return $fullPath
}

function Test-PshVmSessionPathEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    return [string]::Equals(
        (Get-PshVmSessionNormalizedPath -Path $Left),
        (Get-PshVmSessionNormalizedPath -Path $Right),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-PshVmSessionTreeFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $rootPath = Get-PshVmSessionNormalizedPath -Path $Root
    return @(
        Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force |
            ForEach-Object {
                $relative = $_.FullName.Substring($rootPath.Length).TrimStart('\', '/').Replace('\', '/')
                $hash = [string](Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                '{0}|{1}|{2}' -f $relative, $_.Length, $hash
            } |
            Sort-Object
    )
}

function Get-PshVmSessionPromptEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$PromptScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedBranch
    )

    $promptOutput = @($PromptScriptBlock.Invoke())
    Assert-PshVmSessionCondition ($promptOutput.Count -eq 1) 'The prompt did not return exactly one value.'
    $promptText = [string]$promptOutput[0]
    Assert-PshVmSessionCondition ($promptText.StartsWith('[0] ')) ("The prompt did not report a successful previous command: '{0}'" -f $promptText)
    Assert-PshVmSessionCondition ($promptText.Contains($ExpectedPath)) 'The prompt did not preserve the exact fixture path.'
    Assert-PshVmSessionCondition ($promptText.Contains(("(git:{0})" -f $ExpectedBranch))) 'The prompt did not show the active Git branch.'
    Assert-PshVmSessionCondition ($promptText.IndexOf([char]27) -lt 0) 'The prompt contains an ANSI escape character.'

    return [ordered]@{
        commandType = 'ScriptBlock'
        sourcePath  = [string]$PromptScriptBlock.File
        text        = $promptText
    }
}

function Write-PshVmSessionJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    Assert-PshVmSessionCondition (-not [IO.File]::Exists($Path)) "Evidence file already exists: $Path"
    Assert-PshVmSessionCondition (-not [IO.Directory]::Exists($Path)) "Evidence path is a directory: $Path"
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )

    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    $hasUtf8Bom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    Assert-PshVmSessionCondition (-not $hasUtf8Bom) 'Evidence JSON unexpectedly has a UTF-8 BOM.'
    $roundTrip = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
    Assert-PshVmSessionCondition ([string]$roundTrip.evidenceId -ceq $EvidenceId) 'Evidence JSON did not round-trip with the expected ID.'
}

Assert-PshVmSessionCondition ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'This script must run on Windows.'
Assert-PshVmSessionCondition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) 'LOCALAPPDATA is unavailable.'
Assert-PshVmSessionCondition (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) 'EvidenceRoot is empty.'
Assert-PshVmSessionCondition (-not [string]::IsNullOrWhiteSpace($FixturePath)) 'FixturePath is empty.'

$capturedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
$currentProcess = [Diagnostics.Process]::GetCurrentProcess()
$processPath = [string]$currentProcess.MainModule.FileName
Assert-PshVmSessionCondition ([IO.File]::Exists($processPath)) "PowerShell executable is missing: $processPath"
$processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
Assert-PshVmSessionCondition ($processArchitecture -ceq 'Arm64') "PowerShell is not running natively as ARM64: $processArchitecture"

$edition = [string]$PSVersionTable.PSEdition
Assert-PshVmSessionCondition (@('Desktop', 'Core') -ccontains $edition) "Unexpected PowerShell edition: $edition"
$sessionShellId = if ($edition -ceq 'Desktop') { 'winps51-arm64' } else { 'pwsh7-arm64' }

$policyScopes = @(
    Get-ExecutionPolicy -List |
        ForEach-Object {
            [ordered]@{
                scope  = [string]$_.Scope
                policy = [string]$_.ExecutionPolicy
            }
        }
)
$expectedLocalMachinePolicy = if ($edition -ceq 'Desktop') { 'Undefined' } else { 'RemoteSigned' }
$expectedPolicies = [ordered]@{
    MachinePolicy = 'Undefined'
    UserPolicy    = 'Undefined'
    Process       = 'Undefined'
    CurrentUser   = 'RemoteSigned'
    LocalMachine  = $expectedLocalMachinePolicy
}
foreach ($scope in $expectedPolicies.Keys) {
    $scopeEvidence = @($policyScopes | Where-Object { [string]$_.scope -ceq $scope })
    Assert-PshVmSessionCondition ($scopeEvidence.Count -eq 1) "Execution-policy scope is missing or duplicated: $scope"
    Assert-PshVmSessionCondition ([string]$scopeEvidence[0].policy -ceq [string]$expectedPolicies[$scope]) ("Execution-policy scope {0} is {1}, expected {2}." -f $scope, $scopeEvidence[0].policy, $expectedPolicies[$scope])
}
$effectivePolicy = [string](Get-ExecutionPolicy)
Assert-PshVmSessionCondition ($effectivePolicy -ceq 'RemoteSigned') "Effective execution policy is not RemoteSigned: $effectivePolicy"

$documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
Assert-PshVmSessionCondition (-not [string]::IsNullOrWhiteSpace($documents)) 'The current user Documents path is unavailable.'
$allUsersConfigEvidence = $null
$currentUserConfigEvidence = $null
if ($edition -ceq 'Core') {
    $allUsersConfigPath = Join-Path -Path $PSHOME -ChildPath 'powershell.config.json'
    $currentUserConfigPath = Join-Path -Path (Join-Path -Path $documents -ChildPath 'PowerShell') -ChildPath 'powershell.config.json'
    $expectedAllUsersConfigHash = '98c0e5b6ee17eb8b8f4e4940c2b2528689cec8470db4bde427ad16d90d6a52d4'
    $expectedCurrentUserConfigHash = '07b07a34cba62b4a50e941fa9f568e2719c5573853ec2df77a4314f64c5d9bb2'
    Assert-PshVmSessionCondition ([IO.File]::Exists($allUsersConfigPath)) "The packaged PowerShell 7 configuration is missing: $allUsersConfigPath"
    Assert-PshVmSessionCondition ([IO.File]::Exists($currentUserConfigPath)) "The PowerShell 7 CurrentUser configuration is missing: $currentUserConfigPath"
    $allUsersConfigHash = [string](Get-FileHash -LiteralPath $allUsersConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $currentUserConfigHash = [string](Get-FileHash -LiteralPath $currentUserConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-PshVmSessionCondition ($allUsersConfigHash -ceq $expectedAllUsersConfigHash) 'The packaged PowerShell 7 configuration hash changed.'
    Assert-PshVmSessionCondition ($currentUserConfigHash -ceq $expectedCurrentUserConfigHash) 'The PowerShell 7 CurrentUser configuration hash changed.'
    $allUsersConfigDocument = Get-Content -LiteralPath $allUsersConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $currentUserConfigDocument = Get-Content -LiteralPath $currentUserConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $allUsersPolicyProperty = $allUsersConfigDocument.PSObject.Properties['Microsoft.PowerShell:ExecutionPolicy']
    $currentUserPolicyProperty = $currentUserConfigDocument.PSObject.Properties['Microsoft.PowerShell:ExecutionPolicy']
    Assert-PshVmSessionCondition ($null -ne $allUsersPolicyProperty -and [string]$allUsersPolicyProperty.Value -ceq 'RemoteSigned') 'The packaged PowerShell 7 configuration does not select RemoteSigned.'
    Assert-PshVmSessionCondition ($null -ne $currentUserPolicyProperty -and [string]$currentUserPolicyProperty.Value -ceq 'RemoteSigned') 'The PowerShell 7 CurrentUser configuration does not select RemoteSigned.'
    $allUsersConfigEvidence = [ordered]@{
        path   = $allUsersConfigPath
        sha256 = $allUsersConfigHash
        policy = [string]$allUsersPolicyProperty.Value
    }
    $currentUserConfigEvidence = [ordered]@{
        path   = $currentUserConfigPath
        sha256 = $currentUserConfigHash
        policy = [string]$currentUserPolicyProperty.Value
    }
}

$installRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Psh'
$currentPath = Join-Path -Path $installRoot -ChildPath 'current.json'
Assert-PshVmSessionCondition ([IO.File]::Exists($currentPath)) "current.json is missing: $currentPath"
$currentDocument = Get-Content -LiteralPath $currentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$schemaProperty = $currentDocument.PSObject.Properties['schemaVersion']
$versionProperty = $currentDocument.PSObject.Properties['version']
Assert-PshVmSessionCondition ($null -ne $schemaProperty -and [int]$schemaProperty.Value -eq 1) 'current.json has an unsupported schemaVersion.'
Assert-PshVmSessionCondition ($null -ne $versionProperty -and [string]$versionProperty.Value -ceq $ExpectedVersion) ("current.json selected {0}, expected {1}." -f $versionProperty.Value, $ExpectedVersion)

$expectedVersionRoot = Join-Path -Path (Join-Path -Path $installRoot -ChildPath 'versions') -ChildPath $ExpectedVersion
$expectedPshModuleBase = Join-Path -Path $expectedVersionRoot -ChildPath 'Psh'
$expectedPshManifestPath = Join-Path -Path $expectedPshModuleBase -ChildPath 'Psh.psd1'
$expectedPshModulePath = Join-Path -Path $expectedPshModuleBase -ChildPath 'Psh.psm1'
Assert-PshVmSessionCondition ([IO.File]::Exists($expectedPshManifestPath)) "Expected Psh manifest is missing: $expectedPshManifestPath"

$pshModules = @(Get-Module -Name Psh)
Assert-PshVmSessionCondition ($pshModules.Count -eq 1) 'Psh was not already loaded exactly once by the profile.'
$pshModule = $pshModules[0]
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$pshModule.ModuleBase) -Right $expectedPshModuleBase) 'The loaded Psh module base does not match current.json.'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$pshModule.Path) -Right $expectedPshModulePath) 'The loaded Psh root module path does not match current.json.'

$initializeCommands = @(Get-Command -Name Initialize-PshInteractive -CommandType Function -Module Psh -ErrorAction Stop)
Assert-PshVmSessionCondition ($initializeCommands.Count -eq 1) 'Psh does not expose exactly one Initialize-PshInteractive function.'
$initializeCommand = $initializeCommands[0]

$expectedPsReadLineSourceBase = Join-Path -Path (Join-Path -Path $expectedPshModuleBase -ChildPath 'Dependencies') -ChildPath 'PSReadLine\2.4.5'
$expectedProjectionModuleRoot = if ($edition -ceq 'Desktop') {
    Join-Path -Path $documents -ChildPath 'WindowsPowerShell\Modules'
}
else {
    Join-Path -Path $documents -ChildPath 'PowerShell\Modules'
}
$expectedPsReadLineBase = Join-Path -Path (Join-Path -Path $expectedProjectionModuleRoot -ChildPath 'PSReadLine') -ChildPath '2.4.5'
$expectedPsReadLineAssemblyPath = Join-Path -Path $expectedPsReadLineSourceBase -ChildPath 'Microsoft.PowerShell.PSReadLine.dll'
$expectedActivePsReadLineAssemblyPath = Join-Path -Path $expectedPsReadLineBase -ChildPath 'Microsoft.PowerShell.PSReadLine.dll'
$expectedPsReadLineAssemblyHash = 'f8e3a5b7e3e8cad2130ce10647564a2a0ea15d98db8a0cc8d589f80154c108e2'
Assert-PshVmSessionCondition ([IO.File]::Exists($expectedPsReadLineAssemblyPath)) "Bundled PSReadLine assembly is missing: $expectedPsReadLineAssemblyPath"
Assert-PshVmSessionCondition ([IO.File]::Exists($expectedActivePsReadLineAssemblyPath)) "Projected PSReadLine assembly is missing: $expectedActivePsReadLineAssemblyPath"
Assert-PshVmSessionCondition ([string](Get-FileHash -LiteralPath $expectedPsReadLineAssemblyPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedPsReadLineAssemblyHash) 'The bundled PSReadLine assembly hash is wrong.'
$sourcePsReadLineFingerprint = @(Get-PshVmSessionTreeFingerprint -Root $expectedPsReadLineSourceBase)
$projectedPsReadLineFingerprint = @(Get-PshVmSessionTreeFingerprint -Root $expectedPsReadLineBase)
Assert-PshVmSessionCondition (@(Compare-Object $sourcePsReadLineFingerprint $projectedPsReadLineFingerprint).Count -eq 0) 'The CurrentUser PSReadLine projection differs from the bundled seven-file tree.'

$psReadLineModules = @(Get-Module -Name PSReadLine)
Assert-PshVmSessionCondition ($psReadLineModules.Count -eq 1) 'PSReadLine was not already loaded exactly once by the profile.'
$psReadLineModule = $psReadLineModules[0]
Assert-PshVmSessionCondition ([string]$psReadLineModule.Version -ceq '2.4.5') "The loaded PSReadLine version is not 2.4.5: $($psReadLineModule.Version)"
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$psReadLineModule.ModuleBase) -Right $expectedPsReadLineBase) 'The loaded PSReadLine module is not the fixed bundled copy.'
$psCompletionsModules = @(Get-Module -Name PSCompletions)
Assert-PshVmSessionCondition ($psCompletionsModules.Count -eq 0) 'The profile imported the network-capable PSCompletions original.'
$jobsBeforeWarm = @(Get-Job)
Assert-PshVmSessionCondition ($jobsBeforeWarm.Count -eq 0) 'The profile created a background job before the evidence probe.'

$setOptionCommands = @(Get-Command -Name Set-PSReadLineOption -CommandType Cmdlet -All -ErrorAction Stop)
Assert-PshVmSessionCondition ($setOptionCommands.Count -ge 1) 'Set-PSReadLineOption is unavailable.'
$activeSetOption = $setOptionCommands[0]
Assert-PshVmSessionCondition ($null -ne $activeSetOption.ImplementingType) 'Set-PSReadLineOption has no implementing type.'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$activeSetOption.Module.ModuleBase) -Right $expectedPsReadLineBase) 'Set-PSReadLineOption resolves outside the bundled PSReadLine module.'
$activeAssemblyPath = [IO.Path]::GetFullPath([string]$activeSetOption.ImplementingType.Assembly.Location)
Assert-PshVmSessionCondition ([IO.File]::Exists($activeAssemblyPath)) "The active PSReadLine assembly is missing: $activeAssemblyPath"
$activeAssemblyHash = [string](Get-FileHash -LiteralPath $activeAssemblyPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-PshVmSessionCondition ($activeAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'The active PSReadLine implementation assembly hash is wrong.'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left $activeAssemblyPath -Right $expectedActivePsReadLineAssemblyPath) 'The active PSReadLine implementation assembly is not the CurrentUser projection.'
$assemblyState = if (Test-PshVmSessionPathEqual -Left $activeAssemblyPath -Right $expectedPsReadLineAssemblyPath) {
    'fixed-path'
}
else {
    'reused-identical'
}
Assert-PshVmSessionCondition ($assemblyState -ceq 'reused-identical') 'The interactive host did not preload the CurrentUser PSReadLine projection.'

$loadedPsReadLineAssemblies = @(
    [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { [string]$_.GetName().Name -ceq 'Microsoft.PowerShell.PSReadLine' } |
        ForEach-Object {
            $path = [IO.Path]::GetFullPath([string]$_.Location)
            [ordered]@{
                fullName = [string]$_.FullName
                path     = $path
                sha256   = [string](Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
)
Assert-PshVmSessionCondition ($loadedPsReadLineAssemblies.Count -eq 1) 'The VS Code process contains more than one PSReadLine implementation assembly.'
Assert-PshVmSessionCondition ([string]$loadedPsReadLineAssemblies[0].sha256 -ceq $expectedPsReadLineAssemblyHash) 'The VS Code AppDomain contains different PSReadLine implementation bytes.'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$loadedPsReadLineAssemblies[0].path) -Right $activeAssemblyPath) 'Set-PSReadLineOption and the AppDomain use different PSReadLine assemblies.'

$vscodeStateVariable = Get-Variable -Name '__VSCodeState' -Scope Global -ErrorAction Stop
Assert-PshVmSessionCondition ($null -ne $vscodeStateVariable.Value) 'VS Code shell integration state is unavailable.'
$consoleReadLineFunctions = @(Get-Command -Name PSConsoleHostReadLine -CommandType Function -All -ErrorAction Stop)
$vscodeReadLineWrapper = @(
    $consoleReadLineFunctions |
        Where-Object { [string]$_.Definition -like '*__VSCodeState*' }
)
Assert-PshVmSessionCondition ($vscodeReadLineWrapper.Count -eq 1) 'VS Code did not install exactly one PSConsoleHostReadLine wrapper around the fixed implementation.'
$shellIntegrationPath = [string]$vscodeReadLineWrapper[0].ScriptBlock.File
$expectedShellIntegrationHash = '7d27a8cce8c3b9a7e6cb0045a2035f303c34d228b23b6619fed1934a4027a4db'
Assert-PshVmSessionCondition ([IO.File]::Exists($shellIntegrationPath)) "VS Code shellIntegration.ps1 is missing: $shellIntegrationPath"
$shellIntegrationHash = [string](Get-FileHash -LiteralPath $shellIntegrationPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-PshVmSessionCondition ($shellIntegrationHash -ceq $expectedShellIntegrationHash) 'VS Code shellIntegration.ps1 changed from the accepted 1.126.0 build.'
$vscodeState = $vscodeStateVariable.Value
Assert-PshVmSessionCondition ($vscodeState -is [Collections.IDictionary]) 'VS Code shell integration state has an unexpected type.'
$vscodeOriginalPrompt = $vscodeState['OriginalPrompt']
Assert-PshVmSessionCondition ($vscodeOriginalPrompt -is [scriptblock]) 'VS Code did not retain the original Psh prompt script block.'
$expectedPshPromptSourcePath = Join-Path -Path $expectedPshModuleBase -ChildPath 'Interactive\Prompt.ps1'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$vscodeOriginalPrompt.File) -Right $expectedPshPromptSourcePath) 'VS Code retained a prompt from outside the selected Psh version.'
$promptFunctions = @(Get-Command -Name prompt -CommandType Function -All -ErrorAction Stop)
$vscodePromptWrapper = @(
    $promptFunctions |
        Where-Object { [string]$_.Definition -like '*__VSCodeState.OriginalPrompt*' }
)
Assert-PshVmSessionCondition ($vscodePromptWrapper.Count -eq 1) 'VS Code did not install exactly one prompt wrapper around the Psh prompt.'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$vscodePromptWrapper[0].ScriptBlock.File) -Right $shellIntegrationPath) 'The active VS Code prompt wrapper came from a different script.'

$expectedBindings = [ordered]@{
    Tab       = 'MenuComplete'
    'Ctrl+r'  = 'ReverseSearchHistory'
    UpArrow   = 'HistorySearchBackward'
    DownArrow = 'HistorySearchForward'
}
$bindingEvidence = @(
    foreach ($chord in $expectedBindings.Keys) {
        $handlers = @(Get-PSReadLineKeyHandler -Chord $chord -ErrorAction Stop)
        Assert-PshVmSessionCondition ($handlers.Count -eq 1) "PSReadLine handler is missing or duplicated: $chord"
        Assert-PshVmSessionCondition ([string]$handlers[0].Function -ceq [string]$expectedBindings[$chord]) ("PSReadLine handler {0} is {1}, expected {2}." -f $chord, $handlers[0].Function, $expectedBindings[$chord])
        [ordered]@{
            chord       = $chord
            key         = [string]$handlers[0].Key
            function    = [string]$handlers[0].Function
            description = [string]$handlers[0].Description
        }
    }
)

$readLineOption = Get-PSReadLineOption -ErrorAction Stop
Assert-PshVmSessionCondition ([string]$readLineOption.PredictionSource -ceq 'History') "PredictionSource is not History: $($readLineOption.PredictionSource)"
Assert-PshVmSessionCondition ([string]$readLineOption.PredictionViewStyle -ceq 'ListView') "PredictionViewStyle is not ListView: $($readLineOption.PredictionViewStyle)"

$profilePaths = @(
    (Join-Path -Path (Join-Path -Path $documents -ChildPath 'WindowsPowerShell') -ChildPath 'profile.ps1'),
    (Join-Path -Path (Join-Path -Path $documents -ChildPath 'PowerShell') -ChildPath 'profile.ps1')
)
$profileStartMarker = '# >>> Psh managed profile >>>'
$profileEndMarker = '# <<< Psh managed profile <<<'
$profileEvidence = @(
    foreach ($profilePath in $profilePaths) {
        Assert-PshVmSessionCondition ([IO.File]::Exists($profilePath)) "Managed profile is missing: $profilePath"
        $profileText = [IO.File]::ReadAllText($profilePath)
        [string[]]$profileLines = @($profileText -split "`r`n|`n|`r")
        $startCount = @($profileLines | Where-Object { $_ -ceq $profileStartMarker }).Count
        $endCount = @($profileLines | Where-Object { $_ -ceq $profileEndMarker }).Count
        $startOccurrenceCount = ([regex]::Matches($profileText, [regex]::Escape($profileStartMarker))).Count
        $endOccurrenceCount = ([regex]::Matches($profileText, [regex]::Escape($profileEndMarker))).Count
        Assert-PshVmSessionCondition ($startCount -eq 1 -and $startOccurrenceCount -eq 1) "The start marker is not one exact line in profile: $profilePath"
        Assert-PshVmSessionCondition ($endCount -eq 1 -and $endOccurrenceCount -eq 1) "The end marker is not one exact line in profile: $profilePath"
        $startIndex = [Array]::IndexOf($profileLines, $profileStartMarker)
        $endIndex = [Array]::IndexOf($profileLines, $profileEndMarker)
        Assert-PshVmSessionCondition ($startIndex -lt $endIndex) "Managed profile markers are reversed: $profilePath"
        [ordered]@{
            path       = $profilePath
            sha256     = [string](Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
            startCount = $startCount
            endCount   = $endCount
            startLine  = $startIndex + 1
            endLine    = $endIndex + 1
        }
    }
)
$activeProfilePath = [string]$PROFILE.CurrentUserAllHosts
$expectedActiveProfilePath = if ($edition -ceq 'Desktop') { $profilePaths[0] } else { $profilePaths[1] }
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left $activeProfilePath -Right $expectedActiveProfilePath) 'CurrentUserAllHosts does not resolve to the expected profile for this edition.'

$fixtureRoot = Get-PshVmSessionNormalizedPath -Path $FixturePath
Assert-PshVmSessionCondition ([IO.Directory]::Exists($fixtureRoot)) "Fixture directory is missing: $fixtureRoot"
Assert-PshVmSessionCondition ($fixtureRoot.IndexOf(' ') -ge 0) 'Fixture path does not contain a space.'
Assert-PshVmSessionCondition ([regex]::IsMatch($fixtureRoot, '[\u3400-\u4DBF\u4E00-\u9FFF]')) 'Fixture path does not contain a CJK character.'
$location = Get-Location
Assert-PshVmSessionCondition ([string]$location.Provider.Name -ceq 'FileSystem') 'The current location is not in the FileSystem provider.'
$currentWorkingDirectory = [string]$location.ProviderPath
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left $currentWorkingDirectory -Right $fixtureRoot) 'The current working directory is not the fixture path.'

$gitCommands = @(Get-Command -Name git -CommandType Application -All -ErrorAction Stop)
Assert-PshVmSessionCondition ($gitCommands.Count -ge 1) 'Git is unavailable.'
$gitCommand = $gitCommands[0]
$gitPath = [string]$gitCommand.Source
if ([string]::IsNullOrWhiteSpace($gitPath)) {
    $gitPath = [string]$gitCommand.Path
}
Assert-PshVmSessionCondition ([IO.File]::Exists($gitPath)) "Git executable is missing: $gitPath"

$originalConsoleOutputEncoding = [Console]::OutputEncoding
try {
    # Git for Windows emits path data as UTF-8. WinPS otherwise decodes
    # redirected native output with the active legacy console code page.
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

    $gitVersionOutput = @(& $gitPath --version 2>&1)
    $gitVersionExitCode = $LASTEXITCODE
    Assert-PshVmSessionCondition ($gitVersionExitCode -eq 0 -and $gitVersionOutput.Count -eq 1) 'git --version failed or returned unexpected output.'
    $gitVersion = [string]$gitVersionOutput[0]
    Assert-PshVmSessionCondition ($gitVersion -like 'git version *') "Unexpected Git version output: $gitVersion"

    $gitRootOutput = @(& $gitPath -C $fixtureRoot rev-parse --show-toplevel 2>&1)
    $gitRootExitCode = $LASTEXITCODE
    Assert-PshVmSessionCondition ($gitRootExitCode -eq 0 -and $gitRootOutput.Count -eq 1) 'The fixture is not a Git work tree.'
    Assert-PshVmSessionCondition `
        (Test-PshVmSessionPathEqual -Left ([string]$gitRootOutput[0]) -Right $fixtureRoot) `
        ("The fixture resolves to a different Git work-tree root: expected '{0}', actual '{1}'." -f $fixtureRoot, [string]$gitRootOutput[0])

    $branchOutput = @(& $gitPath -C $fixtureRoot for-each-ref '--format=%(refname:short)' refs/heads 2>&1)
    $branchExitCode = $LASTEXITCODE
    Assert-PshVmSessionCondition ($branchExitCode -eq 0) 'Git branch enumeration failed.'
    $branches = @($branchOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-PshVmSessionCondition ($branches -ccontains 'main') 'The fixture has no main branch.'
    Assert-PshVmSessionCondition ($branches -ccontains 'feature/vscode-acceptance') 'The fixture has no feature/vscode-acceptance branch.'

    $activeBranchOutput = @(& $gitPath -C $fixtureRoot symbolic-ref --short HEAD 2>&1)
    $activeBranchExitCode = $LASTEXITCODE
    Assert-PshVmSessionCondition ($activeBranchExitCode -eq 0 -and $activeBranchOutput.Count -eq 1) 'The fixture has no active local branch.'
    $activeBranch = [string]$activeBranchOutput[0]
}
finally {
    [Console]::OutputEncoding = $originalConsoleOutputEncoding
}

$promptBeforeWarm = Get-PshVmSessionPromptEvidence `
    -PromptScriptBlock ([scriptblock]$vscodeOriginalPrompt) `
    -ExpectedPath ([string]$location.Path) `
    -ExpectedBranch $activeBranch

$warmOutput = @(& $initializeCommand -EnablePrompt)
Assert-PshVmSessionCondition ($warmOutput.Count -eq 1) 'Warm initialization emitted output besides its diagnostic object.'
$warmDiagnostic = $warmOutput[0]
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.success) ("Warm initialization failed: {0}" -f (@($warmDiagnostic.errors) -join '; '))
Assert-PshVmSessionCondition (@($warmDiagnostic.errors).Count -eq 0) 'Warm initialization reported errors.'
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.terminal.supported) ("VS Code terminal support was not detected: {0}" -f $warmDiagnostic.terminal.reason)
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.dependencies.psReadLine.imported) 'Warm initialization did not retain PSReadLine.'
Assert-PshVmSessionCondition ([string]$warmDiagnostic.dependencies.psReadLine.loadedVersion -ceq '2.4.5') 'Warm initialization reported the wrong PSReadLine version.'
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.dependencies.psReadLine.assemblyVerified) 'Warm initialization did not verify the PSReadLine assembly.'
Assert-PshVmSessionCondition (@('fixed-path', 'reused-identical') -ccontains [string]$warmDiagnostic.dependencies.psReadLine.assemblyVerificationState) 'Warm initialization reported an invalid PSReadLine assembly state.'
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.dependencies.psReadLine.treeVerified) 'Warm initialization did not verify the complete PSReadLine tree.'
Assert-PshVmSessionCondition ([string]$warmDiagnostic.dependencies.psReadLine.treeVerificationState -ceq 'reused-identical') 'Warm initialization reported the wrong projected-tree state.'
Assert-PshVmSessionCondition ([int]$warmDiagnostic.dependencies.psReadLine.expectedTreeFileCount -eq 7 -and [int]$warmDiagnostic.dependencies.psReadLine.actualTreeFileCount -eq 7) 'Warm initialization did not compare two seven-file PSReadLine trees.'
Assert-PshVmSessionCondition ([string]$warmDiagnostic.dependencies.psReadLine.actualAssemblyHash -ceq $expectedPsReadLineAssemblyHash) 'Warm initialization reported the wrong PSReadLine implementation hash.'
Assert-PshVmSessionCondition ([string]$warmDiagnostic.dependencies.psReadLine.loadAction -ceq 'reused-preloaded-identical') 'Warm initialization did not reuse the preloaded CurrentUser projection in place.'
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.dependencies.psReadLine.mutationSuppressed) 'Warm initialization did not suppress PSReadLine module replacement.'
Assert-PshVmSessionCondition (-not [bool]$warmDiagnostic.dependencies.psReadLine.restartRequired) 'Warm initialization unexpectedly requires a fresh process.'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$warmDiagnostic.dependencies.psReadLine.loadedModuleBase) -Right $expectedPsReadLineBase) 'Warm initialization reported a different PSReadLine module base.'
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.prediction.enabled) 'Warm initialization did not enable prediction.'
Assert-PshVmSessionCondition ([string]$warmDiagnostic.prediction.source -ceq 'History') 'Warm initialization did not select History prediction.'
Assert-PshVmSessionCondition ([string]$warmDiagnostic.prediction.viewStyle -ceq 'ListView') 'Warm initialization did not select ListView prediction.'
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.prompt.enabled) ("Warm initialization did not enable the prompt: {0}" -f $warmDiagnostic.prompt.error)
Assert-PshVmSessionCondition ([string]$warmDiagnostic.prompt.style -ceq 'PlainAscii') 'Warm initialization did not select the PlainAscii prompt.'
Assert-PshVmSessionCondition ([bool]$warmDiagnostic.gitCompletion.registered) ("Warm initialization did not register Git completion: {0}" -f $warmDiagnostic.gitCompletion.error)
Assert-PshVmSessionCondition ([string]$warmDiagnostic.gitCompletion.mode -ceq 'PshOfflineNativeCompleter') 'Warm initialization selected the wrong Git completer.'
Assert-PshVmSessionCondition ([string]$warmDiagnostic.gitCompletion.registrar -ceq 'NativeArgumentCompleter') 'Warm initialization did not use the native argument-completer registry.'
Assert-PshVmSessionCondition (Test-PshVmSessionPathEqual -Left ([string]$warmDiagnostic.gitCompletion.gitPath) -Right $gitPath) 'Warm initialization registered a different Git executable.'

$postWarmPsReadLineModules = @(Get-Module -Name PSReadLine)
Assert-PshVmSessionCondition ($postWarmPsReadLineModules.Count -eq 1) 'Warm initialization left multiple PSReadLine modules loaded.'
$postWarmPsCompletionsModules = @(Get-Module -Name PSCompletions)
Assert-PshVmSessionCondition ($postWarmPsCompletionsModules.Count -eq 0) 'Warm initialization imported the network-capable PSCompletions original.'
$jobsAfterWarm = @(Get-Job)
Assert-PshVmSessionCondition ($jobsAfterWarm.Count -eq 0) 'Warm initialization created a background job.'
$postWarmPromptCommand = Get-Command -Name prompt -CommandType Function -ErrorAction Stop
$promptAfterWarm = Get-PshVmSessionPromptEvidence `
    -PromptScriptBlock $postWarmPromptCommand.ScriptBlock `
    -ExpectedPath ([string]$location.Path) `
    -ExpectedBranch $activeBranch

$sessionEvidence = [ordered]@{
    schemaVersion      = 1
    evidenceId         = $EvidenceId
    capturedAtUtc      = $capturedAtUtc
    expectedVersion    = $ExpectedVersion
    process            = [ordered]@{
        pid           = $PID
        executable    = $processPath
        version       = $PSVersionTable.PSVersion.ToString()
        edition       = $edition
        architecture  = $processArchitecture
        shellId       = $sessionShellId
        hostName      = [string]$Host.Name
        term          = [string]$env:TERM
        termProgram   = [string]$env:TERM_PROGRAM
    }
    executionPolicy    = [ordered]@{
        effective      = $effectivePolicy
        scopes         = $policyScopes
        allUsersConfig = $allUsersConfigEvidence
        currentUserConfig = $currentUserConfigEvidence
    }
    install            = [ordered]@{
        root        = $installRoot
        currentPath = $currentPath
        currentHash = [string](Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        current     = $currentDocument
        psh         = [ordered]@{
            name         = [string]$pshModule.Name
            version      = [string]$pshModule.Version
            moduleBase   = [string]$pshModule.ModuleBase
            modulePath   = [string]$pshModule.Path
            manifestPath = $expectedPshManifestPath
        }
    }
    psReadLine         = [ordered]@{
        moduleCount          = $psReadLineModules.Count
        name                 = [string]$psReadLineModule.Name
        version              = [string]$psReadLineModule.Version
        moduleBase           = [string]$psReadLineModule.ModuleBase
        modulePath           = [string]$psReadLineModule.Path
        bundledModuleBase    = $expectedPsReadLineSourceBase
        projectedTree        = $projectedPsReadLineFingerprint
        implementingDllPath  = $activeAssemblyPath
        implementingDllHash  = $activeAssemblyHash
        assemblyState        = $assemblyState
        handlers             = $bindingEvidence
        prediction           = [ordered]@{
            source    = [string]$readLineOption.PredictionSource
            viewStyle = [string]$readLineOption.PredictionViewStyle
        }
        psCompletionsCount   = $psCompletionsModules.Count
        jobCountBeforeWarm   = $jobsBeforeWarm.Count
        jobCountAfterWarm    = $jobsAfterWarm.Count
        appDomainAssemblies  = $loadedPsReadLineAssemblies
        vscodeWrapper        = [ordered]@{
            functionCount         = $consoleReadLineFunctions.Count
            promptFunctionCount   = $promptFunctions.Count
            shellIntegrationPath  = $shellIntegrationPath
            shellIntegrationHash  = $shellIntegrationHash
            originalPromptPath    = [string]$vscodeOriginalPrompt.File
            stateType             = [string]$vscodeStateVariable.Value.GetType().FullName
        }
    }
    warmInitialization = $warmDiagnostic
    profiles           = [ordered]@{
        activeCurrentUserAllHosts = $activeProfilePath
        targets                   = $profileEvidence
    }
    git                = [ordered]@{
        path         = $gitPath
        version      = $gitVersion
        workTreeRoot = [string]$gitRootOutput[0]
        activeBranch = $activeBranch
        branches     = $branches
    }
    session            = [ordered]@{
        fixturePath     = $fixtureRoot
        cwdPath         = [string]$location.Path
        cwdProviderPath = $currentWorkingDirectory
        promptBeforeWarm = $promptBeforeWarm
        promptAfterWarm  = $promptAfterWarm
    }
}

$evidenceRootPath = Get-PshVmSessionNormalizedPath -Path $EvidenceRoot
if ([IO.File]::Exists($evidenceRootPath)) {
    throw "Goal 2 VM session evidence failed: EvidenceRoot is a file: $evidenceRootPath"
}
[IO.Directory]::CreateDirectory($evidenceRootPath) | Out-Null
$evidencePath = Join-Path -Path $evidenceRootPath -ChildPath ("{0}-{1}-session.json" -f $EvidenceId, $sessionShellId)
Write-PshVmSessionJson -Path $evidencePath -Value $sessionEvidence

Write-Output ("PSH_GOAL2_VM_SESSION_OK {0} {1}" -f $EvidenceId, $sessionShellId)
