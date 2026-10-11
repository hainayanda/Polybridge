import AppKit
@testable import MainWindowFeature
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedReferenceRestorationTests {
    @Test func givenOpenReference_whenCancelled_thenJoiningAndCandidateRegistrationCannotRearmIt() {
        let measurements = ActivityRowMeasurements()
        let reference = ActivityFeedReferenceRestoration(measurements: measurements, generation: 4,
                                                         awaitingPagePublication: true)

        #expect(reference.isActive)
        #expect(reference.pagePending)
        reference.cancelAnchorRestoration()
        reference.join(generation: 5)
        reference.registerCandidate(generation: 5, expectedCount: 8, anchorIndex: 3)

        #expect(reference.cancelled)
        #expect(!reference.isActive)
        #expect(reference.immediateAnchorTarget(document: NSView()) == nil)
        #expect(reference.appliedTarget == nil)
    }

    @Test func givenCapturedAnchor_whenCandidateMatchesPrependDeltaAndNativeIdentity_thenFreshNativeTargetIsApplied() throws {
        let harness = try ReferenceTableHarness(rowCount: 3, anchorIndex: 1)
        defer { harness.close() }
        let measurements = ActivityRowMeasurements()
        measurements.views.add(harness.measurement)
        let identity = ParallelScrollNativeIdentity()
        identity.deliver(harness.scroll)
        let reference = ActivityFeedReferenceRestoration(measurements: measurements, generation: 7,
                                                         awaitingPagePublication: true)
        let anchor = ParallelVerticalAnchor(id: "anchor", index: 1, relativeOffset: 18)

        try #require(reference.captureReference(anchor: anchor, resolvedID: "anchor",
                                                nativeIdentity: identity, document: harness.table))
        harness.setAnchor(index: 3, rowCount: 5)
        reference.registerCandidate(generation: 7, expectedCount: 5, anchorIndex: 3)

        let target = reference.immediateAnchorTarget(document: harness.table)
        #expect(target != nil)
        #expect(reference.appliedTarget == target)
        #expect(reference.appliedDocumentPair == ActivityDocumentSamplePair(documentHeight: harness.table.bounds.height,
                                                                              nativeRowCount: 5))
        #expect(reference.pagePending)
    }

    @Test func givenCapturedAnchor_whenCandidateIndexOrCountDoesNotMatch_thenNativeTargetIsRejected() throws {
        let harness = try ReferenceTableHarness(rowCount: 3, anchorIndex: 1)
        defer { harness.close() }
        let measurements = ActivityRowMeasurements()
        measurements.views.add(harness.measurement)
        let identity = ParallelScrollNativeIdentity()
        identity.deliver(harness.scroll)
        let reference = ActivityFeedReferenceRestoration(measurements: measurements, generation: 8,
                                                         awaitingPagePublication: true)
        let anchor = ParallelVerticalAnchor(id: "anchor", index: 1, relativeOffset: 18)
        try #require(reference.captureReference(anchor: anchor, resolvedID: "anchor",
                                                nativeIdentity: identity, document: harness.table))
        harness.setAnchor(index: 3, rowCount: 5)

        reference.registerCandidate(generation: 8, expectedCount: 5, anchorIndex: 2)
        #expect(reference.immediateAnchorTarget(document: harness.table) == nil)
        reference.registerCandidate(generation: 8, expectedCount: 6, anchorIndex: 3)
        #expect(reference.immediateAnchorTarget(document: harness.table) == nil)
    }

    @Test func givenAppliedPrepend_whenCandidateMatchesTailGrowth_thenNativeOwnershipIsRelinquished() throws {
        let harness = try ReferenceTableHarness(rowCount: 3, anchorIndex: 1)
        defer { harness.close() }
        let measurements = ActivityRowMeasurements()
        measurements.views.add(harness.measurement)
        let identity = ParallelScrollNativeIdentity()
        identity.deliver(harness.scroll)
        let reference = ActivityFeedReferenceRestoration(measurements: measurements, generation: 10,
                                                         awaitingPagePublication: true)
        let anchor = ParallelVerticalAnchor(id: "anchor", index: 1, relativeOffset: 18)
        try #require(reference.captureReference(anchor: anchor, resolvedID: "anchor",
                                                nativeIdentity: identity, document: harness.table))
        harness.setAnchor(index: 3, rowCount: 5)
        reference.registerCandidate(generation: 10, expectedCount: 5, anchorIndex: 3)
        try #require(reference.immediateAnchorTarget(document: harness.table) != nil)

        // A later row was appended below the retained row. The List snapshot is coherent, but
        // this is no longer a pure prepend, so the lease must hand numeric ownership back.
        harness.setAnchor(index: 3, rowCount: 6)
        reference.registerCandidate(generation: 10, expectedCount: 6, anchorIndex: 3)
        #expect(reference.immediateAnchorTarget(document: harness.table) == nil)
        #expect(!reference.ownsNumericRestoration)
        #expect(reference.appliedTarget == nil)
    }

    @Test func givenCapturedAnchor_whenMeasurementIsDuplicatedOrDocumentReplaced_thenCaptureAndTargetAreRejected() throws {
        let harness = try ReferenceTableHarness(rowCount: 3, anchorIndex: 1)
        defer { harness.close() }
        let measurements = ActivityRowMeasurements()
        measurements.views.add(harness.measurement)
        let identity = ParallelScrollNativeIdentity()
        identity.deliver(harness.scroll)
        let anchor = ParallelVerticalAnchor(id: "anchor", index: 1, relativeOffset: 18)
        let duplicate = ActivityRowGeometry.MeasurementView(frame: harness.measurement.frame)
        duplicate.stableID = "anchor"
        harness.anchorRow.addSubview(duplicate)
        measurements.views.add(duplicate)
        let duplicateReference = ActivityFeedReferenceRestoration(measurements: measurements, generation: 9,
                                                                  awaitingPagePublication: true)
        #expect(!duplicateReference.captureReference(anchor: anchor, resolvedID: "anchor",
                                                     nativeIdentity: identity, document: harness.table))

        measurements.views.remove(duplicate)
        let reference = ActivityFeedReferenceRestoration(measurements: measurements, generation: 9,
                                                         awaitingPagePublication: true)
        try #require(reference.captureReference(anchor: anchor, resolvedID: "anchor",
                                                nativeIdentity: identity, document: harness.table))
        harness.setAnchor(index: 3, rowCount: 5)
        reference.registerCandidate(generation: 9, expectedCount: 5, anchorIndex: 3)
        let replacement = NSScrollView(frame: harness.scroll.frame)
        let replacementTable = ReferenceTable()
        replacement.documentView = replacementTable
        identity.deliver(replacement)
        #expect(reference.immediateAnchorTarget(document: replacementTable) == nil)
    }

}

