import Foundation

/// Removes only standalone fillers from a VERBATIM transcript: a filler must sit between punctuation, spaces or the
/// ends of the text, so 好啊, 金额 and 额外 are never touched. Everything else, including false starts, is kept.
enum FillerFilter {
    private static let boundary = "[，。！？、；：,.!?;:\\s]"

    private static let rules: [(NSRegularExpression, String)] = [
        // 嗯 / 呃 / 额 / 啊 / 唔, repeated or not, plus the comma that usually follows.
        (regex("(^|\(boundary))(?:嗯|呃|额|啊|唔)+(?=\(boundary)|$)[，、,]?\\s*"), "$1"),
        (regex("(?i)(^|\(boundary))(?:u+m+|u+h+|e+r+m+|h+m+)(?=\(boundary)|$)[,，]?\\s*"), "$1"),
        // Tidy what removal leaves behind: a comma before other punctuation, leading punctuation, odd spacing.
        (regex("[，、,]\\s*([，。！？、；,.!?;])"), "$1"),
        (regex("^[\\s，、,。.]+"), ""),
        (regex("\\s+([，。！？、；,.!?;])"), "$1"),
        (regex(" {2,}"), " "),
    ]

    static func clean(_ text: String) -> String {
        var result = text
        for (expression, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        result = result.trimmed
        // A sentence that started with a filler should still start with a capital letter.
        if let first = result.first, first.isLowercase, text.trimmed.first.map({ !$0.isLowercase }) ?? false {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
