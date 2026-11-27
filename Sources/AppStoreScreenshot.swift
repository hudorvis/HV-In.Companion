#if DEBUG && APP_STORE_SCREENSHOTS
import UIKit

enum AppStoreScreenshot: String {
    case switching, cues, audio, fullScreen = "full-screen", servers

    static let current = ProcessInfo.processInfo.environment["INCOMPANION_SCREENSHOT_SCENE"]
        .flatMap(AppStoreScreenshot.init(rawValue:))

    var serverName: String {
        switch self {
        case .cues: "Event Control"
        case .audio: "Audio Control"
        default: "Studio A"
        }
    }

    var keys: [String] {
        switch self {
        case .switching, .fullScreen, .servers:
            ["CAM 1", "CAM 2", "CAM 3", "MEDIA", "BLACK",
             "PREVIEW", "PROGRAM", "CUT", "AUTO", "FADE",
             "AUDIO", "GRAPHICS", "RECORD", "STREAM", "CUES"]
        case .cues:
            ["STANDBY", "INTRO", "WALK IN", "GO LIVE", "HOLD",
             "PREVIOUS", "NEXT", "TAKE", "REPLAY", "OUTRO",
             "SLIDES", "PLAYBACK", "LOWER 3RD", "HOUSE", "HOME"]
        case .audio:
            ["HOST", "GUEST 1", "GUEST 2", "PLAYBACK", "MUSIC",
             "MUTE 1", "MUTE 2", "MUTE 3", "DIM", "MONITOR",
             "TALKBACK", "AUX 1", "AUX 2", "MASTER", "HOME"]
        }
    }

    var symbols: [String] {
        switch self {
        case .switching, .fullScreen, .servers:
            ["video.fill", "video.fill", "video.fill", "play.rectangle", "circle.lefthalf.filled",
             "eye", "dot.radiowaves.left.and.right", "scissors", "arrow.left.arrow.right", "circle.dotted",
             "waveform", "rectangle.on.rectangle", "record.circle", "antenna.radiowaves.left.and.right", "list.bullet"]
        case .cues:
            ["clock", "play.circle", "figure.walk", "antenna.radiowaves.left.and.right", "pause.fill",
             "backward.end.fill", "forward.end.fill", "play.fill", "arrow.counterclockwise", "stop.fill",
             "rectangle.stack", "play.rectangle", "rectangle.bottomthird.inset.filled", "lightbulb", "house"]
        case .audio:
            ["mic.fill", "mic.fill", "mic.fill", "play.rectangle", "music.note",
             "mic.slash", "mic.slash", "mic.slash", "speaker.wave.1", "headphones",
             "waveform", "slider.vertical.3", "slider.vertical.3", "speaker.wave.3", "house"]
        }
    }

    func makeArtwork() -> [Int: UIImage] {
        let palette: [UIColor] = [
            UIColor(red: 0.07, green: 0.20, blue: 0.31, alpha: 1),
            UIColor(red: 0.15, green: 0.10, blue: 0.27, alpha: 1),
            UIColor(red: 0.10, green: 0.24, blue: 0.22, alpha: 1)
        ]
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        let labels = keys
        let icons = symbols
        return Dictionary(uniqueKeysWithValues: labels.indices.map { index in
            let image = renderer.image { context in
                let background: UIColor
                if index == 6 && self != .cues && self != .audio {
                    background = UIColor(red: 0.70, green: 0.10, blue: 0.17, alpha: 1)
                } else if index == 7 {
                    background = UIColor(red: 0.10, green: 0.43, blue: 0.29, alpha: 1)
                } else {
                    background = palette[index / 5]
                }
                background.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
                let configuration = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
                if let symbol = UIImage(systemName: icons[index], withConfiguration: configuration) {
                    let scale = min(34 / symbol.size.width, 34 / symbol.size.height)
                    let width = symbol.size.width * scale
                    let height = symbol.size.height * scale
                    symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: (96 - width) / 2, y: 36 - height / 2, width: width, height: height))
                }
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                (labels[index] as NSString).draw(in: CGRect(x: 1, y: 67, width: 94, height: 24), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: style
                ])
            }
            return (index, image)
        })
    }
}
#endif
