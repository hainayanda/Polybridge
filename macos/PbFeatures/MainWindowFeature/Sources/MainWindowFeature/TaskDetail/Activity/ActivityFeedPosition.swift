import AppKit
import PbUI

// MARK: - ActivityDocumentSamplePair

/// A document height and native row count sampled together with a frame: the pairing rejects
/// frames measured against an older state of the SAME document, which document identity alone
/// cannot distinguish — a prepended page keeps the table's identity while moving every row.
struct ActivityDocumentSamplePair: Equatable {
    let documentHeight: CGFloat
    let nativeRowCount: Int
}

// MARK: - ActivityFeedPosition

/// Paired native row geometry used by reading restoration.
@MainActor
final class ActivityFeedPosition {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    var frames: [String: CGRect] = [:]
    var pairedViewportWidths: [String: CGFloat] = [:]
    /// The document height and native row count each recorded frame was sampled with, keyed by
    /// row id and cleared with the frames. A frame whose pair no longer matches the live
    /// document was measured before an in-flight structural change and must not drive a target.
    var sampledPairs: [String: ActivityDocumentSamplePair] = [:]
    weak var pairedDocument: NSView?
    let measurements = ActivityRowMeasurements()
    var pagingTask: Task<Void, Never>?
    /// The open reading-reference restoration lease, if any. Plain coordinator state: opening,
    /// joining, completing and cancelling are the only transitions, and nothing observable
    /// depends on it.
    var referenceRestoration: ActivityFeedReferenceRestoration?

    func clearFrames() {
        frames.removeAll(keepingCapacity: true)
        pairedViewportWidths.removeAll(keepingCapacity: true)
        sampledPairs.removeAll(keepingCapacity: true)
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
        let pair = ActivityDocumentSamplePair(documentHeight: sample.documentHeight, nativeRowCount: sample.nativeRowCount)
        let changed = frames[id] != sample.frame || pairedViewportWidths[id] != sample.viewportWidth
            || sampledPairs[id] != pair
            || pairedDocument !== sample.document
        pairedDocument = sample.document
        frames[id] = sample.frame
        pairedViewportWidths[id] = sample.viewportWidth
        sampledPairs[id] = pair
        return changed
    }

    /// The paired viewport prevents applying a resize delta twice when rows arrive first.
    func expectedRowWidth(for id: String?, viewportWidth: CGFloat, nativeIdentity: ParallelScrollNativeIdentity) -> CGFloat? {
        discardStaleFrames(nativeIdentity: nativeIdentity)
        guard let id, let frame = frames[id], frame.width > 0,
              let sampledViewportWidth = pairedViewportWidths[id] else { return nil }
        return max(0, frame.width + viewportWidth - sampledViewportWidth)
    }

    /// The live document's height and native row count, the pair a recorded frame must match to
    /// count as evidence of the document's current state.
    func currentDocumentPair() -> ActivityDocumentSamplePair? {
        guard let document = pairedDocument else { return nil }
        return ActivityDocumentSamplePair(documentHeight: document.bounds.height,
                                          nativeRowCount: (document as? NSTableView)?.numberOfRows ?? 0)
    }

    /// Opens one fresh irreversible reference restoration lease. The anchor's native package
    /// (measurement view, row view, document, validated inset, native index and count) is
    /// captured here, before the structural change that opened the transaction can reach the
    /// table. A failed capture still opens — the measured-frame and proxy fallbacks then own
    /// the position, exactly as before this lease existed.
    func openReferenceRestoration(anchor: ParallelVerticalAnchor?, shownIDs: [String],
                                  nativeIdentity: ParallelScrollNativeIdentity, generation: Int,
                                  awaitingPagePublication: Bool) {
        discardStaleFrames(nativeIdentity: nativeIdentity)
        let transaction = ActivityFeedReferenceRestoration(measurements: measurements, generation: generation,
                                                          awaitingPagePublication: awaitingPagePublication)
        if let anchor, let id = anchor.resolvedID(in: shownIDs) {
            transaction.captureReference(anchor: anchor, resolvedID: id, nativeIdentity: nativeIdentity,
                                         document: pairedDocument)
        }
        referenceRestoration = transaction
        nativeIdentity.setAnchorProvider(transaction)
    }

