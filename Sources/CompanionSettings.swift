import SwiftUI
import UIKit

@MainActor
struct CompanionSettings: View {
    @ObservedObject var satellite: Satellite
    @ObservedObject var discovery: CompanionDiscovery
    @Binding var haptics: Bool
    @Binding var awake: Bool
    let showWizard: Bool
    let host: String
    let port: String
    let columns: Int
    let rows: Int
    let profiles: [SavedCompanion]
    let activeID: String?
    let test: (SurfaceConfiguration, NearbyCompanion?) -> Void
    let save: (SurfaceConfiguration, NearbyCompanion?) -> Void
    let cancelTest: () -> Void
    let select: (SavedCompanion) -> Void
    let remove: (SavedCompanion) -> Void
    let connect: () -> Void
    let disconnect: () -> Void
    let canConnect: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var displayingWizard = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Button("Connection Setup") { displayingWizard = true }
                    NavigationLink("Diagnostics") {
                        ConnectionDiagnostics(satellite: satellite, connect: connect, disconnect: disconnect,
                                              canConnect: canConnect)
                    }
                }
                if !profiles.isEmpty {
                    Section("Saved Servers") {
                        ForEach(profiles) { profile in
                            HStack {
                                Button { select(profile) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.configuration.host)
                                        Text(profileStatus(profile)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!canSelect(profile))
                                Spacer()
                                Button(role: .destructive) { remove(profile) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(profile.configuration.host)")
                            }
                        }
                    }
                }
                Section("Display") {
                    Toggle("Haptic feedback", isOn: $haptics)
                    Toggle("Keep screen awake", isOn: $awake)
                }
                Section { Text("In.Companion v26.11.27.01").foregroundStyle(.secondary) }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(isPresented: $displayingWizard) {
                ConnectionWizard(satellite: satellite, discovery: discovery, profiles: profiles,
                                 host: host, port: port, columns: columns, rows: rows, test: test, save: save, cancelTest: cancelTest)
            }
        }
        .onAppear { if showWizard { displayingWizard = true } }
    }
    private func canSelect(_ profile: SavedCompanion) -> Bool {
        guard let id = profile.bonjourID else { return true }
        return discovery.servers.filter { $0.serverID == id }.count == 1
    }

    private func profileStatus(_ profile: SavedCompanion) -> String {
        if profile.id == activeID && satellite.connected { return "Connected" }
        if profile.bonjourID == nil { return "Manual address" }
        return canSelect(profile) ? "Nearby" : "Unavailable"
    }

}

@MainActor
private struct ConnectionWizard: View {
    private enum Step: Int {
        case prepare = 1
        case connect
        case surface
    }

    @ObservedObject var satellite: Satellite
    @ObservedObject var discovery: CompanionDiscovery
    let profiles: [SavedCompanion]
    let test: (SurfaceConfiguration, NearbyCompanion?) -> Void
    let save: (SurfaceConfiguration, NearbyCompanion?) -> Void
    let cancelTest: () -> Void
    @State private var step = Step.prepare
    @State private var service: NearbyCompanion?
    @State private var host: String
    @State private var port: String
    @State private var columns: Int
    @State private var rows: Int

    init(satellite: Satellite, discovery: CompanionDiscovery, profiles: [SavedCompanion],
         host: String, port: String, columns: Int, rows: Int,
         test: @escaping (SurfaceConfiguration, NearbyCompanion?) -> Void,
         save: @escaping (SurfaceConfiguration, NearbyCompanion?) -> Void,
         cancelTest: @escaping () -> Void) {
        self.satellite = satellite
        self.discovery = discovery
        self.profiles = profiles
        self.test = test
        self.save = save
        self.cancelTest = cancelTest
        _host = State(initialValue: host)
        _port = State(initialValue: port.isEmpty ? String(SurfaceConfiguration.defaultPort) : port)
        _columns = State(initialValue: min(8, max(1, columns)))
        _rows = State(initialValue: min(6, max(1, rows)))
    }

    private var draft: SurfaceConfiguration? {
        if let service { return SurfaceConfiguration(bonjourName: service.name, columns: columns, rows: rows) }
        return SurfaceConfiguration(host: host, port: port, columns: columns, rows: rows)
    }

    private var serviceAvailable: Bool {
        guard let service else { return true }
        return discovery.servers.contains(service) && uniqueService(service)
    }

    private func uniqueService(_ server: NearbyCompanion) -> Bool {
        discovery.servers.filter { $0.serverID == server.serverID }.count == 1
    }

    private var verified: Bool {
        satellite.usesTestConfiguration && satellite.connected && draft == satellite.configuration && serviceAvailable
    }

