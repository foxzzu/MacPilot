import SwiftUI

/// Paired Macs plus whatever Bonjour currently sees on this network.
struct DevicesView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @State private var pendingRemoval: PairedMac?
    @State private var showsAddressSheet = false
    @State private var host = ""
    @State private var port = "43847"


    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showsAddressSheet = true } label: {
                        Label(appModel.text("manualAdd"), systemImage: "plus")
                    }
                }
                pairedSection
                discoveredSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(appModel.text("devicesTitle"))
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showsAddressSheet) { addressSheet }
            .confirmationDialog(
                appModel.text("forgetConfirmTitle"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(appModel.text("forget"), role: .destructive) {
                    if let mac = pendingRemoval { appModel.forget(mac) }
                    pendingRemoval = nil
                }
                Button(appModel.text("pairingCancel"), role: .cancel) { pendingRemoval = nil }
            } message: {
                Text(appModel.text("forgetConfirmMessage"))
            }
        }
    }

    private var addressSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(appModel.text("manualHost"), text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField(appModel.text("manualPort"), text: $port)
                        .keyboardType(.numberPad)
                } footer: {
                    Text(appModel.text("manualHint"))
                }
                Section {
                    Button(appModel.text("manualConnect")) {
                        guard let address = ManualMacAddress(host: host, port: port) else { return }
                        showsAddressSheet = false
                        appModel.connect(to: address)
                    }
                    .disabled(ManualMacAddress(host: host, port: port) == nil)
                } footer: {
                    if ManualMacAddress(host: host, port: port) == nil {
                        Text(appModel.text("manualInvalid"))
                    }
                }
            }
            .navigationTitle(appModel.text("manualAdd"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(appModel.text("pairingCancel")) { showsAddressSheet = false }
                }
            }
        }
    }

    private var pairedSection: some View {
        Section {
            if appModel.pairedMacs.isEmpty {
                Text(appModel.text("noPaired"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.pairedMacs) { mac in
                    pairedRow(mac)
                }
            }
        } header: {
            Text(appModel.text("pairedSection"))
        } footer: {
            Text(appModel.text("devicesSubtitle"))
        }
    }

    private func pairedRow(_ mac: PairedMac) -> some View {
        let presence = appModel.status(for: mac)
        return HStack(spacing: 12) {
            Circle()
                .fill(color(for: presence))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mac.name).font(.body)
                    if appModel.isDefault(mac) {
                        Text(appModel.text("defaultMac"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(statusCaption(for: presence))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if presence != .connected {
                Button(appModel.text("setDefault")) { appModel.connect(to: mac) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .swipeActions {
            Button(appModel.text("forget"), role: .destructive) { pendingRemoval = mac }
        }
    }

    private var discoveredSection: some View {
        Section(appModel.text("discoveredSection")) {
            Button {
                appModel.searchDevices()
            } label: {
                Label(appModel.text("searchDevices"), systemImage: "arrow.clockwise")
            }
            let unpaired = appModel.discoveredMacs.filter { !appModel.store.isPaired(id: $0.id) }
            if unpaired.isEmpty {
                // "No MacPilot found" would be wrong here: a Mac may be present
                // and already paired, it just is not a pairing candidate.
                Text(appModel.text("noNewDevices"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(unpaired) { mac in
                    HStack(spacing: 12) {
                        Circle().fill(.blue).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mac.name).font(.body)
                            Text(mac.version.isEmpty ? appModel.text("online") : "v\(mac.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if appModel.pairingTargetID == mac.id, appModel.errorKey == nil {
                            ProgressView()
                                .accessibilityLabel(appModel.text("pairingConnecting"))
                        } else {
                            Button(appModel.text(appModel.pairingTargetID == mac.id ? "retry" : "pairDevice")) {
                                appModel.pair(with: mac)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            if appModel.pairingTargetID != nil {
                if let errorKey = appModel.errorKey {
                    Text(appModel.text(errorKey))
                        .foregroundStyle(.orange)
                    Button(appModel.text("retry")) { appModel.retry() }
                } else {
                    Text(appModel.text("pairingConnecting"))
                        .foregroundStyle(.secondary)
                }
                Button(appModel.text("pairingCancel")) { appModel.cancelPairing() }
            }
        }
    }

    private func color(for presence: RemoteAppModel.MacPresence) -> Color {
        switch presence {
        case .connected: return .green
        case .online: return .blue
        case .offline: return .secondary
        }
    }

    private func label(for presence: RemoteAppModel.MacPresence) -> String {
        switch presence {
        case .connected: return appModel.text("connectedLabel")
        case .online: return appModel.text("online")
        case .offline: return appModel.text("offline")
        }
    }

    /// Latency is only measured on the session actually carrying commands, so
    /// the caption carries it for the connected Mac and stays plain otherwise.
    private func statusCaption(for presence: RemoteAppModel.MacPresence) -> String {
        let label = label(for: presence)
        guard presence == .connected, let latency = appModel.latencyMs else { return label }
        return "\(label) · \(appModel.text("latency", latency))"
    }
}
