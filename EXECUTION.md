# Psh v0.1.0 Execution Record

This file records execution evidence for `PLAN.md`. A goal is complete only
after every applicable StopIf condition has been checked and every DoneWhen
condition has direct evidence.

## Status

| Goal | Status | Commit | Notes |
| --- | --- | --- | --- |
| Goal 0 | COMPLETE | `1f87695` | Safety baseline and repository |
| Goal 1 | COMPLETE | `6e5641c` | Module and machine-readable specification |
| Goal 2 | PENDING | - | Blocked on Goal 1 DoneWhen |
| Goal 3 | PENDING | - | Blocked on Goal 2 DoneWhen |
| Goal 4 | PENDING | - | Blocked on Goal 3 DoneWhen |
| Goal 5 | PENDING | - | Blocked on Goal 4 DoneWhen |
| Goal 6 | PENDING | - | Blocked on Goal 5 DoneWhen |
| Goal 7 | PENDING | - | Blocked on Goal 6 DoneWhen |
| Goal 8 | PENDING | - | Blocked on Goal 7 DoneWhen |

## Goal 0: Safety Baseline And Repository

Started: 2026-07-18 (Asia/Shanghai)

### Prerequisite

- [x] No prior goal is required.

### Implementation Checklist

- [x] Reauthenticate the `Emvdy` GitHub account with `gh auth login`.
- [x] Confirm that `Emvdy/psh` is absent or contains only this project.
- [x] Create or configure public repository `Emvdy/psh`.
- [x] Add `GPL-3.0-or-later` license and bilingual README files.
- [x] Add contribution guide and security policy.
- [x] Configure protected GitHub Environment `release`.
- [x] Add `origin`, push `main`, and verify it is the default branch.
- [x] Locate the exact Parallels VM named `Windows 11`.
- [x] Record ARM64 architecture and Parallels Guest Tools state.
- [x] Create a pre-install snapshot named `psh-preinstall-<timestamp>`.
- [x] Record the pre-install snapshot ID.
- [x] Run read-only guest diagnostics with `prlctl exec --current-user`.
- [x] Review the complete Goal 0 diff for credentials and unrelated files.
- [x] Commit Goal 0 and record the commit SHA.

### StopIf Checks

| Condition | State | Evidence / action |
| --- | --- | --- |
| GitHub authentication remains invalid | NOT_HIT | After browser reauthentication, sandbox-external `gh auth status -h github.com` succeeded for `Emvdy` using the keyring. |
| Repository name belongs to unrelated content | NOT_HIT | Authenticated `gh repo view Emvdy/psh` reported that no such repository exists. |
| VM snapshot fails | NOT_HIT | Snapshot creation succeeded and its details were read back by ID. |
| Guest execution requires a plaintext password | NOT_HIT | `prlctl exec 'Windows 11' --current-user cmd.exe /d /c whoami` succeeded without a password argument. |

### Evidence Collected

- Local branch: `main`; `git status --short --branch` reported
  `No commits yet on main` with only `PLAN.md` initially untracked.
- Git remote: none (`git remote -v` produced no output).
- GitHub authentication: the initial token was invalid; browser reauthentication
  completed, then `gh auth status -h github.com` and `gh api user --jq .login`
  succeeded for `Emvdy` on 2026-07-18.
- Repository ownership pre-check: authenticated `gh repo view Emvdy/psh`
  returned `Could not resolve to a Repository`, so no existing repository will
  be overwritten or repurposed.
- Repository: <https://github.com/Emvdy/psh>, visibility `PUBLIC`; GitHub
  identifies the license as GNU GPLv3.
- Initial Goal 0 commit: `1f876951b5773bf56318db0da28d49126a9c58da`.
- Initial push output reported a new `main` branch and configured it to track
  `origin/main`.
- Remote default branch: `main`; `git ls-remote --symref origin HEAD` returned
  `ref: refs/heads/main` and the same commit SHA as local `HEAD`.
- Protected Environment: `release`; API verification returned a
  `required_reviewers` protection rule for GitHub user `Emvdy`.
- VM inventory: exact name `Windows 11`, UUID
  `{acb3e79b-bc02-4c09-9620-275777f58a23}`, status `paused`.
- VM architecture: `BIOS type: efi-arm64` and CPU `type=arm`.
- Parallels Guest Tools: installed, version `26.2.0-57363`.
- Pre-install snapshot: name `psh-preinstall-20260718-135918`, ID
  `{9f0989bf-a672-45a3-b0d4-e8895e860ce4}`, created
  `2026-07-18 13:59:43`, state `pause`, current `yes`.
- Passwordless guest diagnostic:
  `prlctl exec 'Windows 11' --current-user cmd.exe /d /c whoami` returned
  `emvdy217f\emvdy`.
- Post-diagnostic VM status: `VM Windows 11 exist paused`.

### DoneWhen Audit

- [x] Remote accepts pushes.
- [x] `main` is the default branch.
- [x] Pre-install snapshot ID is recorded.
- [x] `prlctl exec --current-user` runs read-only diagnostics.

### Remaining Work

None. All Goal 0 StopIf conditions were checked and not hit after remediation,
and all Goal 0 DoneWhen conditions have direct evidence. Goal 1 may start.

## Goal 1: Module And Machine-Readable Specification

Started: 2026-07-18 (Asia/Shanghai)

