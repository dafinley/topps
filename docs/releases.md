# Releases and repository conventions

[README](../README.md) · [Changelog](../CHANGELOG.md) · [Distribution](distribution.md)

## What a release means here

Current tags mark **source-only alpha milestones**. They do not imply a signed installer, App Store approval, multi-day stability, or a stable public API/file format. Use `vMAJOR.MINOR.PATCH-alpha.N` for preview milestones and annotated tags containing human-readable release notes. The format follows [Semantic Versioning](https://semver.org/); keep versions below 1.0 while compatibility expectations are still being established.

Git milestones are separate from the Xcode bundle version. The checked-in project still reports marketing version `1.0` / build `1`; no build settings were changed during the history/documentation cleanup. Before distributing binaries, deliberately assign and record their bundle version/build alongside the source tag.

Routine work uses focused Conventional Commits. Reserve release commits/tags for selected milestones. Keep [CHANGELOG.md](../CHANGELOG.md) readable: what changed for users, relevant fixes, verification, and known limits—not a dump of commit subjects. This approach is informed by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Cutting the next release

1. Start from a reviewed, clean working tree. Check remote branches and tags before choosing an unused version.
2. Move relevant Unreleased notes into a dated changelog section. Identify docs-only releases and source-only artifacts explicitly.
3. Verify the scope. For app changes, run tests, build Release, and exercise affected workflows. For docs-only changes, check links, examples, and image paths and confirm the app tree is unchanged. Record limitations honestly.
4. Commit with a specific subject, such as `chore(release): v0.2.0-alpha.5 - <milestone>`, and release notes in the body.
5. Create an **annotated** tag on that exact commit with the same notes. Inspect the tag and its target before sharing. Never move an existing published tag; release a new version for corrections.
6. Push only the intended branch and named tags after approval. Do not use a blanket tag push that might include backup or unrelated refs, and do not force-push shared history as part of routine releases.
7. If publishing a GitHub Release, mark alpha versions as prereleases and copy the matching changelog notes. A Git tag is not itself a published GitHub Release. Only attach binaries after the separate signing/notarization and clean-install checks in the distribution guide.

No CI workflow, automatic publisher, branch protection, or private vulnerability-reporting setting is enabled by these docs. Those are separate setup decisions; don't display badges or claim checks that aren't running.

## September 18, 2026 history cleanup

The remote `main` pointed to `9dd7f1d` when checked. At the owner's explicit request, all four original commits, including that published baseline, were reworded **locally**. Their authors and author dates were preserved, and each replacement has exactly the same Git tree as its original. The remote branch has not been changed.

| Original commit | Replacement | Source milestone |
| --- | --- | --- |
| `9dd7f1d` | `30ba9fb` | `v0.1.0-alpha.1` |
| `3b97782` | `52e7773` | `v0.2.0-alpha.1` |
| `e1db7e2` | `b357c76` | `v0.2.0-alpha.2` |
| `f6e0f81` | `7d0fa47` | `v0.2.0-alpha.3` |

`v0.2.0-alpha.4` adds repository documentation and contribution templates only. All milestone tags were created retroactively on September 18, not backdated. Nothing was pushed or published during this cleanup.

Because the root commit changed, this local history does not fast-forward the existing remote `main`. Publishing it requires a separately approved, coordinated history update: recheck the remote for collaborators' work, preserve its current tip, and use an explicit expected-tip lease if replacing the branch is approved. A normal push will reject the divergence; do not automatically retry with force. Collaborators with the old history should coordinate before updating their checkouts.

### Local recovery copies

The original history remains reachable through branch `codex/backup-before-release-history-2026-09-18`. A complete, verified bundle was also saved locally at `.build/history-backups/pre-release-history-2026-09-18.bundle`; it is ignored by Git and is not part of a checkout received by collaborators.

Inspect without changing the current checkout:

```sh
git log --oneline codex/backup-before-release-history-2026-09-18
git bundle verify .build/history-backups/pre-release-history-2026-09-18.bundle
git diff codex/backup-before-release-history-2026-09-18 main -- Topps ToppsTests Topps.xcodeproj run.sh
```

The final command was empty at cleanup completion. To investigate the originals later, create a separate branch or clone from the bundle; don't reset an active working tree. Copy the bundle elsewhere before clearing `.build` if you want an additional recovery copy.
