// swift-tools-version: 6.0
//
// Dictor — a Swift push-to-talk dictation app
// for macOS Apple Silicon. Native AppKit / AVFoundation, FluidAudio
// driving Parakeet TDT v3 on the Apple Neural Engine. macOS 14
// (Sonoma) minimum. The Hardened Runtime microphone entitlement
// (`com.apple.security.device.audio-input` in `entitlements.plist`)
// is what Tahoe 26 checks before exposing the app in Privacy &
// Security → Microphone; on macOS 14–25 the legacy sandbox key
// (`com.apple.security.device.microphone`) is the fallback. Both
// ship in the same build so a single signed binary works
// across the supported range.
import PackageDescription

let package = Package(
    name: "Dictor",
    platforms: [
        .macOS("14.0"),
    ],
    products: [
        .executable(name: "Dictor", targets: ["Dictor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "313feb4bd692780a9a5b5fa9048fdb119486dde8"),
    ],
    targets: [
        // A separate target only because SwiftPM cannot mix languages
        // inside one. It holds a single @try/@catch bridge: AVFoundation
        // reports invalid audio formats by raising NSException, which
        // Swift cannot catch, and an uncaught one suspends the thread
        // instead of crashing — a frozen app with no diagnostics.
        .target(name: "DictorObjCSupport"),
        .executableTarget(
            name: "Dictor",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "DictorObjCSupport",
            ]
            // No `resources:` here on purpose. SwiftPM bundles them as
            // a `<Package>_<Target>.bundle` directory next to the
            // executable, which `codesign --deep` won't accept as a
            // signable component because it lacks Info.plist. Instead,
            // the menubar PNGs are copied into Contents/Resources/ by
            // scripts/build-app.sh — the canonical .app layout
            // where Bundle.main finds them via the standard search
            // path. Source PNGs live in swift/Resources/ at the repo
            // root, NOT in the SwiftPM target, so SwiftPM never sees them.
        ),
    ]
)
