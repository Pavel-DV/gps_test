import SwiftUI

struct LocationRootView: View {
    @State private var showSettings = !FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
    @ObservedObject private var simulation = LocationSimulationSession.shared
    @ObservedObject private var mounting = MountingProgress.shared

    var body: some View {
        NavigationStack {
            LocationSimulationView()
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                            .disabled(simulation.preventsConnectionChanges)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text(mounting.isPreparing ? "Preparing DDI" : (mounting.coolisMounted ? "DDI mounted" : "DDI not mounted"))
                            .font(.caption)
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            LocationSettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowPairingFilePicker"))) { _ in
            showSettings = true
        }
        .task {
            if FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) {
                startTunnelInBackground(showErrorUI: false)
            }
        }
    }
}
