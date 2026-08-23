import Foundation
import Testing

struct PackageGraphVerifierTests {
    @Test
    func acceptsTheExactGraphIndependentOfManifestOrdering() throws {
        var graph = PackageGraphFixture.valid
        graph.products.reverse()
        graph.targets.reverse()
        for index in graph.targets.indices {
            var target = graph.targets[index]
            var dependencies = try #require(target["dependencies"] as? [[String: Any]])
            dependencies.reverse()
            target["dependencies"] = dependencies
            graph.targets[index] = target
        }

        let result = try verify(graph)

        #expect(result.status == 0)
    }

    @Test
    func rejectsAnAccidentallyPublishedProcessFixture() throws {
        var graph = PackageGraphFixture.valid
        graph.products.append(
            PackageGraphFixture.executableProduct(
                name: "KinlogueStorageProcessFixture",
                target: "KinlogueStorageProcessFixture"
            )
        )

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(result.standardError.contains("products do not match the exact allow-list"))
    }

    @Test
    func rejectsAnAccidentallyPublishedDICOMAcceptanceFixtureGenerator() throws {
        var graph = PackageGraphFixture.valid
        graph.products.append(
            PackageGraphFixture.executableProduct(
                name: "KinlogueDICOMAcceptanceFixtureGenerator",
                target: "KinlogueDICOMAcceptanceFixtureGenerator"
            )
        )

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(result.standardError.contains("products do not match the exact allow-list"))
    }

    @Test
    func rejectsAnAccidentallyPublishedExportWriterProbe() throws {
        var graph = PackageGraphFixture.valid
        graph.products.append(
            PackageGraphFixture.executableProduct(
                name: "KinlogueExportWriterProbe",
                target: "KinlogueExportWriterProbe"
            )
        )

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(result.standardError.contains("products do not match the exact allow-list"))
    }

    @Test
    func rejectsAnUnexpectedTarget() throws {
        var graph = PackageGraphFixture.valid
        graph.targets.append(
            PackageGraphFixture.target(name: "UnexpectedTarget", type: "regular")
        )

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(result.standardError.contains("targets do not match the exact allow-list"))
    }

