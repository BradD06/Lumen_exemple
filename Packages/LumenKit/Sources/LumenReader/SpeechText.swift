import Foundation
import NaturalLanguage

/// Кусок главы, как его собирает скрипт читалки: абзац, заголовок или код.
/// `start` считается так же, как место чтения (`SourceLocator.textOffset`): в символах UTF-16
/// от начала текста главы, поэтому часть потом можно подсветить и запомнить как место.
/// Пропущенное внутри куска (сноски, номера страниц) заменено пробелами той же длины.
public struct SpeechBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text
        case heading
        case code
    }

    public var kind: Kind
    public var text: String
    /// Текст как в книге, со сносками (той же длины, что `text`): по нему выписка находит место.
    public var raw: String?
    public var start: Int

    public init(kind: Kind = .text, text: String, raw: String? = nil, start: Int) {
        self.kind = kind
        self.text = text
        self.raw = raw
        self.start = start
    }
}

/// Часть текста, которую голос говорит целиком и которая подсвечена, пока звучит: предложение
/// (или абзац у голоса, который читает абзацами, см. `SpeechText.ramped`).
public struct SpeechPart: Hashable, Sendable {
    /// Что сказать: без переносов, лишних пробелов и номеров сносок.
    public var spoken: String
    /// Тот же кусок, как он стоит в тексте главы: по нему выписка находит место в книге.
    public var raw: String
    /// Где часть в главе и сколько символов главы подсветить.
    public var start: Int
    public var length: Int
    public var isHeading: Bool

    public var end: Int { start + length }

    public init(spoken: String, raw: String? = nil, start: Int, length: Int, isHeading: Bool = false) {
        self.spoken = spoken
        self.raw = raw ?? spoken
        self.start = start
        self.length = length
        self.isHeading = isHeading
    }
}

/// Текст главы для чтения вслух: куски → части (предложения) со своими местами в главе.
/// Очень длинное предложение режется по запятым. `groupLength` склеивает соседние предложения
/// абзаца в одну часть, пока она короче этого числа знаков (0 — каждое предложение отдельно).
/// Код не читается (на слух бессмысленно), вместо него короткое «пример кода пропущен».
/// Голые номера страниц и строки из одних знаков пропускаются.
public enum SpeechText {
    public static let codeNotice = "Пример кода пропущен."
    /// Длиннее предложение режется по запятым: подсветка не стоит на месте полминуты.
    public static let maxPartLength = 320

    public static func parts(from blocks: [SpeechBlock], groupLength: Int = 0) -> [SpeechPart] {
        var grouping = Grouping(limit: groupLength)
        return parts(from: blocks, grouping: &grouping)
    }

    /// Самый длинный абзац одной частью у голоса, который читает абзацами; длиннее режется по предложениям.
    public static let paragraphLength = 600
    /// Насколько каждая следующая часть может быть длиннее: доля уже прочитанного после старта.
    public static let rampGrowth = 0.3

    /// Части абзацами для голоса, который озвучивает лишь чуть быстрее речи («Голос Lumen» с домашнего
    /// компьютера). Целый абзац с места старта он готовил бы полминуты, поэтому с места `offset` идёт
    /// одно предложение, а дальше части растут: каждая не длиннее первой плюс `growth` от уже прочитанного,
    /// пока не станут целыми абзацами до `limit` знаков. Пока звучат первые части, голос успевает
    /// приготовить следующие, и пауз между ними нет. Части не переходят через границу абзаца;
    /// до места старта текст идёт абзацами.
    public static func ramped(
        from blocks: [SpeechBlock],
        startingAt offset: Int,
        limit: Int = paragraphLength,
        growth: Double = rampGrowth
    ) -> [SpeechPart] {
        var grouping = Grouping(limit: limit, rampStart: offset, growth: growth)
        return parts(from: blocks, grouping: &grouping)
    }

