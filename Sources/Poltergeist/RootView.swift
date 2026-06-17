import SwiftUI
import GhosttyTerminal

/// The editor-style shell: a sessions sidebar + a detail area.
/// For M0 these are placeholders; real terminal surfaces land in M1.
struct RootView: View {
    @State private var selection: SidebarItem? = .welcome

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Sessions") {
                    Label("Welcome", systemImage: "sparkles")
                        .tag(SidebarItem.welcome)
                }
            }
            .navigationTitle("Poltergeist")
            .frame(minWidth: 220)
        } detail: {
            DetailPlaceholder()
        }
    }
}

enum SidebarItem: Hashable {
    case welcome
}

/// Placeholder detail pane. It instantiates a `TerminalViewState` purely to
/// exercise (and verify linkage of) the GhosttyTerminal dependency in M0.
private struct DetailPlaceholder: View {
    @StateObject private var terminalProbe = TerminalViewState()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Poltergeist")
                .font(.largeTitle.bold())

            Text("M0 scaffold — GhosttyTerminal is linked and ready.")
                .foregroundStyle(.secondary)

            Text("Engine state: \(terminalProbe.title.isEmpty ? "ready" : terminalProbe.title)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Live terminal surfaces arrive in M1.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
