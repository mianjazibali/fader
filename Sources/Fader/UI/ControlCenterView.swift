import SwiftUI
import AppKit

/// Top-level Control Center panel.
struct ControlCenterView: View {
    let engine: any AudioEngine
    @State private var showSettings = false

    var body: some View {
        @Bindable var state = engine.state

        // The top strip (FooterView) is the app's one persistent nav bar —
        // it always shows, carrying the settings toggle + quit button, so
        // it stays put as the anchor point on both screens. The brand
        // block (HeaderView) is main-screen-only content, so it — and its
        // divider — only appear there.
        VStack(spacing: 0) {
            FooterView(engine: engine, showSettings: $showSettings)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider().opacity(0.3)

            if showSettings {
                SettingsView(state: state)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainPanel(engine: engine, state: state)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if !showSettings {
                VStack(spacing: 0) {
                    Divider().opacity(0.25)

                    HeaderView(state: state)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                }
                .transition(.opacity)
            }
        }
        .frame(width: 340)
        // Same floor on both screens — Settings' natural content height
        // (~346pt) is now the panel's fixed height everywhere, so toggling
        // between Main and Settings never resizes the popover at all. That's
        // what makes it safe to animate this swap (see the toggle button in
        // FooterView): the auto-sizing MenuBarExtra(.window) popover never
        // has to resize mid-animation, so there's nothing for the spring to
        // fight.
        .frame(minHeight: 350, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        // Show apps that are actively playing, PLUS anything the user has
        // muted or turned down — otherwise muting an app, then having it go
        // quiet (track ends, app is paused), hides the row and its mute
        // state with it. Next time that app plays again it's silently
        // muted with no visible way to notice or undo it. Apps the user has
        // never touched still only show up while actually playing, so this
        // doesn't reintroduce clutter/stale rows for untouched apps.
        let visibleApps = state.apps.filter { $0.isActive || $0.hasCustomSettings }

        VStack(spacing: 0) {
            if !state.permissionBannerDismissed, state.systemAudioCaptureLikelyBlocked {
                PermissionBanner(state: state)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if state.duckingEnabled && state.isAnyCommunicationActive {
                AutoLowerBanner(amount: state.duckingAmount)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !state.updateBannerDismissed, let update = state.updateAvailable {
                UpdateBanner(state: state, update: update)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if state.showSupportPrompt {
                SupportPromptBanner(state: state)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if visibleApps.isEmpty {
                Spacer(minLength: 0)
                EmptyStateView()
                Spacer(minLength: 0)
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
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 360)

                // Soaks up any leftover room from the panel-wide minHeight
                // (matched to Settings' height) below a short list, instead
                // of it collecting as dead space under the whole panel.
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity)
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

    var body: some View {
        HStack(spacing: 12) {
            // Brand mini-icon with the same mark as the app icon.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.accent)
                    .frame(width: 30, height: 30)
                    .shadow(color: Brand.accent.opacity(0.30), radius: 6, y: 2)

                FaderMark()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 14, height: 14)
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
        }
    }

    private var statusText: String {
        let active = state.apps.filter { $0.isActive }.count
        if active == 0 { return "No audio playing" }
        return "\(active) app\(active == 1 ? "" : "s") playing"
    }
}

private struct PermissionBanner: View {
    @Bindable var state: AudioState
    private let manager = PermissionsManager()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("A tapped app has stayed silent. Fader may need System Audio Recording access.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Open Settings") { manager.openSystemSettings(for: .systemAudioCapture) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.orange)
                    Button("Not now") { state.permissionBannerDismissed = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

private struct UpdateBanner: View {
    @Bindable var state: AudioState
    let update: (version: String, url: URL)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Fader \(update.version) is available.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Get it") { NSWorkspace.shared.open(update.url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Brand.accent)
                    Button("Not now") { state.updateBannerDismissed = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Brand.accent.opacity(0.28), lineWidth: 0.5)
                )
        )
    }
}

private struct SupportPromptBanner: View {
    @Bindable var state: AudioState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Fader's free, but we would love your support.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Support Fader") {
                        NSWorkspace.shared.open(URL(string: "https://mianjazibali.github.io/fader/#support")!)
                        state.showSupportPrompt = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Brand.accent)
                    Button("No thanks") { state.showSupportPrompt = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Brand.accent.opacity(0.28), lineWidth: 0.5)
                )
        )
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
    @Binding var showSettings: Bool
    @State private var isHoveringSettings = false
    @State private var isHoveringPower = false

    var body: some View {
        // Every element gets the same 22pt-tall slot to center within —
        // without it, the label and the 12-13pt icons don't share a
        // common vertical anchor and visibly drift out of alignment.
        HStack(alignment: .center, spacing: 8) {
            if showSettings {
                Text("Settings")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
                    .frame(height: 22, alignment: .leading)
            } else {
                Text(footerLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(height: 22, alignment: .leading)
            }

            Spacer()

            // Mock-only demo: flip "is playing" on each app.
            if let mock = engine as? MockAudioEngine, !showSettings {
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

            // Settings toggle (also the "Back" button once on the Settings
            // screen — same Button, the icon just swaps). Real resting-
            // state background/border now, same affordance as the mute
            // icon — a background that only appeared on hover read as
            // "just an icon" until you happened to find it clickable.
            // Both screens are pinned to the same height (see
            // ControlCenterView), so this swap is safe to animate: the
            // popover never has to resize mid-transition.
            Button {
                withAnimation(.snappy(duration: 0.28)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "chevron.left" : "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Color.primary.opacity(isHoveringSettings ? 0.14 : 0.07))
                    )
                    .overlay(
                        Circle().strokeBorder(Color.primary.opacity(isHoveringSettings ? 0.22 : 0.14), lineWidth: 1)
                    )
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(showSettings ? "Back" : "Settings")
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHoveringSettings = hovering }
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Color.primary.opacity(isHoveringPower ? 0.14 : 0.07))
                    )
                    .overlay(
                        Circle().strokeBorder(Color.primary.opacity(isHoveringPower ? 0.22 : 0.14), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Quit Fader")
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHoveringPower = hovering }
            }
        }
    }

    private var footerLabel: String {
        if engine is MockAudioEngine { return "Mock data" }
        return "Live audio detection"
    }
}
