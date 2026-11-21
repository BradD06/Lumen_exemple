import Foundation
import Testing
@testable import LumenReader

struct SpeechAlignmentTests {
    private func levels(_ pieces: [(seconds: Double, loud: Bool)]) -> [Float] {
        pieces.flatMap { Array(repeating: $0.loud ? Float(0.5) : 0, count: Int(($0.seconds * 100).rounded())) }
    }

    /// Тишина в начале не сдвигает слова, а пауза на запятой ставит следующее слово на конец паузы.
    @Test func pauseLandsOnTheComma() {
        let sound = levels([(0.2, false), (0.5, true), (0.3, false), (0.6, true), (0.2, false)])
        let words = SpeechAlignment.words(in: "Раз, два три.", levels: sound, step: 0.01)
        #expect(words.map(\.location) == [0, 5, 9])
        let times = words.map(\.time)
        #expect(abs(times[0] - 0.2) < 0.001)
        #expect(abs(times[1] - 1.0) < 0.001)
        #expect(abs(times[2] - 1.3) < 0.001)
    }

    /// Без пауз слова идут по длине между началом и концом речи.
    @Test func withoutPausesWordsFollowTheirLength() {
        let sound = levels([(0.1, false), (1.0, true), (0.3, false)])
        let words = SpeechAlignment.words(in: "один два", levels: sound, step: 0.01)
        #expect(abs(words[0].time - 0.1) < 0.001)
        #expect(abs(words[1].time - (0.1 + 1.0 * 5 / 8)) < 0.001)
    }

    @Test func silenceGivesNoWords() {
        #expect(SpeechAlignment.words(in: "тишина", levels: [0, 0, 0], step: 0.01).isEmpty)
    }
}
