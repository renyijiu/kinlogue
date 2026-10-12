import Foundation
import KinlogueDICOMTestSupport
import Testing
@testable import KinloguePlatform

@Test
func sqliteRealProcessesRejectSecondOwnerAndReleaseAfterCrash() async throws {
    try await withOwnedVaultFixture { fixture in
        try await withStorageProcessFixture(processCount: 2) { processes in
            let owner = processes[0]
            let contender = processes[1]
            try owner.send(.init(operation: "openSQLite", rootURL: fixture.rootURL))
            #expect(try await owner.nextResponse().event == "sqliteOpened")
            let databaseURL = fixture.rootURL.appendingPathComponent(SQLiteLibraryStore.databaseFilename)
            let before = try Data(contentsOf: databaseURL)
            try contender.send(.init(operation: "openSQLite", rootURL: fixture.rootURL))
            let rejected = try await contender.nextResponse()
            #expect(rejected.code == "occupied")
            #expect(try Data(contentsOf: databaseURL) == before)
            let alias = fixture.rootURL.deletingLastPathComponent().appendingPathComponent("vault")
            if FileManager.default.fileExists(atPath: alias.path) {
                try contender.send(.init(operation: "openSQLite", rootURL: alias))
                #expect(try await contender.nextResponse().code == "occupied")
            }
            try owner.send(.init(operation: "suspendSQLite"))
            #expect(try await owner.nextResponse().event == "sqliteSuspended")
            try contender.send(.init(operation: "openSQLite", rootURL: fixture.rootURL))
            #expect(try await contender.nextResponse().code == "occupied")
            try await owner.crash()
            try contender.send(.init(operation: "openSQLite", rootURL: fixture.rootURL))
            #expect(try await contender.nextResponse().event == "sqliteOpened")
            try contender.send(.init(operation: "closeSQLite"))
            #expect(try await contender.nextResponse().event == "sqliteClosed")
            let reopened = try SQLiteLibraryStore(rootURL: fixture.rootURL)
            try reopened.close()
        }
    }
}

@Test(arguments: Array(1...7))
func sqliteOriginalsRecoverAfterRealProcessCrash(point: Int) async throws {
    try await withOwnedVaultFixture { fixture in
        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "holdSQLiteOriginal", rootURL: fixture.rootURL, variant: point))
            #expect(try await process.nextResponse().event == "leaseHeld")
            try await process.crash()
        }
        let reopened = try SQLiteLibraryStore(rootURL: fixture.rootURL)
        defer { try? reopened.close() }
        #expect(try reopened.recoverOriginals().isEmpty)
        let originals = fixture.rootURL.appendingPathComponent("originals")
        let files = try FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)
        #expect(files.count == (point == 5 ? 1 : 0))
        if point == 5 {
            let file = try #require(files.first)
            let id = try #require(UUID(uuidString: file.deletingPathExtension().lastPathComponent))
            let pin = try reopened.pinOriginal(id)
            defer { pin.release() }
            try pin.withVerifiedDescriptor { descriptor in
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                try handle.seek(toOffset: 0)
                #expect(try handle.readToEnd() == Data("synthetic SQLite original".utf8))
            }
        }
    }
}

@Test(arguments: Array(1...4))
func sqliteInitializationRecoversAfterRealProcessCrash(point: Int) async throws {
    try await withOwnedVaultFixture { fixture in
        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "holdSQLiteInitialization", rootURL: fixture.rootURL, variant: point))
            #expect(try await process.nextResponse().event == "leaseHeld")
            try await process.crash()
        }
        let reopened = try SQLiteLibraryStore(rootURL: fixture.rootURL)
        #expect(try reopened.state().generation == 0)
        try reopened.close()
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("initialization.json").path))
    }
}

@Test(arguments: Array(1...5))
func sqliteLANUploadsRecoverAfterRealProcessCrash(point: Int) async throws {
    try await withOwnedVaultFixture { fixture in
        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "holdSQLiteLANUpload", rootURL: fixture.rootURL, variant: point))
            #expect(try await process.nextResponse().event == "leaseHeld")
            try await process.crash()
        }
        let reopened = try SQLiteLibraryStore(rootURL: fixture.rootURL)
        defer { try? reopened.close() }
        let inbox = try SQLiteLANInboxStore(store: reopened)
        let recovered = try await inbox.initialize()
        #expect(recovered.items.count == (point == 4 ? 1 : 0))
        let files = try FileManager.default.contentsOfDirectory(at: fixture.rootURL.appendingPathComponent("originals"), includingPropertiesForKeys: nil)
        #expect(files.count == recovered.items.count)
        #expect(try await inbox.snapshotAndStorageSummary().storage.cleanupDebtObjectCount == 0)
        if let item = recovered.items.first {
            let bytes = try await inbox.withVerifiedItemSourceContent(itemID: item.id) { descriptor in
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                try handle.seek(toOffset: 0)
                return try handle.readToEnd()
            }
            #expect(bytes == Data("synthetic SQLite LAN upload".utf8))
        }
    }
}

@Test(arguments: Array(1...5))
func sqliteDICOMHandoffRecoversAfterRealProcessCrash(point: Int) async throws {
    try await withOwnedVaultFixture { fixture in
        let source = fixture.rootURL.deletingLastPathComponent().appendingPathComponent("DICOMSource")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(to: source.appendingPathComponent("synthetic.dcm"))
        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "holdSQLiteDICOMImport", rootURL: fixture.rootURL, variant: point))
            #expect(try await process.nextResponse().event == "leaseHeld")
            try await process.crash()
        }
        let reopened = try SQLiteLibraryStore(rootURL: fixture.rootURL)
        defer { try? reopened.close() }
        let repository = try SQLiteDICOMRepository(store: reopened)
        let listing = try await repository.summaries()
        #expect(listing.items.count == (point == 5 ? 1 : 0))
        #expect(listing.damagedIDs.isEmpty)
        #expect(try reopened.recoverOriginals().isEmpty)
        #expect(try VaultDICOMImportJournal(rootURL: fixture.rootURL).pendingOperationCount() == 0)
        let originals = try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.appendingPathComponent("originals").path)
        #expect(originals.count == listing.items.count)
        if let study = listing.items.first {
            #expect(try await repository.details(study.id).series.count == 1)
        }
    }
}
