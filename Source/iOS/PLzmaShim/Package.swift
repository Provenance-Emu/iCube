// swift-tools-version:5.9
import PackageDescription

// The app reaches PLzmaSDK through this local package instead of depending on it directly.
// PLzmaSDK sets -fPIC/-fno-rtti through unsafeFlags, and Xcode 27.0 refuses a project target
// that depends on such a remote package, even one pinned by revision ("cannot be used as a
// dependency of this target because it uses unsafe build flags"). A local package may depend
// on a revision-pinned package that uses them, as Provenance's PVArchiving does.
let package = Package(
    name: "PLzmaShim",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PLzmaShim", targets: ["PLzmaShim"])
    ],
    dependencies: [
        // Provenance-Emu fork, tag 1.6.2-provenance.1: upstream 1.6.2 plus the arm64 assembly LZMA decoder
        // switched on (about 25 % faster extraction), hardware CRC32 on Apple arm64, and no linker
        // "debug note" warnings from that decoder. Revision-pinned because a version requirement would
        // reject the unsafe flags.
        .package(url: "https://github.com/Provenance-Emu/PLzmaSDK.git", revision: "eea50ce18a00beb85b645f5b305cded3384de060")
    ],
    targets: [
        .target(name: "PLzmaShim", dependencies: [.product(name: "PLzmaSDK", package: "PLzmaSDK")])
    ]
)
