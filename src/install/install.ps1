# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string] $Edition = 'Core',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Version = 'latest',

    [Parameter()]
    [switch] $NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PshOnlineRepository = 'https://github.com/Emvdy/psh'
$script:PshOnlineLatestApi = 'https://api.github.com/repos/Emvdy/psh/releases/latest'
$script:PshOnlinePolicyRemediation = 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
$script:PshOnlineEntryPath = [IO.Path]::GetFullPath([string]$MyInvocation.MyCommand.Path)
$script:PshOnlineWasDotSourced = $MyInvocation.InvocationName -ceq '.'
$script:PshOnlineRedirectStatuses = @(301, 302, 303, 307, 308)
$script:PshOnlineTransientStatuses = @(502, 503, 504)
$script:PshOnlineCdnHosts = @('release-assets.githubusercontent.com', 'objects.githubusercontent.com')
$script:PshOnlineHelperLoadError = $null

function Throw-PshOnlineEntryError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter()][string] $Kind = 'Runtime',
        [Parameter()][AllowNull()][Exception] $InnerException,
        [Parameter()][string] $Remediation
    )

    $exception = if ($null -eq $InnerException) {
        New-Object System.Exception($Message)
    }
    else {
        New-Object System.Exception($Message, $InnerException)
    }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorKind'] = $Kind
    $exception.Data['PshErrorId'] = $ErrorId
    if (-not [string]::IsNullOrWhiteSpace($Remediation)) {
        $exception.Data['PshRemediation'] = $Remediation
    }
    throw $exception
}

# PSH_EMBED_HELPERS_BEGIN
try {
    foreach ($supportName in @('PackageLifecycle.ps1', 'ReleaseTrust.ps1', 'PackageAcquisition.ps1')) {
        $supportPath = Join-Path $PSScriptRoot $supportName
        if (-not [IO.File]::Exists($supportPath)) {
            Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshOnlineSupportMissing' -Message "Required online installer support file was not found: $supportName"
        }
        . $supportPath
    }
}
catch { $script:PshOnlineHelperLoadError = $_ }
# PSH_EMBED_HELPERS_END

function Test-PshOnlineWindows {
    [CmdletBinding()]
    param()

    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Assert-PshOnlineEdition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Value)

    if ($Value -cnotin @('Core', 'Full')) {
        Throw-PshOnlineEntryError -ExitCode 2 -Kind 'Usage' -ErrorId 'PshOnlineEdition' -Message 'Edition must be Core or Full.'
    }
}

function Assert-PshOnlineExecutionPolicy {
    [CmdletBinding()]
    param()

    if (-not (Test-PshOnlineWindows)) { return }
    try { $effectivePolicy = [string](Get-ExecutionPolicy -ErrorAction Stop) }
    catch {
        Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Unable to determine the effective PowerShell execution policy.' -InnerException $_.Exception -Remediation $script:PshOnlinePolicyRemediation
    }
    if ($effectivePolicy -in @('Restricted', 'AllSigned')) {
        Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicy' -Message "PowerShell execution policy '$effectivePolicy' does not allow this installer workflow." -Remediation $script:PshOnlinePolicyRemediation
    }
    if ($effectivePolicy -ine 'RemoteSigned') { return }
    try {
        $streams = @(Get-Item -LiteralPath $script:PshOnlineEntryPath -Stream * -ErrorAction Stop)
        $zoneStreams = @($streams | Where-Object { [string]$_.Stream -ceq 'Zone.Identifier' })
        if ($zoneStreams.Count -gt 1) {
            Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Multiple Zone.Identifier streams were found on the installer.' -Remediation $script:PshOnlinePolicyRemediation
        }
        if ($zoneStreams.Count -eq 0) { return }
        $zoneText = [string](Get-Content -LiteralPath $script:PshOnlineEntryPath -Stream 'Zone.Identifier' -Raw -ErrorAction Stop)
        $matches = [regex]::Matches($zoneText, '(?im)^\s*ZoneId\s*=\s*([0-9]+)\s*$')
        if ($matches.Count -ne 1) {
            Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Zone.Identifier is malformed and cannot be evaluated safely.' -Remediation $script:PshOnlinePolicyRemediation
        }
        $zoneId = [int]$matches[0].Groups[1].Value
        if ($zoneId -lt 0 -or $zoneId -gt 4) {
            Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Zone.Identifier contains an unknown zone.' -Remediation $script:PshOnlinePolicyRemediation
        }
        if ($zoneId -ge 3) {
            Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicy' -Message 'RemoteSigned does not allow an unapproved Internet-zone installer script.' -Remediation $script:PshOnlinePolicyRemediation
        }
    }
    catch {
        if ($_.Exception.Data.Contains('PshExitCode')) { throw }
        Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshExecutionPolicyProbe' -Message 'Unable to inspect installer Mark-of-the-Web metadata.' -InnerException $_.Exception -Remediation $script:PshOnlinePolicyRemediation
    }
}

