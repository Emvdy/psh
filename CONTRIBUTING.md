# Contributing to Psh

Thank you for helping build Psh. The project is currently working toward its first release, so public interfaces and repository tooling may still change. [PLAN.md](PLAN.md) is the authoritative source for `v0.1.0` scope, safety stops, and acceptance criteria.

## Before starting

- Search existing issues and pull requests before opening a new one.
- For a behavior change or a substantial addition, open an issue first and explain the intended compatibility behavior, affected editions, and test approach.
- Keep changes within the `v0.1.0` scope. Psh is a command compatibility layer, not a Bash interpreter or general `.sh` runtime.
- Never include credentials, tokens, private test data, VM images, or proprietary binaries.

Security vulnerabilities must not be reported in a public issue. Follow [SECURITY.md](SECURITY.md) instead.

## Development requirements

Psh-owned PowerShell code must:

- parse and run on Windows PowerShell 5.1 as well as PowerShell 7;
- avoid `Invoke-Expression` for user command parsing;
- keep Core functional without third-party utility executables;
- preserve source encoding and line endings when editing files;
- use UTF-8 without a BOM for newly created text files;
- resolve paths before destructive operations and preserve the safeguards against deleting a drive root or the user's home directory; and
- avoid administrator requirements, Group Policy changes, execution-policy changes, permanent system `PATH` changes, and telemetry.

Do not silently accept unsupported command flags. Compatibility commands must emit plain text rather than formatted PowerShell objects and must use the documented exit-code contract.

## Tests

Add focused, table-driven Pester coverage for behavior changes. Tests should cover success, no-match, usage, runtime, dependency, and integrity outcomes where relevant. Include edge cases appropriate to the command, such as:

- Windows PowerShell 5.1 and PowerShell 7;
- Unicode and Chinese paths, spaces, CRLF and LF input;
- empty, binary, and hidden files;
- invalid arguments and destructive-operation boundaries; and
- Core behavior with native Full tools absent.

Text compatibility changes should include a GNU/Linux golden-output comparison when the corresponding GNU behavior is part of the contract. Installer or supply-chain changes require integration, checksum, license, and architecture coverage appropriate to their risk.

The exact test commands will be documented once the test harness lands. Until then, describe all checks you ran in the pull request and do not claim unrun tests as passing.

## Pull requests

- Make a narrowly scoped change with a clear commit history.
- Update English and Simplified Chinese user documentation together when public behavior changes.
- Add or update generated specifications through their source definition rather than editing generated output alone.
- Retain complete upstream license texts, source information, versions, architectures, URLs, and checksums for third-party material.
- Explain user-visible behavior, safety impact, Core/Full differences, and verification in the pull request description.
- Confirm that the diff contains no caches, build output, secrets, VM files, or unrelated changes.

All required CI and review gates must pass before merge. Real Windows 11 ARM64 acceptance remains mandatory for changes that affect release artifacts or Full native tools.

## Licensing contributions

Psh-owned work is licensed under `GPL-3.0-or-later`. By submitting a contribution, you agree that your contribution may be distributed under those terms and confirm that you have the right to submit it. Identify any third-party material explicitly and include its complete licensing and provenance information; do not add material whose license is incompatible with the project.
