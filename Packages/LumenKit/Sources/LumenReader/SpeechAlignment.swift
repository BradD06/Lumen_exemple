import AVFoundation
import Foundation

/// Время слов по самому звуку, когда ElevenLabs его не прислал (фраза в кеше с тех пор,
/// как подсветки слов ещё не было, или модель не отдаёт время). Тишина в начале и в конце
/// отбрасывается, паузы в речи привязываются к знакам препинания, а между ними слова идут по
/// длине. Знаков ElevenLabs это не тратит: считается на устройстве по уже скачанному mp3.
public enum SpeechAlignment {
    /// Шаг громкости, секунд.
    static let step = 0.01
    /// Пауза короче этого — просто стык слов.
    static let minimumPause = 0.12
    static let breakMarks: Set<Character> = [",", ".", ";", ":", "!", "?", "—", "–", "…", "(", ")", "«", "»", "\""]

    /// Слова фразы по mp3 на диске; `nil`, если звук не прочитался.
    public static func words(in text: String, audio file: URL) -> [SpeechWord]? {
        guard let levels = levels(of: file), !levels.isEmpty else { return nil }
        let words = words(in: text, levels: levels, step: step)
        return words.isEmpty ? nil : words
    }

    /// Громкость звука по 10 мс (среднеквадратичная, первый канал).
    static func levels(of file: URL) -> [Float]? {
        guard let audio = try? AVAudioFile(forReading: file) else { return nil }
        let format = audio.processingFormat
        let window = max(AVAudioFrameCount(format.sampleRate * step), 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window * 100) else { return nil }
        var levels: [Float] = []
        while audio.framePosition < audio.length {
            do { try audio.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            var index = 0
            let count = Int(buffer.frameLength)
            while index < count {
                let end = min(index + Int(window), count)
                var sum: Float = 0
                for i in index..<end { sum += samples[i] * samples[i] }
                levels.append((sum / Float(end - index)).squareRoot())
                index = end
            }
        }
        return levels
    }

    /// Слова по громкости звука. Чистая функция: её проверяют тесты.
    static func words(in text: String, levels: [Float], step: Double) -> [SpeechWord] {
        let ranges = SpeechTiming.wordRanges(in: text)
        guard !ranges.isEmpty, let loudest = levels.max(), loudest > 0 else { return [] }
        let threshold = loudest * 0.1
        guard let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold }), last > first else { return [] }
        let speechStart = Double(first) * step
        let speechEnd = Double(last + 1) * step

        // Паузы внутри речи.
        var pauses: [(start: Double, end: Double)] = []
        var quietFrom: Int?
        for index in first...last {
            if levels[index] < threshold {
                if quietFrom == nil { quietFrom = index }
            } else if let from = quietFrom {
                if Double(index - from) * step >= minimumPause {
                    pauses.append((Double(from) * step, Double(index) * step))
                }
                quietFrom = nil
            }
        }

        // Места между словами, где стоит знак препинания: там голос делает паузу.
        let units = Array(text.utf16)
        var breaks: [(before: Int, after: Int)] = []
        for (current, next) in zip(ranges, ranges.dropFirst()) {
            let gapStart = current.location + current.length
            let gap = String(decoding: units[gapStart..<next.location], as: UTF16.self)
            if gap.contains(where: { breakMarks.contains($0) }) { breaks.append((gapStart, next.location)) }
        }

        // Пауза → ближайший по ожидаемому месту знак, по порядку.
        let total = Double(units.count)
        let pausing = pauses.reduce(0) { $0 + $1.end - $1.start }
        let speaking = max(speechEnd - speechStart - pausing, step)
        var anchors: [(position: Double, time: Double)] = [(0, speechStart)]
        var pausedBefore = 0.0
        var nextBreak = 0
        for pause in pauses {
            let expected = (pause.start - speechStart - pausedBefore) / speaking * total
            pausedBefore += pause.end - pause.start
            let candidates = breaks.indices.dropFirst(nextBreak)
            guard let best = candidates.min(by: { abs(Double(breaks[$0].before) - expected) < abs(Double(breaks[$1].before) - expected) }),
                  abs(Double(breaks[best].before) - expected) <= max(12, total * 0.2) else { continue }
            anchors.append((Double(breaks[best].before), pause.start))
            anchors.append((Double(breaks[best].after), pause.end))
            nextBreak = best + 1
        }
        anchors.append((total, speechEnd))

        return ranges.map { range in
            SpeechWord(location: range.location, length: range.length, time: time(at: Double(range.location), anchors))
        }
    }

    /// Время для места в тексте: прямая между соседними опорами.
    private static func time(at position: Double, _ anchors: [(position: Double, time: Double)]) -> Double {
        guard let upper = anchors.firstIndex(where: { $0.position > position }), upper > 0 else {
            return anchors.last?.time ?? 0
        }
        let a = anchors[upper - 1]
        let b = anchors[upper]
        let share = b.position > a.position ? (position - a.position) / (b.position - a.position) : 0
        return a.time + (b.time - a.time) * share
    }
}
