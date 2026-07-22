#!/usr/bin/env bash
# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

set -u

policy_remediation='Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
edition='Core'
version='latest'
offline=0
non_interactive=0
archive_path=''
archive_sha256=''
seen_edition=0
seen_version=0
seen_archive_path=0
seen_archive_sha256=0

write_usage() {
    printf '%s\n' 'Usage: install.sh [--offline --archive-path FILE --archive-sha256 HEX] [--edition Core|Full] [--version latest|x.y.z] [--non-interactive]'
}

fail_json() {
    local exit_code="$1"
    local code="$2"
    local message="$3"
    printf '{"schemaVersion":1,"code":"%s","exitCode":%s,"kind":"Dependency","message":"%s","remediation":"%s"}\n' \
        "$code" "$exit_code" "$message" "$policy_remediation" >&2
    exit "$exit_code"
}

is_strict_semver() {
    local value="$1"
    local prerelease=''
    local identifier=''
    local -a identifiers=()
    [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || return 1
    [[ "$value" != *--* ]] || return 1
    if [[ "$value" == *-* ]]; then
        prerelease="${value#*-}"
        prerelease="${prerelease%%+*}"
        IFS='.' read -r -a identifiers <<< "$prerelease"
        for identifier in "${identifiers[@]}"; do
            if [[ "$identifier" =~ ^[0-9]+$ ]]; then
                [[ ${#identifier} -eq 1 || "$identifier" != 0* ]] || return 1
            else
                [[ "$identifier" =~ [A-Za-z] ]] || return 1
            fi
        done
    fi
    return 0
}

while (($# > 0)); do
    case "$1" in
        --offline)
            ((offline == 0)) || fail_json 2 'PshShellUsage' 'The --offline option may be specified only once.'
            offline=1
            shift
            ;;
        --non-interactive)
            ((non_interactive == 0)) || fail_json 2 'PshShellUsage' 'The --non-interactive option may be specified only once.'
            non_interactive=1
            shift
            ;;
        --edition)
            ((seen_edition == 0)) || fail_json 2 'PshShellUsage' 'The --edition option may be specified only once.'
            (($# >= 2)) || fail_json 2 'PshShellUsage' 'Missing value for --edition.'
            case "$2" in
                Core|core|CORE) edition='Core' ;;
                Full|full|FULL) edition='Full' ;;
                *) fail_json 2 'PshShellUsage' 'Edition must be Core or Full.' ;;
            esac
            seen_edition=1
            shift 2
            ;;
        --version)
            ((seen_version == 0)) || fail_json 2 'PshShellUsage' 'The --version option may be specified only once.'
            (($# >= 2)) || fail_json 2 'PshShellUsage' 'Missing value for --version.'
            version="$2"
            seen_version=1
            shift 2
            ;;
        --archive-path)
            ((seen_archive_path == 0)) || fail_json 2 'PshShellUsage' 'The --archive-path option may be specified only once.'
            (($# >= 2)) || fail_json 2 'PshShellUsage' 'Missing value for --archive-path.'
            [[ "$2" != --* ]] || fail_json 2 'PshShellUsage' 'Missing value for --archive-path.'
            archive_path="$2"
            seen_archive_path=1
            shift 2
            ;;
        --archive-sha256)
            ((seen_archive_sha256 == 0)) || fail_json 2 'PshShellUsage' 'The --archive-sha256 option may be specified only once.'
            (($# >= 2)) || fail_json 2 'PshShellUsage' 'Missing value for --archive-sha256.'
            [[ "$2" != --* ]] || fail_json 2 'PshShellUsage' 'Missing value for --archive-sha256.'
            archive_sha256="$2"
            seen_archive_sha256=1
            shift 2
            ;;
        --help|-h)
            (($# == 1)) || fail_json 2 'PshShellUsage' 'The help option cannot be combined with other options.'
            write_usage
            exit 0
            ;;
        *)
            fail_json 2 'PshShellUsage' "Unknown option: $1"
            ;;
    esac
done

if [[ "$version" != 'latest' ]] && ! is_strict_semver "$version"; then
    fail_json 2 'PshShellUsage' 'Version must be latest or a semantic x.y.z version.'
fi

if ((offline == 1)); then
    ((seen_archive_path == 1 && seen_archive_sha256 == 1)) || fail_json 2 'PshShellUsage' 'Offline mode requires both --archive-path and --archive-sha256.'
    [[ "$archive_sha256" =~ ^[0-9A-Fa-f]{64}$ && ! "$archive_sha256" =~ ^0{64}$ ]] || fail_json 2 'PshShellUsage' 'Archive SHA256 must be a non-zero 64-character hexadecimal value.'
    archive_sha256="$(printf '%s' "$archive_sha256" | tr '[:upper:]' '[:lower:]')"
elif ((seen_archive_path == 1 || seen_archive_sha256 == 1)); then
    fail_json 2 'PshShellUsage' 'Archive evidence options are valid only with --offline.'
fi

find_powershell() {
    local candidate
    if candidate="$(command -v powershell.exe 2>/dev/null)" && [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    for candidate in \
        '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe' \
        '/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

to_windows_path() {
    local path="$1"
    local converted=''
    if command -v wslpath >/dev/null 2>&1 && [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]]; then
        converted="$(wslpath -w "$path")" || return 1
    elif command -v cygpath >/dev/null 2>&1; then
        converted="$(cygpath -w "$path")" || return 1
    else
        converted="$path"
    fi
    converted="${converted//$'\r'/}"
    [[ -n "$converted" && "$converted" != *$'\n'* ]] || return 1
    printf '%s\n' "$converted"
}

to_shell_path() {
    local path="$1"
    local converted=''
    if command -v wslpath >/dev/null 2>&1 && [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]]; then
        converted="$(wslpath -u "$path")" || return 1
    elif command -v cygpath >/dev/null 2>&1; then
        converted="$(cygpath -u "$path")" || return 1
    else
        converted="$path"
    fi
    converted="${converted//$'\r'/}"
    [[ -n "$converted" && "$converted" != *$'\n'* ]] || return 1
    printf '%s\n' "$converted"
}

powershell_path="$(find_powershell)" || fail_json 4 'PshShellPowerShellMissing' 'Windows PowerShell 5.1 powershell.exe was not found.'
powershell_windows_path="$(to_windows_path "$powershell_path")" || fail_json 3 'PshShellPath' 'Unable to convert the Windows PowerShell path.'

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)" || fail_json 3 'PshShellPath' 'Unable to resolve the installer directory.'
temporary_root=''
temporary_root_windows=''
release_metadata_path=''
release_metadata_windows_path=''
entry_path=''
entry_windows_path=''

cleanup() {
    local cleanup_status=$?
    local cleanup_failed=0
    trap - EXIT HUP INT TERM
    if [[ -n "$temporary_root_windows" ]]; then
        PSH_SHELL_TEMP_ROOT="$temporary_root_windows" \
        PSH_SHELL_TEMP_METADATA="$release_metadata_windows_path" \
        PSH_SHELL_TEMP_ENTRY="$entry_windows_path" \
            "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$flowMarker = "PshShellCleanupRoot"
try {
    $root = [IO.Path]::GetFullPath([string]$env:PSH_SHELL_TEMP_ROOT).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $metadataPath = [IO.Path]::GetFullPath([string]$env:PSH_SHELL_TEMP_METADATA)
    $entryPath = [IO.Path]::GetFullPath([string]$env:PSH_SHELL_TEMP_ENTRY)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($root), $base, $comparison) -or [IO.Path]::GetFileName($root) -cnotmatch "\Apsh-install-[0-9a-f]{32}\z") { throw "Controlled installer TEMP root is outside Windows TEMP" }
    if (-not [string]::Equals($metadataPath, [IO.Path]::Combine($root, "release.json"), $comparison) -or
        -not [string]::Equals($entryPath, [IO.Path]::Combine($root, "install.ps1"), $comparison)) { throw "Controlled installer TEMP file paths are invalid" }
    if ([IO.Directory]::Exists($root)) {
        $attributes = [IO.File]::GetAttributes($root)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Controlled installer TEMP root became a reparse point" }
        foreach ($path in @($metadataPath, $entryPath)) {
            if ([IO.Directory]::Exists($path)) { throw "Controlled installer TEMP file path became a directory" }
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        }
        [IO.Directory]::Delete($root, $false)
    }
    elseif ([IO.File]::Exists($root)) { throw "Controlled installer TEMP root became a file" }
    exit 0
}
catch { exit 1 }
' </dev/null || cleanup_failed=1
    fi
    if ((cleanup_failed != 0)); then
        printf '%s\n' '{"schemaVersion":1,"code":"PshShellCleanup","exitCode":3,"kind":"Io","message":"Unable to remove the controlled Windows installer temporary directory.","remediation":"Remove the psh-install temporary directory after confirming its exact path."}' >&2
        ((cleanup_status != 0)) || cleanup_status=3
    fi
    exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

entry_url=''
expected_entry_length=''
expected_entry_sha256=''
archive_windows_path=''
if ((offline == 1)); then
    entry_path="$script_dir/install-offline.ps1"
    [[ -f "$entry_path" ]] || fail_json 4 'PshShellOfflineMissing' 'The adjacent install-offline.ps1 entry was not found.'
    entry_windows_path="$(to_windows_path "$entry_path")" || fail_json 3 'PshShellPath' 'Unable to convert the offline PowerShell installer path.'
    archive_windows_path="$(to_windows_path "$archive_path")" || fail_json 3 'PshShellPath' 'Unable to convert the offline archive path.'
else
    command -v curl >/dev/null 2>&1 || fail_json 4 'PshShellCurlMissing' 'curl is required for online installation.'
    temporary_fields="$("$powershell_path" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$flowMarker = "PshShellTempRoot"
$root = $null
$metadataPath = $null
$entryPath = $null
try {
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $baseItem = Get-Item -LiteralPath $base -ErrorAction Stop
    if (-not $baseItem.PSIsContainer -or ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Windows TEMP must be a non-reparse directory" }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $base -cnotmatch "\A[A-Za-z]:\\") { throw "Windows TEMP must resolve to a local drive path" }
    $root = Join-Path $base ("psh-install-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($root)
    $rootItem = Get-Item -LiteralPath $root -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Controlled installer TEMP root is invalid" }
    $metadataPath = Join-Path $root "release.json"
    $entryPath = Join-Path $root "install.ps1"
    foreach ($path in @($root, $metadataPath, $entryPath)) { if ($path -match "[\x00-\x1f]") { throw "Controlled installer TEMP path contains a control character" } }
    [Console]::Out.Write($root + "`t" + $metadataPath + "`t" + $entryPath)
}
catch {
    foreach ($path in @($metadataPath, $entryPath)) { if (-not [string]::IsNullOrEmpty([string]$path) -and [IO.File]::Exists([string]$path)) { try { [IO.File]::Delete([string]$path) } catch { } } }
    if (-not [string]::IsNullOrEmpty([string]$root) -and [IO.Directory]::Exists([string]$root)) { try { [IO.Directory]::Delete([string]$root, $false) } catch { } }
    throw
}
')"
    temporary_status=$?
    ((temporary_status == 0)) || fail_json 3 'PshShellTemp' 'Unable to create a controlled installer directory under Windows TEMP.'
    temporary_fields="${temporary_fields//$'\r'/}"
    IFS=$'\t' read -r temporary_root_windows release_metadata_windows_path entry_windows_path temporary_extra <<< "$temporary_fields"
    [[ -n "$temporary_root_windows" && -n "$release_metadata_windows_path" && -n "$entry_windows_path" && -z "${temporary_extra:-}" ]] \
        || fail_json 3 'PshShellTemp' 'Windows TEMP creation returned an invalid path record.'
    temporary_root="$(to_shell_path "$temporary_root_windows")" || fail_json 3 'PshShellPath' 'Unable to map the Windows installer temporary directory for curl.'
    release_metadata_path="$(to_shell_path "$release_metadata_windows_path")" || fail_json 3 'PshShellPath' 'Unable to map the Windows release-metadata path for curl.'
    entry_path="$(to_shell_path "$entry_windows_path")" || fail_json 3 'PshShellPath' 'Unable to map the Windows installer entry path for curl.'
    [[ "$release_metadata_path" == "$temporary_root/release.json" && "$entry_path" == "$temporary_root/install.ps1" ]] \
        || fail_json 3 'PshShellTemp' 'Mapped Windows installer paths do not remain inside the controlled temporary directory.'

    if [[ "$version" == 'latest' ]]; then
        requested_tag=''
        release_api_url='https://api.github.com/repos/Emvdy/psh/releases/latest'
    else
        requested_tag="v$version"
        release_api_url="https://api.github.com/repos/Emvdy/psh/releases/tags/$requested_tag"
    fi

    release_api_result="$(curl --fail --silent --show-error \
        --retry 3 --retry-all-errors --retry-delay 1 \
        --connect-timeout 30 --max-time 120 \
        --max-filesize 16777216 \
        --proto '=https' \
        --output "$release_metadata_path" --write-out '%{http_code}|%{url_effective}' \
        "$release_api_url")" \
        || fail_json 3 'PshShellReleaseMetadataTransport' 'Unable to obtain fixed GitHub release metadata after retries.'
    [[ "$release_api_result" == "200|$release_api_url" ]] || fail_json 5 'PshShellReleaseMetadataResponse' 'GitHub release metadata did not return an exact non-redirected HTTP 200 response.'
    metadata_fields="$(PSH_SHELL_RELEASE_METADATA_PATH="$release_metadata_windows_path" PSH_SHELL_REQUESTED_TAG="$requested_tag" \
        "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command \
        '$ErrorActionPreference="Stop";$metadataPath=$env:PSH_SHELL_RELEASE_METADATA_PATH;$metadata=Get-Item -LiteralPath $metadataPath -ErrorAction Stop;if($metadata.Length -le 0 -or $metadata.Length -gt 16777216){throw "Release metadata exceeds the installer limit"};$d=Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;foreach($name in @("tag_name","draft","prerelease","assets")){if($null -eq $d.PSObject.Properties[$name]){throw "Missing release property: $name"}};if($d.draft -isnot [bool] -or $d.prerelease -isnot [bool] -or [bool]$d.draft -or [bool]$d.prerelease){throw "Release must be published and stable"};$tag=[string]$d.tag_name;if($tag -cnotmatch "\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z" -or $tag.Contains("--")){throw "Release tag is not strict semantic versioning"};$version=$tag.Substring(1);$buildStart=$version.IndexOf("+");$preStart=$version.IndexOf("-");if($preStart -ge 0 -and ($buildStart -lt 0 -or $preStart -lt $buildStart)){$preEnd=if($buildStart -ge 0){$buildStart}else{$version.Length};$pre=$version.Substring($preStart+1,$preEnd-$preStart-1);foreach($identifier in $pre.Split(".")){if($identifier -cmatch "\A[0-9]+\z"){if($identifier.Length -gt 1 -and $identifier[0] -eq "0"){throw "Numeric prerelease identifiers cannot contain leading zeroes"}}elseif($identifier -cnotmatch "[A-Za-z]"){throw "Nonnumeric prerelease identifiers require an ASCII letter"}}};$requested=[string]$env:PSH_SHELL_REQUESTED_TAG;if(-not [string]::IsNullOrEmpty($requested) -and $tag -cne $requested){throw "Release tag does not match the requested fixed tag"};if($d.assets -isnot [System.Array]){throw "Release assets must be an array"};$matches=@($d.assets|Where-Object{[string]$_.name -ceq "install.ps1"});if($matches.Count -ne 1){throw "Release must contain exactly one install.ps1 asset"};$asset=$matches[0];$digest=$asset.digest;$sizeValue=$asset.size;$url=$asset.browser_download_url;$expectedUrl="https://github.com/Emvdy/psh/releases/download/$tag/install.ps1";if($digest -isnot [string] -or [string]$digest -cnotmatch "\Asha256:[0-9a-f]{64}\z"){throw "install.ps1 has no valid SHA256 digest"};if(($sizeValue -isnot [int]) -and ($sizeValue -isnot [long])){throw "install.ps1 size is not an integer"};$size=[int64]$sizeValue;if($size -le 0 -or $size -gt 16777216){throw "install.ps1 size is outside the installer limit"};if($url -isnot [string] -or [string]$url -cne $expectedUrl){throw "install.ps1 has an unexpected download URL"};[Console]::Out.Write($tag+"`t"+$version+"`t"+([string]$digest).Substring(7)+"`t"+$size.ToString([Globalization.CultureInfo]::InvariantCulture)+"`t"+$expectedUrl)')"
    metadata_status=$?
    ((metadata_status == 0)) || fail_json 5 'PshShellReleaseMetadataSchema' 'GitHub release metadata did not authenticate one exact install.ps1 asset.'
    metadata_fields="${metadata_fields//$'\r'/}"
    IFS=$'\t' read -r fixed_tag fixed_version expected_entry_sha256 expected_entry_length entry_url metadata_extra <<< "$metadata_fields"
    [[ -n "$fixed_tag" && -n "$fixed_version" && "$expected_entry_sha256" =~ ^[0-9a-f]{64}$ && "$expected_entry_length" =~ ^[1-9][0-9]*$ && -n "$entry_url" && -z "${metadata_extra:-}" ]] \
        || fail_json 5 'PshShellReleaseMetadataSchema' 'GitHub release metadata parser returned an invalid asset record.'
    [[ "$entry_url" == "https://github.com/Emvdy/psh/releases/download/$fixed_tag/install.ps1" ]] \
        || fail_json 5 'PshShellReleaseMetadataUrl' 'GitHub release metadata returned an unexpected install.ps1 URL.'

    effective_url="$(curl --fail --silent --show-error --location --max-redirs 5 \
        --retry 3 --retry-all-errors --retry-delay 1 \
        --connect-timeout 30 --max-time 180 \
        --max-filesize "$expected_entry_length" \
        --proto '=https' --proto-redir '=https' \
        --output "$entry_path" --write-out '%{url_effective}' \
        "$entry_url")" || fail_json 3 'PshShellEntryTransport' 'Unable to download the fixed-tag online installer entry.'
    case "$effective_url" in
        "$entry_url"|https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*) ;;
        *) fail_json 5 'PshShellRedirectBoundary' 'The installer download left the GitHub release HTTPS boundary.' ;;
    esac
    version="$fixed_version"
fi

non_interactive_value="$non_interactive"
PSH_SHELL_FLOW_MODE="$(if ((offline == 1)); then printf '%s' offline; else printf '%s' online; fi)" \
PSH_SHELL_ENTRY_PATH="$entry_windows_path" \
PSH_SHELL_ENTRY_LENGTH="$expected_entry_length" \
PSH_SHELL_ENTRY_SHA256="$expected_entry_sha256" \
PSH_SHELL_POWERSHELL_PATH="$powershell_windows_path" \
PSH_SHELL_EDITION="$edition" \
PSH_SHELL_VERSION="$version" \
PSH_SHELL_NON_INTERACTIVE="$non_interactive_value" \
PSH_SHELL_ARCHIVE_PATH="$archive_windows_path" \
PSH_SHELL_ARCHIVE_SHA256="$archive_sha256" \
    "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command \
    '
$ErrorActionPreference = "Stop"
$flowMarker = "PshShellLockedParent"
$entryStream = $null
$hashAlgorithm = $null
$child = $null
$exitCode = 3

function Throw-PshShellParentFailure {
    param([int]$ExitCode, [string]$Code, [string]$Kind, [string]$Message, [string]$Remediation)
    $exception = New-Object System.Exception($Message)
    $exception.Data["PshShellExitCode"] = $ExitCode
    $exception.Data["PshShellCode"] = $Code
    $exception.Data["PshShellKind"] = $Kind
    $exception.Data["PshShellRemediation"] = $Remediation
    throw $exception
}

function ConvertTo-PshShellProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch "[\s`"]") { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append([char]34)
    [int]$slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            if ($slashes -gt 0) { [void]$builder.Append([char]92, [int]($slashes * 2)) }
            [void]$builder.Append([char]92)
            [void]$builder.Append([char]34)
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append([char]92, [int]$slashes); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append([char]92, [int]($slashes * 2)) }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

