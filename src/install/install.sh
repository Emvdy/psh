#!/usr/bin/env bash
# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

set -u

policy_remediation='Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
edition='Core'
version='latest'
offline=0
non_interactive=0
seen_edition=0
seen_version=0

write_usage() {
    printf '%s\n' 'Usage: install.sh [--offline] [--edition Core|Full] [--version latest|x.y.z] [--non-interactive]'
}

fail_json() {
    local exit_code="$1"
    local code="$2"
    local message="$3"
    printf '{"schemaVersion":1,"code":"%s","exitCode":%s,"kind":"Dependency","message":"%s","remediation":"%s"}\n' \
        "$code" "$exit_code" "$message" "$policy_remediation" >&2
    exit "$exit_code"
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

if [[ "$version" != 'latest' && ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
    fail_json 2 'PshShellUsage' 'Version must be latest or a semantic x.y.z version.'
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
        rm -f -- "$temporary_root/latest.json" "$temporary_root/install.ps1"
        rmdir -- "$temporary_root" 2>/dev/null || true
    fi
    return "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

entry_path=''
if ((offline == 1)); then
    entry_path="$script_dir/install-offline.ps1"
    [[ -f "$entry_path" ]] || fail_json 4 'PshShellOfflineMissing' 'The adjacent install-offline.ps1 entry was not found.'
else
    command -v curl >/dev/null 2>&1 || fail_json 4 'PshShellCurlMissing' 'curl is required for online installation.'
    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/psh-install.XXXXXXXX")" || fail_json 3 'PshShellTemp' 'Unable to create a temporary installer directory.'

    fixed_version="$version"
    if [[ "$version" == 'latest' ]]; then
        latest_path="$temporary_root/latest.json"
        curl --fail --silent --show-error \
            --retry 4 --retry-all-errors --retry-delay 1 \
            --connect-timeout 30 --max-time 120 \
            --proto '=https' \
            --output "$latest_path" \
            'https://api.github.com/repos/Emvdy/psh/releases/latest' \
            || fail_json 3 'PshShellLatestTransport' 'Unable to resolve the latest Psh release from the GitHub API.'
        latest_windows_path="$(to_windows_path "$latest_path")" || fail_json 3 'PshShellPath' 'Unable to convert the latest-release document path.'
        fixed_tag="$($powershell_path -NoLogo -NoProfile -NonInteractive -Command \
            '$ErrorActionPreference="Stop";$d=Get-Content -LiteralPath $args[0] -Raw|ConvertFrom-Json;if($d.draft -isnot [bool] -or $d.prerelease -isnot [bool] -or $d.draft -or $d.prerelease){exit 5};$tag=[string]$d.tag_name;if($tag -cnotmatch "\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"){exit 5};[Console]::Out.Write($tag)' \
            "$latest_windows_path")"
        parse_status=$?
        ((parse_status == 0)) || fail_json 5 'PshShellLatestSchema' 'The GitHub latest-release response did not contain a fixed stable semantic-version tag.'
        fixed_tag="${fixed_tag//$'\r'/}"
        fixed_version="${fixed_tag#v}"
    else
        fixed_tag="v$fixed_version"
    fi

    entry_path="$temporary_root/install.ps1"
    entry_url="https://github.com/Emvdy/psh/releases/download/$fixed_tag/install.ps1"
    effective_url="$(curl --fail --silent --show-error --location --max-redirs 5 \
        --retry 4 --retry-all-errors --retry-delay 1 \
        --connect-timeout 30 --max-time 180 \
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

"$powershell_path" -NoLogo -NoProfile -NonInteractive -Command \
    '$ErrorActionPreference="Stop";$path=$args[0];$remediation="Set-ExecutionPolicy -Scope CurrentUser RemoteSigned";try{$policy=[string](Get-ExecutionPolicy);$streams=@(Get-Item -LiteralPath $path -Stream * -ErrorAction Stop);$zones=@($streams|Where-Object{[string]$_.Stream -eq "Zone.Identifier"});$internet=$false;if($zones.Count -gt 1){throw "Multiple Zone.Identifier streams"};if($zones.Count -eq 1){$text=Get-Content -LiteralPath $path -Stream "Zone.Identifier" -Raw -ErrorAction Stop;$m=[regex]::Matches([string]$text,"(?im)^\s*ZoneId\s*=\s*([0-9]+)\s*$");if($m.Count -ne 1){throw "Malformed Zone.Identifier"};$zone=[int]$m[0].Groups[1].Value;if($zone -lt 0 -or $zone -gt 4){throw "Unknown ZoneId"};$internet=$zone -ge 3};if($policy -in @("Restricted","AllSigned") -or ($policy -eq "RemoteSigned" -and $internet)){[Console]::Error.WriteLine((@{schemaVersion=1;code="PshExecutionPolicy";exitCode=4;kind="Dependency";message="PowerShell execution policy does not allow this installer workflow.";remediation=$remediation}|ConvertTo-Json -Compress));exit 4};$signature=Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop;if([string]$signature.Status -ne "Valid"){[Console]::Error.WriteLine((@{schemaVersion=1;code="PshEntrySignature";exitCode=4;kind="Dependency";message="The installer entry does not have a valid trusted Authenticode signature.";remediation=$remediation}|ConvertTo-Json -Compress));exit 4};exit 0}catch{[Console]::Error.WriteLine((@{schemaVersion=1;code="PshExecutionPolicyProbe";exitCode=4;kind="Dependency";message=[string]$_.Exception.Message;remediation=$remediation}|ConvertTo-Json -Compress));exit 4}' \
    "$entry_windows_path"
preflight_status=$?
((preflight_status == 0)) || exit "$preflight_status"

forwarded=(-NoLogo -NoProfile -File "$entry_windows_path" -Edition "$edition" -Version "$version")
if ((non_interactive == 1)); then
    forwarded+=(-NonInteractive)
fi

"$powershell_path" "${forwarded[@]}"
installer_status=$?
exit "$installer_status"
