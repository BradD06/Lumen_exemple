import Foundation
import Testing
@testable import LumenReader

struct SpeechTimingTests {
    @Test func wordsAreLettersAndDigitsWithSoftHyphens() {
        let ranges = SpeechTiming.wordRanges(in: "Кто-то, 12 при\u{00AD}мер!")
        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 2),
            NSRange(location: 8, length: 2),
            NSRange(location: 11, length: 7),
        ])
    }

    @Test func wordAtTimeIsTheLastStartedOne() {
        let words = [
            SpeechWord(location: 0, length: 2, time: 0),
            SpeechWord(location: 3, length: 4, time: 0.4),
            SpeechWord(location: 8, length: 3, time: 1.1),
        ]
        #expect(SpeechTiming.index(at: 0, in: words) == 0)
        #expect(SpeechTiming.index(at: 0.39, in: words) == 0)
        #expect(SpeechTiming.index(at: 0.4, in: words) == 1)
        #expect(SpeechTiming.index(at: 5, in: words) == 2)
        #expect(SpeechTiming.index(at: 1, in: []) == nil)
    }

    /// Без времени от сервиса слова идут равномерно по длительности.
    @Test func estimatedWordsSpreadOverTheDuration() {
        let words = SpeechTiming.estimated(in: "раз два", duration: 2)
        #expect(words.map(\.time) == [0, 2.0 * 4 / 7])
    }

    /// Сказанный текст без сноски и мягкого переноса, а подсвечивается слово на своём месте в главе.
    @Test func spokenWordsFindTheirPlaceInTheChapter() {
        let raw = "Слово[12] при\u{00AD}мер  тут"
        let part = SpeechPart(spoken: SpeechText.clean(raw), raw: raw, start: 100, length: raw.utf16.count)
        #expect(part.spoken == "Слово пример тут")
        let places = SpeechTiming.places(of: part)
        #expect(places.map(\.chapter) == [
            NSRange(location: 100, length: 5),
            NSRange(location: 110, length: 7),
            NSRange(location: 119, length: 3),
        ])
        // «пример» в сказанном тексте: 6…12.
        #expect(SpeechTiming.chapterRange(of: NSRange(location: 6, length: 6), in: places) == NSRange(location: 110, length: 7))
        // Голос Apple может взять «пример тут» одним куском.
        #expect(SpeechTiming.chapterRange(of: NSRange(location: 6, length: 10), in: places) == NSRange(location: 110, length: 12))
        #expect(SpeechTiming.chapterRange(of: NSRange(location: 5, length: 1), in: places) == nil)
    }
}
