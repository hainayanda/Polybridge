import AppKit
import SwiftUI

/// One realized row measurement paired with the native geometry sampled in the same pass: the
/// frame in document coordinates, the enclosing scroll view's viewport width, and the document
/// view the frame was converted to. The row frame callback is asynchronous, so a post-resize
/// frame can be delivered before a viewport change is observed — pairing the row width with the
/// viewport width from the SAME measurement is what keeps a resize delta single in either
/// delivery order.
struct ActivityRowFrameSample {
    var frame: CGRect
    var viewportWidth: CGFloat
    var document: NSView
}

/// Measure realized rows after native layout settles, without adding a SwiftUI geometry dependency
/// to the lazy stack. Coordinates are relative to the scroll document, matching its clip offset.
struct ActivityRowGeometry: NSViewRepresentable {
    let generation: Int
    let measurements: ActivityRowMeasurements
    let onFrame: (ActivityRowFrameSample) -> Void

    func makeNSView(context: Context) -> MeasurementView { MeasurementView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeasurementView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }

    func updateNSView(_ view: MeasurementView, context: Context) {
        measurements.views.add(view)
        if view.generation != generation { view.invalidateMeasurement(); view.generation = generation }
        view.onFrame = onFrame
        view.scheduleMeasurement()
    }

    final class MeasurementView: NSView {
        var onFrame: ((ActivityRowFrameSample) -> Void)?
        var generation = -1
        private var scheduled = false
        private var lastFrame: CGRect?
        private var lastViewportWidth: CGFloat?
        private weak var lastDocument: NSView?

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleMeasurement()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleMeasurement()
        }

        func invalidateMeasurement() {
            lastFrame = nil
            lastViewportWidth = nil
            lastDocument = nil
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                guard window != nil, let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
                var measured = convert(bounds, to: document)
                if !document.isFlipped { measured.origin.y = document.bounds.maxY - measured.maxY }
                let viewportWidth = scrollView.contentView.bounds.width
                // The viewport and document are sampled with the frame so their pairing travels
                // with it: an unchanged CGRect under a changed viewport or document still
                // updates the paired metadata a resize consumer later relies on.
                guard measured != lastFrame || viewportWidth != lastViewportWidth || document !== lastDocument else { return }
                lastFrame = measured
                lastViewportWidth = viewportWidth
                lastDocument = document
                onFrame?(ActivityRowFrameSample(frame: measured, viewportWidth: viewportWidth, document: document))
            }
        }
    }
}

@MainActor
final class ActivityRowMeasurements {
    let views = NSHashTable<ActivityRowGeometry.MeasurementView>.weakObjects()
    func invalidateMeasurements() {
        for view in views.allObjects { view.invalidateMeasurement() }
    }

    func scheduleMeasurements() {
        for view in views.allObjects { view.scheduleMeasurement() }
    }
}
