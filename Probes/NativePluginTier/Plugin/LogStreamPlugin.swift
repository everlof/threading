import ThreadingPluginKit
import AppKit

// MARK: - Row model

/// One log line, kept as a value. Externally sized content never becomes a view until the table
/// asks for the row that holds it.
struct LogRow {
    let time: String
    let level: String
    let process: String
    let subsystem: String
    let message: String

    /// Ordering for the level filter. `log` and the syslog relay use different vocabularies for
    /// the same idea, so both are mapped here rather than at each call site.
    var severity: Int {
        switch level {
        case "Fault", "Emergency", "Critical": return 4
        case "Error": return 3
        case "Default", "Notice", "Warning": return 2
        case "Info": return 1
        default: return 0
        }
    }
}

// MARK: - Source contract

/// Somewhere log rows come from.
///
/// Sources hand rows over in batches rather than calling back per row: the pane drains on a timer,
/// so one batch of main-thread work happens per tick no matter how fast the source runs.
protocol LogRowSource: AnyObject {
    func start()
    func stop()
    /// Everything produced since the last drain.
    func drain() -> [LogRow]
    /// Rows produced but never collected because the handoff was full. A drop is the honest signal
    /// that the consumer is behind; growing the buffer would only hide it in memory.
    var dropped: Int { get }
}

/// Shared batching and bounded handoff. Every source is a producer on its own queue and the pane
/// is a consumer on the main one; this is the only place that boundary is implemented.
class BufferedLogSource: LogRowSource {
    static let handoffCapacity = 20_000

    private var pending: [LogRow] = []
    private let lock = NSLock()
    private(set) var dropped = 0

    func start() {}
    func stop() {}

    func drain() -> [LogRow] {
        lock.lock()
        defer { lock.unlock() }
        let rows = pending
        pending.removeAll(keepingCapacity: true)
        return rows
    }

    func enqueue(_ rows: [LogRow]) {
        guard !rows.isEmpty else { return }
        lock.lock()
        let room = Self.handoffCapacity - pending.count
        if room >= rows.count {
            pending.append(contentsOf: rows)
        } else {
            if room > 0 { pending.append(contentsOf: rows.prefix(room)) }
            dropped += rows.count - max(0, room)
        }
        lock.unlock()
    }

    func enqueue(_ row: LogRow) { enqueue([row]) }
}

// MARK: - Process plumbing

/// Runs a command and hands whole stdout lines to a parser, off the main thread.
///
/// Partial tails wait for the next chunk; an absurdly long line is dropped rather than grown
/// without limit, because a log source is externally sized and one pathological line must not
/// become unbounded memory.
final class LineReadingProcess {
    private let queue: DispatchQueue
    private var process: Process?

    init(label: String) {
        queue = DispatchQueue(label: "codes.threading.probe.\(label)")
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func run(executable: String, arguments: [String], onLine: @escaping (ArraySlice<UInt8>) -> Void) {
        stop()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        process = task

        queue.async {
            var buffer = Data()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = buffer[buffer.index(after: newline)...]
                    onLine(ArraySlice(line))
                }
                if buffer.count > 1_048_576 { buffer.removeAll(keepingCapacity: true) }
            }
        }
        try? task.run()
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

// MARK: - Simulator

/// `log stream --style=ndjson` from a booted simulator.
///
/// The predicate is pushed into the command rather than applied here, so the log daemon bounds the
/// scan. Filtering in this process would bound only the result.
final class SimulatorLogSource: BufferedLogSource {
    private let runner = LineReadingProcess(label: "simulator")
    private let udid: String
    private let predicate: String?

    init(udid: String, predicate: String?) {
        self.udid = udid
        self.predicate = predicate
    }

    override func start() {
        var arguments = ["simctl", "spawn", udid, "log", "stream", "--style=ndjson", "--level=debug"]
        if let predicate, !predicate.isEmpty {
            arguments.append(contentsOf: ["--predicate", predicate])
        }
        runner.run(executable: "/usr/bin/xcrun", arguments: arguments) { [weak self] line in
            if let row = LogRowDecoding.ndjson(line) { self?.enqueue(row) }
        }
    }

