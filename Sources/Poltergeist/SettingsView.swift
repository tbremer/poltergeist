import SwiftUI
import GhosttyTheme
import KeyboardShortcuts

/// The app's Settings window (⌘,). Hosts appearance (theme) and keyboard
/// (global hotkey) preferences in a standard macOS tabbed layout.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            ThemeSettings(model: model)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShortcutSettings()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        .frame(width: 460, height: 540)
    }
}

// MARK: - Appearance

/// Searchable theme chooser with a Light/Dark slot selector. Selecting persists
/// to config.json and applies live; both slots can be set without closing.
private struct ThemeSettings: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var slot: ThemeSlot = .dark

    private var selectedName: String? {
        slot == .light ? model.lightThemeName : model.darkThemeName
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $slot) {
                Text("Light").tag(ThemeSlot.light)
                Text("Dark").tag(ThemeSlot.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)

            TextField("Search themes…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()

            List {
                Button {
                    model.selectTheme(nil, for: slot)
                } label: {
                    HStack {
                        Text("Default")
                        Spacer()
                        if selectedName == nil {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(HoverHighlightButtonStyle())

                ForEach(query.isEmpty ? GhosttyThemeCatalog.allThemes : GhosttyThemeCatalog.search(query)) { theme in
                    Button {
                        model.selectTheme(theme.name, for: slot)
                    } label: {
                        ThemeSwatchRow(theme: theme, selected: theme.name == selectedName)
                    }
                    .buttonStyle(HoverHighlightButtonStyle())
                }
            }
            .listStyle(.plain)

            Divider()
            InactiveDimmingControls(model: model)
                .padding(12)
        }
        .onAppear { slot = model.systemIsDark ? .dark : .light }
    }
}

/// Controls for how unfocused panes are dimmed when a tab is split.
private struct InactiveDimmingControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Dim inactive panes", isOn: Binding(
                get: { model.dimInactivePanes },
                set: { model.setDimInactivePanes($0) }
            ))

            HStack(spacing: 10) {
                Text("Dimming amount")
                Slider(
                    value: Binding(
                        get: { model.inactivePaneDim },
                        set: { model.setInactivePaneDim($0) }
                    ),
                    in: 0 ... 1
                )
                Text("\(Int((model.inactivePaneDim * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .disabled(!model.dimInactivePanes)
        }
    }
}

/// One theme row: a background/foreground swatch + name + selection check.
private struct ThemeSwatchRow: View {
    let theme: GhosttyThemeDefinition
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hexRGB: theme.background) ?? .gray)
                .frame(width: 24, height: 16)
                .overlay(
                    Text("Aa")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(hexRGB: theme.foreground) ?? .white)
                )
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary, lineWidth: 0.5))
            Text(theme.name).lineLimit(1)
            Spacer(minLength: 4)
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }
}

/// Button style that highlights its row on hover (and press) for clear feedback.
private struct HoverHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(fill))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return .primary.opacity(0.16) }
            return hovering ? .primary.opacity(0.08) : .clear
        }
    }
}

// MARK: - Keyboard

/// Records the global summon/hide hotkey. The Recorder persists the binding and
/// warns about conflicts; AppModel registers the matching listener at launch.
private struct ShortcutSettings: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Toggle Poltergeist:", name: .togglePoltergeist)
            Text("Press this shortcut from any app to bring Poltergeist to the front, or hide it when it's already frontmost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
