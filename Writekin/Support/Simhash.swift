import Foundation

private func fnv1a64(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return hash
}

func simhash64(of text: String) -> Int64 {
    let words = canonicalize(text).split(separator: " ").map(String.init)
    guard !words.isEmpty else { return 0 }
    var votes = [Int](repeating: 0, count: 64)
    let shingles: [String]
    if words.count < 3 {
        shingles = [words.joined(separator: " ")]
    } else {
        shingles = (0...(words.count - 3)).map {
            words[$0...($0 + 2)].joined(separator: " ")
        }
    }
    for shingle in shingles {
        let hash = fnv1a64(shingle)
        for bit in 0..<64 {
            votes[bit] += (hash >> UInt64(bit)) & 1 == 1 ? 1 : -1
        }
    }
    var result: UInt64 = 0
    for bit in 0..<64 where votes[bit] > 0 {
        result |= 1 << UInt64(bit)
    }
    return Int64(bitPattern: result)
}

func hammingDistance(_ a: Int64, _ b: Int64) -> Int {
    (UInt64(bitPattern: a) ^ UInt64(bitPattern: b)).nonzeroBitCount
}