    /// Registers the feed body's expected native List snapshot with the open lease, if any.
    /// Plain candidate data only — the lease's lifecycle is untouched by body evaluation.
    func registerListSnapshotCandidate(generation: Int, expectedCount: Int, expectedAnchorIndex: Int?, expectedPadding: CGFloat? = nil) {
        referenceRestoration?.registerCandidate(generation: generation, expectedCount: expectedCount,
                                                anchorIndex: expectedAnchorIndex, expectedPadding: expectedPadding)
    }

    /// Captures the reader's live semantic position directly from a coherent native row.
    /// Cached frames and the cancelled transaction's anchor are deliberately excluded.
    func captureNativeReadingAnchor(shownIDs: [String], nativeIdentity: ParallelScrollNativeIdentity) -> ParallelVerticalAnchor? {
        guard let table = pairedDocument as? NSTableView, nativeIdentity.isCurrentDocument(table),
              let scroll = table.enclosingScrollView, table.window != nil else { return nil }
        let visible = scroll.documentVisibleRect
        let candidates = measurements.views.allObjects.compactMap { source -> (String, CGRect)? in
            guard let id = source.stableID, shownIDs.contains(id), source.window != nil, !source.isHiddenOrHasHiddenAncestor,
                  measurements.views.allObjects.filter({ $0.stableID == id }).count == 1 else { return nil }
            let row = table.row(for: source)
            guard row >= 0, let rowView = table.rowView(atRow: row, makeIfNecessary: false),
                  source.isDescendant(of: rowView) else { return nil }
            let rect = table.rect(ofRow: row)
            let rowFrame = rowView.convert(rowView.bounds, to: table)
            guard abs(rowFrame.minY - rect.minY) <= 1, abs(rowFrame.height - rect.height) <= 1 else { return nil }
            let measured = source.convert(source.bounds, to: table)
            let inset = measured.minY - rect.minY
            guard abs(inset - PbRadius.Metrics.spacing20) <= 2 || abs(inset - PbRadius.Metrics.spacing12) <= 2,
                  measured.intersects(visible) else { return nil }
            return (id, measured)
        }
        guard let first = candidates.min(by: { $0.1.minY < $1.1.minY }),
              let index = shownIDs.firstIndex(of: first.0) else { return nil }
        return ParallelVerticalAnchor(id: first.0, index: index, relativeOffset: first.1.minY - visible.minY)
    }
}

// MARK: - ActivityFeedReferenceRestoration

/// One irreversible reading-reference restoration lease. While open, a single captured native
/// anchor package owns the vertical position across the structural change that opened it: the
/// scroll observer asks the lease for an immediate target computed from the table's fresh
/// `rect(ofRow:)` plus the captured row's validated within-row inset, applied before the
/// observer reports. The lease can only complete or cancel — it is never replaced, rearmed or
/// re-captured by the rows/history/pagination/tail callbacks that join an open page
/// transaction, so a joining callback can never re-read an older anchor, and a cancelled lease
/// never re-arms.
///
/// Every captured reference is weak and re-verified on each use: a recycled row, a replaced
/// document or a vanished window fails the identity checks and the lease declines to correct
/// rather than targeting dead geometry.
@MainActor
final class ActivityFeedReferenceRestoration: ParallelScrollAnchorProvider {
    /// The captured native anchor package.
    private struct ReferencePackage {
        weak var source: ActivityRowGeometry.MeasurementView?
        weak var rowView: NSTableRowView?
        weak var document: NSView?
        let stableID: String
        let relativeOffset: CGFloat
        var inset: CGFloat
        let nativeIndex: Int
        let nativeCount: Int
        let viewportWidth: CGFloat
    }

    /// The expected native snapshot of the List the feed is about to construct, registered by
    /// the feed body before the List exists: the exact row count and anchor index the realized
    /// table must show for the native mapping to be valid.
    private struct ListCandidate {
        let generation: Int
        let expectedCount: Int
        let expectedAnchorIndex: Int?
        let expectedPadding: CGFloat?
    }

    private let measurements: ActivityRowMeasurements
    private var package: ReferencePackage?
    private var candidate: ListCandidate?
    private(set) var generation: Int
    private(set) var pageCommitted: Bool
    private(set) var appliedTarget: CGFloat?
    private(set) var appliedDocumentPair: ActivityDocumentSamplePair?
    private(set) var cancelled = false
    private(set) var finished = false
    var cancellationReconciled = false
    private var awaitsMeasuredResize = false

