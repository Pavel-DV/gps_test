import SwiftUI

struct LocationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("TunnelRemotePairingPort") private var remotePairingPort = ""
    @State private var showImporter = false
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var pairingExists = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing File") {
                    Text(pairingExists ? "Pairing file imported" : "Import this iPhone's pairing file to connect.")
                    Button("Import Pairing File") { showImporter = true }
                        .disabled(tunnel.isStarting || mounting.mountingThread != nil)
                }
                Section("Connection") {
                    Button("Connect LocalDevVPN", action: connectLocalDevVPN)
                    TextField("Remote Pairing Port (automatic)", text: $remotePairingPort)
                        .keyboardType(.numberPad)
                        .disabled(tunnel.isStarting)
                    Button("Connect", action: tunnel.restart)
                        .disabled(!pairingExists || tunnel.isStarting)
                    DeviceConnectionStatusView()
                }
                Section("Developer Disk Image") {
                    Text(mounting.coolisMounted ? "DDI mounted" : "DDI not mounted")
                    Button("Download and Mount DDI") { downloadDDI() }
                        .disabled(isDownloading || mounting.mountingThread != nil || tunnel.isStarting)
                    if isDownloading || mounting.mountingThread != nil { ProgressView() }
                }
                Section("Background Activity") {
                    Toggle("Keep Alive with Audio", isOn: $keepAliveAudio)
                    Toggle("Keep Alive with Location", isOn: $keepAliveLocation)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
                do {
                    try PairingFileStore.importFromPicker(result.get())
                    pairingExists = true
                    errorMessage = nil
                    tunnel.restart()
                } catch { errorMessage = error.localizedDescription }
            }
            .onChange(of: keepAliveAudio) { _, _ in updateKeepAlive() }
            .onChange(of: keepAliveLocation) { _, _ in updateKeepAlive() }
        }
    }

    private func updateKeepAlive() {
        if !keepAliveAudio && !keepAliveLocation { keepAliveAudio = true }
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }

    private func downloadDDI() {
        isDownloading = true
        errorMessage = nil
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                try await DeveloperDiskImageService.shared.downloadMissingFiles()
                mounting.pubMount()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
