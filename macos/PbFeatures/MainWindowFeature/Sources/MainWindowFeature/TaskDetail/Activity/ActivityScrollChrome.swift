//
//  ActivityScrollChrome.swift
//  MainWindowFeature
//
//  The user-authorized Phase 4 amendment: thinner, auto-hiding native scrollbars on ALL three
//  activity feeds (Task detail, Parallel lanes, Workflow activity), which share
//  `ActivityFeedView` — implemented once here. Public NSScrollView/NSScroller API only: the feed's
//  own enclosing vertical scroll view gets the native overlay style, a small scroller control
//  size and native auto-hiding while any feed is attached; the last detach restores the chrome it
//  captured. No custom scrollbar, no width or colour invention, no permanently hidden indicators,
//  and production never flashes them.
//
//  Lifecycle rules (approved amendment): one MainActor owner per scroll view lives in a weak-key
//  AND weak-value registry, capturing the original chrome once and counting independently
//  identified attachment tokens — an overlapping attach never re-captures an already-owned overlay
//  as the original, and a detach never restores while another owner remains. Each attachment
//  strongly retains its owner while active; the registry and the notification closure hold both
//  the owner and the scroll view weakly. ONE presentation-only
//  `NSScroller.preferredScrollerStyleDidChangeNotification` subscription per owned scroll view reasserts
//  overlay after AppKit's own native handling and is removed on the last detach. Restores are
//  skipped entirely when the scroll view has no window: no visible consumer exists and teardown
//  reflow must not mutate a retained feed before its sibling observer detaches — ownership and
//  the subscription are still released. Restoration after that is best-effort from a new owner's
//  captured state, not a promise that the historical legacy chrome returns.
//
//  Chrome fields this touches — and nothing else: `scrollerStyle`, `autohidesScrollers` and the
//  vertical scroller's `controlSize`. Scroller enablement, the document and content views, scroll
//  observers, viewport/restoration callbacks, identity, follow-live, leases and paging are all
//  owned elsewhere and unchanged.
//

import AppKit
import Combine
import PbUI
import SwiftUI

// MARK: - ActivityScrollChromeToken

/// Identifies one attachment. It strongly retains its owner while the attached representable
/// view holds it, so the owner outlives exactly its active attachments and nothing else.
struct ActivityScrollChromeToken: Equatable {
    let owner: ActivityScrollChromeOwner
    let id: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner === rhs.owner && lhs.id == rhs.id
    }
}

// MARK: - ActivityScrollChromeOwner

/// The single MainActor owner of one feed scroll view's thin chrome: it records the original
/// chrome once, applies the overlay/small/autohiding presentation while attached, reasserts
/// overlay after a system preference change, and restores on the last detach.
@MainActor
final class ActivityScrollChromeOwner {
    /// The chrome captured at first attach, before any write.
    struct OriginalChrome: Equatable {
        let scrollerStyle: NSScroller.Style
        let autohidesScrollers: Bool
        let verticalControlSize: NSControl.ControlSize
        let horizontalControlSize: NSControl.ControlSize
    }

    private(set) weak var scrollView: NSScrollView?
    private var original: OriginalChrome?
    private var activeTokenIDs = Set<Int>()
    private var nextTokenID = 0
    /// A system preference notification arrived while this owner held the scroll view — the
    /// final restore then writes the CURRENT preferred style, never the stale captured one.
    private var preferenceChanged = false
    private var notificationCancellable: AnyCancellable?

    /// Applies the thin chrome to `scrollView`, creating the owner if none owns it yet.
    static func attach(to scrollView: NSScrollView) -> ActivityScrollChromeToken {
        let owner = ActivityScrollChromeRegistry.registry.object(forKey: scrollView)
            ?? {
                let owner = ActivityScrollChromeOwner(scrollView: scrollView)
                ActivityScrollChromeRegistry.registry.setObject(owner, forKey: scrollView)
                return owner
            }()
        return owner.attach()
    }

