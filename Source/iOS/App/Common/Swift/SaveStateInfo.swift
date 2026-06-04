import Foundation

public struct SaveStateInfo: Identifiable, Hashable {
  public let id: UUID = UUID()
  public let gameID: String
  public let displayName: String
  public let slot: Int?
  public let createdAt: Date?
  public let modifiedAt: Date?
  public let sizeBytes: Int64?
  public let versionHash: String?
  public let isCompatible: Bool
  public let path: URL
  public let thumbnailURL: URL?
  /// True for the dedicated "resume where I left off" auto-state ({GameID}.auto),
  /// surfaced as a "Continue" entry rather than a numbered slot.
  public let isAuto: Bool
}

public struct SaveStateGroup: Identifiable, Hashable {
  public var id: String { gameID }
  public let gameID: String
  public var states: [SaveStateInfo]
}
