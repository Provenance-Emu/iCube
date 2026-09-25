// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PVHelp",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v9),
        .macOS(.v14),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "PVHelp",
            targets: ["PVHelp"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PVHelp",
            dependencies: [],
            // `.copy` (not `.process`) is load-bearing: `.process` flattens nested folders in
            // the produced resource bundle, which would silently drop the `guide/` and `help/`
            // subdirectories these bundled wiki pages live in.
            //
            // The copied directory must NOT be named `Resources` (or `Contents`/`Versions`):
            // `.copy` nests the whole folder verbatim under a top-level entry of that name in
            // the produced `PVHelp_PVHelp.bundle`, and codesign's bundle-format sniffing reads
            // a root-level `Resources/` as a deep/versioned bundle layout. On a shallow iOS
            // bundle that mismatch makes `codesign` fail with "bundle format unrecognized,
            // invalid, or unsuitable" — reproduced directly via
            // `codesign --force --sign - PVHelp_PVHelp.bundle`, and fixed by renaming this
            // folder to `WikiContent`.
            resources: [
                .copy("WikiContent")
            ]
        ),
        .testTarget(
            name: "PVHelpTests",
            dependencies: ["PVHelp"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
