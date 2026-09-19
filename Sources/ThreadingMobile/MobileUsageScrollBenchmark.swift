#if DEBUG
import SwiftUI
import UIKit

/// Opt-in driver attached inside the shipping Usage scroll content. It never substitutes a
/// benchmark view for the production chart, cards, theme, or native scroll owner.
struct MobileUsageScrollBenchmark: UIViewRepresentable {
    let days: Int

    func makeUIView(context: Context) -> Probe { Probe(days: days) }
    func updateUIView(_ view: Probe, context: Context) {}
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: UIView {
        private let days: Int
        private weak var scroll: UIScrollView?
        private var link: CADisplayLink?
        private var started = false
        private var startTime = 0.0
        private var previousTime = 0.0
        private var duration = 0.0
        private var gaps: [Double] = []
        private var work: [Double] = []
        private var maximumTravel = 0.0
        private var trackingFrames = 0
        private let nativeGestures = ProcessInfo.processInfo.environment["THREADING_MOBILE_USAGE_SCROLL_NATIVE"] == "1"

        init(days: Int) {
            self.days = days
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !started,
                  let seconds = ProcessInfo.processInfo.environment["THREADING_MOBILE_USAGE_SCROLL_SECONDS"]
                    .flatMap(Double.init), seconds >= 2, seconds <= 120 else { return }
            started = true
            duration = seconds
            // Exclude sheet animation, initial model publication, and framework bootstrap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
        }

        private func start() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let owner = view as? UIScrollView { scroll = owner; break }
                ancestor = view.superview
            }
            guard let scroll else { return }
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            scroll.layoutIfNeeded()
            startTime = ProcessInfo.processInfo.systemUptime
            let display = CADisplayLink(target: self, selector: #selector(tick))
            let maximumRate = Float(window?.screen.maximumFramesPerSecond ?? 60)
            display.preferredFrameRateRange = CAFrameRateRange(
                minimum: maximumRate, maximum: maximumRate, preferred: maximumRate
            )
            link = display
            display.add(to: .main, forMode: .common)
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            guard let scroll else { stop(); return }
            let now = ProcessInfo.processInfo.systemUptime
            if previousTime > 0 { gaps.append((now - previousTime) * 1_000) }
            previousTime = now
            let progress = min(1, (now - startTime) / duration)
            let travel = progress <= 0.5 ? progress * 2 : (1 - progress) * 2
            let top = -scroll.adjustedContentInset.top
            let extent = max(0, scroll.contentSize.height - scroll.bounds.height
                + scroll.adjustedContentInset.bottom - top)
            if scroll.isTracking || scroll.isDecelerating { trackingFrames += 1 }
            maximumTravel = max(maximumTravel, nativeGestures ? scroll.contentOffset.y - top : extent * travel)
            let begin = ProcessInfo.processInfo.systemUptime
            if !nativeGestures || progress == 1 {
                scroll.setContentOffset(CGPoint(x: 0, y: top + extent * travel), animated: false)
                scroll.layoutIfNeeded()
            }
            work.append((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
            if progress == 1 {
                stop()
                let line = "THREADING_PERF ios-usage-scroll days=\(days) frames=\(work.count) "
                    + "work_p50_ms=\(percentile(work, 0.5)) work_p95_ms=\(percentile(work, 0.95)) "
                    + "frame_gap_p95_ms=\(percentile(gaps, 0.95)) frame_gap_max_ms=\(percentile(gaps, 1)) "
                    + "frames_over_33_3=\(gaps.filter { $0 > 33.3 }.count) "
                    + "tracking_frames=\(trackingFrames) travel_pt=\(Int(maximumTravel)) final_top_error=\(abs(scroll.contentOffset.y - top))\n"
                UsageScrollBenchmarkReporter.write(line)
            }
        }

        private func percentile(_ values: [Double], _ fraction: Double) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "0" }
            return String(format: "%.3f", sorted[Int(Double(sorted.count - 1) * fraction)])
        }
    }
}

private enum UsageScrollBenchmarkReporter {
    private static let queue = DispatchQueue(label: "codes.threading.usage-scroll-benchmark", qos: .utility)

    static func write(_ line: String) {
        queue.async {
            let data = Data(line.utf8)
            FileHandle.standardError.write(data)
            try? data.write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("threading-usage-scroll-performance.log"))
        }
    }
}
#endif
