# Psh v0.1.0 Execution Record

This file records execution evidence for `PLAN.md`. A goal is complete only
after every applicable StopIf condition has been checked and every DoneWhen
condition has direct evidence.

## Status

| Goal | Status | Commit | Notes |
| --- | --- | --- | --- |
| Goal 0 | IN_PROGRESS | pending | Safety baseline and repository |
| Goal 1 | PENDING | - | Blocked on Goal 0 DoneWhen |
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
- [ ] Create or configure public repository `Emvdy/psh`.
- [x] Add `GPL-3.0-or-later` license and bilingual README files.
- [x] Add contribution guide and security policy.
- [ ] Configure protected GitHub Environment `release`.
- [ ] Add `origin`, push `main`, and verify it is the default branch.
- [x] Locate the exact Parallels VM named `Windows 11`.
- [x] Record ARM64 architecture and Parallels Guest Tools state.
- [x] Create a pre-install snapshot named `psh-preinstall-<timestamp>`.
- [x] Record the pre-install snapshot ID.
- [x] Run read-only guest diagnostics with `prlctl exec --current-user`.
- [x] Review the complete Goal 0 diff for credentials and unrelated files.
- [ ] Commit Goal 0 and record the commit SHA.

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

### DoneWhen Audit

- [ ] Remote accepts pushes.
- [ ] `main` is the default branch.
- [x] Pre-install snapshot ID is recorded.
- [x] `prlctl exec --current-user` runs read-only diagnostics.

### Remaining Work

All unchecked Goal 0 items remain required. Goal 1 must not start until the
four Goal 0 DoneWhen checks above have direct evidence.