function Get-PshOnlinePathComparison {
    [CmdletBinding()]
    param()

    if (Test-PshOnlineWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-PshOnlineRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, (Get-PshOnlinePathComparison))) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlinePathEscape' -Message "Path escapes its owned root: $Path"
    }
    return $fullPath.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
}

function Resolve-PshOnlineChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[\\:]' -or $RelativePath.StartsWith('/') -or
        @($RelativePath.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchivePath' -Message "Archive contains an unsafe path: $RelativePath"
    }
    $root = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $root ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    if (-not $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar, (Get-PshOnlinePathComparison))) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchivePath' -Message "Archive path escapes its extraction root: $RelativePath"
    }
    return $candidate
}

function New-PshOnlineOwnedRoot {
    [CmdletBinding()]
    param()

    $root = Join-Path ([IO.Path]::GetTempPath()) ('psh-online-entry-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    return [pscustomobject][ordered]@{
        Root = [IO.Path]::GetFullPath($root)
        Files = New-Object System.Collections.Generic.List[string]
        Directories = New-Object System.Collections.Generic.List[string]
    }
}

function Add-PshOnlineOwnedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $root = [IO.Path]::GetFullPath([string]$Context.Root)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($full, $root, (Get-PshOnlinePathComparison)) -and
        -not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, (Get-PshOnlinePathComparison))) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineTempEscape' -Message "Temporary path escapes its owned root: $full"
    }
    $relative = if ([string]::Equals($full, $root, (Get-PshOnlinePathComparison))) { '' } else { Get-PshOnlineRelativePath -Root $root -Path $full }
    $current = $root
    foreach ($segment in @($relative -split '/' | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
        $current = Join-Path $current $segment
        if ([IO.File]::Exists($current)) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineTempConflict' -Message "Temporary directory path is a file: $current"
        }
        if (-not [IO.Directory]::Exists($current)) {
            [IO.Directory]::CreateDirectory($current) | Out-Null
            [void]$Context.Directories.Add([IO.Path]::GetFullPath($current))
        }
        elseif (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineTempConflict' -Message "Temporary directory is a reparse point: $current"
        }
    }
}

function Remove-PshOnlineOwnedRoot {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object] $Context)

    if ($null -eq $Context) { return }
    foreach ($file in @($Context.Files.ToArray()) | Sort-Object { $_.Length } -Descending) {
        try {
            if ([IO.File]::Exists($file) -and ([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                [IO.File]::Delete($file)
            }
        }
        catch { }
    }
    $directories = @($Context.Directories.ToArray()) + @([string]$Context.Root)
    foreach ($directory in @($directories | Sort-Object { $_.Length } -Descending -Unique)) {
        try {
            if ([IO.Directory]::Exists($directory) -and ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
                [IO.Directory]::GetFileSystemEntries($directory).Count -eq 0) {
                [IO.Directory]::Delete($directory, $false)
            }
        }
        catch { }
    }
}

function Close-PshOnlineResponse {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object] $Response)

    if ($null -eq $Response) { return }
    $stream = $Response.PSObject.Properties['Stream']
    if ($null -ne $stream -and $stream.Value -is [IDisposable]) {
        try { $stream.Value.Dispose() } catch { }
    }
    $disposable = $Response.PSObject.Properties['Disposable']
    if ($null -ne $disposable -and $disposable.Value -is [IDisposable] -and
        ($null -eq $stream -or -not [object]::ReferenceEquals($stream.Value, $disposable.Value))) {
        try { $disposable.Value.Dispose() } catch { }
    }
}

