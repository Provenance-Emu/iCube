import Foundation
import XCTest
@testable import iCube

final class LibraryGridSizeTests: XCTestCase {
  /// The tvOS library column at 1920 points: the screen less the rail lane and the insets either side.
  private let tvColumn: CGFloat = 1684
  /// The same column with the fast-scroll index beside it.
  private let tvColumnWithIndex: CGFloat = 1580
  private let minSpacing: CGFloat = 52
  private let floorSpacing: CGFloat = 24

  private func metrics(_ size: LibraryGridSize, width: CGFloat) -> LibraryGridSize.Metrics {
    size.tvMetrics(availableWidth: width, minSpacing: minSpacing, floorSpacing: floorSpacing)
  }

  func test_everySizeGivesADifferentColumnCountOnATV() {
    for width in [tvColumn, tvColumnWithIndex] {
      let counts = LibraryGridSize.allCases.map { metrics($0, width: width).count }
      XCTAssertEqual(counts, counts.sorted(by: >), "Compact shows the most per row, Large the fewest")
      XCTAssertEqual(Set(counts).count, counts.count, "Each size must change the layout at width \(width)")
    }
  }

  func test_comfortableKeepsTheLayoutTheLibraryHad() {
    let comfortable = metrics(.comfortable, width: tvColumn)
    XCTAssertEqual(comfortable.count, 5)
    XCTAssertEqual(comfortable.cardSize, CGSize(width: 260, height: 390))
  }

  func test_coversKeepTheCaseShapeAtEverySize() {
    for size in LibraryGridSize.allCases {
      XCTAssertEqual(size.tvCardSize.height / size.tvCardSize.width, 1.5, accuracy: 0.001)
    }
  }

  func test_rowFillsTheColumnExactlyAndNeverOverflows() {
    for size in LibraryGridSize.allCases {
      for width in [tvColumn, tvColumnWithIndex, 1200, 2400] as [CGFloat] {
        let result = metrics(size, width: width)
        let row = CGFloat(result.count) * result.cardSize.width + CGFloat(result.count - 1) * result.spacing
        XCTAssertEqual(row, width, accuracy: 0.001, "\(size) at \(width)")
        XCTAssertGreaterThanOrEqual(result.spacing, minSpacing)
      }
    }
  }

  func test_aColumnNarrowerThanOneCoverStillShowsOne() {
    let result = metrics(.large, width: 100)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.spacing, minSpacing)
    XCTAssertEqual(metrics(.large, width: 0).count, 1)
  }

  func test_storedValueRoundTripsAndUnknownFallsBack() {
    for size in LibraryGridSize.allCases {
      XCTAssertEqual(LibraryGridSize(rawValue: size.rawValue), size)
    }
    XCTAssertNil(LibraryGridSize(rawValue: "huge"))
  }
}

final class LibrarySelectionBarStateTests: XCTestCase {
  func test_emptySelectionOffersOnlySelectAll() {
    let state = LibrarySelectionBarState(selectedCount: 0, visibleCount: 12)
    XCTAssertFalse(state.canActOnSelection)
    XCTAssertFalse(state.canShowProperties)
    XCTAssertFalse(state.canDeselectAll)
    XCTAssertTrue(state.canSelectAll)
  }

  func test_oneGameOffersProperties() {
    let state = LibrarySelectionBarState(selectedCount: 1, visibleCount: 12)
    XCTAssertTrue(state.canActOnSelection)
    XCTAssertTrue(state.canShowProperties)
    XCTAssertTrue(state.canDeselectAll)
  }

  func test_severalGamesHideProperties() {
    XCTAssertFalse(LibrarySelectionBarState(selectedCount: 2, visibleCount: 12).canShowProperties)
  }

  func test_everythingSelectedCannotSelectMore() {
    XCTAssertFalse(LibrarySelectionBarState(selectedCount: 12, visibleCount: 12).canSelectAll)
    XCTAssertFalse(LibrarySelectionBarState(selectedCount: 0, visibleCount: 0).canSelectAll)
  }
}
