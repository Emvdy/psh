# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent ([string]$MyInvocation.MyCommand.Path))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$script:Goal5AcquisitionAssertions = 0
$acquisitionPath = Join-Path $RepositoryRoot 'src/install/PackageAcquisition.ps1'
. $acquisitionPath

function Assert-PshGoal5Acquisition {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
    $script:Goal5AcquisitionAssertions++
    if (-not $Condition) { throw "Goal 5 acquisition failed: $Message" }
}

function Assert-PshGoal5AcquisitionFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Label
    )
    $failed = $false
    try { & $Action | Out-Null }
    catch {
        $failed = $true
        $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
        Assert-PshGoal5Acquisition ([int]$metadata.ExitCode -eq $ExitCode) "$Label used exit code $($metadata.ExitCode), expected $ExitCode (actual error id: $($metadata.ErrorId); message: $($_.Exception.Message))."
        Assert-PshGoal5Acquisition ([string]$metadata.ErrorId -ceq $ErrorId) "$Label used error id $($metadata.ErrorId), expected $ErrorId."
    }
    Assert-PshGoal5Acquisition $failed "$Label unexpectedly succeeded."
}

function Write-PshGoal5AcquisitionText {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-PshGoal5AcquisitionJson {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object] $Value)
    Write-PshGoal5AcquisitionText -Path $Path -Text ((ConvertTo-PshCanonicalJson -InputObject $Value) + "`n")
}

function New-PshGoal5AcquisitionResponse {
    param(
        [Parameter(Mandatory = $true)][int] $StatusCode,
        [Parameter(Mandatory = $true)][string] $ResponseUri,
        [Parameter()][AllowNull()][string] $Location,
        [Parameter()][AllowNull()][byte[]] $Bytes,
        [Parameter()][AllowNull()][object] $ContentLength
    )
    if ($null -eq $Bytes) { $Bytes = New-Object byte[] 0 }
    if ($null -eq $ContentLength) { $ContentLength = [int64]$Bytes.Length }
    $stream = New-Object IO.MemoryStream(, $Bytes)
    return [pscustomobject][ordered]@{
        StatusCode = $StatusCode
        ResponseUri = $ResponseUri
        Location = $Location
        Headers = @{}
        ContentLength = [int64]$ContentLength
        Stream = $stream
        Disposable = $stream
    }
}

function Assert-PshGoal5NoAcquisitionStage {
    param([Parameter(Mandatory = $true)][string] $Directory, [Parameter(Mandatory = $true)][string] $Label)
    $stageCount = if ([IO.Directory]::Exists($Directory)) { [IO.Directory]::GetFiles($Directory, '.psh-download-*.tmp').Length } else { 0 }
    Assert-PshGoal5Acquisition ($stageCount -eq 0) "$Label left an acquisition stage file."
}

function Get-PshGoal5AcquisitionStreamBase64 {
    param([Parameter(Mandatory = $true)][IO.Stream] $Stream)

    $Stream.Position = 0
    $memory = New-Object IO.MemoryStream
    try {
        $Stream.CopyTo($memory)
        return [Convert]::ToBase64String($memory.ToArray())
    }
    finally {
        $memory.Dispose()
        if ($Stream.CanSeek) { $Stream.Position = 0 }
    }
}

function New-PshGoal5AcquisitionDirectoryLink {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Target
    )

    try {
        $itemType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $itemType -Path $Path -Target $Target -ErrorAction Stop)
        return $true
    }
    catch { return $false }
}

function New-PshGoal5AcquisitionFixture {
    param([Parameter(Mandatory = $true)][string] $Root)

    [void][IO.Directory]::CreateDirectory($Root)
    $encoding = New-Object Text.UTF8Encoding($false)
    $version = '2.3.4'
    $commit = 'abcdef0123456789abcdef0123456789abcdef01'
    $assetData = [ordered]@{
        "psh-$version-core.zip" = $encoding.GetBytes('core acquisition payload')
        "psh-$version-full-win-x64.zip" = $encoding.GetBytes('full x64 acquisition payload')
        "psh-$version-full-win-arm64.zip" = $encoding.GetBytes('full arm64 acquisition payload')
    }
    $assets = @()
    foreach ($slot in @(
        @{ Name = "psh-$version-core.zip"; Edition = 'Core'; Architecture = 'any' },
        @{ Name = "psh-$version-full-win-x64.zip"; Edition = 'Full'; Architecture = 'win-x64' },
        @{ Name = "psh-$version-full-win-arm64.zip"; Edition = 'Full'; Architecture = 'win-arm64' }
    )) {
        $bytes = [byte[]]$assetData[[string]$slot.Name]
        $sha256 = Get-PshLifecycleSha256Bytes -Bytes $bytes
        $assets += [pscustomobject][ordered]@{
            name = [string]$slot.Name
            role = 'package'
            url = "https://github.com/Emvdy/psh/releases/download/v$version/$($slot.Name)"
            length = [int64]$bytes.Length
            sha256 = $sha256
            package = [pscustomobject][ordered]@{
                version = $version
                edition = [string]$slot.Edition
                architecture = [string]$slot.Architecture
                packageManifestSha256 = ('1' * 64)
                treeSha256 = ('2' * 64)
                testOnly = $false
            }
        }
    }
    $index = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        repository = 'https://github.com/Emvdy/psh'
        version = $version
        tag = "v$version"
        sourceCommit = $commit
        assets = $assets
    }
    $indexPath = Join-Path $Root "psh-release-$version.json"
    Write-PshGoal5AcquisitionJson -Path $indexPath -Value $index
    $checksumPath = Join-Path $Root 'SHA256SUMS'
    $checksumText = (@($assets | ForEach-Object { '{0}  {1}' -f [string]$_.sha256, [string]$_.name }) -join "`n") + "`n"
    Write-PshGoal5AcquisitionText -Path $checksumPath -Text $checksumText
    $catalogPath = Join-Path $Root 'release.cat'
    [IO.File]::WriteAllBytes($catalogPath, $encoding.GetBytes('catalog fixture'))
    $policy = [pscustomobject][ordered]@{
        schemaVersion = 1
        publisher = 'Emvdy Software'
        subjectDistinguishedNames = @('CN=Emvdy Software, O=Emvdy')
        requiredEkuOids = @('1.3.6.1.5.5.7.3.3')
        requiredCertificatePolicyOids = @()
        allowedRootCertificateSha256 = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    }
    $script:Goal5AcquisitionFixturePolicy = $policy
    try {
        $trusted = Confirm-PshReleaseTrustBundle -IndexPath $indexPath -ChecksumPath $checksumPath -CatalogPath $catalogPath
    }
    finally { Remove-Variable Goal5AcquisitionFixturePolicy -Scope Script -ErrorAction SilentlyContinue }
    return [pscustomobject][ordered]@{
        Root = $Root
        Version = $version
        Assets = $assets
        AssetData = $assetData
        TrustedRelease = $trusted
        CoreName = [string]$assets[0].name
        CoreBytes = [byte[]]$assetData[[string]$assets[0].name]
    }
}

