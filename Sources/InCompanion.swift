import SwiftUI
import UIKit

@main struct InCompanionApp: App {
    var body: some Scene {
        WindowGroup { SurfaceView().preferredColorScheme(.dark) }
    }
}

@MainActor
struct SurfaceView: View {
    private static let cornerSize: CGFloat = 44

    @StateObject private var satellite = Satellite()
    @StateObject private var discovery = CompanionDiscovery()
    @AppStorage("savedCompanionServers") private var savedServers = Data()
    @AppStorage("migratedCompanionServers") private var legacyServerMigrated = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("awake") private var awake = true
    @State private var showServers = false
    @State private var fullScreen = false
    @State private var activeProfile: SavedCompanion?
    @State private var activeService: NearbyCompanion?
    @State private var autoConnect = true
    @Environment(\.scenePhase) private var phase

    private var profiles: [SavedCompanion] {
        (try? JSONDecoder().decode([SavedCompanion].self, from: savedServers)) ?? []
    }

    private var automaticProfile: SavedCompanion? {
        SavedCompanion.automaticMatch(in: profiles, discoveredIDs: discovery.servers.map(\.serverID))
    }

    private var serverName: String {
        activeService?.name ?? activeProfile?.configuration.host ?? "Companion"
    }

    var body: some View {
        GeometryReader { screen in
            let insets = screen.safeAreaInsets
            let landscape = screen.size.width + insets.leading + insets.trailing
                > screen.size.height + insets.top + insets.bottom
            let compactFullScreen = fullScreen && landscape
            let centerOffset = compactFullScreen
                ? CGPoint(x: (insets.trailing - insets.leading) / 2, y: (insets.bottom - insets.top) / 2)
                : .zero
            VStack(spacing: compactFullScreen ? 0 : 8) {
                if !compactFullScreen {
                    header
                        .opacity(fullScreen ? 0 : 1)
                        .allowsHitTesting(!fullScreen)
                        .accessibilityHidden(fullScreen)
                }
                GeometryReader { geometry in
                    let columns = activeProfile == nil ? 5 : satellite.configuration?.columns ?? 5
                    let rows = activeProfile == nil ? 3 : satellite.configuration?.rows ?? 3
                    let grid = DeckLayout(size: geometry.size, columns: columns, rows: rows,
                                          corner: compactFullScreen ? Self.cornerSize : 0,
                                          centerOffset: centerOffset)
                    VStack(spacing: grid.gap) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: grid.gap) {
                                ForEach(0..<columns, id: \.self) { column in
                                    let index = row * columns + column
                                    DeckKey(image: satellite.images[index],
                                            enabled: satellite.inputReady && !showServers && phase == .active,
                                            down: satellite.held.contains(index) || satellite.remoteHeld.contains(index),
                                            haptics: haptics, title: "Companion key \(row + 1), \(column + 1)") { down in
                                        satellite.press(index, down)
                                    }
                                    .frame(width: grid.side, height: grid.side)
                                }
                            }
                        }
                    }
                    .position(x: grid.center.x, y: grid.center.y)
                }
            }
            .padding(compactFullScreen ? 4 : 12)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                satellite.releaseAll()
                fullScreen.toggle()
            } label: {
                Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: Self.cornerSize, height: Self.cornerSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fullScreen ? "Exit full screen" : "Full screen")
            .padding(fullScreen ? 4 : 12)
        }
        .background(Color(white: 0.035).ignoresSafeArea())
        .sheet(isPresented: $showServers) { serverPicker }
        .task(id: phase == .active ? discovery.servers : []) {
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            reconcileServers()
        }
        .onChange(of: satellite.configuration) { _, configuration in
            if let configuration, let profile = activeProfile, configuration != profile.configuration {
                let updated = SavedCompanion(configuration: configuration, bonjourID: profile.bonjourID)
                activeProfile = updated
                save(updated)
            }
        }
        .onChange(of: awake) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = phase == .active && awake
        }
        .onChange(of: satellite.stage) { _, stage in
            if stage == .connected, let activeProfile {
                save(activeProfile)
            }
            if stage == .reconnecting || stage == .failed { reconcileServers() }
        }
        .onChange(of: phase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active && awake
            switch phase {
            case .active:
                discovery.start()
                satellite.resumeConnection()
            case .inactive, .background:
                satellite.releaseAll()
            @unknown default:
                break
            }
        }
        .onAppear {
            #if DEBUG && APP_STORE_SCREENSHOTS
            if let scene = AppStoreScreenshot.current {
                if scene == .servers {
                    activeService = discovery.loadScreenshotServers()
                    showServers = true
                } else {
                    activeService = NearbyCompanion(serverID: "capture", name: scene.serverName,
                                                    domain: "local.", type: CompanionDiscovery.serviceType)
                }
                fullScreen = scene == .fullScreen
                satellite.loadScreenshot(scene)
                return
            }
            #endif
            UIApplication.shared.isIdleTimerDisabled = phase == .active && awake
            migrateLegacyServer()
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
            disconnect()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                (Text("In") + Text(".").foregroundColor(.yellow) + Text("Companion"))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Capsule()
                    .fill(LinearGradient(colors: [.yellow, .green], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 74, height: 2)
            }
            .frame(height: Self.cornerSize)
            .padding(.horizontal, Self.cornerSize)

            HStack {
                Button(action: openServers) {
                    HStack(spacing: 6) {
                        Circle().fill(satellite.connected ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(satellite.stage.rawValue).lineLimit(1)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                Spacer(minLength: 12)
                Button(action: openServers) {
                    HStack(spacing: 5) {
                        Text(serverName).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Choose Companion server, \(serverName)")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var serverPicker: some View {
        NavigationStack {
            List {
                Section("Nearby") {
                    if discovery.servers.isEmpty {
                        Text(discovery.status).foregroundStyle(.secondary)
                    }
                    ForEach(discovery.servers) { server in
                        Button {
                            select(server)
                        } label: {
                            HStack {
                                Text(server.name)
                                Spacer()
                                if activeService == server {
                                    if satellite.connected { Image(systemName: "checkmark") }
                                    else { Text(satellite.stage.rawValue).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        .disabled(discovery.servers.filter { $0.serverID == server.serverID }.count != 1)
                    }
                }
                let manual = profiles.filter { $0.bonjourID == nil }
                if !manual.isEmpty {
                    Section("Saved addresses") {
                        ForEach(manual) { server in
                            Button(server.configuration.host) { select(server) }
                        }
                    }
                }
                if let reply = satellite.lastButtonReply {
                    LabeledContent("Last button reply") {
                        Text(reply).multilineTextAlignment(.trailing)
                    }
                }
                if let error = satellite.error {
                    Text(error).foregroundStyle(.secondary)
                }
                Toggle("Keep Screen Awake", isOn: $awake)
                if activeProfile != nil {
                    Button("Disconnect", role: .destructive) {
                        autoConnect = false
                        disconnect()
                        showServers = false
                    }
                }
                Section {
                    Text("Settings > Protocol > Enable Button Subscriptions API")
                    Text("Settings > General > Announce Companion on the network (mDNS/Bonjour)")
                }
            }
            .navigationTitle("Companion Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showServers = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func openServers() {
        satellite.releaseAll()
        discovery.start()
        showServers = true
    }

    private func nearbyServer(for profile: SavedCompanion) -> NearbyCompanion? {
        let matches = discovery.servers.filter { $0.serverID == profile.bonjourID }
        return matches.count == 1 ? matches.first : nil
    }

    private func reconcileServers() {
        #if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshot.current != nil { return }
        #endif
        guard phase == .active, autoConnect else { return }
        if let profile = activeProfile {
            if profile.bonjourID != nil {
                if let service = nearbyServer(for: profile) {
                    if service != activeService { connect(profile, service: service) }
                    return
                }
            }
            // The retained service endpoint can reconnect without waiting for the
            // Bonjour picker to repopulate. Switch only to another known server on loss.
            guard let alternate = automaticProfile, alternate.id != profile.id,
                  satellite.stage == .reconnecting || satellite.stage == .failed else { return }
            disconnect()
        }
        if let profile = automaticProfile, let service = nearbyServer(for: profile) {
            connect(profile, service: service)
        }
    }

    private func select(_ service: NearbyCompanion) {
        let saved = profiles.first { $0.bonjourID == service.serverID }
        guard let configuration = SurfaceConfiguration(
            bonjourName: service.name, columns: saved?.configuration.columns ?? 5, rows: saved?.configuration.rows ?? 3
        ) else { return }
        select(SavedCompanion(configuration: configuration, bonjourID: service.serverID), service: service)
    }

    private func select(_ profile: SavedCompanion, service: NearbyCompanion? = nil) {
        autoConnect = true
        if profile != activeProfile || service != activeService || !satellite.connected {
            connect(profile, service: service)
        }
        showServers = false
    }

    private func connect(_ profile: SavedCompanion, service: NearbyCompanion?) {
        activeProfile = profile
        activeService = service
        satellite.connect(profile.configuration, endpoint: service?.endpoint)
    }

    private func disconnect() {
        satellite.disconnect()
        activeProfile = nil
        activeService = nil
    }

    private func save(_ profile: SavedCompanion) {
        let previous = profiles
        guard !previous.contains(profile) else { return }
        if let data = try? JSONEncoder().encode(previous.filter { $0.id != profile.id } + [profile]) {
            savedServers = data
        }
    }

    private func migrateLegacyServer() {
        guard !legacyServerMigrated else { return }
        legacyServerMigrated = true
        let defaults = UserDefaults.standard
        guard profiles.isEmpty, defaults.bool(forKey: "verifiedWebSocketConfiguration"),
              let host = defaults.string(forKey: "host"),
              let port = defaults.string(forKey: "port"),
              let configuration = SurfaceConfiguration(host: host, port: port,
                                                       columns: defaults.object(forKey: "columns") as? Int ?? 5,
                                                       rows: defaults.object(forKey: "rows") as? Int ?? 3)
        else { return }
        save(SavedCompanion(configuration: configuration, bonjourID: nil))
    }
}
