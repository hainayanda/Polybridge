import AppKit
import Combine
import MonitorCore
import SwiftUI

// MARK: - ParallelColumnUIState

/// Lightweight interaction state survives eviction of a conversation's activity view.
@Observable
@MainActor
final class ParallelColumnUIState {
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
    @ObservationIgnored var viewportPositioned = false
    @ObservationIgnored var activityMembers: Set<String> = []
    @ObservationIgnored var oldestSequences: [String: Int] = [:]
    @ObservationIgnored var paginationRevision = 0
    @ObservationIgnored var inventoryMembers: [String: TaskInfo] = [:]
    @ObservationIgnored var inventorySession: String?
    @ObservationIgnored var inventoryCursor: String?
    @ObservationIgnored var inventoryComplete = false
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
            guard let frame = frames[ids[middle]] else {
                return captureMeasured(ids: ids, frames: frames, viewportHeight: viewportHeight, offset: offset)
            }
            if frame.maxY <= offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower < ids.count, let frame = frames[ids[lower]],
              frame.minY < offset + viewportHeight else { return nil }
        return Self(id: ids[lower], index: lower, relativeOffset: frame.minY - offset)
    }

    private static func captureMeasured(ids: [String], frames: [String: CGRect], viewportHeight: CGFloat, offset: CGFloat) -> Self? {
        let visible = frames.filter { $0.value.maxY > offset && $0.value.minY < offset + viewportHeight }
        guard let first = visible.min(by: { $0.value.minY < $1.value.minY }),
              let index = ids.firstIndex(of: first.key) else { return nil }
        return Self(id: first.key, index: index, relativeOffset: first.value.minY - offset)
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
    var restorationActive = false
    var onViewportSize: ((CGSize) -> Void)?
    var onUpwardIntent: (() -> Void)?
    /// Scoped native identity (a List-backed feed's own NSScrollView, disclosed through PbUI's
    /// `.scrollChromeScope(onNativeScrollView:)` bounded marker-pair relay). When present the
    /// observation view attaches only to the identities this holder delivers — never to its own
    /// `enclosingScrollView` — and an explicit nil fails closed. Absent (the default), both the
    /// horizontal lane and every ScrollView-backed surface keep their exact prior behaviour.
    var nativeIdentity: ParallelScrollNativeIdentity?
    let onPosition: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ParallelScrollObservationView {
        let view = ParallelScrollObservationView()
        updateNSView(view, context: context)
        return view
    }

    static func dismantleNSView(_ view: ParallelScrollObservationView, coordinator: ()) {
        view.bindNativeIdentity(nil)
        view.teardownObservation()
    }

    func updateNSView(_ view: ParallelScrollObservationView, context: Context) {
        view.usesNativeIdentity = nativeIdentity != nil
        view.axis = axis
        view.onPosition = onPosition
        view.onViewportSize = onViewportSize
        view.onUpwardIntent = onUpwardIntent
        view.updateWheelMonitor()
        view.configure(ids: columnIDs, stride: columnStride, restorationOffset: restorationOffset, restorationActive: restorationActive)
        view.bindNativeIdentity(nativeIdentity)
    }
}

// MARK: - ParallelScrollNativeIdentity

/// Main-actor holder wiring one scoped container's disclosed native scroll identity to this
/// observer's observation view — the bounded path a List-backed feed needs: its own NSScrollView
/// is not reachable as the representable's `enclosingScrollView` (the observation view must sit
/// outside the marker pair, and inside a virtualized row it would die with the row), so the
/// identity comes from PbUI's strict marker-pair discovery instead.
///
/// The holder never defers on its own: the scope relay's single generation-guarded main-queue
/// delivery is the only asynchrony, so an unmounted or replaced observation view is exactly a
/// weak miss — no stale attach callback can reach a dead view. Registration re-delivers the last
/// known identity so a queued restoration survives the observation view's own initial mount, and
/// an explicit nil detaches the observation view's native notifications and wheel monitor — fail
/// closed, never a fallback to any enclosing scroll view.
@MainActor
final class ParallelScrollNativeIdentity {
    private weak var observationView: ParallelScrollObservationView?
    /// The last identity the scope relay delivered — weak, so a scoped scroll view that
    /// deallocated reads as nil on the observation view's next registration.
    private weak var knownScrollView: NSScrollView?
    private weak var knownDocument: NSView?

