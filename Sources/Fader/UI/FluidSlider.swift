import SwiftUI
import AppKit

/// Volume slider styled after macOS's own Control Center sliders (Volume,
/// Brightness): a monochrome capsule track, a solid fill with no separate
/// thumb — the fill's own edge is the indicator — and, optionally, an icon
/// embedded in the track whose color inverts where the fill passes under
/// it (drawn twice: once in the "on light track" color, once in the
/// "on filled track" color, the second copy masked to the filled region).
/// Drag anywhere on the track to scrub; the icon is decorative here, not a
/// separate tap target — muting stays on the row's existing controls.
struct FluidSlider: View {
    @Binding var value: Double          // 0...1
    var height: CGFloat = 24
    /// SF Symbol shown at the track's leading edge, native-style. Omit for
    /// sliders with no natural icon (e.g. the ducking-amount slider).
    var icon: String? = nil
    /// Live level meter (0...1). Drawn as a soft glow inside the filled region.
    var levelMeter: Double = 0

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clampedValue = max(0, min(1, value))
            let fillWidth = clampedValue * w
            let meterWidth = max(0, min(1, levelMeter)) * fillWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))

                Capsule()
                    .fill(Color.primary.opacity(0.82))
                    .frame(width: fillWidth)

                if meterWidth > 1 {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: meterWidth)
                        .blendMode(.plusLighter)
                        .animation(.easeOut(duration: 0.08), value: meterWidth)
                }

                if let icon {
                    iconOverlay(icon, trackWidth: w, fillWidth: fillWidth)
                }
            }
            .frame(height: height)
            .scaleEffect(isDragging ? 1.015 : 1.0, anchor: .leading)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isDragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        value = Double(max(0, min(1, g.location.x / w)))
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: height)
    }

    /// The icon drawn twice at the same fixed leading position: a muted
    /// copy visible on the unfilled (light) track, and a bright copy
    /// masked to only show through where the fill has covered it.
    @ViewBuilder
    private func iconOverlay(_ icon: String, trackWidth: CGFloat, fillWidth: CGFloat) -> some View {
        let inset = height * 0.32
        let glyph = HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: height * 0.42, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.leading, inset)
        .frame(width: trackWidth, alignment: .leading)

        ZStack(alignment: .leading) {
            glyph.foregroundStyle(Color.primary.opacity(0.5))
            glyph
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .mask(alignment: .leading) {
                    Rectangle().frame(width: fillWidth)
                }
        }
        .allowsHitTesting(false)
    }
}