    override func stop() { runner.stop() }
}

// MARK: - Real device

/// `idevicesyslog` from a paired iPhone.
///
/// Text rather than NDJSON: the syslog relay flattens the unified log, so this is the one source
/// whose rows are parsed out of prose. Everything the device redacts (`<private>`) stays redacted;
/// only the app's own tap can publish those, and it does so as ordinary `os_log` entries which
/// arrive here like any other line.
final class DeviceLogSource: BufferedLogSource {
    private let runner = LineReadingProcess(label: "device")
    private let udid: String
    private let overNetwork: Bool
    private let toolPath: String

    init(udid: String, overNetwork: Bool, toolPath: String) {
        self.udid = udid
        self.overNetwork = overNetwork
        self.toolPath = toolPath
    }

    override func start() {
        var arguments = ["-u", udid, "--no-colors"]
        if overNetwork { arguments.append("-n") }
        runner.run(executable: toolPath, arguments: arguments) { [weak self] line in
            if let row = LogRowDecoding.syslog(line) { self?.enqueue(row) }
        }
    }

    override func stop() { runner.stop() }
}

// MARK: - Replay

/// Replays a captured NDJSON log at a stated rate, so the scaling contract can be exercised rather
/// than assumed. Make a fixture with:
///
///     log show --archive <pulled>.logarchive --style ndjson --last 5m --info --debug > capture.ndjson
final class ReplayLogSource: BufferedLogSource {
    private let queue = DispatchQueue(label: "codes.threading.probe.replay")
    private let path: String
    private let rowsPerSecond: Int
    private var stopped = false

    init(path: String, rowsPerSecond: Int) {
        self.path = path
        self.rowsPerSecond = rowsPerSecond
    }

    override func start() {
        stopped = false
        queue.async { [weak self] in
            guard let self, let handle = FileHandle(forReadingAtPath: self.path) else { return }
            var rows: [LogRow] = []
            var buffer = Data()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = buffer[buffer.index(after: newline)...]
                    if let row = LogRowDecoding.ndjson(ArraySlice(line)) { rows.append(row) }
                }
            }
            guard !rows.isEmpty else { return }
            // 20 ms slices, so the rate is even rather than one burst a second.
            let perSlice = max(1, self.rowsPerSecond / 50)
            var index = 0
            while !self.stopped {
                let slice = (0..<perSlice).map { rows[(index + $0) % rows.count] }
                index = (index + perSlice) % rows.count
                self.enqueue(slice)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    override func stop() { stopped = true }
}

// MARK: - Decoding

enum LogRowDecoding {

    /// `log stream --style=ndjson`, and `log show --archive --style ndjson`, which are the same
    /// schema. One parser therefore serves the simulator, a replayed capture, and a device archive.
    static func ndjson(_ line: ArraySlice<UInt8>) -> LogRow? {
        let data = Data(line)
        guard data.first == 0x7B,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let process = (object["processImagePath"] as? String)
            .map { ($0 as NSString).lastPathComponent } ?? "?"
        var time = "--:--:--"
        if let raw = object["timestamp"] as? String, raw.count >= 23 {
            time = String(raw.dropFirst(11).prefix(12))
        }
        return LogRow(
            time: time,
            level: (object["messageType"] as? String) ?? "Default",
            process: process,
            subsystem: (object["subsystem"] as? String) ?? "",
            message: (object["eventMessage"] as? String) ?? ""
        )
    }

