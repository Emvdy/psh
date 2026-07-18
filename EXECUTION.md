# Psh v0.1.0 Execution Record

This file records execution evidence for `PLAN.md`. A goal is complete only
after every applicable StopIf condition has been checked and every DoneWhen
condition has direct evidence.

## Status

| Goal | Status | Commit | Notes |
| --- | --- | --- | --- |
| Goal 0 | COMPLETE | `1f87695` | Safety baseline and repository |
| Goal 1 | COMPLETE | `83ed21f` | Module and machine-readable specification |
| Goal 2 | IN_PROGRESS | `380726f` | Automated matrix complete; real VM interaction pending |
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

- Goal 1 completion evidence commit: `83ed21f99793508d8112e429c8486869f5c97869`.
- Default-branch CI: <https://github.com/Emvdy/psh/actions/runs/29636062661>,
  conclusion `success` for the same completion head on `main`.

## Goal 2: Interactive Experience

Started: 2026-07-18 (Asia/Shanghai)

### Prerequisite

- [x] Goal 1 is complete on `main`; clean Windows PowerShell 5.1 and
  PowerShell 7 jobs passed import, generated-artifact, capability, completion,
  and current-user layout acceptance.

### Implementation Checklist

- [x] Pin and bundle PSReadLine `2.4.5` from an official immutable package.
- [x] Pin and bundle PSCompletions `6.10.0` from an official immutable package.
- [x] Record source URLs and SHA256 values and retain both upstream licenses.
- [x] Import fixed bundled PSReadLine only; validate the fixed PSCompletions
  manifest without executing its network-capable `ScriptsToProcess`, and use a
  Psh-owned offline Git completion adapter.
- [x] Bind Tab to `MenuComplete` and Ctrl+R to reverse history search.
- [x] Bind Up/Down arrows to prefix history search.
- [x] Configure prediction source `History` and view style `ListView` when the
  host supports it, with a safe documented fallback.
- [x] Add a compact ASCII prompt with path, previous status, and optional Git
  branch without requiring a Nerd Font.
- [x] Provide a safe non-VT fallback and verify no startup blocking path.
- [x] Validate profile markers strictly and stop on malformed marker state.
- [x] Back up and losslessly update both Windows PowerShell and PowerShell 7
  CurrentUserAllHosts profiles using one marked loader block.
- [x] Make profile update idempotent and restore exact pre-existing bytes on
  removal.
- [x] Add PS5.1-compatible automated tests for dependency pins, key bindings,
  prompt behavior, Unicode/space paths, profile backup/restore, malformed
  markers, and startup timing.
- [x] Run the Goal 2 automated matrix in Windows PowerShell 5.1 and PowerShell
  7 CI.
- [ ] Verify Tab, ListView, Ctrl+R, Chinese/space paths, and Git completion in
  VS Code on the real Windows 11 ARM64 VM.
- [x] Review the Goal 2 diff for secrets, caches, binaries, and unrelated files.
- [ ] Commit Goal 2, push it, and record commit, CI, VM logs, and screenshots.

### StopIf Checks

| Condition | State | Evidence / action |
| --- | --- | --- |
| Existing profile markers are malformed | NOT HIT (automated) | Five unmatched, duplicated, reversed, inline, or modified variants caused whole-batch refusal with zero profile/state writes. The complete matrix passed in local PS7, Windows PowerShell 5.1, and Windows PS7. |
| VT is unavailable with no safe fallback | NOT HIT (automated) | Redirected output disabled prediction with a structured reason while keys and the ANSI-free ASCII prompt remained available. Windows CI passed; real VS Code validation remains pending. |
| Shell startup becomes noticeably blocked | NOT HIT (automated) | Fresh local fixed-bundle initialization measured 229 ms cold and 73 ms warm, created zero jobs, did not import PSCompletions, and left the dependency tree byte-identical. Both Windows jobs also passed the enforced cold/warm timing bounds; real VM timing remains pending. |

### Known Environment Gate

- The real VM currently has all execution-policy scopes `Undefined`, yielding
  effective `Restricted`. Normal profile/module script loading is blocked.
  No GPO or policy was changed and no bypass was used. Automated implementation
  can proceed, but VM interactive acceptance will require a user-approved
  execution-policy/deployment path before Goal 2 can complete.

### DoneWhen Audit

- [ ] VS Code shows completions below the prompt.
- [ ] History view acceptance passes.
- [ ] Chinese paths pass interactive acceptance.
- [ ] Paths with spaces pass interactive acceptance.
- [ ] Git completion passes interactive acceptance.

### Automated Evidence

