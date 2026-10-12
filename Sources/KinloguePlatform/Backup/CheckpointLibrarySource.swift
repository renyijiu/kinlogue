import Foundation
import KinlogueCore

// Temporary compile bridge until the single production cutover removes the JSON source.
package enum CheckpointLibrarySource: Sendable {
    case legacy(PlaintextLibraryBackupSource)
    case logical(SQLiteLogicalBackupSource)
    package func currentRevision() async throws -> BackupRevisionPair {
        switch self {
        case let .legacy(source): try await source.prepare().revisionPair
        case let .logical(source): try source.currentRevision()
        }
    }
    func prepare() async throws -> CheckpointLibraryPlan {
        switch self {
        case let .legacy(source): .legacy(try await source.prepare())
        case let .logical(source): .logical(try await source.prepare())
        }
    }
    func containerSources(for plan: CheckpointLibraryPlan) async throws -> [BackupContainerEntrySource] {
        switch (self, plan) {
        case let (.legacy(source), .legacy(plan)): return await source.containerSources(for: plan)
        case let (.logical(_), .logical(plan)): return plan.sources()
        default: throw SQLiteLogicalBackupError.invalidStream
        }
    }
    func withValidatedCurrentPair<T: Sendable>(for plan: CheckpointLibraryPlan, _ body: @Sendable () throws -> T) async throws -> T {
        switch (self, plan) {
        case let (.legacy(source), .legacy(plan)): return try await source.withValidatedCurrentPair(for: plan, body)
        case let (.logical(_), .logical(plan)): try plan.validate(); return try body()
        default: throw SQLiteLogicalBackupError.invalidStream
        }
    }
    func maximumSimultaneousOpenFileCount(for plan: CheckpointLibraryPlan) async -> Int {
        switch (self, plan) {
        case let (.legacy(source), .legacy): await source.maximumSimultaneousOpenFileCount
        case let (.logical, .logical(plan)): plan.pins.maximumSimultaneousOpenFileCount
        default: 0
        }
    }
}

enum CheckpointLibraryPlan: Sendable {
    case legacy(PlaintextLibraryBackupPlan)
    case logical(SQLiteLogicalBackupSnapshot)
    var revisionPair: BackupRevisionPair { switch self { case let .legacy(plan): plan.revisionPair; case let .logical(plan): plan.revisionPair } }
    var maximumContainerByteCount: UInt64 { get throws {
        switch self { case let .legacy(plan): plan.maximumContainerByteCount; case let .logical(plan): try plan.maximumContainerByteCount }
    } }
    func release() { if case let .logical(plan) = self { plan.release() } }
}
