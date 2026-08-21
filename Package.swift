// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Clio",
    platforms: [
        .macOS(.v14)  // macOS 14 (Sonoma) minimum, Sequoia compatible
    ],
    products: [
        // Executable app
        .executable(
            name: "Clio",
            targets: ["Clio"]
        ),
    ],
    dependencies: [
        // FluidAudio: Apache-2.0 Swift SDK for on-device speaker
        // diarization (CoreML / Apple Neural Engine). Replaces the
        // pyannote.audio Python subprocess + HuggingFace-token UX.
        // See `docs/no_anonymizer_v2_implementasjon.md` for context —
        // and `FluidDiarizationService.swift` for the Swift wrapper.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            from: "0.12.4"),
        // WhisperKit (argmax-oss-swift): on-device speech-to-text via
        // CoreML / Apple Neural Engine. Replaces the no-transcribe Python
        // subprocess bridge — no embedded interpreter, no second Mach-O
        // executable, so no app-sandbox entitlement conflict with the
        // main app's own sandbox. See ADR for the embedded-Python
        // sandbox dead end this replaces.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            from: "0.9.0"),
        // MSAL (Microsoft Authentication Library): official Entra ID /
        // Azure AD OAuth2 + PKCE client for the Teams/SharePoint upload
        // feature. Handles the browser-based sign-in flow, secure token
        // caching, and silent token refresh — deliberately not
        // hand-rolled, since token security is not something we want to
        // own ourselves. Distributed as a precompiled binary
        // .xcframework (no extra build-time compilation).
        // See Sources/Clio/Upload/EntraConfig.swift for tenant/client
        // configuration and Sources/Clio/Upload/GraphAuthService.swift
        // for the Swift wrapper.
        .package(
            url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc.git",
            from: "2.15.0"),
    ],
    targets: [
        // Executable app target (combines all sources)
        .executableTarget(
            name: "Clio",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "MSAL", package: "microsoft-authentication-library-for-objc"),
            ],
            path: "Sources/Clio",
            linkerSettings: [
                .linkedFramework("MultipeerConnectivity"),
            ]
        ),
        // Unit tests for pure, hardware-independent logic (sidecar parsing,
        // transcript merge, transfer stem matching). Uses `@testable import`
        // to reach internal symbols on the executable target.
        .testTarget(
            name: "ClioTests",
            dependencies: ["Clio"],
            path: "tests/ClioTests"
        ),
    ]
)
