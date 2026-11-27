import SwiftUI
import UIKit

@main struct InCompanionApp: App {
    var body: some Scene {
        WindowGroup { SurfaceView().preferredColorScheme(.dark) }
    }
}

@MainActor
struct SurfaceView: View {
    @StateObject private var satellite = Satellite()
    @StateObject private var discovery = CompanionDiscovery()
    @AppStorage("savedCompanionServers") private var savedServers = Data()
    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = String(SurfaceConfiguration.defaultPort)
    @AppStorage("columns") private var columns = 5
    @AppStorage("rows") private var rows = 3
    @AppStorage("verifiedWebSocketConfiguration") private var configured = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("awake") private var awake = true
    @State private var settings = false
    @State private var launchWizard = false
    @State private var full = false
    @State private var started = false
    @State private var reconnectOnForeground = true
    @State private var activeID: String?
    @State private var activeService: NearbyCompanion?
    @AppStorage("migratedCompanionServers") private var legacyServerMigrated = false
    @Environment(\.scenePhase) private var phase

    private var profiles: [SavedCompanion] {
        (try? JSONDecoder().decode([SavedCompanion].self, from: savedServers)) ?? []
    }

    private var activeProfile: SavedCompanion? { profiles.first { $0.id == activeID } }

    private var automaticProfile: SavedCompanion? {
        SavedCompanion.automaticMatch(in: profiles, discoveredIDs: discovery.servers.map(\.serverID))
    }

    private var connectionStatus: String {
        if activeID != nil { return satellite.stage.rawValue }
        if profiles.isEmpty { return "Setup required" }
        let known = Set(profiles.compactMap(\.bonjourID))
        if discovery.servers.filter({ known.contains($0.serverID) }).count > 1 { return "Choose Companion" }
        return "Select a server"
    }

