# Security

## Reporting a vulnerability

Please don't disclose vulnerabilities, credentials, or private process data in public issues.

If GitHub's **Security → Report a vulnerability** option is available for this repository, use it. That option requires a repository setting; this file does not enable it. Otherwise, use an existing private maintainer contact, or open an issue asking for a private security contact **without including exploit details or sensitive data**. No dedicated security email address is published yet. [GitHub's private reporting guidance](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately)

Privately include the affected commit/tag, macOS version, impact, a minimal reproduction, and any suggested mitigation. Use synthetic process names and paths where possible.

## Support status

Topps is an alpha project. Reports should identify whether the issue reproduces on current `main`; there is no promised response time, security support window, or maintained backport branch. Older milestone tags are historical snapshots, not separate supported products.

## Boundaries worth knowing

- Core monitoring is local, but commands, paths, network endpoints, screenshots, and exports may contain sensitive information.
- The current app runs without App Sandbox. macOS permissions and protections still apply; unavailable information must not be interpreted as proof of absence.
- Storage recommendations are advisory. Topps does not automatically delete, move, or upload files.
- Process termination is explicit and can lose unsaved work. Never test destructive scenarios against unrelated processes or data.
- Optional external tools have their own behavior and supply-chain risks. Do not assume their privacy properties are the same as Topps's.
- Release tags and GitHub source archives are not notarized app binaries. See [distribution](docs/distribution.md) before installing or sharing builds.
