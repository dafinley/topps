# Using Topps

[Back to README](../README.md)

## Find a process worth investigating

Start in **Processes**. Sort by **Footprint**, **CPU**, or **Growth**, then narrow the list with search and the sidebar's scope/threshold filters. Search accepts names, commands, PIDs, users, paths, and bundle identifiers.

Select a row to inspect its command, executable, working directory, parent chain, recent history, and visible network endpoints. Pin a process to keep it easy to reach from the sidebar. **Applications** groups related helpers; **Process Tree** follows parent PIDs. Grouping is heuristic, and a detached process may no longer have its original parent available.

**Memory Investigation** provides starting points for large footprints, growth, and detached processes. An attention indicator is a reason to investigate—not a diagnosis of a leak or malicious activity.

## Find who's holding a port

1. Open **Ports** and search for a number such as `3000`.
2. Use **Open** for TCP listeners and bound UDP sockets, **Connected** for sockets with a remote endpoint, or **All Sockets** for the broader snapshot.
3. Select a result to inspect the owning process and command. Use **Scan Now** after starting or stopping a server.

Entering Ports refreshes a missing snapshot or one at least 10 seconds old. Staying on the page does not start continuous polling. A scan discovers current processes even when the main process list is paused. IPv4 and IPv6 are supported; `*` represents a wildcard local address. Multiple rows can belong to one process because each row represents a socket/file descriptor.

If a port is missing, clear search, choose **All Sockets**, and scan again. macOS may deny inspection, and a process can exit during the scan. An empty result does **not** guarantee that the port is available. The selected process's Network Ports card also has its own refresh button.

## Track disk growth

Open **Storage Growth** and choose a focused folder, such as a project directory or Developer Data. Choosing a folder starts a scan; simply entering the page does not.

The first scan establishes a baseline. Return later, select the same root, and use **Scan Again**:

- **Growth** compares paths retained in the two latest snapshots.
- **Cleanup** highlights recognizable caches, dependencies, and build output.
- **Move / Archive** suggests large archives, models, media, and datasets to review.
- **Largest** shows the biggest retained entries regardless of growth.

Select a result for the measured size and the reason it was surfaced. **Reveal in Finder** and **Copy Path** help you investigate; there is no automatic deletion, migration, or cloud upload. Check backups and use the owning app's cleanup tools where possible.

Folder sizes overlap: a parent's total already includes its children. Allocated size can differ from logical size or Finder's display. Unreadable paths are counted, not silently treated as measured content. Scans don't follow interior symlinks or descend into another mounted volume.

Topps keeps a bounded selection of findings, not a complete file index. Growth is available only for exact paths retained in both scans; moved/renamed items don't preserve identity. A cancelled or memory-limited scan doesn't replace the last completed snapshot.

## Read memory without mixing the totals

**Footprint** is macOS's memory charge to a process. Topps prefers this metric and falls back to resident size if necessary. Compressed, swapped, shared, graphics, and device-backed allocations can affect the accounting. **Resident** describes pages currently resident in physical memory. A large gap between the two is possible; it doesn't establish a leak by itself.

**PhysMem Used** follows the app's `top`-style accounting: total physical memory minus unused memory. **Available to Reuse** includes unused and inactive memory, so it overlaps the used value. Don't add these two cards together.

The physical-memory bar separates wired, compressor-resident, active, inactive/cache, residual system/other, and unused memory. Swap is disk-backed and shown separately. The CPU and process cards are not bar segments.

Process footprints cannot be summed into a unique count of physical RAM. The **Critical/Elevated** badge is Topps's own classification from memory ratios, not Apple's private memory-pressure measure. A single screenshot is not a diagnosis.

## History, refresh, and safety

The process views share one sampler, defaulting to one second. Change the interval in the toolbar; **⌘.** pauses/resumes sampling and **⌘R** requests a refresh. CPU is measured over sampling intervals, not lifetime CPU time; a process can exceed 100% across multiple cores.

Each process retains up to 300 history points—about five minutes at the default rate—in memory only. Paused rows remain snapshots. The sidebar's **Topps** footprint is measured separately every five seconds, including while paused.

If Topps hits its own memory safety limit, it pauses sampling and warns you. Quit and relaunch, then report the footprint and the actions leading up to it. Don't treat the guardrail as a cure for a leak. Automatic page-entry refresh is suppressed after that warning; explicit scan buttons remain available.

## Optional tools and exports

For model-fit estimates, install `llmfit`, open **LLM Fit**, use **Check Again** if needed, then **Analyze This Mac**. Re-run after changing the use case. Existing analyses refresh on page entry after five minutes; the first analysis is manual. Topps invokes the tool for results, not as a model server. Review [llmfit's own documentation](https://github.com/AlexsJones/llmfit) for its behavior.

Diagnostics explicitly run `vmmap`, `sample`, or `lsof` for the selected PID. Permissions can limit their output. Export process snapshots through the **Export** menu as CSV or JSON; inspect commands, paths, and endpoints before sharing.

Termination sends SIGTERM; force termination sends SIGKILL and can lose unsaved work. Topps only enables these actions for your user-owned processes, excludes PID 1, and never terminates automatically.

## Where data lives—and current limits

Storage history is local at `~/Library/Application Support/Topps/storage-history.json`, capped at 24 snapshots per root and 120 overall. Process history isn't persisted. Core monitoring sends no analytics or process information; optional external tools may have their own network behavior.

Some Settings controls are still unfinished: exact-byte display, attention thresholds, and the hidden-window sampling toggle currently store values without changing behavior. The refresh interval and menu-bar visibility controls are wired up. See [development notes](development.md) for implementation details and [distribution](distribution.md) for the current release status.
