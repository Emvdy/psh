# Psh

[简体中文](README.zh-CN.md)

Psh is a planned PowerShell 5.1-compatible command layer that brings a focused set of familiar Bash-style commands to Windows. It targets Windows 10 and 11 on x64 and ARM64, in both Windows PowerShell 5.1 and PowerShell 7.

> [!IMPORTANT]
> Psh is under active development. `v0.1.0` has not been released, and there is currently no supported installer or release package. The interfaces below describe the intended first release, not functionality available from this repository today.

Psh is a command compatibility layer. It is not a Bash interpreter, a general `.sh` runtime, or a POSIX environment.

## Planned v0.1.0 scope

The first release is planned to provide 64 command names:

- Files and search: `pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname stat file tree find fd du df mktemp`
- Text and data: `cat bat head tail grep rg sed awk jq cut tr sort uniq wc tee xargs printf echo base64`
- Environment and processes: `which env printenv export test ps kill pgrep pkill timeout sleep`
- Network and archives: `curl wget tar zip unzip gzip gunzip sha256sum md5sum date whoami hostname clear`

The planned management interface is:

```text
psh version|doctor|capabilities|commands|config|update|rollback|self-test|uninstall
```

`doctor` and `capabilities` are planned to support machine-readable JSON output. Bash-style commands will emit text and use documented, stable exit codes.

### Editions

- **Core** is planned as the default. It will contain no third-party utility executables. `rg`, `fd`, `jq`, and `bat` will use documented PowerShell subsets.
- **Full** will add pinned native builds of ripgrep, fd, jq, and bat. Their complete argument sets will be handled by the corresponding native tools.

Third-party components in Full remain separately licensed aggregate works. Release packages will retain their original licenses and notices.

## Safety and installation design

The `v0.1.0` installers are intended to:

- install for the current user without administrator privileges;
- avoid changing Group Policy, PowerShell execution policy, or the permanent system `PATH`;
- back up existing PowerShell profiles before inserting a marked loader block;
- verify downloaded and offline artifacts with SHA256 checksums;
- provide online and offline Core and Full packages; and
- collect no telemetry.

Installation commands and download links will be documented only after the release artifacts have passed the required Windows x64 CI and Windows 11 ARM64 acceptance testing. Psh will not recommend an `irm | iex` installation path.

See [PLAN.md](PLAN.md) for the authoritative product scope and acceptance gates.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before proposing a change. Please report suspected vulnerabilities according to [SECURITY.md](SECURITY.md), without disclosing sensitive details in a public issue.

## License

Psh-owned source and documentation are licensed under the [GNU General Public License v3.0 or later](LICENSE) (`GPL-3.0-or-later`). Bundled third-party components, when added, will retain their own license texts and notices.
