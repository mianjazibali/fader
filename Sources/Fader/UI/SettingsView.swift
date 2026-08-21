import SwiftUI

struct SettingsView: View {
    @Bindable var state: AudioState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section(title: "Auto-Lower for Calls", icon: "waveform.badge.mic") {
                    HStack {
                        Text("Lower other apps during calls")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Toggle("", isOn: $state.duckingEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }

                    Text("Automatically turns other apps down while you're on a call.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)

                    LabeledControl(label: "Lower by", value: "\(Int(state.duckingAmount * 100))%") {
                        FluidSlider(
                            value: Binding(
                                get: { Double(state.duckingAmount) },
                                set: { state.duckingAmount = Float($0) }
                            ),
                            height: 18
                        )
                    }
                    .disabled(!state.duckingEnabled)
                    .opacity(state.duckingEnabled ? 1 : 0.5)
                }

                section(title: "About", icon: "sparkles") {
                    InfoLine(label: "Version", value: "0.2.0")

                    Link(destination: URL(string: "https://github.com/mianjazibali/fader/issues/new/choose")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "ladybug")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Report a bug")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.tint)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        // Matches MainPanel's ScrollView cap (360) — an unconstrained
        // ScrollView leaves its ideal height ambiguous/unbounded, which is
        // exactly the kind of thing that can send an auto-sizing container
        // (the MenuBarExtra popover, or an NSHostingController-backed
        // window in --preview) into a runaway layout-invalidation loop
        // trying to resolve it.
        .frame(maxHeight: 400)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
            }
            content()
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LabeledControl<Content: View>: View {
    let label: String
    let value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tint)
            }
            content()
        }
    }
}

private struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium))
        }
    }
}
