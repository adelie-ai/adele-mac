// swift-tools-version:6.0
import PackageDescription
import Foundation

// Absolute path to the Rust core's build output. Defaults to the sibling
// checkout (<...>/adelie-ai/client-ui-common is a sibling of adele-mac), but is
// overridable via ADELE_CORE_LIB_DIR so the package still builds from a git
// worktree (where the sibling layout doesn't hold). Phase 1 links the debug
// dylib directly and bakes a dev RPATH; distribution packaging comes later.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let coreLibDir = ProcessInfo.processInfo.environment["ADELE_CORE_LIB_DIR"]
    ?? packageDir
        .deletingLastPathComponent()                   // adelie-ai/
        .appendingPathComponent("client-ui-common/target/debug")
        .standardizedFileURL.path

// Link the prebuilt Rust cdylib and bake a dev RPATH so the loader resolves
// @rpath/libadele_client_core.dylib at runtime. Shared by every executable.
let coreLinkFlags: LinkerSetting = .unsafeFlags([
    "-L", coreLibDir,
    "-ladele_client_core",
    "-Xlinker", "-rpath", "-Xlinker", coreLibDir,
])

let package = Package(
    name: "adele-mac",
    platforms: [.macOS(.v14)],
    targets: [
        // Wraps the cbindgen-generated C ABI header as an importable module.
        // `scripts/build-core.sh` stages the header into include/ before build.
        .systemLibrary(name: "CAdeleCore", path: "Sources/CAdeleCore"),

        // Swift wrapper over the C ABI: owns the opaque Core handle, marshals the
        // core's JSON view-events onto the main thread, decodes them, and exposes
        // typed intents. The macOS analog of adele-kde's AdeleCore QObject glue.
        .target(
            name: "AdeleCore",
            dependencies: ["CAdeleCore"]
        ),

        // The SwiftUI app. Links the prebuilt Rust cdylib with a dev RPATH so the
        // dynamic loader resolves @rpath/libadele_client_core.dylib at runtime.
        .executableTarget(
            name: "AdeleMac",
            dependencies: ["AdeleCore"],
            linkerSettings: [coreLinkFlags]
        ),

        // Headless end-to-end smoke driver: login → connect → new conversation →
        // prompt → stream, printing each view-event. Used to validate the core +
        // transport + auth against a real daemon without the GUI.
        .executableTarget(
            name: "AdeleSmoke",
            dependencies: ["AdeleCore"],
            linkerSettings: [coreLinkFlags]
        ),

        // Unit tests for the pure logic in AdeleCore: view-event decoding,
        // command wire-format builders, result decoders, login-URL derivation.
        // Links the core dylib (AdeleCore references the C symbols).
        .testTarget(
            name: "AdeleCoreTests",
            dependencies: ["AdeleCore"],
            linkerSettings: [coreLinkFlags]
        ),
    ]
)
