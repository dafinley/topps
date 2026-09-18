# Mac App Store readiness

Assessed September 16, 2026 against the source tree now tagged `v0.2.0-alpha.1` (original commit `3b97782`; see the [history record](releases.md)).

Status: **not submission-ready**. This is a preparation checklist, not an App Review approval prediction. The current developer build remains unchanged; no signing credentials, entitlements, store records, or uploads have been configured.

## 1. Resolve sandbox compatibility first

The project explicitly sets `ENABLE_APP_SANDBOX = NO` and `CODE_SIGNING_ALLOWED = NO` for both app configurations. Hardened Runtime is enabled, but does not replace App Sandbox. Apple requires sandboxing for Mac App Store apps and identifies terminating other running apps as incompatible with the sandbox. [Apple's sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

- [ ] Create an isolated, signed sandbox compatibility build without disrupting the working developer configuration. Follow [Apple's configuration guidance](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).
- [ ] Measure actual API coverage on supported macOS versions: process enumeration, CPU and footprint, ancestry, command arguments, executable paths, working directories, and TCP/UDP ownership. Test self, same-user unrelated processes, and protected processes. Current unsandboxed tests do **not** establish sandbox compatibility.
- [ ] Record permitted, denied, and partial results separately. A denied socket inspection must not appear as proof that a port is unused.
- [ ] Decide how the Store edition handles process-control actions. `ProcessSignalService` currently sends `SIGTERM`/`SIGKILL` to unrelated same-user processes; those controls cannot be assumed to carry over.
- [ ] Test the explicit `vmmap`, `sample`, and `lsof` actions under the sandbox, including subprocess access, cancellation, timeouts, and bounded output. Remove or redesign unavailable actions rather than leave nonfunctional buttons.

Relevant code: `Topps/CProcessBridge/CProcessBridge.c`, `Topps/Services/Services.swift`, and `Topps/Services/DiscoveryServices.swift`. Exact inspection coverage remains an engineering question, not a confirmed blanket prohibition.

The external `llmfit` integration is another design gate: it currently discovers and executes a separately installed tool and suggests Homebrew installation. Audit a bundled, sandbox-compatible implementation and its licenses, or explicitly omit the feature from the Store edition. Apple's requirements for self-contained packaging and restrictions on additional executable functionality make the current integration a review risk; this assessment does not establish its eligibility. Do not introduce a privileged helper or external installer to bypass the sandbox. [App Review Guidelines, 2.4.5 and 2.5.2](https://developer.apple.com/app-store/review/guidelines/)

## 2. Make file access and privacy submission-ready

- [ ] Replace implicit Home/common-location access with user-granted folder access. Storage Growth currently remembers a path string, not a persistent access grant.
- [ ] Implement security-scoped bookmarks for rescans after relaunch, balanced access lifetimes, stale bookmark recovery, and clear denied/revoked/moved-folder states. Request only necessary access; storage measurement does not need write permission. [Sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [ ] Keep history and caches in the app container. Plan explicit, user-authorized import of existing developer-build storage history; do not assume the old Application Support path remains accessible.
- [ ] Audit required-reason APIs, including the existing `UserDefaults` and file-timestamp usage. Add a bundled `PrivacyInfo.xcprivacy` with reasons that match the shipping implementation; none exists today. Review any bundled dependencies too. [Required-reason API declarations](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [ ] Publish a privacy policy and complete App Store Connect privacy responses for the actual shipping app and integrations. Core monitoring is local with no telemetry, but that alone does not audit third-party behavior. Apple requires a privacy-policy URL for all apps. [App privacy setup](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [ ] Keep exports user-selected and warn that diagnostics can contain sensitive commands, paths, and endpoints. Verify save panels in the sandbox.

## 3. Finish release engineering and product quality

- [ ] Confirm Apple Developer team, final app name/bundle identifier, copyright owner, and supported architectures. The current identifier is `com.dafinley.Topps`, version `1.0`, build `1`, minimum macOS `14.0`.
- [ ] Configure App Store signing/provisioning and a repeatable archive/validation workflow. `run.sh` is a local, unsigned, active-architecture development launcher, not a distribution pipeline. Recheck Apple's SDK/submission requirements when submitting. [Distribution preparation](https://developer.apple.com/documentation/Xcode/preparing-your-app-for-distribution)
- [ ] Add a real app icon/asset catalog. The build setting names `AppIcon`, but the repository contains no corresponding asset resources.
- [ ] Wire up or remove currently inert settings: exact-byte display, memory/CPU attention thresholds, and continuing collection while hidden. Their stored values currently appear only in the settings UI.
- [ ] Verify opt-in `SMAppService` launch-at-login registration and removal in the signed build; preserve consent.
- [ ] Prepare accurate screenshots, description, support/privacy URLs, review notes, dependency notices, and App Store Connect metadata. Complete age-rating and encryption/export questions from the shipping implementation, not guesses.
- [ ] Run signed sandbox tests, archive validation, and TestFlight testing. Cover accessibility, light/dark appearance, permission failures, IPv4/IPv6 listeners, sleep/wake, process churn, large directories, cancellation, and repeated navigation.
- [ ] Run long-session memory/CPU/energy tests. The current development build passed 39 tests, including two 4,000-update UI memory regressions, and a Release build. This does not establish multi-day stability, sandbox functionality, or Store readiness.

## Recommended next step

Start with the sandbox compatibility prototype and a capability report. Then agree on the App Store feature set and whether to maintain separate developer and Store configurations. That product decision should precede removing functionality or changing the default build. Signing, artwork, and store metadata can follow once the intended app is demonstrably viable inside the sandbox.
