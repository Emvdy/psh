#!/usr/bin/env bash
# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

export LC_ALL=C

if [[ $# -ne 1 ]] || [[ -z $1 ]]; then
    printf 'Usage: %s OUTPUT_ROOT\n' "${0##*/}" >&2
    exit 2
fi

output_root=$1
if [[ -e "$output_root" ]] && [[ ! -d "$output_root" ]]; then
    printf 'Output path must be a directory: %s\n' "$output_root" >&2
    exit 2
fi
if [[ -d "$output_root" ]]; then
    shopt -s dotglob nullglob
    output_entries=("$output_root"/*)
    shopt -u dotglob nullglob
    if (( ${#output_entries[@]} != 0 )); then
        printf 'Output directory must be empty: %s\n' "$output_root" >&2
        exit 2
    fi
fi

required_commands=(env printenv test sleep sha256sum md5sum mkdir mktemp rm)
required_paths=()
required_versions=()
for required_command in "${required_commands[@]}"; do
    command_path=$(type -P -- "$required_command" || true)
    if [[ -z "$command_path" ]]; then
        printf 'Required GNU coreutils command is unavailable: %s\n' "$required_command" >&2
        exit 4
    fi
    required_paths+=("$command_path")

    if [[ "$required_command" == test ]]; then
        required_versions+=('')
        continue
    fi

    if ! version_output=$("$command_path" --version 2>&1); then
        printf 'Unable to identify required command: %s\n' "$command_path" >&2
        exit 4
    fi
    version_line=${version_output%%$'\n'*}
    if [[ "$version_line" != *'GNU coreutils'* ]]; then
        printf 'GNU coreutils is required for %s; found: %s\n' "$required_command" "$version_line" >&2
        exit 4
    fi
    required_versions+=("$version_line")
done

env_path=${required_paths[0]}
printenv_path=${required_paths[1]}
test_path=${required_paths[2]}
sleep_path=${required_paths[3]}
sha256sum_path=${required_paths[4]}
md5sum_path=${required_paths[5]}
mkdir_path=${required_paths[6]}
mktemp_path=${required_paths[7]}
rm_path=${required_paths[8]}

# GNU test intentionally treats --version as a normal string operand. Verify
# that the external executable comes from the same coreutils installation.
if [[ "${test_path%/*}" != "${env_path%/*}" ]]; then
    printf 'GNU coreutils is required for test; found: %s\n' "$test_path" >&2
    exit 4
fi
if ! "$test_path" -n value || "$test_path" -n ''; then
    printf 'Required test command failed its coreutils behavior check: %s\n' "$test_path" >&2
    exit 4
fi

"$mkdir_path" -p "$output_root"
output_root=$(cd "$output_root" && pwd -P)

sandbox_root=$("$mktemp_path" -d "${TMPDIR:-/tmp}/psh-goal3-batch4.XXXXXX")
cleanup() {
    "$rm_path" -rf -- "$sandbox_root"
}
trap cleanup EXIT

"$env_path" -i \
    PSH_BATCH4_GOLDEN_ZETA=two \
    PSH_BATCH4_GOLDEN_ALPHA=one \
    > "$output_root/env_clean.txt"

PSH_BATCH4_GOLDEN_ALPHA='first value' \
PSH_BATCH4_GOLDEN_ZETA='second value' \
    "$printenv_path" PSH_BATCH4_GOLDEN_ALPHA PSH_BATCH4_GOLDEN_ZETA \
    > "$output_root/printenv_values.txt"

"$test_path" -n value > "$output_root/test_true.txt"
"$sleep_path" 0 > "$output_root/sleep_zero.txt"

checksum_path="$sandbox_root/checksum payload.bin"
printf '\000\001\002\003\012\015\177\200\377' > "$checksum_path"
(
    cd "$sandbox_root"
    "$sha256sum_path" 'checksum payload.bin'
) > "$output_root/sha256sum.txt"
(
    cd "$sandbox_root"
    "$md5sum_path" 'checksum payload.bin'
) > "$output_root/md5sum.txt"

cat > "$output_root/manifest.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "suite": "goal3-batch4-system-process-archive-commands",
  "locale": "C",
  "normalization": {
    "lineEndings": "LF",
    "trailingNewline": "ignored-once-by-acceptance"
  },
  "fixtures": [
    {
      "path": "checksum payload.bin",
      "hexBytes": "000102030a0d7f80ff"
    }
  ],
  "entries": [
    { "id": "env_clean", "command": "env -i PSH_BATCH4_GOLDEN_ZETA=two PSH_BATCH4_GOLDEN_ALPHA=one", "expectedFile": "env_clean.txt" },
    { "id": "printenv_values", "command": "printenv PSH_BATCH4_GOLDEN_ALPHA PSH_BATCH4_GOLDEN_ZETA", "expectedFile": "printenv_values.txt" },
    { "id": "test_true", "command": "test -n value", "expectedFile": "test_true.txt" },
    { "id": "sleep_zero", "command": "sleep 0", "expectedFile": "sleep_zero.txt" },
    { "id": "sha256sum", "command": "sha256sum 'checksum payload.bin'", "expectedFile": "sha256sum.txt" },
    { "id": "md5sum", "command": "md5sum 'checksum payload.bin'", "expectedFile": "md5sum.txt" }
  ]
}
JSON

{
    printf 'Goal 3 Batch 4 GNU golden report\n'
    printf 'LC_ALL=%s\n' "$LC_ALL"
    for index in "${!required_commands[@]}"; do
        if [[ "${required_commands[$index]}" == test ]]; then
            printf 'test (GNU coreutils installation: %s)\n' "${test_path%/*}"
        else
            printf '%s\n' "${required_versions[$index]}"
        fi
    done
} > "$output_root/toolchain-report.txt"

checksum_inputs=(
    env_clean.txt
    manifest.json
    md5sum.txt
    printenv_values.txt
    sha256sum.txt
    sleep_zero.txt
    test_true.txt
)
(
    cd "$output_root"
    "$sha256sum_path" "${checksum_inputs[@]}"
) > "$output_root/SHA256SUMS"

printf 'Generated Goal 3 Batch 4 GNU goldens in %s\n' "$output_root"
