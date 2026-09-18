import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Shared by caption rendering and the follow policy, so decorative spacing is never
/// mistaken for unread text. The tolerance is one system-font line plus its line gap.
struct CaptionLayoutMetrics {
    let fontSize: CGFloat

    var verticalPadding: CGFloat { 24 }
    var lineSpacing: CGFloat { fontSize * 0.16 }
    var utteranceSpacing: CGFloat { fontSize * 0.5 }
    var speakerBlockSpacing: CGFloat { fontSize * 0.6 }
    var trailingPadding: CGFloat { verticalPadding + speakerBlockSpacing }

    var lineAdvance: CGFloat {
        #if os(iOS)
        UIFont.systemFont(ofSize: fontSize).lineHeight + lineSpacing
        #else
        let font = NSFont.systemFont(ofSize: fontSize)
        return font.ascender - font.descender + font.leading + lineSpacing
        #endif
    }
}

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
    var clampedOffset: CGFloat { min(maximumOffset, max(0, offsetFromTop)) }

    func hasSameLayout(as other: Self) -> Bool {
        contentHeight == other.contentHeight && containerHeight == other.containerHeight
            && topInset == other.topInset && bottomInset == other.bottomInset
    }
}

struct CaptionScrollRequest: Equatable {
    enum Target { case top, bottom }

    let target: Target
    let geometry: CaptionScrollGeometry
}

struct CaptionScrollState {
    private(set) var isPinnedToBottom = true
    private(set) var phase: ScrollPhase = .idle
    private(set) var geometry: CaptionScrollGeometry?
    private var metrics: CaptionLayoutMetrics
    private var lineTolerance: CGFloat
    private var furthestDragOffset: CGFloat?
    private var directionalDragTravel: CGFloat = 0
    private var isCoastingUp = false

    init(fontSize: Double = 34) {
        metrics = CaptionLayoutMetrics(fontSize: CGFloat(fontSize))
        lineTolerance = metrics.lineAdvance
    }

    var isUserScrolling: Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    mutating func reset() {
        isPinnedToBottom = true
        furthestDragOffset = nil
        directionalDragTravel = 0
        isCoastingUp = false
    }

    mutating func updateGeometry(_ newGeometry: CaptionScrollGeometry, fontSize: Double? = nil) {
        // Update the font and measured layout together; a new tolerance applied to the
        // previous font's shorter content could accidentally pull a reader out of history.
        let fontChanged = fontSize.map { CGFloat($0) != metrics.fontSize } ?? false
        if fontChanged, let fontSize {
            metrics = CaptionLayoutMetrics(fontSize: CGFloat(fontSize))
            lineTolerance = metrics.lineAdvance
            furthestDragOffset = nil
        }
        let oldGeometry = geometry
        geometry = newGeometry

        var deliberatelyMovedUp = false
        if phase == .interacting || (phase == .decelerating && isCoastingUp) {
            if !fontChanged, let oldGeometry, newGeometry.hasSameLayout(as: oldGeometry) {
                if phase == .interacting {
                    let movement = newGeometry.clampedOffset - oldGeometry.clampedOffset
                    if movement < 0 {
                        directionalDragTravel = min(0, directionalDragTravel) + movement
                    } else if movement > 0 {
                        directionalDragTravel = max(0, directionalDragTravel) + movement
                    }
                }
                let furthest = max(furthestDragOffset ?? oldGeometry.clampedOffset, newGeometry.clampedOffset)
                furthestDragOffset = furthest
                deliberatelyMovedUp = newGeometry.clampedOffset < furthest - 1
            } else {
                // Reflow can change both height and offset while a finger is down.
                // Start measuring the drag again in the new layout's coordinates.
                furthestDragOffset = newGeometry.clampedOffset
            }
        }

        let distanceFromLatestText = max(0, newGeometry.distanceFromBottom - metrics.trailingPadding)
        if !newGeometry.overflows || distanceFromLatestText <= lineTolerance {
            if !isPinnedToBottom { isCoastingUp = false }
            isPinnedToBottom = true
        } else if deliberatelyMovedUp {
            isPinnedToBottom = false
        }
        // Only momentum from a deliberate upward flick may detach during deceleration.
        // A downward coast can reattach; its rebound must not undo that decision.
    }

    mutating func updatePhase(_ newPhase: ScrollPhase, geometry: CaptionScrollGeometry, fontSize: Double? = nil) {
        if newPhase == .tracking || newPhase == .interacting {
            if newPhase == .tracking || phase != .interacting {
                furthestDragOffset = nil
                directionalDragTravel = 0
                isCoastingUp = false
            }
            phase = newPhase
            updateGeometry(geometry, fontSize: fontSize)
        } else {
            // Include the finger's final movement before entering deceleration/idle.
            // Carry the actual drag direction into the coast, rather than interpreting
            // the bottom's elastic rebound as a new upward gesture.
            updateGeometry(geometry, fontSize: fontSize)
            isCoastingUp =
                newPhase == .decelerating && phase == .interacting
                && directionalDragTravel < -1
            phase = newPhase
            furthestDragOffset = isCoastingUp ? geometry.clampedOffset : nil
            directionalDragTravel = 0
        }
    }

    func request(isEmpty: Bool) -> CaptionScrollRequest? {
        guard !isUserScrolling, let geometry, geometry.viewportHeight > 0 else { return nil }

        if isEmpty || !geometry.overflows {
            guard abs(geometry.offsetFromTop) > 1 else { return nil }
            return CaptionScrollRequest(target: .top, geometry: geometry)
        }

        guard isPinnedToBottom,
            abs(geometry.maximumOffset - geometry.offsetFromTop) > 1
        else { return nil }
        return CaptionScrollRequest(target: .bottom, geometry: geometry)
    }
}
