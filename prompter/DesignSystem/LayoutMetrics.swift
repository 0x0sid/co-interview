import SwiftUI

/// Spacing, padding and control sizes for Home and Settings, in two sets: **regular** for ordinary
/// iPhones and **compact** for small ones (SE-size, minis, anything short or narrow in portrait).
///
/// One place for these numbers, so a screen asks for `metrics.cardPadding` instead of hard-coding 14.
/// Compact mode tightens space before it touches readability: text sizes change little; padding,
/// gaps, control heights and previews change most. Tap targets never go below 44 points.
struct LayoutMetrics: Equatable, Sendable {
    /// Outer margin of a scrolling screen.
    var screenPadding: CGFloat
    /// Gap between major blocks on a screen.
    var sectionSpacing: CGFloat
    /// Padding inside a card.
    var cardPadding: CGFloat
    /// Gap between lines inside a card.
    var cardSpacing: CGFloat
    var cardCornerRadius: CGFloat
    /// The screen's one primary action (Start interview).
    var primaryControlHeight: CGFloat
    /// A button inside a card (Download, Upgrade to Pro, Renew). Visual height; the hit area is ≥ 44.
    var cardControlHeight: CGFloat
    /// Vertical padding of a saved-interview card, and the gap between cards.
    var listCardVerticalPadding: CGFloat
    var listCardSpacing: CGFloat
    /// The sheet header (title and Done).
    var headerHeight: CGFloat
    /// The answer-size preview in Settings.
    var previewMaxHeight: CGFloat
    /// Title sizes.
    var cardTitleSize: CGFloat
    var bodySize: CGFloat
    var footnoteSize: CGFloat
    let isCompact: Bool

    static let regular = LayoutMetrics(
        screenPadding: 20, sectionSpacing: 16, cardPadding: 14, cardSpacing: 8, cardCornerRadius: 14,
        primaryControlHeight: 50, cardControlHeight: 44, listCardVerticalPadding: 11, listCardSpacing: 8,
        headerHeight: 52, previewMaxHeight: 76, cardTitleSize: 17, bodySize: 14, footnoteSize: 12, isCompact: false)

    static let compact = LayoutMetrics(
        screenPadding: 16, sectionSpacing: 12, cardPadding: 12, cardSpacing: 6, cardCornerRadius: 12,
        primaryControlHeight: 46, cardControlHeight: 40, listCardVerticalPadding: 9, listCardSpacing: 6,
        headerHeight: 44, previewMaxHeight: 52, cardTitleSize: 16, bodySize: 13, footnoteSize: 11, isCompact: true)

    /// Compact when the window is short (SE: 667 pt tall) or narrow (≤ 375 pt wide).
    static func forSize(_ size: CGSize) -> LayoutMetrics {
        guard size.width > 0, size.height > 0 else { return .regular }
        return size.height < 700 || size.width < 380 ? .compact : .regular
    }
}

private struct LayoutMetricsKey: EnvironmentKey {
    static let defaultValue = LayoutMetrics.regular
}

extension EnvironmentValues {
    var layoutMetrics: LayoutMetrics {
        get { self[LayoutMetricsKey.self] }
        set { self[LayoutMetricsKey.self] = newValue }
    }
}

extension View {
    /// Measures the window once and hands the matching metrics to everything below — sheets included.
    func adaptiveLayoutMetrics() -> some View { modifier(AdaptiveLayoutMetrics()) }
}

private struct AdaptiveLayoutMetrics: ViewModifier {
    @State private var metrics = LayoutMetrics.regular

    func body(content: Content) -> some View {
        content
            .environment(\.layoutMetrics, metrics)
            .onGeometryChange(for: CGSize.self) { proxy in
                // The whole window, not the safe area's inner frame.
                CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                       height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            } action: { size in
                metrics = LayoutMetrics.forSize(size)
            }
    }
}

/// The filled button inside a card (Download, Renew, Upgrade to Pro): exactly
/// `metrics.cardControlHeight` tall — the system's bordered styles add their own padding on top — with
/// a hit area of at least 44 points.
struct CardPrimaryButtonStyle: ButtonStyle {
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(metrics.bodySize + 2, weight: .semibold))
            .foregroundStyle(Theme.Color.onDark)
            .frame(maxWidth: .infinity, minHeight: metrics.cardControlHeight)
            .background(Theme.Color.action.opacity(isEnabled ? 1 : 0.45),
                        in: RoundedRectangle(cornerRadius: metrics.cardControlHeight / 2, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
