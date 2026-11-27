import Combine
import Network

struct NearbyCompanion: Equatable, Identifiable {
    let serverID: String
    let name: String
    let domain: String
    let type: String

    var id: String { "\(serverID)|\(name)|\(domain)|\(type)" }
    var endpoint: NWEndpoint { .service(name: name, type: type, domain: domain, interface: nil) }
}

@MainActor
final class CompanionDiscovery: ObservableObject {
    static let serviceType = "_comp-sat-ws._tcp"

    @Published private(set) var servers: [NearbyCompanion] = []
    @Published private(set) var status = "Looking for Companion"
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        status = "Looking for Companion"
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                let services = results.compactMap { result -> NearbyCompanion? in
                    guard case let .service(name, type, domain, _) = result.endpoint,
                          case let .bonjour(record) = result.metadata,
                          let id = record["id"], !id.isEmpty, id.utf8.count <= 255 else { return nil }
                    return NearbyCompanion(serverID: id, name: name, domain: domain, type: type)
                }
                var seen = Set<String>()
                self.servers = services.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
                self.updateStatus()
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready:
                    self.updateStatus()
                case .waiting(let error):
                    self.servers = []
                    self.status = "Bonjour waiting. Check Wi-Fi and iOS Local Network access. (\(error))"
                case .failed(let error):
                    self.stop()
                    self.status = "Bonjour unavailable (\(error))"
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        let old = browser
        browser = nil
        old?.cancel()
        servers = []
    }

    private func updateStatus() {
        status = servers.isEmpty ? "Looking for Companion" : "\(servers.count) available"
    }
}
