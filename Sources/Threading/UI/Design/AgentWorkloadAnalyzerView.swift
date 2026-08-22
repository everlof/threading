import AppKit

/// A compact, fixed-budget spectrum presentation of the app-wide agent workload.
///
/// Exact meaning stays outside the pixels: the reading is the number of sessions in `.working`
/// (`99+` at the fixed display's overflow), and `MAX` means at least one of those sessions is at
/// the top of its provider's announced effort ladder. The seven bands are a visual envelope over
/// `AgentIntensity`; they never claim to be token throughput, CPU use, or one band per agent.
///
/// The component is presentation-ready under every theme, but `SidebarBrandView` currently
/// mounts it only for the existing spectrum material (Classic Player and themes derived from
/// it). Its timer exists only while that presentation is in a window with work to show. Reduce
/// Motion and a zero workload both remove the driver outright.
@MainActor
final class AgentWorkloadAnalyzerView: NSView, ThemedComponent {

    // MARK: - Properties

    private let appEvents = AppEventObservations()
    private var intensity: AgentIntensity = .none
    private var phase: Double = 0
    private var frameTimer: Timer?
    private var isPresented = false
    private var freezesPresentationForTesting = false

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        intensity = AgentWorkloadMonitor.shared.intensity

        appEvents.observe(AgentIntensityDidChange.self) { [weak self] event in
            self?.update(intensity: event.intensity)
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            self.refreshFrameDriver()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            frameTimer?.invalidate()
        }
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize { Design.WorkloadAnalyzer.size }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshFrameDriver()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The brand row remains one static-text accessibility element and is not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Presentation

    func setPresented(_ presented: Bool) {
        let presentationChanged = presented != isPresented
        isPresented = presented
        isHidden = !presented
        guard presentationChanged else { return }
        refreshFrameDriver()
    }

    func update(intensity: AgentIntensity) {
        guard intensity != self.intensity else { return }
        self.intensity = intensity
        needsDisplay = true
        refreshFrameDriver()
    }