    /// Registers the observation view — also re-registering it after a representable remount —
    /// and immediately delivers the last known identity, so a scroll view disclosed before the
    /// observation view mounted still attaches once it exists.
    func register(_ view: ParallelScrollObservationView) {
        observationView = view
        view.adoptNativeIdentity(knownScrollView)
    }

    /// Releases the observation view at representable dismantle; the dying view detaches its own
    /// subscriptions and wheel monitor.
    func unregister(_ view: ParallelScrollObservationView) {
        guard observationView === view else { return }
        observationView = nil
    }

    /// The scope relay's delivery point: pushes the disclosed identity straight to the weakly
    /// held observation view — direct adoption that bypasses `configure`'s unchanged-input early
    /// return, so a discovered or replaced target attaches and reports even when nothing else
    /// changed.
    @discardableResult
    func deliver(_ scrollView: NSScrollView?) -> Bool {
        let changed = knownScrollView !== scrollView || knownDocument !== scrollView?.documentView
        knownScrollView = scrollView
        knownDocument = scrollView?.documentView
        observationView?.adoptNativeIdentity(scrollView)
        return changed
    }

    /// Identity matching for cached native measurements: whether the document view a sample was
    /// measured in is the one the scoped relay currently discloses. A sample that fails this
    /// check belongs to a replaced (or already deallocated) native target and must be rejected,
    /// never scaled onto a new viewport.
    func isCurrentDocument(_ document: NSView?) -> Bool {
        guard let document else { return false }
        return knownScrollView?.documentView === document
    }
}

// MARK: - ParallelScrollObservationView

final class ParallelScrollObservationView: NSView {
    private weak var nativeIdentityOwner: ParallelScrollNativeIdentity?
    private var isTornDown = false

    /// Transfer registration when the representable changes holders; preserve the old holder's
    /// last scoped identity for an observer-only remount.
    func bindNativeIdentity(_ holder: ParallelScrollNativeIdentity?) {
        guard nativeIdentityOwner !== holder else { return }
        nativeIdentityOwner?.unregister(self)
        if nativeIdentityOwner != nil { detachNativeTarget() }
        nativeIdentityOwner = holder
        holder?.register(self)
    }

    var axis = ParallelScrollObserver.Axis.horizontal
    var onPosition: ((CGFloat, CGFloat, CGFloat) -> Void)?
    var onViewportSize: ((CGSize) -> Void)?
    var onUpwardIntent: (() -> Void)?
    private var wheelMonitor: Any?
    private var liveUserScroll = false
    private weak var observedScrollView: NSScrollView?
    /// The document currently observed; a scroll view can replace it without changing identity.
    private weak var observedDocument: NSView?
    private var subscriptions = Set<AnyCancellable>()
    private var documentSubscription: AnyCancellable?
    private var ids: [String] = []
    private var stride: CGFloat = 0
    private var pendingOffset: CGFloat?
    private var applyingRestoration = false
    private var requestedOffset: CGFloat?
    private var restorationActive = false
    private var configuredAxis: ParallelScrollObserver.Axis?
    private var pendingPositionAcknowledgement = false
    private var lastOffset: CGFloat = 0
    private var lastReported: CGRect?
    private var lastViewportSize: CGSize?
    /// True when a scoped native identity (`nativeIdentity`) owns attachment: the observation
    /// view then never attaches through its own `enclosingScrollView` — including never to an
    /// enclosing horizontal lane — and every attach/detach comes from `adoptNativeIdentity`.
    var usesNativeIdentity = false
    /// The most recently delivered scoped identity, kept even while it cannot attach yet (a
    /// native document view that has not laid out): the bounded lifecycle events re-attempt it.
    private weak var nativeTarget: NSScrollView?
    /// The borrowed insets state of the currently adopted native target, restored on replacement
    /// or detach while the target is still on a window.
    private var nativeInsetBackup: NativeInsetBackup?

    /// The inset state this observer explicitly zeroes on an adopted native target so the feed's
    /// document keeps plain zero scroll-view content insets — see `enforceNativeInsets(on:)`.
    private struct NativeInsetBackup {
        weak var scrollView: NSScrollView?
        var automaticallyAdjusts: Bool
        var insets: NSEdgeInsets
    }

