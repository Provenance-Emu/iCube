// swift-tools-version:5.9
import PackageDescription

// RAR and RAR5 extraction for iCube. The decoder is the RAR-reading subset of libarchive 3.8.11
// (BSD 2-clause, see Sources/CLibArchiveRAR/LICENSE.libarchive), compiled from source so the app
// does not rely on the system's header-less libarchive. unrar is not used: its licence is not
// compatible with the GPL the app is under.
let package = Package(
    name: "RarArchive",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RarArchive", targets: ["RarArchive"])
    ],
    targets: [
        .target(
            name: "CLibArchiveRAR",
            exclude: ["LICENSE.libarchive"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The libarchive notice ships in the app bundle (RarArchive_RarArchive.bundle): its licence
        // asks binary redistributions to reproduce it, and the app has no licences screen to list it on.
        .target(
            name: "RarArchive",
            dependencies: ["CLibArchiveRAR"],
            resources: [.copy("Resources/libarchive-LICENSE.txt")]
        ),
        .testTarget(
            name: "RarArchiveTests",
            dependencies: ["RarArchive"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
