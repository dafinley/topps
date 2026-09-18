# Sharing Topps

[Back to README](../README.md)

## Today

The repository supports local source builds with `./run.sh`. It does **not** yet include a team-beta packaging command, a signed/notarized download, or an automatic updater. A successful local build is not a release check.

## A small team beta

The simplest planned delivery is a ZIP shared privately with the team—no website or custom installer needed.

Before sharing:

1. Confirm testers use macOS 14 or newer and build for their architectures. `run.sh` builds only for the current Mac; don't assume its output also supports Intel.
2. Build Release, assign a distinguishable version/build, and run the tests.
3. Sign with a **Developer ID Application** certificate and Hardened Runtime, submit for notarization, attach the accepted ticket to the app, then make the final ZIP. Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) explains the sequence; a ZIP itself can't have a ticket stapled to it.
4. Test the actual downloaded ZIP on another Mac, including first launch, process/port inspection, and a focused storage scan.
5. Share the ZIP with short release notes and known issues. Testers unzip, move `Topps.app` to Applications, and open it. For updates, quit Topps and replace the app with the new build.

Developer ID distribution doesn't require testers to install Xcode or join a developer team. Signing/notarization needs the publisher's Apple Developer setup. See [Apple's Developer ID guide](https://developer.apple.com/developer-id/).

An unsigned/unnotarized internal build may trigger Gatekeeper warnings, and managed Macs may block it. Don't ask teammates to disable Gatekeeper or strip quarantine metadata. Prefer preparing a verified release over sharing an unexplained security workaround.

## Public downloads later

The same signed, notarized app can be delivered through a website, with a DMG and updater added when useful. Hosting, updates, release notes, and support would be our responsibility. App Sandbox is optional for direct distribution; normal macOS privacy and process protections still apply. [Apple's distribution comparison](https://developer.apple.com/macos/distribution/)

The Mac App Store is a separate path, not a prerequisite. It requires sandboxing and a capability assessment before promising the current feature set. The [App Store readiness assessment](app-store-readiness.md) records those restrictions and the outstanding release work.
