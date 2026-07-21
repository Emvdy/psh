# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
    Release asset acquisition primitives. Every asset is resolved from a
    publisher-authenticated release handle. Redirects are followed manually,
    downloaded bytes are length/hash checked, and publication is an atomic
    non-overwriting move in the destination directory.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($null -eq (Get-Command -Name Assert-PshTrustedRelease -CommandType Function -ErrorAction SilentlyContinue)) {
    $trustPath = Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseTrust.ps1'
    if (-not [IO.File]::Exists($trustPath)) {
        throw "Psh release trust helpers were not found: $trustPath"
    }
    . $trustPath
}

$script:PshAcquisitionRedirectStatuses = @(301, 302, 303, 307, 308)
$script:PshAcquisitionCdnHosts = @(
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com'
)
$script:PshAcquisitionMaxRedirects = 5
$script:PshAcquisitionBufferSize = 65536
if ($null -eq (Get-Variable -Name PshTrustedAssetToken -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshTrustedAssetToken = New-Object object
}
if ($null -eq (Get-Variable -Name PshTrustedAssetRegistry -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PshTrustedAssetRegistry = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]'
}

function Throw-PshAcquisitionError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter()][AllowNull()][Exception] $InnerException
    )

    $kind = if ($ExitCode -eq 3) { 'Io' } elseif ($ExitCode -eq 4) { 'Dependency' } else { 'Integrity' }
    Throw-PshLifecycleError -ExitCode $ExitCode -Kind $kind -ErrorId $ErrorId -Message $Message -InnerException $InnerException
}

function ConvertTo-PshFixedReleaseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Version)

    if ($Version -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Version) -or
        [string]$Version -match '(?i)\A(?:latest|head|main|master|refs(?:/|\z)|origin(?:/|\z))') {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshFloatingReleaseRef' -Message 'Release acquisition requires an exact Semantic Version, not latest, HEAD, a branch, or another floating reference.'
    }
    $fixedVersion = Assert-PshLifecycleSemVer -Value $Version -Description 'Release version'
    return 'v' + $fixedVersion
}

function Resolve-PshTrustedReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $TrustedRelease,
        [Parameter(Mandatory = $true)][AllowNull()][object] $AssetName
    )

    $release = Assert-PshTrustedRelease -InputObject $TrustedRelease
    $name = Assert-PshReleaseLeafName -Value $AssetName -Description 'Requested release asset name'
    $assets = @((Get-PshLifecycleProperty (Get-PshLifecycleProperty $release 'Index') 'assets') |
        Where-Object { [string]$_.name -ceq $name })
    if ($assets.Count -ne 1) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshReleaseAssetMissing' -Message "Authenticated release does not contain asset '$name'."
    }
    return Copy-PshReleaseTrustData -InputObject $assets[0]
}

function Resolve-PshTrustedPackageAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $TrustedRelease,
        [Parameter(Mandatory = $true)][ValidateSet('Core', 'Full')][string] $Edition,
        [Parameter(Mandatory = $true)][ValidateSet('any', 'win-x64', 'win-arm64')][string] $Architecture
    )

    if (($Edition -ceq 'Core' -and $Architecture -cne 'any') -or
        ($Edition -ceq 'Full' -and $Architecture -notin @('win-x64', 'win-arm64'))) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshPackageSlot' -Message "Package slot '$Edition/$Architecture' is not valid."
    }
    $release = Assert-PshTrustedRelease -InputObject $TrustedRelease
    $assets = @((Get-PshLifecycleProperty (Get-PshLifecycleProperty $release 'Index') 'assets') | Where-Object {
            [string]$_.role -ceq 'package' -and $null -ne $_.package -and
            [string]$_.package.edition -ceq $Edition -and [string]$_.package.architecture -ceq $Architecture
        })
    if ($assets.Count -ne 1) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshPackageSlotMissing' -Message "Authenticated release does not contain exactly one package for '$Edition/$Architecture'."
    }
    return Copy-PshReleaseTrustData -InputObject $assets[0]
}