    static func parts(from blocks: [SpeechBlock], grouping: inout Grouping) -> [SpeechPart] {
        var result: [SpeechPart] = []
        for original in blocks {
            // Переносы строк внутри абзаца (в EPUB их полно) разбивщик принял бы за конец
            // предложения: заменяем их пробелами той же длины, место в главе не меняется.
            var block = original
            block.text = flattened(original.text)
            block.raw = original.raw ?? original.text
            switch block.kind {
            case .code:
                let length = block.text.utf16.count
                guard length > 0, hasWords(block.text) else { continue }
                // Несколько блоков кода подряд говорим один раз.
                if let last = result.last, last.spoken == codeNotice, block.start - last.end < 4 {
                    result[result.count - 1].length = block.start + length - last.start
                    continue
                }
                result.append(SpeechPart(spoken: codeNotice, start: block.start, length: length))
                grouping.counted(result[result.count - 1])
            case .heading:
                guard !isNoise(block.text),
                      let range = trimmed(block.text, in: block.text.startIndex..<block.text.endIndex) else { continue }
                result.append(part(block, range, isHeading: true))
                grouping.counted(result[result.count - 1])
            case .text:
                guard !isNoise(block.text) else { continue }
                let pieces = sentences(in: block.text).flatMap { cut(block.text, $0) }
                for range in grouping.group(block.text, pieces, at: block.start) {
                    guard let range = trimmed(block.text, in: range) else { continue }
                    let made = part(block, range, isHeading: false)
                    if hasWords(made.spoken) { result.append(made) }
                }
            }
        }
        return result
    }

    /// Часть, на которой стоит место `offset`: первая, что кончается после него.
    public static func index(of offset: Int, in parts: [SpeechPart]) -> Int? {
        guard !parts.isEmpty else { return nil }
        var low = 0
        var high = parts.count
        while low < high {
            let middle = (low + high) / 2
            if parts[middle].end <= offset { low = middle + 1 } else { high = middle }
        }
        return low < parts.count ? low : nil
    }

    /// Язык главы, чтобы выбрать голос: «ru», «en»…
    /// Предложение части `part`, на котором стоит место `offset`, в символах главы: голос может читать
    /// целыми абзацами, а подсветка всё равно идёт по предложениям (`sentences` — части `parts(from:)`).
    /// Не нашлось — вся часть.
    public static func sentence(at offset: Int, of part: SpeechPart, in sentences: [SpeechPart]) -> Range<Int> {
        let whole = part.start..<part.end
        guard let found = index(of: max(offset, part.start), in: sentences) else { return whole }
        let sentence = sentences[found]
        let start = max(sentence.start, part.start)
        let end = min(sentence.end, part.end)
        return start < end ? start..<end : whole
    }

    public static func language(of parts: [SpeechPart]) -> String? {
        var sample = ""
        for part in parts where !part.isHeading && part.spoken != codeNotice {
            sample += part.spoken + " "
            if sample.count > 2_000 { break }
        }
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Примерно сколько секунд займут части при обычной скорости: ~15 символов в секунду.
    public static func estimatedSeconds(of parts: some Collection<SpeechPart>, rate: Double = 1) -> Double {
        let characters = parts.reduce(0) { $0 + $1.spoken.count }
        return Double(characters) / (15 * max(rate, 0.1))
    }

    // MARK: Разбор

    static func sentences(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        return ranges.isEmpty ? [text.startIndex..<text.endIndex] : ranges
    }

    /// Предложение длиннее предела режется по знакам препинания, а если их нет, по пробелу.
    static func cut(_ text: String, _ range: Range<String.Index>) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var start = range.lowerBound
        while text.distance(from: start, to: range.upperBound) > maxPartLength {
            let limit = text.index(start, offsetBy: maxPartLength)
            let window = text[start..<limit]
            let cut = window.lastIndex { ",;:—–".contains($0) }.map { text.index(after: $0) }
                ?? window.lastIndex(where: \.isWhitespace)
                ?? limit
            guard cut > start else { break }
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<range.upperBound)
        return pieces
    }

    /// Как склеивать предложения абзаца в части: до `limit` знаков, а с разгоном от места
    /// `rampStart` — сначала одно предложение, потом всё длиннее (`ramped`).
    struct Grouping {
        var limit: Int
        var rampStart: Int?
        var growth: Double = 0
        /// Длина части, с которой начинается чтение, и сколько знаков прочитано после старта.
        private(set) var first: Int?
        private(set) var played = 0

        /// Совсем короткая первая фраза («— Да.») не должна держать разгон на месте.
        static let shortestFirst = 60

