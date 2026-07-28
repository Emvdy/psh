# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param([string]$RepositoryRoot)

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $scriptPath = [string]$MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'Goal 5 workflow contract could not resolve its script path.'
    }
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $scriptPath)
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Goal5WorkflowAssertions = 0

function Assert-PshGoal5Workflow {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw ('Goal 5 workflow contract failed: {0}' -f $Message)
    }
    $script:Goal5WorkflowAssertions++
}

function Get-PshGoal5WorkflowText {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-PshGoal5Workflow ([IO.File]::Exists($Path)) "Workflow file is missing: $Path"
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshGoal5Workflow ($bytes.Length -gt 0) 'Workflow file is empty.'
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or
        ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))
    Assert-PshGoal5Workflow (-not $hasBom) 'Workflow file must not contain a byte-order mark.'
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    try { $text = $utf8.GetString($bytes) }
    catch { throw ('Goal 5 workflow contract failed: Workflow is not strict UTF-8: {0}' -f $_.Exception.Message) }
    Assert-PshGoal5Workflow ($text.IndexOf("`r", [StringComparison]::Ordinal) -lt 0) 'Workflow must use LF line endings.'
    Assert-PshGoal5Workflow ($text.EndsWith("`n", [StringComparison]::Ordinal)) 'Workflow must end with a newline.'
    return $text
}

function Assert-PshGoal5WorkflowMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$Minimum = 1,
        [int]$Maximum = -1
    )

    $count = [regex]::Matches($Text, $Pattern).Count
    Assert-PshGoal5Workflow ($count -ge $Minimum) "$Description is missing."
    if ($Maximum -ge 0) {
        Assert-PshGoal5Workflow ($count -le $Maximum) "$Description occurs $count times; maximum is $Maximum."
    }
}

function Assert-PshGoal5WorkflowNoMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PshGoal5Workflow (-not [regex]::IsMatch($Text, $Pattern)) $Description
}

function Get-PshGoal5RunBlocks {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = $Text.Split("`n")
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($lineIndex = 0; $lineIndex -lt $lines.Length; $lineIndex++) {
        $match = [regex]::Match($lines[$lineIndex], '^(?<indent> +)run:\s*\|\s*$')
        if (-not $match.Success) { continue }
        $runIndent = $match.Groups['indent'].Length
        $body = New-Object System.Collections.Generic.List[string]
        for ($bodyIndex = $lineIndex + 1; $bodyIndex -lt $lines.Length; $bodyIndex++) {
            $line = $lines[$bodyIndex]
            if ($line.Length -eq 0) {
                [void]$body.Add('')
                continue
            }
            $leading = [regex]::Match($line, '^ *').Value.Length
            if ($leading -le $runIndent) { break }
            $remove = [Math]::Min($runIndent + 2, $leading)
            [void]$body.Add($line.Substring($remove))
        }
        [void]$blocks.Add([pscustomobject]@{
                Line = $lineIndex + 1
                Script = $body.ToArray() -join "`n"
            })
    }
    return $blocks.ToArray()
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$workflowPath = Join-Path $repositoryRootPath '.github/workflows/goal5.yml'
$workflowText = Get-PshGoal5WorkflowText -Path $workflowPath

$contractPath = $MyInvocation.MyCommand.Path
$contractBytes = [IO.File]::ReadAllBytes($contractPath)
$contractHasBom = $contractBytes.Length -ge 3 -and $contractBytes[0] -eq 0xEF -and $contractBytes[1] -eq 0xBB -and $contractBytes[2] -eq 0xBF
Assert-PshGoal5Workflow (-not $contractHasBom) 'Workflow contract script must not contain a UTF-8 BOM.'
$contractTokens = $null
$contractErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($contractPath, [ref]$contractTokens, [ref]$contractErrors)
Assert-PshGoal5Workflow (@($contractErrors).Count -eq 0) 'Workflow contract script has PowerShell parser errors.'

$runBlocks = @(Get-PshGoal5RunBlocks -Text $workflowText)
Assert-PshGoal5Workflow ($runBlocks.Count -eq 7) "Workflow must contain exactly seven explicit run blocks; found $($runBlocks.Count)."
foreach ($runBlock in $runBlocks) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput([string]$runBlock.Script, [ref]$tokens, [ref]$errors)
    $diagnostic = @($errors | ForEach-Object { 'line {0}: {1}' -f ([int]$runBlock.Line + [int]$_.Extent.StartLineNumber), $_.Message }) -join '; '
    Assert-PshGoal5Workflow (@($errors).Count -eq 0) ('Embedded PowerShell run block is invalid: {0}' -f $diagnostic)
}

