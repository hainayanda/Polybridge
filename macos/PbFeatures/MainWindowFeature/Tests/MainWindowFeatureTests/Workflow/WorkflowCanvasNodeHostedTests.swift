import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowCanvasNodeHostedTests

@MainActor @Suite(.serialized) struct WorkflowCanvasNodeHostedTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenVeryLongModel_whenActualCanvasNodeRenders_thenMetadataStaysOnOneLineWithoutCoveringPortsOrDetail(appearance: ColorScheme) async throws {
        // given
        let model = String(repeating: "provider/very-long-unlisted-model-name-", count: 15)
        let node = WorkflowNodeModel(raw: ["id": .string("model-node"), "title": .string("Long model step"),
                                          "type": .string("agent"), "role": .string("task"),
                                          "position": .object(["x": .number(50), "y": .number(50)]),
                                          "agent": .object(["backend": .string("codex"), "model": .string(model)])])
        let fixture = RedesignHost(
            WorkflowCanvas(nodes: [node], edges: [], selectedNodeID: nil, selectedEdgeID: nil, isEditable: false,
                           status: { _ in "completed" }, attempt: { _ in 0 }, onSelectNode: { _ in }, onSelectEdge: { _ in },
                           onMove: { _, _ in }, onConnect: { _ in }, onDrop: { _, _ in })
                .preferredColorScheme(appearance), size: CGSize(width: 400, height: 300)
        )
        defer { fixture.close() }
        await fixture.settle { fixture.element("Input to Long model step") != nil && fixture.element(model) != nil }

        // when
        let probe = try #require(fixture.descendants.compactMap { $0 as? WorkflowCanvasScrollProbe }.first)
        let logicalFrame = probe.convert(CGRect(origin: node.position, size: WorkflowCanvasGeometry.size(node)), to: nil)
        let metadata = try #require(fixture.element(model))
        let metadataFrame = try #require(fixture.frame(metadata))
        let input = try #require(fixture.element("Input to Long model step"))
        let output = try #require(fixture.element("Connect from Long model step"))
        let inputFrame = try #require(fixture.frame(input))
        let outputFrame = try #require(fixture.frame(output))
        let detail = try #require(fixture.element("Done"))
        let detailFrame = try #require(fixture.frame(detail))

        // then
        #expect(logicalFrame.size == CGSize(width: 200, height: 92))
        #expect(metadataFrame.width > 0 && metadataFrame.height <= PbRadius.Metrics.workflowNodeIconTileSize)
        #expect(logicalFrame.insetBy(dx: -1, dy: -1).contains(metadataFrame))
        #expect(metadataFrame.minX >= inputFrame.midX + WorkflowCanvasGeometry.portOuterRadius)
        #expect(metadataFrame.maxX <= outputFrame.midX - WorkflowCanvasGeometry.portOuterRadius)
        #expect(!metadataFrame.intersects(detailFrame), "Model metadata must not cover the retained node detail")
        #expect(fixture.string(metadata, "accessibilityHelp") == model, "The complete truncated model remains available in help")
    }
}