function Invoke-PshOnlineHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.AutomaticDecompression = [Net.DecompressionMethods]::None
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.UserAgent = 'Psh-Installer/1.0'
    $request.Accept = 'application/vnd.github+json, application/octet-stream;q=0.9, */*;q=0.1'
    $response = $null
    try {
        try { $response = [Net.HttpWebResponse]$request.GetResponse() }
        catch [Net.WebException] {
            if ($null -eq $_.Exception.Response) { throw }
            $response = [Net.HttpWebResponse]$_.Exception.Response
        }
        return [pscustomobject][ordered]@{
            StatusCode = [int]$response.StatusCode
            ResponseUri = $response.ResponseUri.AbsoluteUri
            Location = [string]$response.Headers['Location']
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

function Invoke-PshOnlineRequestWithRetry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $response = $null
        try { $response = Invoke-PshOnlineHttpRequest -Uri $Uri }
        catch {
            if ($attempt -lt 4) { Start-Sleep -Milliseconds (250 * $attempt); continue }
            Throw-PshOnlineEntryError -ExitCode 3 -Kind 'Io' -ErrorId 'PshOnlineTransport' -Message "HTTPS request failed after $attempt attempts: $($Uri.AbsoluteUri)" -InnerException $_.Exception
        }
        $statusCode = [int]$response.StatusCode
        if ($statusCode -in $script:PshOnlineTransientStatuses -and $attempt -lt 4) {
            Close-PshOnlineResponse -Response $response
            Start-Sleep -Milliseconds (250 * $attempt)
            continue
        }
        return $response
    }
    Throw-PshOnlineEntryError -ExitCode 3 -Kind 'Io' -ErrorId 'PshOnlineTransport' -Message "HTTPS request failed: $($Uri.AbsoluteUri)"
}

function ConvertTo-PshOnlineUri {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Value)

    try { $uri = New-Object Uri($Value, [UriKind]::Absolute) }
    catch { Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineUri' -Message "Invalid HTTPS URI: $Value" -InnerException $_.Exception }
    if ($uri.Scheme -cne 'https' -or -not $uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineUri' -Message "URI leaves the HTTPS boundary: $Value"
    }
    return $uri
}

function Read-PshOnlineResponseBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int64] $MaximumLength,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $declaredLength = [int64]$Response.ContentLength
    if ($declaredLength -gt $MaximumLength) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineLength' -Message "$Description is larger than the installer limit."
    }
    if ($Response.Stream -isnot [IO.Stream] -or -not $Response.Stream.CanRead) {
        Throw-PshOnlineEntryError -ExitCode 3 -Kind 'Io' -ErrorId 'PshOnlineResponse' -Message "$Description response has no readable stream."
    }
    $memory = New-Object IO.MemoryStream
    try {
        $buffer = New-Object byte[] 65536
        while ($true) {
            $read = $Response.Stream.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { break }
            if ($memory.Length -gt ($MaximumLength - $read)) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineLength' -Message "$Description is larger than the installer limit."
            }
            $memory.Write($buffer, 0, $read)
        }
        if ($declaredLength -ge 0 -and $memory.Length -ne $declaredLength) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineLength' -Message "$Description length does not match its HTTPS response metadata."
        }
        return $memory.ToArray()
    }
    finally { $memory.Dispose() }
}

function Resolve-PshOnlineVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $RequestedVersion)

    $metadata = Resolve-PshTrustedReleaseMetadata -RequestedVersion $RequestedVersion
    $record = Assert-PshTrustedReleaseMetadata -InputObject $metadata
    return [pscustomobject][ordered]@{
        Version = [string]$record.Version
        Tag = [string]$record.Tag
        TrustedMetadata = $metadata
    }
}

function Resolve-PshOnlineRedirectUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Uri] $BaseUri,
        [Parameter(Mandatory = $true)][string] $Location
    )

    if ([string]::IsNullOrWhiteSpace($Location) -or $Location -match '[\x00-\x1f\x7f]') {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineRedirectLocation' -Message 'HTTPS redirect has no valid Location header.'
    }
    try { $uri = New-Object Uri($BaseUri, $Location) }
    catch { Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineRedirectLocation' -Message 'HTTPS redirect Location is invalid.' -InnerException $_.Exception }
    if ($uri.Scheme -cne 'https' -or -not $uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or $script:PshOnlineCdnHosts -cnotcontains $uri.DnsSafeHost.ToLowerInvariant()) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineRedirectBoundary' -Message "HTTPS redirect leaves the GitHub release CDN boundary: $($uri.AbsoluteUri)"
    }
    return $uri
}

