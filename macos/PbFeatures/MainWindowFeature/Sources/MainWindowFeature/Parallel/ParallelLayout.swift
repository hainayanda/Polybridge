import Foundation

// MARK: - ParallelLayout

/// The column-width rule (Monitor piece 12, Design point 3): columns fill the available width rather
/// than a fixed 900pt budget, so there is no empty band on the right when the window is wide — with a
/// 420pt reading-width floor, below which columns keep their old fixed width and the row scrolls horizontally
/// instead of squeezing further. A pure function so it is testable without a SwiftUI rendering
/// harness.
enum ParallelLayout {
    /// The width of the hairline `Divider` drawn after every column (`ParallelView`'s `ForEach`) —
    /// subtracted from `availableWidth` before dividing, so `memberCount` columns plus their dividers
    /// together account for the whole row rather than overflowing it by a few points.
    static let dividerWidth: CGFloat = 1
    static let minimumColumnWidth: CGFloat = 420

    static func columnWidth(memberCount: Int, availableWidth: CGFloat) -> CGFloat {
        let count = max(1, memberCount)
        let usableWidth = max(0, availableWidth - CGFloat(count) * dividerWidth)
        return max(minimumColumnWidth, usableWidth / CGFloat(count))
    }
}