Assert-PshGoal5Acquisition ([IO.File]::Exists($acquisitionPath)) 'PackageAcquisition.ps1 is missing.'
foreach ($name in @(
    'ConvertTo-PshFixedReleaseTag', 'Resolve-PshTrustedReleaseAsset',
    'Resolve-PshTrustedPackageAsset', 'Confirm-PshTrustedAssetFile',
    'Save-PshTrustedReleaseAsset', 'Test-PshTrustedAssetHandle',
    'Assert-PshTrustedAssetHandle'
)) {
    Assert-PshGoal5Acquisition ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) "Public helper is missing: $name"
}

$acquisitionTokens = $null
$acquisitionParseErrors = $null
$acquisitionAst = [System.Management.Automation.Language.Parser]::ParseFile(
    [IO.Path]::GetFullPath($acquisitionPath),
    [ref]$acquisitionTokens,
    [ref]$acquisitionParseErrors
)
Assert-PshGoal5Acquisition ($acquisitionParseErrors.Count -eq 0) 'PackageAcquisition.ps1 has parser errors.'
$acquisitionFunctions = @($acquisitionAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
$acquisitionParameters = @($acquisitionFunctions | ForEach-Object {
        if ($null -ne $_.Body.ParamBlock) { $_.Body.ParamBlock.Parameters }
    })
Assert-PshGoal5Acquisition (@($acquisitionFunctions | Where-Object { $_.Name -like '*TestCore' }).Count -eq 0) 'Production acquisition source exposes a TestCore function.'
Assert-PshGoal5Acquisition (@($acquisitionParameters | Where-Object { $_.Name.VariablePath.UserPath -in @('Transport', 'UseBeforePublishTestHook', 'BeforePublish', 'Hook', 'Watcher') }).Count -eq 0) 'Production acquisition source exposes a transport or hook parameter.'
Assert-PshGoal5Acquisition (@($acquisitionParameters | Where-Object { $_.StaticType -eq [scriptblock] }).Count -eq 0) 'Production acquisition source exposes a scriptblock parameter.'
$acquisitionSource = [IO.File]::ReadAllText([IO.Path]::GetFullPath($acquisitionPath))
Assert-PshGoal5Acquisition ($acquisitionSource -notmatch 'Save-PshTrustedReleaseAssetTestCore|UseBeforePublishTestHook|PshAcquisitionBeforePublishTestHook') 'Production acquisition source retains test hook state or entry points.'
$productionSaveCommand = Get-Command Save-PshTrustedReleaseAsset -CommandType Function
$productionOneRequestCommand = Get-Command Invoke-PshAcquisitionOneRequest -CommandType Function
$productionCoreCommand = Get-Command Invoke-PshSaveTrustedReleaseAssetCore -CommandType Function
Assert-PshGoal5Acquisition (-not $productionSaveCommand.Parameters.ContainsKey('Transport') -and -not $productionOneRequestCommand.Parameters.ContainsKey('Transport') -and -not $productionCoreCommand.Parameters.ContainsKey('Transport')) 'Runtime acquisition API exposes a caller-supplied transport.'
Assert-PshGoal5Acquisition ($null -eq (Get-Command Save-PshTrustedReleaseAssetTestCore -CommandType Function -ErrorAction SilentlyContinue)) 'Runtime acquisition API exposes Save-PshTrustedReleaseAssetTestCore.'

Assert-PshGoal5Acquisition ((ConvertTo-PshFixedReleaseTag -Version '1.2.3') -ceq 'v1.2.3') 'Exact release version did not become a fixed tag.'
Assert-PshGoal5Acquisition ((ConvertTo-PshFixedReleaseTag -Version '1.2.3-test.1') -ceq 'v1.2.3-test.1') 'Prerelease version did not become a fixed tag.'
foreach ($floating in @('latest', 'HEAD', 'main', 'master', 'refs/heads/main', 'origin/main')) {
    $floatingValue = $floating
    Assert-PshGoal5AcquisitionFailure -Action { ConvertTo-PshFixedReleaseTag -Version $floatingValue } -ExitCode 5 -ErrorId PshFloatingReleaseRef -Label "floating release ref '$floatingValue'"
}
Assert-PshGoal5AcquisitionFailure -Action { ConvertTo-PshFixedReleaseTag -Version '1.2' } -ExitCode 5 -ErrorId PshInvalidVersion -Label 'invalid fixed release version'

$script:Goal5OriginalAcquisitionHttpRequest = (Get-Command Invoke-PshAcquisitionHttpRequest -CommandType Function).ScriptBlock
$script:Goal5OriginalAcquisitionOneRequest = (Get-Command Invoke-PshAcquisitionOneRequest -CommandType Function).ScriptBlock
$script:Goal5OriginalSaveTrustedReleaseAsset = (Get-Command Save-PshTrustedReleaseAsset -CommandType Function).ScriptBlock
$script:Goal5OriginalAssertAcquisitionOwnedStageStable = (Get-Command Assert-PshAcquisitionOwnedStageStable -CommandType Function).ScriptBlock
$script:Goal5OriginalProductionPublisherPolicy = (Get-Command Get-PshProductionPublisherPolicy -CommandType Function).ScriptBlock
$script:Goal5OriginalWindowsCatalogTrustVerifier = (Get-Command Invoke-PshWindowsCatalogTrustVerifier -CommandType Function).ScriptBlock
$testRoot = $null
try {
    function Invoke-PshAcquisitionHttpRequest {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)][object] $Request)

        $transportVariable = Get-Variable Goal5AcquisitionTransport -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $transportVariable -or $transportVariable.Value -isnot [scriptblock]) {
            throw 'Goal 5 acquisition transport is not configured.'
        }
        return & ([scriptblock]$transportVariable.Value) $Request
    }

    function Invoke-PshAcquisitionOneRequest {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][Uri] $Uri,
            [Parameter()][AllowNull()][scriptblock] $Transport
        )

        if (-not $PSBoundParameters.ContainsKey('Transport')) {
            return & $script:Goal5OriginalAcquisitionOneRequest -Uri $Uri
        }
        $before = Get-Variable Goal5AcquisitionTransport -Scope Script -ErrorAction SilentlyContinue
        $beforeExists = $null -ne $before
        $beforeValue = if ($beforeExists) { $before.Value } else { $null }
        Set-Variable Goal5AcquisitionTransport -Scope Script -Value $Transport
        try { return & $script:Goal5OriginalAcquisitionOneRequest -Uri $Uri }
        finally {
            if (-not $beforeExists) { Remove-Variable Goal5AcquisitionTransport -Scope Script -ErrorAction SilentlyContinue }
            else { Set-Variable Goal5AcquisitionTransport -Scope Script -Value $beforeValue }
        }
    }

    function Save-PshTrustedReleaseAsset {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][object] $TrustedRelease,
            [Parameter(Mandatory = $true)][string] $AssetName,
            [Parameter(Mandatory = $true)][string] $DestinationPath,
            [Parameter()][AllowNull()][string] $InitialUri,
            [Parameter()][switch] $Offline,
            [Parameter()][AllowNull()][scriptblock] $Transport
        )

        $arguments = @{
            TrustedRelease = $TrustedRelease
            AssetName = $AssetName
            DestinationPath = $DestinationPath
            InitialUri = $InitialUri
            Offline = $Offline
        }
        if (-not $PSBoundParameters.ContainsKey('Transport')) {
            return & $script:Goal5OriginalSaveTrustedReleaseAsset @arguments
        }
        $before = Get-Variable Goal5AcquisitionTransport -Scope Script -ErrorAction SilentlyContinue
        $beforeExists = $null -ne $before
        $beforeValue = if ($beforeExists) { $before.Value } else { $null }
        Set-Variable Goal5AcquisitionTransport -Scope Script -Value $Transport
        try { return & $script:Goal5OriginalSaveTrustedReleaseAsset @arguments }
        finally {
            if (-not $beforeExists) { Remove-Variable Goal5AcquisitionTransport -Scope Script -ErrorAction SilentlyContinue }
            else { Set-Variable Goal5AcquisitionTransport -Scope Script -Value $beforeValue }
        }
    }

    function Assert-PshAcquisitionOwnedStageStable {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $true)][object] $ExpectedState
        )

        $observerVariable = Get-Variable Goal5AcquisitionStageObserver -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $observerVariable -and $observerVariable.Value -is [scriptblock]) {
            $observer = [scriptblock]$observerVariable.Value
            Remove-Variable Goal5AcquisitionStageObserver -Scope Script -ErrorAction SilentlyContinue
            & $observer ([pscustomobject][ordered]@{
                    StagePath = $Path
                    Length = [int64](Get-PshLifecycleProperty $ExpectedState 'Length')
                    Sha256 = [string](Get-PshLifecycleProperty $ExpectedState 'Sha256')
                })
        }
        return & $script:Goal5OriginalAssertAcquisitionOwnedStageStable -Path $Path -ExpectedState $ExpectedState
    }

    function Get-PshProductionPublisherPolicy {
        [CmdletBinding()]
        param()

        $policyVariable = Get-Variable Goal5AcquisitionFixturePolicy -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $policyVariable) { throw 'Goal 5 publisher policy is not configured.' }
        return Assert-PshPublisherPolicy -Policy $policyVariable.Value
    }

    function Invoke-PshWindowsCatalogTrustVerifier {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)][object] $Request)

        $policyVariable = Get-Variable Goal5AcquisitionFixturePolicy -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $policyVariable) { throw 'Goal 5 publisher policy is not configured.' }
        return [pscustomobject][ordered]@{
            Trusted = $true
            Publisher = [string](Get-PshLifecycleProperty $policyVariable.Value 'publisher')
        }
    }

    $temporaryBase = if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and [IO.Directory]::Exists('/private/tmp')) { '/private/tmp' } else { [IO.Path]::GetTempPath() }
    $testRoot = Join-Path $temporaryBase ('psh-goal5-acquisition-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($testRoot)

    $pathProbePath = Join-Path $testRoot 'readwrite-handle-path-probe.bin'
    $pathProbeBytes = (New-Object Text.UTF8Encoding($false)).GetBytes('path probe')
    $pathProbeStream = New-Object IO.FileStream($pathProbePath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::Read))
    try {
        $pathProbeStream.Write($pathProbeBytes, 0, $pathProbeBytes.Length)
        try { $pathProbeStream.Flush($true) } catch { $pathProbeStream.Flush() }
        $pathProbeState = Get-PshAcquisitionPathState -Path $pathProbePath -Description 'Goal 5 read/write handle path probe'
        Assert-PshGoal5Acquisition ([int64]$pathProbeState.Length -eq [int64]$pathProbeBytes.Length -and
            [string]$pathProbeState.Sha256 -ceq (Get-PshLifecycleSha256Bytes -Bytes $pathProbeBytes)) 'Read-only acquisition path CAS could not coexist with an owned read/write handle.'
    }
    finally { $pathProbeStream.Dispose() }

    $fixture = New-PshGoal5AcquisitionFixture -Root (Join-Path $testRoot 'release')
    $trusted = $fixture.TrustedRelease
    $coreAsset = Resolve-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName
    Assert-PshGoal5Acquisition ([string]$coreAsset.name -ceq $fixture.CoreName -and [string]$coreAsset.sha256 -ceq [string]$fixture.Assets[0].sha256) 'Trusted release asset did not resolve.'
    Assert-PshGoal5Acquisition ([string](Resolve-PshTrustedPackageAsset -TrustedRelease $trusted -Edition Core -Architecture any).name -ceq $fixture.CoreName) 'Core/any package slot did not resolve.'
    Assert-PshGoal5Acquisition ([string](Resolve-PshTrustedPackageAsset -TrustedRelease $trusted -Edition Full -Architecture win-x64).package.architecture -ceq 'win-x64') 'Full/win-x64 package slot did not resolve.'
    Assert-PshGoal5Acquisition ([string](Resolve-PshTrustedPackageAsset -TrustedRelease $trusted -Edition Full -Architecture win-arm64).package.architecture -ceq 'win-arm64') 'Full/win-arm64 package slot did not resolve.'
    Assert-PshGoal5AcquisitionFailure -Action { Resolve-PshTrustedPackageAsset -TrustedRelease $trusted -Edition Core -Architecture win-x64 } -ExitCode 5 -ErrorId PshPackageSlot -Label 'invalid Core RID slot'
    Assert-PshGoal5AcquisitionFailure -Action { Resolve-PshTrustedPackageAsset -TrustedRelease $trusted -Edition Full -Architecture any } -ExitCode 5 -ErrorId PshPackageSlot -Label 'invalid Full any slot'
    Assert-PshGoal5AcquisitionFailure -Action { Resolve-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName 'missing.zip' } -ExitCode 5 -ErrorId PshReleaseAssetMissing -Label 'missing trusted asset'

    $trusted.Index.assets[0].sha256 = ('f' * 64)
    Assert-PshGoal5Acquisition ([string](Resolve-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName).sha256 -ceq [string]$fixture.Assets[0].sha256) 'Public release handle mutation changed acquisition metadata.'
    $forgedRelease = [pscustomobject]@{ TrustToken = $trusted.TrustToken; Trusted = $true; Index = $trusted.Index }
    Assert-PshGoal5AcquisitionFailure -Action { Resolve-PshTrustedReleaseAsset -TrustedRelease $forgedRelease -AssetName $fixture.CoreName } -ExitCode 5 -ErrorId PshUntrustedRelease -Label 'forged acquisition release handle'

    $downloads = Join-Path $testRoot 'downloads'
    [void][IO.Directory]::CreateDirectory($downloads)
    $directPath = Join-Path $downloads $fixture.CoreName
    $script:Goal5DirectCalls = 0
    $script:Goal5DirectBytes = $fixture.CoreBytes
    $directTransport = {
        param($request)
        $script:Goal5DirectCalls++
        Assert-PshGoal5Acquisition ([string]$request.Method -ceq 'GET' -and -not [bool]$request.AllowAutoRedirect) 'Transport request did not disable automatic redirects.'
        New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $script:Goal5DirectBytes
    }
    $direct = Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $directPath -Transport $directTransport
    Assert-PshGoal5Acquisition ($direct -is [IO.FileStream] -and $direct -is [IDisposable]) 'Direct acquisition did not return a disposable FileStream handle.'
    Assert-PshGoal5Acquisition (Test-PshTrustedAssetHandle -InputObject $direct) 'Direct acquisition handle is not registered as trusted.'
    $directRecord = Assert-PshTrustedAssetHandle -InputObject $direct
    Assert-PshGoal5Acquisition ([string]$directRecord.Status -ceq 'Downloaded' -and [int]$directRecord.RedirectCount -eq 0) 'Direct 200 acquisition did not publish.'
    Assert-PshGoal5Acquisition ($script:Goal5DirectCalls -eq 1) 'Direct acquisition did not invoke transport exactly once.'
    Assert-PshGoal5Acquisition ((Get-PshGoal5AcquisitionStreamBase64 -Stream $direct) -ceq [Convert]::ToBase64String($fixture.CoreBytes)) 'Direct handle does not read the authenticated bytes.'
    Assert-PshGoal5Acquisition ([string](Get-PshLifecycleFileSha256 -Path $directPath).Sha256 -ceq [string]$fixture.Assets[0].sha256) 'Direct acquisition published wrong bytes.'
    $direct.Path = 'forged-public-path'
    $direct.Sha256 = ('f' * 64)
    $direct.Status = 'Forged'
    $directRegistered = Assert-PshTrustedAssetHandle -InputObject $direct
    Assert-PshGoal5Acquisition ([string]$directRegistered.Path -ceq $directPath -and [string]$directRegistered.Sha256 -ceq [string]$fixture.Assets[0].sha256 -and [string]$directRegistered.Status -ceq 'Downloaded') 'Public asset-handle mutation changed the registered snapshot.'
    $copiedToken = $direct.TrustToken
    $direct.Dispose()
    Assert-PshGoal5Acquisition (-not (Test-PshTrustedAssetHandle -InputObject $direct)) 'Disposed asset handle remained trusted.'
    Assert-PshGoal5AcquisitionFailure -Action { Assert-PshTrustedAssetHandle -InputObject $direct } -ExitCode 5 -ErrorId PshUntrustedAssetHandle -Label 'disposed trusted asset handle'
    $forgedAssetStream = New-Object IO.FileStream($directPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
    $forgedAssetStream | Add-Member -NotePropertyName TrustToken -NotePropertyValue $copiedToken
    Assert-PshGoal5Acquisition (-not (Test-PshTrustedAssetHandle -InputObject $forgedAssetStream)) 'Copied asset TrustToken forged a trusted stream handle.'
    $forgedAssetStream.Dispose()
    Assert-PshGoal5NoAcquisitionStage -Directory $downloads -Label 'direct acquisition'

    $script:Goal5ExistingCalls = 0
    $existing = Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $directPath -Transport { $script:Goal5ExistingCalls++; throw 'transport must not run' }
    Assert-PshGoal5Acquisition ((Test-PshTrustedAssetHandle -InputObject $existing) -and [string](Assert-PshTrustedAssetHandle -InputObject $existing).Status -ceq 'Existing') 'Matching destination was not returned as a trusted idempotent handle.'
    Assert-PshGoal5Acquisition ($script:Goal5ExistingCalls -eq 0) 'Matching destination invoked transport.'
    $existing.Dispose()

    $localPath = Join-Path $downloads 'local-core.zip'
    [IO.File]::WriteAllBytes($localPath, $fixture.CoreBytes)
    $local = Confirm-PshTrustedAssetFile -TrustedRelease $trusted -AssetName $fixture.CoreName -Path $localPath
    Assert-PshGoal5Acquisition ((Test-PshTrustedAssetHandle -InputObject $local) -and [string](Assert-PshTrustedAssetHandle -InputObject $local).Sha256 -ceq [string]$fixture.Assets[0].sha256) 'Local trusted asset validation failed.'
    $local.Dispose()
    $localTampered = [byte[]]$fixture.CoreBytes.Clone()
    $localTampered[0] = [byte]($localTampered[0] -bxor 1)
    [IO.File]::WriteAllBytes($localPath, $localTampered)
    Assert-PshGoal5AcquisitionFailure -Action { Confirm-PshTrustedAssetFile -TrustedRelease $trusted -AssetName $fixture.CoreName -Path $localPath } -ExitCode 5 -ErrorId PshAcquisitionHash -Label 'tampered local asset'
    Assert-PshGoal5AcquisitionFailure -Action { Confirm-PshTrustedAssetFile -TrustedRelease $forgedRelease -AssetName $fixture.CoreName -Path $localPath } -ExitCode 5 -ErrorId PshUntrustedRelease -Label 'bare hash without trusted release metadata'

    $replacePath = Join-Path $downloads 'replace-after-return.zip'
    [IO.File]::WriteAllBytes($replacePath, $fixture.CoreBytes)
    $replaceHandle = Confirm-PshTrustedAssetFile -TrustedRelease $trusted -AssetName $fixture.CoreName -Path $replacePath
    $replaceBackup = $replacePath + '.authenticated'
    $replaceSucceeded = $false
    try {
        [IO.File]::Move($replacePath, $replaceBackup)
        [IO.File]::WriteAllBytes($replacePath, (New-Object Text.UTF8Encoding($false)).GetBytes('attacker replacement'))
        $replaceSucceeded = $true
    }
    catch { }
    Assert-PshGoal5Acquisition ((Get-PshGoal5AcquisitionStreamBase64 -Stream $replaceHandle) -ceq [Convert]::ToBase64String($fixture.CoreBytes)) 'Returned handle stopped reading the authenticated bytes after path replacement.'
    Assert-PshGoal5Acquisition ([string](Assert-PshTrustedAssetHandle -InputObject $replaceHandle).Sha256 -ceq [string]$fixture.Assets[0].sha256) 'Path replacement changed the registered trusted asset record.'
    if ($replaceSucceeded) {
        Assert-PshGoal5Acquisition ([IO.File]::ReadAllText($replacePath) -ceq 'attacker replacement') 'Path replacement fixture did not replace the public path.'
    }
    $replaceHandle.Dispose()

    $conflictPath = Join-Path $downloads 'conflict.zip'
    [IO.File]::WriteAllBytes($conflictPath, (New-Object Text.UTF8Encoding($false)).GetBytes('preexisting owner bytes'))
    $conflictBefore = [IO.File]::ReadAllBytes($conflictPath)
    $script:Goal5ConflictCalls = 0
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $conflictPath -Transport { $script:Goal5ConflictCalls++; throw 'transport must not run' }
    } -ExitCode 5 -ErrorId PshAcquisitionDestinationConflict -Label 'mismatching existing destination'
    Assert-PshGoal5Acquisition ($script:Goal5ConflictCalls -eq 0) 'Mismatching existing destination invoked transport.'
    Assert-PshGoal5Acquisition ([Convert]::ToBase64String([IO.File]::ReadAllBytes($conflictPath)) -ceq [Convert]::ToBase64String($conflictBefore)) 'Mismatching existing destination was overwritten.'

    $script:Goal5InitialUriCalls = 0
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'wrong-uri.zip') -InitialUri 'https://github.com/Emvdy/psh/releases/download/v2.3.4/other.zip' -Transport { $script:Goal5InitialUriCalls++ }
    } -ExitCode 5 -ErrorId PshAcquisitionInitialUri -Label 'unsigned initial URI'
    Assert-PshGoal5Acquisition ($script:Goal5InitialUriCalls -eq 0) 'Unsigned initial URI invoked transport.'
    $script:Goal5OfflineCalls = 0
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'offline.zip') -Offline -Transport { $script:Goal5OfflineCalls++ }
    } -ExitCode 4 -ErrorId PshAcquisitionOffline -Label 'offline acquisition'
    Assert-PshGoal5Acquisition ($script:Goal5OfflineCalls -eq 0) 'Offline acquisition invoked transport.'

    $redirectPath = Join-Path $downloads 'redirect.zip'
    $script:Goal5RedirectCalls = 0
    $script:Goal5RedirectBytes = $fixture.CoreBytes
    $redirectProbe = New-PshGoal5AcquisitionResponse -StatusCode 302 -ResponseUri ([string]$fixture.Assets[0].url) -Location 'https://release-assets.githubusercontent.com/probe'
    Assert-PshGoal5Acquisition ([string]$redirectProbe.Location -ceq 'https://release-assets.githubusercontent.com/probe') 'Redirect response fixture lost its Location value.'
    Assert-PshGoal5Acquisition ([string](Get-PshAcquisitionResponseLocation -Response $redirectProbe) -ceq 'https://release-assets.githubusercontent.com/probe') 'Acquisition response parser lost its Location value.'
    Close-PshAcquisitionResponse -Response $redirectProbe
    $wrappedRedirectProbe = Invoke-PshAcquisitionOneRequest -Uri ([Uri][string]$fixture.Assets[0].url) -Transport {
        param($request)
        New-PshGoal5AcquisitionResponse -StatusCode 302 -ResponseUri ([string]$request.Uri) -Location 'https://release-assets.githubusercontent.com/wrapped-probe'
    }
    Assert-PshGoal5Acquisition ([string](Get-PshAcquisitionResponseLocation -Response $wrappedRedirectProbe) -ceq 'https://release-assets.githubusercontent.com/wrapped-probe') 'One-request transport wrapper lost its Location value.'
    Close-PshAcquisitionResponse -Response $wrappedRedirectProbe
    $redirectTransport = {
        param($request)
        $script:Goal5RedirectCalls++
        if ($script:Goal5RedirectCalls -eq 1) {
            $redirectResponse = New-PshGoal5AcquisitionResponse -StatusCode 302 -ResponseUri ([string]$request.Uri) -Location 'https://release-assets.githubusercontent.com/github-production-release-asset/core.zip?sig=fixed'
            Assert-PshGoal5Acquisition (-not [string]::IsNullOrWhiteSpace([string]$redirectResponse.Location)) 'Redirect transport lost its Location value.'
            $redirectResponse
        }
        else {
            $redirectResponse = New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $script:Goal5RedirectBytes
            $redirectResponse
        }
    }
    $actualRedirectProbe = Invoke-PshAcquisitionOneRequest -Uri ([Uri][string]$fixture.Assets[0].url) -Transport $redirectTransport
    Assert-PshGoal5Acquisition ([string](Get-PshAcquisitionResponseLocation -Response $actualRedirectProbe) -ceq 'https://release-assets.githubusercontent.com/github-production-release-asset/core.zip?sig=fixed') 'Actual redirect transport lost its Location value through the wrapper.'
    Close-PshAcquisitionResponse -Response $actualRedirectProbe
    $script:Goal5RedirectCalls = 0
    $redirected = Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $redirectPath -Transport $redirectTransport
    Assert-PshGoal5Acquisition ([string]$redirected.Status -ceq 'Downloaded' -and [int]$redirected.RedirectCount -eq 1) 'Allowed redirect acquisition result is malformed.'
    Assert-PshGoal5Acquisition ([string]$redirected.FinalUri -ceq 'https://release-assets.githubusercontent.com/github-production-release-asset/core.zip?sig=fixed') 'Allowed redirect final URI is wrong.'
    Assert-PshGoal5Acquisition ($script:Goal5RedirectCalls -eq 2) 'Allowed redirect did not use two manual requests.'
    Assert-PshGoal5Acquisition (Test-PshTrustedAssetHandle -InputObject $redirected) 'Redirect acquisition did not return a trusted disposable handle.'
    $redirected.Dispose()
    Assert-PshGoal5NoAcquisitionStage -Directory $downloads -Label 'redirect acquisition'

    foreach ($redirectCase in @(
        @{ Label = 'disallowed redirect host'; Location = 'https://example.invalid/core.zip'; Id = 'PshAcquisitionRedirectBoundary' },
        @{ Label = 'HTTP redirect'; Location = 'http://release-assets.githubusercontent.com/core.zip'; Id = 'PshAcquisitionRedirectBoundary' },
        @{ Label = 'credential redirect'; Location = 'https://user@release-assets.githubusercontent.com/core.zip'; Id = 'PshAcquisitionRedirectBoundary' },
        @{ Label = 'custom-port redirect'; Location = 'https://release-assets.githubusercontent.com:444/core.zip'; Id = 'PshAcquisitionRedirectBoundary' }
    )) {
        $caseLocation = [string]$redirectCase.Location
        $casePath = Join-Path $downloads (([string]$redirectCase.Label).Replace(' ', '-') + '.zip')
        Assert-PshGoal5AcquisitionFailure -Action {
            Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $casePath -Transport {
                param($request)
                New-PshGoal5AcquisitionResponse -StatusCode 302 -ResponseUri ([string]$request.Uri) -Location $caseLocation
            }
        } -ExitCode 5 -ErrorId ([string]$redirectCase.Id) -Label ([string]$redirectCase.Label)
        Assert-PshGoal5NoAcquisitionStage -Directory $downloads -Label ([string]$redirectCase.Label)
    }

    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'missing-location.zip') -Transport {
            param($request)
            New-PshGoal5AcquisitionResponse -StatusCode 302 -ResponseUri ([string]$request.Uri)
        }
    } -ExitCode 5 -ErrorId PshAcquisitionRedirectLocation -Label 'redirect without Location'
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'hidden-redirect.zip') -Transport {
            param($request)
            New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri 'https://release-assets.githubusercontent.com/hidden.zip' -Bytes $fixture.CoreBytes
        }
    } -ExitCode 5 -ErrorId PshAcquisitionHiddenRedirect -Label 'hidden automatic redirect'

    $script:Goal5LoopCalls = 0
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'loop.zip') -Transport {
            param($request)
            $script:Goal5LoopCalls++
            $location = if ($script:Goal5LoopCalls -eq 1) {
                'https://release-assets.githubusercontent.com/loop-a'
            }
            elseif ($script:Goal5LoopCalls -eq 2) {
                'https://release-assets.githubusercontent.com/loop-b'
            }
            else {
                'https://release-assets.githubusercontent.com/loop-a'
            }
            New-PshGoal5AcquisitionResponse -StatusCode 302 -ResponseUri ([string]$request.Uri) -Location $location
        }
    } -ExitCode 5 -ErrorId PshAcquisitionRedirectLoop -Label 'redirect loop'
    Assert-PshGoal5Acquisition ($script:Goal5LoopCalls -eq 3) 'Redirect loop was not detected at the repeated URI.'

    $script:Goal5LimitCalls = 0
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'limit.zip') -Transport {
            param($request)
            $script:Goal5LimitCalls++
            New-PshGoal5AcquisitionResponse -StatusCode 302 -ResponseUri ([string]$request.Uri) -Location ("https://release-assets.githubusercontent.com/hop-$script:Goal5LimitCalls")
        }
    } -ExitCode 5 -ErrorId PshAcquisitionRedirectLimit -Label 'redirect limit'
    Assert-PshGoal5Acquisition ($script:Goal5LimitCalls -eq 6) 'Redirect limit did not allow exactly five redirects.'

    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads '404.zip') -Transport {
            param($request)
            New-PshGoal5AcquisitionResponse -StatusCode 404 -ResponseUri ([string]$request.Uri)
        }
    } -ExitCode 3 -ErrorId PshAcquisitionHttpStatus -Label 'HTTP 404'
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'transport-error.zip') -Transport { throw 'network unavailable' }
    } -ExitCode 3 -ErrorId PshAcquisitionTransport -Label 'transport exception'
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'multiple-response.zip') -Transport {
            param($request)
            New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $fixture.CoreBytes
            New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $fixture.CoreBytes
        }
    } -ExitCode 3 -ErrorId PshAcquisitionTransportResult -Label 'multiple transport responses'

    [byte[]]$shortBytes = $fixture.CoreBytes[0..($fixture.CoreBytes.Length - 2)]
    [byte[]]$longBytes = @($fixture.CoreBytes) + @([byte]0x21)
    [byte[]]$wrongHashBytes = $fixture.CoreBytes.Clone()
    $wrongHashBytes[0] = [byte]($wrongHashBytes[0] -bxor 1)
    foreach ($bodyCase in @(
        @{ Label = 'short body'; Bytes = $shortBytes; Id = 'PshAcquisitionLength' },
        @{ Label = 'long body'; Bytes = $longBytes; Id = 'PshAcquisitionLength' },
        @{ Label = 'hash mismatch body'; Bytes = $wrongHashBytes; Id = 'PshAcquisitionHash' }
    )) {
        $caseBytes = [byte[]]$bodyCase.Bytes
        $casePath = Join-Path $downloads (([string]$bodyCase.Label).Replace(' ', '-') + '.zip')
        Assert-PshGoal5AcquisitionFailure -Action {
            Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $casePath -Transport {
                param($request)
                New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $caseBytes -ContentLength ([int64]-1)
            }
        } -ExitCode 5 -ErrorId ([string]$bodyCase.Id) -Label ([string]$bodyCase.Label)
        Assert-PshGoal5Acquisition (-not [IO.File]::Exists($casePath)) "$($bodyCase.Label) published a destination."
        Assert-PshGoal5NoAcquisitionStage -Directory $downloads -Label ([string]$bodyCase.Label)
    }
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $downloads 'content-length.zip') -Transport {
            param($request)
            New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $fixture.CoreBytes -ContentLength 1
        }
    } -ExitCode 5 -ErrorId PshAcquisitionLength -Label 'wrong Content-Length'

    $racePath = Join-Path $downloads 'race.zip'
    $script:Goal5RacePath = $racePath
    $script:Goal5RaceBytes = $fixture.CoreBytes
    $raceOwnerBytes = (New-Object Text.UTF8Encoding($false)).GetBytes('race owner')
    $script:Goal5RaceOwnerBytes = $raceOwnerBytes
    Assert-PshGoal5AcquisitionFailure -Action {
        Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $racePath -Transport {
            param($request)
            [IO.File]::WriteAllBytes($script:Goal5RacePath, $script:Goal5RaceOwnerBytes)
            New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $script:Goal5RaceBytes
        }
    } -ExitCode 5 -ErrorId PshAcquisitionPublishRace -Label 'race-created destination'
    Assert-PshGoal5Acquisition ([Convert]::ToBase64String([IO.File]::ReadAllBytes($racePath)) -ceq [Convert]::ToBase64String($raceOwnerBytes)) 'Race-created destination was overwritten.'
    Assert-PshGoal5NoAcquisitionStage -Directory $downloads -Label 'race-created destination'

    $destinationTarget = Join-Path $testRoot 'destination-link-target'
    [void][IO.Directory]::CreateDirectory($destinationTarget)
    $destinationSentinel = Join-Path $destinationTarget 'sentinel.txt'
    Write-PshGoal5AcquisitionText -Path $destinationSentinel -Text 'destination sentinel'
    $destinationLink = Join-Path $testRoot 'destination-link'
    if (New-PshGoal5AcquisitionDirectoryLink -Path $destinationLink -Target $destinationTarget) {
        $script:Goal5DestinationLinkCalls = 0
        Assert-PshGoal5AcquisitionFailure -Action {
            Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath (Join-Path $destinationLink 'linked.zip') -Transport { $script:Goal5DestinationLinkCalls++; throw 'transport must not run' }
        } -ExitCode 5 -ErrorId PshReparsePoint -Label 'destination parent reparse ancestor'
        Assert-PshGoal5Acquisition ($script:Goal5DestinationLinkCalls -eq 0) 'Destination reparse ancestor invoked transport.'
        Assert-PshGoal5Acquisition ([IO.File]::ReadAllText($destinationSentinel) -ceq 'destination sentinel') 'Destination reparse rejection changed the external target.'
    }

    $localTarget = Join-Path $testRoot 'local-link-target'
    [void][IO.Directory]::CreateDirectory($localTarget)
    $linkedLocalFile = Join-Path $localTarget 'linked-local.zip'
    [IO.File]::WriteAllBytes($linkedLocalFile, $fixture.CoreBytes)
    $localSentinel = Join-Path $localTarget 'sentinel.txt'
    Write-PshGoal5AcquisitionText -Path $localSentinel -Text 'local sentinel'
    $localLink = Join-Path $testRoot 'local-link'
    if (New-PshGoal5AcquisitionDirectoryLink -Path $localLink -Target $localTarget) {
        Assert-PshGoal5AcquisitionFailure -Action {
            Confirm-PshTrustedAssetFile -TrustedRelease $trusted -AssetName $fixture.CoreName -Path (Join-Path $localLink 'linked-local.zip')
        } -ExitCode 5 -ErrorId PshReparsePoint -Label 'local asset reparse ancestor'
        Assert-PshGoal5Acquisition ([IO.File]::ReadAllText($localSentinel) -ceq 'local sentinel') 'Local reparse rejection changed the external target.'
    }

    $stageRaceDestination = Join-Path $downloads 'stage-race.zip'
    $script:Goal5StageRaceBytes = $fixture.CoreBytes
    $script:Goal5StageRacePath = $null
    $script:Goal5StageRaceOriginal = $null
    $script:Goal5StageRaceReplacement = (New-Object Text.UTF8Encoding($false)).GetBytes('replacement stage evidence')
    Assert-PshGoal5AcquisitionFailure -Action {
        $script:Goal5AcquisitionStageObserver = {
            param($request)
            $script:Goal5StageRacePath = [string]$request.StagePath
            $script:Goal5StageRaceOriginal = [string]$request.StagePath + '.authenticated'
            [IO.File]::Move($script:Goal5StageRacePath, $script:Goal5StageRaceOriginal)
            [IO.File]::WriteAllBytes($script:Goal5StageRacePath, $script:Goal5StageRaceReplacement)
        }
        try {
            Save-PshTrustedReleaseAsset -TrustedRelease $trusted -AssetName $fixture.CoreName -DestinationPath $stageRaceDestination -Transport {
                param($request)
                New-PshGoal5AcquisitionResponse -StatusCode 200 -ResponseUri ([string]$request.Uri) -Bytes $script:Goal5StageRaceBytes
            }
        }
        finally { Remove-Variable Goal5AcquisitionStageObserver -Scope Script -ErrorAction SilentlyContinue }
    } -ExitCode 5 -ErrorId PshAcquisitionStageChanged -Label 'stage replacement after hash'
    Assert-PshGoal5Acquisition (-not [IO.File]::Exists($stageRaceDestination)) 'Replaced stage was published.'
    Assert-PshGoal5Acquisition ([IO.File]::Exists([string]$script:Goal5StageRacePath) -and [IO.File]::Exists([string]$script:Goal5StageRaceOriginal)) 'Stage race evidence was not preserved.'
    Assert-PshGoal5Acquisition ([Convert]::ToBase64String([IO.File]::ReadAllBytes([string]$script:Goal5StageRacePath)) -ceq [Convert]::ToBase64String($script:Goal5StageRaceReplacement)) 'Stage cleanup deleted or changed the replacement evidence.'
    Assert-PshGoal5Acquisition ([string](Get-PshLifecycleFileSha256 -Path ([string]$script:Goal5StageRaceOriginal)).Sha256 -ceq [string]$fixture.Assets[0].sha256) 'Authenticated stage evidence was not preserved.'
}
finally {
    if ($null -ne $testRoot -and [IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    try { Set-Item Function:Invoke-PshAcquisitionHttpRequest -Value $script:Goal5OriginalAcquisitionHttpRequest -ErrorAction Stop } catch { }
    try { Set-Item Function:Invoke-PshAcquisitionOneRequest -Value $script:Goal5OriginalAcquisitionOneRequest -ErrorAction Stop } catch { }
    try { Set-Item Function:Save-PshTrustedReleaseAsset -Value $script:Goal5OriginalSaveTrustedReleaseAsset -ErrorAction Stop } catch { }
    try { Set-Item Function:Assert-PshAcquisitionOwnedStageStable -Value $script:Goal5OriginalAssertAcquisitionOwnedStageStable -ErrorAction Stop } catch { }
    try { Set-Item Function:Get-PshProductionPublisherPolicy -Value $script:Goal5OriginalProductionPublisherPolicy -ErrorAction Stop } catch { }
    try { Set-Item Function:Invoke-PshWindowsCatalogTrustVerifier -Value $script:Goal5OriginalWindowsCatalogTrustVerifier -ErrorAction Stop } catch { }
    Remove-Variable Goal5DirectCalls, Goal5DirectBytes, Goal5ExistingCalls, Goal5ConflictCalls, Goal5InitialUriCalls, Goal5OfflineCalls, Goal5RedirectCalls, Goal5RedirectBytes, Goal5LoopCalls, Goal5LimitCalls, Goal5RacePath, Goal5RaceBytes, Goal5RaceOwnerBytes, Goal5DestinationLinkCalls, Goal5StageRaceBytes, Goal5StageRacePath, Goal5StageRaceOriginal, Goal5StageRaceReplacement, Goal5AcquisitionTransport, Goal5AcquisitionStageObserver, Goal5AcquisitionFixturePolicy, Goal5OriginalAcquisitionHttpRequest, Goal5OriginalAcquisitionOneRequest, Goal5OriginalSaveTrustedReleaseAsset, Goal5OriginalAssertAcquisitionOwnedStageStable, Goal5OriginalProductionPublisherPolicy, Goal5OriginalWindowsCatalogTrustVerifier -Scope Script -ErrorAction SilentlyContinue
}

Write-Output "Goal 5 acquisition passed ($script:Goal5AcquisitionAssertions assertions)."