function Save-PshOnlineBootstrapAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $DestinationPath,
        [Parameter(Mandatory = $true)][int64] $MaximumLength
    )

    $initialUri = ConvertTo-PshOnlineUri -Value $Uri
    if ($initialUri.Host -cne 'github.com' -or -not [string]::IsNullOrEmpty($initialUri.Query)) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineBootstrapUri' -Message "Bootstrap asset URL is not a fixed GitHub release URL: $Uri"
    }
    Add-PshOnlineOwnedDirectory -Context $Context -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DestinationPath)))
    $currentUri = $initialUri
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    [void]$seen.Add($currentUri.AbsoluteUri)
    for ($redirects = 0; $redirects -le 5; $redirects++) {
        $response = $null
        try {
            $response = Invoke-PshOnlineRequestWithRetry -Uri $currentUri
            if ([string]$response.ResponseUri -cne $currentUri.AbsoluteUri) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineHiddenRedirect' -Message 'HTTPS transport followed an unreviewed redirect.'
            }
            if ([int]$response.StatusCode -in $script:PshOnlineRedirectStatuses) {
                if ($redirects -ge 5) {
                    Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineRedirectLimit' -Message 'Bootstrap asset exceeded five HTTPS redirects.'
                }
                $nextUri = Resolve-PshOnlineRedirectUri -BaseUri $currentUri -Location ([string]$response.Location)
                if (-not $seen.Add($nextUri.AbsoluteUri)) {
                    Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineRedirectLoop' -Message 'Bootstrap asset encountered a redirect loop.'
                }
                $currentUri = $nextUri
                continue
            }
            if ([int]$response.StatusCode -ne 200) {
                Throw-PshOnlineEntryError -ExitCode 3 -Kind 'Io' -ErrorId 'PshOnlineHttpStatus' -Message "Bootstrap asset returned HTTP status $($response.StatusCode)."
            }
            $bytes = Read-PshOnlineResponseBytes -Response $response -MaximumLength $MaximumLength -Description ([IO.Path]::GetFileName($DestinationPath))
            $stream = New-Object IO.FileStream($DestinationPath, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None))
            try { $stream.Write($bytes, 0, $bytes.Length); try { $stream.Flush($true) } catch { $stream.Flush() } }
            finally { $stream.Dispose() }
            [void]$Context.Files.Add([IO.Path]::GetFullPath($DestinationPath))
            return [IO.Path]::GetFullPath($DestinationPath)
        }
        finally { Close-PshOnlineResponse -Response $response }
    }
    Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineRedirectLimit' -Message 'Bootstrap asset exceeded the redirect limit.'
}

function Get-PshOnlineArchitecture {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Edition)

    Assert-PshOnlineEdition -Value $Edition
    if ($Edition -ceq 'Core') { return 'any' }
    $architecture = [string]$env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = [string]$env:PROCESSOR_ARCHITECTURE }
    if ($architecture -match '(?i)ARM64|AARCH64') { return 'win-arm64' }
    if ($architecture -match '(?i)AMD64|X86_64') { return 'win-x64' }
    Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshOnlineArchitecture' -Message "Full edition is unavailable for this Windows architecture: $architecture"
}

function Save-PshOnlineTrustedAssetWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $TrustedRelease,
        [Parameter(Mandatory = $true)][string] $AssetName,
        [Parameter(Mandatory = $true)][string] $DestinationPath,
        [Parameter(Mandatory = $true)][string] $InitialUri
    )

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            return Save-PshTrustedReleaseAsset -TrustedRelease $TrustedRelease -AssetName $AssetName -DestinationPath $DestinationPath -InitialUri $InitialUri
        }
        catch {
            $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
            if ([int]$metadata.ExitCode -ne 3 -or $attempt -ge 4) { throw }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    Throw-PshOnlineEntryError -ExitCode 3 -Kind 'Io' -ErrorId 'PshOnlineAssetTransport' -Message "Unable to acquire release asset: $AssetName"
}