Assert-PshGoal5WorkflowMatch $workflowText '(?m)^on:\s*$' 'on trigger block' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^  push:\s*$' 'push trigger' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^    branches:\s*$' 'push branch allowlist' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "(?m)^      - main\s*$" 'main push branch' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "(?m)^      - 'goal5/\*\*'\s*$" 'goal5 branch family' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "(?m)^      - 'goal6/\*\*'\s*$" 'goal6 branch family' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^  pull_request:\s*$' 'pull_request trigger' 1 1

$permissions = [regex]::Match($workflowText, '(?ms)^permissions:\s*\n(?<body>(?:  [^\n]*\n)+)')
Assert-PshGoal5Workflow ($permissions.Success) 'Top-level permissions block is missing.'
Assert-PshGoal5Workflow ($permissions.Groups['body'].Value.TrimEnd() -ceq '  contents: read') 'Workflow permissions must be exactly contents: read.'
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^concurrency:\s*$' 'concurrency block' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^  group: goal5-\$\{\{ github\.workflow \}\}-\$\{\{ github\.ref \}\}\s*$' 'workflow/ref concurrency group' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^  cancel-in-progress: true\s*$' 'cancel-in-progress setting' 1 1

Assert-PshGoal5WorkflowMatch $workflowText '(?m)^    runs-on: windows-2022\s*$' 'pinned Windows 2022 runner' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^      fail-fast: false\s*$' 'non-short-circuiting matrix strategy' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^        include:\s*$' 'matrix include list' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^          - name: ' 'matrix runtime entry' 2 2
Assert-PshGoal5WorkflowMatch $workflowText '(?ms)^          - name: Windows PowerShell 5\.1 x64\s*\n            runtime: winps51\s*\n            shell: powershell\s*\n            expected_major: 5\s*\n            expected_minor: 1\s*\n            expected_edition: Desktop\s*$' 'Windows PowerShell 5.1 matrix contract' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?ms)^          - name: PowerShell 7 x64\s*\n            runtime: pwsh7\s*\n            shell: pwsh\s*\n            expected_major: 7\s*\n            expected_minor: 0\s*\n            expected_edition: Core\s*$' 'PowerShell 7 matrix contract' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^        shell: powershell\s*$' 'native Windows PowerShell step' 1 -1
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^        shell: pwsh\s*$' 'native PowerShell 7 step' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\[Environment\]::Is64BitProcess' 'x64 process validation' 2 -1
Assert-PshGoal5WorkflowMatch $workflowText "PROCESSOR_ARCHITECTURE -ine 'AMD64'" 'AMD64 runner validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'actualMajor -ne 5 -or \$actualMinor -ne 1 -or \$actualEdition -cne \x27Desktop\x27' 'exact Windows PowerShell 5.1 Desktop validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'actualMajor -lt 7 -or \$actualEdition -cne \x27Core\x27' 'PowerShell 7 Core validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "Get-Command -Name 'pwsh\.exe'.*-ErrorAction Stop" 'explicit PowerShell 7 relaunch' 4 4

