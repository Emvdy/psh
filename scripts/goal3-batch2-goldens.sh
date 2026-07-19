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
    base64 cat cut env find head mkdir mktemp rm sed sha256sum sort tail tee tr uniq wc xargs
)
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'Required GNU command is unavailable: %s\n' "$required_command" >&2
        exit 4
    fi
done

coreutils_version=$(cat --version | sed -n '1p')
if [[ "$coreutils_version" != *'GNU coreutils'* ]]; then
    printf 'GNU coreutils is required; found: %s\n' "$coreutils_version" >&2
    exit 4
fi

mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd -P)

sandbox_root=$(mktemp -d "${TMPDIR:-/tmp}/psh-goal3-batch2.XXXXXX")
cleanup() {
    rm -rf -- "$sandbox_root"
}
trap cleanup EXIT

text_path="$sandbox_root/text.txt"
csv_path="$sandbox_root/data.csv"
binary_path="$sandbox_root/small.bin"

env printf 'alpha\n\nbeta\nbeta\n10\n2\n' > "$text_path"
env printf 'one,two,three\nfour,five,six\n' > "$csv_path"
env printf '\000\001\002\375\376\377' > "$binary_path"

cat -ns "$text_path" > "$output_root/cat_ns.txt"
head -n 2 "$text_path" > "$output_root/head_n2.txt"
tail -n 2 "$text_path" > "$output_root/tail_n2.txt"
cut -d, -f1,3 "$csv_path" > "$output_root/cut_fields.txt"
env printf %s 'alpha beta' | tr '[:lower:]' '[:upper:]' > "$output_root/tr_upper.txt"
env printf '10\n2\n1' | sort -n > "$output_root/sort_numeric.txt"
env printf 'a\na\nb' | uniq -c > "$output_root/uniq_count.txt"
cat "$text_path" | wc -lw > "$output_root/wc_lw.txt"
env printf %s 'tee golden' | tee "$sandbox_root/tee.txt" > "$output_root/tee_text.txt"
env printf '%s:%03d\n' value 7 > "$output_root/printf_format.txt"
env echo -e 'one\ttwo' > "$output_root/echo_escape.txt"
base64 -w0 "$binary_path" > "$output_root/base64_encode.txt"

cat > "$output_root/manifest.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "suite": "goal3-batch2-text-commands",
  "locale": "C",
  "normalization": {
    "lineEndings": "LF",
    "trailingNewline": "ignored-once-by-acceptance"
  },
  "entries": [
    { "id": "cat_ns", "command": "cat -ns text.txt", "expectedFile": "cat_ns.txt" },
    { "id": "head_n2", "command": "head -n 2 text.txt", "expectedFile": "head_n2.txt" },
    { "id": "tail_n2", "command": "tail -n 2 text.txt", "expectedFile": "tail_n2.txt" },
    { "id": "cut_fields", "command": "cut -d, -f1,3 data.csv", "expectedFile": "cut_fields.txt" },
    { "id": "tr_upper", "command": "printf %s 'alpha beta' | tr '[:lower:]' '[:upper:]'", "expectedFile": "tr_upper.txt" },
    { "id": "sort_numeric", "command": "printf '10\\n2\\n1' | sort -n", "expectedFile": "sort_numeric.txt" },
    { "id": "uniq_count", "command": "printf 'a\\na\\nb' | uniq -c", "expectedFile": "uniq_count.txt" },
    { "id": "wc_lw", "command": "cat text.txt | wc -lw", "expectedFile": "wc_lw.txt" },
    { "id": "tee_text", "command": "printf %s 'tee golden' | tee tee.txt", "expectedFile": "tee_text.txt" },
    { "id": "printf_format", "command": "printf '%s:%03d\\n' value 7", "expectedFile": "printf_format.txt" },
    { "id": "echo_escape", "command": "echo -e 'one\\ttwo'", "expectedFile": "echo_escape.txt" },
    { "id": "base64_encode", "command": "base64 -w0 small.bin", "expectedFile": "base64_encode.txt" }
  ]
}
JSON

{
    printf 'Goal 3 Batch 2 GNU golden report\n'
    printf 'LC_ALL=%s\n' "$LC_ALL"
    printf '%s\n' "$coreutils_version"
    base64 --version | sed -n '1p'
    sort --version | sed -n '1p'
} > "$output_root/toolchain-report.txt"

(
    cd "$output_root"
    find . -maxdepth 1 -type f \( -name '*.txt' -o -name 'manifest.json' \) \
        ! -name 'toolchain-report.txt' -printf '%P\0' \
        | sort -z \
        | xargs -0 sha256sum
) > "$output_root/SHA256SUMS"

printf 'Generated Goal 3 Batch 2 GNU goldens in %s\n' "$output_root"