function Expand-PshOnlineTrustedPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][IO.Stream] $TrustedAsset,
        [Parameter(Mandatory = $true)][string] $DestinationRoot
    )

    if (-not (Test-PshTrustedAssetHandle -InputObject $TrustedAsset)) {
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineTrustedHandle' -Message 'Package extraction requires a live disposable trusted asset handle.'
    }
    Add-PshOnlineOwnedDirectory -Context $Context -Path $DestinationRoot
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop }
    catch { Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshOnlineZipSupport' -Message 'System.IO.Compression is unavailable.' -InnerException $_.Exception }
    $archive = $null
    try {
        $TrustedAsset.Position = 0
        $archive = New-Object IO.Compression.ZipArchive($TrustedAsset, ([IO.Compression.ZipArchiveMode]::Read), $true)
        if ($archive.Entries.Count -gt 20000) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveEntries' -Message 'Package archive contains too many entries.'
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [int64]$totalLength = 0
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name)) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchivePath' -Message 'Package archive contains an empty path.'
            }
            $isDirectory = $name.EndsWith('/', [StringComparison]::Ordinal)
            $relative = if ($isDirectory) { $name.TrimEnd('/') } else { $name }
            if ([string]::IsNullOrWhiteSpace($relative)) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchivePath' -Message 'Package archive contains a root directory entry.'
            }
            $destination = Resolve-PshOnlineChildPath -Root $DestinationRoot -RelativePath $relative
            if (-not $seen.Add($relative)) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveDuplicate' -Message "Package archive contains a duplicate path: $relative"
            }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000 -or ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveLink' -Message "Package archive contains a link or reparse entry: $relative"
            }
            if ($isDirectory) {
                Add-PshOnlineOwnedDirectory -Context $Context -Path $destination
                continue
            }
            if ($entry.Length -lt 0 -or $entry.Length -gt 4294967296) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveLength' -Message "Package archive entry is too large: $relative"
            }
            if ($totalLength -gt (8589934592 - [int64]$entry.Length)) {
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveLength' -Message 'Package archive expands beyond the installer limit.'
            }
            $totalLength += [int64]$entry.Length
            Add-PshOnlineOwnedDirectory -Context $Context -Path ([IO.Path]::GetDirectoryName($destination))
            $input = $null
            $output = $null
            try {
                $input = $entry.Open()
                $output = New-Object IO.FileStream($destination, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None))
                [void]$Context.Files.Add([IO.Path]::GetFullPath($destination))
                $buffer = New-Object byte[] 65536
                [int64]$written = 0
                while ($true) {
                    $read = $input.Read($buffer, 0, $buffer.Length)
                    if ($read -eq 0) { break }
                    $output.Write($buffer, 0, $read)
                    $written += [int64]$read
                    if ($written -gt [int64]$entry.Length) {
                        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveLength' -Message "Package archive entry exceeded its declared length: $relative"
                    }
                }
                try { $output.Flush($true) } catch { $output.Flush() }
                if ($written -ne [int64]$entry.Length) {
                    Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveLength' -Message "Package archive entry length changed during extraction: $relative"
                }
            }
            catch {
                if ($_.Exception.Data.Contains('PshExitCode')) { throw }
                Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveRead' -Message "Unable to extract package archive entry: $relative" -InnerException $_.Exception
            }
            finally {
                if ($null -ne $output) { try { $output.Dispose() } catch { } }
                if ($null -ne $input) { try { $input.Dispose() } catch { } }
            }
        }
    }
    catch {
        if ($_.Exception.Data.Contains('PshExitCode')) { throw }
        Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchive' -Message 'Package asset is not a valid safe ZIP archive.' -InnerException $_.Exception
    }
    finally {
        if ($null -ne $archive) { try { $archive.Dispose() } catch { } }
        if ($TrustedAsset.CanSeek) { try { $TrustedAsset.Position = 0 } catch { } }
    }
    foreach ($required in @('package.manifest.json', 'package.manifest.cat', 'install-offline.ps1')) {
        if (-not [IO.File]::Exists((Join-Path $DestinationRoot $required))) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineArchiveLayout' -Message "Package archive is missing required root file: $required"
        }
    }
    return [IO.Path]::GetFullPath($DestinationRoot)
}