    var body: some View {
        Form {
            switch step {
            case .prepare:
                Section("1 of 3 · Prepare Companion") {
                    Text("Open Bitfocus Companion 4.3 or later on your control computer and select Launch GUI.")
                    Text("Open Settings → Protocols. If Protocols is hidden, expand Settings in the sidebar.")
                    Text("Enable Button Subscriptions API. To be found automatically, turn on Announce Companion on the network (mDNS/Bonjour) if your version offers it.")
                }
                Section { Button("Continue") { step = .connect } }
            case .connect:
                Section("2 of 3 · Nearby Companion") {
                    if discovery.servers.isEmpty {
                        Text(discovery.status).foregroundStyle(.secondary)
                    }
                    ForEach(discovery.servers) { server in
                        Button {
                            service = server
                            if let profile = profiles.first(where: { $0.bonjourID == server.serverID }) {
                                resize(columns: profile.configuration.columns, rows: profile.configuration.rows)
                            }
                            runTest()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name)
                                if !uniqueService(server) {
                                    Text("Duplicate Companion ID").foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                        .disabled(!uniqueService(server))
                    }
                }
                Section("Manual Address") {
                    TextField("Hostname or IP address", text: $host, prompt: Text("companion.local"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Satellite WebSocket port", text: $port)
                        .keyboardType(.numberPad)
                    Button("Test Connection") {
                        service = nil
                        runTest()
                    }
                    .disabled(SurfaceConfiguration(host: host, port: port, columns: columns, rows: rows) == nil)
                }
                Section("Local Network") {
                    Text("Connect your iPhone or iPad to the same network as Companion. Tap Allow when iOS asks for Local Network access. If access was denied, enable Local Network for In.Companion in iOS Settings.")
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section { Button("Previous") { step = .prepare } }
            case .surface:
                Section("3 of 3 · Configure Surface") {
                    LabeledContent("Server", value: draft?.host ?? "—")
                    LabeledContent("Status", value: satellite.stage.rawValue)
                    if !serviceAvailable {
                        Text("This Companion is no longer uniquely available on this network.")
                            .foregroundStyle(.red)
                    }
                    verificationRow("WebSocket opened", passed: satellite.verification.webSocket)
                    verificationRow("Companion API compatible", passed: satellite.verification.compatibleAPI)
                    verificationRow("Button subscription accepted", passed: satellite.verification.subscriptionAccepted)
                    verificationRow("Surface registered", passed: satellite.verification.registered)
                    verificationRow("Button artwork received", passed: satellite.verification.surfaceArtwork && satellite.verification.subscriptionArtwork)
                    if let error = satellite.error { Text(error).foregroundStyle(.red) }
                    Text("In.Companion registers its own surface in Companion. Set its starting page and assignments in Companion’s Surfaces tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Layout") {
                    Menu {
                        Button("Mini · 3 × 2") { resize(columns: 3, rows: 2) }
                        Button("Standard · 5 × 3") { resize(columns: 5, rows: 3) }
                        Button("XL · 8 × 4") { resize(columns: 8, rows: 4) }
                        Button("Extended · 8 × 6") { resize(columns: 8, rows: 6) }
                    } label: {
                        LabeledContent("Preset", value: "\(columns) × \(rows)")
                    }
                    Stepper("Columns · \(columns)", value: $columns, in: 1...8)
                    Stepper("Rows · \(rows)", value: $rows, in: 1...6)
                    if satellite.configuration != draft {
                        Text("Test this layout before opening the surface.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Open Surface") { if let draft, verified { save(draft, service) } }.disabled(!verified)
                    Button("Test Again") { runTest() }.disabled(draft == nil || !serviceAvailable)
                    Button("Change Server") {
                        cancelTest()
                        step = .connect
                    }
                }
            }
        }
        .navigationTitle("Connection Setup")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: cancelTest)
    }

    private func runTest() {
        guard let draft, serviceAvailable else { return }
        step = .surface
        test(draft, service)
    }

    private func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    private func verificationRow(_ label: String, passed: Bool) -> some View {
        Label(label, systemImage: passed ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(passed ? Color.green : Color.secondary)
            .accessibilityValue(passed ? "Verified" : "Pending")
    }
}

@MainActor
private struct ConnectionDiagnostics: View {
    @ObservedObject var satellite: Satellite
    let connect: () -> Void
    let disconnect: () -> Void
    let canConnect: Bool

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Server", value: satellite.diagnosticHost)
                LabeledContent("Port", value: satellite.diagnosticPort)
                LabeledContent("Protocol", value: "Satellite WebSocket")
                LabeledContent("Status", value: satellite.stage.rawValue)
                LabeledContent("Companion version", value: satellite.companionVersion ?? "—")
                LabeledContent("API version", value: satellite.apiVersion ?? "—")
                LabeledContent("Surface name", value: Satellite.surfaceName)
                LabeledContent("Surface identifier", value: satellite.surfaceID)
                LabeledContent("Last successful connection",
                               value: satellite.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                LabeledContent("Button images received", value: String(satellite.imageCount))
                if let error = satellite.error { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button("Connect", action: connect).disabled(!canConnect || satellite.mayDisconnect)
                Button("Disconnect", action: disconnect).disabled(!satellite.mayDisconnect)
                Button("Retry Connection", action: connect).disabled(!canConnect)
                Button("Copy Diagnostics") { UIPasteboard.general.string = satellite.diagnostics }
                Button("Clear Diagnostics", role: .destructive) { satellite.clearDiagnostics() }
            }
            Section("Protocol Messages") {
                if satellite.log.isEmpty {
                    Text("No messages yet").foregroundStyle(.secondary)
                }
                ForEach(Array(satellite.log.enumerated()), id: \.offset) { entry in
                    Text(entry.element).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
