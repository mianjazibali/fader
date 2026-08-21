import SwiftUI

/// Top-level Control Center panel.
struct ControlCenterView: View {
    let engine: any AudioEngine
    @State private var showSettings = false

    var body: some View {
        @Bindable var state = engine.state

        // FooterView/HeaderView are both top-level (shared, not nested
        // inside MainPanel) so their padding/position stays identical
        // whenever they DO show on both screens. The settings screen hides
        // most of their content (see below) to stay simple/uncluttered,
        // but what remains (the divider layout, the back button's slot)
        // still lines up the same way, not two independently-built strips.
        VStack(spacing: 0) {
            if !showSettings {
                FooterView(engine: engine)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                Divider().opacity(0.3)
            }

            if showSettings {
                SettingsView(state: state)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainPanel(engine: engine, state: state)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            Divider().opacity(0.25)

            HeaderView(state: state, showSettings: $showSettings)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(width: 340)
        // No minHeight: it was sized for the old, taller empty state (big
        // icon + more padding). Now that the empty state is intentionally
        // compact, a fixed floor just forces an awkward blank gap to fill
        // the difference. The panel sizes to its actual content instead —
        // MenuBarExtra(.window) already auto-sizes, so nothing is lost.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Not animated, same reason as MainPanel below: MainPanel and
        // SettingsView have different natural heights, and animating that
        // swap makes the auto-sizing MenuBarExtra(.window) popover fight
        // the spring every frame instead of settling.
        //
        // MenuBarExtra(.window) keeps this view (and its @State) alive
        // across close/reopen — without resetting here, reopening the
        // popover after leaving it on Settings would still show Settings.
        // Every fresh click on the menu bar icon should land on the main
        // screen.
        .onAppear { showSettings = false }
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
                AutoLowerBanner(amount: state.duckingAmount)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if visibleApps.isEmpty {
                EmptyStateView()
                    .padding(.vertical, 24)
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
        }
        .padding(.vertical, 10)
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
        VStack(spacing: 6) {
            Text("Listening for audio…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Apps appear here the moment they start playing sound.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HeaderView: View {
    @Bindable var state: AudioState
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showSettings {
                // Simple/uncluttered on the settings screen — no need to
                // repeat the brand mark or "no audio playing" status here.
                Text("Settings")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
            } else {
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
            }

            Spacer()

            Button {
                // Not wrapped in withAnimation — see the note on
                // ControlCenterView's body: animating this swap fights the
                // auto-sizing popover window's own resize.
                showSettings.toggle()
            } label: {
                Image(systemName: showSettings ? "chevron.left" : "gearshape.fill")
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

private struct AutoLowerBanner: View {
    let amount: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("On a call · others lowered \(Int(amount * 100))%")
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
        // Every element gets the same 22pt-tall slot to center within —
        // without it, the 10pt label and the 12-13pt icons don't share a
        // common vertical anchor and visibly drift out of alignment.
        HStack(alignment: .center, spacing: 8) {
            Text(footerLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(height: 22)

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
                .frame(width: 22, height: 22)
                .help("Toggle which apps are 'playing audio'")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
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
