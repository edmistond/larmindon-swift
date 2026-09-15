import SwiftUI

/// Measured scroll bounds, including any system insets. Content offset alone is not
/// enough to decide whether a short transcript fits or whether the reader is at the end.
struct CaptionScrollGeometry: Equatable {
    let contentOffsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentOffsetY = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        topInset = geometry.contentInsets.top
        bottomInset = geometry.contentInsets.bottom
    }

    var viewportHeight: CGFloat { max(0, containerHeight - topInset - bottomInset) }
    var offsetFromTop: CGFloat { contentOffsetY + topInset }
    var maximumOffset: CGFloat { max(0, contentHeight - viewportHeight) }
    var overflows: Bool { maximumOffset > 1 }
    var distanceFromBottom: CGFloat { max(0, maximumOffset - offsetFromTop) }
}

struct CaptionScrollRequest: Equatable {
    enum Target { case top, bottom }

    let target: Target
    let geometry: CaptionScrollGeometry
}

struct CaptionScrollState {
    private(set) var isPinnedToBottom = true
    private(set) var isUserScrolling = false
    private(set) var geometry: CaptionScrollGeometry?

    private let bottomTolerance: CGFloat = 28

    mutating func reset() {
        isPinnedToBottom = true
    }

    mutating func updateGeometry(_ newGeometry: CaptionScrollGeometry) {
        let oldGeometry = geometry
        geometry = newGeometry

        if !newGeometry.overflows || newGeometry.distanceFromBottom <= bottomTolerance {
            isPinnedToBottom = true
        } else if isUserScrolling, let oldGeometry,
                  newGeometry.offsetFromTop < oldGeometry.offsetFromTop - 1 {
            // Content growth, resize, and programmatic layout corrections must not
            // disengage following. Only the reader moving up does that.
            isPinnedToBottom = false
        }
    }

    mutating func updateInteraction(isUserScrolling: Bool, geometry: CaptionScrollGeometry) {
        // Process the final gesture geometry before ending the interaction.
        if isUserScrolling { self.isUserScrolling = true }
        updateGeometry(geometry)
        self.isUserScrolling = isUserScrolling
    }

    func request(isEmpty: Bool) -> CaptionScrollRequest? {
        guard !isUserScrolling, let geometry, geometry.viewportHeight > 0 else { return nil }

        if isEmpty || !geometry.overflows {
            guard abs(geometry.offsetFromTop) > 1 else { return nil }
            return CaptionScrollRequest(target: .top, geometry: geometry)
        }

        guard isPinnedToBottom,
              abs(geometry.maximumOffset - geometry.offsetFromTop) > 1 else { return nil }
        return CaptionScrollRequest(target: .bottom, geometry: geometry)
    }
}