### Prerequisite

- [x] Goal 0 is complete and all four Goal 0 DoneWhen checks have direct
  evidence above.

### Implementation Checklist

- [x] Create a Windows PowerShell 5.1-compatible `Psh` module and manifest.
- [x] Define all 64 command names, flags, exit codes, Core/Full backends, help,
  examples, object APIs, and completion data in one structured specification.
- [x] Define all management commands and JSON-capable interfaces in the same
  specification.
- [x] Generate `commands.json` deterministically from the specification.
- [x] Generate the compatibility documentation from the specification.
- [x] Generate argument completers from the specification.
- [x] Implement `psh capabilities --json` with active Core/Full backends.
- [x] Implement the `%LOCALAPPDATA%\Psh\versions\<version>` layout contract.
- [x] Add stable `bootstrap.ps1`, default `config.psd1`, and atomic
  `current.json` switching support.
- [x] Add focused Goal 1 tests, including generated-artifact drift checks.
- [x] Verify Core has no third-party utility executable dependency.
- [x] Import the module in clean PowerShell 7 and verify 64 capabilities.
- [x] Import the module in clean Windows PowerShell 5.1 and verify 64
  capabilities.
- [x] Review the complete Goal 1 diff for secrets and unrelated files.
- [x] Commit Goal 1, push it, and record the commit SHA and test evidence.

### StopIf Checks

| Condition | State | Evidence / action |
| --- | --- | --- |
| Core unexpectedly requires PowerShell 7 | NOT_HIT | Windows x64 CI imported and exercised the module in Windows PowerShell 5.1.26100.32995. |
| Core requires administrator access | NOT_HIT | Acceptance uses an isolated current-user temporary layout; source scan found no elevation request. |
| Core performs startup downloads | NOT_HIT | Module/bootstrap review and acceptance found no network API; import and bootstrap are local-only. |
| Core requires third-party utility executables | NOT_HIT | Core reports all backends as `powershell`; source contains no EXE/DLL and acceptance passes without native tools. |

### Evidence Collected

- Authoritative specification:
  `src/Psh/Specification/commands.psd1`, schema `1.0`, version `0.1.0`,
  exactly 64 unique commands and management actions from PLAN.md.
- Deterministic generator: PowerShell 7.6.3 ARM64 generated
  `generated/commands.json`, `docs/compatibility.md`, and
  `src/Psh/Generated/ArgumentCompleters.ps1`; a separate `-Check` run returned
  `Generated command artifacts are up to date.`
- PS7 test runtime: official PowerShell `v7.6.3` macOS ARM64 portable asset;
  SHA256 `f0263c2072fe7d0953781c60497a574bea99b37237f2554a59ce4bad07de8d36`
  matched the official `hashes.sha256` asset. The runtime remained under
  `/private/tmp` and was not installed or added to PATH.
- Clean PS7 acceptance output:
  `Goal 1 acceptance passed: specification, generated artifacts, module`
  `capabilities, safety constraints, and install layout.`
- Direct capabilities output: Core reported 64 commands, no native backends,
  exit `0`; Full reported 64 commands with only `fd,bat,rg,jq` native, exit
  `0`.
- Real VM PS5.1 runtime: `5.1.26100.8655`. Parser API read-only validation
  returned `PS5.1_PARSE files=9 errors=0`.
- VM import blocker: every `Get-ExecutionPolicy -List` scope is `Undefined`,
  producing the Windows client effective `Restricted` policy. A normal,
  non-bypassed `Import-Module` returned `PSSecurityException`,
  `UnauthorizedAccess`, stating that script execution is disabled. No policy
  or GPO was changed.
- Safe alternative completed: `.github/workflows/goal1.yml` ran the same
  generated-artifact and acceptance tests on Windows x64 with native Windows
  PowerShell 5.1 and PowerShell 7.
- Goal 1 implementation head: `6e5641cb34360124eade55545ed028b0b005debd`.
- Final branch CI: <https://github.com/Emvdy/psh/actions/runs/29635418864>,
  conclusion `success`. Both jobs and every non-cleanup test step succeeded.
- Windows PowerShell job: version `5.1.26100.32995`, PSEdition `Desktop`;
  generator `-Check` and Goal 1 acceptance both passed.
- PowerShell job: version `7.6.3`, PSEdition `Core`, Win32NT;
  generator `-Check` and Goal 1 acceptance both passed.
- CI action supply chain: `actions/checkout` is pinned to immutable v6 commit
  `df4cb1c069e1874edd31b4311f1884172cec0e10`; final logs contain no Node 20
  deprecation warning.
- Line-ending determinism: `.gitattributes` fixes generated and source text to
  LF; the same byte-level `-Check` passed on PS5.1 and PS7 Windows jobs.
- VM test-batch cleanup: original `pause-idle=on` was restored and
  `prlctl status 'Windows 11'` returned `VM Windows 11 exist paused`.

### DoneWhen Audit

- [x] Module imports in a clean Windows PowerShell 5.1 session.
- [x] Module imports in a clean PowerShell 7 session.
- [x] `psh capabilities --json` reports all 64 commands and active backends.

### Remaining Work

None. All Goal 1 StopIf conditions were checked and not hit, and all Goal 1
DoneWhen conditions have direct evidence. Goal 2 may start after this evidence
commit is merged to `main` and the resulting `main` workflow is green.
