import SwiftUI

/// Volume slider styled after macOS's own system volume control: a plain
/// capsule track with a solid fill and no separate thumb — the fill's own
/// edge is the indicator — flanked by static min/max icons OUTSIDE the
/// track (quiet on the left, loud on the right), not embedded inside it.
///
/// Hovering (without pressing) previews where a click would land: the fill
/// ghosts to a lower opacity and tracks the cursor instead of the real
/// value, snapping back once the cursor leaves. Dragging commits for real,
/// same as before.
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
    @State private var hoverFraction: Double? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let minIcon {
                minIconView(minIcon)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let clampedValue = max(0, min(1, value))
                // Real value while idle or dragging; a ghosted preview of
                // where a click would land while just hovering.
                let previewing = !isDragging && hoverFraction != nil
                let displayedFraction = isDragging ? clampedValue : (hoverFraction ?? clampedValue)
                let fillWidth = displayedFraction * w
                let meterWidth = max(0, min(1, levelMeter)) * (clampedValue * w)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))

                    Capsule()
                        .fill(Color.primary.opacity(previewing ? 0.55 : 0.92))
                        .frame(width: fillWidth)

                    if meterWidth > 1 {
                        Capsule()
                            .fill(.white.opacity(0.22))
                            .frame(width: meterWidth)
                            .blendMode(.plusLighter)
                            .animation(.easeOut(duration: 0.08), value: meterWidth)
                    }
                }
                .frame(height: height)
                .scaleEffect(isDragging ? 1.02 : 1.0, anchor: .leading)
                .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isDragging)
                .animation(.easeOut(duration: 0.1), value: hoverFraction)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverFraction = max(0, min(1, location.x / w))
                    case .ended:
                        hoverFraction = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            isDragging = true
                            value = Double(max(0, min(1, g.location.x / w)))
                        }
                        .onEnded { _ in
                            isDragging = false
                            hoverFraction = nil
                        }
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
