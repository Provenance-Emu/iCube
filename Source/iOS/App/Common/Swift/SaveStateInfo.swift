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
  /// In-game play time at the moment this state was written, when the metadata
  /// sidecar recorded one. Nil for legacy saves with no sidecar, or a sidecar
  /// written before this field existed.
  public let playTimeSeconds: Double?

  public init(gameID: String,
              displayName: String,
              slot: Int?,
              createdAt: Date?,
              modifiedAt: Date?,
              sizeBytes: Int64?,
              versionHash: String?,
              isCompatible: Bool,
              path: URL,
              thumbnailURL: URL?,
              isAuto: Bool,
              playTimeSeconds: Double? = nil) {
    self.gameID = gameID
    self.displayName = displayName
    self.slot = slot
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.sizeBytes = sizeBytes
    self.versionHash = versionHash
    self.isCompatible = isCompatible
    self.path = path
    self.thumbnailURL = thumbnailURL
    self.isAuto = isAuto
    self.playTimeSeconds = playTimeSeconds
  }
}

public struct SaveStateGroup: Identifiable, Hashable {
  public var id: String { gameID }
  public let gameID: String
  public var states: [SaveStateInfo]
}
