import SwiftUI
import ForelCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHistory = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if showHistory {
                HistoryView(showHistory: $showHistory)
            } else {
                RuleListView(showHistory: $showHistory)
            }
        }
        .toolbarBackground(ForelTheme.background, for: .windowToolbar)
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
        .tint(ForelTheme.accent)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