        init(limit: Int, rampStart: Int? = nil, growth: Double = 0) {
            self.limit = limit
            self.rampStart = rampStart
            self.growth = growth
        }

        /// Заголовок или пропущенный код после старта тоже звучит и даёт голосу время.
        mutating func counted(_ part: SpeechPart) {
            guard first != nil else { return }
            played += part.spoken.count
        }

        mutating func group(_ text: String, _ pieces: [Range<String.Index>], at blockStart: Int) -> [Range<String.Index>] {
            guard let start = rampStart else { return SpeechText.group(text, pieces, upTo: limit) }
            var result: [Range<String.Index>] = []
            var current: Range<String.Index>?
            var currentAfter = false
            for piece in pieces {
                // Конец без пробелов, как у части: так же считает `index(of:in:)`.
                let last = SpeechText.trimmed(text, in: piece)?.upperBound ?? piece.upperBound
                let after = blockStart + text.utf16.distance(from: text.startIndex, to: last) > start
                if after, first == nil {
                    // Предложение, с которого начинается чтение: отдельной частью.
                    if let current { result.append(current) }
                    let length = text.distance(from: piece.lowerBound, to: piece.upperBound)
                    first = max(length, Self.shortestFirst)
                    played += length
                    result.append(piece)
                    current = nil
                    continue
                }
                let budget = after ? min(limit, (first ?? 0) + Int(growth * Double(played))) : limit
                if let joined = current, currentAfter == after,
                   text.distance(from: joined.lowerBound, to: piece.upperBound) <= budget {
                    current = joined.lowerBound..<piece.upperBound
                    continue
                }
                if let done = current {
                    result.append(done)
                    if currentAfter { played += text.distance(from: done.lowerBound, to: done.upperBound) }
                }
                current = piece
                currentAfter = after
            }
            if let done = current {
                result.append(done)
                if currentAfter { played += text.distance(from: done.lowerBound, to: done.upperBound) }
            }
            return result
        }
    }

    /// Склеивает соседние куски, пока часть короче `length` знаков.
    static func group(_ text: String, _ pieces: [Range<String.Index>], upTo length: Int) -> [Range<String.Index>] {
        guard length > 0, var current = pieces.first else { return pieces }
        var result: [Range<String.Index>] = []
        for piece in pieces.dropFirst() {
            if text.distance(from: current.lowerBound, to: piece.upperBound) <= length {
                current = current.lowerBound..<piece.upperBound
            } else {
                result.append(current)
                current = piece
            }
        }
        result.append(current)
        return result
    }

    /// Диапазон без пробелов по краям; `nil`, если в нём одни пробелы.
    static func trimmed(_ text: String, in range: Range<String.Index>) -> Range<String.Index>? {
        guard let first = text[range].firstIndex(where: { !$0.isWhitespace }),
              let last = text[range].lastIndex(where: { !$0.isWhitespace }) else { return nil }
        return first..<text.index(after: last)
    }

    private static func part(_ block: SpeechBlock, _ range: Range<String.Index>, isHeading: Bool) -> SpeechPart {
        let text = block.text
        let start = block.start + text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.utf16.distance(from: range.lowerBound, to: range.upperBound)
        let offset = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let raw = block.raw.flatMap { full -> String? in
            let units = Array(full.utf16)
            guard offset + length <= units.count else { return nil }
            return String(decoding: units[offset..<offset + length], as: UTF16.self)
        } ?? String(text[range])
        return SpeechPart(spoken: clean(raw), raw: raw, start: start, length: length, isHeading: isHeading)
    }

    /// Переводы строк → пробелы, по одному символу UTF-16 на символ: места не сдвигаются.
    static func flattened(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Мягкие переносы, сноски вида [12] и лишние пробелы голосу не нужны.
    static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\u{00AD}", with: "")
        value = value.replacingOccurrences(of: #"\[\d{1,3}\]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Номер страницы, «* * *» и прочее, что вслух не читают.
    static func isNoise(_ text: String) -> Bool {
        let value = clean(text)
        if value.isEmpty { return true }
        if value.range(of: #"^[\d\s.\-–—]+$"#, options: .regularExpression) != nil { return true }
        return !hasWords(value)
    }

    static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