$expectedTests = @(
    'tests/Goal1.Acceptance.ps1',
    'tests/Goal5.WorkflowContract.ps1',
    'tests/Goal5.PackageLifecycle.ps1',
    'tests/Goal5.LifecycleAcceptance.ps1',
    'tests/Goal5.UninstallSafety.ps1',
    'tests/Goal5.Bootstrapper.ps1',
    'tests/Goal5.ReleaseTrust.ps1',
    'tests/Goal5.Acquisition.ps1',
    'tests/Goal5.OnlineOffline.ps1',
    'tests/Goal5.PackageBuild.ps1'
)
foreach ($testPath in $expectedTests) {
    Assert-PshGoal5WorkflowMatch $workflowText ([regex]::Escape($testPath)) "fixed test path $testPath" 2 2
}
$expectedInputs = @(
    'scripts/Build-PshBootstrapper.ps1',
    'scripts/Build-PshPackages.ps1',
    'scripts/Generate-PshReleaseIndex.ps1',
    'scripts/Test-PshReleaseArtifacts.ps1',
    'src/bootstrapper/Psh.Bootstrapper.csproj',
    'src/install/Install-PshPackage.ps1',
    'src/install/PackageAcquisition.ps1',
    'src/install/PackageLifecycle.ps1',
    'src/install/ReleaseTrust.ps1',
    'src/install/Rollback-PshVersion.ps1',
    'src/install/Set-PshCurrentVersion.ps1',
    'src/install/bootstrap.ps1',
    'src/install/install.ps1',
    'src/install/install-offline.ps1',
    'src/install/install.sh',
    'src/install/Uninstall-Psh.ps1'
)
foreach ($inputPath in $expectedInputs) {
    Assert-PshGoal5WorkflowMatch $workflowText ([regex]::Escape($inputPath)) "fixed build input $inputPath" 1 -1
}
Assert-PshGoal5WorkflowMatch $workflowText '\$requiredFiles = @\(' 'fixed input list' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'foreach \(\$relativePath in \$requiredFiles\)' 'fixed input preflight loop' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Test-Path -LiteralPath \$requiredPath -PathType Leaf' 'fixed input existence check' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Required Goal 5 input is missing' 'missing-input failure' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Test-Path -LiteralPath \$testPath -PathType Leaf' 'per-test existence check' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Required Goal 5 test is missing' 'missing-test failure' 1 1
Assert-PshGoal5WorkflowNoMatch $workflowText '(?im)Get-ChildItem[^\n]*(?:tests[/\\]|Goal5\.)' 'Workflow must not discover tests with Get-ChildItem or a wildcard.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?im)tests[/\\]Goal5\*' 'Workflow must not use wildcard Goal 5 test paths.'

Assert-PshGoal5WorkflowMatch $workflowText 'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force' 'process-only Bypass test policy' 3 3
Assert-PshGoal5WorkflowMatch $workflowText '& \$enginePath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \$testPath -RepositoryRoot \$env:GITHUB_WORKSPACE' 'isolated test process invocation with explicit repository root' 1 1
Assert-PshGoal5WorkflowNoMatch $workflowText '& \$enginePath[^\n]*-File \$testPath(?![^\n]*-RepositoryRoot \$env:GITHUB_WORKSPACE)' 'Every isolated test invocation must pass the fixed GitHub workspace as RepositoryRoot.'
Assert-PshGoal5WorkflowMatch $workflowText '\$testErrorActionPreference = \$ErrorActionPreference' 'isolated test error-action preference save' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\$ErrorActionPreference = \x27Continue\x27' 'isolated native stderr continuation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\$ErrorActionPreference = \$testErrorActionPreference' 'isolated test error-action preference restore' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\$testExitCode = if \(\$null -eq \$LASTEXITCODE\)' 'test exit-code capture' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\$global:LASTEXITCODE = 0' 'LASTEXITCODE reset' 6 6
Assert-PshGoal5WorkflowMatch $workflowText "\\b\(\?:deferred\|skipped\)\\b" 'deferred/skipped log gate' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'test-logs' 'per-test log directory' 2 -1
Assert-PshGoal5WorkflowMatch $workflowText 'test-summary\.json' 'structured test summary' 2 2
Assert-PshGoal5WorkflowMatch $workflowText 'failureCount = \$failures\.Count' 'aggregate test failure count' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Goal5\.OnlineOffline\.summary\.json' 'online/offline acceptance report retention' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'onlineOfflineReport\.assertions -le 0' 'online/offline assertion report validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'onlineOfflineReport\.offlineLog\)\.Count -lt 3' 'online/offline sequence report validation' 1 1

