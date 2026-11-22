#if DEBUG
  import Observation
  import QuartzCore
  import UIKit

  /// Debug-only frame timing for the drawer scroll trace. It records display-link intervals only
  /// while a scroll is in flight and exposes the distribution as an accessibility label.
  @MainActor
  @Observable
  final class ScrollFrameProbe {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [Double] = []
    var isScrolling = false {
      didSet {
        if isScrolling {
          intervals.removeAll(keepingCapacity: true)
          lastTimestamp = nil
          link?.isPaused = false
        } else {
          link?.isPaused = true
          lastTimestamp = nil
        }
      }
    }

    init() {
      let link = CADisplayLink(target: self, selector: #selector(tick))
      link.add(to: .main, forMode: .common)
      link.isPaused = true
      self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
      defer { lastTimestamp = link.timestamp }
      guard isScrolling, let last = lastTimestamp else { return }
      let milliseconds = (link.timestamp - last) * 1_000
      guard milliseconds > 0, milliseconds < 1_000 else { return }
      intervals.append(milliseconds)
      if intervals.count > 600 { intervals.removeFirst(intervals.count - 600) }
    }

    func invalidate() {
      link?.invalidate()
      link = nil
    }

    var summary: String {
      guard !intervals.isEmpty else { return "frames=0" }
      let sorted = intervals.sorted()
      let p50 = sorted[sorted.count / 2]
      let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
      return String(
        format: "frames=%d p50=%.1fms p95=%.1fms max=%.1fms",
        sorted.count,
        p50,
        p95,
        sorted.last ?? 0
      )
    }
  }
#endif
