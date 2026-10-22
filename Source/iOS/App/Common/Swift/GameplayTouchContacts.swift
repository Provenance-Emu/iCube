// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Real contact ownership, separate from emulated axis/button writes (including continuous motion).
/// Every contact blocks neutral; only a new contact on a gameplay control may activate resume.
@MainActor
final class GameplayTouchContacts {
  private static var scopes: [UUID: (all: Int, gameplay: Int)] = [:]
  static var hasAnyContacts: Bool { scopes.values.contains { $0.all > 0 } }
  static var hasNonGameplayContacts: Bool { scopes.values.contains { $0.all > $0.gameplay } }
  static var hasAnyGameplayContacts: Bool { scopes.values.contains { $0.gameplay > 0 } }
  private let id = UUID()
  private var live: Set<ObjectIdentifier> = []
  private var gameplay: Set<ObjectIdentifier> = []
  var onGameplayBegan: () -> Void = {
    NotificationCenter.default.post(name: .DOLGameplayInputBegan, object: nil)
  }
  var hasGameplayContacts: Bool { !gameplay.isEmpty }

  func began(_ contacts: Set<ObjectIdentifier>, gameplay eligible: Set<ObjectIdentifier>) {
    let fresh = contacts.subtracting(live)
    live.formUnion(contacts)
    gameplay.formUnion(eligible.intersection(contacts))
    Self.scopes[id] = (live.count, gameplay.count)
    if !fresh.intersection(eligible).isEmpty { onGameplayBegan() }
  }

  func ended(_ contacts: Set<ObjectIdentifier>) {
    live.subtract(contacts)
    gameplay.subtract(contacts)
    if live.isEmpty { Self.scopes.removeValue(forKey: id) }
    else { Self.scopes[id] = (live.count, gameplay.count) }
  }

  func cancelAll() {
    live.removeAll()
    gameplay.removeAll()
    Self.scopes.removeValue(forKey: id)
  }

  deinit {
    let scopeID = id
    MainActor.assumeIsolated { _ = Self.scopes.removeValue(forKey: scopeID) }
  }
}

// MARK: - UIKit contact delivery
#if os(iOS)
import UIKit

/// Installed on the common touch-pad ancestor, covering legacy XIBs and hosted/skinned surfaces.
/// It observes contacts without recognizing a gesture, preventing another recognizer, or cancelling controls.
@MainActor
final class GameplayTouchContactObserver: UIGestureRecognizer {
  let contacts = GameplayTouchContacts()
  private final class Target {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
  }
  private var targets: [ObjectIdentifier: Target] = [:]

  struct BeganContact {
    let id: ObjectIdentifier
    let target: UIView
    let gameplay: Bool
  }

  /// Register every target and classification before the single possible activation callback.
  func recordContactsBegan(_ batch: [BeganContact]) {
    for contact in batch { targets[contact.id] = Target(contact.target) }
    let all = Set(batch.map(\.id))
    let gameplay = Set(batch.filter(\.gameplay).map(\.id))
    contacts.began(all, gameplay: gameplay)
  }

  func recordContactsBegan(_ ids: Set<ObjectIdentifier>, target: UIView, gameplay: Set<ObjectIdentifier>) {
    recordContactsBegan(ids.map { BeganContact(id: $0, target: target, gameplay: gameplay.contains($0)) })
  }
  func cancelAllContacts() { targets.removeAll(); contacts.cancelAll() }

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }
  // This observer is installed programmatically and is never decoded from an archive.
  required init?(coder: NSCoder) { return nil }

  static func isGameplayControl(_ touched: UIView, in root: UIView, at point: CGPoint) -> Bool {
    var node: UIView? = touched
    while let candidate = node, candidate !== root {
      if let surface = candidate as? TouchOverlaySurface.SurfaceView {
        return surface.gameplayHitTest(candidate.convert(point, from: touched))
      }
      if let ir = candidate as? TouchOverlayIRPadView.IRSurfaceView { return ir.mode != .gyro }
      if candidate is TCButton || candidate is TCJoystick || candidate is TCDirectionalPad { return true }
      if let wiiPad = candidate as? TCWiiPad, wiiPad.mode != .gyro { return true }
      node = candidate.superview
    }
    return false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let root = view else { return }
    let batch = touches.compactMap { touch -> BeganContact? in
      guard let target = touch.view else { return nil }
      return BeganContact(id: ObjectIdentifier(touch), target: target,
        gameplay: Self.isGameplayControl(target, in: root, at: touch.location(in: target)))
    }
    recordContactsBegan(batch)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    let ended = Set(touches.map(ObjectIdentifier.init))
    for id in ended { targets.removeValue(forKey: id) }
    contacts.ended(ended)
    if !GameplayTouchContacts.hasAnyContacts { state = .failed }
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    touchesEnded(touches, with: event)
  }
  static func cancelContacts(in subtree: UIView) {
    var node: UIView? = subtree
    while let candidate = node {
      for case let observer as GameplayTouchContactObserver in candidate.gestureRecognizers ?? [] {
        let removed = Set(observer.targets.compactMap { id, target -> ObjectIdentifier? in
          guard let view = target.view else { return id }
          return view === subtree || view.isDescendant(of: subtree) ? id : nil
        })
        for id in removed { observer.targets.removeValue(forKey: id) }
        observer.contacts.ended(removed)
      }
      node = candidate.superview
    }
  }
  deinit {
    let owned = contacts
    MainActor.assumeIsolated { owned.cancelAll() }
  }
  override func reset() { cancelAllContacts(); super.reset() }
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