function Invoke-PshOnlineInstall {
    [CmdletBinding()]
    param(
        [Parameter()][string] $Edition = 'Core',
        [Parameter()][ValidateNotNullOrEmpty()][string] $Version = 'latest',
        [Parameter()][switch] $NonInteractive
    )

    if ($null -ne $script:PshOnlineHelperLoadError) { throw $script:PshOnlineHelperLoadError }
    Assert-PshOnlineEdition -Value $Edition
    Assert-PshOnlineExecutionPolicy
    $resolved = Resolve-PshOnlineVersion -RequestedVersion $Version
    $fixedVersion = [string]$resolved.Version
    $fixedTag = [string]$resolved.Tag
    $context = $null
    $trustedAsset = $null
    $archiveBinding = $null
    try {
        $context = New-PshOnlineOwnedRoot
        $trustRoot = Join-Path ([string]$context.Root) 'release-trust'
        Add-PshOnlineOwnedDirectory -Context $context -Path $trustRoot
        $indexName = "psh-release-$fixedVersion.json"
        $catalogName = "psh-release-$fixedVersion.cat"
        $releaseBase = "$($script:PshOnlineRepository)/releases/download/$fixedTag"
        $indexPath = Save-PshOnlineBootstrapAsset -Context $context -Uri "$releaseBase/$indexName" -DestinationPath (Join-Path $trustRoot $indexName) -MaximumLength 16777216
        $checksumPath = Save-PshOnlineBootstrapAsset -Context $context -Uri "$releaseBase/SHA256SUMS" -DestinationPath (Join-Path $trustRoot 'SHA256SUMS') -MaximumLength 16777216
        $catalogPath = Save-PshOnlineBootstrapAsset -Context $context -Uri "$releaseBase/$catalogName" -DestinationPath (Join-Path $trustRoot $catalogName) -MaximumLength 33554432
        $trustedRelease = Confirm-PshReleaseTrustBundle -IndexPath $indexPath -ChecksumPath $checksumPath -CatalogPath $catalogPath -TrustedMetadata $resolved.TrustedMetadata
        $releaseRecord = Assert-PshTrustedRelease -InputObject $trustedRelease
        if ([string]$releaseRecord.Index.version -cne $fixedVersion -or [string]$releaseRecord.Index.tag -cne $fixedTag) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineReleaseMismatch' -Message 'Authenticated release does not match the requested fixed version and tag.'
        }
        $architecture = Get-PshOnlineArchitecture -Edition $Edition
        $packageAsset = Resolve-PshTrustedPackageAsset -TrustedRelease $trustedRelease -Edition $Edition -Architecture $architecture
        $downloadRoot = Join-Path ([string]$context.Root) 'download'
        Add-PshOnlineOwnedDirectory -Context $context -Path $downloadRoot
        $packagePath = Join-Path $downloadRoot ([string]$packageAsset.name)
        $trustedAsset = Save-PshOnlineTrustedAssetWithRetry -TrustedRelease $trustedRelease -AssetName ([string]$packageAsset.name) -DestinationPath $packagePath -InitialUri ([string]$packageAsset.url)
        [void]$context.Files.Add([IO.Path]::GetFullPath($packagePath))
        $assetRecord = Assert-PshTrustedAssetHandle -InputObject $trustedAsset
        $packageRoot = Expand-PshOnlineTrustedPackage -Context $context -TrustedAsset $trustedAsset -DestinationRoot (Join-Path ([string]$context.Root) 'extracted')
        $trustedPackage = Confirm-PshPackageManifestTrust -ManifestPath (Join-Path $packageRoot 'package.manifest.json') -CatalogPath (Join-Path $packageRoot 'package.manifest.cat') -ExpectedAsset $packageAsset -TrustedRelease $trustedRelease
        $packageRecord = Assert-PshTrustedPackageManifest -InputObject $trustedPackage
        $archiveBinding = Confirm-PshPackageArchiveBinding -ArchivePath $packagePath -ArchiveSha256 ([string]$assetRecord.Sha256) -PackageRoot $packageRoot -RetainLocks
        if ([string]$packageRecord.Manifest.version -cne $fixedVersion -or [string]$packageRecord.Manifest.edition -cne $Edition) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlinePackageMismatch' -Message 'Authenticated package manifest does not match the selected release package.'
        }

        $requestedEdition = $Edition
        $requestedNonInteractive = [bool]$NonInteractive
        $offlineEntry = Join-Path $packageRoot 'install-offline.ps1'
        # The package entry is authenticated by the release asset hash and the
        # package manifest/catalog before this offline entry is loaded.
        # It owns the sidecar-free materialization and final Install-PshPackage call.
        . $offlineEntry -Edition $requestedEdition -Version $fixedVersion -NonInteractive:$requestedNonInteractive -ArchivePath $packagePath -ArchiveSha256 ([string]$archiveBinding.ArchiveSha256)
        $offlineCommand = Get-Command -Name Invoke-PshOfflineInstall -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $offlineCommand) {
            Throw-PshOnlineEntryError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOnlineOfflineEntry' -Message 'Trusted package offline entry did not expose Invoke-PshOfflineInstall.'
        }
        $installResults = @(Invoke-PshOfflineInstall -Edition $requestedEdition -Version $fixedVersion -NonInteractive:$requestedNonInteractive -ArchivePath $packagePath -ArchiveSha256 ([string]$archiveBinding.ArchiveSha256))
        if ($installResults.Count -eq 0 -or $null -eq $installResults[-1]) {
            Throw-PshOnlineEntryError -ExitCode 3 -Kind 'Io' -ErrorId 'PshOnlineInstallResult' -Message 'Trusted offline entry returned no installation result.'
        }
        $finalTrust = Complete-PshProductionArchiveTrustReport -InputObject $packageRecord.Trust -TrustMode 'github-release-asset-digest+archive-binding+package-catalog-sha256' -Checksum 'release-asset-archive-manifest-tree-sha256-verified' -ArchiveSha256 ([string]$archiveBinding.ArchiveSha256)
        $installResults[-1] | Add-Member -NotePropertyName trust -NotePropertyValue $finalTrust -Force
        return $installResults
    }
    finally {
        if ($null -ne $archiveBinding) { try { $archiveBinding.Dispose() } catch { } }
        if ($null -ne $trustedAsset) { try { $trustedAsset.Dispose() } catch { } }
        Remove-PshOnlineOwnedRoot -Context $context
    }
}