    var body: some View {
        VStack(spacing: 8) {
            if !full {
                ZStack {
                    VStack(spacing: 3) {
                        (Text("In") + Text(".").foregroundColor(.yellow) + Text("Companion"))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                        Capsule()
                            .fill(LinearGradient(colors: [.yellow, .green], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 74, height: 2)
                    }
                    HStack {
                        Spacer()
                        Button {
                            satellite.releaseAll()
                            launchWizard = false
                            settings = true
                        } label: {
                            Image(systemName: "gearshape.fill").font(.title2).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                HStack {
                    Circle().fill(satellite.connected ? Color.green : Color.red).frame(width: 7, height: 7)
                    Text(connectionStatus).lineLimit(1)
                    Spacer()
                    Text(activeService?.name ?? activeProfile?.configuration.host ?? "").monospacedDigit().lineLimit(1)
                    Button {
                        satellite.releaseAll()
                        full = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Full screen")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let columnCount = activeProfile?.configuration.columns ?? min(8, max(1, columns))
                let rowCount = activeProfile?.configuration.rows ?? min(6, max(1, rows))
                let gap: CGFloat = 7
                let width = (geometry.size.width - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount)
                let height = (geometry.size.height - CGFloat(rowCount - 1) * gap) / CGFloat(rowCount)
                let side = max(1, min(width, height))
                VStack(spacing: gap) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<columnCount, id: \.self) { column in
                                let index = row * columnCount + column
                                let image = satellite.connected && !satellite.usesTestConfiguration ? satellite.images[index] : nil
                                DeckKey(image: image, enabled: image != nil && !settings && phase == .active,
                                        down: satellite.held.contains(index) || satellite.remoteHeld.contains(index),
                                        haptics: haptics) { pressed in
                                    if !pressed || (!settings && phase == .active) { satellite.press(index, pressed) }
                                }
                                .frame(width: side, height: side)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if full {
                Button {
                    satellite.releaseAll()
                    full = false
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 44, height: 30)
                }
                .accessibilityLabel("Exit full screen")
            }
        }
        .padding(12)
        .background(Color(white: 0.035).ignoresSafeArea())
        .sheet(isPresented: $settings, onDismiss: cancelTest) {
            CompanionSettings(
                satellite: satellite, discovery: discovery, haptics: $haptics, awake: $awake,
                showWizard: launchWizard, host: host,
                port: !configured && port == "16622" ? String(SurfaceConfiguration.defaultPort) : port,
                columns: activeProfile?.configuration.columns ?? columns,
                rows: activeProfile?.configuration.rows ?? rows,
                profiles: profiles, activeID: activeID,
                test: testConfiguration, save: saveConfiguration, cancelTest: cancelTest,
                select: selectSaved, remove: removeProfile,
                connect: connectSaved, disconnect: disconnectSaved,
                canConnect: activeProfile != nil || automaticProfile != nil
            )
        }
        .task(id: discovery.servers) {
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            reconcileServers()
        }
        .onChange(of: satellite.stage) { _, stage in
            if stage == .reconnecting || stage == .failed { reconcileServers() }
        }
        .onChange(of: phase) { _, newPhase in
            updateIdleTimer()
            switch newPhase {
            case .active:
                discovery.start()
                reconcileServers()
            case .inactive:
                satellite.releaseAll()
            case .background:
                discovery.stop()
                satellite.disconnect()
                clearSelection()
            @unknown default:
                break
            }
        }
        .onChange(of: awake) { _, _ in updateIdleTimer() }
        .onAppear {
            updateIdleTimer()
            guard !started else { return }
            started = true
            migrateLegacyServer()
            discovery.start()
            if profiles.isEmpty {
                launchWizard = true
                settings = true
            }
        }
        .onDisappear {
            discovery.stop()
            satellite.disconnect()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = phase == .active && awake
    }

    private func migrateLegacyServer() {
        guard !legacyServerMigrated else { return }
        legacyServerMigrated = true
        guard savedServers.isEmpty, configured,
              let configuration = SurfaceConfiguration(host: host, port: port, columns: columns, rows: rows)
        else { return }
        storeProfiles([SavedCompanion(configuration: configuration, bonjourID: nil)])
    }

    private func storeProfiles(_ profiles: [SavedCompanion]) {
        if let encoded = try? JSONEncoder().encode(profiles) { savedServers = encoded }
    }

    private func nearbyServer(for profile: SavedCompanion) -> NearbyCompanion? {
        guard let id = profile.bonjourID else { return nil }
        let matches = discovery.servers.filter { $0.serverID == id }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private func reconcileServers() {
        guard phase == .active, reconnectOnForeground, !satellite.usesTestConfiguration else { return }
        if let activeProfile {
            if activeProfile.bonjourID != nil {
                if let service = nearbyServer(for: activeProfile) {
                    if service != activeService { activate(activeProfile) }
                    return
                }
            } else {
                guard automaticProfile != nil,
                      satellite.stage == .reconnecting || satellite.stage == .failed else { return }
            }
            satellite.disconnect()
            clearSelection()
        }
        if let profile = automaticProfile { activate(profile) }
    }

    private func activate(_ profile: SavedCompanion) {
        let service = nearbyServer(for: profile)
        guard profile.bonjourID == nil || service != nil else { return }
        activeID = profile.id
        activeService = service
        satellite.connect(profile.configuration, endpoint: service?.endpoint)
    }

    private func selectSaved(_ profile: SavedCompanion) {
        reconnectOnForeground = true
        activate(profile)
        settings = false
    }

    private func connectSaved() {
        reconnectOnForeground = true
        discovery.start()
        if let profile = activeProfile ?? automaticProfile { activate(profile) }
    }

    private func disconnectSaved() {
        reconnectOnForeground = false
        satellite.disconnect()
    }

    private func removeProfile(_ profile: SavedCompanion) {
        if activeID == profile.id {
            satellite.disconnect()
            clearSelection()
        }
        storeProfiles(profiles.filter { $0.id != profile.id })
        reconcileServers()
    }

    private func testConfiguration(_ configuration: SurfaceConfiguration, _ service: NearbyCompanion?) {
        satellite.connect(configuration, endpoint: service?.endpoint, testing: true)
    }

    private func saveConfiguration(_ configuration: SurfaceConfiguration, _ service: NearbyCompanion?) {
        guard satellite.connected, satellite.usesTestConfiguration, satellite.configuration == configuration else { return }
        let profile = SavedCompanion(configuration: configuration, bonjourID: service?.serverID)
        if let service, nearbyServer(for: profile) != service { return }
        storeProfiles(profiles.filter { $0.id != profile.id } + [profile])
        activeID = profile.id
        activeService = service
        reconnectOnForeground = true
        satellite.acceptTest()
        settings = false
    }

    private func cancelTest() {
        guard satellite.usesTestConfiguration else { return }
        satellite.discardTest()
        guard phase != .background, reconnectOnForeground else { return }
        if let profile = activeProfile, profile.bonjourID == nil || nearbyServer(for: profile) != nil {
            activate(profile)
        } else {
            clearSelection()
            reconcileServers()
        }
    }

    private func clearSelection() {
        activeID = nil
        activeService = nil
    }
}

struct DeckKey: View {
    let image: UIImage?
    let enabled: Bool
    let down: Bool
    let haptics: Bool
    let action: (Bool) -> Void
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width,geo.size.height)
            let radius = size*0.17
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(LinearGradient(colors:[Color(white:0.27),.black],startPoint:.top,endPoint:.bottom))
                ZStack {
                    RoundedRectangle(cornerRadius: radius*0.8).fill(.black)
                    if let image { Image(uiImage:image).resizable().interpolation(.high).aspectRatio(contentMode:.fit) }
                }.padding(size*0.065)
                RoundedRectangle(cornerRadius:radius).strokeBorder(LinearGradient(colors:[.white.opacity(0.28),.white.opacity(0.04)],startPoint:.top,endPoint:.bottom),lineWidth:1)
            }.shadow(color:.black.opacity(0.9),radius:3,y:3).scaleEffect(down ? 0.94 : 1)
             .overlay { TouchKey(enabled:enabled) { value in if value && haptics { UIImpactFeedbackGenerator(style:.light).impactOccurred() }; action(value) } }
        }.accessibilityLabel("Companion key").accessibilityAddTraits(.isButton).accessibilityAction { if enabled { action(true); action(false) } }
    }
}

struct TouchKey: UIViewRepresentable {
    var enabled: Bool
    var action: (Bool) -> Void
    func makeUIView(context: Context) -> KeyTouchView { KeyTouchView() }
    func updateUIView(_ view: KeyTouchView, context: Context) { view.action = action; if !enabled { view.finish() }; view.isUserInteractionEnabled = enabled }
    static func dismantleUIView(_ view: KeyTouchView, coordinator: ()) { view.finish() }
}
final class KeyTouchView: UIView {
    var action: ((Bool)->Void)?
    private var active = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { guard !active else { return }; active = true; action?(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }
    func finish() { guard active else { return }; active = false; action?(false) }
}