function ConvertTo-PshAcquisitionUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if ($Value -is [Uri]) {
        if (-not ([Uri]$Value).IsAbsoluteUri) {
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionUri' -Message "$Description must be absolute."
        }
        $text = ([Uri]$Value).AbsoluteUri
    }
    elseif ($Value -is [string]) { $text = [string]$Value }
    else {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionUri' -Message "$Description must be an absolute HTTPS URI."
    }
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 8192 -or $text -match '[\x00-\x1f\x7f]') {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionUri' -Message "$Description is malformed."
    }
    try { $uri = New-Object -TypeName Uri -ArgumentList ($text, [UriKind]::Absolute) }
    catch { Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionUri' -Message "$Description is invalid: $text" -InnerException $_.Exception }
    if (-not $uri.IsAbsoluteUri) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionUri' -Message "$Description must be absolute."
    }
    return $uri
}

function Resolve-PshAcquisitionRedirectUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Uri] $BaseUri,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Location
    )

    if ($Location -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Location) -or
        [string]$Location -match '[\x00-\x1f\x7f]' -or ([string]$Location).Length -gt 8192) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionRedirectLocation' -Message 'Redirect response has no valid Location header.'
    }
    try { $uri = New-Object -TypeName Uri -ArgumentList ($BaseUri, [string]$Location) }
    catch { Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionRedirectLocation' -Message 'Redirect Location is not a valid URI.' -InnerException $_.Exception }
    $redirectHost = $uri.DnsSafeHost.ToLowerInvariant()
    if ($uri.Scheme -cne 'https' -or -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or
        $script:PshAcquisitionCdnHosts -cnotcontains $redirectHost) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionRedirectBoundary' -Message "Redirect leaves the fixed HTTPS release CDN boundary: $($uri.AbsoluteUri)"
    }
    return $uri
}

function Get-PshAcquisitionResponseLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Response)

    $location = Get-PshLifecycleProperty $Response 'Location'
    if ($null -ne $location) { return [string]$location }
    $headers = Get-PshLifecycleProperty $Response 'Headers'
    if ($headers -is [Collections.IDictionary]) {
        foreach ($key in $headers.Keys) {
            if ([string]::Equals([string]$key, 'Location', [StringComparison]::OrdinalIgnoreCase)) {
                return [string]$headers[$key]
            }
        }
    }
    elseif ($headers -is [Net.WebHeaderCollection]) {
        return [string]$headers['Location']
    }
    return $null
}

function Close-PshAcquisitionResponse {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object] $Response)

    if ($null -eq $Response) { return }
    $stream = Get-PshLifecycleProperty $Response 'Stream'
    if ($stream -is [IDisposable]) {
        try { $stream.Dispose() } catch { }
    }
    $disposable = Get-PshLifecycleProperty $Response 'Disposable'
    if ($disposable -is [IDisposable] -and -not [object]::ReferenceEquals($stream, $disposable)) {
        try { $disposable.Dispose() } catch { }
    }
}

function Invoke-PshAcquisitionHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Request)

    $uri = ConvertTo-PshAcquisitionUri -Value (Get-PshLifecycleProperty $Request 'Uri') -Description 'Acquisition request URI'
    $webRequest = [Net.HttpWebRequest][Net.WebRequest]::Create($uri)
    $webRequest.Method = 'GET'
    $webRequest.AllowAutoRedirect = $false
    $webRequest.AutomaticDecompression = [Net.DecompressionMethods]::None
    $webRequest.Timeout = 30000
    $webRequest.ReadWriteTimeout = 30000
    $webRequest.UserAgent = 'Psh-Installer/1.0'
    $response = $null
    try {
        try { $response = [Net.HttpWebResponse]$webRequest.GetResponse() }
        catch [Net.WebException] {
            if ($null -eq $_.Exception.Response) { throw }
            $response = [Net.HttpWebResponse]$_.Exception.Response
        }
        return [pscustomobject][ordered]@{
            StatusCode = [int]$response.StatusCode
            ResponseUri = $response.ResponseUri.AbsoluteUri
            Location = [string]$response.Headers['Location']
            Headers = $response.Headers
            ContentLength = [int64]$response.ContentLength
            Stream = $response.GetResponseStream()
            Disposable = $response
        }
    }
    catch {
        if ($null -ne $response) { try { $response.Dispose() } catch { } }
        throw
    }
}