Assert-PshGoal5WorkflowMatch $workflowText 'scripts/Build-PshBootstrapper\.ps1' 'bootstrapper build script' 2 2
Assert-PshGoal5WorkflowMatch $workflowText 'Join-Path \$buildRoot \x27install\.ps1\x27' 'temporary online install.ps1 template' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "src/install/install-offline\.ps1" 'real offline installer input' 2 2
Assert-PshGoal5WorkflowMatch $workflowText '<TargetFrameworkVersion>v4\.7\.2</TargetFrameworkVersion>' 'net472 project gate' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '<PlatformTarget>AnyCPU</PlatformTarget>' 'AnyCPU project gate' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '<Prefer32Bit>false</Prefer32Bit>' 'Prefer32Bit project gate' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '<TreatWarningsAsErrors>true</TreatWarningsAsErrors>' 'warnings-as-errors project gate' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Get-AuthenticodeSignature -LiteralPath \$bootstrapperPath' 'Authenticode status inspection' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "Status -cne 'NotSigned'" 'unsigned pre-sign requirement' 2 2
Assert-PshGoal5WorkflowMatch $workflowText '\$machine -ne 0x014c -or \$optionalMagic -ne 0x010b' 'AnyCPU PE machine/magic validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'ILONLY' 'CLR ILONLY validation' 1 -1
Assert-PshGoal5WorkflowMatch $workflowText '32BITREQUIRED' 'CLR 32BITREQUIRED rejection' 1 -1
Assert-PshGoal5WorkflowMatch $workflowText '32BITPREFERRED' 'CLR 32BITPREFERRED rejection' 1 -1
Assert-PshGoal5WorkflowMatch $workflowText '0x00000001' 'ILONLY bit mask' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '0x00000002' '32BITREQUIRED bit mask' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '0x00020000' '32BITPREFERRED bit mask' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'bootstrapper-build-report\.json' 'bootstrapper JSON report' 2 2
Assert-PshGoal5WorkflowMatch $workflowText 'workflow-started\.txt' 'early report-root marker' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'bootstrapper-build/build\.log' 'bootstrapper build log retention' 1 1

