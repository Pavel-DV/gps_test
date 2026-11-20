import SwiftUI

struct LocationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var simulation = LocationSimulationSession.shared
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @State private var remotePairingPort = UserDefaults.standard.string(forKey: "TunnelRemotePairingPort") ?? ""
    @State private var targetIPAddress = DeviceConnectionContext.targetIPAddress
    @State private var useRemoteDevice = DeviceConnectionContext.targetIPAddress != DeviceConnectionContext.defaultTargetIPAddress
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var pairingExists = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)

    private var connectionIsBusy: Bool {
        tunnel.isStarting || mounting.isPreparing || simulation.preventsConnectionChanges
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing File") {
                    Text(pairingExists ? "Pairing file imported" : "Import the target iPhone's Remote Pairing file to connect.")
                    Button("Import Pairing File") { showImporter = true }
                        .disabled(connectionIsBusy)
                }
                Section("Connection") {
                    Toggle("Connect to Another iPhone", isOn: $useRemoteDevice)
                        .disabled(connectionIsBusy)
                    if useRemoteDevice {
                        TextField("Target iPhone IPv4 Address", text: $targetIPAddress)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(connectionIsBusy)
                        Text("Use the target iPhone's Wi-Fi address and its pairing file. Enable Developer Mode on the target and keep it unlocked. Both phones must be on a network that allows them to reach each other.")
                            .font(.footnote)
                    } else {
                        Button("Connect LocalDevVPN", action: connectLocalDevVPN)
                            .disabled(connectionIsBusy)
                    }
                    TextField("Remote Pairing Port (automatic)", text: $remotePairingPort)
                        .keyboardType(.numberPad)
                        .disabled(connectionIsBusy)
                    Text("If automatic discovery fails, enter the target's Remote Pairing port. An empty port falls back to 49152.")
                        .font(.footnote)
                    Button("Connect", action: connect)
                        .disabled(!pairingExists || connectionIsBusy)
                    if tunnel.isConnected {
                        Text("Connected target: \(DeviceConnectionContext.targetIPAddress)")
                            .font(.footnote)
                    }
                    DeviceConnectionStatusView()
                }
                Section("Developer Disk Image") {
                    Text(mounting.coolisMounted ? "DDI mounted" : "DDI not mounted")
                    Button("Download and Mount DDI", action: mounting.pubMount)
                        .disabled(!tunnel.isConnected || connectionIsBusy)
                    if mounting.isPreparing {
                        ProgressView("Preparing target Developer Disk Image")
                    }
                    if let error = mounting.lastError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
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
                guard !connectionIsBusy else { return }
                do {
                    try PairingFileStore.importFromPicker(result.get())
                    pairingExists = true
                    errorMessage = nil
                    tunnel.markDisconnected()
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

    private func connect() {
        guard !connectionIsBusy, !LocationSimulationSession.shared.preventsConnectionChanges else { return }
        let address = useRemoteDevice
            ? targetIPAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            : DeviceConnectionContext.defaultTargetIPAddress
        guard DeviceConnectionContext.isValidIPv4Address(address) else {
            errorMessage = "Enter a valid target IPv4 address."
            return
        }
        let port = remotePairingPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard port.isEmpty || (UInt16(port).map { $0 != 0 } ?? false) else {
            errorMessage = "Remote Pairing Port must be between 1 and 65535, or empty for automatic discovery."
            return
        }
        UserDefaults.standard.set(address, forKey: DeviceConnectionContext.targetAddressKey)
        UserDefaults.standard.set(port, forKey: "TunnelRemotePairingPort")
        errorMessage = nil
        tunnel.restart()
    }
}
