// swift-tools-version: 6.0
//
//  General Keyboard — the shared engine of the LekiTech iOS keyboards.
//
//  Products:
//    GeneralKeyboard        the keyboard engine; linked by a product's
//                           keyboard extension, which installs its
//                           KeyboardDefinition and subclasses
//                           GeneralKeyboardViewController.
//    GeneralKeyboardBridge  the contribution file protocol shared by the
//                           extension and the containing app.
//    GeneralKeyboardApp     the containing app's shared onboarding screen.
//    GeneralKeyboardReference
//                           a complete reference KeyboardDefinition used by
//                           the tests and by Reference/ (dev-only; never
//                           linked by a shipping product).
//
//  Swift 5 language mode on purpose: the shipping keyboard extensions
//  compile in Swift 5 mode, and Swift 6 mode adds runtime isolation
//  checks that would change behavior inside UIKit callbacks.
//
//  Tests run on an iOS simulator:
//    xcodebuild test -scheme GeneralKeyboard-Package \
//      -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'
//
import PackageDescription

// The same compiler semantics the shipping extensions build with: Swift 5
// mode plus the upcoming features Xcode turns on for those targets
// (SWIFT_APPROACHABLE_CONCURRENCY and SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_
// VISIBILITY). NonisolatedNonsendingByDefault changes where nonisolated
// async code runs, so engine code must not compile differently here than
// it does inside a product.
let swift5: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "GeneralKeyboard",
    defaultLocalization: "en",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "GeneralKeyboard", targets: ["GeneralKeyboard"]),
        .library(name: "GeneralKeyboardBridge", targets: ["GeneralKeyboardBridge"]),
        .library(name: "GeneralKeyboardApp", targets: ["GeneralKeyboardApp"]),
        .library(name: "GeneralKeyboardReference", targets: ["GeneralKeyboardReference"]),
    ],
    targets: [
        .target(
            name: "GeneralKeyboardBridge",
            swiftSettings: swift5
        ),
        .target(
            name: "GeneralKeyboard",
            dependencies: ["GeneralKeyboardBridge"],
            resources: [.process("Resources")],
            swiftSettings: swift5
        ),
        .target(
            name: "GeneralKeyboardApp",
            resources: [.process("Resources")],
            swiftSettings: swift5
        ),
        .target(
            name: "GeneralKeyboardReference",
            dependencies: ["GeneralKeyboard"],
            resources: [.process("Resources")],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "GeneralKeyboardTests",
            dependencies: ["GeneralKeyboard", "GeneralKeyboardBridge", "GeneralKeyboardApp", "GeneralKeyboardReference"],
            // Reference images are read through #filePath, not bundled.
            exclude: ["Snapshots"],
            resources: [.copy("Fixtures")],
            swiftSettings: swift5
        ),
    ]
)