Assert-PshGoal5WorkflowMatch $workflowText 'PSH_GOAL5_REPORT_ROOT' 'Goal 5 report root environment contract' 10 -1
Assert-PshGoal5WorkflowMatch $workflowText 'PSH_GOAL5_PRE_SIGN_ROOT' 'Goal 5 pre-sign root environment contract' 8 -1
Assert-PshGoal5WorkflowMatch $workflowText 'Join-Path \$env:RUNNER_TEMP \(\x27goal5-\x27 \+ \$env:PSH_GOAL5_RUNTIME\)' 'runner-temp report-root derivation' 5 5
Assert-PshGoal5WorkflowMatch $workflowText 'Join-Path \$env:PSH_GOAL5_REPORT_ROOT \x27pre-sign-build\x27' 'pre-sign root derivation' 4 4
Assert-PshGoal5WorkflowMatch $workflowText 'pre-sign-build\.json' 'pre-sign build state retention' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'buildState\.phase -cne \x27pre-sign\x27 -or \[int\]\$buildState\.code -ne 4' 'pre-sign phase/code validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "-Filter 'package\.manifest\.json'" 'staged package manifest validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'archiveRelativePath' 'archive-path rejection' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '0\.0\.1-test' 'synthetic fixture isolation checks' 3 3
Assert-PshGoal5WorkflowMatch $workflowText 'testOnly' 'synthetic testOnly checks' 5 -1
Assert-PshGoal5WorkflowMatch $workflowText "Extension -ieq '\.zip'" 'pre-sign ZIP rejection' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Join-Path \$env:PSH_GOAL5_PRE_SIGN_ROOT \x27release-assets\x27' 'release-assets absence check' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'package-build-report\.json' 'package build report retention' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'release-artifacts-report\.json' 'release artifact report retention' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'release-artifacts-final-report\.json' 'final release artifact report retention' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'packageBuildReport\.preSignRoot' 'package report pre-sign root validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "packageBuildReport\.indexPhase -cne 'catalog-deferred'" 'package report index phase validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "packageBuildReport\.artifactPhase -cne 'static-verified-catalog-membership-deferred'" 'package report artifact phase validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "packageBuildReport\.finalIndexPhase -cne 'finalized-with-verified-catalog-membership'" 'package report final index phase validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "packageBuildReport\.finalArtifactPhase -cne 'release-catalog-membership-verified'" 'package report final artifact phase validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '-not \[bool\]\$packageBuildReport\.catalogMembershipVerified' 'package report catalog membership validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "releaseArtifactsReport\.phase -cne 'static-verified-catalog-membership-deferred'" 'release artifact phase validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'releaseArtifactsReport\.code -ne 4' 'release artifact code validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'releaseArtifactsReport\.assetCount -ne 12' 'build-stage release asset count validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\[bool\]\$releaseArtifactsReport\.catalogMembershipVerified' 'build-stage catalog membership deferral validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "finalReleaseArtifactsReport\.phase -cne 'release-catalog-membership-verified'" 'final release artifact phase validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'finalReleaseArtifactsReport\.code -ne 0' 'final release artifact code validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'finalReleaseArtifactsReport\.assetCount -ne 13' 'exact final release asset count validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '-not \[bool\]\$finalReleaseArtifactsReport\.catalogMembershipVerified' 'final catalog membership validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\$expectedReleaseAssetNames = @\(' 'exact release asset name contract' 1 1
Assert-PshGoal5WorkflowMatch $workflowText '\$releaseAssetEntries\.Count -ne 13' 'on-disk release asset count validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'Name -ceq \$expectedAssetName' 'on-disk exact release asset name validation' 1 1
Assert-PshGoal5WorkflowMatch $workflowText "phase = 'pre-sign-and-catalog-membership-validated'" 'workflow validation phase' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'workflow-validation-report\.json' 'workflow validation report' 1 1

Assert-PshGoal5WorkflowMatch $workflowText 'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' 'pinned checkout action' 1 1
Assert-PshGoal5WorkflowMatch $workflowText 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' 'pinned upload-artifact action' 1 1
$usesLines = @([regex]::Matches($workflowText, '(?m)^\s+uses:\s*(?<value>[^\s#]+)') | ForEach-Object { [string]$_.Groups['value'].Value })
Assert-PshGoal5Workflow ($usesLines.Count -eq 2) 'Workflow must use exactly checkout and upload-artifact actions.'
foreach ($uses in $usesLines) {
    Assert-PshGoal5Workflow ($uses -match '@[0-9a-f]{40}\z') "Action is not pinned to a full commit SHA: $uses"
}
Assert-PshGoal5WorkflowMatch $workflowText '\$\{\{ always\(\) \}\}' 'always-run report validation/upload' 2 2
Assert-PshGoal5WorkflowMatch $workflowText '(?m)^          if-no-files-found: error\s*$' 'strict missing-artifact behavior' 1 1
Assert-PshGoal5WorkflowNoMatch $workflowText '(?im)^\s*if-no-files-found:\s*(?:warn|ignore)\s*$' 'Artifact upload must not warn or ignore when reports are missing.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?im)^\s*continue-on-error\s*:' 'Workflow must not continue after a failed test or build step.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?i)\bsecrets?(?:\.|\[|:)' 'Workflow must not consume or define secrets.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?i)\b(?:prlctl|parallels|vagrant|virtualbox|vboxmanage|hyper-v|hyperv|qemu)\b' 'Workflow must not invoke VM or hypervisor tooling.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?i)\b(?:signtool|azuresigntool|Set-AuthenticodeSignature|New-GitHubRelease|Publish-Module)\b' 'Workflow must not sign or publish artifacts.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?i)(?:^|\s)gh\s+release\b|actions/create-release|softprops/action-gh-release|ncipollo/release-action' 'Workflow must not create a GitHub release.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?i)(?:^|\s)-Finalize(?:\s|$)' 'Workflow must not finalize pre-sign packages.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?i)-Version\s+[^\s]*0\.0\.1-test' 'Workflow must not build the synthetic fixture as a public version.'
Assert-PshGoal5WorkflowNoMatch $workflowText '(?im)(?:New-Item|CreateDirectory)[^\n]*release-assets' 'Workflow must not create a release-assets directory.'

Write-Output "Goal 5 workflow contract passed ($script:Goal5WorkflowAssertions assertions)."
