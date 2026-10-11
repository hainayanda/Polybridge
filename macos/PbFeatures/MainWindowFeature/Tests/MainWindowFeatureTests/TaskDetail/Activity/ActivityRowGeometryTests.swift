import AppKit
@testable import MainWindowFeature
import Testing

@MainActor @Suite(.serialized) struct ActivityRowGeometryTests {
    @Test func givenUnchangedFrameAndWidth_whenDocumentPairChanges_thenMeasureNowReportsFreshPair() throws {
        _ = NSApplication.shared
        let harness = try GeometryHarness(rowCount: 3)
        defer { harness.close() }
        var samples: [ActivityRowFrameSample] = []
        harness.measurement.onFrame = { samples.append($0) }

        harness.measurement.measureNow()
        let first = try #require(samples.last)
        #expect(samples.count == 1)
        #expect(first.nativeRowCount == 3)
        let initialHeight = first.documentHeight

        // Keep the realized row's frame and the viewport width unchanged. A List publication
        // still changes the document height and native row count, which must advance the pair.
        harness.table.install(rowCount: 5)
        harness.measurement.measureNow()
        let second = try #require(samples.last)
        #expect(samples.count == 2)
        #expect(second.frame == first.frame)
        #expect(second.viewportWidth == first.viewportWidth)
        #expect(second.documentHeight > initialHeight)
        #expect(second.nativeRowCount == 5)

        harness.measurement.measureNow()
        #expect(samples.count == 2)
    }

    @Test func givenPreviouslyMeasuredView_whenInvalidated_thenMeasureNowReportsAgain() throws {
        _ = NSApplication.shared
        let harness = try GeometryHarness(rowCount: 3)
        defer { harness.close() }
        var samples: [ActivityRowFrameSample] = []
        harness.measurement.onFrame = { samples.append($0) }

        harness.measurement.measureNow()
        #expect(samples.count == 1)
        harness.measurement.invalidateMeasurement()
        harness.measurement.measureNow()

        #expect(samples.count == 2)
        #expect(samples[1].frame == samples[0].frame)
        #expect(samples[1].documentHeight == samples[0].documentHeight)
        #expect(samples[1].nativeRowCount == samples[0].nativeRowCount)
    }
}

@MainActor
private final class GeometryHarness {
    let window: NSWindow
    let scroll: NSScrollView
    let table: GeometryTable
    let measurement: ActivityRowGeometry.MeasurementView

    init(rowCount: Int) throws {
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        self.table = GeometryTable()
        table.frame = NSRect(x: 0, y: 0, width: 420, height: CGFloat(rowCount * 100))
        self.measurement = ActivityRowGeometry.MeasurementView(frame: NSRect(x: 0, y: 20, width: 420, height: 60))
        table.install(rowCount: rowCount)
        table.addSubview(measurement)
        scroll.documentView = table
        window.contentView = scroll
        window.orderFront(nil)
        window.layoutIfNeeded()
        try #require(measurement.window != nil)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class GeometryTable: NSTableView {
    private(set) var rowCount = 0

    func install(rowCount: Int) {
        self.rowCount = rowCount
        frame.size.height = CGFloat(rowCount * 100)
    }

    override var numberOfRows: Int { rowCount }
}
