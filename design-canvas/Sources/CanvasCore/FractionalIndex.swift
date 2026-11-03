/// Order keys for siblings. A key between two neighbours always exists, so a move or
/// insert touches only the moved node and concurrent inserts never renumber siblings.
public enum FractionalIndex {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let base = alphabet.count

    /// A key strictly between `lower` and `upper`. `nil` means unbounded on that side.
    public static func between(_ lower: String?, _ upper: String?) -> String {
        let a = digits(lower ?? "")
        let b = upper.map(digits)
        if let b { precondition(compare(a, b), "lower must sort before upper") }
        return String(midpoint(a, b).map { alphabet[$0] })
    }

    /// `count` increasing keys after `lower`, for bulk inserts.
    public static func sequence(after lower: String?, count: Int) -> [String] {
        var keys: [String] = []
        var previous = lower
        for _ in 0..<count {
            let key = between(previous, nil)
            keys.append(key)
            previous = key
        }
        return keys
    }

    private static func digits(_ key: String) -> [Int] {
        key.map { character in
            guard let index = alphabet.firstIndex(of: character) else { preconditionFailure("Invalid key \(key)") }
            return index
        }
    }

    private static func compare(_ a: [Int], _ b: [Int]) -> Bool { a.lexicographicallyPrecedes(b) }

    // Keys never end in the zero digit, which keeps a key below any non-empty upper bound.
    private static func midpoint(_ a: [Int], _ b: [Int]?) -> [Int] {
        if let b {
            var shared = 0
            while shared < b.count, (shared < a.count ? a[shared] : 0) == b[shared] { shared += 1 }
            if shared > 0 {
                return Array(b[..<shared]) + midpoint(Array(a.dropFirst(shared)), Array(b.dropFirst(shared)))
            }
        }
        let low = a.first ?? 0
        let high = b?.first ?? base
        if high - low > 1 { return [(low + high) / 2] }
        if let b, b.count > 1 { return [b[0]] }
        return [low] + midpoint(Array(a.dropFirst()), nil)
    }
}