- Dependency verifier output: `2 fixed components, 14 independently pinned`
  `runtime files, and 2 verified licenses`. A negative fixture that changed a
  vendored file and its lock entry together was still rejected by the
  independent trusted manifest.
- Package SHA256: PSReadLine `2.4.5`
  `cb9390e9733208456c234a7971d1ec4a917886c239502aab68f4b71aa4bba235`;
  PSCompletions `6.10.0`
  `9f2bf9c6d143d2dc0c50a531b964f9f6ff30393077405914ca7d746ef8e38cb7`.
- Local runtime: official portable PowerShell `7.6.3` for macOS ARM64,
  archive SHA256
  `f0263c2072fe7d0953781c60497a574bea99b37237f2554a59ce4bad07de8d36`.
- Goal 2 implementation and Windows acceptance fixes:
  `c1d0047c8a0505b46cfcb2146a58aec3ec1467c3`,
  `0f872860c9b86e68812f961b30561c88e72eb937`,
  `2eaac03b1ad8692b9e5093361b3362381c1f9620`, and
  `380726f1b5f32b5e656e1f0742a71626e3a8cf8b`.
- Final branch CI: <https://github.com/Emvdy/psh/actions/runs/29643665073>,
  conclusion `success` at head `380726f1b5f32b5e656e1f0742a71626e3a8cf8b`.
  Both jobs and every non-cleanup step succeeded.
- Windows PowerShell job used `5.1.26100.32995`, PSEdition `Desktop`; the
  PowerShell job used `7.6.3`, PSEdition `Core`, platform `Win32NT`. Both used
  Git for Windows `2.55.0.windows.2` and passed generated-artifact checking,
  Goal 1 regression, the independent dependency verifier, and full Goal 2
  acceptance.
- The Windows matrix exercised the real fixed PSReadLine completion core in a
  runner with no usable console handle by injecting only a test `IConsole`;
  `_mockableMethods` remained the production singleton and singleton state was
  restored after the call. It also drained 6,000 valid LF-formatted packed refs
  and returned the deterministic 4,096-candidate cap on both runtimes.
- Goal 1 regression passed after bundling the managed PSReadLine assemblies.
- Goal 2 acceptance passed dependency isolation, actual PSReadLine
  implementation-assembly hash verification, exact handlers, engine-native Git
  command/ref completion in a Chinese and space-containing path, the real
  PSReadLine `GetCompletions` path, a 6,000-ref pipe-drain case capped at 4,096
  results, prompt status, Git branch, `LASTEXITCODE`, missing-prompt
  degradation, and profile tests.
- Assembly conflict coverage preserved a pre-existing correct bundled module
  while restoring a second conflict after forced verification failure. A fresh
  child process preloaded a one-byte-altered PSReadLine DLL and verified
  structured refusal plus exact module rollback.
- Profile coverage passed UTF-8 LF/no-BOM, UTF-8 BOM/CRLF, UTF-16LE/CRLF,
  empty and originally absent files; repeat install; exact uninstall; outside
  edits; marker conflicts; modified backup; modified managed block; real
  bootstrap scope isolation; `WarningPreference=Stop`; relative paths; atomic
  displaced-byte compare/exchange; unread recovery interleavings; and a
  cross-process state-root mutex with trailing-separator normalization. Windows
  CI additionally runs two system-ANSI round trips.
- Fresh local timing: 229 ms cold, 73 ms warm, zero jobs, PSReadLine assembly
  state `fixed-path`, and Git registrar `NativeArgumentCompleter` using the
  explicit native switch.
- Diff review found no cache, temporary, credential, or unrelated files and no
  common private-key/token signatures. No dedicated secret-scanner executable
  was installed locally; later Goal 6 CI retains the mandatory scanner gate.
- The PSCompletions Gallery original is retained byte-for-byte and audited. Its
  import is intentionally suppressed because isolated review confirmed module
  directory mutation, startup output, global state, and a network-capable
  update job. `Test-ModuleManifest` metadata validation caused zero writes,
  modules, variables, aliases, or jobs.
- During CI diagnosis the `Windows 11` VM was temporarily resumed only for
  read-only availability checks. Effective execution policy remained
  `Restricted`, Git was not installed, no policy or GPO was changed, and
  `prlctl status 'Windows 11'` again reported `paused` after the check.

### Remaining Work

Real Windows 11 ARM64 VS Code acceptance, screenshots, and final Goal 2 VM
evidence remain. The automated Windows PowerShell 5.1 and PowerShell 7 matrix,
diff/secret review, implementation commits, and branch push are complete. The
VM execution-policy gate still requires an approved deployment path. Goal 3
must not start until every Goal 2 DoneWhen check has direct evidence.
