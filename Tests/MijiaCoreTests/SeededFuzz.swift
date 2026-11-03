import Foundation

/// SplitMix64: a small deterministic generator so a fuzz failure reproduces from the printed seed.
struct SeededFuzzGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func bytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) })
    }
}

enum FuzzSupport {
    /// Shared base seed for the #186 fuzz suites; each suite derives its own from this.
    static let baseSeed: UInt64 = 0x0000_0186_C0FF_EE01

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Seeds the generator with a fresh per-iteration value but reports the parent seed on failure.
    static func iterationSeed(_ base: UInt64, _ iteration: Int) -> UInt64 {
        base &+ UInt64(iteration) &* 0x9E37_79B9
    }

    /// One seeded mutation: bit flips, truncation, insertion, deletion, replacement, or trailing junk.
    static func mutate(_ base: Data, rng: inout SeededFuzzGenerator) -> Data {
        var bytes = [UInt8](base)
        switch rng.int(in: 0...5) {
        case 0:
            for _ in 0..<rng.int(in: 1...8) where !bytes.isEmpty {
                let index = rng.int(in: 0...(bytes.count - 1))
                bytes[index] ^= UInt8(1 << rng.int(in: 0...7))
            }
        case 1:
            bytes = Array(bytes.prefix(rng.int(in: 0...bytes.count)))
        case 2:
            bytes.insert(contentsOf: rng.bytes(count: rng.int(in: 1...16)), at: rng.int(in: 0...bytes.count))
        case 3:
            if !bytes.isEmpty {
                let start = rng.int(in: 0...(bytes.count - 1))
                bytes.removeSubrange(start..<(start + rng.int(in: 1...(bytes.count - start))))
            }
        case 4:
            if !bytes.isEmpty {
                let start = rng.int(in: 0...(bytes.count - 1))
                let count = rng.int(in: 1...(bytes.count - start))
                bytes.replaceSubrange(start..<(start + count), with: rng.bytes(count: rng.int(in: 0...16)))
            }
        default:
            bytes.append(contentsOf: rng.bytes(count: rng.int(in: 0...32)))
        }
        return Data(bytes)
    }
}