    /// Releases one attachment; the last one restores the scroll view and removes the registry
    /// entry and the notification subscription.
    static func detach(_ token: ActivityScrollChromeToken) {
        token.owner.detach(tokenID: token.id)
    }

    private init(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    private func attach() -> ActivityScrollChromeToken {
        if original == nil, let scrollView {
            // The FIRST owner captures the original chrome before writing anything; an overlapping
            // attach finds this owner in the registry and never captures the overlay as original.
            original = OriginalChrome(
                scrollerStyle: scrollView.scrollerStyle,
                autohidesScrollers: scrollView.autohidesScrollers,
                verticalControlSize: scrollView.verticalScroller?.controlSize ?? .regular,
                horizontalControlSize: scrollView.horizontalScroller?.controlSize ?? .regular
            )
        }
        nextTokenID += 1
        let token = ActivityScrollChromeToken(owner: self, id: nextTokenID)
        activeTokenIDs.insert(token.id)
        applyChrome()
        subscribeIfNeeded()
        return token
    }

    private func detach(tokenID: Int) {
        guard activeTokenIDs.remove(tokenID) != nil else { return }
        guard activeTokenIDs.isEmpty else { return }
        // Release ownership first: another owner (or a reparenting attach) never sees this owner
        // as the current chrome's captor once its last attachment is gone.
        notificationCancellable?.cancel()
        notificationCancellable = nil
        if let scrollView, let original {
            if scrollView.window != nil {
                restoreChrome(on: scrollView, original: original)
            } else {
                // No visible consumer: skip the restore WRITES, release everything. A later
                // re-attach captures the then-current chrome as its original — best-effort by
                // design, never a promise the historical legacy chrome returns.
            }
        }
        if let scrollView { ActivityScrollChromeRegistry.registry.removeObject(forKey: scrollView) }
        scrollView = nil
        original = nil
        preferenceChanged = false
    }

    /// The thin chrome itself. Guarded assignments: an already-overlay attachment or an
    /// equality-identical update writes nothing.
    fileprivate func applyChrome() {
        guard !activeTokenIDs.isEmpty, let scrollView else { return }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        if scrollView.verticalScroller?.controlSize != .small { scrollView.verticalScroller?.controlSize = .small }
    }

    private func restoreChrome(on scrollView: NSScrollView, original: OriginalChrome) {
        // After a preference change, AppKit has already restyled the scroll view to the user's
        // new preferred style — restore THAT, not the stale captured one.
        let style = preferenceChanged ? NSScroller.preferredScrollerStyle : original.scrollerStyle
        if scrollView.scrollerStyle == .overlay, scrollView.scrollerStyle != style { scrollView.scrollerStyle = style }
        if scrollView.autohidesScrollers, scrollView.autohidesScrollers != original.autohidesScrollers {
            scrollView.autohidesScrollers = original.autohidesScrollers
        }
        if scrollView.verticalScroller?.controlSize == .small,
           scrollView.verticalScroller?.controlSize != original.verticalControlSize {
            scrollView.verticalScroller?.controlSize = original.verticalControlSize
        }
    }

    /// ONE subscription per owned scroll view, removed on the last detach or deallocation; its
    /// closure holds this owner weakly and reasserts only while an attachment still exists.
    private func subscribeIfNeeded() {
        guard notificationCancellable == nil else { return }
        notificationCancellable = NotificationCenter.default
            .publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !activeTokenIDs.isEmpty else { return }
                // AppKit has already applied the new preferred style natively (NSScrollView.h);
                // this owner's feeds asked for overlay, so reassert it — scheduled on the main
                // actor, weakly owned, and only while this owner still holds attachments.
                preferenceChanged = true
                applyChrome()
            }
    }
}

// MARK: - ActivityScrollChrome

