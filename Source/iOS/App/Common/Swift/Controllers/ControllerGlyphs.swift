import Foundation
import GameController

enum ControllerGlyphSet: String {
  case playstation
  case xbox
  case nintendo
  case generic
}

struct ControllerGlyphs {
  static func detectGlyphSet() -> ControllerGlyphSet {
    guard let c = GCController.controllers().first else { return .generic }
    let vendor = (c.vendorName ?? "").lowercased()
    let product = c.productCategory.lowercased()
    if product.contains("dualshock") || product.contains("dualsense") || vendor.contains("sony") || vendor.contains("playstation") {
      return .playstation
    }
    if product.contains("xbox") || vendor.contains("microsoft") {
      return .xbox
    }
    if product.contains("nintendo") || vendor.contains("nintendo") || product.contains("switch") {
      return .nintendo
    }
    return .generic
  }

  static func glyphName(for action: String, set: ControllerGlyphSet) -> String {
    switch set {
    case .playstation:
      switch action {
      case "confirm": return "square.and.arrow.down" // placeholder
      case "cancel": return "xmark.circle"
      case "start": return "rectangle.portrait.and.arrow.right"
      default: return "circle"
      }
    case .xbox:
      switch action {
      case "confirm": return "a.circle"
      case "cancel": return "b.circle"
      case "start": return "rectangle.portrait.and.arrow.right"
      default: return "circle"
      }
    case .nintendo:
      switch action {
      case "confirm": return "a.circle"
      case "cancel": return "b.circle"
      case "start": return "rectangle.portrait.and.arrow.right"
      default: return "circle"
      }
    case .generic:
      switch action {
      case "confirm": return "checkmark.circle"
      case "cancel": return "xmark.circle"
      case "start": return "play.circle"
      default: return "circle"
      }
    }
  }
}
