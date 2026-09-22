// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Identifiers for iCube's CloudKit sync, in one place.
///
/// - Important: **The container below is NOT PROVISIONED YET.** It does not exist
///   in the Apple Developer account, and none of the four `.entitlements` files
///   request it. Everything in this module is written to degrade cleanly in that
///   state — see `CloudKitAvailability.containerIsProvisioned`, which is the
///   single switch that turns CloudKit on once the account work is done.
///   The entitlements changes are staged, un-applied, in
///   `docs/cloudkit-entitlements.patch`; applying them before the container
///   exists breaks code signing for everyone building the app.
public enum CloudSyncConstants {

    /// iCube's CloudKit container. Analogue of iFly's `iCloud.com.joemattiello.iFly`.
    ///
    /// Not yet provisioned — see the type doc.
    public static let containerIdentifier = "iCloud.com.joemattiello.iCube"

    /// Custom record zone in the **private** database. A custom zone (rather
    /// than the default zone) is what makes `CKFetchRecordZoneChangesOperation`
    /// usable, which in turn is what lets the provider enumerate every record
    /// without needing `recordName` marked Queryable in the CloudKit schema.
    public static let zoneName = "iCubeUserData"

    /// The one and only record type. iFly proved a single type is enough: the
    /// category lives in a field, not in the schema, so adding a
    /// `SyncableFileType` case never requires a CloudKit schema migration.
    public static let recordType = "iCubeUserFile"

    /// Field names on `recordType`. Centralised because a typo in one of these
    /// is a silent "record never round-trips" bug, not a compile error.
    public enum Field {
        public static let fileName = "fileName"
        public static let fileData = "fileData"
        public static let lastModified = "lastModified"
        public static let checksum = "checksum"
        public static let fileType = "fileType"
        public static let fileSize = "fileSize"
        public static let deviceIdentifier = "deviceIdentifier"
        public static let appVersion = "appVersion"
    }

    /// How often the background timer fires a sync (30 minutes, matching iFly).
    public static let backgroundSyncInterval: TimeInterval = 30 * 60

    /// Filesystem-watcher debounce.
    public static let watcherDebounceInterval: TimeInterval = 0.5

    /// Two modification times within this many seconds are treated as "the same
    /// version" and skipped, so a round-tripped file does not churn.
    public static let modificationTimeTolerance: TimeInterval = 2.0
}