/// Attaches the thin native chrome to the feed's own enclosing vertical scroll view. Placed
/// inside the feed's document, so it can only ever target that scroll view — never an outer
/// horizontal lane, a workflow canvas or an inspector.
struct ActivityScrollChrome: NSViewRepresentable {
    /// Holds this representable's attachment token — the strong "each attachment retains its
    /// owner while active" link — and outlives the NSView across SwiftUI updates.
    @MainActor
    final class Coordinator {
        var token: ActivityScrollChromeToken?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ActivityScrollChromeView {
        let view = ActivityScrollChromeView()
        view.setAccessibilityElement(false)
        view.onHierarchyChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view, let coordinator else { return }
            Self.sync(view: view, coordinator: coordinator)
        }
        // Prefer synchronous attachment: the chrome lands before the feed's scroll observer
        // asynchronously reports its first viewport, without changing that observer.
        Self.sync(view: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: ActivityScrollChromeView, context: Context) {
        Self.sync(view: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: ActivityScrollChromeView, coordinator: Coordinator) {
        view.onHierarchyChange = nil
        if let token = coordinator.token {
            ActivityScrollChromeOwner.detach(token)
            coordinator.token = nil
        }
    }

    /// The single attach/dismantle decision point, always on the main actor: attach to the
    /// current enclosing vertical scroll view, detach from a previous one on reparent (restoring
    /// it before attaching to the new one), and release when the view has left its window.
    @MainActor
    private static func sync(view: ActivityScrollChromeView, coordinator: Coordinator) {
        guard view.window != nil, let scroll = view.enclosingScrollView, scroll.hasVerticalScroller else {
            // Off-window or outside a vertical scroll view: teardown. When the scroll view's own
            // window is gone too, the owner skips the restore writes by design.
            if let token = coordinator.token {
                ActivityScrollChromeOwner.detach(token)
                coordinator.token = nil
            }
            return
        }
        if let token = coordinator.token, token.owner.scrollView === scroll {
            token.owner.applyChrome()
            return
        }
        if let token = coordinator.token {
            ActivityScrollChromeOwner.detach(token)
            coordinator.token = nil
        }
        coordinator.token = ActivityScrollChromeOwner.attach(to: scroll)
    }
}

// MARK: - ActivityScrollChromeRegistry

/// The weak-key AND weak-value owner registry. Entries are removed explicitly on the last
/// detach — never lazily purged.
enum ActivityScrollChromeRegistry {
    @MainActor static let registry = NSMapTable<NSScrollView, ActivityScrollChromeOwner>.weakToWeakObjects()
}

// MARK: - ActivityScrollChromeView

/// A zero-footprint, noninteractive attachment point: it never becomes an accessibility element,
/// never accepts first responder, and only reports its own mount changes to the representable's
/// main-actor coordinator — all ownership lives there.
final class ActivityScrollChromeView: NSView {
    /// Set by the representable; called on the main thread for every move to a window or a new
    /// superview, exactly the events that can change the enclosing scroll view.
    var onHierarchyChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onHierarchyChange?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onHierarchyChange?()
    }
}

#if DEBUG
/// Overflowing dummy data — the thin chrome only shows itself while scrolling.
private struct ActivityScrollChromePreview: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PbRadius.Metrics.spacing20) {
                ForEach(PreviewFixtures.sampleRows(taskID: "chrome-preview")) { row in
                    TimelineRow(model: TimelineRowModel(item: PreviewFixtures.textItem(
                        "Scroll me — the indicator fades at rest. Row \(row.id)."
                    ), start: row.timestamp, live: false, showsPromptBubble: false))
                }
            }
            .padding(PbRadius.Metrics.spacing16)
            .background(ActivityScrollChrome())
        }
        .frame(width: PbRadius.Metrics.activityPreviewWidth * 2, height: PbRadius.Metrics.foundationHeight / 2)
        .background(Color.windowBG)
    }
}

#Preview("ActivityScrollChrome - light") {
    ActivityScrollChromePreview().preferredColorScheme(.light)
}

#Preview("ActivityScrollChrome - dark") {
    ActivityScrollChromePreview().preferredColorScheme(.dark)
}
#endif