    private func refreshFrameDriver() {
        let interval = Design.Motion.workloadAnalyzerFrameInterval
        let shouldRun = interval > 0
            && isPresented
            && window != nil
            && intensity.workload.workingCount > 0
            && !freezesPresentationForTesting

        guard shouldRun else {
            frameTimer?.invalidate()
            frameTimer = nil
            return
        }
        guard frameTimer == nil else { return }

        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(advanceFrame(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    @objc private func advanceFrame(_ timer: Timer) {
        let cycle = Design.Motion.workloadAnalyzerFrameInterval
            * Double(Design.WorkloadAnalyzer.bandCount + Design.WorkloadAnalyzer.cellCount)
        guard cycle > 0 else {
            refreshFrameDriver()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        phase = (now / cycle).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        _ = ThemedSurface.draw(
            bounds,
            fill: Design.Surface.field,
            border: Design.Surface.border,
            radius: Design.Radius.control,
            borderWidth: Design.Radius.border,
            bevel: .sunken
        )

        let content = bounds.insetBy(
            dx: Design.WorkloadAnalyzer.contentInset,
            dy: Design.WorkloadAnalyzer.contentInset
        )
        guard content.width > 0, content.height > 0 else { return }

        let bandsWidth = CGFloat(Design.WorkloadAnalyzer.bandCount)
            * Design.WorkloadAnalyzer.bandWidth
            + CGFloat(Design.WorkloadAnalyzer.bandCount - 1)
            * Design.WorkloadAnalyzer.bandGap
        let bands = NSRect(
            x: content.minX,
            y: content.minY,
            width: min(bandsWidth, content.width),
            height: content.height
        )
        let reading = NSRect(
            x: bands.maxX + Design.WorkloadAnalyzer.readingGap,
            y: content.minY,
            width: min(
                Design.WorkloadAnalyzer.readingWidth,
                max(0, content.maxX - bands.maxX - Design.WorkloadAnalyzer.readingGap)
            ),
            height: content.height
        )

        let now = freezesPresentationForTesting
            ? intensity.measuredAt
            : ProcessInfo.processInfo.systemUptime
        let level = intensity.level(at: now)
        let cells = displayedCellCounts(level: level)
        drawBands(cells, in: bands)
        drawReading(in: reading)
    }

    private func displayedCellCounts(level: Double) -> [Int] {
        guard intensity.workload.workingCount > 0 else {
            return Array(repeating: 0, count: Design.WorkloadAnalyzer.bandCount)
        }

        return (0..<Design.WorkloadAnalyzer.bandCount).map { band in
            let position = Double(band)
            let primary = sin(phase * 2 * .pi + position * 0.91)
            let secondary = sin(phase * 4 * .pi + position * 1.73)
            let shape = 0.72 + primary * 0.18 + secondary * 0.10
            let count = Int((level * shape * Double(Design.WorkloadAnalyzer.cellCount)).rounded())
            return min(max(count, 1), Design.WorkloadAnalyzer.cellCount)
        }
    }

    private func drawBands(_ activeCounts: [Int], in rect: NSRect) {
        let inactive = Design.Surface.accentMuted
        for band in 0..<Design.WorkloadAnalyzer.bandCount {
            let x = rect.minX + CGFloat(band)
                * (Design.WorkloadAnalyzer.bandWidth + Design.WorkloadAnalyzer.bandGap)
            let activeCount = activeCounts.indices.contains(band) ? activeCounts[band] : 0

            for cell in 0..<Design.WorkloadAnalyzer.cellCount {
                let y = rect.minY + CGFloat(cell)
                    * (Design.WorkloadAnalyzer.cellHeight + Design.WorkloadAnalyzer.cellGap)
                let cellRect = NSRect(
                    x: x,
                    y: y,
                    width: Design.WorkloadAnalyzer.bandWidth,
                    height: Design.WorkloadAnalyzer.cellHeight
                )
                let isActive = cell < activeCount
                let isTopEffortCell = intensity.workload.anyAtTopEffort
                    && cell >= Design.WorkloadAnalyzer.cellCount - 2
                (isActive
                    ? (isTopEffortCell ? Design.Syntax.type : Design.Surface.accent)
                    : inactive).setFill()
                cellRect.fill()
            }

            guard activeCount > 0 else { continue }
            let peakY = min(
                rect.maxY - Design.WorkloadAnalyzer.peakHeight,
                rect.minY + CGFloat(activeCount)
                    * (Design.WorkloadAnalyzer.cellHeight + Design.WorkloadAnalyzer.cellGap)
            )
            (intensity.workload.anyAtTopEffort
                ? Design.Syntax.type
                : Design.Surface.accent).setFill()
            NSRect(
                x: x,
                y: peakY,
                width: Design.WorkloadAnalyzer.bandWidth,
                height: Design.WorkloadAnalyzer.peakHeight
            ).fill()
        }
    }

    private func drawReading(in rect: NSRect) {
        guard rect.width > 0 else { return }
        let countRect = NSRect(
            x: rect.minX,
            y: rect.midY,
            width: rect.width,
            height: rect.maxY - rect.midY
        )
        let stateRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.midY - rect.minY
        )
        ThemedButton.PixelTitleArtwork.draw(
            readingTitle,
            in: countRect,
            ink: Design.Surface.accent,
            mnemonicCharacter: nil
        )
        ThemedButton.PixelTitleArtwork.draw(
            intensity.workload.anyAtTopEffort ? "MAX" : "AGT",
            in: stateRect,
            ink: intensity.workload.anyAtTopEffort
                ? Design.Syntax.type
                : Design.Text.tertiary,
            mnemonicCharacter: nil
        )
    }

    private var readingTitle: String {
        let count = max(intensity.workload.workingCount, 0)
        return count > 99 ? "99+" : String(format: "%02d", count)
    }

    // MARK: - Test seams

    var displayedCellCountsForTesting: [Int] {
        displayedCellCounts(level: intensity.level(at: intensity.measuredAt))
    }

    var hasFrameDriverForTesting: Bool { frameTimer != nil }

    var readingTitleForTesting: String { readingTitle }

    func freezePresentationForTesting(intensity: AgentIntensity, phase: Double) {
        freezesPresentationForTesting = true
        frameTimer?.invalidate()
        frameTimer = nil
        self.intensity = intensity
        self.phase = min(max(phase, 0), 1)
        needsDisplay = true
    }
}
