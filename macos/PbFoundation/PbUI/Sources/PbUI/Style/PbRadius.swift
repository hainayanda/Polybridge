import SwiftUI

// MARK: - PbRadius

/// The Monitor's corner radii and design-derived component dimensions (SPEC §3/§5). Views pick a
/// radius or a metric from here instead of writing a numeric size literal, so a dimension change
/// happens in one place.
public enum PbRadius {
    /// Cards, stat tiles, node cards, activity cards.
    public static let card: CGFloat = 12
    /// List rows, selection highlights, grouped-row containers' inner rows.
    public static let row: CGFloat = 8
    /// Buttons and fields.
    public static let button: CGFloat = 8
    /// Inspector, canvas frame, lane cards, sheets' panels.
    public static let panel: CGFloat = 16
    /// Sheets.
    public static let sheet: CGFloat = 20

    /// Shared component dimensions the design derives once: heights, paddings, glyph sizes and
    /// strokes. Component and screen dimensions belong in named tokens, never view literals.
    public enum Metrics {
        /// Foundation diagnostics and component preview canvases.
        public static let foundationWidth: CGFloat = 1000
        public static let foundationHeight: CGFloat = 780
        public static let foundationPixelWidth = 2000
        public static let foundationPixelHeight = 1560
        public static let foundationSampleStride = 17
        public static let activityPreviewWidth: CGFloat = 320
        public static let formPreviewWidth: CGFloat = 300
        public static let toolbarPreviewWidth: CGFloat = 900
        public static let toolbarPreviewHeight: CGFloat = 500
        /// Shared layout steps, including unpadded compositional containers.
        public static let zero: CGFloat = 0
        public static let spacing2: CGFloat = 2
        public static let spacing4: CGFloat = 4
        public static let spacing5: CGFloat = 5
        public static let spacing6: CGFloat = 6
        public static let spacing8: CGFloat = 8
        public static let spacing10: CGFloat = 10
        public static let spacing12: CGFloat = 12
        public static let spacing14: CGFloat = 14
        public static let spacing16: CGFloat = 16
        public static let spacing20: CGFloat = 20
        /// Compact native form-control button target and value width.
        public static let compactControlHeight: CGFloat = 24
        public static let compactValueWidth: CGFloat = 28
        /// The standalone spinner's size and ring width.
        public static let spinnerSize: CGFloat = 14
        public static let spinnerStroke: CGFloat = 2
        /// The status badge capsule (§5.1): its height, horizontal padding and icon glyph.
        public static let badgeHeight: CGFloat = 24
        public static let badgeHorizontalPadding: CGFloat = 10
        public static let badgeGlyphSize: CGFloat = 12
        /// The sidebar status icon's square frame (§5.1).
        public static let statusIconSize: CGFloat = 16
        /// Primary and tinted buttons (§5.3): capsule height and horizontal paddings.
        public static let primaryButtonHeight: CGFloat = 30
        public static let primaryButtonHorizontalPadding: CGFloat = 16
        public static let secondaryButtonHorizontalPadding: CGFloat = 14
        /// Grouped form rows (§5.5): container radius, row height and horizontal paddings.
        public static let formRadius: CGFloat = 10
        public static let formRowHeight: CGFloat = 36
        public static let formRowLeadingPadding: CGFloat = 12
        public static let formRowTrailingPadding: CGFloat = 10
        /// Activity cards (§5.4): padded-card and row paddings, the row icon's glyph, hairlines.
        public static let cardPaddingVertical: CGFloat = 10
        public static let cardPaddingHorizontal: CGFloat = 14
        public static let activityRowPaddingVertical: CGFloat = 10
        public static let activityRowPaddingHorizontal: CGFloat = 14
        public static let activityIconSize: CGFloat = 15
        public static let hairlineStroke: CGFloat = 1
        /// The sliding segmented control (§5.6): track/thumb radii, height and the thumb's shadow.
        public static let segmentedTrackRadius: CGFloat = 10
        public static let segmentedThumbRadius: CGFloat = 7
        public static let segmentedHeight: CGFloat = 32
        public static let segmentedShadowRadius: CGFloat = 1
        /// The backend identity dot and its overlapping stack (§5.2).
        public static let backendDotSize: CGFloat = 8
        public static let backendDotStackSize: CGFloat = 10
        public static let backendDotStackOverlap: CGFloat = 0.3
        public static let backendDotStackStroke: CGFloat = 1.5
        /// The shared row's own geometry (§6.1's consumers keep it as their default): the
        /// vertical padding, the title-to-meta gap, the item gap, the chevron's square frame and
        /// the tree gutter's default column.
        public static let rowPaddingVertical: CGFloat = 6
        public static let rowLineSpacing: CGFloat = 3
        public static let rowItemSpacing: CGFloat = 8
        public static let rowChevronFrame: CGFloat = 16
        public static let treeGutterColumnWidth: CGFloat = 16
        /// The sidebar's own row treatment (§6.1): the 15 pt status glyph frame, the 7 pt row
        /// padding over the 8 pt row insets, the 20 pt child-guide column, the filter's compact
        /// dots, the group's 3 pt progress strip and the footer's connection dot.
        public static let sidebarStatusIconSize: CGFloat = 15
        public static let sidebarRowPaddingVertical: CGFloat = 7
        public static let sidebarRowInsetHorizontal: CGFloat = 8
        public static let sidebarChildGuideWidth: CGFloat = 20
        public static let sidebarFilterDotSize: CGFloat = 7
        public static let sidebarProgressHeight: CGFloat = 3
        public static let sidebarConnectionDotSize: CGFloat = 7
        /// Sidebar control adaptation and preview canvases.
        public static let sidebarSearchMinimumWidth: CGFloat = 120
        public static let sidebarPreviewWidth: CGFloat = 272
        public static let sidebarPreviewHeight: CGFloat = 600
        public static let sidebarCompactPreviewHeight: CGFloat = 400
        public static let sidebarHistoryMinimumHeight: CGFloat = 20
        public static let groupPreviewWidth: CGFloat = 280
        public static let sidebarTallFixtureHeight: CGFloat = 800
    }
}
