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
    if command -v wslpath >/dev/null 2>&1 && [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]]; then
        wslpath -w "$path"
        return
    fi
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$path"
        return
    fi
    printf '%s\n' "$path"
}

powershell_path="$(find_powershell)" || fail_json 4 'PshShellPowerShellMissing' 'Windows PowerShell 5.1 powershell.exe was not found.'

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)" || fail_json 3 'PshShellPath' 'Unable to resolve the installer directory.'
temporary_root=''

cleanup() {
    local cleanup_status=$?
    if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
        rm -f -- "$temporary_root/release.json" "$temporary_root/install.ps1"
        rmdir -- "$temporary_root" 2>/dev/null || true
    fi
    return "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

entry_path=''
entry_url=''
expected_entry_length=''
expected_entry_sha256=''
archive_windows_path=''
if ((offline == 1)); then
    entry_path="$script_dir/install-offline.ps1"
    [[ -f "$entry_path" ]] || fail_json 4 'PshShellOfflineMissing' 'The adjacent install-offline.ps1 entry was not found.'
    archive_windows_path="$(to_windows_path "$archive_path")" || fail_json 3 'PshShellPath' 'Unable to convert the offline archive path.'
else
    command -v curl >/dev/null 2>&1 || fail_json 4 'PshShellCurlMissing' 'curl is required for online installation.'
    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/psh-install.XXXXXXXX")" || fail_json 3 'PshShellTemp' 'Unable to create a temporary installer directory.'

    if [[ "$version" == 'latest' ]]; then
        requested_tag=''
        release_api_url='https://api.github.com/repos/Emvdy/psh/releases/latest'
    else
        requested_tag="v$version"
        release_api_url="https://api.github.com/repos/Emvdy/psh/releases/tags/$requested_tag"
    fi

    release_metadata_path="$temporary_root/release.json"
    release_api_result="$(curl --fail --silent --show-error \
        --retry 3 --retry-all-errors --retry-delay 1 \
        --connect-timeout 30 --max-time 120 \
        --max-filesize 16777216 \
        --proto '=https' \
        --output "$release_metadata_path" --write-out '%{http_code}|%{url_effective}' \
        "$release_api_url")" \
        || fail_json 3 'PshShellReleaseMetadataTransport' 'Unable to obtain fixed GitHub release metadata after retries.'
    [[ "$release_api_result" == "200|$release_api_url" ]] || fail_json 5 'PshShellReleaseMetadataResponse' 'GitHub release metadata did not return an exact non-redirected HTTP 200 response.'
    release_metadata_windows_path="$(to_windows_path "$release_metadata_path")" || fail_json 3 'PshShellPath' 'Unable to convert the release-metadata document path.'
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

    entry_path="$temporary_root/install.ps1"
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

entry_windows_path="$(to_windows_path "$entry_path")" || fail_json 3 'PshShellPath' 'Unable to convert the PowerShell installer path.'

if ((offline == 0)); then
    PSH_SHELL_ENTRY_PATH="$entry_windows_path" PSH_SHELL_ENTRY_LENGTH="$expected_entry_length" PSH_SHELL_ENTRY_SHA256="$expected_entry_sha256" \
        "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command \
        '$ErrorActionPreference="Stop";$path=$env:PSH_SHELL_ENTRY_PATH;$stream=$null;$sha=$null;try{$expectedLength=[int64]::Parse([string]$env:PSH_SHELL_ENTRY_LENGTH,[Globalization.CultureInfo]::InvariantCulture);$expectedSha=[string]$env:PSH_SHELL_ENTRY_SHA256;$attributes=[IO.File]::GetAttributes($path);if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Downloaded installer is a reparse point"};$stream=New-Object IO.FileStream($path,([IO.FileMode]::Open),([IO.FileAccess]::Read),([IO.FileShare]::Read));if($stream.Length -ne $expectedLength){throw "Downloaded installer length does not match GitHub release metadata"};$sha=[Security.Cryptography.SHA256]::Create();$actual=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-","").ToLowerInvariant();if($actual -cne $expectedSha){throw "Downloaded installer SHA256 does not match GitHub release metadata"};exit 0}catch{[Console]::Error.WriteLine((@{schemaVersion=1;code="PshShellEntryDigest";exitCode=5;kind="Integrity";message=[string]$_.Exception.Message;remediation="Download the installer again from the fixed GitHub release."}|ConvertTo-Json -Compress));exit 5}finally{if($null -ne $sha){$sha.Dispose()};if($null -ne $stream){$stream.Dispose()}}'
    digest_status=$?
    ((digest_status == 0)) || exit "$digest_status"
fi

non_interactive_value="$non_interactive"
PSH_SHELL_POLICY_ENTRY_PATH="$entry_windows_path" PSH_SHELL_POLICY_NON_INTERACTIVE="$non_interactive_value" \
    "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command \
    '$ErrorActionPreference="Stop";$path=$env:PSH_SHELL_POLICY_ENTRY_PATH;$nonInteractive=[string]$env:PSH_SHELL_POLICY_NON_INTERACTIVE -ceq "1";$remediation="Set-ExecutionPolicy -Scope CurrentUser RemoteSigned";try{$policy=[string](Get-ExecutionPolicy);$streams=@(Get-Item -LiteralPath $path -Stream * -ErrorAction Stop);$zones=@($streams|Where-Object{[string]$_.Stream -eq "Zone.Identifier"});$internet=$false;if($zones.Count -gt 1){throw "Multiple Zone.Identifier streams"};if($zones.Count -eq 1){$text=Get-Content -LiteralPath $path -Stream "Zone.Identifier" -Raw -ErrorAction Stop;$m=[regex]::Matches([string]$text,"(?im)^\s*ZoneId\s*=\s*([0-9]+)\s*$");if($m.Count -ne 1){throw "Malformed Zone.Identifier"};$zone=[int]$m[0].Groups[1].Value;if($zone -lt 0 -or $zone -gt 4){throw "Unknown ZoneId"};$internet=$zone -ge 3};$signature=[string](Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop).Status;$validSignature=$signature -ieq "Valid";$allowed=($policy -ieq "Bypass") -or (($policy -ieq "AllSigned") -and $validSignature) -or (($policy -ieq "RemoteSigned") -and (-not $internet -or $validSignature)) -or (($policy -ieq "Unrestricted") -and -not ($nonInteractive -and $internet -and -not $validSignature));if(-not $allowed){[Console]::Error.WriteLine((@{schemaVersion=1;code="PshExecutionPolicy";exitCode=4;kind="Dependency";message="PowerShell execution policy does not allow this installer workflow.";remediation=$remediation}|ConvertTo-Json -Compress));exit 4};exit 0}catch{[Console]::Error.WriteLine((@{schemaVersion=1;code="PshExecutionPolicyProbe";exitCode=4;kind="Dependency";message=[string]$_.Exception.Message;remediation=$remediation}|ConvertTo-Json -Compress));exit 4}' \
    </dev/null
preflight_status=$?
((preflight_status == 0)) || exit "$preflight_status"

forwarded=(-NoLogo -NoProfile -File "$entry_windows_path" -Edition "$edition" -Version "$version")
if ((offline == 1)); then
    forwarded+=(-ArchivePath "$archive_windows_path" -ArchiveSha256 "$archive_sha256")
fi
if ((non_interactive == 1)); then
    forwarded+=(-NonInteractive)
fi

"$powershell_path" "${forwarded[@]}"
installer_status=$?
exit "$installer_status"
