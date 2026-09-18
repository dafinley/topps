# Contributing to Topps

Small, well-explained changes are easiest to review. Start with the [README](README.md) and [development guide](docs/development.md).

## Before you start

- Search existing issues before opening another. For a substantial feature, describe the problem and proposed scope before implementing it.
- Keep bug reports reproducible: macOS version, Apple Silicon/Intel, commit or release tag, active page, and the shortest steps that show the problem.
- Redact commands, paths, endpoints, and exports. Use the [security reporting process](SECURITY.md) for vulnerabilities, not a public reproduction.
- Be respectful and focus review feedback on the work. No personal attacks or sharing someone else's private information.

**Licensing is still pending.** No open-source license has been adopted. Coordinate with the repository owner on contribution/reuse terms before submitting substantial work; this guide does not grant new rights. See [GitHub's licensing guidance](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/adding-a-license-to-a-repository).

## Working on a change

1. Branch from current `main`; use a descriptive name such as `fix/port-owner-refresh` or `docs/memory-guide`.
2. Keep each pull request focused. Avoid unrelated formatting, dependency updates, generated build products, or local Xcode state.
3. Follow the surrounding Swift/C style. Put expensive work off the main actor, keep retained state bounded, and handle denied permissions and process exits as normal outcomes.
4. Add a regression test for changed behavior. UI changes need a screenshot; memory changes need measurements and a stated observation period, not just a claim that usage is lower.
5. Run the relevant tests and a Release build using the commands in the development guide. Docs-only changes need link, image, and command checks; say explicitly when runtime tests weren't rerun.
6. Update user-facing docs and the **Unreleased** section of [CHANGELOG.md](CHANGELOG.md) when behavior changes. Small editorial corrections don't need release notes.

## Commit messages and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) with a short, specific subject:

```text
fix(ports): refresh owners after a paused sample
feat(storage): explain unreadable paths
docs: clarify footprint versus resident memory
test(history): cover PID reuse
```

Explain the reason and trade-offs in the body when they aren't obvious. Release commits are reserved for selected milestones; routine commits don't each need a release tag.

In the pull request, state what changed, how you checked it, and what remains uncertain. Include a related issue if there is one. Do not commit signing keys, credentials, raw private process exports, or screenshots containing secrets.

## Review and release boundaries

Avoid rewriting shared history or moving an existing release tag. Maintainers review changes and handle releases using the [release checklist](docs/releases.md). CI and branch protection are not configured by these documents; report checks actually run instead of assuming automation covers them.
