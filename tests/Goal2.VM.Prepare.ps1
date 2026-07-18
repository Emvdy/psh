# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[0-9a-f]{40}\z')]
    [string]$SourceCommit,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A0\.1\.0-vm\.[0-9a-f]{8}\z')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$GitPath,

    [Parameter(Mandatory = $true)]
    [string]$PwshPath,

    [Parameter(Mandatory = $true)]
    [string]$CodePath,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-PshVmCondition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Goal 2 VM preparation failed: $Message"
    }
}

function Get-PshVmTreeFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
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

function Get-PshVmPeMachine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshVmCondition ($bytes.Length -ge 64) "PE image is too short: $Path"
    $peOffset = [BitConverter]::ToInt32($bytes, 60)
    Assert-PshVmCondition ($peOffset -ge 0 -and ($peOffset + 6) -le $bytes.Length) "PE header is invalid: $Path"
    return ('{0:X4}' -f [BitConverter]::ToUInt16($bytes, $peOffset + 4))
}

function Write-PshVmUtf8Json {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-PshVmChildAcceptance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$LogRoot
    )

    $output = @(
        & $Executable `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $ScriptPath `
            -RepositoryRoot $Root 2>&1
    )
    $exitCode = $LASTEXITCODE
    $logPath = Join-Path $LogRoot ("goal2-{0}.log" -f $Name)
    [IO.File]::WriteAllLines(
        $logPath,
        @($output | ForEach-Object { [string]$_ }),
        (New-Object Text.UTF8Encoding($false))
    )
    Assert-PshVmCondition ($exitCode -eq 0) ("{0} Goal 2 acceptance exited {1}; see {2}" -f $Name, $exitCode, $logPath)
    Assert-PshVmCondition (@($output | Where-Object { [string]$_ -like 'Goal 2 acceptance passed:*' }).Count -eq 1) "$Name did not report the Goal 2 success sentinel."
    return $logPath
}

function Invoke-PshVmGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $output = @(& $Executable @ArgumentList 2>&1)
    Assert-PshVmCondition ($LASTEXITCODE -eq 0) ("git {0} failed: {1}" -f ($ArgumentList -join ' '), ($output -join ' '))
    return @($output)
}

function Invoke-PshVmProfileStartupProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$LogRoot
    )

    $probeCommand = @'
$ErrorActionPreference = 'Stop'
$psh = @(Get-Module -Name Psh)
$psReadLine = @(Get-Module -Name PSReadLine)
$psCompletions = @(Get-Module -Name PSCompletions)
$jobs = @(Get-Job)
[ordered]@{
    pshCount = $psh.Count
    pshModuleBase = if ($psh.Count -eq 1) { [string]$psh[0].ModuleBase } else { $null }
    psReadLineCount = $psReadLine.Count
    psReadLineVersion = if ($psReadLine.Count -eq 1) { [string]$psReadLine[0].Version } else { $null }
    psCompletionsCount = $psCompletions.Count
    jobCount = $jobs.Count
    profile = [string]$PROFILE.CurrentUserAllHosts
} | ConvertTo-Json -Depth 5 -Compress
'@
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& $Executable -NoLogo -NonInteractive -Command $probeCommand 2>&1)
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()
    $durationMilliseconds = [long]$stopwatch.ElapsedMilliseconds
    $logPath = Join-Path -Path $LogRoot -ChildPath ("startup-{0}.log" -f $Name)
    [IO.File]::WriteAllLines(
        $logPath,
        @($output | ForEach-Object { [string]$_ }),
        (New-Object Text.UTF8Encoding($false))
    )

    Assert-PshVmCondition ($exitCode -eq 0) ("{0} profile startup exited {1}; see {2}" -f $Name, $exitCode, $logPath)
    Assert-PshVmCondition ($output.Count -eq 1) ("{0} profile startup emitted unexpected output; see {1}" -f $Name, $logPath)
    $probe = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    Assert-PshVmCondition ([int]$probe.pshCount -eq 1) "$Name did not load Psh exactly once from the profile."
    Assert-PshVmCondition ([int]$probe.psReadLineCount -eq 1 -and [string]$probe.psReadLineVersion -ceq '2.4.5') "$Name did not load fixed PSReadLine 2.4.5 exactly once."
    Assert-PshVmCondition ([int]$probe.psCompletionsCount -eq 0) "$Name imported the network-capable PSCompletions original."
    Assert-PshVmCondition ([int]$probe.jobCount -eq 0) "$Name created a background job during profile startup."
    Assert-PshVmCondition ($durationMilliseconds -lt 5000) "$Name profile startup took ${durationMilliseconds}ms, exceeding 5000ms."

    return [ordered]@{
        durationMilliseconds = $durationMilliseconds
        exitCode             = $exitCode
        log                  = $logPath
        probe                = $probe
    }
}

