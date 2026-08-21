import SwiftUI

/// Volume slider styled after macOS's own system volume control: a plain
/// capsule track with a solid fill and no separate thumb — the fill's own
/// edge is the indicator — flanked by static min/max icons OUTSIDE the
/// track (quiet on the left, loud on the right), not embedded inside it.
/// The fill is a plain adaptive white/black, same as the system control —
/// the brand's orange gradient was tried here and looked overkill.
struct FluidSlider: View {
    @Binding var value: Double          // 0...1
    var height: CGFloat = 24
    /// SF Symbols shown to either side of the track. Omit both for sliders
    /// with no natural icon (e.g. the ducking-amount slider).
    var minIcon: String? = nil
    var maxIcon: String? = nil
    /// Live level meter (0...1). Drawn as a soft glow inside the filled region.
    var levelMeter: Double = 0
    /// Tapping the min icon (e.g. mute toggle) — nil makes it non-interactive.
    var onMinIconTap: (() -> Void)? = nil

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 8) {
            if let minIcon {
                minIconView(minIcon)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let clampedValue = max(0, min(1, value))
                let fillWidth = clampedValue * w
                let meterWidth = max(0, min(1, levelMeter)) * fillWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))

                    Capsule()
                        .fill(Color.primary.opacity(0.92))
                        .frame(width: fillWidth)

                    if meterWidth > 1 {
                        // Deliberately NOT animated: levelMeter updates every
                        // ~200ms for as long as the app is playing audio,
                        // which would otherwise be a continuous stream of
                        // animation transactions inside the
                        // MenuBarExtra(.window) popover — same root cause as
                        // the last two "grows/shrinks on repeat" bugs, just
                        // a quieter source that only shows up with real
                        // audio actively playing (which is exactly when
                        // this got tested against a live app).
                        Capsule()
                            .fill(.white.opacity(0.22))
                            .frame(width: meterWidth)
                            .blendMode(.plusLighter)
                    }
                }
                .frame(height: height)
                .scaleEffect(isDragging ? 1.02 : 1.0, anchor: .leading)
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

            if let maxIcon {
                Image(systemName: maxIcon)
                    .font(.system(size: height * 0.48, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .frame(width: height * 0.85)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func minIconView(_ name: String) -> some View {
        let glyph = Image(systemName: name)
            .font(.system(size: height * 0.48, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.82))
            .frame(width: height * 0.85)
            .contentTransition(.symbolEffect(.replace))
            .contentShape(Rectangle())
            .onTapGesture { onMinIconTap?() }

        if onMinIconTap != nil {
            glyph.help("Mute")
        } else {
            glyph
        }
    }
}
