import SwiftUI
import UIKit

@main struct InCompanionApp: App {
    var body: some Scene { WindowGroup { SurfaceView().preferredColorScheme(.dark) } }
}

struct SurfaceView: View {
    @StateObject private var satellite = Satellite()
    @AppStorage("host") private var host = "192.168.1.100"
    @AppStorage("port") private var port = "16622"
    @AppStorage("columns") private var columns = 5
    @AppStorage("rows") private var rows = 3
    @AppStorage("haptics") private var haptics = true
    @AppStorage("awake") private var awake = true
    @State private var settings = false
    @State private var full = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 8) {
            if !full {
                ZStack {
                    VStack(spacing: 3) {
                        (Text("In") + Text(".").foregroundColor(.yellow) + Text("Companion")).font(.system(size: 24, weight: .semibold, design: .rounded))
                        Capsule().fill(LinearGradient(colors: [.yellow,.green], startPoint: .leading, endPoint: .trailing)).frame(width: 74,height: 2)
                    }
                    HStack { Spacer(); Button { satellite.releaseAll(); settings = true } label: { Image(systemName: "gearshape.fill").font(.title2).frame(width:44,height:44) }.accessibilityLabel("Settings") }
                }
                HStack {
                    Circle().fill(satellite.connected ? Color.green : Color.red).frame(width: 7,height: 7)
                    Text(satellite.status)
                    Spacer(); Text(host).monospacedDigit()
                    Button { full = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Full screen")
                }.font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let c = max(1,min(columns, 8)), r = max(1,min(rows, 6))
                let gap: CGFloat = 7
                let side = max(1,min((geo.size.width - CGFloat(c-1)*gap)/CGFloat(c),(geo.size.height-CGFloat(r-1)*gap)/CGFloat(r)))
                VStack(spacing: gap) {
                    ForEach(0..<r,id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<c,id: \.self) { col in
                                let i = row*c+col
                                DeckKey(image: satellite.images[i], enabled: satellite.connected && !settings, haptics: haptics) { down in satellite.press(i,down) }
                                    .frame(width: side,height: side)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            if full { Button { full = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width:44,height:30) }.accessibilityLabel("Exit full screen") }
        }
        .padding(12).background(Color(white: 0.035).ignoresSafeArea())
        .sheet(isPresented: $settings) { configuration }
        .onChange(of: phase) { _, new in
            UIApplication.shared.isIdleTimerDisabled = new == .active && awake
            if new != .active { satellite.releaseAll(); satellite.disconnect() }
            else { connect() }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = awake; connect() }
        .onDisappear { satellite.disconnect(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func connect() { satellite.connect(host: host, port: UInt16(port) ?? 0, columns: max(1,min(columns,8)), rows: max(1,min(rows,6))) }
    private var configuration: some View {
        NavigationStack {
            Form {
                Section("Connection") { TextField("Host or IP address",text:$host).textInputAutocapitalization(.never).autocorrectionDisabled(); TextField("Port",text:$port).keyboardType(.numberPad) }
                Section("Layout") {
                    Button("Mini · 3 × 2") { columns = 3; rows = 2 }
                    Button("Standard · 5 × 3") { columns = 5; rows = 3 }
                    Button("XL · 8 × 4") { columns = 8; rows = 4 }
                    Stepper("Columns: \(columns)",value:$columns,in:1...8); Stepper("Rows: \(rows)",value:$rows,in:1...6)
                }
                Section("Display") { Toggle("Haptic feedback",isOn:$haptics); Toggle("Keep screen awake",isOn:$awake) }
                Section { Text("In.Companion v26.11.26.04").foregroundStyle(.secondary) }
            }.navigationTitle("Settings").toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { settings = false; UIApplication.shared.isIdleTimerDisabled = awake; connect() } } }
        }.interactiveDismissDisabled()
    }
}

struct DeckKey: View {
    let image: UIImage?
    let enabled: Bool
    let haptics: Bool
    let action: (Bool) -> Void
    @State private var down = false
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
            }.shadow(color:.black.opacity(0.9),radius:3,y:3).scaleEffect(down ? 0.94 : 1).opacity(enabled ? 1 : 0.45)
             .overlay { TouchKey(enabled:enabled) { value in down = value; if value && haptics { UIImpactFeedbackGenerator(style:.light).impactOccurred() }; action(value) } }
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