Assert-PshVmCondition ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'This script must run on Windows.'
Assert-PshVmCondition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) 'LOCALAPPDATA is unavailable.'
Assert-PshVmCondition ([IO.Directory]::Exists($RepositoryRoot)) "Repository root is missing: $RepositoryRoot"
foreach ($path in @($GitPath, $PwshPath, $CodePath)) {
    Assert-PshVmCondition ([IO.File]::Exists($path)) "Required executable is missing: $path"
}

$processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
Assert-PshVmCondition ($processArchitecture -ceq 'Arm64') "Windows PowerShell is not running natively as ARM64: $processArchitecture"
Assert-PshVmCondition ((Get-ExecutionPolicy -Scope MachinePolicy) -ceq 'Undefined') 'MachinePolicy controls Windows PowerShell.'
Assert-PshVmCondition ((Get-ExecutionPolicy -Scope UserPolicy) -ceq 'Undefined') 'UserPolicy controls Windows PowerShell.'
Assert-PshVmCondition ((Get-ExecutionPolicy -Scope Process) -ceq 'Undefined') 'Process execution policy was overridden.'
Assert-PshVmCondition ((Get-ExecutionPolicy -Scope CurrentUser) -ceq 'RemoteSigned') 'Windows PowerShell CurrentUser is not RemoteSigned.'
Assert-PshVmCondition ((Get-ExecutionPolicy -Scope LocalMachine) -ceq 'Undefined') 'Windows PowerShell LocalMachine changed from Undefined.'
foreach ($policyPath in @(
    'HKCU:\Software\Policies\Microsoft\Windows\PowerShell',
    'HKLM:\Software\Policies\Microsoft\Windows\PowerShell',
    'HKCU:\Software\Policies\Microsoft\PowerShellCore',
    'HKLM:\Software\Policies\Microsoft\PowerShellCore'
)) {
    Assert-PshVmCondition (-not (Test-Path -LiteralPath $policyPath)) "A Group Policy key exists: $policyPath"
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = @($machinePath, $userPath) -join [IO.Path]::PathSeparator
Assert-PshVmCondition ($null -ne (Get-Command git.exe -CommandType Application -ErrorAction Ignore)) 'A fresh process PATH does not resolve Git.'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-PshVmCondition (-not $isElevated) 'VM preparation must run without an elevated administrator token.'

$gitVersionOutput = @(& $GitPath --version 2>&1)
Assert-PshVmCondition ($LASTEXITCODE -eq 0 -and $gitVersionOutput.Count -eq 1 -and [string]$gitVersionOutput[0] -ceq 'git version 2.55.0.windows.3') 'The official Git for Windows version is not 2.55.0.windows.3.'
$gitVersion = [string]$gitVersionOutput[0]
$gitMachine = Get-PshVmPeMachine -Path $GitPath
Assert-PshVmCondition ($gitMachine -ceq 'AA64') "Git for Windows is not ARM64: $gitMachine"

$codeVersion = @(& $CodePath --version 2>&1)
Assert-PshVmCondition ($LASTEXITCODE -eq 0 -and $codeVersion.Count -eq 3) 'VS Code did not return its version, commit, and architecture.'
Assert-PshVmCondition ([string]$codeVersion[0] -ceq '1.126.0' -and [string]$codeVersion[2] -ceq 'arm64') 'VS Code is not the expected 1.126.0 ARM64 build.'
$codeExtensions = @(& $CodePath --list-extensions --show-versions 2>&1)
Assert-PshVmCondition ($LASTEXITCODE -eq 0) 'VS Code extension enumeration failed.'
Assert-PshVmCondition (@($codeExtensions | Where-Object { [string]$_ -ceq 'ms-vscode.powershell@2025.4.0' }).Count -eq 1) 'The official PowerShell VS Code extension 2025.4.0 is missing or duplicated.'
$codeExePath = [IO.Path]::Combine($env:LOCALAPPDATA, 'Programs', 'Microsoft VS Code', 'Code.exe')
Assert-PshVmCondition ([IO.File]::Exists($codeExePath)) "VS Code executable is missing: $codeExePath"
$codeMachine = Get-PshVmPeMachine -Path $codeExePath
Assert-PshVmCondition ($codeMachine -ceq 'AA64') "VS Code is not ARM64: $codeMachine"

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
Assert-PshVmCondition (-not $repositoryRootPath.StartsWith('\\')) 'Repository scripts must be copied to a local path before execution.'
$sourceHead = @(Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $repositoryRootPath, 'rev-parse', '--verify', 'HEAD'))
Assert-PshVmCondition ($sourceHead.Count -eq 1 -and [string]$sourceHead[0] -ceq $SourceCommit) 'The local VM checkout does not match SourceCommit.'
$sourceStatus = @(Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $repositoryRootPath, 'status', '--porcelain=v1', '--untracked-files=all'))
Assert-PshVmCondition ($sourceStatus.Count -eq 0) 'The local VM checkout is not clean.'
$dependencyVerifier = Join-Path $repositoryRootPath 'scripts/Test-InteractiveDependencies.ps1'
$goal2Acceptance = Join-Path $repositoryRootPath 'tests/Goal2.Acceptance.ps1'
$sourceModuleRoot = Join-Path $repositoryRootPath 'src/Psh'
$sourceBootstrap = Join-Path $repositoryRootPath 'src/install/bootstrap.ps1'
$sourceConfig = Join-Path $repositoryRootPath 'src/install/config.psd1'
$versionSetter = Join-Path $repositoryRootPath 'src/install/Set-PshCurrentVersion.ps1'
$profileInstaller = Join-Path $repositoryRootPath 'src/profile/Install-PshProfile.ps1'
foreach ($requiredPath in @(
    $dependencyVerifier,
    $goal2Acceptance,
    (Join-Path $sourceModuleRoot 'Psh.psd1'),
    $sourceBootstrap,
    $sourceConfig,
    $versionSetter,
    $profileInstaller
)) {
    Assert-PshVmCondition ([IO.File]::Exists($requiredPath)) "Required repository file is missing: $requiredPath"
}
$zoneStreams = @(
    Get-ChildItem -LiteralPath $repositoryRootPath -Recurse -File -Force |
        ForEach-Object {
            Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction Ignore
        }
)
Assert-PshVmCondition ($zoneStreams.Count -eq 0) 'The local VM source contains Zone.Identifier streams.'

