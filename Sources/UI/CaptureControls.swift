import SwiftUI

// Start/Stop and Clear as quarter discs in the bottom corners of the screen, with the
// capture status drawn as a ring around Start/Stop. See the addendum to
// status-indicator-brief.html for the design and the reasoning behind each choice.
//
// Nothing here animates continuously. The ring and label redraw only when
// `CaptionSession.captureStatus` changes, which is the point of replacing the level meter.

/// A quarter disc centered on one bottom corner of its frame.
///
/// The disc is drawn from the frame's corner rather than inset from the display's rounded
/// corner: the radius is roughly twice any iPhone's corner radius, so the screen clips only
/// the tip, and the view never needs the device's corner radius (which isn't public API).
struct CornerDisc: Shape {
    var edge: HorizontalEdge
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = rect.bottomCorner(edge)
        path.move(to: corner)
        path.addArc(
            center: corner,
            radius: radius,
            startAngle: edge.arcStart,
            endAngle: edge.arcEnd,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// The curved edge of a `CornerDisc` alone, for strokes: the status ring, Clear's outline.
struct CornerArc: Shape {
    var edge: HorizontalEdge
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: rect.bottomCorner(edge),
            radius: radius,
            startAngle: edge.arcStart,
            endAngle: edge.arcEnd,
            clockwise: false
        )
        return path
    }
}

extension CGRect {
    fileprivate func bottomCorner(_ edge: HorizontalEdge) -> CGPoint {
        CGPoint(x: edge == .leading ? minX : maxX, y: maxY)
    }
}

extension HorizontalEdge {
    // Angles run clockwise on screen (y points down): 270° is straight up.
    fileprivate var arcStart: Angle { .degrees(self == .leading ? 270 : 180) }
    fileprivate var arcEnd: Angle { .degrees(self == .leading ? 360 : 270) }
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
    /// Radius of the tappable disc.
    let radius: CGFloat
    /// Gap between the disc and the status ring.
    static let ringGap: CGFloat = 5
    /// Room for the ring's stroke outside the disc.
    static let ringAllowance: CGFloat = ringGap + 4

    static func side(forRadius radius: CGFloat) -> CGFloat { radius + ringAllowance }

    var frameSide: CGFloat { Self.side(forRadius: radius) }
    var ringRadius: CGFloat { radius + Self.ringGap }
    /// The glyph sits on the diagonal, clear of the display's rounded corner and above the
    /// bottom safe-area inset.
    var glyphInset: CGFloat { (radius * 0.44).rounded() }
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
        let side = metrics.frameSide

        Button(action: action) {
            ZStack {
                // Same colors as the Start/Stop button had before the redesign, in every
                // theme: the theme's accent to start, red to stop.
                CornerDisc(edge: .leading, radius: metrics.radius)
                    .fill(isRunning ? Color.red : accent)

                if appearance.ring != .none {
                    CornerArc(edge: .leading, radius: metrics.ringRadius)
                        .stroke(appearance.color(accent: accent), style: appearance.strokeStyle)
                }

                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .position(x: metrics.glyphInset, y: side - metrics.glyphInset)

                if appearance.showsBadge {
                    // On the ring at 45°, where it can't collide with the glyph.
                    let offset = metrics.ringRadius * 0.7071
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .orange)
                        .position(x: offset, y: side - offset)
                }
            }
            .frame(width: side, height: side)
            .contentShape(CornerDisc(edge: .leading, radius: metrics.ringRadius))
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
        let side = metrics.frameSide

        Button {
            session.clear()
        } label: {
            ZStack {
                // Neutral, so it doesn't compete with Start/Stop or the status ring.
                CornerDisc(edge: .trailing, radius: metrics.radius)
                    .fill(Color.primary.opacity(0.12))

                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .position(x: side - metrics.glyphInset, y: side - metrics.glyphInset)
            }
            .frame(width: side, height: side)
            .contentShape(CornerDisc(edge: .trailing, radius: metrics.radius))
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
