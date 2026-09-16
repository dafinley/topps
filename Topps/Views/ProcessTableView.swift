import AppKit
import SwiftUI

/// The process list intentionally uses one long-lived NSTableView instead of SwiftUI.Table.
/// SwiftUI.Table rebuilt AppKit-backed row hosts on every one-second sample and, over a long
/// run, retained millions of KVO and Auto Layout objects. NSTableView reuses a bounded set of
/// cells and lets us update their contents without rebuilding the view hierarchy.
struct ProcessTableView: View {
    @EnvironmentObject private var store: ToppsStore

    var body: some View {
        let rows = store.filteredProcesses
        let parentNames = Dictionary(uniqueKeysWithValues: store.processes.map { ($0.pid, $0.name) })

        ZStack {
            ReusableProcessTable(
                rows: rows,
                parentNames: parentNames,
                pinned: store.pinned,
                watched: store.watched,
                selection: $store.selectedIdentity,
                copyText: store.copy,
                togglePin: store.togglePin,
                toggleWatch: store.toggleWatch
            )

            if rows.isEmpty {
                ContentUnavailableView(
                    "No matching processes",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try clearing search or filters.")
                )
                .allowsHitTesting(false)
            }
        }
    }
}

enum ProcessTableReloadStrategy: Equatable {
    case visibleRows
    case allRows

    static func choose(previous: [ProcessIdentity], next: [ProcessIdentity]) -> Self {
        previous == next ? .visibleRows : .allRows
    }
}

private struct ReusableProcessTable: NSViewRepresentable {
    let rows: [ProcessSnapshot]
    let parentNames: [Int32: String]
    let pinned: Set<ProcessIdentity>
    let watched: Set<ProcessIdentity>
    @Binding var selection: ProcessIdentity?
    let copyText: (String) -> Void
    let togglePin: (ProcessSnapshot) -> Void
    let toggleWatch: (ProcessSnapshot) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applySnapshot()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tableView.delegate = nil
        coordinator.tableView.dataSource = nil
        coordinator.tableView.contextMenuProvider = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ReusableProcessTable
        let tableView = ProcessNSTableView()
        private var rows: [ProcessSnapshot] = []
        private var isSynchronizingSelection = false

        init(parent: ReusableProcessTable) {
            self.parent = parent
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            configureTable()
            let scrollView = NSScrollView()
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .controlBackgroundColor
            return scrollView
        }

