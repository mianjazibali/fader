import SwiftUI

/// Top-level Control Center panel.
struct ControlCenterView: View {
    let engine: any AudioEngine
    @State private var showSettings = false

    var body: some View {
        @Bindable var state = engine.state

        VStack(spacing: 0) {
            HeaderView(state: state, showSettings: $showSettings)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)

            Divider().opacity(0.3)

            if showSettings {
                SettingsView(state: state)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainPanel(engine: engine, state: state)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 340)
        .frame(minHeight: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Not animated, same reason as MainPanel below: MainPanel and
        // SettingsView have different natural heights, and animating that
        // swap makes the auto-sizing MenuBarExtra(.window) popover fight
        // the spring every frame instead of settling.
    }
}

private struct MainPanel: View {
    let engine: any AudioEngine
    @Bindable var state: AudioState

    var body: some View {
        // Only display apps that are actually producing audio right now —
        // matches user expectation ("apps playing"), removes the awkward
        // "No audio playing" + stale-rows mismatch, and avoids showing
        // washed-out dim rows. State still remembers paused apps' volumes.
        let visibleApps = state.apps.filter { $0.isActive }

        VStack(spacing: 0) {
            if state.duckingEnabled && state.isAnyCommunicationActive {
                DuckingBanner(amount: state.duckingAmount)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if visibleApps.isEmpty {
                EmptyStateView()
                    .padding(.vertical, 36)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleApps) { app in
                            AppRowView(app: app, state: state, engine: engine)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal:   .opacity.combined(with: .scale(scale: 0.96))
                                ))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 360)
            }

            Divider().opacity(0.2)

            FooterView(engine: engine)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .padding(.top, 10)
        // Deliberately NOT animated: MenuBarExtra(.window) auto-sizes its
        // popover to content, and animating a height-affecting change here
        // (ducking banner / app list appearing) makes the window itself
        // fight the in-flight spring animation every frame — it never
        // settles and the popover visibly grows/shrinks on a loop. Content
        // changes size instantly instead; per-row insertion/removal still
        // has its own `.transition()` below for a soft fade even without
        // an ambient animation context.
        //
        // System volume changes (F11/F12, Control Center) rescale every
        // app's effective gain, since per-app volume is relative to it.
        // Ducking changes need the same re-push.
        .onChange(of: state.systemVolume)              { _, _ in engine.resyncAllGains() }
        .onChange(of: state.duckingEnabled)             { _, _ in engine.resyncAllGains() }
        .onChange(of: state.duckingAmount)              { _, _ in engine.resyncAllGains() }
        .onChange(of: state.isAnyCommunicationActive)   { _, _ in engine.resyncAllGains() }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Brand.softGradient(opacity: 0.35), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Brand.gradient)
            }
            .frame(height: 64)

            Text("Listening for audio…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 2)

            Text("Apps appear here the moment they start playing sound.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        // Deliberately static — no pulse/repeatForever animation. An
        // infinite, always-running animation inside a MenuBarExtra(.window)
        // popover is the same risk pattern that caused three separate
        // "grows/shrinks on repeat" bugs this session (ducking banner,
        // hover-preview, level meter), just not yet confirmed as a fourth
        // trigger.
    }
}

private struct HeaderView: View {
    @Bindable var state: AudioState
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Brand gradient mini-icon with the same mark as the app icon.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.gradient)
                    .frame(width: 30, height: 30)
                    .shadow(color: Brand.orange.opacity(0.30), radius: 6, y: 2)

                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Fader")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.apps.contains(where: { $0.isActive }) ? .green : .secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.opacity)
                }
            }

            Spacer()

            Button {
                // Not wrapped in withAnimation — see the note on
                // ControlCenterView's body: animating this swap fights the
                // auto-sizing popover window's own resize.
                showSettings.toggle()
            } label: {
                Image(systemName: showSettings ? "chevron.left" : "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(.quaternary)
                            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    )
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(showSettings ? "Back" : "Settings")
        }
    }

    private var statusText: String {
        let active = state.apps.filter { $0.isActive }.count
        if active == 0 { return "No audio playing" }
        return "\(active) app\(active == 1 ? "" : "s") playing"
    }
}

private struct DuckingBanner: View {
    let amount: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("Ducking active · others lowered \(Int(amount * 100))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.orange.opacity(0.30), lineWidth: 0.5)
                )
        )
    }
}

private struct FooterView: View {
    let engine: any AudioEngine

    var body: some View {
        HStack(spacing: 8) {
            Text(footerLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            // Mock-only demo: flip "is playing" on each app.
            if let mock = engine as? MockAudioEngine {
                Menu {
                    ForEach(mock.state.apps) { app in
                        Button("\(app.isActive ? "Stop" : "Start") \(app.displayName)") {
                            mock.toggleActivity(for: app.id)
                        }
                    }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                .help("Toggle which apps are 'playing audio'")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Fader")
        }
    }

    private var footerLabel: String {
        if engine is MockAudioEngine { return "Mock data" }
        return "Live audio detection"
    }
}
