import AppKit
import SwiftUI

/// One realized row measurement paired with the native geometry sampled in the same pass: the
/// frame in document coordinates, the enclosing scroll view's viewport width, the document
/// view the frame was converted to, and the document's height and native row count read in the
/// same instant. The row frame callback is asynchronous, so a post-resize frame can be delivered
/// before a viewport change is observed — pairing the row width with the viewport width from
/// the SAME measurement is what keeps a resize delta single in either delivery order. The
/// height/count pair rejects a frame measured against an older state of the SAME document,
/// which document identity alone cannot distinguish.
struct ActivityRowFrameSample {
    var frame: CGRect
    var viewportWidth: CGFloat
    var document: NSView
    var documentHeight: CGFloat = 0
    var nativeRowCount: Int = 0
}

/// Measure realized rows after native layout settles, without adding a SwiftUI geometry dependency
/// to the lazy stack. Coordinates are relative to the scroll document, matching its clip offset.
struct ActivityRowGeometry: NSViewRepresentable {
    let generation: Int
    let measurements: ActivityRowMeasurements
    /// The row's stable semantic identity: the reading reference transaction matches realized
    /// measurement views to their rows through this ID, never through view identity or index.
    var stableID: String?
    let onFrame: (ActivityRowFrameSample) -> Void

    func makeNSView(context: Context) -> MeasurementView { MeasurementView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeasurementView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }

    func updateNSView(_ view: MeasurementView, context: Context) {
        measurements.views.add(view)
        view.stableID = stableID
        if view.generation != generation { view.invalidateMeasurement(); view.generation = generation }
        view.onFrame = onFrame
        view.scheduleMeasurement()
    }

    final class MeasurementView: NSView {
        var onFrame: ((ActivityRowFrameSample) -> Void)?
        var generation = -1
        var stableID: String?
        private var scheduled = false
        private var lastFrame: CGRect?
        private var lastViewportWidth: CGFloat?
        private weak var lastDocument: NSView?
        private var lastDocumentHeight: CGFloat?
        private var lastNativeRowCount: Int?

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
            lastDocumentHeight = nil
            lastNativeRowCount = nil
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                measureNow()
            }
        }

        /// Reads the current native geometry and reports it through `onFrame` when it differs
        /// from the last report. The viewport, the document and the document's height/row-count
        /// pair are sampled with the frame so their pairing travels with it: an unchanged CGRect
        /// under a changed viewport, document or document state still updates the paired
        /// metadata, and downstream rejection (generation, document identity, width, pair)
        /// stays authoritative for every consumer.
        func measureNow() {
            guard window != nil, let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
            var measured = convert(bounds, to: document)
            if !document.isFlipped { measured.origin.y = document.bounds.maxY - measured.maxY }
            let viewportWidth = scrollView.contentView.bounds.width
            let documentHeight = document.bounds.height
            let nativeRowCount = (document as? NSTableView)?.numberOfRows ?? 0
            guard measured != lastFrame || viewportWidth != lastViewportWidth || document !== lastDocument
                || documentHeight != lastDocumentHeight || nativeRowCount != lastNativeRowCount else { return }
            lastFrame = measured
            lastViewportWidth = viewportWidth
            lastDocument = document
            lastDocumentHeight = documentHeight
            lastNativeRowCount = nativeRowCount
            onFrame?(ActivityRowFrameSample(frame: measured, viewportWidth: viewportWidth, document: document,
                                            documentHeight: documentHeight, nativeRowCount: nativeRowCount))
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
