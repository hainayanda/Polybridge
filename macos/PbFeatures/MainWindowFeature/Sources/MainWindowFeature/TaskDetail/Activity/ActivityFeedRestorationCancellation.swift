import SwiftUI

extension ActivityFeedView {
    func pauseLayoutFollowingForUserIntent() {
        guard state.followLive.isFollowing else { return }
        state.followLive.suspend()
        followingLayout = false
        if state.retainedFirstID == nil { state.retainedFirstID = shown.first?.id }
        targetOffset = nil
        if position.referenceRestoration == nil { cancelNumericRestoration() }
        else { position.pendingReadingCapture = true }
    }

    func restorationCancelled(_ context: ParallelScrollRestorationCancellation) -> Int? {
        guard nativeIdentity.isCurrentBinding(observer: context.observer, scrollView: context.scrollView) else { return nil }
        let acceptedGeneration = restorationGeneration
        if !context.isUpward, state.followLive.isFollowing {
            targetOffset = nil
            restorationGeneration &+= 1
            followingLayout = true
            return acceptedGeneration
        }
        if context.isUpward { pauseLayoutFollowingForUserIntent() }
        // The reference lease reconciles cancellation and pending-page ownership itself.
        guard position.referenceRestoration == nil else { return acceptedGeneration }
        cancelNumericRestoration()
        return acceptedGeneration
    }

    func cancelNumericRestoration() {
        targetOffset = nil
        restoring = false
        position.pagingTask?.cancel()
        position.pagingTask = nil
        restorationWidth.clear()
        position.pendingReadingCapture = true
        position.cancelledSinceBegin = true
        state.viewportPositioned = false
    }

    @discardableResult
    func captureCancelledReadingPosition() -> Bool {
        guard let offset = position.nativeReadingOffset,
              let anchor = position.captureNativeReadingAnchor(shownIDs: shown.map(\.id), nativeIdentity: nativeIdentity) else { return false }
        position.offset = offset
        state.scrollOffset = offset
        state.anchor = anchor
        position.pendingReadingCapture = false
        positioned = true
        return true
    }
}
