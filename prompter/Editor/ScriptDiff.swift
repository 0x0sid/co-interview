import Foundation

/// Minimal line-level diff for §12.3's AI-rewrite review — good enough for paragraph-shaped
/// script text; not a general-purpose diff algorithm. Classic LCS-based, O(n·m) DP, fine at
/// script sizes (tens to low hundreds of lines).
enum ScriptDiff {
    enum Line: Identifiable {
        case unchanged(String)
        case removed(String)
        case added(String)

        var id: String {
            switch self {
            case .unchanged(let text): "u:\(text)"
            case .removed(let text): "r:\(text)"
            case .added(let text): "a:\(text)"
            }
        }

        var text: String {
            switch self {
            case .unchanged(let text), .removed(let text), .added(let text): text
            }
        }
    }

    static func diff(original: String, revised: String) -> [Line] {
        let a = original.components(separatedBy: .newlines)
        let b = revised.components(separatedBy: .newlines)
        let n = a.count
        let m = b.count

        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var result: [Line] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                result.append(.unchanged(a[i]))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                result.append(.removed(a[i]))
                i += 1
            } else {
                result.append(.added(b[j]))
                j += 1
            }
        }
        while i < n { result.append(.removed(a[i])); i += 1 }
        while j < m { result.append(.added(b[j])); j += 1 }
        return result
    }
}
