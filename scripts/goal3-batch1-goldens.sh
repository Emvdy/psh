#!/usr/bin/env bash
# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

export LC_ALL=C

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s OUTPUT_ROOT\n' "${0##*/}" >&2
    exit 2
fi

output_root=$1
if [[ -e "$output_root" ]] && [[ -n "$(find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf 'Output directory must be empty: %s\n' "$output_root" >&2
    exit 2
fi

required_commands=(
    awk basename cat cd cp dirname find ln mkdir mktemp mv pwd
    realpath rm rmdir sed sha256sum sort touch xargs
)
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required GNU command is unavailable: %s\n' "$required_command" >&2
        exit 4
    fi
done

coreutils_version=$(basename --version | sed -n '1p')
findutils_version=$(command find --version | sed -n '1p')
if [[ "$coreutils_version" != *'GNU coreutils'* ]]; then
    printf 'GNU coreutils is required; found: %s\n' "$coreutils_version" >&2
    exit 4
fi
if [[ "$findutils_version" != *'GNU findutils'* ]]; then
    printf 'GNU findutils is required; found: %s\n' "$findutils_version" >&2
    exit 4
fi

mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd -P)

sandbox_root=$(mktemp -d "${TMPDIR:-/tmp}/psh-goal3-batch1.XXXXXX")
cleanup() {
    rm -rf -- "$sandbox_root"
}
trap cleanup EXIT

raw_root="$sandbox_root/.raw"
mkdir -p "$raw_root"

normalize_capture() {
    local source_path=$1
    local destination_path=$2

    awk -v sandbox="$sandbox_root" '
        {
            gsub(/\r/, "")
            gsub(/\\/, "/")
            while ((position = index($0, sandbox)) != 0) {
                $0 = substr($0, 1, position - 1) "<ROOT>" substr($0, position + length(sandbox))
            }
            print
        }
    ' "$source_path" > "$destination_path"
}

(cd "$sandbox_root" && pwd -P) > "$raw_root/pwd.raw"

mkdir -p "$sandbox_root/cd/child"
(cd "$sandbox_root/cd/child" && pwd -P) > "$raw_root/cd_pwd.raw"

(cd "$sandbox_root" && mkdir -pv mkdir/one/two) > "$raw_root/mkdir_verbose.raw"

mkdir -p "$sandbox_root/rmdir/one/two"
(cd "$sandbox_root" && rmdir -pv rmdir/one/two) > "$raw_root/rmdir_verbose.raw"

mkdir -p "$sandbox_root/cp"
printf 'alpha\nbeta\n' > "$sandbox_root/cp/source.txt"
cp -v "$sandbox_root/cp/source.txt" "$sandbox_root/cp/copy.txt" > "$raw_root/cp_verbose.raw"

mkdir -p "$sandbox_root/mv"
printf 'move me\n' > "$sandbox_root/mv/source.txt"
mv -v "$sandbox_root/mv/source.txt" "$sandbox_root/mv/moved.txt" > "$raw_root/mv_verbose.raw"

mkdir -p "$sandbox_root/rm"
printf 'remove me\n' > "$sandbox_root/rm/remove.txt"
rm -v "$sandbox_root/rm/remove.txt" > "$raw_root/rm_verbose.raw"

mkdir -p "$sandbox_root/touch"
touch "$sandbox_root/touch/created.txt" > "$raw_root/touch_quiet.raw"

mkdir -p "$sandbox_root/ln"
printf 'linked content\n' > "$sandbox_root/ln/source.txt"
ln -v "$sandbox_root/ln/source.txt" "$sandbox_root/ln/link.txt" > "$raw_root/ln_verbose.raw"

mkdir -p "$sandbox_root/realpath/child"
printf 'target\n' > "$sandbox_root/realpath/target.txt"
realpath "$sandbox_root/realpath/child/../target.txt" > "$raw_root/realpath.raw"

basename "$sandbox_root/basename/report.txt" .txt > "$raw_root/basename.raw"
dirname "$sandbox_root/dirname/child/report.txt" > "$raw_root/dirname.raw"

mkdir -p "$sandbox_root/mktemp"
(cd "$sandbox_root/mktemp" && mktemp item.XXXXXX) > "$raw_root/mktemp_pattern.raw"

case_ids=(
    pwd cd_pwd mkdir_verbose rmdir_verbose cp_verbose mv_verbose rm_verbose
    touch_quiet ln_verbose realpath basename dirname mktemp_pattern
)
for case_id in "${case_ids[@]}"; do
    normalize_capture "$raw_root/$case_id.raw" "$output_root/$case_id.txt"
done

sed -E 's#item\.[[:alnum:]]{6}#<TEMP_NAME>#g' \
    "$output_root/mktemp_pattern.txt" > "$raw_root/mktemp_pattern.normalized"
mv "$raw_root/mktemp_pattern.normalized" "$output_root/mktemp_pattern.txt"

cat > "$output_root/manifest.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "suite": "goal3-batch1-file-commands",
  "locale": "C",
  "normalization": {
    "pathSeparators": "forward-slash",
    "lineEndings": "LF",
    "sandboxRoot": "<ROOT>",
    "mktempBasename": "<TEMP_NAME>"
  },
  "entries": [
    { "id": "pwd", "command": "pwd -P", "expectedFile": "pwd.txt", "platformShaped": false },
    { "id": "cd_pwd", "command": "cd child; pwd -P", "expectedFile": "cd_pwd.txt", "platformShaped": false },
    { "id": "ls_names", "command": "ls", "expectedFile": null, "platformShaped": true },
    { "id": "mkdir_verbose", "command": "mkdir -pv mkdir/one/two", "expectedFile": "mkdir_verbose.txt", "platformShaped": false },
    { "id": "rmdir_verbose", "command": "rmdir -pv rmdir/one/two", "expectedFile": "rmdir_verbose.txt", "platformShaped": false },
    { "id": "cp_verbose", "command": "cp -v source.txt copy.txt", "expectedFile": "cp_verbose.txt", "platformShaped": false },
    { "id": "mv_verbose", "command": "mv -v source.txt moved.txt", "expectedFile": "mv_verbose.txt", "platformShaped": false },
    { "id": "rm_verbose", "command": "rm -v remove.txt", "expectedFile": "rm_verbose.txt", "platformShaped": false },
    { "id": "touch_quiet", "command": "touch created.txt", "expectedFile": "touch_quiet.txt", "platformShaped": false },
    { "id": "ln_verbose", "command": "ln -v source.txt link.txt", "expectedFile": "ln_verbose.txt", "platformShaped": false },
    { "id": "realpath", "command": "realpath child/../target.txt", "expectedFile": "realpath.txt", "platformShaped": false },
    { "id": "basename", "command": "basename report.txt .txt", "expectedFile": "basename.txt", "platformShaped": false },
    { "id": "dirname", "command": "dirname child/report.txt", "expectedFile": "dirname.txt", "platformShaped": false },
    { "id": "mktemp_pattern", "command": "mktemp item.XXXXXX", "expectedFile": "mktemp_pattern.txt", "platformShaped": false }
  ]
}
JSON

{
    printf 'Goal 3 Batch 1 GNU golden report\n'
    printf 'LC_ALL=%s\n' "$LC_ALL"
    printf '%s\n' "$coreutils_version"
    printf '%s\n' "$findutils_version"
    sha256sum --version | sed -n '1p'
} > "$output_root/toolchain-report.txt"

(
    cd "$output_root"
    find . -maxdepth 1 -type f \( -name '*.txt' -o -name 'manifest.json' \) \
        ! -name 'toolchain-report.txt' -printf '%P\0' \
        | sort -z \
        | xargs -0 sha256sum
) > "$output_root/SHA256SUMS"

printf 'Generated Goal 3 Batch 1 GNU goldens in %s\n' "$output_root"
