# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$script:Assertions = 0
$script:RunningOnWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)

function Assert-PshGoal5Bootstrapper {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:Assertions++
    if (-not $Condition) {
        throw ('Goal 5 bootstrapper acceptance failed: {0}' -f $Message)
    }
}

function Get-PshStrictText {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-PshGoal5Bootstrapper (Test-Path -LiteralPath $Path -PathType Leaf) ('Missing file: {0}' -f $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-PshGoal5Bootstrapper (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) ('UTF-8 BOM found in {0}' -f $Path)
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    try {
        return $encoding.GetString($bytes)
    }
    catch {
        throw ('Goal 5 bootstrapper acceptance failed: invalid UTF-8 in {0}' -f $Path)
    }
}

function Get-PshSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

function Invoke-PshExpectedParserFailure {
    param(
        [Parameter(Mandatory = $true)][type]$ParserType,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $failed = $false
    try {
        [void]$ParserType::Parse($Arguments)
    }
    catch {
        $failed = $true
    }

    Assert-PshGoal5Bootstrapper $failed ('Parser accepted invalid input: {0}' -f $Description)
}

function Invoke-PshExpectedProbeParseFailure {
    param(
        [Parameter(Mandatory = $true)][Reflection.MethodInfo]$ParseMethod,
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $failed = $false
    try {
        [void]$ParseMethod.Invoke($null, @($Json))
    }
    catch {
        $failed = $true
    }

    Assert-PshGoal5Bootstrapper $failed ('Policy probe parser accepted invalid metadata: {0}' -f $Description)
}

function Invoke-PshBootstrapperProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& $Executable @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Output   = $output
    }
}

$bootstrapperRoot = Join-Path $RepositoryRoot 'src/bootstrapper'
$parserPath = Join-Path $bootstrapperRoot 'ArgumentParser.cs'
$commandLinePath = Join-Path $bootstrapperRoot 'CommandLineEscaping.cs'
$projectPath = Join-Path $bootstrapperRoot 'Psh.Bootstrapper.csproj'
$programPath = Join-Path $bootstrapperRoot 'Program.cs'
$policyPath = Join-Path $bootstrapperRoot 'ExecutionPolicyPreflight.cs'
$integrityPath = Join-Path $bootstrapperRoot 'ScriptIntegrityVerifier.cs'
$locatorPath = Join-Path $bootstrapperRoot 'WindowsPowerShellLocator.cs'
$buildScriptPath = Join-Path $RepositoryRoot 'scripts/Build-PshBootstrapper.ps1'

foreach ($requiredPath in @($parserPath, $commandLinePath, $projectPath, $programPath, $policyPath, $integrityPath, $locatorPath, $buildScriptPath)) {
    Assert-PshGoal5Bootstrapper (Test-Path -LiteralPath $requiredPath -PathType Leaf) ('Required bootstrapper artifact is missing: {0}' -f $requiredPath)
}

$allSourceText = @(
    (Get-PshStrictText -Path $parserPath),
    (Get-PshStrictText -Path $commandLinePath),
    (Get-PshStrictText -Path (Join-Path $bootstrapperRoot 'ErrorEnvelope.cs')),
    (Get-PshStrictText -Path $policyPath),
    (Get-PshStrictText -Path $programPath),
    (Get-PshStrictText -Path $integrityPath),
    (Get-PshStrictText -Path $locatorPath),
    (Get-PshStrictText -Path (Join-Path $bootstrapperRoot 'EmbeddedScriptHashes.g.cs'))
) -join "`n"
$programText = Get-PshStrictText -Path $programPath
$policyText = Get-PshStrictText -Path $policyPath
$integrityText = Get-PshStrictText -Path $integrityPath
$locatorText = Get-PshStrictText -Path $locatorPath
$buildText = Get-PshStrictText -Path $buildScriptPath
$projectText = Get-PshStrictText -Path $projectPath

Assert-PshGoal5Bootstrapper ($allSourceText -match 'SPDX-License-Identifier:\s*GPL-3\.0-or-later') 'C# sources are missing the GPL-3.0-or-later declaration.'
Assert-PshGoal5Bootstrapper ($buildText -match 'SPDX-License-Identifier:\s*GPL-3\.0-or-later') 'Build script is missing the GPL-3.0-or-later declaration.'
Assert-PshGoal5Bootstrapper ($projectText -match 'SPDX-License-Identifier:\s*GPL-3\.0-or-later') 'Project is missing the GPL-3.0-or-later declaration.'

$projectXml = [xml]$projectText
$namespaceManager = New-Object System.Xml.XmlNamespaceManager -ArgumentList $projectXml.NameTable
$namespaceManager.AddNamespace('msb', 'http://schemas.microsoft.com/developer/msbuild/2003')
function Get-PshProjectProperty {
    param([Parameter(Mandatory = $true)][string]$Name)
    $node = $projectXml.SelectSingleNode(('//msb:{0}' -f $Name), $namespaceManager)
    if ($null -eq $node) { return $null }
    return [string]$node.InnerText
}

Assert-PshGoal5Bootstrapper ((Get-PshProjectProperty -Name 'OutputType') -ceq 'Exe') 'Bootstrapper project is not a console executable.'
Assert-PshGoal5Bootstrapper ((Get-PshProjectProperty -Name 'TargetFrameworkVersion') -in @('v4.7.2', 'v4.8')) 'Bootstrapper project does not target classic net472/net48.'
Assert-PshGoal5Bootstrapper ((Get-PshProjectProperty -Name 'PlatformTarget') -ceq 'AnyCPU') 'Bootstrapper project is not AnyCPU.'
Assert-PshGoal5Bootstrapper ((Get-PshProjectProperty -Name 'Prefer32Bit') -ceq 'false') 'Bootstrapper project enables Prefer32Bit.'
Assert-PshGoal5Bootstrapper ((Get-PshProjectProperty -Name 'Deterministic') -ceq 'true') 'Bootstrapper project is not deterministic.'
Assert-PshGoal5Bootstrapper ((Get-PshProjectProperty -Name 'LangVersion') -ceq '5') 'Bootstrapper project does not enforce the Windows PowerShell 5.1-compatible C# 5 language level.'
Assert-PshGoal5Bootstrapper ($projectText -notmatch '(?i)PackageReference|packages\.config|NuGet') 'Bootstrapper project has a package-manager dependency.'
Assert-PshGoal5Bootstrapper ($buildText -notmatch '(?i)PS2EXE|Invoke-PS2EXE|dotnet\s+restore|PackageReference|NuGet') 'Build script references a prohibited packaging dependency.'
Assert-PshGoal5Bootstrapper ($buildText -match '(?s)GenerateHashSourceOnly.*Write-PshHashSource') 'Build script does not expose hash-source generation.'
Assert-PshGoal5Bootstrapper (([regex]::Matches($buildText, '&\s*\$msbuild')).Count -eq 1) 'Build script does not have exactly one MSBuild invocation.'
Assert-PshGoal5Bootstrapper ($buildText -match '/t:Build' -and $buildText -notmatch '/t:Rebuild') 'Build script is not a single clean Build invocation.'

Assert-PshGoal5Bootstrapper ($allSourceText -match 'install\.ps1' -and $allSourceText -match 'install-offline\.ps1') 'Fixed adjacent script names are missing.'
Assert-PshGoal5Bootstrapper ($allSourceText -match 'OnlineScriptSha256' -and $allSourceText -match 'OfflineScriptSha256') 'Both embedded script hashes are missing.'
Assert-PshGoal5Bootstrapper ($allSourceText -match 'System32' -and $allSourceText -match 'WindowsPowerShell' -and $allSourceText -match 'powershell\.exe') 'Native Windows PowerShell path selection is missing.'
Assert-PshGoal5Bootstrapper ($locatorText -match 'SpecialFolder\.Windows' -and $locatorText -match 'Environment\.SystemDirectory') 'Windows PowerShell locator does not use trusted system-directory APIs.'
Assert-PshGoal5Bootstrapper ($locatorText -notmatch '(?i)GetEnvironmentVariable\s*\([^)]*WINDIR') 'Windows PowerShell locator trusts the spoofable WINDIR environment variable.'
Assert-PshGoal5Bootstrapper ($locatorText -match 'SysWOW64' -and $locatorText -match 'Sysnative') 'WOW64 native PowerShell path handling is missing.'
Assert-PshGoal5Bootstrapper ($allSourceText -notmatch 'catch\s*\([^)]*\)\s*when\s*\(') 'Bootstrapper source uses C# exception filters, which Windows PowerShell 5.1 Add-Type cannot compile.'
Assert-PshGoal5Bootstrapper ($allSourceText -match 'Get-ExecutionPolicy\s+-List') 'Read-only execution-policy probe is missing.'
Assert-PshGoal5Bootstrapper ($programText -match 'PowerShellFileArguments' -and $programText -match '"-NoLogo"' -and $programText -match '"-NoProfile"' -and $programText -match '"-File"') 'Installer launch does not use the required PowerShell file arguments.'
Assert-PshGoal5Bootstrapper ($policyText -match '"-Command"' -and $policyText -match 'Get-ExecutionPolicy') 'The policy probe is not explicit and read-only.'
Assert-PshGoal5Bootstrapper ($programText -notmatch '(?i)cmd\.exe|Invoke-Expression') 'Bootstrapper contains a shell or Invoke-Expression escape hatch.'
Assert-PshGoal5Bootstrapper ($programText -notmatch '(?i)-ExecutionPolicy\s+Bypass') 'Bootstrapper attempts to bypass execution policy.'
Assert-PshGoal5Bootstrapper ($programText -notmatch '(?i)"-Command"') 'Installer launch uses -Command instead of -File.'
Assert-PshGoal5Bootstrapper ($programText -match 'UsageExitCode\s*=\s*2' -and $programText -match 'DependencyExitCode\s*=\s*4' -and $programText -match 'IntegrityExitCode\s*=\s*5') 'Required exit-code constants are missing.'
Assert-PshGoal5Bootstrapper ($programText -match 'PSH_E_EXECUTION_POLICY' -and $programText -match 'PolicyRemediation') 'Policy-denial JSON envelope does not use the frozen error code.'
Assert-PshGoal5Bootstrapper ($integrityText -match 'FileAttributes\.ReparsePoint') 'Integrity verifier does not reject reparse points.'
Assert-PshGoal5Bootstrapper ($integrityText -match 'AssertNoReparsePoints\(requestedPath\)' -and $integrityText -match 'Path\.GetDirectoryName\(current\)') 'Integrity verifier does not inspect every installer path ancestor.'
Assert-PshGoal5Bootstrapper ($integrityText -match 'CreateFile' -and $integrityText -match 'FileFlagBackupSemantics' -and $integrityText -match 'FileFlagOpenReparsePoint') 'Integrity verifier does not open and lock the package directory without following its leaf reparse point.'
Assert-PshGoal5Bootstrapper ($integrityText -match 'ShareRead\s*=\s*0x00000001' -and $integrityText -match 'OpenDirectoryReadLock') 'Package-directory lock does not use read-only sharing.'
Assert-PshGoal5Bootstrapper ($integrityText -match 'GetFinalPathNameByHandle' -and $integrityText -match 'NormalizeFinalPath') 'Integrity verifier does not resolve stable final paths from open handles.'
Assert-PshGoal5Bootstrapper ($integrityText -match 'directoryHandle' -and $integrityText -match 'GetCurrentFinalPath') 'Verified handle does not retain both directory and file path state.'
Assert-PshGoal5Bootstrapper ($programText -match 'Path\.GetFullPath') 'Installer script path is not made absolute before ProcessStartInfo construction.'
Assert-PshGoal5Bootstrapper ($integrityText -match 'VerifiedScriptHandle' -and $integrityText -match 'FileShare\.Read') 'Integrity verifier does not return a read-locked verified handle.'
Assert-PshGoal5Bootstrapper ($programText -match 'using \(verifiedScript\)' -and $programText -match 'StartInstaller\(powershellPath, verifiedScript\.GetCurrentFinalPath\(\)') 'Verified handle is not held through installer child completion.'
Assert-PshGoal5Bootstrapper ($programText -match '(?i)ancestor rename' -and $programText -match 'GetCurrentFinalPath') 'Residual ancestor-rename limitation is not documented alongside the final-path refresh.'
Assert-PshGoal5Bootstrapper ($policyText -match 'Get-AuthenticodeSignature' -and $policyText -match 'Zone\.Identifier') 'Policy probe does not inspect Authenticode and MOTW.'
Assert-PshGoal5Bootstrapper ($policyText -match 'PSH_BOOTSTRAPPER_POLICY_SCRIPT_PATH' -and $policyText -match 'EnvironmentVariables') 'Policy probe does not pass the script path through a controlled environment variable.'
Assert-PshGoal5Bootstrapper ($policyText -notmatch '(?i)Unblock-File|Remove-Item') 'Policy probe modifies script trust metadata.'

# Parser checks run on every platform. The parser has no Windows-only API and
# therefore gives the non-Windows gate useful coverage before CI runs a PE.
$parserType = 'Psh.Bootstrapper.ArgumentParser' -as [type]
if ($null -eq $parserType) {
    Add-Type -Path @($parserPath, $commandLinePath, $policyPath, $integrityPath, $locatorPath) -ErrorAction Stop
    $parserType = 'Psh.Bootstrapper.ArgumentParser' -as [type]
}
Assert-PshGoal5Bootstrapper ($null -ne $parserType) 'Could not load the C# argument parser.'
$integrityType = 'Psh.Bootstrapper.ScriptIntegrityVerifier' -as [type]
Assert-PshGoal5Bootstrapper ($null -ne $integrityType) 'Could not load the C# integrity verifier.'
$policyResultType = 'Psh.Bootstrapper.ExecutionPolicyResult' -as [type]
Assert-PshGoal5Bootstrapper ($null -ne $policyResultType) 'Could not load the C# execution-policy decision type.'
$preflightType = $parserType.Assembly.GetType('Psh.Bootstrapper.ExecutionPolicyPreflight', $false)
$locatorType = $parserType.Assembly.GetType('Psh.Bootstrapper.WindowsPowerShellLocator', $false)
Assert-PshGoal5Bootstrapper ($null -ne $locatorType) 'Could not load the Windows PowerShell locator type.'
$locatorHelper = @($locatorType.GetMethods([Reflection.BindingFlags]'Static,NonPublic') | Where-Object {
        $_.Name -ceq 'ResolveWindowsPowerShellPath' -and $_.GetParameters().Count -eq 5
    })[0]
Assert-PshGoal5Bootstrapper ($null -ne $locatorHelper) 'Could not load the injectable Windows PowerShell locator helper.'
$locatorDelegateType = [Func[string, string, bool, bool, Func[string, bool], string]]
$locatorDelegate = $locatorHelper.CreateDelegate($locatorDelegateType)
$alwaysExists = [Func[string, bool]] { param([string]$Candidate) return $true }
$simulatedWindowsRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-locator-root-' + [Guid]::NewGuid().ToString('N'))
$simulatedWow64 = Join-Path $simulatedWindowsRoot 'SysWOW64'
$simulatedSystem32 = Join-Path $simulatedWindowsRoot 'System32'
$wow64NativePath = [string]$locatorDelegate.Invoke($simulatedWindowsRoot, $simulatedWow64, $true, $false, $alwaysExists)
$expectedSysnativePath = [IO.Path]::GetFullPath((Join-Path $simulatedWindowsRoot 'Sysnative/WindowsPowerShell/v1.0/powershell.exe'))
Assert-PshGoal5Bootstrapper ($wow64NativePath -ceq $expectedSysnativePath) '32-bit process on 64-bit Windows did not select native PowerShell through Sysnative.'
$nativeSystem32Path = [string]$locatorDelegate.Invoke($simulatedWindowsRoot, $simulatedSystem32, $true, $true, $alwaysExists)
$expectedSystem32Path = [IO.Path]::GetFullPath((Join-Path $simulatedWindowsRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
Assert-PshGoal5Bootstrapper ($nativeSystem32Path -ceq $expectedSystem32Path) 'Native process did not select PowerShell under System32.'
$mismatchedSystemPath = $locatorDelegate.Invoke($simulatedWindowsRoot, $simulatedSystem32, $true, $false, $alwaysExists)
Assert-PshGoal5Bootstrapper ($null -eq $mismatchedSystemPath) 'WOW64 locator accepted a reported System32 path instead of SysWOW64.'
$parseProbeMethod = $preflightType.GetMethod('Parse', [Reflection.BindingFlags]'Static,NonPublic')
$probeCommandField = $preflightType.GetField('ProbeCommand', [Reflection.BindingFlags]'Static,NonPublic')
$probeCommandText = [string]$probeCommandField.GetRawConstantValue()
$probeTokens = $null
$probeErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($probeCommandText, [ref]$probeTokens, [ref]$probeErrors)
Assert-PshGoal5Bootstrapper (@($probeErrors).Count -eq 0) 'Embedded execution-policy probe is not valid PowerShell syntax.'
$zonePatternField = $preflightType.GetField('ZoneIdPattern', [Reflection.BindingFlags]'Static,NonPublic')
$zonePattern = [string]$zonePatternField.GetRawConstantValue()
Assert-PshGoal5Bootstrapper ($probeCommandText.Contains($zonePattern)) 'ProbeCommand does not embed the declared ZoneId regex.'
$zonePatternMatch = [regex]::Match("[ZoneTransfer]`r`nZoneId=3`r`n", $zonePattern)
Assert-PshGoal5Bootstrapper ($zonePatternMatch.Success -and $zonePatternMatch.Groups[1].Value -ceq '3') 'Final ProbeCommand ZoneId regex did not match ZoneId=3 and capture 3.'
Assert-PshGoal5Bootstrapper ($probeCommandText -match 'Get-Item -LiteralPath \$scriptPath -Stream') 'ProbeCommand does not enumerate alternate streams before treating MOTW as absent.'
Assert-PshGoal5Bootstrapper ($probeCommandText -match '\$zoneMatches\.Count -ne 1' -and $probeCommandText -match 'unknown ZoneId') 'ProbeCommand does not fail closed for malformed or unknown ZoneId metadata.'
$probeFixture = $parseProbeMethod.Invoke($null, @('{"schemaVersion":1,"effectivePolicy":"RemoteSigned","governedByGpo":false,"signatureStatus":"NotSigned","isInternetZone":true,"zoneId":3}'))
Assert-PshGoal5Bootstrapper ($probeFixture.EffectivePolicy -ceq 'RemoteSigned' -and $probeFixture.SignatureStatus -ceq 'NotSigned' -and $probeFixture.IsInternetZone -and [int]$probeFixture.ZoneId -eq 3) 'Policy probe JSON metadata did not parse correctly.'
Assert-PshGoal5Bootstrapper (-not $probeFixture.AllowsScript($true)) 'Parsed Internet-zone unsigned metadata did not drive RemoteSigned denial.'
$localProbeFixture = $parseProbeMethod.Invoke($null, @('{"schemaVersion":1,"effectivePolicy":"RemoteSigned","governedByGpo":false,"signatureStatus":"NotSigned","isInternetZone":false,"zoneId":null}'))
Assert-PshGoal5Bootstrapper ($null -eq $localProbeFixture.ZoneId -and -not $localProbeFixture.IsInternetZone -and $localProbeFixture.AllowsScript($true)) 'A probe with no Zone.Identifier did not preserve the valid local-script decision.'
Assert-PshGoal5Bootstrapper ($localProbeFixture.EffectivePolicy -ceq 'RemoteSigned' -and $localProbeFixture.SignatureStatus -ceq 'NotSigned') 'A valid no-MOTW probe lost required policy metadata.'
foreach ($invalidProbe in @(
        @{ Json = '{"schemaVersion":1,"effectivePolicy":"RemoteSigned","governedByGpo":false,"signatureStatus":"NotSigned","zoneId":3}'; Description = 'missing isInternetZone' },
        @{ Json = '{"schemaVersion":1,"effectivePolicy":"RemoteSigned","governedByGpo":false,"signatureStatus":"NotSigned","isInternetZone":false}'; Description = 'missing zoneId' },
        @{ Json = '{"schemaVersion":1,"effectivePolicy":"RemoteSigned","governedByGpo":false,"signatureStatus":"NotSigned","isInternetZone":false,"zoneId":9}'; Description = 'unknown ZoneId' },
        @{ Json = '{"schemaVersion":1,"effectivePolicy":"RemoteSigned","governedByGpo":false,"signatureStatus":"NotSigned","isInternetZone":false,"zoneId":3}'; Description = 'inconsistent Internet-zone flag' },
        @{ Json = '{"schemaVersion":1,"effectivePolicy":"RemoteSigned","governedByGpo":false,"signatureStatus":"","isInternetZone":false,"zoneId":null}'; Description = 'empty signature status' }
    )) {
    Invoke-PshExpectedProbeParseFailure -ParseMethod $parseProbeMethod -Json $invalidProbe.Json -Description $invalidProbe.Description
}

$defaults = $parserType::Parse([string[]]@())
Assert-PshGoal5Bootstrapper (-not $defaults.Offline -and $defaults.Edition -ceq 'Core' -and $defaults.Version -ceq 'latest' -and -not $defaults.NonInteractive) 'Parser defaults do not select online Core latest.'

$parsed = $parserType::Parse([string[]]@('--offline', '--edition', 'full', '--version', '0.0.1-test', '--non-interactive'))
Assert-PshGoal5Bootstrapper ($parsed.Offline -and $parsed.Edition -ceq 'Full' -and $parsed.Version -ceq '0.0.1-test' -and $parsed.NonInteractive) 'Parser did not normalize the public option set.'
$strictPrerelease = $parserType::Parse([string[]]@('--version', '1.2.3-alpha.1+build.01'))
Assert-PshGoal5Bootstrapper ($strictPrerelease.Version -ceq '1.2.3-alpha.1+build.01') 'Parser rejected a valid strict prerelease and build version.'

$slashParsed = $parserType::Parse([string[]]@('/offline', '-edition', 'Core', '/version', '1.2.3'))
Assert-PshGoal5Bootstrapper ($slashParsed.Offline -and $slashParsed.Edition -ceq 'Core' -and $slashParsed.Version -ceq '1.2.3') 'Parser did not accept the documented slash/single-dash forms.'

$help = $parserType::Parse([string[]]@('--help'))
Assert-PshGoal5Bootstrapper $help.Help 'Parser did not recognize --help.'
foreach ($invalidCase in @(
        @{ Arguments = @('--unknown'); Description = 'unknown option' },
        @{ Arguments = @('--edition', 'Core', '--edition', 'Full'); Description = 'duplicate edition' },
        @{ Arguments = @('--edition', 'Core', '--version', '1.2'); Description = 'short version' },
        @{ Arguments = @('--version', '../1.2.3'); Description = 'path-like version' },
        @{ Arguments = @('--version', '1.2.3-01'); Description = 'leading-zero prerelease identifier' },
        @{ Arguments = @('--version', '1.2.3-00.alpha'); Description = 'leading-zero numeric prerelease identifier' },
        @{ Arguments = @('--version', '1.2.3-1-2'); Description = 'nonnumeric prerelease without an ASCII letter' },
        @{ Arguments = @('--version', '1.2.3--'); Description = 'double hyphen prerelease' },
        @{ Arguments = @('--version', '1.2.3+build--1'); Description = 'double hyphen build identifier' },
        @{ Arguments = @('--version', '1.2.3-alpha..beta'); Description = 'empty prerelease identifier' },
        @{ Arguments = @('--help', '--offline'); Description = 'combined help' },
        @{ Arguments = @('positional'); Description = 'positional argument' }
    )) {
    Invoke-PshExpectedParserFailure -ParserType $parserType -Arguments ([string[]]$invalidCase.Arguments) -Description $invalidCase.Description
}

$policyCases = @(
    @{ Policy = 'Restricted'; Signature = 'Valid'; Internet = $false; NonInteractive = $false; Expected = $false; Label = 'Restricted rejects signed local' },
    @{ Policy = 'AllSigned'; Signature = 'Valid'; Internet = $true; NonInteractive = $true; Expected = $true; Label = 'AllSigned accepts valid signature' },
    @{ Policy = 'AllSigned'; Signature = 'NotSigned'; Internet = $false; NonInteractive = $false; Expected = $false; Label = 'AllSigned rejects unsigned local' },
    @{ Policy = 'RemoteSigned'; Signature = 'NotSigned'; Internet = $false; NonInteractive = $true; Expected = $true; Label = 'RemoteSigned accepts unsigned local' },
    @{ Policy = 'RemoteSigned'; Signature = 'Valid'; Internet = $true; NonInteractive = $true; Expected = $true; Label = 'RemoteSigned accepts trusted Internet script' },
    @{ Policy = 'RemoteSigned'; Signature = 'NotSigned'; Internet = $true; NonInteractive = $false; Expected = $false; Label = 'RemoteSigned rejects unsigned Internet script' },
    @{ Policy = 'Unrestricted'; Signature = 'NotSigned'; Internet = $true; NonInteractive = $false; Expected = $true; Label = 'Unrestricted permits interactive trust prompt' },
    @{ Policy = 'Unrestricted'; Signature = 'NotSigned'; Internet = $true; NonInteractive = $true; Expected = $false; Label = 'Unrestricted rejects non-interactive trust prompt' },
    @{ Policy = 'Unrestricted'; Signature = 'Valid'; Internet = $true; NonInteractive = $true; Expected = $true; Label = 'Unrestricted accepts valid Internet signature' },
    @{ Policy = 'Bypass'; Signature = 'NotSigned'; Internet = $true; NonInteractive = $true; Expected = $true; Label = 'Bypass is respected when already configured' },
    @{ Policy = 'Undefined'; Signature = 'Valid'; Internet = $false; NonInteractive = $false; Expected = $false; Label = 'Unknown effective policy fails closed' }
)
foreach ($policyCase in $policyCases) {
    $policyDecision = [Activator]::CreateInstance($policyResultType)
    $policyDecision.EffectivePolicy = [string]$policyCase.Policy
    $policyDecision.SignatureStatus = [string]$policyCase.Signature
    $policyDecision.IsInternetZone = [bool]$policyCase.Internet
    $policyDecision.ZoneId = if ($policyCase.Internet) { 3 } else { $null }
    $actualDecision = [bool]$policyDecision.AllowsScript([bool]$policyCase.NonInteractive)
    Assert-PshGoal5Bootstrapper ($actualDecision -eq [bool]$policyCase.Expected) ('Policy decision mismatch: {0}' -f $policyCase.Label)
}

$fixtureBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $script:RunningOnWindows -and $fixtureBase.StartsWith('/var/', [StringComparison]::Ordinal) -and [IO.Directory]::Exists('/private/var')) {
    # macOS exposes /var through a root-level symlink. Use the physical path so
    # the fixture itself does not violate the all-ancestors reparse-point rule.
    $fixtureBase = '/private' + $fixtureBase
}
$fixtureRoot = Join-Path $fixtureBase ('psh-goal5-bootstrapper-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$fixtureOnline = Join-Path $fixtureRoot 'install.ps1'
$fixtureOffline = Join-Path $fixtureRoot 'install-offline.ps1'
$fixtureHashSource = Join-Path $fixtureRoot 'generated\EmbeddedScriptHashes.g.cs'
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
try {
    [IO.File]::WriteAllText($fixtureOnline, "# online fixture`n", $utf8NoBom)
    [IO.File]::WriteAllText($fixtureOffline, "# offline fixture`n", $utf8NoBom)

    $verifiedOnline = $integrityType::VerifyScriptIntegrity($fixtureOnline, (Get-PshSha256 -Path $fixtureOnline))
    try {
        $verifiedFinalPath = [string]$verifiedOnline.GetCurrentFinalPath()
        Assert-PshGoal5Bootstrapper ([StringComparer]::OrdinalIgnoreCase.Equals($verifiedFinalPath, [IO.Path]::GetFullPath($fixtureOnline))) 'Verified handle did not resolve the open script handle to its absolute final path.'
        if ($script:RunningOnWindows) {
            $writeDenied = $false
            $writeProbe = $null
            try {
                $writeProbe = [IO.File]::Open($fixtureOnline, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            }
            catch {
                $writeDenied = $true
            }
            finally {
                if ($null -ne $writeProbe) { $writeProbe.Dispose() }
            }
            Assert-PshGoal5Bootstrapper $writeDenied 'Verified handle allowed the script to be opened for writing.'
        }
        else {
            $streamField = $verifiedOnline.GetType().GetField('stream', [Reflection.BindingFlags]'Instance,NonPublic')
            $heldStream = $streamField.GetValue($verifiedOnline)
            Assert-PshGoal5Bootstrapper ($null -ne $heldStream -and $heldStream.CanRead -and -not $heldStream.SafeFileHandle.IsClosed) 'Verified handle did not retain an open read stream on the non-Windows contract gate.'
        }
    }
    finally {
        $verifiedOnline.Dispose()
    }
    if (-not $script:RunningOnWindows) {
        Assert-PshGoal5Bootstrapper $heldStream.SafeFileHandle.IsClosed 'Verified handle did not close its retained stream after disposal.'
    }

    $postVerifyWrite = [IO.File]::Open($fixtureOnline, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $postVerifyWrite.Dispose()
    Assert-PshGoal5Bootstrapper $true 'Verified handle did not release its write lock after disposal.'

    if ($script:RunningOnWindows) {
        $renamePath = Join-Path $fixtureRoot 'lock-rename.ps1'
        $renamedPath = Join-Path $fixtureRoot 'lock-renamed.ps1'
        [IO.File]::WriteAllText($renamePath, "# rename lock`n", $utf8NoBom)
        $renameHandle = $integrityType::VerifyScriptIntegrity($renamePath, (Get-PshSha256 -Path $renamePath))
        try {
            $renameDenied = $false
            try { [IO.File]::Move($renamePath, $renamedPath) } catch { $renameDenied = $true }
            Assert-PshGoal5Bootstrapper $renameDenied 'Verified handle allowed the script to be renamed.'
        }
        finally {
            $renameHandle.Dispose()
        }

        $deletePath = Join-Path $fixtureRoot 'lock-delete.ps1'
        [IO.File]::WriteAllText($deletePath, "# delete lock`n", $utf8NoBom)
        $deleteHandle = $integrityType::VerifyScriptIntegrity($deletePath, (Get-PshSha256 -Path $deletePath))
        try {
            $deleteDenied = $false
            try { [IO.File]::Delete($deletePath) } catch { $deleteDenied = $true }
            Assert-PshGoal5Bootstrapper $deleteDenied 'Verified handle allowed the script to be deleted.'
        }
        finally {
            $deleteHandle.Dispose()
        }

        $packageLockPath = Join-Path $fixtureRoot 'package-lock'
        $packageRenamedPath = Join-Path $fixtureRoot 'package-renamed'
        [void][IO.Directory]::CreateDirectory($packageLockPath)
        $packageScriptPath = Join-Path $packageLockPath 'install.ps1'
        [IO.File]::WriteAllText($packageScriptPath, "# package directory lock`n", $utf8NoBom)
        $packageHandle = $integrityType::VerifyScriptIntegrity($packageScriptPath, (Get-PshSha256 -Path $packageScriptPath))
        try {
            $packageRenameDenied = $false
            try { [IO.Directory]::Move($packageLockPath, $packageRenamedPath) } catch { $packageRenameDenied = $true }
            Assert-PshGoal5Bootstrapper $packageRenameDenied 'Verified handle allowed the locked package directory to be renamed.'
        }
        finally {
            $packageHandle.Dispose()
        }
        [IO.Directory]::Move($packageLockPath, $packageRenamedPath)
        Assert-PshGoal5Bootstrapper ([IO.Directory]::Exists($packageRenamedPath)) 'Verified handle did not release the package-directory rename lock after disposal.'
    }

    if (-not $script:RunningOnWindows) {
        $reparseTarget = Join-Path $fixtureRoot 'integrity-target.ps1'
        $reparseLink = Join-Path $fixtureRoot 'integrity-link.ps1'
        [IO.File]::WriteAllText($reparseTarget, "# target`n", $utf8NoBom)
        [void](New-Item -ItemType SymbolicLink -Path $reparseLink -Target $reparseTarget -Force)
        $reparseRejected = $false
        $reparseHandle = $null
        try {
            $reparseHandle = $integrityType::VerifyScriptIntegrity($reparseLink, (Get-PshSha256 -Path $reparseTarget))
        }
        catch {
            $reparseRejected = $true
        }
        finally {
            if ($null -ne $reparseHandle) { $reparseHandle.Dispose() }
        }
        Assert-PshGoal5Bootstrapper $reparseRejected 'Integrity verifier followed a reparse-point script on a non-Windows fixture.'

        $ancestorTarget = Join-Path $fixtureRoot 'integrity-ancestor-target'
        $ancestorLink = Join-Path $fixtureRoot 'integrity-ancestor-link'
        [void][IO.Directory]::CreateDirectory($ancestorTarget)
        $ancestorTargetScript = Join-Path $ancestorTarget 'install.ps1'
        [IO.File]::WriteAllText($ancestorTargetScript, "# ancestor target`n", $utf8NoBom)
        [void](New-Item -ItemType SymbolicLink -Path $ancestorLink -Target $ancestorTarget -Force)
        $ancestorScriptPath = Join-Path $ancestorLink 'install.ps1'
        $ancestorRejected = $false
        $ancestorHandle = $null
        try {
            $ancestorHandle = $integrityType::VerifyScriptIntegrity($ancestorScriptPath, (Get-PshSha256 -Path $ancestorTargetScript))
        }
        catch {
            $ancestorRejected = $true
        }
        finally {
            if ($null -ne $ancestorHandle) { $ancestorHandle.Dispose() }
        }
        Assert-PshGoal5Bootstrapper $ancestorRejected 'Integrity verifier followed a reparse-point ancestor directory on a non-Windows fixture.'
    }

    $generationOutput = @(& $buildScriptPath -OnlineScriptPath $fixtureOnline -OfflineScriptPath $fixtureOffline -HashSourcePath $fixtureHashSource -GenerateHashSourceOnly 2>&1 | ForEach-Object { [string]$_ })
    Assert-PshGoal5Bootstrapper ($generationOutput.Count -gt 0) 'Hash-source generation returned no status.'
    $generatedHashSource = Get-PshStrictText -Path $fixtureHashSource
    Assert-PshGoal5Bootstrapper ($generatedHashSource -match (Get-PshSha256 -Path $fixtureOnline)) 'Generated source omitted the online SHA256.'
    Assert-PshGoal5Bootstrapper ($generatedHashSource -match (Get-PshSha256 -Path $fixtureOffline)) 'Generated source omitted the offline SHA256.'
    Assert-PshGoal5Bootstrapper ($generatedHashSource -match 'OnlineScriptSha256' -and $generatedHashSource -match 'OfflineScriptSha256') 'Generated source omitted one of the fixed hash constants.'
    Assert-PshGoal5Bootstrapper ($generatedHashSource -notmatch '"0{64}"') 'Generated source retained a fail-closed placeholder hash.'
    Assert-PshGoal5Bootstrapper (-not (Test-Path -LiteralPath ($fixtureOnline + '.sha256'))) 'Build unexpectedly trusted or created an online sidecar.'
    Assert-PshGoal5Bootstrapper (-not (Test-Path -LiteralPath ($fixtureOffline + '.sha256'))) 'Build unexpectedly trusted or created an offline sidecar.'

    $oldOnlineBytes = [IO.File]::ReadAllBytes($fixtureOnline)
    [IO.File]::AppendAllText($fixtureOnline, "# changed`n", $utf8NoBom)
    $changedHashSource = Join-Path $fixtureRoot 'generated\ChangedHashes.g.cs'
    & $buildScriptPath -OnlineScriptPath $fixtureOnline -OfflineScriptPath $fixtureOffline -HashSourcePath $changedHashSource -GenerateHashSourceOnly | Out-Null
    $changedText = Get-PshStrictText -Path $changedHashSource
    Assert-PshGoal5Bootstrapper ($changedText -match (Get-PshSha256 -Path $fixtureOnline)) 'Hash source did not change after online script bytes changed.'
    Assert-PshGoal5Bootstrapper ([IO.File]::ReadAllBytes($fixtureOnline).Length -ne $oldOnlineBytes.Length) 'Fixture mutation did not change bytes.'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:RunningOnWindows) {
    $windowsHandleType = $parserType.Assembly.GetType('Psh.Bootstrapper.WindowsHandle', $false)
    $normalizeFinalPathMethod = $windowsHandleType.GetMethod('NormalizeFinalPath', [Reflection.BindingFlags]'Static,NonPublic')
    $normalizeFinalPath = $normalizeFinalPathMethod.CreateDelegate([Func[string, string]])
    $actualWindowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $normalizedLocalPath = [string]$normalizeFinalPath.Invoke(('\\?\' + $actualWindowsRoot))
    Assert-PshGoal5Bootstrapper ([StringComparer]::OrdinalIgnoreCase.Equals($normalizedLocalPath, [IO.Path]::GetFullPath($actualWindowsRoot))) 'Handle final-path normalization did not remove the local device prefix.'
    $normalizedUncPath = [string]$normalizeFinalPath.Invoke('\\?\UNC\server\share\folder\install.ps1')
    Assert-PshGoal5Bootstrapper ($normalizedUncPath -ceq '\\server\share\folder\install.ps1') 'Handle final-path normalization did not convert the UNC device prefix.'

    $fakeWindowsRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-fake-windir-' + [Guid]::NewGuid().ToString('N'))
    $fakePowerShellPath = Join-Path $fakeWindowsRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $oldWindir = [Environment]::GetEnvironmentVariable('WINDIR', 'Process')
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fakePowerShellPath))
        [IO.File]::WriteAllBytes($fakePowerShellPath, [byte[]]@(0x4D, 0x5A))
        [Environment]::SetEnvironmentVariable('WINDIR', $fakeWindowsRoot, 'Process')
        $resolvedPowerShellPath = [string]$locatorType::ResolveWindowsPowerShellPath()
        Assert-PshGoal5Bootstrapper (-not [string]::IsNullOrWhiteSpace($resolvedPowerShellPath) -and [IO.File]::Exists($resolvedPowerShellPath)) 'Windows PowerShell locator did not resolve the real system executable.'
        Assert-PshGoal5Bootstrapper (-not $resolvedPowerShellPath.StartsWith($fakeWindowsRoot, [StringComparison]::OrdinalIgnoreCase)) 'Windows PowerShell locator followed a spoofed WINDIR root.'
    }
    finally {
        [Environment]::SetEnvironmentVariable('WINDIR', $oldWindir, 'Process')
        if (Test-Path -LiteralPath $fakeWindowsRoot -PathType Container) {
            Remove-Item -LiteralPath $fakeWindowsRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $script:RunningOnWindows) {
    Write-Output ('Goal 5 bootstrapper parser/static/build-contract checks passed ({0} assertions); Windows PE, file-lock, MOTW policy, and process-forwarding checks are deferred to Windows CI. The package directory and script are locked and the final path is refreshed immediately before launch; rename of a higher ancestor remains a documented residual limitation of path-based -File startup.' -f $script:Assertions)
    exit 0
}

# Windows-only integration is intentionally kept in this script so CI is the
# authority for classic net472 compilation and native PowerShell behavior.
$runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal5-bootstrapper-runtime-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runtimeRoot)
$runtimeOnline = Join-Path $runtimeRoot 'install.ps1'
$runtimeOffline = Join-Path $runtimeRoot 'install-offline.ps1'
$runtimeOutput = Join-Path $runtimeRoot 'psh-installer.exe'
$capturePath = Join-Path $runtimeRoot 'forwarded.json'
$runtimeOnlineBytes = $null
$runtimeOnlineHash = $null
$oldCapture = [Environment]::GetEnvironmentVariable('PSH_BOOTSTRAPPER_CAPTURE', 'Process')
$oldPolicyPreference = [Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference', 'Process')
try {
    $onlineScript = @'
[CmdletBinding()]
param([ValidateSet('Core','Full')][string]$Edition, [string]$Version, [switch]$NonInteractive)
$payload = [ordered]@{ mode = 'online'; edition = $Edition; version = $Version; nonInteractive = [bool]$NonInteractive }
$encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
[IO.File]::WriteAllText($env:PSH_BOOTSTRAPPER_CAPTURE, ($payload | ConvertTo-Json -Compress), $encoding)
exit 23
'@
    $offlineScript = @'
[CmdletBinding()]
param([ValidateSet('Core','Full')][string]$Edition, [string]$Version, [switch]$NonInteractive)
$payload = [ordered]@{ mode = 'offline'; edition = $Edition; version = $Version; nonInteractive = [bool]$NonInteractive }
$encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
[IO.File]::WriteAllText($env:PSH_BOOTSTRAPPER_CAPTURE, ($payload | ConvertTo-Json -Compress), $encoding)
exit 29
'@
    [IO.File]::WriteAllText($runtimeOnline, $onlineScript.Replace("`r`n", "`n"), $utf8NoBom)
    [IO.File]::WriteAllText($runtimeOffline, $offlineScript.Replace("`r`n", "`n"), $utf8NoBom)
    $runtimeOnlineBytes = [IO.File]::ReadAllBytes($runtimeOnline)
    $runtimeOnlineHash = Get-PshSha256 -Path $runtimeOnline
    [Environment]::SetEnvironmentVariable('PSH_BOOTSTRAPPER_CAPTURE', $capturePath, 'Process')

    & $buildScriptPath -OnlineScriptPath $runtimeOnline -OfflineScriptPath $runtimeOffline -OutputPath $runtimeOutput | Out-Null
    Assert-PshGoal5Bootstrapper (Test-Path -LiteralPath $runtimeOutput -PathType Leaf) 'Windows build did not produce the bootstrapper executable.'
    $peBytes = [IO.File]::ReadAllBytes($runtimeOutput)
    Assert-PshGoal5Bootstrapper ($peBytes.Length -gt 64 -and $peBytes[0] -eq 0x4D -and $peBytes[1] -eq 0x5A) 'Built output is not a PE executable.'

    $onlineResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @('--edition', 'Full', '--version', '0.0.1-test', '--non-interactive')
    if ($onlineResult.ExitCode -eq 4 -and $onlineResult.Output.Count -eq 1 -and $onlineResult.Output[0] -match 'PSH_E_EXECUTION_POLICY') {
        Write-Warning 'Windows CI execution policy forbids unsigned fixture scripts; forwarding checks are deferred for this runner.'
    }
    else {
        Assert-PshGoal5Bootstrapper ($onlineResult.ExitCode -eq 23) ('Online script exit code was not passed through: {0}' -f $onlineResult.ExitCode)
        $onlinePayload = Get-Content -LiteralPath $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-PshGoal5Bootstrapper ($onlinePayload.mode -ceq 'online' -and $onlinePayload.edition -ceq 'Full' -and $onlinePayload.version -ceq '0.0.1-test' -and $onlinePayload.nonInteractive) 'Online forwarding payload was incorrect.'

        $offlineResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @('--offline', '--edition', 'Core', '--version', 'latest')
        Assert-PshGoal5Bootstrapper ($offlineResult.ExitCode -eq 29) ('Offline script exit code was not passed through: {0}' -f $offlineResult.ExitCode)
        $offlinePayload = Get-Content -LiteralPath $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-PshGoal5Bootstrapper ($offlinePayload.mode -ceq 'offline' -and $offlinePayload.edition -ceq 'Core' -and $offlinePayload.version -ceq 'latest') 'Offline forwarding payload was incorrect.'
    }

    [IO.File]::AppendAllText($runtimeOnline, "`n# tamper`n", $utf8NoBom)
    $integrityResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @()
    Assert-PshGoal5Bootstrapper ($integrityResult.ExitCode -eq 5 -and $integrityResult.Output.Count -eq 1) 'Tampered script did not return one-line integrity error 5.'
    $integrityEnvelope = $integrityResult.Output[0] | ConvertFrom-Json
    Assert-PshGoal5Bootstrapper ($integrityEnvelope.code -ceq 'PSH_E_INTEGRITY' -and [int]$integrityEnvelope.exitCode -eq 5) 'Integrity envelope fields were incorrect.'

    $usageResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @('--not-allowed')
    Assert-PshGoal5Bootstrapper ($usageResult.ExitCode -eq 2) 'Unknown option did not return usage exit code 2.'

    [IO.File]::WriteAllBytes($runtimeOnline, $runtimeOnlineBytes)

    [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference', 'RemoteSigned', 'Process')
    $remoteLocalResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @()
    Assert-PshGoal5Bootstrapper ($remoteLocalResult.ExitCode -eq 23) ('RemoteSigned did not allow an unsigned local script: {0}' -f $remoteLocalResult.ExitCode)

    Set-Content -LiteralPath $runtimeOnline -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
    Assert-PshGoal5Bootstrapper ((Get-PshSha256 -Path $runtimeOnline) -ceq $runtimeOnlineHash) 'Adding MOTW unexpectedly changed the primary script bytes.'

    $remoteInternetResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @()
    Assert-PshGoal5Bootstrapper ($remoteInternetResult.ExitCode -eq 4 -and $remoteInternetResult.Output.Count -eq 1) 'RemoteSigned did not reject an unsigned Internet-zone script.'
    $remoteInternetEnvelope = $remoteInternetResult.Output[0] | ConvertFrom-Json
    Assert-PshGoal5Bootstrapper ($remoteInternetEnvelope.code -ceq 'PSH_E_EXECUTION_POLICY' -and $remoteInternetEnvelope.effectivePolicy -ceq 'RemoteSigned') 'RemoteSigned Internet-zone denial envelope was incorrect.'

    Set-Content -LiteralPath $runtimeOnline -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=9" -Encoding ASCII
    $unknownZoneResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @()
    Assert-PshGoal5Bootstrapper ($unknownZoneResult.ExitCode -eq 4 -and $unknownZoneResult.Output.Count -eq 1) 'Unknown ZoneId did not fail closed with dependency exit 4.'
    $unknownZoneEnvelope = $unknownZoneResult.Output[0] | ConvertFrom-Json
    Assert-PshGoal5Bootstrapper ($unknownZoneEnvelope.code -ceq 'PSH_E_EXECUTION_POLICY_PROBE' -and [int]$unknownZoneEnvelope.exitCode -eq 4) 'Unknown ZoneId did not return the policy-probe error envelope.'

    Set-Content -LiteralPath $runtimeOnline -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nHostUrl=https://example.invalid" -Encoding ASCII
    $malformedZoneResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @('--non-interactive')
    Assert-PshGoal5Bootstrapper ($malformedZoneResult.ExitCode -eq 4 -and $malformedZoneResult.Output.Count -eq 1) 'Malformed Zone.Identifier did not fail closed with dependency exit 4.'
    $malformedZoneEnvelope = $malformedZoneResult.Output[0] | ConvertFrom-Json
    Assert-PshGoal5Bootstrapper ($malformedZoneEnvelope.code -ceq 'PSH_E_EXECUTION_POLICY_PROBE' -and [int]$malformedZoneEnvelope.exitCode -eq 4) 'Malformed Zone.Identifier did not return the policy-probe error envelope.'

    Set-Content -LiteralPath $runtimeOnline -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
    [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference', 'Unrestricted', 'Process')
    $unrestrictedNonInteractive = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @('--non-interactive')
    Assert-PshGoal5Bootstrapper ($unrestrictedNonInteractive.ExitCode -eq 4 -and $unrestrictedNonInteractive.Output.Count -eq 1) 'Unrestricted non-interactive mode did not reject an unsigned Internet-zone prompt.'
    $unrestrictedEnvelope = $unrestrictedNonInteractive.Output[0] | ConvertFrom-Json
    Assert-PshGoal5Bootstrapper ($unrestrictedEnvelope.code -ceq 'PSH_E_EXECUTION_POLICY' -and $unrestrictedEnvelope.effectivePolicy -ceq 'Unrestricted') 'Unrestricted non-interactive denial envelope was incorrect.'

    [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference', 'Bypass', 'Process')
    $existingBypassResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @('--non-interactive')
    Assert-PshGoal5Bootstrapper ($existingBypassResult.ExitCode -eq 23) 'Bootstrapper did not respect an already-configured Bypass process policy.'

    Remove-Item -LiteralPath $runtimeOnline -Stream 'Zone.Identifier' -Force
    [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference', 'AllSigned', 'Process')
    $allSignedResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @()
    Assert-PshGoal5Bootstrapper ($allSignedResult.ExitCode -eq 4 -and $allSignedResult.Output.Count -eq 1) 'AllSigned did not reject the unsigned local fixture.'
    $allSignedEnvelope = $allSignedResult.Output[0] | ConvertFrom-Json
    Assert-PshGoal5Bootstrapper ($allSignedEnvelope.code -ceq 'PSH_E_EXECUTION_POLICY' -and $allSignedEnvelope.effectivePolicy -ceq 'AllSigned') 'AllSigned denial envelope was incorrect.'

    [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference', 'Restricted', 'Process')
    $policyResult = Invoke-PshBootstrapperProcess -Executable $runtimeOutput -Arguments @()
    Assert-PshGoal5Bootstrapper ($policyResult.ExitCode -eq 4 -and $policyResult.Output.Count -eq 1) 'Restricted Process policy did not return a one-line error with exit 4.'
    $policyEnvelope = $policyResult.Output[0] | ConvertFrom-Json
    Assert-PshGoal5Bootstrapper ($policyEnvelope.code -ceq 'PSH_E_EXECUTION_POLICY' -and [int]$policyEnvelope.exitCode -eq 4 -and $policyEnvelope.effectivePolicy -ceq 'Restricted' -and $policyEnvelope.PSObject.Properties.Name -contains 'governedByGpo' -and $policyEnvelope.remediation -match 'Set-ExecutionPolicy') 'Policy denial envelope did not contain the required fields.'
}
finally {
    [Environment]::SetEnvironmentVariable('PSH_BOOTSTRAPPER_CAPTURE', $oldCapture, 'Process')
    [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference', $oldPolicyPreference, 'Process')
    if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ('Goal 5 bootstrapper acceptance passed ({0} assertions).' -f $script:Assertions)
