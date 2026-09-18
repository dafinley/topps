# Changelog

Notable changes, newest first. Tags identify **alpha source snapshots**, not signed/notarized app downloads. Historical milestones were tagged on September 18, 2026; their dates below record when the work was originally committed, not a previous public launch.

## Unreleased

No changes recorded yet.

## v0.2.0-alpha.4 — 2026-09-18

### Project maintenance

- Added contribution guidelines, bug/feature templates, a pull request checklist, and security-reporting guidance.
- Added this changelog and a documented release/verification process.
- Organized all four original commits into release milestones with annotated tags and release notes. Preserved every file tree and original author information; retained the original history in a backup branch and verified Git bundle. The rewrite is local only.
- No application code, tests, project/build settings, launcher, or screenshot content changed. Licensing remains undecided.

## v0.2.0-alpha.3 — 2026-09-18

### Documentation

- Reworked the README around a quick start and practical investigation workflows.
- Added real process-explorer and menu-bar screenshots.
- Added user, development, and private-team distribution guides, including memory accounting and missing-port troubleshooting.
- Release build passed; local documentation links and shell examples were checked. No application behavior changed.

## v0.2.0-alpha.2 — 2026-09-16

### Documentation

- Added an App Store readiness assessment: sandbox compatibility, process control, folder access, privacy, signing, and release quality.
- Clarified that local builds aren't submission archives. No entitlements, signing settings, or application code changed.

## v0.2.0-alpha.1 — 2026-09-16

### Added

- Storage Growth: local snapshots, exact-path growth comparisons, cache/dependency/build-output leads, and move/archive suggestions.
- Ports: system-wide TCP/UDP ownership with searchable process and endpoint details.
- Optional LLM Fit integration for hardware-based model recommendations.
- Page-entry refresh for stale Ports and existing LLM Fit results, with non-overlapping scans and cached results during refresh.

### Fixed

- Reused native process rows, bounded history/icon caches, drained sampling autoreleases, and balanced Mach host-port ownership to reduce memory growth and allocation churn.
- Discovered current port owners independently of paused monitoring; included IPv6 coverage and ungrouped port-number formatting.
- Made `./run.sh` launch the freshly built Release app instead of silently reactivating an older instance.
- Kept Topps's own footprint reading current while monitoring is paused; cancelled storage scans cannot overlap replacements or save partial results.

### Validation and limits

- 39 tests and a Release build passed on the development Mac, including two 4,000-update UI memory regressions and a 30,000-file storage scan.
- Bounded tests do not establish multi-day stability. The [memory investigation](docs/memory-validation-2026-09-16.md) records the earlier investigation phase and its measurements.
- Protected processes/files can remain inaccessible. Storage suggestions never delete or move files. LLM Fit requires a separately installed tool.

## v0.1.0-alpha.1 — 2026-07-23

### Initial preview

- Native macOS process table, application grouping, process tree, memory investigation, and menu-bar summary.
- Process inspector with ancestry, commands, history, and explicit diagnostics.
- Local CSV/JSON exports, user-owned process controls, mock data, and initial tests.
- Reworded the original preview commit with release notes while preserving its exact source tree. This preview predates Storage Growth and the system-wide Ports/LLM Fit pages.
