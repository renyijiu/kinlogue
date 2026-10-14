import GRDB
import KinlogueSQLiteConfiguration

/// Installs a guard only for this serialized connection scope. Never use nested
/// scopes on the same connection. The callback restores cancellation/deadline
/// errors before the store sanitizes SQLite's otherwise ambiguous INTERRUPT.
enum SQLiteReadProgress {
    private final class Context {
        let check: () throws -> Void
        var failure: (any Error)?
        init(check: @escaping () throws -> Void) { self.check = check }
        func step() -> Int32 {
            if failure != nil { return 1 }
            do { try check(); return 0 } catch { failure = error; return 1 }
        }
    }
    static func withGuard<T>(_ db: Database, check: () throws -> Void, body: () throws -> T) throws -> T {
        try withoutActuallyEscaping(check) { callback in
            let context = Context(check: callback)
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            sqlite3_progress_handler(db.sqliteConnection, 1_000, { pointer in
                guard let pointer else { return 1 }
                return Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue().step()
            }, pointer)
            defer {
                sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil)
                withExtendedLifetime(context) {}
            }
            do {
                try check()
                let result = try body()
                try check()
                return result
            } catch {
                if let failure = context.failure { throw failure }
                throw error
            }
        }
    }
}
