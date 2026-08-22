import SwiftUI
import AppKit

struct AppRowView: View {
    let app: AudioApp
    @Bindable var state: AudioState
    let engine: any AudioEngine

    @State private var showUnsupportedDetail = false
    @State private var showCommDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: name + comm badge + ... + % + lock badge
            HStack(spacing: 6) {
                Text(app.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if app.category == .communication {
                    Button {
                        showCommDetail = true
                    } label: {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Communication app. Click for details.")
                    .popover(isPresented: $showCommDetail, arrowEdge: .bottom) {
                        Text(commDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 220, alignment: .leading)
                            .padding(12)
                    }
                }

                Spacer(minLength: 0)

                if !app.supportsVolumeControl {
                    Button {
                        showUnsupportedDetail = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help(unsupportedShortHint)
                    .popover(isPresented: $showUnsupportedDetail, arrowEdge: .bottom) {
                        Text(unsupportedDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 220, alignment: .leading)
                            .padding(12)
                    }
                }

                Text(volumeText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(app.isMuted ? .red.opacity(0.85) : .secondary)
                    .contentTransition(.numericText())
            }

            // Native-style slider — quiet/loud icons flank the track, same
            // as the system volume control. Tapping the quiet-end icon
            // toggles mute (native behavior); no separate app-icon avatar
            // or button needed for that anymore.
            FluidSlider(
                value: Binding(
                    get: { Double(app.volume) },
                    set: { engine.applyGain(Float($0), to: app.id) }
                ),
                height: 22,
                minIcon: app.isMuted ? "speaker.slash.fill" : "speaker.fill",
                maxIcon: "speaker.wave.3.fill",
                levelMeter: app.isActive ? Double(app.levelMeter) : 0,
                onMinIconTap: {
                    guard app.supportsVolumeControl else { return }
                    withAnimation(.snappy) { engine.setMuted(!app.isMuted, for: app.id) }
                    HapticFeedback.tap()
                },
                isMuted: app.isMuted
            )
            .disabled(!app.supportsVolumeControl)
            .opacity(app.supportsVolumeControl ? 1.0 : 0.5)
            .allowsHitTesting(app.supportsVolumeControl)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .animation(.snappy, value: app.isActive)
        .animation(.snappy, value: app.isMuted)
        .contextMenu {
            Button(app.isMuted ? "Unmute" : "Mute") {
                engine.setMuted(!app.isMuted, for: app.id)
                HapticFeedback.tap()
            }
            .disabled(!app.supportsVolumeControl)
            Divider()
            Button("Show \(app.displayName)") { activateApp() }
                .disabled(app.pid == nil)
            Button("Quit \(app.displayName)") { quitApp() }
                .disabled(app.pid == nil)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var rowBackground: some View {
        if app.isMuted {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.red.opacity(0.18), lineWidth: 0.5))
        } else {
            Color.clear
        }
    }

    // MARK: - Helpers

    private func activateApp() {
        guard let pid = app.pid,
              let running = NSRunningApplication(processIdentifier: pid) else { return }
        running.activate()
    }

    private func quitApp() {
        guard let pid = app.pid,
              let running = NSRunningApplication(processIdentifier: pid) else { return }
        running.terminate()
    }

    private var unsupportedShortHint: String {
        app.isInLiveCall ? "On a call. Click for details." : "Volume control unavailable. Click for details."
    }

    private var unsupportedDetail: String {
        if app.isInLiveCall {
            return "\(app.displayName) is on a live call. Fader leaves call audio untouched by default, since macOS doesn't guarantee it can cleanly silence the original audio when Fader taps it, so forcing control here could cause an echo.\n\nTo try it anyway, turn on \"Control volume during calls\" in Settings → During Calls. If it echoes, turn it back off."
        }
        return "Fader can't control \(app.displayName)'s volume right now."
    }

    private var commDetail: String {
        "\(app.displayName) is a communication app. While it's active, Fader automatically lowers other apps' volume by \(Int(state.duckingAmount * 100))% so calls stay easy to hear.\n\nAdjust or turn this off in Settings → Auto-Lower for Calls."
    }

    // Label reflects the app's OWN slider setting (0...100%, relative —
    // see AudioState.effectiveVolume), not the system-scaled effective
    // output. Otherwise dragging a slider to max wouldn't read "100%"
    // whenever the system volume itself is below 100%.
    private var volumeText: String {
        if !app.supportsVolumeControl { return "—" }
        if app.isMuted { return "Muted" }
        let pct = Int(app.volume * 100)
        if state.duckingEnabled, state.isAnyCommunicationActive, app.category != .communication {
            return "\(pct)%↓"
        }
        return "\(pct)%"
    }
}