function Invoke-PshAcquisitionOneRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    $request = [pscustomobject][ordered]@{
        Uri = $Uri.AbsoluteUri
        Method = 'GET'
        AllowAutoRedirect = $false
    }
    try {
        $results = @(Invoke-PshAcquisitionHttpRequest -Request $request)
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionTransport' -Message "Release request failed: $($Uri.AbsoluteUri)" -InnerException $_.Exception
    }
    if ($results.Count -ne 1 -or $null -eq $results[0]) {
        foreach ($result in $results) { Close-PshAcquisitionResponse -Response $result }
        Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionTransportResult' -Message 'Acquisition transport must return exactly one response.'
    }
    return $results[0]
}

function Get-PshAcquisitionDestination {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

    try { $fullPath = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description 'acquisition destination' }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionDestination' -Message "Destination path is invalid: $Path" -InnerException $_.Exception
    }
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrEmpty($parent)) {
        Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionDestination' -Message "Destination has no parent directory: $Path"
    }
    $parent = Assert-PshLifecycleNoReparseAncestors -Path $parent -Description 'acquisition destination parent'
    $parentEntry = Get-PshLifecyclePathEntry -Path $parent -Description 'acquisition destination parent'
    if (-not [bool]$parentEntry.Exists -or -not [bool]$parentEntry.IsDirectory -or [bool]$parentEntry.IsReparsePoint) {
        Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionDestinationParent' -Message "Destination parent must be an existing non-reparse directory: $parent"
    }
    return [pscustomobject][ordered]@{ Path = $fullPath; Parent = $parent }
}

function Get-PshAcquisitionStreamState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IO.Stream] $Stream,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if (-not $Stream.CanRead -or -not $Stream.CanSeek) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionHandle' -Message "$Description must remain readable and seekable."
    }
    try {
        $Stream.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $length = [int64]$Stream.Length
            $hash = ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
        return [pscustomobject][ordered]@{ Length = $length; Sha256 = $hash }
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionHandleRead' -Message "Unable to read ${Description}." -InnerException $_.Exception
    }
    finally {
        if ($Stream.CanSeek) { try { $Stream.Position = 0 } catch { } }
    }
}

function Get-PshAcquisitionPathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $fullPath = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description
    $entry = Get-PshLifecyclePathEntry -Path $fullPath -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionLocalFile' -Message "$Description must be a regular non-reparse file: $fullPath"
    }
    $stream = $null
    try {
        # A read-only CAS probe may coexist with an owned ReadWrite staging
        # handle on Windows only when its share mode admits that existing write
        # access. The owned handle's FileShare.Read lock still blocks every new
        # writer and replacement; this probe remains read-only.
        $stream = New-Object IO.FileStream($fullPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::ReadWrite))
        return Get-PshAcquisitionStreamState -Stream $stream -Description $Description
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionPathChanged' -Message "$Description changed while it was being locked: $fullPath" -InnerException $_.Exception
    }
    finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
    }
}

