import SwiftUI
import UIKit

struct DeviceConnectionStatusView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @State private var didCopy = false
    var errorMessage: String?

    private var isWorking: Bool { tunnel.isStarting || mounting.isPreparing }
    private var errorDetail: String? {
        tunnel.lastError.map { "Code \($0.code): \($0.localizedDescription)" }
            ?? mounting.lastError ?? errorMessage
    }
    private var diagnosis: ConnectionDiagnosis? { tunnel.lastDiagnosis }
    private var title: String {
        if tunnel.isStarting { return "Connecting to remote iPhone..." }
        if mounting.isPreparing { return "Preparing remote Developer Disk Image..." }
        if let diagnosis { return diagnosis.title }
        if errorDetail != nil { return "Remote iPhone needs attention" }
        if !tunnel.isConnected { return "Remote iPhone not connected" }
        return mounting.coolisMounted ? "Remote iPhone ready" : "Remote iPhone connected"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isWorking {
                ProgressView()
            } else {
                Image(systemName: diagnosis?.systemImage ?? (tunnel.isConnected && errorDetail == nil ? "checkmark.circle" : "exclamationmark.circle"))
                    .foregroundStyle(tunnel.isConnected && errorDetail == nil ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let target = tunnel.connectionTarget {
                    Text("Remote iPhone: \(target)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                if !isWorking, let diagnosis {
                    Text(diagnosis.message).font(.subheadline)
                }
                if !isWorking, let detail = errorDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isWorking, let detail = errorDetail {
                Button {
                    let target = tunnel.connectionTarget ?? "Not selected"
                    UIPasteboard.general.string = "Remote iPhone: \(target)\n\(detail)\nController diagnostics:\n\(connectionDiagnosticDetails())"
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(didCopy ? "Error copied" : "Copy Error")
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    didCopy = false
                }
            }
        }
        .onChange(of: errorDetail) { _, _ in didCopy = false }
    }
}
