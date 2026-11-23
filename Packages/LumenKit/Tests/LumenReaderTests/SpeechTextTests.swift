import Foundation
import Testing
@testable import LumenReader

struct SpeechTextTests {
    /// Часть текста главы по месту, как её подсветит читалка.
    private func slice(_ chapter: String, _ part: SpeechPart) -> String {
        let utf16 = Array(chapter.utf16)
        return String(decoding: utf16[part.start..<part.end], as: UTF16.self)
    }

    @Test func sentencesKeepTheirPlaceInTheChapter() {
        let heading = "Глава 4"
        let text = "\n  Аграрная революция была спорной. Одни говорят «да». Другие —\n нет! "
        let chapter = heading + text
        let blocks = [
            SpeechBlock(kind: .heading, text: heading, start: 0),
            SpeechBlock(text: text, start: heading.utf16.count),
        ]
        let parts = SpeechText.parts(from: blocks)
        #expect(parts.map(\.spoken) == [
            "Глава 4",
            "Аграрная революция была спорной.",
            "Одни говорят «да».",
            "Другие — нет!",
        ])
        #expect(parts.map(\.isHeading) == [true, false, false, false])
        for part in parts {
            #expect(SpeechText.clean(slice(chapter, part)) == part.spoken)
        }
    }

    @Test func offsetsCountUTF16LikeTheReaderScript() {
        // Эмодзи занимает два символа UTF-16, как и в JavaScript.
        let text = "😀 Привет. Пока."
        let parts = SpeechText.parts(from: [SpeechBlock(text: text, start: 10)])
        #expect(parts.count == 2)
        #expect(parts[1].spoken == "Пока.")
        #expect(parts[1].start == 10 + "😀 Привет. ".utf16.count)
        #expect(parts[1].length == 5)
    }

    @Test func groupingJoinsShortSentences() {
        let text = "Раз. Два. Три. Длинно " + String(repeating: "длинно ", count: 20) + "конец."
        let parts = SpeechText.parts(from: [SpeechBlock(text: text, start: 0)], groupLength: 40)
        #expect(parts.first?.spoken == "Раз. Два. Три.")
        #expect(parts.count == 2)
    }

    /// Абзац из одинаковых по длине предложений.
    private func paragraph(_ count: Int, from first: Int = 1) -> String {
        (first..<first + count).map { "Это предложение номер \($0) в длинном абзаце." }.joined(separator: " ")
    }

    @Test func rampStartsWithOneSentenceAndGrows() {
        let text = paragraph(40)
        let parts = SpeechText.ramped(from: [SpeechBlock(text: text, start: 0)], startingAt: 0)
        #expect(parts.first?.spoken == "Это предложение номер 1 в длинном абзаце.")
        let lengths = parts.map(\.spoken.count)
        // Части только растут, но не длиннее абзаца-предела.
        for (left, right) in zip(lengths, lengths.dropFirst()) {
            #expect(left <= right)
        }
        #expect(lengths.allSatisfy { $0 <= SpeechText.paragraphLength })
        #expect(lengths.last! > 3 * lengths.first!)
        // Ничего не потеряно и не повторено.
        #expect(parts.map(\.spoken).joined(separator: " ") == text)
    }

    @Test func rampBeginsAtTheReadingPlaceAndKeepsParagraphs() throws {
        let before = paragraph(3)
        let text = paragraph(20, from: 4)
        let blocks = [
            SpeechBlock(text: before, start: 0),
            SpeechBlock(text: text, start: before.utf16.count + 1),
        ]
        let place = blocks[1].start + text.utf16.count / 2
        let parts = SpeechText.ramped(from: blocks, startingAt: place)
        // До места чтения абзацами.
        #expect(parts[0].spoken == before)
        #expect(parts[1].start == blocks[1].start)
        // С места чтения одно предложение, за ним тоже короткая часть.
        let index = try #require(SpeechText.index(of: place, in: parts))
        #expect(index == 2)
        #expect(parts[index].spoken.filter { $0 == "." }.count == 1)
        #expect(parts[index + 1].spoken.filter { $0 == "." }.count == 1)
        // Ни одна часть не захватывает два абзаца.
        #expect(parts.allSatisfy { $0.end <= blocks[1].start || $0.start >= blocks[1].start })
    }

    @Test func rampFromTheEndIsJustParagraphs() {
        let parts = SpeechText.ramped(from: [SpeechBlock(text: paragraph(40), start: 0)], startingAt: .max)
        #expect(parts.count < 5)
        #expect(parts.allSatisfy { $0.spoken.count <= SpeechText.paragraphLength })
    }

    @Test func codeIsReplacedOnceAndPageNumbersAreSkipped() {
        let blocks = [
            SpeechBlock(text: "Пример ниже.", start: 0),
            SpeechBlock(kind: .code, text: "let x = 1", start: 12),
            SpeechBlock(kind: .code, text: "print(x)", start: 22),
            SpeechBlock(text: "214", start: 30),
            SpeechBlock(text: "* * *", start: 33),
            SpeechBlock(text: "Дальше.", start: 38),
        ]
        let parts = SpeechText.parts(from: blocks)
        #expect(parts.map(\.spoken) == ["Пример ниже.", SpeechText.codeNotice, "Дальше."])
        #expect(parts[1].start == 12)
        #expect(parts[1].end == 30)
    }

    @Test func footnoteMarksAndSoftHyphensAreNotSpoken() {
        let parts = SpeechText.parts(from: [SpeechBlock(text: "Зем\u{00AD}леделие[12]   изменило   всё.", start: 0)])
        #expect(parts.map(\.spoken) == ["Земледелие изменило всё."])
    }

    @Test func longSentencesAreCutAtCommas() {
        let piece = String(repeating: "слово ", count: 40) + "и ещё, "
        let sentence = String(repeating: piece, count: 3) + "конец."
        let parts = SpeechText.parts(from: [SpeechBlock(text: sentence, start: 0)])
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.spoken.count <= SpeechText.maxPartLength })
        #expect(parts.dropLast().allSatisfy { $0.spoken.hasSuffix(",") })
        // Части идут подряд, без наложений.
        for (left, right) in zip(parts, parts.dropFirst()) {
            #expect(left.end <= right.start)
        }
    }

    @Test func indexFindsThePartAtAPlace() {
        let parts = SpeechText.parts(from: [SpeechBlock(text: "Раз. Два. Три.", start: 100)])
        #expect(parts.count == 3)
        #expect(SpeechText.index(of: 0, in: parts) == 0)
        #expect(SpeechText.index(of: 105, in: parts) == 1)
        #expect(SpeechText.index(of: 107, in: parts) == 1)
        #expect(SpeechText.index(of: 112, in: parts) == 2)
        #expect(SpeechText.index(of: 500, in: parts) == nil)
    }

    @Test func languageIsDetected() {
        let ru = SpeechText.parts(from: [SpeechBlock(text: "Аграрная революция была одним из самых спорных событий в истории человечества.", start: 0)])
        let en = SpeechText.parts(from: [SpeechBlock(text: "The agricultural revolution was one of the most controversial events in history.", start: 0)])
        #expect(SpeechText.language(of: ru) == "ru")
        #expect(SpeechText.language(of: en) == "en")
    }

    @Test func rateMultiplierMapsToSynthesizerRange() {
        #expect(SpeechVoicePlayer.utteranceRate(1) == 0.5)
        #expect(SpeechVoicePlayer.utteranceRate(0.5) == 0.25)
        #expect(SpeechVoicePlayer.utteranceRate(3) == 1)
        #expect(SpeechVoicePlayer.utteranceRate(2) > 0.7)
    }
}