$ps7AuditCommand = @'
$allUsersConfigPath = Join-Path -Path $PSHOME -ChildPath 'powershell.config.json'
$documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
$currentUserConfigPath = Join-Path -Path (Join-Path -Path $documents -ChildPath 'PowerShell') -ChildPath 'powershell.config.json'
[ordered]@{
    version = $PSVersionTable.PSVersion.ToString()
    architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    policies = @(Get-ExecutionPolicy -List | ForEach-Object {
        [ordered]@{
            scope = [string]$_.Scope
            policy = [string]$_.ExecutionPolicy
        }
    })
    allUsersConfig = [ordered]@{
        path = $allUsersConfigPath
        sha256 = [string](Get-FileHash -LiteralPath $allUsersConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
        document = Get-Content -LiteralPath $allUsersConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    currentUserConfig = [ordered]@{
        path = $currentUserConfigPath
        sha256 = [string](Get-FileHash -LiteralPath $currentUserConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
        document = Get-Content -LiteralPath $currentUserConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
} | ConvertTo-Json -Depth 8 -Compress
'@
$ps7PolicyOutput = @(
    & $PwshPath `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -Command $ps7AuditCommand 2>&1
)
Assert-PshVmCondition ($LASTEXITCODE -eq 0) ("PowerShell 7 policy audit failed: {0}" -f ($ps7PolicyOutput -join ' '))
$ps7Audit = [string]$ps7PolicyOutput[$ps7PolicyOutput.Count - 1] | ConvertFrom-Json -ErrorAction Stop
$ps7Policies = @($ps7Audit.policies)
Assert-PshVmCondition ([string]$ps7Audit.version -ceq '7.6.3') 'PowerShell 7 is not version 7.6.3.'
Assert-PshVmCondition ([string]$ps7Audit.architecture -ceq 'Arm64') 'PowerShell 7 is not running natively as ARM64.'
foreach ($requiredPolicy in @(
    [PSCustomObject]@{ Scope = 'MachinePolicy'; Policy = 'Undefined' },
    [PSCustomObject]@{ Scope = 'UserPolicy'; Policy = 'Undefined' },
    [PSCustomObject]@{ Scope = 'Process'; Policy = 'Undefined' },
    [PSCustomObject]@{ Scope = 'CurrentUser'; Policy = 'RemoteSigned' },
    [PSCustomObject]@{ Scope = 'LocalMachine'; Policy = 'RemoteSigned' }
)) {
    $actualPolicy = @($ps7Policies | Where-Object { [string]$_.scope -ceq $requiredPolicy.Scope })
    Assert-PshVmCondition ($actualPolicy.Count -eq 1 -and [string]$actualPolicy[0].policy -ceq $requiredPolicy.Policy) ("PowerShell 7 {0} policy is not {1}." -f $requiredPolicy.Scope, $requiredPolicy.Policy)
}
Assert-PshVmCondition (@($ps7Policies | Where-Object { [string]$_.policy -ceq 'Bypass' }).Count -eq 0) 'PowerShell 7 has a Bypass policy scope.'
$expectedPs7AllUsersConfigHash = '98c0e5b6ee17eb8b8f4e4940c2b2528689cec8470db4bde427ad16d90d6a52d4'
$expectedPs7CurrentUserConfigHash = '07b07a34cba62b4a50e941fa9f568e2719c5573853ec2df77a4314f64c5d9bb2'
Assert-PshVmCondition ([string]$ps7Audit.allUsersConfig.sha256 -ceq $expectedPs7AllUsersConfigHash) 'The packaged PowerShell 7 configuration hash changed.'
Assert-PshVmCondition ([string]$ps7Audit.currentUserConfig.sha256 -ceq $expectedPs7CurrentUserConfigHash) 'The PowerShell 7 CurrentUser configuration hash changed.'
Assert-PshVmCondition ([string]$ps7Audit.allUsersConfig.document.'Microsoft.PowerShell:ExecutionPolicy' -ceq 'RemoteSigned') 'The packaged PowerShell 7 configuration does not select RemoteSigned.'
Assert-PshVmCondition ([string]$ps7Audit.currentUserConfig.document.'Microsoft.PowerShell:ExecutionPolicy' -ceq 'RemoteSigned') 'The PowerShell 7 CurrentUser configuration does not select RemoteSigned.'

$evidenceRootPath = [IO.Path]::GetFullPath($EvidenceRoot)
Assert-PshVmCondition (-not [IO.File]::Exists($evidenceRootPath) -and -not [IO.Directory]::Exists($evidenceRootPath)) "Evidence root already exists: $evidenceRootPath"
[IO.Directory]::CreateDirectory($evidenceRootPath) | Out-Null
$evidenceId = 'goal2-{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $SourceCommit.Substring(0, 8)

& $dependencyVerifier -RepositoryRoot $repositoryRootPath
$ps51Log = Invoke-PshVmChildAcceptance `
    -Executable ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) `
    -Name 'winps51-arm64' `
    -ScriptPath $goal2Acceptance `
    -Root $repositoryRootPath `
    -LogRoot $evidenceRootPath
$ps7Log = Invoke-PshVmChildAcceptance `
    -Executable $PwshPath `
    -Name 'pwsh7-arm64' `
    -ScriptPath $goal2Acceptance `
    -Root $repositoryRootPath `
    -LogRoot $evidenceRootPath

$installRoot = Join-Path $env:LOCALAPPDATA 'Psh'
$targetVersionRoot = Join-Path (Join-Path $installRoot 'versions') $Version
$targetModuleRoot = Join-Path $targetVersionRoot 'Psh'
$targetBootstrap = Join-Path $installRoot 'bootstrap.ps1'
$targetConfig = Join-Path $installRoot 'config.psd1'
$currentPath = Join-Path $installRoot 'current.json'
$chinese = ([char]0x4E2D).ToString() + ([char]0x6587).ToString()
$acceptance = ([char]0x9A8C).ToString() + ([char]0x6536).ToString()
$spaceWord = ([char]0x7A7A).ToString() + ([char]0x683C).ToString()
$fixtureParent = Join-Path $HOME ("Psh {0} {1}" -f $acceptance, $spaceWord)
$fixtureRoot = Join-Path $fixtureParent 'repo'
Assert-PshVmCondition (-not [IO.Directory]::Exists($fixtureParent) -and -not [IO.File]::Exists($fixtureParent)) "Fixture path already exists: $fixtureParent"

if ([IO.Directory]::Exists($targetModuleRoot)) {
    $sourceFingerprint = @(Get-PshVmTreeFingerprint -Root $sourceModuleRoot)
    $targetFingerprint = @(Get-PshVmTreeFingerprint -Root $targetModuleRoot)
    Assert-PshVmCondition (@(Compare-Object $sourceFingerprint $targetFingerprint).Count -eq 0) "Existing VM version differs from source: $targetModuleRoot"
}
elseif ([IO.File]::Exists($targetModuleRoot)) {
    throw "Goal 2 VM preparation failed: target module path is a file: $targetModuleRoot"
}

foreach ($stableFile in @(
    [PSCustomObject]@{ Source = $sourceBootstrap; Target = $targetBootstrap },
    [PSCustomObject]@{ Source = $sourceConfig; Target = $targetConfig }
)) {
    if ([IO.File]::Exists($stableFile.Target)) {
        $sourceHash = [string](Get-FileHash -LiteralPath $stableFile.Source -Algorithm SHA256).Hash
        $targetHash = [string](Get-FileHash -LiteralPath $stableFile.Target -Algorithm SHA256).Hash
        Assert-PshVmCondition ($sourceHash -ceq $targetHash) "Existing stable file differs from source: $($stableFile.Target)"
    }
    elseif ([IO.Directory]::Exists($stableFile.Target)) {
        throw "Goal 2 VM preparation failed: stable file target is a directory: $($stableFile.Target)"
    }
}

if ([IO.File]::Exists($currentPath)) {
    $existingCurrent = Get-Content -LiteralPath $currentPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    Assert-PshVmCondition ([string]$existingCurrent.version -ceq $Version) "current.json already selects another version: $($existingCurrent.version)"
}
elseif ([IO.Directory]::Exists($currentPath)) {
    throw "Goal 2 VM preparation failed: current.json is a directory: $currentPath"
}

$whatIfResult = @(& $profileInstaller -WhatIf)
[void]$whatIfResult

if (-not [IO.Directory]::Exists($targetModuleRoot)) {
    $stageRoot = Join-Path $installRoot ('.vm-stage-{0}' -f [Guid]::NewGuid().ToString('N'))
    $stageModuleRoot = Join-Path $stageRoot 'Psh'
    try {
        [IO.Directory]::CreateDirectory($stageModuleRoot) | Out-Null
        Get-ChildItem -LiteralPath $sourceModuleRoot -Force |
            Copy-Item -Destination $stageModuleRoot -Recurse -Force
        $sourceFingerprint = @(Get-PshVmTreeFingerprint -Root $sourceModuleRoot)
        $stagedFingerprint = @(Get-PshVmTreeFingerprint -Root $stageModuleRoot)
        Assert-PshVmCondition (@(Compare-Object $sourceFingerprint $stagedFingerprint).Count -eq 0) 'The staged module differs from source.'
        [IO.Directory]::CreateDirectory($targetVersionRoot) | Out-Null
        [IO.Directory]::Move($stageModuleRoot, $targetModuleRoot)
    }
    finally {
        if ([IO.Directory]::Exists($stageRoot)) {
            [IO.Directory]::Delete($stageRoot, $true)
        }
    }
}

[IO.Directory]::CreateDirectory($installRoot) | Out-Null
if (-not [IO.File]::Exists($targetBootstrap)) {
    [IO.File]::Copy($sourceBootstrap, $targetBootstrap, $false)
}
if (-not [IO.File]::Exists($targetConfig)) {
    [IO.File]::Copy($sourceConfig, $targetConfig, $false)
}
& $versionSetter -Version $Version -InstallRoot $installRoot
$profileResults = @(& $profileInstaller)
Assert-PshVmCondition ($profileResults.Count -eq 2) 'Profile installer did not report exactly two targets.'

$documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
$profilePaths = @(
    (Join-Path $documents 'WindowsPowerShell\profile.ps1'),
    (Join-Path $documents 'PowerShell\profile.ps1')
)
$markerStart = '# >>> Psh managed profile >>>'
$markerEnd = '# <<< Psh managed profile <<<'
$profileEvidence = @(
    foreach ($profilePath in $profilePaths) {
        Assert-PshVmCondition ([IO.File]::Exists($profilePath)) "Managed profile is missing: $profilePath"
        $profileText = [IO.File]::ReadAllText($profilePath)
        $startCount = ([regex]::Matches($profileText, [regex]::Escape($markerStart))).Count
        $endCount = ([regex]::Matches($profileText, [regex]::Escape($markerEnd))).Count
        Assert-PshVmCondition ($startCount -eq 1 -and $endCount -eq 1) "Managed profile marker count is invalid: $profilePath"
        [ordered]@{
            path       = $profilePath
            sha256     = [string](Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
            startCount = $startCount
            endCount   = $endCount
        }
    }
)

$windowsPowerShellExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$startupEvidence = [ordered]@{
    windowsPowerShell = @(
        Invoke-PshVmProfileStartupProbe -Executable $windowsPowerShellExecutable -Name 'winps51-cold' -LogRoot $evidenceRootPath
        Invoke-PshVmProfileStartupProbe -Executable $windowsPowerShellExecutable -Name 'winps51-warm' -LogRoot $evidenceRootPath
    )
    powerShell7 = @(
        Invoke-PshVmProfileStartupProbe -Executable $PwshPath -Name 'pwsh7-cold' -LogRoot $evidenceRootPath
        Invoke-PshVmProfileStartupProbe -Executable $PwshPath -Name 'pwsh7-warm' -LogRoot $evidenceRootPath
    )
}

[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'init') | Out-Null
Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'config', 'user.name', 'Psh Goal2 VM') | Out-Null
Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'config', 'user.email', 'goal2-vm@example.invalid') | Out-Null
[IO.File]::WriteAllText((Join-Path $fixtureRoot ("{0}.txt" -f $chinese)), 'goal2-vm', (New-Object Text.UTF8Encoding($false)))
Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'add', '.') | Out-Null
Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'commit', '-m', 'goal2 vm fixture') | Out-Null
Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'branch', '-M', 'main') | Out-Null
Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'branch', 'feature/vscode-acceptance') | Out-Null
$branches = @(Invoke-PshVmGit -Executable $GitPath -ArgumentList @('-C', $fixtureRoot, 'for-each-ref', '--format=%(refname:short)', 'refs/heads'))

$currentDocument = Get-Content -LiteralPath $currentPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$prepareEvidence = [ordered]@{
    schemaVersion       = 1
    evidenceId          = $evidenceId
    capturedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    sourceCommit        = $SourceCommit
    stagedVersion       = $Version
    user                = $identity.Name
    elevated            = $isElevated
    processArchitecture = $processArchitecture
    windowsPowerShell   = [ordered]@{
        version  = $PSVersionTable.PSVersion.ToString()
        policies = @(Get-ExecutionPolicy -List | ForEach-Object { [ordered]@{ scope = [string]$_.Scope; policy = [string]$_.ExecutionPolicy } })
        log      = $ps51Log
    }
    powerShell7         = [ordered]@{
        executable = $PwshPath
        version     = [string]$ps7Audit.version
        architecture = [string]$ps7Audit.architecture
        policies    = $ps7Policies
        allUsersConfig = $ps7Audit.allUsersConfig
        currentUserConfig = $ps7Audit.currentUserConfig
        log         = $ps7Log
    }
    install             = [ordered]@{
        root        = $installRoot
        currentPath = $currentPath
        current     = $currentDocument
        moduleRoot  = $targetModuleRoot
        moduleTree  = @(Get-PshVmTreeFingerprint -Root $targetModuleRoot)
        profiles    = $profileEvidence
        startup     = $startupEvidence
    }
    tools               = [ordered]@{
        gitPath    = $GitPath
        gitVersion = $gitVersion
        gitMachine = $gitMachine
        codePath   = $CodePath
        codeVersion = $codeVersion
        codeMachine = $codeMachine
        codeExtensions = $codeExtensions
    }
    fixture             = [ordered]@{
        path     = $fixtureRoot
        branches = $branches
    }
}
$prepareEvidencePath = Join-Path $evidenceRootPath 'prepare.json'
Write-PshVmUtf8Json -Path $prepareEvidencePath -Value $prepareEvidence

Write-Output ("PSH_GOAL2_VM_PREPARE_OK {0}" -f $evidenceId)
Write-Output ("EVIDENCE={0}" -f $prepareEvidencePath)
Write-Output ("FIXTURE={0}" -f $fixtureRoot)
