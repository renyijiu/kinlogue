import CryptoKit
import Foundation

/// A content checksum used to detect accidental corruption in the plaintext
/// vault. It is not an authenticity proof and provides no confidentiality.
public enum ContentDigest {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
