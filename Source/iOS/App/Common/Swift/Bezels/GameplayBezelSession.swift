// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import SkinKitBezelsUI

/// The TV in effect for the game on screen, and what the pause menu's switcher needs from it.
///
/// `EmulationScreen` owns one. It keeps the resolved TV (the switcher's preview first, then the game's own TV,
/// then the saved choice) so the screen's body reads a stored value instead of running the rules on every pass,
/// and resolves again when the game, the preview or a stored choice changes.
@MainActor
final class GameplayBezelSession: ObservableObject, BezelSwitcherSession {
  /// The TV to draw, when the screen's state also allows one (`ICubeBezels.showsTV`). `nil` is the picture alone.
  @Published private(set) var bezel: TVBezel?
  /// `Resolution.isAutomatic` of `bezel`: nobody chose this TV, so it shows in landscape only.
  @Published private(set) var choiceIsAutomatic = true
  /// The TV on screen has not drawn its artwork yet.
  @Published private(set) var isBezelLoading = false
  /// The choice the switcher is trying. Read ahead of the stored choices and stored nowhere.
  @Published var bezelPreview: BezelPreview? {
    didSet { if bezelPreview != oldValue { resolve() } }
  }

  let renderer = GameplayBezelRenderer()
  @Published private(set) var droppedForSession = false
  /// TVs whose Metal scene could not be loaded or drawn this session. The screen shows them the plain way, as an
  /// image, where they have one; a shader-only TV shows the picture alone.
  @Published private(set) var sceneUnavailable: Set<String> = []

  var supportsRoomLight: Bool {
    GameplayBezelRenderer.supportsRoomLight && screenState.canvas.width > screenState.canvas.height
      && !droppedForSession && bezel?.image == nil && bezel?.lightsRoom == true
  }

  @Published private(set) var wantsRoomLight = false

  var lightsRoom: Bool { supportsRoomLight && wantsRoomLight }

  func showScene(_ request: GameplayBezelRenderer.Request?) {
    renderer.didDrop = { [weak self] in
      self?.droppedForSession = true
      self?.isBezelLoading = false
    }
    renderer.didFail = { [weak self] id in
      self?.sceneUnavailable.insert(id)
      self?.isBezelLoading = false
    }
    if request != nil { DOLShaderPostProcessor.shared.useBezelRenderer(renderer) }
    if renderer.update(request, didLoad: { [weak self] in self?.isBezelLoading = false }), request != nil {
      isBezelLoading = true
    }
  }

  /// What the screen last reported, for `canShowBezel`.
  @Published var screenState = ICubeBezels.ScreenState()

  private var gameKey: String?
  private var isWii = false
  /// TVs whose artwork could not be read this session; the picture is shown alone instead of in an empty frame.
  private var unreadable: Set<String> = []
  private var subscriptions: Set<AnyCancellable> = []

  init() {
    ICubeBezels.configure()
    NotificationCenter.default.publisher(for: .bezelSettingsDidChange)
      .merge(with: NotificationCenter.default.publisher(for: TVBezelLibrary.didChangeNotification))
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.resolve() }
      .store(in: &subscriptions)
    resolve()
  }

  /// The game on screen. Call it when the screen appears, when the core starts and when the system is re-inferred.
  func setGame(key: String?, isWii: Bool) {
    guard key != gameKey || isWii != self.isWii else { return }
    gameKey = key
    self.isWii = isWii
    resolve()
  }

  /// `TVBezelArtworkView`'s report for the TV with `id`: on screen, or unreadable.
  func artworkLoaded(_ loaded: Bool, id: String) {
    guard id == bezel?.id else { return }
    isBezelLoading = false
    guard !loaded, unreadable.insert(id).inserted else { return }
    resolve()
  }

  private func resolve() {
    wantsRoomLight = BezelChoice.lightsRoom(preview: bezelPreview)
    let resolved = BezelChoice.resolve(gameID: gameKey, systemID: bezelSystemID, systemSuitsTV: bezelSystemSuitsTV,
                                       preview: bezelPreview)
    let next = resolved.bezel.flatMap { unreadable.contains($0.id) ? nil : $0 }
    if choiceIsAutomatic != resolved.resolution.isAutomatic { choiceIsAutomatic = resolved.resolution.isAutomatic }
    guard next != bezel else { return }
    isBezelLoading = next != nil
    bezel = next
  }

  // MARK: - BezelSwitcherSession

  var bezelGameID: String? { gameKey }
  var bezelSystemID: String? { ICubeBezels.systemID(isWii: isWii) }
  /// GameCube and Wii were both played on a TV.
  var bezelSystemSuitsTV: Bool { true }
  var canShowBezel: Bool { ICubeBezels.offersSwitcher(screenState) }

  /// The running game, for the picker's "Choose from The Bezel Project…".
  func gameContext(filePath: String, title: String) -> ExternalDisplayGameContext? {
    guard let gameKey else { return nil }
    let romName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
    return ExternalDisplayGameContext(gameID: gameKey, systemID: ICubeBezels.systemID(isWii: isWii), romName: romName, title: title)
  }
}