        func applySnapshot() {
            let previousIDs = rows.map(\.identity)
            let nextIDs = parent.rows.map(\.identity)
            rows = parent.rows

            switch ProcessTableReloadStrategy.choose(previous: previousIDs, next: nextIDs) {
            case .allRows:
                tableView.reloadData()
            case .visibleRows:
                reloadVisibleRows()
            }
            synchronizeSelection()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let process = rows[row]
            switch tableColumn.identifier {
            case .process:
                let cell = reusableProcessCell(in: tableView)
                cell.configure(process)
                return cell
            case .footprint:
                let cell = reusableFootprintCell(in: tableView)
                cell.configure(process)
                return cell
            default:
                let cell = reusableTextCell(in: tableView, identifier: tableColumn.identifier)
                configure(cell.textField!, column: tableColumn.identifier, process: process)
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection else { return }
            let row = tableView.selectedRow
            parent.selection = rows.indices.contains(row) ? rows[row].identity : nil
        }

        private func configureTable() {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.rowHeight = 44
            tableView.intercellSpacing = NSSize(width: 0, height: 1)
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            tableView.style = .fullWidth
            tableView.backgroundColor = .controlBackgroundColor
            tableView.contextMenuProvider = { [weak self] row in self?.contextMenu(for: row) }

            addColumn(.process, title: "Process", width: 245, minimum: 170)
            addColumn(.pid, title: "PID", width: 64, minimum: 55)
            addColumn(.cpu, title: "CPU", width: 60, minimum: 55)
            addColumn(.footprint, title: "Footprint", width: 128, minimum: 105)
            tableView.tableColumn(withIdentifier: .footprint)?.headerToolTip = "Physical footprint is macOS's ledger charge. The second line shows resident pages."
            addColumn(.delta, title: "Δ Footprint", width: 94, minimum: 78)
            addColumn(.threads, title: "Threads", width: 68, minimum: 60)
            addColumn(.parent, title: "Parent", width: 112, minimum: 82)
            addColumn(.runtime, title: "Runtime", width: 78, minimum: 70)
            addColumn(.state, title: "State", width: 82, minimum: 65)
        }

        private func addColumn(_ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minimum: CGFloat) {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minimum
            column.resizingMask = [.userResizingMask]
            tableView.addTableColumn(column)
        }

        private func reloadVisibleRows() {
            guard !rows.isEmpty else { return }
            let range = tableView.rows(in: tableView.visibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return }
            let lower = max(0, range.location)
            let upper = min(rows.count, NSMaxRange(range))
            guard lower < upper else { return }
            for row in lower..<upper {
                for (index, column) in tableView.tableColumns.enumerated() {
                    guard let cell = tableView.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView else { continue }
                    if let cell = cell as? ProcessNameCellView { cell.configure(rows[row]) }
                    else if let cell = cell as? FootprintCellView { cell.configure(rows[row]) }
                    else if let field = cell.textField { configure(field, column: column.identifier, process: rows[row]) }
                }
            }
        }

        private func synchronizeSelection() {
            isSynchronizingSelection = true
            defer { isSynchronizingSelection = false }
            if let selection = parent.selection, let index = rows.firstIndex(where: { $0.identity == selection }) {
                if tableView.selectedRow != index {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
            } else if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
        }

        private func reusableProcessCell(in tableView: NSTableView) -> ProcessNameCellView {
            if let cell = tableView.makeView(withIdentifier: .process, owner: self) as? ProcessNameCellView { return cell }
            let cell = ProcessNameCellView()
            cell.identifier = .process
            return cell
        }

        private func reusableFootprintCell(in tableView: NSTableView) -> FootprintCellView {
            if let cell = tableView.makeView(withIdentifier: .footprint, owner: self) as? FootprintCellView { return cell }
            let cell = FootprintCellView()
            cell.identifier = .footprint
            return cell
        }

        private func reusableTextCell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { return cell }
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func configure(_ field: NSTextField, column: NSUserInterfaceItemIdentifier, process: ProcessSnapshot) {
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.textColor = .labelColor
            field.alignment = .left
            field.toolTip = nil

            switch column {
            case .pid:
                configureNumeric(field, value: String(process.pid), color: .secondaryLabelColor)
            case .cpu:
                configureNumeric(field, value: String(format: "%.1f", process.cpuPercent), color: process.cpuPercent > 80 ? .systemOrange : .labelColor)
            case .delta:
                let color: NSColor = process.memoryChange > 0 ? .systemOrange : process.memoryChange < 0 ? .systemGreen : .secondaryLabelColor
                configureNumeric(field, value: ByteFormat.signed(process.memoryChange), color: color)
            case .threads:
                configureNumeric(field, value: process.threadCount.map(String.init) ?? "—", color: .secondaryLabelColor)
            case .parent:
                field.stringValue = parent.parentNames[process.ppid] ?? (process.ppid == 1 ? "launchd" : String(process.ppid))
                field.textColor = process.isDetached ? .systemOrange : .secondaryLabelColor
            case .runtime:
                configureNumeric(field, value: DurationFormat.string(process.runtime), color: .secondaryLabelColor)
            case .state:
                field.stringValue = process.state.rawValue
                field.textColor = .secondaryLabelColor
            default:
                field.stringValue = ""
            }
        }

        private func configureNumeric(_ field: NSTextField, value: String, color: NSColor) {
            field.stringValue = value
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.textColor = color
            field.alignment = .right
        }

        private func contextMenu(for row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            let process = rows[row]
            let menu = NSMenu()
            menu.addItem(menuItem("Copy PID", action: #selector(copyPID(_:)), process: process))
            menu.addItem(menuItem("Copy Command", action: #selector(copyCommand(_:)), process: process))
            menu.addItem(.separator())
            menu.addItem(menuItem(parent.pinned.contains(process.identity) ? "Unpin" : "Pin Process", action: #selector(togglePin(_:)), process: process))
            menu.addItem(menuItem(parent.watched.contains(process.identity) ? "Stop Watching Growth" : "Watch for Growth", action: #selector(toggleWatch(_:)), process: process))
            return menu
        }

        private func menuItem(_ title: String, action: Selector, process: ProcessSnapshot) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = process.identity.id
            return item
        }

        private func process(from sender: NSMenuItem) -> ProcessSnapshot? {
            guard let identity = sender.representedObject as? String else { return nil }
            return rows.first { $0.identity.id == identity }
        }

        @objc private func copyPID(_ sender: NSMenuItem) {
            guard let process = process(from: sender) else { return }
            parent.copyText(String(process.pid))
        }

        @objc private func copyCommand(_ sender: NSMenuItem) {
            guard let process = process(from: sender) else { return }
            parent.copyText(process.displayCommand)
        }

        @objc private func togglePin(_ sender: NSMenuItem) {
            guard let process = process(from: sender) else { return }
            parent.togglePin(process)
        }

        @objc private func toggleWatch(_ sender: NSMenuItem) {
            guard let process = process(from: sender) else { return }
            parent.toggleWatch(process)
        }
    }
}

@MainActor
private final class ProcessNSTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        return contextMenuProvider?(clicked)
    }
}

@MainActor
private final class ProcessNameCellView: NSTableCellView {
    private let processIcon = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let indicators = (0..<6).map { _ in NSImageView() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        processIcon.imageScaling = .scaleProportionallyUpOrDown
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        addSubview(processIcon)
        addSubview(nameField)
        indicators.forEach {
            $0.imageScaling = .scaleProportionallyUpOrDown
            addSubview($0)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 23
        processIcon.frame = NSRect(x: 7, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let textX: CGFloat = 37
        nameField.frame = NSRect(x: textX, y: 20, width: max(0, bounds.width - textX - 5), height: 20)
        for (index, indicator) in indicators.enumerated() {
            indicator.frame = NSRect(x: textX + CGFloat(index) * 16, y: 5, width: 13, height: 13)
        }
    }

    func configure(_ process: ProcessSnapshot) {
        processIcon.image = ProcessIconCache.shared.icon(for: process)
            ?? NSImage(systemSymbolName: process.isGUIApplication ? "app.fill" : "terminal.fill", accessibilityDescription: nil)
        nameField.stringValue = process.name
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.textColor = .labelColor

        let descriptors = IndicatorDescriptor.forProcess(process)
        for (index, view) in indicators.enumerated() {
            guard descriptors.indices.contains(index) else {
                view.image = nil
                view.isHidden = true
                continue
            }
            let descriptor = descriptors[index]
            view.image = NSImage(systemSymbolName: descriptor.symbol, accessibilityDescription: descriptor.description)
            view.contentTintColor = descriptor.color
            view.setAccessibilityLabel(descriptor.description)
            view.isHidden = false
        }
        setAccessibilityLabel("\(process.name), PID \(process.pid)")
    }
}

@MainActor
private final class FootprintCellView: NSTableCellView {
    private let footprintField = NSTextField(labelWithString: "")
    private let residentField = NSTextField(labelWithString: "")
    private let warningIcon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        footprintField.alignment = .right
        residentField.alignment = .right
        residentField.textColor = .secondaryLabelColor
        warningIcon.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Footprint is substantially larger than resident memory")
        warningIcon.contentTintColor = .systemOrange
        addSubview(footprintField)
        addSubview(residentField)
        addSubview(warningIcon)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        warningIcon.frame = NSRect(x: 4, y: 25, width: 12, height: 12)
        footprintField.frame = NSRect(x: 17, y: 20, width: max(0, bounds.width - 23), height: 20)
        residentField.frame = NSRect(x: 4, y: 4, width: max(0, bounds.width - 10), height: 16)
    }

    func configure(_ process: ProcessSnapshot) {
        footprintField.stringValue = ByteFormat.string(process.memory)
        footprintField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        footprintField.textColor = .labelColor
        residentField.stringValue = process.residentMemory.map { "Resident \(ByteFormat.string($0))" } ?? "Resident unavailable"
        residentField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        warningIcon.isHidden = !process.hasLedgerHeavyFootprint
        setAccessibilityLabel("Footprint \(ByteFormat.string(process.memory)); \(residentField.stringValue)")
    }
}

@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1_024 * 1_024
    }

    func icon(for process: ProcessSnapshot) -> NSImage? {
        guard let executablePath = process.executablePath else { return nil }
        let iconPath: String
        if let range = executablePath.range(of: ".app/", options: .caseInsensitive) {
            iconPath = String(executablePath[..<range.upperBound].dropLast())
        } else {
            iconPath = executablePath
        }
        let key = iconPath as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return autoreleasepool {
            let source = NSWorkspace.shared.icon(forFile: iconPath)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.addRepresentation(bitmap)
            cache.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
            return image
        }
    }
}

private struct IndicatorDescriptor {
    let symbol: String
    let color: NSColor
    let description: String

    static func forProcess(_ process: ProcessSnapshot) -> [Self] {
        var result: [Self] = []
        if process.memory > 2_000_000_000 { result.append(Self(symbol: "memorychip.fill", color: .systemPurple, description: "More than 2 GB")) }
        if process.cpuPercent > 80 { result.append(Self(symbol: "gauge.with.dots.needle.67percent", color: .systemOrange, description: "More than 80 percent CPU")) }
        if process.memoryChangePerMinute > 100_000_000 { result.append(Self(symbol: "chart.line.uptrend.xyaxis", color: .systemRed, description: "Growing faster than 100 MB per minute")) }
        if process.isDetached { result.append(Self(symbol: "link.badge.plus", color: .systemYellow, description: "Parent is launchd")) }
        if (process.threadCount ?? 0) > 64 { result.append(Self(symbol: "square.stack.3d.up.fill", color: .systemBlue, description: "More than 64 threads")) }
        if (process.fileDescriptorCount ?? 0) > 200 { result.append(Self(symbol: "doc.on.doc.fill", color: .systemMint, description: "More than 200 file descriptors")) }
        return result
    }
}

// Flat records and stable NSObject items keep sampling changes out of SwiftUI's
// OutlineGroup/DisclosureGroup row hosting machinery.
struct ProcessOutlineSnapshot {
    struct Row {
        let id: String
        let process: ProcessSnapshot
        var title: String
        var detail: String
        var memory: UInt64
        var cpu: Double
        var children: [String] = []
        var isGroup = false

        init(_ process: ProcessSnapshot) {
            self.process = process
            id = process.identity.id
            title = process.name
            detail = "PID \(process.pid)"
            memory = process.memory
            cpu = process.cpuPercent
        }

        init(group: ProcessGroup) {
            id = "group:" + group.id
            process = group.highestConsumer
            title = group.name
            detail = "\(group.memberIDs.count) processes · \(group.totalThreads) threads"
            memory = group.totalMemory
            cpu = group.totalCPU
            isGroup = true
        }
    }
    var roots: [String] = []
    var rows: [String: Row] = [:]

    static func tree(_ processes: [ProcessSnapshot]) -> Self {
        var result = Self()
        let children = Dictionary(grouping: processes, by: \.ppid)
        let pids = Set(processes.map(\.pid))
        var visited: Set<ProcessIdentity> = []
        func visit(_ process: ProcessSnapshot, depth: Int) {
            guard visited.insert(process.identity).inserted else { return }
            var row = Row(process)
            if depth < 64 {
                for child in children[process.pid] ?? [] where !visited.contains(child.identity) {
                    row.children.append(child.identity.id)
                    visit(child, depth: depth + 1)
                }
            }
            result.rows[row.id] = row
        }
        for process in processes where !pids.contains(process.ppid) || process.pid == process.ppid {
            guard !visited.contains(process.identity) else { continue }
            result.roots.append(process.identity.id)
            visit(process, depth: 0)
        }
        // Missing parents, cycles and unusually deep trees must not hide a PID.
        for process in processes where !visited.contains(process.identity) {
            result.roots.append(process.identity.id)
            visit(process, depth: 0)
        }
        return result
    }

    static func applications(groups: [ProcessGroup], processes: [ProcessSnapshot]) -> Self {
        var result = Self()
        let byID = Dictionary(uniqueKeysWithValues: processes.map { ($0.identity, $0) })
        for group in groups {
            var row = Row(group: group)
            for process in group.memberIDs.compactMap({ byID[$0] }).sorted(by: { $0.memory > $1.memory }) {
                let child = Row(process)
                row.children.append(child.id)
                result.rows[child.id] = child
            }
            result.rows[row.id] = row
            result.roots.append(row.id)
        }
        return result
    }
}

struct ReusableProcessOutline: NSViewRepresentable {
    let snapshot: ProcessOutlineSnapshot
    @Binding var selection: ProcessIdentity?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applySnapshot()
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.outline.delegate = nil
        coordinator.outline.dataSource = nil
        coordinator.items.removeAll()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        final class Item: NSObject {
            var row: ProcessOutlineSnapshot.Row
            init(_ row: ProcessOutlineSnapshot.Row) { self.row = row }
        }
        var parent: ReusableProcessOutline
        let outline = NSOutlineView()
        var items: [String: Item] = [:]
        private var roots: [String] = []
        private var synchronizing = false

        init(parent: ReusableProcessOutline) { self.parent = parent }
        func makeScrollView() -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
            column.width = 700
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.headerView = nil
            outline.rowHeight = 42
            outline.indentationPerLevel = 16
            outline.usesAlternatingRowBackgroundColors = true
            outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            outline.allowsEmptySelection = true
            outline.delegate = self
            outline.dataSource = self
            let scroll = NSScrollView()
            scroll.documentView = outline
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            return scroll
        }

        func applySnapshot() {
            let snapshot = parent.snapshot
            let expanded = Set(items.filter { outline.isItemExpanded($0.value) }.map(\.key))
            var changed = roots != snapshot.roots || items.count != snapshot.rows.count
            for (id, row) in snapshot.rows {
                if let item = items[id] {
                    if item.row.children != row.children { changed = true }
                    item.row = row
                } else { items[id] = Item(row); changed = true }
            }
            items = items.filter { snapshot.rows[$0.key] != nil }
            roots = snapshot.roots
            synchronizing = true
            defer { synchronizing = false }
            if changed {
                outline.reloadData()
                for id in expanded { if let item = items[id] { outline.expandItem(item) } }
            }
            // No reload on metric-only ticks: update the existing visible cells.
            let visible = outline.rows(in: outline.visibleRect)
            if visible.location != NSNotFound {
                for index in visible.location..<min(NSMaxRange(visible), outline.numberOfRows) {
                    if let item = outline.item(atRow: index) as? Item,
                       let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? ProcessOutlineCell {
                        cell.configure(item.row)
                    }
                }
            }
            let selectedRow = parent.selection.flatMap { items[$0.id] }.map { outline.row(forItem: $0) } ?? -1
            if selectedRow >= 0 && outline.selectedRow != selectedRow {
                outline.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            } else if selectedRow < 0 && outline.selectedRow >= 0 { outline.deselectAll(nil) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.row.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let ids = (item as? Item)?.row.children ?? roots
            return items[ids[index]]!
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item)?.row.children.isEmpty == false
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            let id = NSUserInterfaceItemIdentifier("outlineRow")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ProcessOutlineCell ?? ProcessOutlineCell()
            cell.identifier = id
            cell.configure(item.row)
            return cell
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Item)?.row.isGroup == false
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing else { return }
            parent.selection = (outline.item(atRow: outline.selectedRow) as? Item)?.row.process.identity
        }
    }
}

@MainActor
private final class ProcessOutlineCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let memory = NSTextField(labelWithString: "")
    private let cpu = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for field in [name, detail, memory, cpu] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        memory.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        cpu.font = memory.font
        memory.alignment = .right
        cpu.alignment = .right
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 4, y: 9, width: 24, height: 24)
        let width = max(0, bounds.width - 218)
        name.frame = NSRect(x: 36, y: 21, width: width, height: 18)
        detail.frame = NSRect(x: 36, y: 4, width: width, height: 16)
        memory.frame = NSRect(x: bounds.width - 175, y: 12, width: 105, height: 20)
        cpu.frame = NSRect(x: bounds.width - 65, y: 12, width: 60, height: 20)
    }
    func configure(_ row: ProcessOutlineSnapshot.Row) {
        name.stringValue = row.title
        detail.stringValue = row.detail
        memory.stringValue = ByteFormat.string(row.memory)
        cpu.stringValue = String(format: "%.1f%%", row.cpu)
        icon.image = ProcessIconCache.shared.icon(for: row.process)
        setAccessibilityLabel("\(row.title), \(row.detail), footprint \(memory.stringValue), CPU \(cpu.stringValue)")
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let process = Self("process")
    static let pid = Self("pid")
    static let cpu = Self("cpu")
    static let footprint = Self("footprint")
    static let delta = Self("delta")
    static let threads = Self("threads")
    static let parent = Self("parent")
    static let runtime = Self("runtime")
    static let state = Self("state")
}