    /// Direct push from the scoped identity holder — bypasses `configure`'s unchanged-input early
    /// return, so a discovered or replaced List scroll view attaches and reports even when no
    /// configure input changed. An explicit nil detaches the native notifications and wheel
    /// monitor and fails closed; a repeated identical target only reports.
    func adoptNativeIdentity(_ scrollView: NSScrollView?) {
        guard usesNativeIdentity, !isTornDown else { return }
        nativeTarget = scrollView
        applyNativeIdentity(scrollView)
    }

    /// The bounded lifecycle retry: window and superview moves (and configure's deferred block)
    /// re-attempt the native adoption, or fall back to the enclosing-scroll attachment for every
    /// default observer, whose behaviour is unchanged.
    private func reattach() {
        guard !isTornDown else { return }
        if usesNativeIdentity { applyNativeIdentity(nativeTarget) } else { attach() }
    }

    /// An unchanged target reports; document replacement rebinds frame observation while
    /// preserving insets, wheel monitoring, live gestures and pending restoration.
    /// A temporarily absent document drops only its frame subscription for lifecycle retry.
    /// A different scroll view fully detaches the previous target; nil fails closed.
    private func applyNativeIdentity(_ scrollView: NSScrollView?) {
        guard let scrollView else {
            if observedScrollView != nil { detachNativeTarget() }
            return
        }
        if scrollView === observedScrollView {
            let document = scrollView.documentView
            if document !== observedDocument {
                if document != nil {
                    attachDocumentNotifications(for: document)
                    lastReported = nil
                    report()
                } else {
                    documentSubscription = nil
                    observedDocument = nil
                }
            } else {
                report()
            }
            return
        }
        detachNativeTarget()
        guard scrollView.documentView != nil else { return }
        observedScrollView = scrollView
        enforceNativeInsets(on: scrollView)
        attachNotifications(for: scrollView)
        updateWheelMonitor()
        report()
    }

    /// Detaches the currently adopted native target's notifications, wheel monitor and borrowed
    /// insets. The queued restoration state (`requestedOffset`/`pendingOffset`) deliberately
    /// survives — replacement and initial attachment must still land a pending restoration.
    private func detachNativeTarget() {
        subscriptions.removeAll()
        documentSubscription = nil
        removeWheelMonitor()
        liveUserScroll = false
        restoreNativeInsets()
        observedScrollView = nil
        observedDocument = nil
        lastReported = nil
    }

    /// Full release at representable dismantle: notifications, wheel monitor and any borrowed
    /// native insets go with the observation view.
    func teardownObservation() {
        isTornDown = true
        liveUserScroll = false
        subscriptions.removeAll()
        documentSubscription = nil
        removeWheelMonitor()
        restoreNativeInsets()
        observedScrollView = nil
        observedDocument = nil
    }

    /// A List-backed feed owns its document's vertical spacing (row padding and explicit gap
    /// logic inside row content), so the adopted native target's scroll-view insets are
    /// explicitly owned: automatic native adjustment is disabled and the insets zeroed on
    /// adoption and re-asserted on every report — keeping this observer's geometry in plain
    /// document coordinates across later resize and layout passes. The pre-adoption state is
    /// captured once per target and restored while the target still has a window.
    ///
    /// Leave native table spacing and sizing to SwiftUI. Mutating them during scroll reports
    /// can repeatedly change row heights and cause visible oscillation on first mount.
    private func enforceNativeInsets(on scroll: NSScrollView) {
        if nativeInsetBackup?.scrollView !== scroll {
            nativeInsetBackup = NativeInsetBackup(
                scrollView: scroll,
                automaticallyAdjusts: scroll.automaticallyAdjustsContentInsets,
                insets: scroll.contentInsets
            )
        }
        if scroll.automaticallyAdjustsContentInsets { scroll.automaticallyAdjustsContentInsets = false }
        let insets = scroll.contentInsets
        if insets.top != 0 || insets.left != 0 || insets.bottom != 0 || insets.right != 0 {
            scroll.contentInsets = NSEdgeInsetsZero
        }
    }