function Write-PshOnlineFailureEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $ErrorRecord)

    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $metadataCommand = Get-Command -Name Get-PshLifecycleErrorMetadata -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $metadataCommand) {
        $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $ErrorRecord
    }
    else {
        $metadataException = $exception
        while ($null -ne $metadataException -and $metadataException -is [Exception] -and $null -ne $metadataException.InnerException -and -not $metadataException.Data.Contains('PshExitCode')) { $metadataException = $metadataException.InnerException }
        $metadata = [pscustomobject][ordered]@{
            ExitCode = if ($null -ne $metadataException -and $metadataException.Data.Contains('PshExitCode')) { [int]$metadataException.Data['PshExitCode'] } else { 3 }
            Kind = if ($null -ne $metadataException -and $metadataException.Data.Contains('PshErrorKind')) { [string]$metadataException.Data['PshErrorKind'] } else { 'Runtime' }
            ErrorId = if ($null -ne $metadataException -and $metadataException.Data.Contains('PshErrorId')) { [string]$metadataException.Data['PshErrorId'] } else { 'PshOnlineEntry' }
            Message = if ($null -ne $metadataException) { [string]$metadataException.Message } else { [string]$ErrorRecord }
        }
    }
    $remediation = $null
    while ($null -ne $exception -and $exception -is [Exception]) {
        if ($exception.Data.Contains('PshRemediation')) { $remediation = [string]$exception.Data['PshRemediation']; break }
        $exception = $exception.InnerException
    }
    $envelope = [pscustomobject][ordered]@{
        schemaVersion = 1
        code = [string]$metadata.ErrorId
        exitCode = [int]$metadata.ExitCode
        kind = [string]$metadata.Kind
        message = [string]$metadata.Message
        remediation = $remediation
    }
    [Console]::Error.WriteLine(($envelope | ConvertTo-Json -Compress))
    return [int]$metadata.ExitCode
}

if (-not $script:PshOnlineWasDotSourced) {
    try {
        Invoke-PshOnlineInstall -Edition $Edition -Version $Version -NonInteractive:$NonInteractive
        $global:LASTEXITCODE = 0
    }
    catch {
        $exitCode = Write-PshOnlineFailureEnvelope -ErrorRecord $_
        $global:LASTEXITCODE = $exitCode
        exit $exitCode
    }
}
