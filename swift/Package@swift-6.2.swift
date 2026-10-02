// swift-tools-version: 6.2
//
// Манифест для Swift 6.2 и новее. Отличается от Package.swift одним:
// зависимость подключается с `traits: []`.
//
// FluidAudio тянет готовый бинарный модуль нормализации текста для своих
// синтезаторов речи — статическую библиотеку на Rust без исходников в
// пакете. Dictor речь не синтезирует, а приложению, которое обещает работать
// целиком на устройстве, непрозрачный бинарник в составе ни к чему. Отключить
// его можно только трейтом, а трейты SwiftPM соблюдает начиная с 6.2: на 6.1
// синтаксис принимается, но модуль всё равно линкуется. Поэтому манифестов
// два, и SwiftPM сам берёт этот там, где он работает; Package.swift остаётся
// для тулчейнов постарше, в том числе для CI.
//
// Ревизия FluidAudio в обоих файлах обязана совпадать — за этим следит
// scripts/check.sh.
//
// Dictor — a Swift push-to-talk dictation app
// for macOS Apple Silicon. Native AppKit / AVFoundation, FluidAudio
// driving Parakeet Ultra on the Apple Neural Engine. macOS 14
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
                 revision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f",
                 traits: []),
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