@MainActor
private final class ReferenceTableHarness {
    let window: NSWindow
    let scroll: NSScrollView
    let table: ReferenceTable
    let anchorRow: NSTableRowView
    let measurement: ActivityRowGeometry.MeasurementView

    init(rowCount: Int, anchorIndex: Int) throws {
        _ = NSApplication.shared
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        self.table = ReferenceTable()
        self.anchorRow = NSTableRowView(frame: NSRect(x: 0, y: CGFloat(anchorIndex * 100), width: 420, height: 100))
        self.measurement = ActivityRowGeometry.MeasurementView(frame: NSRect(x: 0, y: 20, width: 420, height: 60))
        measurement.stableID = "anchor"
        anchorRow.addSubview(measurement)
        table.installAnchorRow(anchorRow, index: anchorIndex, count: rowCount)
        scroll.documentView = table
        window.contentView = scroll
        window.orderFront(nil)
        window.layoutIfNeeded()
        try #require(measurement.window != nil)
    }

    func setAnchor(index: Int, rowCount: Int) {
        table.installAnchorRow(anchorRow, index: index, count: rowCount)
        measurement.frame.origin.y = 20
        table.frame.size.height = CGFloat(rowCount * 100)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class ReferenceTable: NSTableView {
    private var rowCount = 0
    private var anchorIndex = -1
    private var anchorRow: NSTableRowView?

    func installAnchorRow(_ row: NSTableRowView, index: Int, count: Int) {
        rowCount = count
        anchorIndex = index
        anchorRow = row
        row.frame.origin.y = CGFloat(index * 100)
        if row.superview !== self { addSubview(row) }
    }

    override var numberOfRows: Int { rowCount }

    override func row(for view: NSView) -> Int {
        if let anchorRow, view === anchorRow || view.isDescendant(of: anchorRow) { return anchorIndex }
        return -1
    }

    override func rowView(atRow row: Int, makeIfNecessary: Bool) -> NSTableRowView? {
        row == anchorIndex ? anchorRow : nil
    }

    override func rect(ofRow row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row * 100), width: bounds.width, height: 100)
    }
}