    /// `idevicesyslog` output, which looks like:
    ///
    ///     Sep  1 16:21:01.548727 AccessibilityUIServer(CoreMotion)[41737] <Debug>: message
    ///     Sep  1 16:21:01.549408 kernel[0] <Notice>: message
    ///
    /// The parenthesised part is the *sender image* (the library that logged), which is the
    /// closest thing the relay gives to a subsystem, so it is shown in that column.
    static func syslog(_ line: ArraySlice<UInt8>) -> LogRow? {
        guard let text = String(bytes: line, encoding: .utf8), !text.isEmpty else { return nil }
        guard !text.hasPrefix("[connected"), !text.hasPrefix("[disconnected") else { return nil }

        // "Sep  1 16:21:01.548727 " — take the clock, drop the date.
        var rest = Substring(text)
        guard let firstSpace = rest.firstIndex(of: " ") else { return nil }
        rest = rest[rest.index(after: firstSpace)...].drop(while: { $0 == " " })
        guard let secondSpace = rest.firstIndex(of: " ") else { return nil }
        rest = rest[rest.index(after: secondSpace)...]
        guard let thirdSpace = rest.firstIndex(of: " ") else { return nil }
        let stamp = String(rest[rest.startIndex..<thirdSpace].prefix(12))
        rest = rest[rest.index(after: thirdSpace)...]

        // "process(sender)[pid] <Level>: message"
        guard let colon = rest.range(of: ">: ") else { return nil }
        let head = rest[rest.startIndex..<colon.lowerBound]
        let message = String(rest[colon.upperBound...])
        guard let angle = head.range(of: " <") else { return nil }
        let level = String(head[head.index(angle.lowerBound, offsetBy: 2)...])
        var name = String(head[head.startIndex..<angle.lowerBound])
        if let bracket = name.range(of: "[", options: .backwards) {
            name = String(name[name.startIndex..<bracket.lowerBound])
        }
        var subsystem = ""
        if let open = name.firstIndex(of: "("), name.hasSuffix(")") {
            subsystem = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
            name = String(name[name.startIndex..<open])
        }
        return LogRow(time: stamp, level: level, process: name, subsystem: subsystem, message: message)
    }
}

// MARK: - Source discovery

/// One thing the user can point the pane at.
struct LogSourceOption {
    enum Kind {
        case simulator(udid: String)
        case device(udid: String, overNetwork: Bool)
        case replay(path: String, rate: Int)
    }

    let title: String
    let kind: Kind

    func makeSource(predicate: String?) -> LogRowSource {
        switch kind {
        case .simulator(let udid):
            return SimulatorLogSource(udid: udid, predicate: predicate)
        case .device(let udid, let overNetwork):
            return DeviceLogSource(
                udid: udid,
                overNetwork: overNetwork,
                toolPath: LogSourceCatalog.idevicesyslogPath ?? "/usr/bin/false"
            )
        case .replay(let path, let rate):
            return ReplayLogSource(path: path, rowsPerSecond: rate)
        }
    }
}

/// Finds the booted simulators and paired devices worth offering.
///
/// Every call here spawns a child process, so discovery never runs on the main thread and every
/// command is given a deadline: a wedged `simctl` or a phone that stops answering must produce an
/// empty list, not a hung pane.
enum LogSourceCatalog {