    var isActive: Bool { !cancelled && !finished }
    var isAnchorRestorationActive: Bool { isActive }
    var ownsNumericRestoration: Bool { isActive && !awaitsMeasuredResize && validateReferenceIdentity() }

    func deferToMeasuredResize() {
        awaitsMeasuredResize = true
        appliedTarget = nil
        appliedDocumentPair = nil
    }

    /// The captured package's anchor id — nil while the lease is unarmed.
    var stableID: String? { package?.stableID }
    /// True while the lease is waiting for its page publication to commit.
    var pagePending: Bool { !pageCommitted }

    init(measurements: ActivityRowMeasurements, generation: Int, awaitingPagePublication: Bool) {
        self.measurements = measurements
        self.generation = generation
        self.pageCommitted = !awaitingPagePublication
    }

    /// Captures the coherent pre-change anchor package: exactly one realized, unhidden
    /// measurement view carrying the anchor's stable id, its native row view, the current
    /// document, the within-row inset validated against the feed's two row paddings, and the
    /// native index and count. No eager realization (`makeIfNecessary: false`), no forced
    /// layout, no sizing or inset writes. A failed capture leaves the lease open but unarmed.
    @discardableResult
    func captureReference(anchor: ParallelVerticalAnchor, resolvedID: String,
                          nativeIdentity: ParallelScrollNativeIdentity, document: NSView?) -> Bool {
        guard let document, nativeIdentity.isCurrentDocument(document),
              let table = document as? NSTableView else { return false }
        let sources = measurements.views.allObjects.filter { $0.stableID == resolvedID }
        guard sources.count == 1, let source = sources.first,
              source.window != nil, !source.isHiddenOrHasHiddenAncestor else { return false }
        let row = table.row(for: source)
        guard row >= 0, let rowView = table.rowView(atRow: row, makeIfNecessary: false),
              source === rowView || source.isDescendant(of: rowView) else { return false }
        let rect = table.rect(ofRow: row)
        let rowFrame = rowView.convert(rowView.bounds, to: table)
        guard abs(rowFrame.minY - rect.minY) <= 1, abs(rowFrame.height - rect.height) <= 1 else { return false }
        let measured = source.convert(source.bounds, to: document)
        let inset = measured.minY - rect.minY
        // Only the feed's two row paddings are valid insets. A conversion taken mid-layout can
        // produce an incoherent (often negative) inset and must never arm the native correction.
        guard abs(inset - PbRadius.Metrics.spacing20) <= 2 || abs(inset - PbRadius.Metrics.spacing12) <= 2 else { return false }
        package = ReferencePackage(source: source, rowView: rowView, document: document, stableID: resolvedID,
                                   relativeOffset: anchor.relativeOffset, inset: inset,
                                   nativeIndex: row, nativeCount: table.numberOfRows,
                                   viewportWidth: source.enclosingScrollView?.contentView.bounds.width ?? 0)
        return true
    }

    /// A joining callback (rows, history, pagination, tail) keeps the lease and its captured
    /// anchor; only the measurement generation advances, so the newest body-registered
    /// candidate still gates the native mapping.
    func join(generation: Int) {
        self.generation = generation
    }

    /// Registers the expected native snapshot of the List the feed body is about to construct.
    /// Plain candidate data only — body evaluation can never open, rearm or complete a lease.
    func registerCandidate(generation: Int, expectedCount: Int, anchorIndex: Int?, expectedPadding: CGFloat? = nil) {
        candidate = ListCandidate(generation: generation, expectedCount: expectedCount, expectedAnchorIndex: anchorIndex,
                                  expectedPadding: expectedPadding)
    }

    /// Lost or recycled native identity permanently relinquishes native ownership. A candidate
    /// mismatch is different: it can be a pending List publication and never drops the package.
    private func validateReferenceIdentity() -> Bool {
        guard let captured = package else { return false }
        guard let source = captured.source, let table = captured.document as? NSTableView,
              source.window != nil, !source.isHiddenOrHasHiddenAncestor, source.stableID == captured.stableID,
              source.enclosingScrollView?.documentView === table,
              measurements.views.allObjects.filter({ $0.stableID == captured.stableID }).count == 1 else {
            package = nil; appliedTarget = nil; appliedDocumentPair = nil
            return false
        }
        let index = table.row(for: source)
        guard index >= 0, let row = table.rowView(atRow: index, makeIfNecessary: false),
              row === captured.rowView, source.isDescendant(of: row) else {
            package = nil; appliedTarget = nil; appliedDocumentPair = nil
            return false
        }
        return true
    }

