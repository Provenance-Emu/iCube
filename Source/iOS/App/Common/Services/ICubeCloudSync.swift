import PVCloudSync

/// Persistent identity of the existing iCube private CloudKit database.
enum ICubeCloudSync {
    static let configuration = CloudSyncConfiguration(
        containerIdentifier: "iCloud.com.joemattiello.iCube",
        zoneName: "iCubeUserData",
        recordType: "iCubeUserFile",
        containerIsProvisioned: true
    )
}
