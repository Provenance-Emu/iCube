import Foundation
import PVLibrarySnapshot

/// Storage and URL identity shared by iCube and every extension. Keep the App
/// Group equal to DOLAppGroupIdentifier in Common/SharedDefaults.m.
enum ICubeSnapshot {
    static let configuration = LibrarySnapshotConfiguration(
        appGroupIdentifier: "group.com.joemattiello.icube",
        launchURLScheme: "dolphinios",
        telemetrySubsystem: "com.joemattiello.iCube"
    )
    static let appGroup = LibrarySnapshotAppGroup(configuration: configuration)
}

extension LibrarySnapshotStore {
    public init() { self.init(appGroup: ICubeSnapshot.appGroup) }
}

extension ExtensionTelemetry {
    init(_ surface: Surface) {
        self.init(surface, subsystem: ICubeSnapshot.configuration.telemetrySubsystem)
    }
}

extension LibrarySnapshotGame {
    var icubePlatform: LibraryPlatform { LibraryPlatform(rawValue: platform) ?? .unknown }
    var launchURL: URL? { launchURL(using: ICubeSnapshot.configuration) }
    var coverURL: URL? { coverURL(in: ICubeSnapshot.appGroup) }

    init(id: String, title: String, filePath: String, platform: LibraryPlatform,
         gametdbID: String?, region: String?, lastPlayed: Date?, isFavorite: Bool,
         dateAdded: Date? = nil, coverFilename: String?) {
        self.init(id: id, title: title, filePath: filePath, platform: platform.rawValue,
                  gametdbID: gametdbID, region: region, lastPlayed: lastPlayed,
                  isFavorite: isFavorite, dateAdded: dateAdded, coverFilename: coverFilename)
    }
}