    static let idevicesyslogPath: String? = {
        ["/opt/homebrew/bin/idevicesyslog", "/usr/local/bin/idevicesyslog"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func discover(replay: (path: String, rate: Int)?, completion: @escaping ([LogSourceOption]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var options: [LogSourceOption] = []
            for (udid, name) in bootedSimulators() {
                options.append(.init(title: "􀟜  \(name)", kind: .simulator(udid: udid)))
            }
            if idevicesyslogPath != nil {
                for (udid, network) in pairedDevices() {
                    let label = network ? "Wi-Fi" : "USB"
                    options.append(.init(
                        title: "􀟠  \(String(udid.prefix(8)))… (\(label))",
                        kind: .device(udid: udid, overNetwork: network)
                    ))
                }
            }
            if let replay {
                options.append(.init(
                    title: "􀊞  Replay \((replay.path as NSString).lastPathComponent) @ \(replay.rate)/s",
                    kind: .replay(path: replay.path, rate: replay.rate)
                ))
            }
            DispatchQueue.main.async { completion(options) }
        }
    }

    private static func bootedSimulators() -> [(String, String)] {
        guard let output = run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"]),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return byRuntime.values.flatMap { $0 }.compactMap {
            guard let udid = $0["udid"] as? String, let name = $0["name"] as? String else { return nil }
            return (udid, name)
        }
    }

    /// `idevice_id -l` lists devices reachable over USB, `-n` over the network. A phone silently
    /// moves between the two when it is unplugged, and `idevicesyslog` needs the matching flag, so
    /// which list a device came from is part of its identity here.
    private static func pairedDevices() -> [(String, Bool)] {
        let usb = (run("/opt/homebrew/bin/idevice_id", ["-l"]) ?? "")
            .split(separator: "\n").map(String.init)
        let network = (run("/opt/homebrew/bin/idevice_id", ["-n"]) ?? "")
            .split(separator: "\n").map(String.init)
        var seen = Set<String>()
        var result: [(String, Bool)] = []
        for udid in usb where !udid.isEmpty && seen.insert(udid).inserted {
            result.append((udid, false))
        }
        for udid in network where !udid.isEmpty && seen.insert(udid).inserted {
            result.append((udid, true))
        }
        return result
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(6)
        var data = Data()
        while task.isRunning, Date() < deadline {
            data.append(pipe.fileHandleForReading.availableData)
        }
        if task.isRunning { task.terminate(); return nil }
        data.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return String(data: data, encoding: .utf8)
    }
}

/// Everything the probe reports about itself goes to stderr, so a run can be verified from a
/// script. Photographing the window is not always available and was never the point.
enum Probe {
    static func log(_ text: String) {
        FileHandle.standardError.write(Data(("[probe] " + text + "\n").utf8))
    }
}

// MARK: - Pane

final class LogPaneView: NSView {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let sourcePopUp = NSPopUpButton()
    private let levelPopUp = NSPopUpButton()
    private let filterField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")

    private var options: [LogSourceOption] = []
    private var source: LogRowSource?
    private let replay: (path: String, rate: Int)?
    private let predicate: String?

    /// The ring: bounded, so a firehose cannot grow memory without limit.
    private let capacity = 50_000
    private var rows: [LogRow] = []
    private var visibleRows: [LogRow] = []
    private var filter = ""
    private var minimumSeverity = 0

    private var timer: Timer?
    private var received = 0
    private var lastCount = 0
    private var rate = 0
    private var peakRate = 0
    private var worstTickMS = 0.0

    private var background = NSColor.textBackgroundColor
    private var surface = NSColor.controlBackgroundColor
    private var text = NSColor.labelColor
    private var secondary = NSColor.secondaryLabelColor
    private var accent = NSColor.controlAccentColor
    private var monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Preselected source (a substring of its title) and preset filter, so a run can be scripted.
    private let preferredSource: String?

    init(predicate: String?, replay: (path: String, rate: Int)?, preferredSource: String?, presetFilter: String?) {
        self.predicate = predicate
        self.replay = replay
        self.preferredSource = preferredSource
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 560))
        buildTable()
        buildChrome()
        if let presetFilter, !presetFilter.isEmpty {
            filterField.stringValue = presetFilter
            filter = presetFilter.lowercased()
        }
        reloadSources()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.rate = self.received - self.lastCount
            self.lastCount = self.received
            self.peakRate = max(self.peakRate, self.rate)
            self.updateStatus()
            Probe.log("stats rows=\(self.received) shown=\(self.visibleRows.count)"
                + " rate=\(self.rate)/s peak=\(self.peakRate)/s"
                + " worstTick=\(String(format: "%.1f", self.worstTickMS))ms"
                + " ring=\(self.rows.count) dropped=\(self.source?.dropped ?? 0)"
                + " filter=\u{22}\(self.filter)\u{22} minLevel=\(self.minimumSeverity)")
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        source?.stop()
        timer?.invalidate()
    }

    // MARK: Building