function New-PshTrustedAssetHandle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Asset,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('Local', 'Existing', 'Downloaded')][string] $Status,
        [Parameter()][AllowNull()][string] $FinalUri,
        [Parameter()][int] $RedirectCount = 0
    )

    $assetName = [string](Get-PshLifecycleProperty $Asset 'name')
    $fullPath = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description "release asset '$assetName'"
    $entry = Get-PshLifecyclePathEntry -Path $fullPath -Description "release asset '$assetName'"
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionLocalFile' -Message "Trusted release asset must be a regular non-reparse file: $fullPath"
    }
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($fullPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
        $handleState = Get-PshAcquisitionStreamState -Stream $stream -Description "release asset '$assetName' handle"
        $pathState = Get-PshAcquisitionPathState -Path $fullPath -Description "release asset '$assetName' path"
        if ([int64]$handleState.Length -ne [int64](Get-PshLifecycleProperty $Asset 'length') -or
            [int64]$pathState.Length -ne [int64](Get-PshLifecycleProperty $Asset 'length')) {
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionLength' -Message "Release asset '$assetName' length does not match authenticated metadata."
        }
        if ([string]$handleState.Sha256 -cne [string](Get-PshLifecycleProperty $Asset 'sha256') -or
            [string]$pathState.Sha256 -cne [string](Get-PshLifecycleProperty $Asset 'sha256')) {
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionHash' -Message "Release asset '$assetName' SHA256 does not match authenticated metadata."
        }
        $record = [pscustomobject][ordered]@{
            Stream = $stream
            Status = $Status
            Path = $fullPath
            AssetName = $assetName
            Length = [int64]$handleState.Length
            Sha256 = [string]$handleState.Sha256
            FinalUri = $FinalUri
            RedirectCount = $RedirectCount
        }
        $stream.PSObject.TypeNames.Insert(0, 'Psh.TrustedAssetHandle')
        $stream | Add-Member -NotePropertyName TrustToken -NotePropertyValue $script:PshTrustedAssetToken -Force
        $stream | Add-Member -NotePropertyName Trusted -NotePropertyValue $true -Force
        $stream | Add-Member -NotePropertyName Status -NotePropertyValue $Status -Force
        $stream | Add-Member -NotePropertyName Path -NotePropertyValue $fullPath -Force
        $stream | Add-Member -NotePropertyName AssetName -NotePropertyValue $assetName -Force
        $stream | Add-Member -NotePropertyName Sha256 -NotePropertyValue ([string]$handleState.Sha256) -Force
        $stream | Add-Member -NotePropertyName FinalUri -NotePropertyValue $FinalUri -Force
        $stream | Add-Member -NotePropertyName RedirectCount -NotePropertyValue $RedirectCount -Force
        [void]$script:PshTrustedAssetRegistry.Add($stream, $record)
        return $stream
    }
    catch {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionPathChanged' -Message "Release asset '$assetName' changed while its trusted handle was being created: $fullPath" -InnerException $_.Exception
    }
}

function Get-PshTrustedAssetRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    $record = $null
    $token = Get-PshLifecycleProperty $InputObject 'TrustToken'
    $readable = $false
    if ($InputObject -is [IO.FileStream]) {
        try { $readable = [bool]$InputObject.CanRead -and [bool]$InputObject.CanSeek } catch { $readable = $false }
    }
    if (-not $readable -or $null -eq $token -or -not [object]::ReferenceEquals($token, $script:PshTrustedAssetToken) -or
        -not $script:PshTrustedAssetRegistry.TryGetValue($InputObject, [ref]$record) -or
        -not [object]::ReferenceEquals($InputObject, (Get-PshLifecycleProperty $record 'Stream'))) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshUntrustedAssetHandle' -Message 'A live disposable trusted asset handle is required.'
    }
    return [pscustomobject][ordered]@{
        Status = [string](Get-PshLifecycleProperty $record 'Status')
        Path = [string](Get-PshLifecycleProperty $record 'Path')
        AssetName = [string](Get-PshLifecycleProperty $record 'AssetName')
        Length = [int64](Get-PshLifecycleProperty $record 'Length')
        Sha256 = [string](Get-PshLifecycleProperty $record 'Sha256')
        FinalUri = Get-PshLifecycleProperty $record 'FinalUri'
        RedirectCount = [int](Get-PshLifecycleProperty $record 'RedirectCount')
    }
}

