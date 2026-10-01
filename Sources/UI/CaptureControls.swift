import SwiftUI

// Start/Stop and Clear as circles tucked into the bottom corners of the screen, with the
// capture status drawn as a ring around Start/Stop. See the addendum to
// status-indicator-brief.html for the design and the reasoning behind each choice.
//
// Nothing here animates continuously. The ring and label redraw only when
// `CaptionSession.captureStatus` changes, which is the point of replacing the level meter.

/// A circle anchored near one bottom corner of its frame, with its center `center.x` in
/// from the side edge and `center.y` up from the bottom edge.
///
/// The center sits inside the screen and the radius reaches past both edges, so the screen
/// clips the circle into a corner button that is more than a quarter. The glyph goes at the
/// circle's real center, which lets the eye find it as centered. The view never needs the
/// display's corner radius (which isn't public API): the rounded corner only trims what's
/// already past the edges.
struct CornerCircle: Shape {
    var edge: HorizontalEdge
    var center: CGPoint
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let x = edge == .leading ? rect.minX + center.x : rect.maxX - center.x
        let point = CGPoint(x: x, y: rect.maxY - center.y)
        return Path(
            ellipseIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    }
}

/// How a capture status draws. Each state differs in shape as well as color, so it reads
/// without color vision: no ring, dashed, thin, thick, thick with a badge.
struct CaptureStatusAppearance: Equatable {
    enum Ring: Equatable {
        case none
        case dashed
        case thin
        case thick
    }

    enum Tone: Equatable {
        case secondary
        case accent
        case warning
    }

    let ring: Ring
    let tone: Tone
    let showsBadge: Bool

    init(_ status: CaptureStatus) {
        switch status {
        case .stopped:
            self.init(ring: .none, tone: .secondary)
        case .starting, .noAudio:
            self.init(ring: .dashed, tone: .secondary)
        case .listening:
            self.init(ring: .thin, tone: .secondary)
        case .captioning:
            self.init(ring: .thick, tone: .accent)
        case .stalled:
            self.init(ring: .thick, tone: .warning, showsBadge: true)
        }
    }

    private init(ring: Ring, tone: Tone, showsBadge: Bool = false) {
        self.ring = ring
        self.tone = tone
        self.showsBadge = showsBadge
    }

    var lineWidth: CGFloat {
        switch ring {
        case .none: 0
        case .dashed, .thin: 2.5
        case .thick: 4
        }
    }

    var strokeStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: lineWidth,
            lineCap: ring == .dashed ? .butt : .round,
            dash: ring == .dashed ? [5, 5] : []
        )
    }

    func color(accent: Color) -> Color {
        switch tone {
        case .secondary: .secondary
        case .accent: accent
        case .warning: .orange
        }
    }
}

/// Status in words, beside or above the ring: the meaning never rests on the ring alone.
/// Its own view so status changes rebuild only this leaf.
struct CaptureStatusLabel: View {
    let session: CaptionSession
    let isSelectedModeConfigured: Bool
    let accent: Color

    var body: some View {
        let status = session.captureStatus
        Text(text(for: status))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CaptureStatusAppearance(status).color(accent: accent))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: status)
    }

    private func text(for status: CaptureStatus) -> String {
        let mode = session.requestedMode.title
        if session.store.isRunning {
            // Say what's wrong rather than "No captions" when the cause is known.
            if session.isInterrupted { return "Interrupted · \(mode)" }
            if session.isReconnecting { return "Reconnecting · \(mode)" }
            guard let activeMode = session.activeMode else {
                return status == .starting ? "Starting · \(mode)" : "Switching to \(mode)…"
            }
            return "\(status.title) · \(activeMode.title)"
        }
        if session.speechAnalyzerState != "Error", !isSelectedModeConfigured {
            return "Soniox key required"
        }
        return "Stopped · \(mode)"
    }
}

/// Dims while pressed. A one-shot highlight, like any system button.
struct CornerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// Geometry for the iOS corner controls, in points.
struct CornerControlMetrics: Equatable {
    /// Radius of the tappable circle.
    let radius: CGFloat
    /// The circle's center: `x` in from the side edge, `y` up from the screen's bottom edge.
    /// The band puts `y` on the input chip's center line, so glyphs and chip read as a row.
    let center: CGPoint
    /// Gap between the circle and the status ring.
    static let ringGap: CGFloat = 5
    /// Room for the ring's stroke outside the circle.
    static let ringAllowance: CGFloat = ringGap + 4

    var ringRadius: CGFloat { radius + Self.ringGap }
    /// The frame runs from the screen corner to just past the ring.
    var frameSize: CGSize {
        CGSize(
            width: center.x + radius + Self.ringAllowance,
            height: center.y + radius + Self.ringAllowance
        )
    }

    /// Where the glyph goes, in a frame anchored to the given bottom corner.
    func glyphPosition(_ edge: HorizontalEdge) -> CGPoint {
        let size = frameSize
        return CGPoint(x: edge == .leading ? center.x : size.width - center.x, y: size.height - center.y)
    }

