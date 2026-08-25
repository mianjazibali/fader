import SwiftUI

/// Volume slider styled after macOS's own system volume control: a plain
/// capsule track with a solid fill and no separate thumb — the fill's own
/// edge is the indicator — flanked by static min/max icons OUTSIDE the
/// track (quiet on the left, loud on the right), not embedded inside it.
/// The fill is a plain adaptive white/black, same as the system control —
/// the brand's orange gradient was tried here and looked overkill.
struct FluidSlider: View {
    @Binding var value: Double          // 0...maxValue
    /// Upper bound of `value`. Default 1.0 (100%) for every normal
    /// slider; pass 2.0 to expose the gain engine's existing boost
    /// headroom (`GainSlot.setGain` has always clamped to 0...2) for a
    /// specific app that opted into it — see AppRowView's boost button.
    var maxValue: Double = 1.0
    var height: CGFloat = 24
    /// SF Symbols shown to either side of the track. Omit both for sliders
    /// with no natural icon (e.g. the ducking-amount slider).
    var minIcon: String? = nil
    var maxIcon: String? = nil
    /// Live level meter (0...1). Brightens the fill's opacity slightly —
    /// real audio-derived value, see CoreAudioEngine.tickPulse.
    var levelMeter: Double = 0
    /// Tapping the min icon (e.g. mute toggle) — nil makes it non-interactive.
    var onMinIconTap: (() -> Void)? = nil
    /// Drives the min icon's button styling — a bare glyph with no
    /// resting-state background read as "just an icon," not something
    /// clickable, until you happened to hover it.
    var isMuted: Bool = false

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 8) {
            if let minIcon {
                minIconView(minIcon)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let clampedValue = max(0, min(maxValue, value))
                let fillWidth = (clampedValue / maxValue) * w
                // Live level brightens the WHOLE fill's opacity rather than
                // overlaying a second, shorter capsule on top of it — a
                // separate glow shape shorter than the fill has its own
                // rounded end sitting in the middle of the track, which
                // reads as a floating thumb, not a glow. A single shape
                // whose fill value just varies can't create that seam.
                let level = max(0, min(1, levelMeter))
                let fillOpacity = 0.78 + level * 0.17

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))

                    Capsule()
                        .fill(Color.primary.opacity(fillOpacity))
                        .frame(width: fillWidth)

                    // Marks where "100%" sits on an extended (boosted)
                    // range, so dragging past it reads as a deliberate
                    // choice, not an accident.
                    if maxValue > 1.0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 1.5)
                            .offset(x: (1.0 / maxValue) * w)
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
                            let fraction = max(0, min(1, g.location.x / w))
                            value = Double(fraction) * maxValue
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .frame(height: height)

            if let maxIcon {
                Image(systemName: maxIcon)
                    .font(.system(size: height * 0.48, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .frame(width: height, height: height)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func minIconView(_ name: String) -> some View {
        let interactive = onMinIconTap != nil
        let glyph = Image(systemName: name)
            .font(.system(size: height * 0.42, weight: .semibold))
            .foregroundStyle(isMuted ? Color.red : Color.primary.opacity(0.82))
            .frame(width: height, height: height)
            .background(
                Circle().fill(
                    interactive
                        ? (isMuted ? Color.red.opacity(0.14) : Color.primary.opacity(0.07))
                        : .clear
                )
            )
            .overlay(
                Circle().strokeBorder(
                    interactive
                        ? (isMuted ? Color.red.opacity(0.35) : Color.primary.opacity(0.14))
                        : .clear,
                    lineWidth: 1
                )
            )
            .contentTransition(.symbolEffect(.replace))
            .contentShape(Circle())
            .onTapGesture { onMinIconTap?() }

        if interactive {
            glyph.help(isMuted ? "Unmute" : "Mute")
        } else {
            glyph
        }
    }
}