    @Test
    func rejectsAnUnexpectedTargetDependency() throws {
        var graph = PackageGraphFixture.valid
        let appIndex = try #require(
            graph.targets.firstIndex { $0["name"] as? String == "KinlogueApp" }
        )
        var app = graph.targets[appIndex]
        var dependencies = try #require(app["dependencies"] as? [[String: Any]])
        dependencies.append(PackageGraphFixture.byName("UnexpectedDependency"))
        app["dependencies"] = dependencies
        graph.targets[appIndex] = app

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(
            result.standardError.contains(
                "KinlogueApp direct dependencies do not match the exact allow-list"
            )
        )
    }

    @Test
    func rejectsFixtureBoundaryDrift() throws {
        var graph = PackageGraphFixture.valid
        let fixtureIndex = try #require(
            graph.targets.firstIndex {
                $0["name"] as? String == "KinlogueStorageProcessFixture"
            }
        )
        var fixture = graph.targets[fixtureIndex]
        fixture["dependencies"] = [PackageGraphFixture.byName("KinloguePlatform")]
        graph.targets[fixtureIndex] = fixture

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(
            result.standardError.contains(
                "KinlogueStorageProcessFixture direct dependencies do not match the exact allow-list"
            )
        )
    }

    @Test
    func rejectsAnAdditionalPackageDependency() throws {
        var graph = PackageGraphFixture.valid
        graph.dependencies.append(["sourceControl": []])

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(
            result.standardError.contains(
                "package dependencies do not match the exact allow-list"
            )
        )
    }

    @Test
    func acceptsOnlyTheIsolatedDICOMHelperDependencyShape() throws {
        let result = try verify(PackageGraphFixture.valid)

        #expect(result.status == 0)
    }

    @Test
    func rejectsDicomCoreOutsideTheDecoderHelper() throws {
        var graph = PackageGraphFixture.valid
        let platformIndex = try #require(
            graph.targets.firstIndex { $0["name"] as? String == "KinloguePlatform" }
        )
        var platform = graph.targets[platformIndex]
        var dependencies = try #require(platform["dependencies"] as? [[String: Any]])
        dependencies.append(PackageGraphFixture.product("DicomCore", package: "DICOM-Swift"))
        platform["dependencies"] = dependencies
        graph.targets[platformIndex] = platform

        let result = try verify(graph)

        #expect(result.status != 0)
        #expect(result.standardError.contains(
            "KinloguePlatform direct dependencies do not match the exact allow-list"
        ))
    }

    private func verify(_ graph: PackageGraphFixture) throws -> VerificationResult {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-package-graph-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let manifest = temporaryDirectory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(
            withJSONObject: graph.jsonObject,
            options: [.sortedKeys]
        )
        try data.write(to: manifest, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repository.appendingPathComponent("scripts/verify-package-graph.sh").path,
            manifest.path,
        ]
        let standardError = Pipe()
        process.standardError = standardError
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        return VerificationResult(
            status: process.terminationStatus,
            standardError: String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct VerificationResult {
    let status: Int32
    let standardError: String
}

private struct PackageGraphFixture {
    var dependencies: [[String: Any]]
    var products: [[String: Any]]
    var targets: [[String: Any]]

    var jsonObject: [String: Any] {
        [
            "dependencies": dependencies,
            "products": products,
            "targets": targets,
        ]
    }

    static var valid: PackageGraphFixture {
        PackageGraphFixture(
            dependencies: [
                ["sourceControl": [["identity": "dicom-swift"]]],
                ["sourceControl": [["identity": "swift-nio"]]],
                ["sourceControl": [["identity": "zipfoundation"]]],
            ],
            products: [
                executableProduct(name: "Kinlogue", target: "KinlogueApp"),
            ],
            targets: [
                target(name: "KinlogueCore", type: "regular"),
                target(name: "KinlogueDICOMIPC", type: "regular"),
                target(
                    name: "KinlogueDICOMDecoderHelper",
                    type: "executable",
                    dependencies: [
                        byName("KinlogueDICOMIPC"),
                        product("DicomCore", package: "DICOM-Swift"),
                    ]
                ),
                target(
                    name: "KinlogueDICOMTestSupport",
                    type: "regular",
                    dependencies: [byName("KinlogueDICOMIPC")]
                ),
                target(
                    name: "KinlogueDICOMXPCProbe",
                    type: "executable",
                    dependencies: [
                        byName("KinloguePlatform"),
                        byName("KinlogueDICOMTestSupport"),
                    ]
                ),
                target(
                    name: "KinlogueDICOMAcceptanceFixtureGenerator",
                    type: "executable",
                    dependencies: [byName("KinlogueDICOMTestSupport")]
                ),
                target(
                    name: "KinloguePlatform",
                    type: "regular",
                    dependencies: [
                        byName("KinlogueCore"),
                        byName("KinlogueDICOMIPC"),
                        product("NIOCore", package: "swift-nio"),
                        product("NIOHTTP1", package: "swift-nio"),
                        product("NIOPosix", package: "swift-nio"),
                        product("ZIPFoundation", package: "ZIPFoundation"),
                    ]
                ),
                target(
                    name: "KinlogueApp",
                    type: "executable",
                    dependencies: [byName("KinlogueCore"), byName("KinloguePlatform")]
                ),
                target(
                    name: "KinlogueCoreTests",
                    type: "test",
                    dependencies: [byName("KinlogueCore")]
                ),
                target(
                    name: "KinloguePlatformTests",
                    type: "test",
                    dependencies: [
                        byName("KinloguePlatform"),
                        byName("KinlogueDICOMIPC"),
                        byName("KinlogueDICOMTestSupport"),
                        product("NIOEmbedded", package: "swift-nio"),
                        product("ZIPFoundation", package: "ZIPFoundation"),
                    ]
                ),
                target(
                    name: "KinlogueAppTests",
                    type: "test",
                    dependencies: [
                        byName("KinlogueApp"),
                        byName("KinlogueDICOMIPC"),
                        byName("KinlogueDICOMTestSupport"),
                    ]
                ),
                target(
                    name: "KinlogueStorageProcessFixture",
                    type: "executable",
                    dependencies: [
                        byName("KinlogueCore"),
                        byName("KinlogueDICOMIPC"),
                        byName("KinloguePlatform"),
                    ]
                ),
                target(
                    name: "KinlogueExportWriterProbe",
                    type: "executable",
                    dependencies: [
                        product("ZIPFoundation", package: "ZIPFoundation")
                    ]
                ),
                target(
                    name: "KinlogueStorageProcessTests",
                    type: "test",
                    dependencies: [
                        byName("KinlogueCore"),
                        byName("KinlogueDICOMTestSupport"),
                        byName("KinloguePlatform"),
                        byName("KinlogueStorageProcessFixture"),
                    ]
                ),
            ]
        )
    }

    static func executableProduct(name: String, target: String) -> [String: Any] {
        [
            "name": name,
            "settings": [],
            "targets": [target],
            "type": ["executable": NSNull()],
        ]
    }

    static func target(
        name: String,
        type: String,
        dependencies: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "dependencies": dependencies,
            "name": name,
            "type": type,
        ]
    }

    static func byName(_ name: String) -> [String: Any] {
        ["byName": [name, NSNull()]]
    }

    static func product(_ name: String, package: String) -> [String: Any] {
        ["product": [name, package, NSNull(), NSNull()]]
    }
}