    /// How far from the side edge the circle reaches at `height` above the screen's bottom,
    /// including the ring. Content beside the controls insets by this much.
    func reach(atHeight height: CGFloat) -> CGFloat {
        let ring = radius + Self.ringAllowance
        let dy = abs(height - center.y)
        guard dy < ring else { return 0 }
        return center.x + (ring * ring - dy * dy).squareRoot()
    }
}

#if os(iOS)
struct CornerStartStopButton: View {
    let session: CaptionSession
    let metrics: CornerControlMetrics
    let accent: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let status = session.captureStatus
        let appearance = CaptureStatusAppearance(status)
        let isRunning = session.store.isRunning
        let size = metrics.frameSize
        let glyph = metrics.glyphPosition(.leading)

        Button(action: action) {
            ZStack {
                // Same colors as the Start/Stop button had before the redesign, in every
                // theme: the theme's accent to start, red to stop.
                CornerCircle(edge: .leading, center: metrics.center, radius: metrics.radius)
                    .fill(isRunning ? Color.red : accent)

                if appearance.ring != .none {
                    CornerCircle(edge: .leading, center: metrics.center, radius: metrics.ringRadius)
                        .stroke(appearance.color(accent: accent), style: appearance.strokeStyle)
                }

                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    // A play triangle's visual weight sits left of its box; nudge it right.
                    .offset(x: isRunning ? 0 : 2)
                    .position(glyph)

                if appearance.showsBadge {
                    // On the ring at 45°, up and to the right, clear of the glyph.
                    let offset = metrics.ringRadius * 0.7071
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .orange)
                        .position(x: glyph.x + offset, y: glyph.y - offset)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(CornerCircle(edge: .leading, center: metrics.center, radius: metrics.ringRadius))
            .animation(.easeOut(duration: 0.2), value: status)
        }
        .buttonStyle(CornerButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(isRunning ? "Stop captions" : "Start captions")
        .accessibilityValue(status.title)
    }
}

/// Clear, always on screen. Its own view so caption updates rebuild only this leaf.
struct CornerClearButton: View {
    let session: CaptionSession
    let metrics: CornerControlMetrics

    var body: some View {
        let isEmpty = session.store.finalizedChunks.isEmpty && session.store.volatileCaptions.isEmpty
        let size = metrics.frameSize

        Button {
            session.clear()
        } label: {
            ZStack {
                // Neutral, so it doesn't compete with Start/Stop or the status ring.
                CornerCircle(edge: .trailing, center: metrics.center, radius: metrics.radius)
                    .fill(Color.primary.opacity(0.12))

                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .position(metrics.glyphPosition(.trailing))
            }
            .frame(width: size.width, height: size.height)
            .contentShape(CornerCircle(edge: .trailing, center: metrics.center, radius: metrics.radius))
        }
        .buttonStyle(CornerButtonStyle())
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.45 : 1)
        .accessibilityLabel("Clear captions")
    }
}
#endif

#if os(macOS)
/// Start/Stop for the macOS window toolbar, with the status as a ring around the glyph.
struct ToolbarStartStopButton: View {
    let session: CaptionSession
    let accent: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let status = session.captureStatus
        let appearance = CaptureStatusAppearance(status)
        let isRunning = session.store.isRunning

        Button(action: action) {
            ZStack {
                if appearance.ring != .none {
                    Circle()
                        .inset(by: appearance.lineWidth / 2)
                        .stroke(appearance.color(accent: accent), style: appearance.strokeStyle)
                }
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isRunning ? Color.red : accent)
                if appearance.showsBadge {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .orange)
                        .offset(x: 10, y: -10)
                }
            }
            .frame(width: 26, height: 26)
            .animation(.easeOut(duration: 0.2), value: status)
        }
        .disabled(!isEnabled)
        .help(isRunning ? "Stop captions" : "Start captions")
        .accessibilityLabel(isRunning ? "Stop captions" : "Start captions")
        .accessibilityValue(status.title)
    }
}

/// Clear for the macOS window toolbar. Its own view so caption updates rebuild only it.
struct ToolbarClearButton: View {
    let session: CaptionSession

    var body: some View {
        Button {
            session.clear()
        } label: {
            Label("Clear Captions", systemImage: "trash")
        }
        .disabled(session.store.finalizedChunks.isEmpty && session.store.volatileCaptions.isEmpty)
        .help("Clear captions")
    }
}
#endif

/// Shown for a few seconds after Clear. Never repeats the cleared text, and has no
/// countdown: a shrinking bar would redraw every frame for the whole window.
struct ClearUndoToast: View {
    let session: CaptionSession
    let accent: Color

    var body: some View {
        Group {
            if session.canUndoClear {
                HStack(spacing: 16) {
                    Text("Captions cleared")
                        .foregroundStyle(.primary)
                    Button("Undo") {
                        session.undoClear()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(accent)
                    .buttonStyle(.plain)
                }
                .font(.subheadline)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.canUndoClear)
    }
}