function Test-PshTrustedAssetHandle {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    try { [void](Get-PshTrustedAssetRecord -InputObject $InputObject); return $true }
    catch { return $false }
}

function Assert-PshTrustedAssetHandle {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    return Get-PshTrustedAssetRecord -InputObject $InputObject
}

function Confirm-PshTrustedAssetFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $TrustedRelease,
        [Parameter(Mandatory = $true)][string] $AssetName,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $asset = Resolve-PshTrustedReleaseAsset -TrustedRelease $TrustedRelease -AssetName $AssetName
    return New-PshTrustedAssetHandle -Asset $asset -Path $Path -Status Local
}

function Assert-PshAcquisitionOwnedStageStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $ExpectedState
    )

    try {
        $state = Get-PshAcquisitionPathState -Path $Path -Description 'acquisition stage file'
        if ([int64]$state.Length -ne [int64](Get-PshLifecycleProperty $ExpectedState 'Length') -or
            [string]$state.Sha256 -cne [string](Get-PshLifecycleProperty $ExpectedState 'Sha256')) {
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionStageChanged' -Message "Acquisition stage file changed before publication: $Path"
        }
    }
    catch {
        $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
        if ([string]$metadata.ErrorId -ceq 'PshAcquisitionStageChanged') { throw }
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionStageChanged' -Message "Acquisition stage file changed before publication: $Path" -InnerException $_.Exception
    }
    return $true
}

function Remove-PshAcquisitionOwnedStageIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][AllowNull()][object] $ExpectedState
    )

    if ($null -eq $ExpectedState) { return }
    try {
        [void](Assert-PshLifecycleNoReparseAncestors -Path $Path -Description 'acquisition stage cleanup')
        $entry = Get-PshLifecyclePathEntry -Path $Path -Description 'acquisition stage cleanup'
        if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) { return }
        $state = Get-PshAcquisitionPathState -Path $Path -Description 'acquisition stage cleanup'
        if ([int64]$state.Length -eq [int64](Get-PshLifecycleProperty $ExpectedState 'Length') -and
            [string]$state.Sha256 -ceq [string](Get-PshLifecycleProperty $ExpectedState 'Sha256')) {
            [IO.File]::Delete($Path)
        }
    }
    catch { }
}

