import SwiftUI

struct LocationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var simulation = LocationSimulationSession.shared
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @State private var remotePairingPort = UserDefaults.standard.string(forKey: "TunnelRemotePairingPort") ?? ""
    @State private var targetIPAddress = DeviceConnectionContext.targetIPAddress
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var pairingExists = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
    @State private var pairingName = UserDefaults.standard.string(forKey: "ImportedRemotePairingName")
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case address, port }
    private var connectionIsBusy: Bool {
        tunnel.isStarting || mounting.isPreparing || simulation.preventsConnectionChanges
    }
    private var address: String { targetIPAddress.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: String { remotePairingPort.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var inputError: String? {
        if !address.isEmpty, let message = DeviceConnectionContext.validationMessage(for: address) { return message }
        if !port.isEmpty, UInt16(port).map({ $0 != 0 }) != true {
            return "Remote Pairing port must be between 1 and 65535, or empty for automatic discovery."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Wi-Fi IPv4 Address") {
                        TextField("192.168.1.25", text: $targetIPAddress)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .address)
                            .accessibilityLabel("Remote iPhone Wi-Fi IPv4 Address")
                    }
                    .disabled(connectionIsBusy)
                } header: {
                    Text("1. Remote iPhone")
                } footer: {
                    Text("On the other iPhone, open Settings > Wi-Fi > your network to find its IP address. Enable Developer Mode and keep that iPhone unlocked. Both phones must be able to reach each other over the network.")
                }

                Section {
                    Label(pairingExists ? (pairingName ?? "Remote Pairing file imported") : "No pairing file selected",
                          systemImage: pairingExists ? "checkmark.circle.fill" : "doc.badge.plus")
                        .foregroundStyle(pairingExists ? Color.green : Color.secondary)
                    Button(pairingExists ? "Replace Pairing File" : "Import Pairing File") {
                        focusedField = nil
                        showImporter = true
                    }
                    .disabled(connectionIsBusy)
                } header: {
                    Text("2. Remote Pairing File")
                } footer: {
                    Text("Import the Remote Pairing file generated for the other iPhone. It does not need to match this controller iPhone. Importing a file does not start a connection.")
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            Text(tunnel.isStarting ? "Connecting to Remote iPhone..." : "Connect to Remote iPhone")
                            Spacer()
                        }
                    }
                    .disabled(connectionIsBusy || !pairingExists || address.isEmpty || inputError != nil)
                    DeviceConnectionStatusView()
                    if let message = inputError ?? errorMessage {
                        Text(message).foregroundStyle(.red).textSelection(.enabled)
                    }
                } header: {
                    Text("3. Connect")
                } footer: {
                    Text("After connecting, the app automatically checks and prepares the remote iPhone's Developer Disk Image. Wait until it is ready, then close settings and choose coordinates on the map.")
                }

                if tunnel.isConnected {
                    Section("Developer Disk Image") {
                        if mounting.isPreparing {
                            ProgressView("Preparing remote iPhone...")
                        } else {
                            Label(mounting.coolisMounted ? "Ready for location simulation" : "Developer Disk Image is not ready",
                                  systemImage: mounting.coolisMounted ? "checkmark.circle.fill" : "externaldrive.badge.exclamationmark")
                        }
                        Button("Retry Developer Disk Setup", action: mounting.pubMount)
                            .disabled(connectionIsBusy)
                    }
                }

                Section {
                    DisclosureGroup("Advanced Connection Settings") {
                        LabeledContent("Remote Pairing Port") {
                            TextField("Automatic", text: $remotePairingPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .port)
                                .accessibilityLabel("Remote Pairing Port")
                        }
                        .disabled(connectionIsBusy)
                        Text("Leave empty to discover the port at the entered address. If discovery fails, port 49152 is tried. Enter the remote iPhone's actual port if needed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Background Activity") {
                        Toggle("Keep Alive with Audio", isOn: $keepAliveAudio)
                        Text("Keeps the controller active while sending coordinates to the remote iPhone. iOS may suspend updates when background activity is disabled.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Remote iPhone")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
                guard !connectionIsBusy else { return }
                do {
                    let source = try result.get()
                    try PairingFileStore.importFromPicker(source)
                    pairingExists = true
                    pairingName = source.lastPathComponent
                    UserDefaults.standard.set(pairingName, forKey: "ImportedRemotePairingName")
                    errorMessage = nil
                    tunnel.markDisconnected()
                } catch let error as CocoaError where error.code == .userCancelled {
                    // Cancelling the picker leaves the selected file intact.
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: keepAliveAudio) { _, _ in BackgroundAudioManager.shared.configurationDidChange() }
            .onChange(of: targetIPAddress) { _, _ in errorMessage = nil }
            .onChange(of: remotePairingPort) { _, _ in errorMessage = nil }
        }
    }

    private func connect() {
        guard !connectionIsBusy else { return }
        focusedField = nil
        if let validationError = DeviceConnectionContext.validationMessage(for: address) ?? inputError {
            errorMessage = validationError
            return
        }
        guard pairingExists else {
            errorMessage = "Import the remote iPhone's Remote Pairing file first."
            return
        }
        UserDefaults.standard.set(address, forKey: DeviceConnectionContext.targetAddressKey)
        UserDefaults.standard.set(port, forKey: "TunnelRemotePairingPort")
        errorMessage = nil
        tunnel.start()
    }
}