    private func buildTable() {
        let columns: [(String, String, CGFloat)] = [
            ("time", "Time", 92),
            ("level", "Level", 62),
            ("process", "Process", 150),
            ("subsystem", "Subsystem", 180),
            ("message", "Message", 640),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 16
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.headerView = NSTableHeaderView()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
    }

    private func buildChrome() {
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)
        sourcePopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        for (title, severity) in [("All levels", 0), ("Info and above", 1), ("Errors only", 3)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = severity
            levelPopUp.menu?.addItem(item)
        }
        levelPopUp.target = self
        levelPopUp.action = #selector(levelChanged)
        levelPopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let reload = NSButton(title: "Rescan", target: self, action: #selector(reloadSources))
        reload.bezelStyle = .rounded
        reload.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearRows))
        clear.bezelStyle = .rounded
        clear.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        filterField.placeholderString = "Filter message, process or subsystem"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsSearchStringImmediately = false
        filterField.sendsWholeSearchString = false
        filterField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let bar = NSStackView(views: [sourcePopUp, reload, levelPopUp, filterField, clear, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)

        let stack = NSStackView(views: [bar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Sources

    @objc private func reloadSources() {
        LogSourceCatalog.discover(replay: replay) { [weak self] found in
            guard let self else { return }
            let previous = self.sourcePopUp.indexOfSelectedItem
            self.options = found
            self.sourcePopUp.removeAllItems()
            if found.isEmpty {
                self.sourcePopUp.addItem(withTitle: "No sources found")
                self.sourcePopUp.isEnabled = false
                self.updateStatus()
                return
            }
            self.sourcePopUp.isEnabled = true
            found.forEach { self.sourcePopUp.addItem(withTitle: $0.title) }
            Probe.log("sources: " + found.map(\.title).joined(separator: " | "))
            var index = (previous >= 0 && previous < found.count) ? previous : 0
            if let wanted = self.preferredSource,
               let match = found.firstIndex(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) {
                index = match
            }
            self.sourcePopUp.selectItem(at: index)
            self.startSelectedSource()
        }
    }

    @objc private func sourceChanged() { startSelectedSource() }

    private func startSelectedSource() {
        let index = sourcePopUp.indexOfSelectedItem
        guard index >= 0, index < options.count else { return }
        source?.stop()
        rows.removeAll(keepingCapacity: true)
        visibleRows.removeAll(keepingCapacity: true)
        received = 0
        lastCount = 0
        peakRate = 0
        worstTickMS = 0
        tableView.reloadData()
        let started = options[index].makeSource(predicate: predicate)
        source = started
        started.start()
        Probe.log("selected: \(options[index].title)")
        updateStatus()
    }

    @objc private func clearRows() {
        rows.removeAll(keepingCapacity: true)
        visibleRows.removeAll(keepingCapacity: true)
        tableView.reloadData()
        updateStatus()
    }

    // MARK: Filtering

    @objc private func filterChanged() {
        filter = filterField.stringValue.lowercased()
        recomputeVisible()
        tableView.reloadData()
        updateStatus()
    }

    @objc private func levelChanged() {
        minimumSeverity = levelPopUp.selectedItem?.tag ?? 0
        recomputeVisible()
        tableView.reloadData()
        updateStatus()
    }

    private func matches(_ row: LogRow) -> Bool {
        guard row.severity >= minimumSeverity else { return false }
        guard !filter.isEmpty else { return true }
        return row.message.lowercased().contains(filter)
            || row.process.lowercased().contains(filter)
            || row.subsystem.lowercased().contains(filter)
    }

    private var isFiltering: Bool { !filter.isEmpty || minimumSeverity > 0 }

    private func recomputeVisible() {
        visibleRows = isFiltering ? rows.filter { matches($0) } : rows
    }

    // MARK: Streaming

    /// One batch per tick. Appends are coalesced, and the bottom stays pinned only if it was
    /// already there, so scrolling back to read something is not fought by the stream.
    private func tick() {
        guard let source else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let incoming = source.drain()
        guard !incoming.isEmpty else { return }
        received += incoming.count

        let wasPinned = isPinnedToBottom()
        rows.append(contentsOf: incoming)
        if rows.count > capacity { rows.removeFirst(rows.count - capacity) }

        if isFiltering {
            visibleRows.append(contentsOf: incoming.filter { matches($0) })
            if visibleRows.count > capacity { visibleRows.removeFirst(visibleRows.count - capacity) }
        } else {
            visibleRows = rows
        }

        tableView.reloadData()
        if wasPinned, !visibleRows.isEmpty {
            tableView.scrollRowToVisible(visibleRows.count - 1)
        }
        // The tick is the whole main-thread cost of the stream: drain, append, reload, scroll.
        // If it grows with total content rather than with the batch, the design is wrong.
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        worstTickMS = max(worstTickMS, elapsed)
    }

    private func isPinnedToBottom() -> Bool {
        guard let document = scrollView.documentView else { return true }
        return scrollView.contentView.documentVisibleRect.maxY >= document.bounds.height - 4
    }

    private func updateStatus() {
        let drops = source?.dropped ?? 0
        var parts = ["\(visibleRows.count) shown"]
        if isFiltering { parts.append("of \(rows.count)") }
        parts.append("\(rate)/s")
        if peakRate > 0 { parts.append("peak \(peakRate)/s") }
        if drops > 0 { parts.append("dropped \(drops)") }
        statusLabel.stringValue = parts.joined(separator: " · ")
        statusLabel.textColor = drops > 0 ? accent : secondary
    }

    // MARK: Theme

    func apply(theme: PluginTheme) {
        background = theme.background
        surface = theme.surface
        text = theme.text
        secondary = theme.secondaryText
        accent = theme.accent
        monoFont = theme.monospacedFont
        tableView.rowHeight = theme.rowHeight

        wantsLayer = true
        layer?.backgroundColor = surface.cgColor
        // The clip view paints the region the rows sit in, so setting only the table's colour
        // leaves the old ground showing. Both need saying, and all three need marking dirty:
        // reloadData rebuilds cells, not the background behind them.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = background
        tableView.backgroundColor = background
        filterField.textColor = text
        updateStatus()
        tableView.reloadData()
        tableView.needsDisplay = true
        scrollView.contentView.needsDisplay = true
        scrollView.needsDisplay = true
    }
}

extension LogPaneView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }
}

extension LogPaneView: NSTableViewDelegate {
    /// Only the viewport's rows are ever built, through ordinary reuse. This is the whole reason
    /// the pane is a table rather than a stack of labels.
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, row < visibleRows.count else { return nil }
        let identifier = tableColumn.identifier
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.isSelectable = true
        }
        let entry = visibleRows[row]
        field.font = monoFont
        switch identifier.rawValue {
        case "time":
            field.stringValue = entry.time
            field.textColor = secondary
        case "level":
            field.stringValue = entry.level
            field.textColor = entry.severity >= 3 ? accent : secondary
        case "process":
            field.stringValue = entry.process
            field.textColor = text
        case "subsystem":
            field.stringValue = entry.subsystem
            field.textColor = secondary
        default:
            field.stringValue = entry.message
            field.textColor = entry.severity >= 3 ? accent : text
        }
        return field
    }
}

// MARK: - Principal class

@objc(LogStreamPlugin)
public final class LogStreamPlugin: NSObject, ThreadingNativePlugin {
    private weak var pane: LogPaneView?

    public override required init() { super.init() }

    public var pluginIdentifier: String { "codes.threading.probe.logstream" }

    public static var pluginAPIVersion: Int { ThreadingPluginAPI.version }

    public func makePaneView(context: PluginContext) -> NSView {
        let replay = context.argument("replayPath").map {
            (path: $0, rate: context.argument("replayRate").flatMap(Int.init) ?? 6_000)
        }
        let view = LogPaneView(
            predicate: context.argument("predicate"),
            replay: replay,
            preferredSource: context.argument("source"),
            presetFilter: context.argument("filter")
        )
        pane = view
        view.apply(theme: context.theme)
        return view
    }

    public func apply(theme: PluginTheme) {
        pane?.apply(theme: theme)
    }
}