    /// The page publication this lease was opened for has committed: the requested ids changed,
    /// or loading finished with an error or no further page.
    func markPageCommitted() {
        pageCommitted = true
    }

    func finish() {
        guard !cancelled else { return }
        finished = true
    }

    func matchesCurrentCandidate(document: NSView?) -> Bool {
        guard let table = document as? NSTableView, let candidate,
              candidate.generation == generation,
              candidate.expectedCount == table.numberOfRows else { return false }
        guard let captured = package else { return true }
        guard document === captured.document, let source = captured.source,
              source.stableID == captured.stableID else { return false }
        return candidate.expectedAnchorIndex == table.row(for: source)
    }

    // MARK: ParallelScrollAnchorProvider

    /// Irreversibly ends the lease: real user intent, a replaced, detached or disappeared
    /// native target. A cancelled lease declines every later correction and never re-arms.
    func cancelAnchorRestoration() {
        cancelled = true
    }

    /// The lease's immediate semantic vertical target for the given document, computed from the
    /// table's fresh `rect(ofRow:)` plus the captured row's validated inset — never from the
    /// stale descendant layout the measured frames still carry. Reserved for a pure prepend
    /// above the anchor (native index and count grow by the same delta) whose realized table
    /// matches the registered candidate exactly; resize, disclosure, shuffle, reuse and tail
    /// structural changes decline and wait for the coherent measured mapping. No arbitrary
    /// native relocation is ever inferred.
    func immediateAnchorTarget(document: NSView) -> CGFloat? {
        if let captured = package, document !== captured.document {
            package = nil; appliedTarget = nil; appliedDocumentPair = nil
        }
        guard isActive, validateReferenceIdentity(), let captured = package, document === captured.document,
              let source = captured.source, source.window != nil, !source.isHiddenOrHasHiddenAncestor,
              source.stableID == captured.stableID,
              !awaitsMeasuredResize,
              let table = document as? NSTableView else { return nil }
        // The stable id must still identify exactly one realized measurement view.
        let sources = measurements.views.allObjects.filter { $0.stableID == captured.stableID }
        guard sources.count == 1, sources.first === source else { return nil }
        let currentIndex = table.row(for: source)
        guard currentIndex >= 0,
              let rowView = table.rowView(atRow: currentIndex, makeIfNecessary: false),
              rowView === captured.rowView,
              source === rowView || source.isDescendant(of: rowView) else { return nil }
        let currentCount = table.numberOfRows
        guard let candidate, candidate.generation == generation,
              candidate.expectedCount == currentCount,
              candidate.expectedAnchorIndex == currentIndex else { return nil }
        let delta = currentCount - captured.nativeCount
        guard delta >= 0, currentIndex - captured.nativeIndex == delta else {
            // The intended snapshot has committed, but its mapping is not a prepend. Native
            // ownership cannot become valid later; release it to measured/proxy restoration.
            package = nil
            appliedTarget = nil
            appliedDocumentPair = nil
            return nil
        }
        let rect = table.rect(ofRow: currentIndex)
        // Adjust the expected padding only from a coherent measured conversion: a stale
        // descendant layout disagrees with the fresh native rect and must never produce an
        // inset.
        let measuredInset = source.convert(source.bounds, to: document).minY - rect.minY
        let rowFrame = rowView.convert(rowView.bounds, to: table)
        let rowIsCoherent = abs(rowFrame.minY - rect.minY) <= 1 && abs(rowFrame.height - rect.height) <= 1
            && abs(rowFrame.minX - rect.minX) <= 1 && abs(rowFrame.width - rect.width) <= 1
        if rowIsCoherent, let expectedPadding = candidate.expectedPadding,
           abs(measuredInset - expectedPadding) <= 2 {
            package?.inset = measuredInset
        }
        let target = max(0, rect.minY + (package?.inset ?? captured.inset) - captured.relativeOffset)
        appliedTarget = target
        appliedDocumentPair = ActivityDocumentSamplePair(documentHeight: document.bounds.height,
                                                        nativeRowCount: currentCount)
        return target
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