function Invoke-PshSaveTrustedReleaseAssetCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $TrustedRelease,
        [Parameter(Mandatory = $true)][string] $AssetName,
        [Parameter(Mandatory = $true)][string] $DestinationPath,
        [Parameter()][AllowNull()][string] $InitialUri,
        [Parameter()][switch] $Offline
    )

    $asset = Resolve-PshTrustedReleaseAsset -TrustedRelease $TrustedRelease -AssetName $AssetName
    $signedUri = [string]$asset.url
    if ([string]::IsNullOrEmpty($InitialUri)) { $InitialUri = $signedUri }
    if ([string]$InitialUri -cne $signedUri) {
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionInitialUri' -Message 'Initial acquisition URI must exactly match the publisher-authenticated release index.'
    }
    $currentUri = ConvertTo-PshAcquisitionUri -Value $InitialUri -Description 'Initial acquisition URI'
    if ($Offline) {
        Throw-PshAcquisitionError -ExitCode 4 -ErrorId 'PshAcquisitionOffline' -Message 'Offline mode forbids release asset network acquisition.'
    }

    $destination = Get-PshAcquisitionDestination -Path $DestinationPath
    $destinationEntry = Get-PshLifecyclePathEntry -Path $destination.Path -Description 'acquisition destination'
    if ([bool]$destinationEntry.Exists) {
        try {
            return New-PshTrustedAssetHandle -Asset $asset -Path $destination.Path -Status Existing -FinalUri $signedUri
        }
        catch {
            if (Test-PshLifecycleExceptionMetadata $_) {
                Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionDestinationConflict' -Message "Existing destination is not the authenticated release asset and will not be overwritten: $($destination.Path)" -InnerException $_.Exception
            }
            throw
        }
    }

    $seenUris = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    [void]$seenUris.Add($currentUri.AbsoluteUri)
    $redirectCount = 0
    $response = $null
    while ($true) {
        $response = Invoke-PshAcquisitionOneRequest -Uri $currentUri
        $statusValue = Get-PshLifecycleProperty $response 'StatusCode'
        try { $statusCode = [int]$statusValue }
        catch {
            Close-PshAcquisitionResponse -Response $response
            Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionTransportResult' -Message 'Acquisition response has no valid HTTP status code.' -InnerException $_.Exception
        }
        $responseUriValue = Get-PshLifecycleProperty $response 'ResponseUri'
        try { $responseUri = ConvertTo-PshAcquisitionUri -Value $responseUriValue -Description 'Acquisition response URI' }
        catch {
            Close-PshAcquisitionResponse -Response $response
            throw
        }
        if ($responseUri.AbsoluteUri -cne $currentUri.AbsoluteUri) {
            Close-PshAcquisitionResponse -Response $response
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionHiddenRedirect' -Message 'Transport followed an unreviewed automatic redirect.'
        }

        if ($statusCode -in $script:PshAcquisitionRedirectStatuses) {
            try {
                if ($redirectCount -ge $script:PshAcquisitionMaxRedirects) {
                    Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionRedirectLimit' -Message "Release acquisition exceeded $($script:PshAcquisitionMaxRedirects) redirects."
                }
                $redirectLocation = Get-PshAcquisitionResponseLocation -Response $response
                $nextUri = Resolve-PshAcquisitionRedirectUri -BaseUri $currentUri -Location $redirectLocation
                if (-not $seenUris.Add($nextUri.AbsoluteUri)) {
                    Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionRedirectLoop' -Message 'Release acquisition encountered a redirect loop.'
                }
                $redirectCount++
                $currentUri = $nextUri
            }
            finally { Close-PshAcquisitionResponse -Response $response }
            $response = $null
            continue
        }
        if ($statusCode -ne 200) {
            Close-PshAcquisitionResponse -Response $response
            $response = $null
            Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionHttpStatus' -Message "Release request returned HTTP status $statusCode."
        }
        break
    }

    $contentLengthValue = Get-PshLifecycleProperty $response 'ContentLength'
    $contentLength = [int64]-1
    if ($null -ne $contentLengthValue) {
        try { $contentLength = [int64]$contentLengthValue }
        catch {
            Close-PshAcquisitionResponse -Response $response
            Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionTransportResult' -Message 'Acquisition response Content-Length is invalid.' -InnerException $_.Exception
        }
    }
    if ($contentLength -ge 0 -and $contentLength -ne [int64]$asset.length) {
        Close-PshAcquisitionResponse -Response $response
        Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionLength' -Message "Release asset '$AssetName' Content-Length does not match authenticated metadata."
    }
    $inputStream = Get-PshLifecycleProperty $response 'Stream'
    if ($inputStream -isnot [IO.Stream] -or -not $inputStream.CanRead) {
        Close-PshAcquisitionResponse -Response $response
        Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionTransportResult' -Message 'Successful acquisition response has no readable stream.'
    }

    $stagePath = Assert-PshLifecycleNoReparseAncestors -Path (Join-Path $destination.Parent ('.psh-download-' + [Guid]::NewGuid().ToString('N') + '.tmp')) -Description 'acquisition stage file'
    $stageStream = $null
    $sha = $null
    $stageOwned = $false
    $published = $false
    $stageState = $null
    try {
        try {
            $stageStream = New-Object IO.FileStream($stagePath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::Read))
            $stageOwned = $true
        }
        catch { Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionStage' -Message "Unable to create acquisition stage file: $stagePath" -InnerException $_.Exception }
        $sha = [Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] $script:PshAcquisitionBufferSize
        [int64]$total = 0
        while ($true) {
            try { $read = $inputStream.Read($buffer, 0, $buffer.Length) }
            catch { Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionRead' -Message "Unable to read release asset '$AssetName'." -InnerException $_.Exception }
            if ($read -eq 0) { break }
            if ($read -lt 0 -or $total -gt ([int64]$asset.length - [int64]$read)) {
                Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionLength' -Message "Release asset '$AssetName' is longer than authenticated metadata."
            }
            try {
                $stageStream.Write($buffer, 0, $read)
                [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            }
            catch { Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionWrite' -Message "Unable to stage release asset '$AssetName'." -InnerException $_.Exception }
            $total += [int64]$read
        }
        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        try {
            try { $stageStream.Flush($true) } catch { $stageStream.Flush() }
            $stageState = Get-PshAcquisitionStreamState -Stream $stageStream -Description "staged release asset '$AssetName'"
        }
        catch { Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionWrite' -Message "Unable to flush release asset '$AssetName'." -InnerException $_.Exception }
        $actualSha256 = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        if ($total -ne [int64]$asset.length -or [int64]$stageState.Length -ne [int64]$asset.length) {
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionLength' -Message "Release asset '$AssetName' is shorter than authenticated metadata."
        }
        if ($actualSha256 -cne [string]$asset.sha256 -or [string]$stageState.Sha256 -cne [string]$asset.sha256) {
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionHash' -Message "Release asset '$AssetName' SHA256 does not match authenticated metadata."
        }
        $stageStream.Dispose()
        $stageStream = $null

        [void](Assert-PshAcquisitionOwnedStageStable -Path $stagePath -ExpectedState $stageState)
        $destination = Get-PshAcquisitionDestination -Path $destination.Path
        $destinationEntry = Get-PshLifecyclePathEntry -Path $destination.Path -Description 'acquisition destination'
        if ([bool]$destinationEntry.Exists) {
            Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionPublishRace' -Message "Destination appeared during acquisition and was preserved: $($destination.Path)"
        }
        try { [IO.File]::Move($stagePath, $destination.Path) }
        catch {
            $destinationAfter = Get-PshLifecyclePathEntry -Path $destination.Path -Description 'acquisition destination'
            if ([bool]$destinationAfter.Exists) {
                Throw-PshAcquisitionError -ExitCode 5 -ErrorId 'PshAcquisitionPublishRace' -Message "Destination appeared during acquisition and was preserved: $($destination.Path)" -InnerException $_.Exception
            }
            Throw-PshAcquisitionError -ExitCode 3 -ErrorId 'PshAcquisitionPublish' -Message "Unable to publish release asset: $($destination.Path)" -InnerException $_.Exception
        }
        $published = $true
        return New-PshTrustedAssetHandle -Asset $asset -Path $destination.Path -Status Downloaded -FinalUri $currentUri.AbsoluteUri -RedirectCount $redirectCount
    }
    finally {
        Close-PshAcquisitionResponse -Response $response
        if ($null -ne $stageStream) {
            if ($stageOwned -and -not $published -and $null -eq $stageState) {
                try { $stageState = Get-PshAcquisitionStreamState -Stream $stageStream -Description 'partial acquisition stage' } catch { }
            }
            try { $stageStream.Dispose() } catch { }
        }
        if ($null -ne $sha) { try { $sha.Dispose() } catch { } }
        if ($stageOwned -and -not $published) {
            Remove-PshAcquisitionOwnedStageIfMatch -Path $stagePath -ExpectedState $stageState
        }
    }
}

function Save-PshTrustedReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $TrustedRelease,
        [Parameter(Mandatory = $true)][string] $AssetName,
        [Parameter(Mandatory = $true)][string] $DestinationPath,
        [Parameter()][AllowNull()][string] $InitialUri,
        [Parameter()][switch] $Offline
    )

    return Invoke-PshSaveTrustedReleaseAssetCore -TrustedRelease $TrustedRelease -AssetName $AssetName -DestinationPath $DestinationPath -InitialUri $InitialUri -Offline:$Offline
}
