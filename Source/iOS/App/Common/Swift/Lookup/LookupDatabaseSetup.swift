// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVLookup
import PVSQLiteDatabase

/// Points PVLookup at the databases this app ships.
///
/// PVLookup (github.com/Provenance-Emu/PVLookup) carries no database bytes. The "Fetch Lookup
/// Databases" build phase downloads the ones pinned in `databases.lock.json` into
/// `Common/Resources/LookupDatabases/`, which is copied into the app as a folder. iCube ships
/// libretrodb only; OpenVGDB, TheGamesDB, ShiraGame and the cheat database are not shipped, so
/// PVLookup reports them unavailable.
///
/// Must run before anything touches `PVLookup.shared`: `AppDelegate` calls it at launch.
enum LookupDatabaseSetup {
  static let folderName = "LookupDatabases"

  static func configure(in bundle: Bundle = .main) {
    // No folder in the bundle means the fetch phase did not run; lookups then find nothing.
    guard let folder = bundle.url(forResource: folderName, withExtension: nil),
          let databases = Bundle(url: folder) else { return }
    LookupDatabases.configure(Dictionary(uniqueKeysWithValues: LookupDatabase.allCases.map {
      ($0, LookupDatabaseSource.bundled(databases, resource: $0.defaultResourceName))
    }))
  }
}
