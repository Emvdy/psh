# Security Policy

## Supported versions

Psh has not released `v0.1.0` yet. There is currently no supported production version or release artifact.

| Version | Supported |
| --- | --- |
| Unreleased development branch | Best effort only |
| `v0.1.0` | Not released |

This policy will be updated when the first release is published. Download links or installers that claim to be an official Psh release before then should be treated as untrusted.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, pull request, discussion, test log, or screenshot.

Use GitHub's private vulnerability reporting flow for this repository: open the repository's **Security** tab, choose **Advisories**, and select **Report a vulnerability**. If that control is unavailable, open a public issue containing only a request for a private maintainer contact channel. Do not include the vulnerability details in that issue.

Include the following in the private report when possible:

- the affected commit, version, edition, architecture, and PowerShell version;
- a concise impact assessment and the conditions required to reproduce it;
- minimal reproduction steps or a proof of concept;
- whether installer, profile, checksum, native-tool, archive, or destructive command behavior is involved; and
- any suggested mitigation.

Redact tokens, passwords, personal paths, private repository data, and other secrets. Do not upload a VM image or user profile containing personal data.

The maintainers will use the private advisory to coordinate validation, remediation, and disclosure. Please allow time for a fix and affected artifact review before publishing details. No response-time or remediation-time guarantee is offered before the first release.

## Security-sensitive areas

Reports are especially useful for issues involving:

- command or argument injection, including any path that could evaluate user input as PowerShell code;
- deletion or mutation outside the explicitly requested path, especially drive-root or home-directory deletion;
- loss or unsafe modification of an existing PowerShell profile;
- checksum, manifest, SBOM, provenance, architecture, or dependency substitution failures;
- unexpected network access during offline installation or Core operation;
- execution-policy, Group Policy, privilege, permanent `PATH`, or telemetry changes; and
- secrets included in source, logs, packages, workflows, or release assets.

Please test only on systems and data you own or are authorized to use. Avoid destructive testing outside an isolated temporary directory.
