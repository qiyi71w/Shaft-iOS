import SwiftUI
import UIKit

/// A crossing triggers once; content loading and initially resting at the top
/// don't vibrate. Re-arms only after moving back into the scrollable content.
struct ScrollEdgeState {
    private(set) var previous: Int?
    mutating func crossed(offset: Double, content: Double, viewport: Double) -> Bool {
        guard content > viewport + 1 else { previous = nil; return false }
        let edge = offset <= 0.5 ? -1 : offset >= content - viewport - 0.5 ? 1 : 0
        defer { previous = edge }
        guard let previous else { return false }
        return edge != 0 && previous == 0
    }
}

private struct ScrollEdgeFeedback: ViewModifier {
    @State private var state = ScrollEdgeState()
    @State private var settings = AppSettingsStore.shared
    @State private var interacting = false
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in interacting = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: ScrollEdgeGeometry.self) { geometry in
                ScrollEdgeGeometry(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                   content: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                   viewport: geometry.containerSize.height)
            } action: { _, geometry in
                let crossed = state.crossed(offset: geometry.offset, content: geometry.content, viewport: geometry.viewport)
                if crossed && interacting && settings.scrollEdgeHapticEnable { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5) }
            }
        } else {
            content
        }
    }
}

private struct ScrollEdgeGeometry: Equatable {
    let offset: Double
    let content: Double
    let viewport: Double
}

extension View {
    func scrollEdgeFeedback() -> some View { modifier(ScrollEdgeFeedback()) }
}

private struct IllustScrollPosition: ViewModifier {
    @State private var position: Int64?
    func body(content: Content) -> some View {
        content.scrollPosition(id: $position, anchor: .top)
    }
}
extension View {
    func preserveIllustScrollPosition() -> some View { modifier(IllustScrollPosition()) }
}

/// iOS 17 stand-in for the `ScrollGeometry` fields callers read.
struct ScrollMetrics {
    let contentOffset: CGPoint
    let contentSize: CGSize
    let contentInsets: EdgeInsets
    let containerSize: CGSize
}

extension View {
    /// `onScrollGeometryChange` is iOS 18+. On iOS 17 the action never fires,
    /// so callers keep their initial state.
    @ViewBuilder
    func onScrollMetricsChange<T: Equatable>(
        for type: T.Type,
        of transform: @escaping (ScrollMetrics) -> T,
        action: @escaping (_ oldValue: T, _ newValue: T) -> Void
    ) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: type, of: { geometry in
                transform(ScrollMetrics(contentOffset: geometry.contentOffset,
                                        contentSize: geometry.contentSize,
                                        contentInsets: geometry.contentInsets,
                                        containerSize: geometry.containerSize))
            }, action: action)
        } else {
            self
        }
    }
}
