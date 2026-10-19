import Foundation

/// Adapted from Voxt's GeminiLiveTranscriptJoining (Apache-2.0).
/// Gemini emits Chinese segments that must not be space-joined and English ones that must be, so decide per boundary.
enum TranscriptJoiner {
    static func join(_ segments: [String]) -> String {
        var result = ""
        for segment in segments {
            let piece = segment.trimmed
            guard !piece.isEmpty else { continue }
            if result.isEmpty {
                result = piece
                continue
            }
            if needsSeparator(previous: result, next: piece) {
                result += " "
            }
            result += piece
        }
        return result
    }

    private static func needsSeparator(previous: String, next: String) -> Bool {
        guard let left = previous.unicodeScalars.last, let right = next.unicodeScalars.first else { return false }
        return !isCJK(left) && !isCJK(right)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
