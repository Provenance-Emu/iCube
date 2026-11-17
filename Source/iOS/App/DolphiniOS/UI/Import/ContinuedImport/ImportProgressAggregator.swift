// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Combines the byte progress of every file in one import into the single figure a system
/// progress UI shows. Pure value type; callers serialize access.
struct ImportProgressAggregator: Equatable {
  struct Item: Equatable {
    var name: String
    var totalBytes: Int64
    var copiedBytes: Int64 = 0
    var isFinished = false
  }

  private(set) var items: [Item]

  /// Files that will not be copied (already imported) are passed with `totalBytes: 0`
  /// and finished by the caller, so they add nothing to either side of the fraction.
  init(items: [(name: String, totalBytes: Int64)]) {
    self.items = items.map { Item(name: $0.name, totalBytes: max(0, $0.totalBytes)) }
  }

  var itemCount: Int { items.count }
  var finishedCount: Int { items.filter(\.isFinished).count }
  var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
  var copiedBytes: Int64 { items.reduce(0) { $0 + $1.copiedBytes } }

  /// 0...1. A batch with no bytes is complete only once every item is finished.
  var fractionCompleted: Double {
    let total = totalBytes
    if total == 0 { return finishedCount == itemCount ? 1 : 0 }
    return min(1, Double(copiedBytes) / Double(total))
  }

  /// Unit counts for `Progress`; never a zero total, which the system reads as "no progress".
  var unitCounts: (total: Int64, completed: Int64) {
    let total = totalBytes
    if total == 0 { return (1, finishedCount == itemCount ? 1 : 0) }
    return (total, min(total, copiedBytes))
  }

  /// Name of the first unfinished item, for the subtitle.
  var currentName: String? { items.first(where: { !$0.isFinished })?.name }

  /// Records bytes copied of one item. Clamped to the item's size and never moves backwards, so a
  /// retried or out-of-order report cannot make the bar jump back.
  mutating func update(item index: Int, copiedBytes: Int64) {
    guard items.indices.contains(index), !items[index].isFinished else { return }
    let clamped = min(max(0, copiedBytes), items[index].totalBytes)
    items[index].copiedBytes = max(items[index].copiedBytes, clamped)
  }

  mutating func finish(item index: Int) {
    guard items.indices.contains(index) else { return }
    items[index].copiedBytes = items[index].totalBytes
    items[index].isFinished = true
  }
}
