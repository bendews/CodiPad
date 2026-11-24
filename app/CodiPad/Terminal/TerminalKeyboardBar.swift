import UIKit

/// Terminal keys stay outside WebKit without taking its text input focus.
private final class AccessibleTerminalKey: UIButton {
    var onActivate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

final class TerminalKeyboardBar: UIStackView {
    var send: ((String) -> Void)?
    private var repeatTimer: Timer?
    private var held: UIButton?
    private var modifiers: [String: UIButton] = [:]

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        distribution = .fillEqually
        spacing = 4
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        backgroundColor = .secondarySystemBackground
        for (title, key, label) in [("esc", "Escape", "Escape"), ("tab", "Tab", "Tab"),
                                  ("ctrl", "Control", "Control"), ("alt", "Alt", "Alt"),
                                  ("←", "ArrowLeft", "Left arrow"), ("↑", "ArrowUp", "Up arrow"),
                                  ("↓", "ArrowDown", "Down arrow"), ("→", "ArrowRight", "Right arrow")] {
            let button = AccessibleTerminalKey(type: .system)
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = "codipad.terminal.key.\(key)"
            button.accessibilityLabel = label
            button.accessibilityHint = key == "Control" || key == "Alt" ? "Applies to the next terminal key" : "Hold to repeat"
            button.restorationIdentifier = key
            if key == "Control" || key == "Alt" {
                modifiers[key] = button
                button.onActivate = { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.toggle(button)
                }
                button.addTarget(self, action: #selector(toggle(_:)), for: .touchUpInside)
            } else {
                button.onActivate = { [weak self, weak button] in
                    guard let self, let key = button?.restorationIdentifier else { return }
                    self.send?(key + ":down"); self.send?(key + ":up")
                }
                button.addTarget(self, action: #selector(begin(_:)), for: .touchDown)
                button.addTarget(self, action: #selector(end(_:)), for: .touchUpInside)
                button.addTarget(self, action: #selector(cancelTouch), for: [.touchCancel, .touchUpOutside, .touchDragExit])
            }
            addArrangedSubview(button)
        }
    }

    required init(coder: NSCoder) { fatalError("Use init()") }
    deinit { repeatTimer?.invalidate() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        for button in modifiers.values where button.isSelected {
            button.backgroundColor = tintColor.withAlphaComponent(0.18)
        }
    }

    func update(ctrl: Bool, alt: Bool) {
        for (key, active) in [("Control", ctrl), ("Alt", alt)] {
            modifiers[key]?.isSelected = active
            modifiers[key]?.backgroundColor = active ? tintColor.withAlphaComponent(0.18) : .clear
            modifiers[key]?.accessibilityValue = active ? "On" : "Off"
        }
    }

    func cancel() {
        cancelTouch()
        update(ctrl: false, alt: false)
    }

    @objc private func toggle(_ button: UIButton) {
        if let key = button.restorationIdentifier { send?(key) }
    }

    @objc private func begin(_ button: UIButton) {
        cancel()
        held = button
        if let key = button.restorationIdentifier { send?(key + ":down") }
        repeatTimer = Timer(timeInterval: 0.45, repeats: false) { [weak self, weak button] _ in
            guard let self, let button, self.held === button else { return }
            self.repeatTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self, weak button] _ in
                guard let self, let button, self.held === button else { return }
                if let key = button.restorationIdentifier { self.send?(key + ":repeat") }
            }
            if let timer = self.repeatTimer { RunLoop.main.add(timer, forMode: .common) }
        }
        if let timer = repeatTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    @objc private func end(_ button: UIButton) {
        cancelTouch()
    }

    @objc private func cancelTouch() {
        repeatTimer?.invalidate(); repeatTimer = nil
        if let key = held?.restorationIdentifier { send?(key + ":up") }
        held = nil
    }
}
