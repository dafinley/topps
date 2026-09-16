# Topps

Topps is a native macOS process explorer for developers. It combines the immediacy of `top` with application grouping, process ancestry, physical-footprint memory accounting, short histories, port ownership, safe termination controls, and on-demand diagnostics.

Core monitoring stays on the Mac. Topps has no cloud service, analytics, or telemetry. The optional LLM Fit screen invokes a separately installed `llmfit` executable on demand; it is not bundled and does not remain running.

## What it shows

- A live system header for used/available/wired/compressed memory, swap, CPU, process count, running processes, and threads
- A dense process table searchable by name, PID, command, path, user, and bundle identifier
- Physical footprint as the primary Memory value, with resident memory retained for comparison
- Per-sample memory change, normalized growth per minute, CPU averages, and five-minute in-memory histories
- Application groups, including helper processes related through bundle metadata and ancestry
- A PPID-based process tree with cycle protection
- A Memory Investigation view for largest, fastest-growing, and significant detached processes
- A right-side inspector for the full command, executable, working directory, start/runtime, I/O, ancestry, children, accessibility, and sparklines
- Native per-process TCP/UDP endpoint inspection showing listening ports, established peers, protocol, state, and file descriptor
- A system-wide Ports explorer mapping TCP listeners, bound UDP ports, and active connections to process name, PID, user, and command
- An on-demand Storage Growth explorer for comparing folder snapshots, surfacing growing paths, caches, dependency trees, build output, large files, and conservative external-SSD/cloud candidates
- An optional LLM Fit screen that uses [llmfit](https://github.com/AlexsJones/llmfit) to rank local models by hardware fit, speed, quality, context, runtime, quantization, and use case
- Explicit one-shot `vmmap`, `sample`, and `lsof` diagnostics with searchable, copyable, saveable output
- Optional menu-bar status, launch at login, CSV/JSON export, pinning, and memory-growth watches

The included mock sample models the motivating case: a detached Python process where RSS is under 1 GB but physical footprint is roughly 14 GB, alongside Chrome helpers, Codex, a fast-growing Node process, and a protected process.

## Screenshots

Add release screenshots here after selecting representative light- and dark-mode process samples. The Xcode canvas includes a realistic mock-data preview named **Topps — realistic process sample**.

## Requirements

- macOS 14 Sonoma or newer
- Xcode 16 or newer (built and tested with Xcode 26.4 / Swift 6.3)
- No root privileges are needed for normal operation
- Optional: `brew install llmfit` to enable the LLM Fit analysis screen

## Build and run

From the repository root, one command builds an optimized Release app and restarts Topps with that build:

```sh
./run.sh
```

The script keeps Derived Data under `.build/DerivedData`, which is ignored by Git. After a successful build it requests a normal quit of any running Topps instance, waits for it to exit, and opens the exact newly built app. This prevents an old instance from silently staying active after an update. Use `TOPPS_CONFIGURATION=Debug ./run.sh` when debugging.

Open [Topps.xcodeproj](Topps.xcodeproj) in Xcode, select the **Topps** scheme and **My Mac**, then press **Run**.

Equivalent manual command:

```sh
xcodebuild \
  -project Topps.xcodeproj \
  -scheme Topps \
  -destination 'platform=macOS' \
  build
```

Run tests:

```sh
xcodebuild \
  -project Topps.xcodeproj \
  -scheme Topps \
  -destination 'platform=macOS' \
  test
```

Create a release build:

```sh
xcodebuild \
  -project Topps.xcodeproj \
  -scheme Topps \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

For distribution, choose a Developer ID signing team and archive in Xcode. The checked-in project disables code signing for reproducible local command-line builds.

## How sampling works

The process list never depends on continuously launching `top`, `ps`, `vmmap`, or `lsof`. A small C bridge uses public Darwin interfaces:

- `proc_listallpids`, `proc_pidinfo`, `proc_pidpath`, and `proc_pid_rusage` for enumeration and process metrics
- `proc_pidinfo(PROC_PIDLISTFDS)` and `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` for selected-process endpoints and on-demand system-wide port snapshots
- `sysctl(KERN_PROCARGS2)` for command arguments when permitted
- Mach host VM and CPU statistics for the system summary
- `sysctl(vm.swapusage)` for swap usage

`DarwinProcessDataProvider` is an actor, so collection occurs away from the main actor. The UI receives one consolidated sample. Static metadata is cached by stable identity (PID plus start time), and working directories are fetched only for the selected process. The `ProcessDataProvider` protocol permits deterministic previews and tests through `MockProcessDataProvider`.

CPU percentage is calculated from the difference between two cumulative CPU-time samples divided by elapsed wall-clock time. It is not the cumulative CPU time. A process can exceed 100% when it uses more than one logical CPU.

History uses in-place circular buffers capped at 300 points per process at the default one-second interval. Sampling overwrites old slots instead of copying and shifting every process's history array. Processes not seen for 60 seconds are discarded before ingestion, including after a long pause. No process-history database is created.

The Ports explorer is deliberately not part of the live sampling loop. Entering it starts one background scan if no snapshot exists or the last successful scan is at least **10 seconds** old. **Scan Now** bypasses that age check. Each scan discovers current processes independently, even while monitoring is paused or frozen; it does not reuse the paused process list or advance the CPU sampling baselines. Socket inspection is attempted even if unrelated task metrics are unavailable. Port numbers are displayed as plain identifiers (for example, `3100`). Protected processes may still deny socket access.

LLM Fit's first analysis is manual. Returning to the page refreshes an existing analysis when it is at least **5 minutes** old and `llmfit` is installed. Topps runs `llmfit --json system` followed by a filtered `llmfit recommend --json`, reads the JSON, and lets the command exit. Automatic retries are also spaced at least five minutes apart if analysis fails; **Analyze This Mac** can retry immediately.

Both pages keep cached results and filters visible during refresh, show an updated timestamp or refreshing indicator, and allow only one scan per feature at a time. Navigation does not add a polling timer or start work for hidden pages. A memory-safety pause suppresses automatic page-entry work; explicit scan buttons remain available. Processes, Applications, Process Tree, and Memory Investigation continue sharing the existing sampler. Entering Storage Growth only loads saved history and never starts a filesystem walk.

Storage analysis is also deliberately on-demand. Choose a focused folder—or Home for a broad baseline—and capture a snapshot. A later scan of the same root compares exact retained paths and highlights what grew. Topps measures allocated disk space as well as logical file size, never follows interior symbolic links, and does not descend into a different mounted volume. The filesystem walk uses native post-order traversal and fixed-capacity heaps for the largest folders, recognized cleanup opportunities, and files of at least 100 MB. Only the best 1,400 candidates cross into Swift. The native traversal also holds directory entries while walking, so exceptionally wide directories still have a temporary cost; the scan guard remains active.

Storage snapshots are saved locally at `~/Library/Application Support/Topps/storage-history.json`, with at most 24 snapshots per root and 120 overall. Folder rows are hierarchical and overlap, so their values must not be added together. Recommendations are review prompts only: Topps can reveal a path in Finder or copy it, but never deletes, moves, uploads, or archives data.

The main process list uses a reusable `NSTableView`; Process Tree and Applications use `NSOutlineView` with stable items. Metric changes update existing visible cells directly; topology changes reload the outline while preserving expansion and selection. Tied sort values have a stable PID order to avoid needless reloads. All process icons share a cost-limited cache of small raster images. Background sampling drains Foundation autoreleases every tick and releases its Mach host-port reference.

As a final guardrail, Topps monitors its own physical footprint and pauses sampling with a warning if it reaches 1 GB. Storage scans additionally stop at a lower guardrail and never save a partial snapshot. Cancelling a scan keeps it marked active until its worker exits so scans cannot overlap. The sidebar measures Topps's current footprint independently every five seconds, even while the process list is paused; paused process rows remain historical readings.

Memory regression coverage includes 4,000 rendered updates each for Process Tree and Applications (320 processes, process churn, expansion, collapse, and selection), with a post-warm-up footprint-growth limit, plus a 30,000-file storage scan. These bounded tests cannot prove the absence of every possible long-session leak; they exercise the actual live UI as well as the scanner.

## Why App Sandbox is disabled

The application target has App Sandbox disabled. Sandbox process isolation prevents a system-wide developer utility from reading many process records and from signaling user-owned processes. Topps is not designed for the Mac App Store.

Disabling App Sandbox does not grant root access. Standard Unix permissions and macOS protections still apply. A protected or other-user process may expose only its PID and basic BSD record; unavailable metrics are displayed as **Unavailable** rather than inferred.

## Memory accounting

Topps prefers `ri_phys_footprint`, the same broad physical-footprint concept surfaced by Apple memory tools, and falls back to resident size. Physical footprint can be dramatically larger than RSS for workloads backed by graphics allocations, compressed pages, or other accounted resources.

Adding all process Memory values will not equal system used memory. System totals also include kernel and wired allocations, shared pages, compressed memory, file cache, shared frameworks, and categories with different ownership/accounting rules. Shared resources may be charged differently at the process and host levels.

The purple system **Memory** value follows `top`'s `PhysMem used` convention: physical memory minus currently unused/free pages. **Available** is intentionally broader and also includes inactive pages that macOS can reclaim. Available memory therefore overlaps the used accounting category. The physical-memory breakdown separates wired, compressor-resident, active, inactive/cache, residual system/other, and unused page states; its info popover also reports purgeable memory and swap without double-counting them as bar segments.

Process rows deliberately distinguish macOS **physical footprint** from **resident pages**. Footprint is a per-process ledger charge and may include compressed, swapped, shared, graphics, and device-backed allocations. It is not a count of unique DRAM pages, can exceed installed physical memory, and cannot be summed or compared directly with the system PhysMem-used card.

Compressed-memory accounting is especially unintuitive: compressed pages remain used physical RAM, may be attributed differently from a process's current resident pages, and can coexist with swap. High compressed memory is useful context, not proof that any one process is responsible.

## Grouping

The libproc enumeration remains the source of truth. Grouping uses bundle identifiers, `.app` paths, parent ancestry, process-group information, and executable families. Helper processes such as Chrome renderers are walked toward their owning parent application. Command-line workloads without bundle metadata fall back to a canonical executable or recognizable runtime family such as Python, Node.js, Bun, or Docker. Every stable process identity is placed in one bucket, preventing double counting.

Grouping is heuristic. A detached child, reparented daemon, deliberately changed process group, or helper with an unrelated launcher may appear separately.

## Diagnostics and process control

Advanced diagnostics are opt-in. A click launches an explicit executable URL with an argument array—never a shell string and never `sudo`:

- `/usr/bin/vmmap -summary PID`
- `/usr/bin/sample PID 5`
- `/usr/sbin/lsof -p PID`
- `/usr/sbin/lsof -Pan -p PID -i`

SIGTERM is the primary termination action. SIGKILL is secondary and requires confirmation. The dialog repeats the process name, PID, command, current memory, and child count. Topps only enables signals for a process owned by the current user and never terminates anything automatically.

## Security and privacy

- All collection, filtering, history, diagnostics, exports, and settings are local
- No process data is uploaded
- No telemetry or analytics exists
- Exports are written only to the location chosen in the save panel
- Diagnostics may contain sensitive commands, paths, filenames, or network endpoints; review output before sharing it
- Storage history contains local paths and aggregate sizes, remains on this Mac, and is never uploaded. Storage recommendations never perform an automatic delete, move, or cloud transfer
- The first LLM Fit analysis requires an explicit click; existing analyses may refresh when returning to the page. Topps does not install `llmfit`; consult that project's own privacy and network behavior before enabling optional integrations
- Launch at Login uses `SMAppService`, and can be disabled at any time in Settings

## Known limitations

- macOS intentionally denies details for protected and other-user processes
- Per-process compressed-memory attribution is not consistently available through the public APIs used here
- Rosetta status is shown only when it can be determined safely; otherwise it is unavailable
- Application grouping is heuristic for reparented and detached processes
- Working directories can disappear or become unreadable between selection and inspection
- A process may exit between enumeration, inspection, signaling, or diagnostics; Topps treats this as a normal race
- Protected and other-user sockets may be absent from a system-wide port snapshot because macOS denied inspection
- Storage scans can omit unreadable paths. APFS clones, hard links, sparse files, purgeable data, and cloud-provider placeholders can make allocated and logical sizes differ from Finder or `du`
- Storage growth is exact only for paths retained in both snapshots; renamed or moved items appear as a disappearance and a new path
- Memory pressure is a compact local classification derived from host memory ratios; it is context, not Apple's private pressure-level implementation
- Attention and sustained-growth labels prioritize investigation. They do not diagnose malware or memory leaks