try {
    $mode = [string]$env:PSH_SHELL_FLOW_MODE
    if ($mode -cnotin @("online", "offline")) { Throw-PshShellParentFailure 3 "PshShellParentInput" "Io" "The shell parent flow mode is invalid." "Run the installer again." }
    $entryPath = [IO.Path]::GetFullPath([string]$env:PSH_SHELL_ENTRY_PATH)
    try { $entryItem = Get-Item -LiteralPath $entryPath -ErrorAction Stop }
    catch { Throw-PshShellParentFailure 5 "PshShellEntryFile" "Integrity" "The installer entry could not be opened as a file." "Download the installer again from the fixed GitHub release." }
    if ($entryItem.PSIsContainer -or ($entryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-PshShellParentFailure 5 "PshShellEntryFile" "Integrity" "The installer entry must be a regular non-reparse file." "Download the installer again from the fixed GitHub release."
    }
    try { $entryStream = New-Object IO.FileStream($entryPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)) }
    catch { Throw-PshShellParentFailure 5 "PshShellEntryLock" "Integrity" "Unable to acquire the installer entry read lock." "Close processes modifying the installer and run it again." }

    $expectedLength = [int64]$entryStream.Length
    $expectedSha = $null
    if ($mode -ceq "online") {
        try { $expectedLength = [int64]::Parse([string]$env:PSH_SHELL_ENTRY_LENGTH, [Globalization.CultureInfo]::InvariantCulture) }
        catch { Throw-PshShellParentFailure 5 "PshShellEntryDigest" "Integrity" "The authenticated installer length is invalid." "Download the installer again from the fixed GitHub release." }
        $expectedSha = [string]$env:PSH_SHELL_ENTRY_SHA256
        if ($expectedLength -le 0 -or $expectedLength -gt 16777216 -or $expectedSha -cnotmatch "\A[0-9a-f]{64}\z") {
            Throw-PshShellParentFailure 5 "PshShellEntryDigest" "Integrity" "The authenticated installer digest record is invalid." "Download the installer again from the fixed GitHub release."
        }
        if ($entryStream.Length -ne $expectedLength) {
            Throw-PshShellParentFailure 5 "PshShellEntryDigest" "Integrity" "Downloaded installer length does not match GitHub release metadata." "Download the installer again from the fixed GitHub release."
        }
        $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
        try { $actualSha = ([BitConverter]::ToString($hashAlgorithm.ComputeHash($entryStream))).Replace("-", "").ToLowerInvariant() }
        finally { $hashAlgorithm.Dispose(); $hashAlgorithm = $null }
        if ($actualSha -cne $expectedSha) {
            Throw-PshShellParentFailure 5 "PshShellEntryDigest" "Integrity" "Downloaded installer SHA256 does not match GitHub release metadata." "Download the installer again from the fixed GitHub release."
        }
        $entryStream.Position = 0
    }

    $nonInteractive = [string]$env:PSH_SHELL_NON_INTERACTIVE -ceq "1"
    try { $policy = [string](Get-ExecutionPolicy -ErrorAction Stop) }
    catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" "Unable to determine the effective PowerShell execution policy." "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" }
    $internet = $false
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            $streams = @(Get-Item -LiteralPath $entryPath -Stream * -ErrorAction Stop)
            $zones = @($streams | Where-Object { [string]$_.Stream -ieq "Zone.Identifier" })
            if ($zones.Count -gt 1) { throw "Multiple Zone.Identifier streams" }
            if ($zones.Count -eq 1) {
                $zoneText = Get-Content -LiteralPath $entryPath -Stream "Zone.Identifier" -Raw -ErrorAction Stop
                $matches = [regex]::Matches([string]$zoneText, "(?im)^\s*ZoneId\s*=\s*([0-9]+)\s*$")
                if ($matches.Count -ne 1) { throw "Malformed Zone.Identifier" }
                $zone = [int]$matches[0].Groups[1].Value
                if ($zone -lt 0 -or $zone -gt 4) { throw "Unknown ZoneId" }
                $internet = $zone -ge 3
            }
        }
        catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" ([string]$_.Exception.Message) "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" }
    }
    $requiresSignature = ($policy -ieq "AllSigned") -or (($policy -ieq "RemoteSigned") -and $internet) -or (($policy -ieq "Unrestricted") -and $nonInteractive -and $internet)
    $validSignature = $false
    if ($requiresSignature) {
        try { $validSignature = [string](Get-AuthenticodeSignature -LiteralPath $entryPath -ErrorAction Stop).Status -ieq "Valid" }
        catch { Throw-PshShellParentFailure 4 "PshExecutionPolicyProbe" "Dependency" "Unable to inspect the installer Authenticode status required by execution policy." "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" }
    }
    $allowed = ($policy -ieq "Bypass") -or (($policy -ieq "AllSigned") -and $validSignature) -or
        (($policy -ieq "RemoteSigned") -and (-not $internet -or $validSignature)) -or
        (($policy -ieq "Unrestricted") -and -not ($nonInteractive -and $internet -and -not $validSignature))
    if (-not $allowed) {
        Throw-PshShellParentFailure 4 "PshExecutionPolicy" "Dependency" "PowerShell execution policy does not allow this installer workflow." "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    }

    $launchItem = Get-Item -LiteralPath $entryPath -ErrorAction Stop
    if ($launchItem.PSIsContainer -or ($launchItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [int64]$launchItem.Length -ne [int64]$entryStream.Length) {
        Throw-PshShellParentFailure 5 "PshShellEntryChanged" "Integrity" "The installer entry path changed before child launch." "Download the installer again from the fixed GitHub release."
    }
    if ($mode -ceq "online") {
        $entryStream.Position = 0
        $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
        try { $launchSha = ([BitConverter]::ToString($hashAlgorithm.ComputeHash($entryStream))).Replace("-", "").ToLowerInvariant() }
        finally { $hashAlgorithm.Dispose(); $hashAlgorithm = $null }
        if ($launchSha -cne $expectedSha) {
            Throw-PshShellParentFailure 5 "PshShellEntryChanged" "Integrity" "The installer entry changed before child launch." "Download the installer again from the fixed GitHub release."
        }
        $entryStream.Position = 0
    }

    $childPath = [IO.Path]::GetFullPath([string]$env:PSH_SHELL_POWERSHELL_PATH)
    if (-not [IO.File]::Exists($childPath)) { Throw-PshShellParentFailure 3 "PshShellChildStart" "Io" "The Windows PowerShell child executable was not found." "Verify Windows PowerShell 5.1 and run the installer again." }
    $childArguments = New-Object System.Collections.Generic.List[string]
    foreach ($value in @("-NoLogo", "-NoProfile", "-File", $entryPath, "-Edition", [string]$env:PSH_SHELL_EDITION, "-Version", [string]$env:PSH_SHELL_VERSION)) { [void]$childArguments.Add($value) }
    if ($mode -ceq "offline") {
        foreach ($value in @("-ArchivePath", [string]$env:PSH_SHELL_ARCHIVE_PATH, "-ArchiveSha256", [string]$env:PSH_SHELL_ARCHIVE_SHA256)) { [void]$childArguments.Add($value) }
    }
    if ($nonInteractive) { [void]$childArguments.Add("-NonInteractive") }
    $quotedArguments = New-Object System.Collections.Generic.List[string]
    foreach ($value in $childArguments) { [void]$quotedArguments.Add((ConvertTo-PshShellProcessArgument -Value $value)) }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $childPath
    $startInfo.Arguments = [string]::Join(" ", $quotedArguments.ToArray())
    $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName($entryPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $startInfo
    try { if (-not $child.Start()) { throw "Windows PowerShell child did not start" } }
    catch { Throw-PshShellParentFailure 3 "PshShellChildStart" "Io" ([string]$_.Exception.Message) "Verify Windows PowerShell 5.1 and run the installer again." }
    # Keep the entry FileShare.Read handle alive through child completion. A
    # higher ancestor rename remains the narrow limitation of path-based -File.
    $child.WaitForExit()
    $exitCode = [int]$child.ExitCode
}
catch {
    $failure = $_.Exception
    while ($null -ne $failure -and -not $failure.Data.Contains("PshShellExitCode") -and $null -ne $failure.InnerException) { $failure = $failure.InnerException }
    if ($null -ne $failure -and $failure.Data.Contains("PshShellExitCode")) {
        $exitCode = [int]$failure.Data["PshShellExitCode"]
        $code = [string]$failure.Data["PshShellCode"]
        $kind = [string]$failure.Data["PshShellKind"]
        $message = [string]$failure.Message
        $remediation = [string]$failure.Data["PshShellRemediation"]
    }
    else {
        $exitCode = 3
        $code = "PshShellParentRuntime"
        $kind = "Io"
        $message = [string]$_.Exception.Message
        $remediation = "Run the installer again."
    }
    [Console]::Error.WriteLine((@{schemaVersion=1;code=$code;exitCode=$exitCode;kind=$kind;message=$message;remediation=$remediation}|ConvertTo-Json -Compress))
}
finally {
    if ($null -ne $child) { try { $child.Dispose() } catch { } }
    if ($null -ne $hashAlgorithm) { try { $hashAlgorithm.Dispose() } catch { } }
    if ($null -ne $entryStream) { try { $entryStream.Dispose() } catch { } }
}
exit $exitCode
' \
    </dev/null
parent_status=$?
exit "$parent_status"
