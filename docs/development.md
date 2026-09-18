# Building and working on Topps

[Back to README](../README.md)

Topps uses SwiftUI for the window and inspector, AppKit for reusable process tables/outlines, and a small C bridge for Darwin process and filesystem APIs. There is no Rust service or web frontend to run.

## Local build

Use macOS 14 or newer and full Xcode. Xcode 26.4 is the verified toolchain; older versions aren't currently validated. Open Xcode once to complete its setup.

From the repository root:

```sh
./run.sh
```

This builds **Release**, requests a normal quit of existing Topps instances, waits for them to exit, and opens the exact new app. It doesn't force-kill a stuck instance. If quitting times out, quit Topps yourself and rerun.

Build products stay in the ignored `.build/DerivedData` directory. The app is at `.build/DerivedData/Build/Products/Release/Topps.app`. Local builds disable distribution signing and target the current Mac's architecture.

For debugging:

```sh
TOPPS_CONFIGURATION=Debug ./run.sh
```

Or open `Topps.xcodeproj`, choose the **Topps** scheme and **My Mac**, then Run. The Xcode canvas includes a mock-data preview; local monitoring itself needs neither `llmfit` nor root privileges.

If the command line reports that Xcode is missing, check `xcode-select -p` and `xcodebuild -version`. Select your full Xcode installation under **Xcode → Settings → Locations → Command Line Tools**. The standalone Command Line Tools installation isn't enough for this app project.

## Tests and build-only checks

```sh
xcodebuild \
  -project Topps.xcodeproj \
  -scheme Topps \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  test
```

The suite includes history wrapping, PID reuse, ancestry cycles, memory accounting, socket ownership/IPv6, refresh thresholds, storage comparisons, and a 30,000-file storage scan. Two UI memory tests each render 4,000 updates with 320 simulated processes, churn, selection, and expansion/collapse. Expect those to take longer than ordinary unit tests.

Build Release without restarting the running app:

```sh
xcodebuild \
  -project Topps.xcodeproj \
  -scheme Topps \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build
```

Building alone does not replace the app already running. Use `./run.sh` when checking a fix interactively. None of these commands produces a signed distribution archive.

## Where to look

- [`ToppsStore.swift`](../Topps/ViewModels/ToppsStore.swift): shared state, sampling lifecycle, selection, scans, and exports.
- [`DarwinProcessDataProvider.swift`](../Topps/Services/DarwinProcessDataProvider.swift): off-main-actor sampling, metadata caches, and mock data.
- [`CProcessBridge.c`](../Topps/CProcessBridge/CProcessBridge.c): native process/socket reads and storage traversal.
- [`ProcessTableView.swift`](../Topps/Views/ProcessTableView.swift): reusable `NSTableView` and `NSOutlineView` implementations.
- [`DiscoveryServices.swift`](../Topps/Services/DiscoveryServices.swift): fresh-process port discovery, page freshness policy, and the `llmfit` adapter.
- [`StorageServices.swift`](../Topps/Services/StorageServices.swift): bounded findings, local snapshots, and conservative recommendations.
- [`ToppsTests.swift`](../ToppsTests/ToppsTests.swift): functional and memory regression tests.

## Sampling and memory design

The live loop reads `libproc`, `sysctl`, and Mach host statistics; it doesn't repeatedly shell out to `top`, `ps`, or `lsof`. CPU is the change in cumulative CPU time divided by sample duration. Stable process identities pair PID with start time so PID reuse doesn't inherit another process's history.

Histories use 300-point circular buffers. Processes absent for 60 seconds are pruned before ingestion, including after a pause. Sampling drains Foundation autoreleases and balances Mach host-port references. Icons share a cost-limited raster cache. Native rows update visible metrics in place; topology changes preserve expansion and selection where possible.

Ports and LLM Fit allow one scan each at a time. Entry refresh thresholds are 10 seconds and five minutes, respectively; LLM Fit requires an existing analysis and uses a retry cooldown. No page-entry polling timer is created. Storage only scans on explicit request. Cached results remain visible during refresh.

Storage uses post-order native traversal and fixed-capacity candidate heaps. At most 1,400 findings cross into Swift; individual large-file candidates start at 100 MB. Traversal can still allocate temporary directory entries, so exceptionally wide trees aren't constant-memory operations. Cancellation stays active until the worker exits, preventing overlapping scans.

The app's sampling guard trips at 1,000,000,000 bytes of physical footprint. Storage checks a lower 700,000,000-byte threshold and never saves partial scans. These are safety limits, not target memory budgets or guarantees against overshoot. Keep the guards enabled while testing.

Read the [dated memory investigation](memory-validation-2026-09-16.md) for measurements and their limits. Screenshots in the README show real usage, not a promised memory ceiling. Bounded tests do not prove multi-day stability.

## Report a useful bug

Include macOS version, Apple Silicon/Intel, the commit/build, active page, refresh interval, and the actions leading up to the issue. For memory growth, include runtime and whether a storage scan or diagnostic was active. For missing ports, include TCP/UDP, IPv4/IPv6, and the snapshot time. Redact private commands, paths, and endpoints before sharing screenshots or exports.

The current app is unsandboxed but still subject to macOS permissions. See [distribution](distribution.md) before changing signing or entitlement settings.
