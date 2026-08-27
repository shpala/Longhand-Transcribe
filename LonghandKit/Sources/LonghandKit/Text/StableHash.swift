import Foundation

/// A hash that means the same thing in every process and every build.
///
/// `String.hashValue` is seeded per process, so anything persisted from it
/// stops matching the moment the app relaunches, which is exactly what a
/// stored edit anchor must not do (§13.2 durability). CryptoKit would do, but
/// this target is Foundation-only by design (see CLAUDE.md), and change
/// detection needs no cryptographic strength: FNV-1a is enough to tell "this
/// is the text I edited" from "this is different text".
public enum StableHash {

    /// FNV-1a over the UTF-8 bytes, as 16 lowercase hex digits.
    public static func hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016lx", hash)
    }
}
