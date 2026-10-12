import KinlogueCore
import KinloguePlatform

actor SQLiteVaultDestroyService: VaultDestroyServicing {
    private let store: SQLiteLibraryStore
    init(store: SQLiteLibraryStore) { self.store = store }
    @concurrent func destroyCurrentVault() async throws { try store.destroyLibrary() }
}
