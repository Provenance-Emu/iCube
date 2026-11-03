import Foundation
import XCTest
@testable import iCube

final class LibraryGridSizingTests: XCTestCase {
  func test_moreImmediatelyReversesFewerAtPhoneMinimum() {
    let fewer = LibraryLayout.adjustedColumnOffset(autoFit: 2, offset: 0, delta: -1)
    let more = LibraryLayout.adjustedColumnOffset(autoFit: 2, offset: fewer, delta: 1)
    XCTAssertEqual(more, 1, "A clamped Fewer action must not swallow the next More action")
  }

  func test_fewerImmediatelyReversesMoreAtTabletMaximum() {
    let more = LibraryLayout.adjustedColumnOffset(autoFit: 6, offset: 2, delta: 1)
    let fewer = LibraryLayout.adjustedColumnOffset(autoFit: 6, offset: more, delta: -1)
    XCTAssertEqual(fewer, 1)
  }

  func test_morePerRowShrinksArtworkAndFewerEnlargesIt() {
    let fewer = LibraryLayout.cardSize(availableWidth: 358, columns: 2, spacing: 16)
    let more = LibraryLayout.cardSize(availableWidth: 358, columns: 3, spacing: 16)
    XCTAssertGreaterThan(fewer.width, more.width)
    XCTAssertGreaterThan(fewer.height, more.height)
    XCTAssertEqual(fewer.width * 2 + 16, 358, accuracy: 0.001)
    XCTAssertEqual(more.width * 3 + 32, 358, accuracy: 0.001)
  }

  func test_coverAspectRatioSurvivesPhoneAndTabletColumnCounts() {
    for available: CGFloat in [358, 736, 992] {
      for columns in 2 ... 8 {
        let size = LibraryLayout.cardSize(availableWidth: available, columns: columns, spacing: 16)
        XCTAssertEqual(size.height / size.width, 1.5, accuracy: 0.001)
        XCTAssertEqual(size.width * CGFloat(columns) + CGFloat(columns - 1) * 16, available, accuracy: 0.001)
      }
    }
  }

  func test_transientZeroWidthNeverProducesNegativeFrames() {
    let size = LibraryLayout.cardSize(availableWidth: 0, columns: 8, spacing: 16)
    XCTAssertEqual(size, .zero)
  }
}

#if os(iOS)
import SwiftUI

@MainActor
final class LibraryGridCardRenderTests: XCTestCase {
  func test_realCardArtworkFollowsGridSlotWidth() throws {
    let item = TVGameItem(demoTitle: "Grid Size", gameID: "GTEST1", platform: 0,
                          maker: "Test", countryName: "USA", fileSize: 1, accentHue: 0.3)
    var widths: [Int] = []
    for columns in [2, 3] {
      let size = LibraryLayout.cardSize(availableWidth: 358, columns: columns, spacing: 16)
      let card = GameGridItem(
        item: item, select: { _ in }, focusedFilePath: .constant(nil),
        showProperties: { _ in }, showCheatList: { _ in }, downloadGeckoAction: { _ in },
        presentCheatGecko: { _ in }, presentCheatAR: { _ in }, requestDelete: { _ in },
        showFavoriteToggle: { _ in }, showStorageAlert: { _ in }, setDefaultISO: { _ in },
        showCacheInfo: { _ in }, showSaveStates: { _ in }, showMods: { _ in },
        showModManager: { _ in }, moddedVariants: [], moddedInfo: nil,
        autoPreCacheProgress: 0, isAutoPreCaching: false, showSubtitles: false, cardSize: size)
      let renderer = ImageRenderer(content: card)
      renderer.scale = 1
      let image = try XCTUnwrap(renderer.cgImage)
      XCTAssertEqual(CGFloat(image.width), size.width, accuracy: 1)
      widths.append(image.width)
    }
    XCTAssertGreaterThan(widths[0], widths[1])
  }
}
#endif
