# Memory investigation — September 16, 2026

## Findings

- The running process (PID 43620) had launched on September 1 at 14:31:40 from the Debug build produced at 14:31:39. Its symbols still included the older Foundation storage scanner. It predated the native scanner fix made later that afternoon.
- The launcher previously built an app and called `open`, which could simply activate an already-running older instance. Building did not reliably deploy the fixes into the running process.
- The screenshot's 956.7 MB was the last sample before the safety pause, not a fresh reading. At investigation time, `vmmap` reported 338.1 MiB current physical footprint and 4.3 GiB lifetime peak. Heap accounting showed 70.6 MiB allocated and 206.6 MiB fragmentation. Without historical allocation stacks, the exact cause of that past peak cannot be established.
- Remaining allocation churn included rebuilding SwiftUI process trees, copying and shifting history arrays, and repeatedly obtaining workspace icons. The system sampler also acquired Mach host-port send rights without balancing their ownership.

## Changes

- Process Tree and Applications now use reusable native outline rows; metric-only updates modify visible cells rather than reconstructing a SwiftUI tree. Stable identities preserve expansion and selection across topology changes.
- Per-process history uses capped ring buffers, and expired history is discarded before resuming sampling.
- Icons share a bounded raster cache; each synchronous sample runs inside an autorelease pool.
- The system sampler releases its host-port send right. Refreshes cannot overlap, and cancelled storage scans remain marked active until the worker exits.
- The self-memory label continues sampling while monitoring is paused. History duration uses the recorded timestamps rather than elapsed wall time since a pause.
- `./run.sh` defaults to Release, requests a normal quit after a successful build, waits for process exit, and launches the exact new app.

## Verification

All 29 tests passed on this Mac, including a 30,000-file storage scan, history wrapping/resume behavior, malformed process ancestry, and 1,000 system samples with unchanged Mach host-port reference count.

The UI regression tests render 4,000 updates per screen with 320 simulated processes, process churn, expansion/collapse, and selection. They enforce a 64 MB post-warm-up peak-growth budget. Values below are decimal MB, measured from physical footprint; warm-up ends at update 1,000.

| Screen | Warm-up | Final | Post-warm-up peak | Peak growth |
| --- | ---: | ---: | ---: | ---: |
| Process Tree | 145.25 MB | 148.05 MB | 149.80 MB | 4.55 MB |
| Applications | 140.51 MB | 153.04 MB | 161.94 MB | 21.43 MB |

The Release app launched at 11:49:12. At 12:03:52, `vmmap -summary` reported **107.4 MiB current footprint and 150.8 MiB lifetime peak**. Manual checks verified tree expansion, child selection and inspector updates, Applications grouping, and navigation back to Ports.

These are bounded regression tests and approximately 15 minutes of live validation, not proof of multi-day stability. The safety limit remains enabled. The original 4.3 GiB peak was not reproduced during the short baseline test, so it should not be attributed conclusively to any one of the fixed allocation paths.
