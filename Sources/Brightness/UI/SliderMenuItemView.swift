import AppKit

/// Brightness slider hosted inside the status menu.
final class SliderMenuItemView: NSView {
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "100%")
    private let onChange: (Double) -> Void

    init(title: String, initial: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 54))

        label.stringValue = title
        label.font = .menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = initial
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true

        for view in [label, value, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            value.centerYAnchor.constraint(equalTo: label.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
        ])

        updateValueLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setValue(_ newValue: Double) {
        slider.doubleValue = newValue
        updateValueLabel()
    }

    @objc private func sliderMoved() {
        updateValueLabel()
        onChange(slider.doubleValue)
    }

    private func updateValueLabel() {
        value.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
    }
}
