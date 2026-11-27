import SwiftUI
import UIKit

struct DeckKey: UIViewRepresentable {
    let image: UIImage?
    let enabled: Bool
    let down: Bool
    let haptics: Bool
    let title: String
    let action: (Bool) -> Bool

    func makeUIView(context: Context) -> DeckKeyControl { DeckKeyControl() }

    func updateUIView(_ view: DeckKeyControl, context: Context) {
        view.update(image: image, enabled: enabled && image != nil, down: down,
                    haptics: haptics, title: title, action: action)
    }
}

final class DeckKeyControl: UIControl {
    private let face = UIView()
    private let shine = CAGradientLayer()
    private let artwork = UIImageView()
    private let bezel = UIView()
    private var pressed = false
    private var haptics = true
    private var action: ((Bool) -> Bool)?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true
        face.isUserInteractionEnabled = false
        face.layer.shadowColor = UIColor.black.cgColor
        face.layer.shadowOffset = CGSize(width: 0, height: 3)
        face.layer.shadowRadius = 3
        face.layer.shadowOpacity = 0.9
        shine.colors = [UIColor(white: 0.27, alpha: 1).cgColor, UIColor.black.cgColor]
        face.layer.addSublayer(shine)
        bezel.backgroundColor = .black
        artwork.contentMode = .scaleAspectFit
        face.addSubview(bezel)
        face.addSubview(artwork)
        addSubview(face)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.bounds = bounds
        face.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = min(bounds.width, bounds.height)
        let radius = side * 0.17
        shine.frame = face.bounds
        shine.cornerRadius = radius
        shine.borderWidth = 1
        shine.borderColor = UIColor(white: 1, alpha: 0.16).cgColor
        bezel.frame = face.bounds.insetBy(dx: side * 0.065, dy: side * 0.065)
        bezel.layer.cornerRadius = radius * 0.8
        artwork.frame = bezel.frame
    }

    func update(image: UIImage?, enabled: Bool, down: Bool, haptics: Bool,
                title: String, action: @escaping (Bool) -> Bool) {
        if !enabled { finishPress() }
        self.action = action
        self.haptics = haptics
        isEnabled = enabled
        accessibilityLabel = title
        accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        artwork.image = image
        face.transform = down ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, !pressed, action?(true) == true else { return false }
        pressed = true
        if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        finishPress()
    }

    override func cancelTracking(with event: UIEvent?) {
        finishPress()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishPress() }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, action?(true) == true else { return false }
        _ = action?(false)
        return true
    }

    private func finishPress() {
        guard pressed else { return }
        pressed = false
        _ = action?(false)
    }
}
