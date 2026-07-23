# Topps

Topps is a native macOS process explorer for developers. It combines the immediacy of `top` with application grouping, process ancestry, physical-footprint memory accounting, short histories, safe termination controls, and on-demand diagnostics.

Everything stays on the Mac. Topps has no network code, cloud service, analytics, telemetry, or third-party dependency.

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
- Explicit one-shot `vmmap`, `sample`, and `lsof` diagnostics with searchable, copyable, saveable output
- Optional menu-bar status, launch at login, CSV/JSON export, pinning, and memory-growth watches

The included mock sample models the motivating case: a detached Python process where RSS is under 1 GB but physical footprint is roughly 14 GB, alongside Chrome helpers, Codex, a fast-growing Node process, and a protected process.

## Screenshots

Add release screenshots here after selecting representative light- and dark-mode process samples. The Xcode canvas includes a realistic mock-data preview named **Topps — realistic process sample**.

## Requirements

- macOS 14 Sonoma or newer
- Xcode 16 or newer (built and tested with Xcode 26.4 / Swift 6.3)
- No root privileges are needed for normal operation

## Build and run

Open [Topps.xcodeproj](Topps.xcodeproj) in Xcode, select the **Topps** scheme and **My Mac**, then press **Run**.

Command line:

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
- `proc_pidinfo(PROC_PIDLISTFDS)` and `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` for selected-process network endpoints
- `sysctl(KERN_PROCARGS2)` for command arguments when permitted
- Mach host VM and CPU statistics for the system summary
- `sysctl(vm.swapusage)` for swap usage

`DarwinProcessDataProvider` is an actor, so collection occurs away from the main actor. The UI receives one consolidated sample. Static metadata is cached by stable identity (PID plus start time), and working directories are fetched only for the selected process. The `ProcessDataProvider` protocol permits deterministic previews and tests through `MockProcessDataProvider`.

CPU percentage is calculated from the difference between two cumulative CPU-time samples divided by elapsed wall-clock time. It is not the cumulative CPU time. A process can exceed 100% when it uses more than one logical CPU.

History is an in-memory ring buffer capped at 300 points per visible process at the default one-second interval. Exited-process history receives a short grace period and is then discarded. No history database is created.

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
- Launch at Login uses `SMAppService`, and can be disabled at any time in Settings

## Known limitations

- macOS intentionally denies details for protected and other-user processes
- Per-process compressed-memory attribution is not consistently available through the public APIs used here
- Rosetta status is shown only when it can be determined safely; otherwise it is unavailable
- Application grouping is heuristic for reparented and detached processes
- Working directories can disappear or become unreadable between selection and inspection
- A process may exit between enumeration, inspection, signaling, or diagnostics; Topps treats this as a normal race
- Memory pressure is a compact local classification derived from host memory ratios; it is context, not Apple's private pressure-level implementation
- Attention and sustained-growth labels prioritize investigation. They do not diagnose malware or memory leaks
