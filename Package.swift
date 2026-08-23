// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Kinlogue",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Kinlogue", targets: ["KinlogueApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ThalesMMS/DICOM-Swift.git",
            exact: "1.3.3"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        )
    ],
    targets: [
        .target(name: "KinlogueCore"),
        .target(name: "KinlogueDICOMIPC"),
        .executableTarget(
            name: "KinlogueDICOMDecoderHelper",
            dependencies: [
                "KinlogueDICOMIPC",
                .product(name: "DicomCore", package: "DICOM-Swift"),
            ]
        ),
        .target(
            name: "KinlogueDICOMTestSupport",
            dependencies: ["KinlogueDICOMIPC"]
        ),
        .executableTarget(
            name: "KinlogueDICOMXPCProbe",
            dependencies: ["KinloguePlatform", "KinlogueDICOMTestSupport"]
        ),
        .executableTarget(
            name: "KinlogueDICOMAcceptanceFixtureGenerator",
            dependencies: ["KinlogueDICOMTestSupport"]
        ),
        .target(
            name: "KinloguePlatform",
            dependencies: [
                "KinlogueCore",
                "KinlogueDICOMIPC",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                .copy("Resources/LANUpload")
            ],
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "KinlogueApp",
            dependencies: ["KinlogueCore", "KinloguePlatform"],
            exclude: ["Localization"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KinlogueCoreTests",
            dependencies: ["KinlogueCore"]
        ),
        .testTarget(
            name: "KinloguePlatformTests",
            dependencies: [
                "KinloguePlatform",
                "KinlogueDICOMIPC",
                "KinlogueDICOMTestSupport",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "KinlogueAppTests",
            dependencies: [
                "KinlogueApp",
                "KinlogueDICOMIPC",
                "KinlogueDICOMTestSupport",
            ]
        ),
        .executableTarget(
            name: "KinlogueStorageProcessFixture",
            dependencies: ["KinlogueCore", "KinlogueDICOMIPC", "KinloguePlatform"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "KinlogueExportWriterProbe",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "KinlogueStorageProcessTests",
            dependencies: [
                "KinlogueCore",
                "KinloguePlatform",
                "KinlogueDICOMTestSupport",
                "KinlogueStorageProcessFixture",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