    /// Restores the borrowed insets of the last adopted target, capturing nothing new; an
    /// off-window target is released without writes, mirroring the shared chrome owner's rule.
    private func restoreNativeInsets() {
        guard let backup = nativeInsetBackup else { return }
        nativeInsetBackup = nil
        guard let scroll = backup.scrollView, scroll.window != nil else { return }
        scroll.automaticallyAdjustsContentInsets = backup.automaticallyAdjusts
        scroll.contentInsets = backup.insets
    }

    func configure(ids: [String], stride: CGFloat, restorationOffset: CGFloat?, restorationActive: Bool) {
        let geometryChanged = configuredAxis != axis || ids != self.ids || stride != self.stride
        guard geometryChanged || restorationOffset != requestedOffset || restorationActive != self.restorationActive else { return }
        if !restorationActive { pendingPositionAcknowledgement = false }
        if restorationActive, restorationOffset != nil,
           restorationOffset != requestedOffset || restorationActive != self.restorationActive {
            pendingPositionAcknowledgement = true
        }
        configuredAxis = axis
        self.restorationActive = restorationActive
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
        DispatchQueue.main.async { [weak self] in self?.reattach(); self?.report() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            liveUserScroll = false
            subscriptions.removeAll()
            documentSubscription = nil
            removeWheelMonitor()
            restoreNativeInsets()
            observedScrollView = nil
            observedDocument = nil
            lastReported = nil
            lastViewportSize = nil
        } else { DispatchQueue.main.async { [weak self] in self?.reattach() } }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.reattach() }
    }

    private func attach() {
        // Native-identity mode never attaches through `enclosingScrollView` — that would reach
        // an outer lane or canvas, not the scoped List's own scroll view.
        guard !usesNativeIdentity, window != nil, let scroll = enclosingScrollView, scroll !== observedScrollView,
              scroll.documentView != nil else { return }
        subscriptions.removeAll()
        documentSubscription = nil
        removeWheelMonitor()
        observedScrollView = scroll
        updateWheelMonitor()
        attachNotifications(for: scroll)
        report()
    }

    /// Subscribes the native bounds/frame notifications of one adopted scroll view and its
    /// document — the shared body of both attachment paths — and records the subscribed
    /// document so a same-scroll replacement can be detected later.
    private func attachNotifications(for scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        subscriptions.removeAll()
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scroll.contentView),
            (NSView.frameDidChangeNotification, scroll.contentView)
        ] {
            NotificationCenter.default
                .publisher(for: name, object: object)
                .sink { [weak self] _ in self?.report(observeExternalMovement: name == NSView.boundsDidChangeNotification) }
                .store(in: &subscriptions)
        }
        if usesNativeIdentity {
            NotificationCenter.default
    .publisher(for: NSScrollView.willStartLiveScrollNotification, object: scroll)
                .sink { [weak self] _ in self?.liveUserScroll = true }
                .store(in: &subscriptions)
            NotificationCenter.default
    .publisher(for: NSScrollView.didEndLiveScrollNotification, object: scroll)
                .sink { [weak self] _ in self?.liveUserScroll = false }
                .store(in: &subscriptions)
        }
        attachDocumentNotifications(for: document)
    }

    /// Moves only the document frame observer; scroll and live-gesture notifications survive
    /// a same-scroll document replacement, including a temporary nil document.
    private func attachDocumentNotifications(for document: NSView?) {
        documentSubscription = nil
        observedDocument = document
        guard let document else { return }
        document.postsFrameChangedNotifications = true
        documentSubscription = NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: document)
            .sink { [weak self] _ in self?.report() }
    }

    func updateWheelMonitor() {
        guard onUpwardIntent != nil, observedScrollView?.window != nil else {
            removeWheelMonitor()
            return
        }
        guard wheelMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = usesNativeIdentity
            ? [.scrollWheel, .keyDown, .leftMouseDown] : .scrollWheel
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            if event.type == .scrollWheel {
                self?.observeWheelIntent(event)
            } else {
                self?.observeNativeNavigationIntent(event)
            }
            return event
        }
    }

    func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    private func observeWheelIntent(_ event: NSEvent) {
        guard axis == .vertical, let scroll = observedScrollView, event.window === scroll.window,
              scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)),
              event.scrollingDeltaY > 0, event.momentumPhase.isEmpty,
              event.phase.isEmpty || event.phase.contains(.began) else { return }
        signalUpwardIntent()
    }

    /// Native List navigation signals apply only to this scoped scroll view and never consume
    /// the event. Keyboard navigation must originate from its own first responder subtree.
    private func observeNativeNavigationIntent(_ event: NSEvent) {
        guard usesNativeIdentity, !isTornDown, axis == .vertical,
              let scroll = observedScrollView, event.window === scroll.window else { return }
        switch event.type {
        case .keyDown:
            guard let responder = scroll.window?.firstResponder as? NSView,
                  responder === scroll || responder.isDescendant(of: scroll),
                  let character = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
                  [UInt32(NSUpArrowFunctionKey), UInt32(NSPageUpFunctionKey), UInt32(NSHomeFunctionKey)].contains(character)
            else { return }
            signalUpwardIntent()
        case .leftMouseDown:
            guard let scroller = scroll.verticalScroller,
                  scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil)) else { return }
            let part = scroller.testPart(event.locationInWindow)
            if part == .decrementLine || part == .decrementPage { signalUpwardIntent() }
        default: break
        }
    }

    private func signalUpwardIntent() {
        if usesNativeIdentity {
            pendingOffset = nil
            requestedOffset = nil
            restorationActive = false
        }
        onUpwardIntent?()
    }

    /// Observe an upward reading move before a queued layout restoration can replace it.
    /// Content shrinkage and viewport resizing remain layout changes, not user scroll evidence.
    private func observeExternalUpwardScroll(visible: CGRect, document: NSView, length: CGFloat, viewport: CGFloat) {
        let offset = document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
        if usesNativeIdentity, liveUserScroll, offset < lastOffset - 0.5 { signalUpwardIntent() }
        guard axis == .vertical, let lastReported, offset < lastOffset - 0.5,
              abs(length - lastReported.width) < 0.5, viewport == lastReported.height else { return }
        pendingOffset = nil
        requestedOffset = nil
        lastOffset = offset
        self.lastReported = CGRect(x: offset, y: 0, width: length, height: viewport)
        onPosition?(offset, length, viewport)
    }

    private func report(observeExternalMovement: Bool = false) {
        guard !isTornDown, let scroll = observedScrollView, let document = scroll.documentView else { return }
        // Native targets re-assert the zero-inset contract on every report, so a later resize or
        // layout pass that restores an automatic inset cannot shift the feed's document geometry.
        if usesNativeIdentity { enforceNativeInsets(on: scroll) }
        let visible = scroll.documentVisibleRect
        let viewportSize = scroll.contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            onViewportSize?(viewportSize)
        }
        let length = axis == .horizontal ? document.bounds.width : document.bounds.height
        let viewport = axis == .horizontal ? viewportSize.width : viewportSize.height
        // A queued layout report can precede the bounds notification for a user move.
        if observeExternalMovement || liveUserScroll, !applyingRestoration {
            observeExternalUpwardScroll(visible: visible, document: document, length: length, viewport: viewport)
        }
        let horizontalLayoutReady = axis != .horizontal || abs(length - CGFloat(ids.count) * stride) < 2
        if restorationActive, pendingOffset == nil, let requestedOffset { pendingOffset = requestedOffset }
        if let pendingOffset, viewport > 0, horizontalLayoutReady {
            self.pendingOffset = nil
            let target = min(max(0, pendingOffset), max(0, length - viewport))
            var point = scroll.contentView.bounds.origin
            if axis == .horizontal { point.x = target } else { point.y = document.isFlipped ? target : max(0, document.bounds.maxY - viewport - target) }
            if abs((axis == .horizontal ? point.x : point.y) - (axis == .horizontal ? visible.minX : visible.minY)) > 0.5 {
                applyingRestoration = true
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
                applyingRestoration = false
            }
        }
        let updated = scroll.documentVisibleRect
        lastOffset = axis == .horizontal ? updated.minX : (document.isFlipped ? updated.minY : document.bounds.maxY - updated.maxY)
        let report = CGRect(x: lastOffset, y: 0, width: length, height: viewport)
        let acknowledgesRestoration = pendingPositionAcknowledgement && viewport > 0 && horizontalLayoutReady && pendingOffset == nil
        if acknowledgesRestoration { pendingPositionAcknowledgement = false }
        if report != lastReported || acknowledgesRestoration {
            lastReported = report
            onPosition?(lastOffset, length, viewport)
        }
    }
}
