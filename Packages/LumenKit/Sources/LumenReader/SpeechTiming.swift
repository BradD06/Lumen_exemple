import Foundation

/// Слово сказанной фразы: где оно в тексте, который получил голос (UTF-16), и с какой секунды звучит.
public struct SpeechWord: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public var time: Double

    public init(location: Int, length: Int, time: Double) {
        self.location = location
        self.length = length
        self.time = time
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// Слово фразы и его место в главе: по нему подсвечивается звучащее слово.
public struct SpeechWordPlace: Hashable, Sendable {
    /// В сказанном тексте (`SpeechPart.spoken`), UTF-16.
    public var spoken: NSRange
    /// В главе, как `SpeechPart.start`.
    public var chapter: NSRange
}

/// Слова внутри фразы: подсветка идёт за голосом по словам, а не стоит на всей фразе.
public enum SpeechTiming {
    /// Слова текста (буквы и цифры подряд) в UTF-16. Мягкий перенос считается частью слова.
    public static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var offset = 0
        var start: Int?
        for scalar in text.unicodeScalars {
            let inWord = scalar == "\u{00AD}" || CharacterSet.alphanumerics.contains(scalar)
            if inWord, start == nil { start = offset }
            if !inWord, let first = start {
                ranges.append(NSRange(location: first, length: offset - first))
                start = nil
            }
            offset += scalar.utf16.count
        }
        if let first = start { ranges.append(NSRange(location: first, length: offset - first)) }
        return ranges
    }

    /// Слова с временем из ответа ElevenLabs: буквы текста и секунда начала каждой.
    /// Если буквы не сошлись с текстом по длине, место слова пересчитывается пропорционально.
    public static func words(in text: String, characters: [String], starts: [Double]) -> [SpeechWord] {
        var times: [Double] = []
        for (character, start) in zip(characters, starts) {
            times.append(contentsOf: repeatElement(start, count: character.utf16.count))
        }
        guard !times.isEmpty else { return [] }
        let total = max(text.utf16.count, 1)
        return wordRanges(in: text).map { range in
            let index = times.count == total ? range.location : range.location * times.count / total
            return SpeechWord(location: range.location, length: range.length, time: times[min(max(index, 0), times.count - 1)])
        }
    }

    /// Времени нет (звук из старого кеша): слова идут равномерно по длительности фразы.
    public static func estimated(in text: String, duration: Double) -> [SpeechWord] {
        let total = Double(max(text.utf16.count, 1))
        return wordRanges(in: text).map {
            SpeechWord(location: $0.location, length: $0.length, time: duration * Double($0.location) / total)
        }
    }

    /// Номер слова, которое звучит на секунде `time`: последнее из начавшихся.
    public static func index(at time: Double, in words: [SpeechWord]) -> Int? {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : (words.isEmpty ? nil : 0)
    }

    /// Слова фразы и их места в главе. Сказанный текст — это кусок главы без сносок, мягких
    /// переносов и лишних пробелов, поэтому слова сопоставляются по порядку, пропуская лишние
    /// (номер сноски) в главе.
    public static func places(of part: SpeechPart) -> [SpeechWordPlace] {
        let spoken = part.spoken as NSString
        let raw = part.raw as NSString
        let rawWords = wordRanges(in: part.raw)
        var places: [SpeechWordPlace] = []
        var next = 0
        for word in wordRanges(in: part.spoken) {
            let wanted = normalized(spoken.substring(with: word))
            let window = next..<min(next + 6, rawWords.count)
            guard let found = window.first(where: { normalized(raw.substring(with: rawWords[$0])) == wanted }) else { continue }
            let place = rawWords[found]
            places.append(SpeechWordPlace(spoken: word, chapter: NSRange(location: part.start + place.location, length: place.length)))
            next = found + 1
        }
        return places
    }

    /// Место в главе для куска сказанного текста (голос Apple даёт свои границы слов):
    /// от первого задетого слова до последнего.
    public static func chapterRange(of spoken: NSRange, in places: [SpeechWordPlace]) -> NSRange? {
        let end = spoken.location + max(spoken.length, 1)
        let touched = places.filter { $0.spoken.location < end && $0.spoken.location + $0.spoken.length > spoken.location }
        guard let first = touched.first, let last = touched.last else { return nil }
        let start = first.chapter.location
        return NSRange(location: start, length: last.chapter.location + last.chapter.length - start)
    }

    private static func normalized(_ word: String) -> String {
        word.replacingOccurrences(of: "\u{00AD}", with: "").lowercased()
    }
}
