import AppKit

// MARK: - ActivityFeedPosition

/// Paired native row geometry used by reading restoration.
@MainActor
final class ActivityFeedPosition {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    var frames: [String: CGRect] = [:]
    var pairedViewportWidths: [String: CGFloat] = [:]
    weak var pairedDocument: NSView?
    let measurements = ActivityRowMeasurements()
    var pagingTask: Task<Void, Never>?

    func clearFrames() {
        frames.removeAll(keepingCapacity: true)
        pairedViewportWidths.removeAll(keepingCapacity: true)
        pairedDocument = nil
    }

    func discardStaleFrames(nativeIdentity: ParallelScrollNativeIdentity) {
        if !nativeIdentity.isCurrentDocument(pairedDocument) { clearFrames() }
    }

    /// Reject deliveries from a replaced target before they enter the cache.
    /// Metadata changes also wake restoration when the frame itself is unchanged.
    @discardableResult
    func record(_ sample: ActivityRowFrameSample, for id: String, nativeIdentity: ParallelScrollNativeIdentity) -> Bool {
        discardStaleFrames(nativeIdentity: nativeIdentity)
        guard nativeIdentity.isCurrentDocument(sample.document) else { return false }
        let changed = frames[id] != sample.frame || pairedViewportWidths[id] != sample.viewportWidth
            || pairedDocument !== sample.document
        pairedDocument = sample.document
        frames[id] = sample.frame
        pairedViewportWidths[id] = sample.viewportWidth
        return changed
    }

    /// The paired viewport prevents applying a resize delta twice when rows arrive first.
    func expectedRowWidth(for id: String?, viewportWidth: CGFloat, nativeIdentity: ParallelScrollNativeIdentity) -> CGFloat? {
        discardStaleFrames(nativeIdentity: nativeIdentity)
        guard let id, let frame = frames[id], frame.width > 0,
              let sampledViewportWidth = pairedViewportWidths[id] else { return nil }
        return max(0, frame.width + viewportWidth - sampledViewportWidth)
    }
}

// MARK: - ActivityRowWidthRestoration

/// A pending resize width survives measurement invalidation until restoration completes.
struct ActivityRowWidthRestoration {
    private(set) var width: CGFloat?

    mutating func resize(measuredWidth: CGFloat?, previousViewportWidth: CGFloat, viewportWidth: CGFloat, restoring: Bool) {
        if let measuredWidth {
            width = measuredWidth
        } else if restoring, let width {
            self.width = max(0, width + viewportWidth - previousViewportWidth)
        } else {
            width = nil
        }
    }

    func accepts(rowWidth: CGFloat?) -> Bool {
        guard let width else { return true }
        return abs((rowWidth ?? -1) - width) <= 1
    }

    mutating func finish(restoring: Bool) {
        if !restoring { clear() }
    }

    mutating func clear() { width = nil }
}
