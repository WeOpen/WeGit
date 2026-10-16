import AppKit
import OSLog
import SwiftUI

struct ViewPerformanceSpan: Equatable {
    let name: String
    let id: UUID
}

/// Enabled only in the isolated ReleasePerformance target. Production builds
/// neither accept its environment variable nor write performance fixture data.
@MainActor enum ViewPerformanceJournal {
    static func waitForProfiler() async {
        #if WEGIT_PERFORMANCE
            guard let path = ProcessInfo.processInfo.environment["WEGIT_PERFORMANCE_START_FILE"] else {
                return
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !FileManager.default.fileExists(atPath: path), ContinuousClock.now < deadline,
                !Task.isCancelled
            {
                try? await Task.sleep(for: .milliseconds(20))
            }
        #endif
    }
    #if WEGIT_PERFORMANCE
        private struct Pending {
            let id: UUID?
            let began: UInt64
            let interval: OSSignpostIntervalState
        }
        private static let signposter = OSSignposter(
            subsystem: "com.willxue.wegit", category: "PointsOfInterest")
        private struct Sample: Codable {
            let name: String
            let id: UUID
            let milliseconds: Double
            let peakRSSBytes: Int
            let endedAtNanoseconds: UInt64
        }
        private static var pending: [String: Pending] = [:]
        private static var samples: [Sample] = []
    #endif

    static func selectionChanged() {
        #if WEGIT_PERFORMANCE
            if let previous = pending["diff"] {
                signposter.endInterval("View to paint", previous.interval)
            }
            pending["diff"] = Pending(
                id: nil, began: DispatchTime.now().uptimeNanoseconds,
                interval: signposter.beginInterval("View to paint", id: signposter.makeSignpostID(), "diff"))
        #endif
    }
    static func begin(_ name: String, id: UUID, preservingSelection: Bool = false) {
        #if WEGIT_PERFORMANCE
            let began =
                preservingSelection && pending[name]?.id == nil
                ? pending[name]?.began ?? DispatchTime.now().uptimeNanoseconds
                : DispatchTime.now().uptimeNanoseconds
            let interval: OSSignpostIntervalState
            if preservingSelection, let previous = pending[name], previous.id == nil {
                interval = previous.interval
            } else {
                if let previous = pending[name] { signposter.endInterval("View to paint", previous.interval) }
                interval = signposter.beginInterval(
                    "View to paint", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
            }
            pending[name] = Pending(id: id, began: began, interval: interval)
        #endif
    }
    static func finish(_ name: String, id: UUID) {
        #if WEGIT_PERFORMANCE
            guard let start = pending[name], start.id == id else { return }
            pending.removeValue(forKey: name)
            signposter.endInterval("View to paint", start.interval)
            let ended = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(ended - start.began) / 1_000_000
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            samples.append(
                Sample(
                    name: name, id: id, milliseconds: elapsed, peakRSSBytes: usage.ru_maxrss,
                    endedAtNanoseconds: ended))
            guard let path = ProcessInfo.processInfo.environment["WEGIT_PERFORMANCE_REPORT"] else { return }
            do {
                try JSONEncoder().encode(samples).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch { NSLog("Could not write the isolated performance report.") }
        #endif
    }
}

#if WEGIT_PERFORMANCE
    struct ViewPerformanceProbe: NSViewRepresentable {
        let spans: [ViewPerformanceSpan]
        func makeNSView(context: Context) -> PerformancePaintProbe {
            let view = PerformancePaintProbe()
            view.setAccessibilityElement(false)
            return view
        }
        func updateNSView(_ view: PerformancePaintProbe, context: Context) {
            if view.spans != spans {
                view.spans = spans
                view.needsDisplay = true
            }
        }
    }
    @MainActor final class PerformancePaintProbe: NSView {
        var spans: [ViewPerformanceSpan] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard window?.occlusionState.contains(.visible) == true, !visibleRect.isEmpty else { return }
            let drawn = spans
            DispatchQueue.main.async {
                for span in drawn { ViewPerformanceJournal.finish(span.name, id: span.id) }
            }
        }
    }
#else
    struct ViewPerformanceProbe: View {
        let spans: [ViewPerformanceSpan]
        var body: some View { EmptyView() }
    }
#endif
