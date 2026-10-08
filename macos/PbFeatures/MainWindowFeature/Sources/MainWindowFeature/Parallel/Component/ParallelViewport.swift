import AppKit
import Combine
import SwiftUI

// MARK: - ParallelColumnUIState

/// Lightweight interaction state survives eviction of a conversation's activity view.
@Observable
@MainActor
final class ParallelColumnUIState {
    var showAll = false
    var expandedGroups: Set<String> = []
    @ObservationIgnored private var followState = FollowLiveScrollState()
    private var followsLive = true
    var followLive: FollowLiveScrollState {
        get { _ = followsLive; return followState }
        set {
            followState = newValue
            if followsLive != newValue.isFollowing { followsLive = newValue.isFollowing }
        }
    }

    var retainedFirstID: String?
    var recentFirstID: String?
    @ObservationIgnored var anchor: ParallelVerticalAnchor?
    @ObservationIgnored var scrollOffset: CGFloat = 0
}

// MARK: - ParallelVerticalAnchor

struct ParallelVerticalAnchor: Equatable {
    let id: String
    let index: Int
    let relativeOffset: CGFloat

    static func capture(ids: [String], frames: [String: CGRect], viewportHeight: CGFloat, offset: CGFloat = 0) -> Self? {
        var lower = 0
        var upper = ids.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            guard let frame = frames[ids[middle]] else { return nil }
            if frame.maxY <= offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower < ids.count, let frame = frames[ids[lower]],
              frame.minY < offset + viewportHeight else { return nil }
        return Self(id: ids[lower], index: lower, relativeOffset: frame.minY - offset)
    }

    func offset(in frame: CGRect) -> CGFloat {
        // Reflow can shorten a row past its saved intra-row reading position.
        // Keep that row visible rather than restoring an offset inside its successor.
        max(0, frame.minY - max(relativeOffset, -max(0, frame.height - 1)))
    }

    func resolvedID(in ids: [String]) -> String? {
        if ids.contains(id) { return id }
        guard !ids.isEmpty else { return nil }
        return ids[min(index, ids.count - 1)]
    }
}

// MARK: - ParallelHorizontalAnchor

struct ParallelHorizontalAnchor: Equatable {
    let id: String
    let index: Int
    let relativeOffset: CGFloat
    let previousIDs: [String]

    static func capture(ids: [String], stride: CGFloat, offset: CGFloat) -> Self? {
        guard !ids.isEmpty, stride > 0 else { return nil }
        let index = min(ids.count - 1, max(0, Int(floor(max(0, offset) / stride))))
        return Self(id: ids[index], index: index, relativeOffset: offset - CGFloat(index) * stride, previousIDs: ids)
    }

    func offset(ids: [String], stride: CGFloat) -> CGFloat {
        guard !ids.isEmpty else { return 0 }
        let positions = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var position = positions[id]
        if position == nil {
            for distance in 1 ... max(1, previousIDs.count) {
                let next = index + distance
                let previous = index - distance
                if next < previousIDs.count, let survivor = positions[previousIDs[next]] { position = survivor; break }
                if previous >= 0, let survivor = positions[previousIDs[previous]] { position = survivor; break }
            }
        }
        return CGFloat(position ?? min(index, ids.count - 1)) * stride + min(relativeOffset, max(0, stride - 1))
    }
}

// MARK: - ParallelScrollObserver

/// Native observation also covers scrollbar and keyboard movement on macOS 14.
struct ParallelScrollObserver: NSViewRepresentable {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    var columnIDs: [String] = []
    var columnStride: CGFloat = 0
    var restorationOffset: CGFloat?
    var onViewportSize: ((CGSize) -> Void)?
    let onPosition: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ParallelScrollObservationView {
        let view = ParallelScrollObservationView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ParallelScrollObservationView, context: Context) {
        view.axis = axis
        view.onPosition = onPosition
        view.onViewportSize = onViewportSize
        view.configure(ids: columnIDs, stride: columnStride, restorationOffset: restorationOffset)
    }
}

// MARK: - ParallelScrollObservationView

final class ParallelScrollObservationView: NSView {
    var axis = ParallelScrollObserver.Axis.horizontal
    var onPosition: ((CGFloat, CGFloat, CGFloat) -> Void)?
    var onViewportSize: ((CGSize) -> Void)?
    private weak var observedScrollView: NSScrollView?
    private var subscriptions = Set<AnyCancellable>()
    private var ids: [String] = []
    private var stride: CGFloat = 0
    private var pendingOffset: CGFloat?
    private var requestedOffset: CGFloat?
    private var lastOffset: CGFloat = 0
    private var lastReported: CGRect?
    private var lastViewportSize: CGSize?

    func configure(ids: [String], stride: CGFloat, restorationOffset: CGFloat?) {
        if axis == .horizontal, ids != self.ids || stride != self.stride,
           let anchor = ParallelHorizontalAnchor.capture(ids: self.ids, stride: self.stride, offset: lastOffset) {
            pendingOffset = anchor.offset(ids: ids, stride: stride)
        }
        self.ids = ids
        self.stride = stride
        if restorationOffset != requestedOffset {
            requestedOffset = restorationOffset
            if let restorationOffset { pendingOffset = restorationOffset } else if axis == .vertical { pendingOffset = nil }
        }
        DispatchQueue.main.async { [weak self] in self?.attach(); self?.report() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            subscriptions.removeAll()
            observedScrollView = nil
            lastReported = nil
            lastViewportSize = nil
        } else { DispatchQueue.main.async { [weak self] in self?.attach() } }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard window != nil, let scroll = enclosingScrollView, scroll !== observedScrollView,
              let document = scroll.documentView else { return }
        subscriptions.removeAll()
        observedScrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scroll.contentView),
            (NSView.frameDidChangeNotification, document)
        ] {
            NotificationCenter.default
.publisher(for: name, object: object)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.report() }
                .store(in: &subscriptions)
        }
        report()
    }

    private func report() {
        guard let scroll = observedScrollView, let document = scroll.documentView else { return }
        let visible = scroll.documentVisibleRect
        if visible.size != lastViewportSize {
            lastViewportSize = visible.size
            onViewportSize?(visible.size)
        }
        let length = axis == .horizontal ? document.bounds.width : document.bounds.height
        let viewport = axis == .horizontal ? visible.width : visible.height
        let horizontalLayoutReady = axis != .horizontal || abs(length - CGFloat(ids.count) * stride) < 2
        if let pendingOffset, viewport > 0, horizontalLayoutReady {
            self.pendingOffset = nil
            let target = min(max(0, pendingOffset), max(0, length - viewport))
            var point = scroll.contentView.bounds.origin
            if axis == .horizontal { point.x = target } else { point.y = document.isFlipped ? target : max(0, document.bounds.maxY - viewport - target) }
            if abs((axis == .horizontal ? point.x : point.y) - (axis == .horizontal ? visible.minX : visible.minY)) > 0.5 {
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let updated = scroll.documentVisibleRect
        lastOffset = axis == .horizontal ? updated.minX : (document.isFlipped ? updated.minY : document.bounds.maxY - updated.maxY)
        let report = CGRect(x: lastOffset, y: 0, width: length, height: viewport)
        if report != lastReported {
            lastReported = report
            onPosition?(lastOffset, length, viewport)
        }
    }
}
