import Foundation

public struct BackupPublishedFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: UInt64

    public init(device: UInt64, inode: UInt64, byteCount: UInt64) {
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
    }
}
