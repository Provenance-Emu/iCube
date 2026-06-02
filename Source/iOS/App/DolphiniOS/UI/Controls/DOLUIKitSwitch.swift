import UIKit

#if os(tvOS)
@objc(DOLTVSwitch)
class DOLTVSwitch: UIControl {
  @objc dynamic var on: Bool = false {
    didSet { updateAppearance() }
  }

  private let backgroundView = UIView()
  private let knobView = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    commonInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    isUserInteractionEnabled = true
    clipsToBounds = false

    backgroundView.isUserInteractionEnabled = false
    backgroundView.layer.cornerRadius = 14
    addSubview(backgroundView)

    knobView.isUserInteractionEnabled = false
    knobView.layer.cornerRadius = 12
    knobView.layer.shadowColor = UIColor.black.cgColor
    knobView.layer.shadowOpacity = 0.2
    knobView.layer.shadowRadius = 2
    addSubview(knobView)

    updateAppearance()
  }

  override var canBecomeFocused: Bool { true }

  override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
    super.didUpdateFocus(in: context, with: coordinator)
    coordinator.addCoordinatedAnimations({
      self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
    }, completion: nil)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let h: CGFloat = 28
    let w: CGFloat = 52
    let x: CGFloat = (bounds.width - w) / 2
    let y: CGFloat = (bounds.height - h) / 2
    backgroundView.frame = CGRect(x: x, y: y, width: w, height: h)
    let knobSize: CGFloat = 24
    let knobY = y + (h - knobSize) / 2
    let knobX = on ? (x + w - knobSize - 2) : (x + 2)
    knobView.frame = CGRect(x: knobX, y: knobY, width: knobSize, height: knobSize)
  }

  private func updateAppearance() {
    backgroundView.backgroundColor = on ? UIColor.systemGreen : UIColor.systemGray
    knobView.backgroundColor = UIColor.white
    setNeedsLayout()
  }

  @objc func addValueChangedTarget(_ target: Any?, action: Selector) {
    addTarget(target, action: action, for: .valueChanged)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if presses.contains(where: { $0.type == .select }) {
      on.toggle()
      sendActions(for: .valueChanged)
      return
    }
    super.pressesEnded(presses, with: event)
  }
}
#endif
