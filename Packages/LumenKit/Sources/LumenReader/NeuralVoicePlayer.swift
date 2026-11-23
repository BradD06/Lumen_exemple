import AVFoundation
import Foundation

/// Читает части главы голосом ElevenLabs: каждая фраза приходит mp3-файлом со временем слов
/// (или из кеша) и играет через `AVAudioPlayer`, а `onWord` говорит, какое слово звучит.
/// Пока звучит фраза, следующие две скачиваются по очереди (бесплатный тариф не любит много
/// запросов сразу), поэтому между фразами нет пауз. Свой сервер «Голос Lumen» готовит несколько
/// частей сразу быстрее, чем по одной: ему `parallelLoads` и `lookahead` побольше.
/// Временный сбой (сеть моргнула, компьютер занят) — `onWaiting`, голос ждёт и пробует снова
/// около минуты. Не получилось и так, или сбой не временный (ключ, кончились знаки) — `onFailure`,
/// и читалка переходит на голос Apple.
@MainActor
public final class NeuralVoicePlayer: NSObject, SpeechPlaying {
    public var onPart: ((Int) -> Void)?
    public var onWord: ((Int, NSRange) -> Void)?
    public var onFinish: (() -> Void)?
    public var onFailure: ((NeuralVoiceError) -> Void)?
    /// Связь пропала или компьютер занят: голос ждёт и пробует снова, а не сразу уходит на Apple.
    public var onWaiting: ((NeuralVoiceError) -> Void)?

    public private(set) var parts: [SpeechPart] = []
    public private(set) var index = 0
    public private(set) var isPlaying = false
    public private(set) var isPaused = false

    /// Скорость меняется сразу, без новой загрузки: тот же звук играет быстрее, тон не меняется.
    public var rate: Double = 1 {
        didSet { audio?.rate = Float(Self.playbackRate(rate)) }
    }
    public var language: String?
    public var voiceId: String? {
        didSet { if voiceId != oldValue { restart() } }
    }
    public var model: NeuralVoiceModel = .multilingual {
        didSet { if model != oldValue { restart() } }
    }
    /// Ровность и выразительность: новое звучание с текущей фразы.
    public var tuning: NeuralVoiceTuning = .standard {
        didSet { if tuning != oldValue { restart() } }
    }
    /// Ключ берётся при каждой загрузке: его могли сменить в настройках.
    public var apiKey: () -> String? = { nil }
    /// Свой сервер «Голос Lumen» вместо ElevenLabs (`voiceId` тогда голос сервера).
    /// Адрес и ключ тоже берутся при каждой загрузке.
    public var lumenServer: (() -> LumenVoiceServer?)?
    /// Сколько следующих частей готовить, пока звучит эта, и все ли сразу, а не по одной.
    public var lookahead = 2
    public var parallelLoads = false
    /// Через сколько секунд пробовать снова при временном сбое, всего около минуты; потом `onFailure`.
    /// На паузе попытки не считаются: голос спрашивает реже и ждёт сколько угодно.
    var retryDelays: [Double] = [1, 2, 4, 8, 15, 30]
    /// Для тестов: озвучка текста части без сети и кеша.
    var fetch: (@Sendable (String) async throws -> NeuralAudio)?

    /// `AVAudioPlayer` ускоряет без смены тона только до 2×.
    public nonisolated static let rates: ClosedRange<Double> = 0.5...2
    static let wordLead = 0.12

    private var audio: AVAudioPlayer?
    private var audioIndex: Int?
    private var loads: [Int: Task<NeuralAudio, any Error>] = [:]
    /// Растёт при каждом переходе: опоздавшая загрузка старой фразы ничего не включит.
    private var generation = 0
    private var startTask: Task<Void, Never>?
    /// Следит за временем звучащей фразы и сообщает, какое слово звучит.
    private var wordTask: Task<Void, Never>?
    private let delegate = Delegate()
    private let silence = SilentAudio()

    public override init() {
        super.init()
        delegate.player = self
    }

    nonisolated static func playbackRate(_ rate: Double) -> Double {
        min(max(rate, rates.lowerBound), rates.upperBound)
    }

    public func play(_ parts: [SpeechPart], from index: Int) {
        // Та же глава: уже скачанные фразы пригодятся.
        halt(keepLoads: parts == self.parts)
        self.parts = parts
        guard parts.indices.contains(index) else {
            isPlaying = false
            isPaused = false
            onFinish?()
            return
        }
        isPlaying = true
        isPaused = false
        SpeechAudio.activate()
        start(index)
    }

    public func pause() {
        guard isPlaying, !isPaused else { return }
        isPaused = true
        audio?.pause()
        silence.stop()
    }

    public func resume() {
        guard isPlaying, isPaused else { return }
        isPaused = false
        if let audio {
            audio.play()
        } else {
            start(index)
        }
    }

    public func stop() {
        halt(keepLoads: false)
        isPlaying = false
        isPaused = false
    }

    public func jump(to number: Int) {
        guard isPlaying, parts.indices.contains(number) else { return }
        halt(keepLoads: true)
        if isPaused {
            index = number
            onPart?(number)
        } else {
            start(number)
        }
    }

    /// Сменили голос или модель: скачанное не годится, текущая фраза звучит заново.
    private func restart() {
        guard isPlaying else { return }
        halt(keepLoads: false)
        if !isPaused { start(index) }
    }

    private func halt(keepLoads: Bool) {
        generation += 1
        startTask?.cancel()
        startTask = nil
        wordTask?.cancel()
        wordTask = nil
        audio?.stop()
        audio = nil
        audioIndex = nil
        silence.stop()
        if !keepLoads {
            loads.values.forEach { $0.cancel() }
            loads = [:]
        }
    }

    /// Скачать (или взять из кеша) фразу `number` и сыграть её.
    private func start(_ number: Int, delay: Double = 0) {
        generation += 1
        let current = generation
        index = number
        audio?.stop()
        audio = nil
        audioIndex = nil
        wordTask?.cancel()
        startTask?.cancel()
        startTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.generation == current else { return }
            // Пока часть озвучивается, звучит тишина: в фоне iOS не усыпит приложение посреди запроса.
            if !self.isPaused { self.silence.start() }
            do {
                let sound = try await self.loadWaiting(number, generation: current)
                guard self.generation == current, self.isPlaying else { return }
                self.silence.stop()
                let player = try AVAudioPlayer(data: sound.data)
                player.enableRate = true
                player.rate = Float(Self.playbackRate(self.rate))
                player.delegate = self.delegate
                player.prepareToPlay()
                self.audio = player
                self.audioIndex = number
                if !self.isPaused { player.play() }
                self.onPart?(number)
                self.followWords(of: player, part: number, words: sound.words
                    ?? SpeechTiming.estimated(in: self.parts[number].spoken, duration: player.duration))
                self.prefetch(after: number, generation: current)
            } catch {
                guard self.generation == current, !(error is CancellationError) else { return }
                self.fail(.wrap(error))
            }
        }
    }

    /// Пока фраза звучит, раз в 50 мс смотрит время и сообщает новое слово.
    private func followWords(of player: AVAudioPlayer, part number: Int, words: [SpeechWord]) {
        wordTask?.cancel()
        guard !words.isEmpty else { return }
        let id = ObjectIdentifier(player)
        wordTask = Task { [weak self] in
            var shown: Int?
            while !Task.isCancelled {
                guard let self, let audio = self.audio, ObjectIdentifier(audio) == id else { return }
                // Чуть наперёд: пока подсветка дойдёт до страницы, голос уже начнёт слово.
                if let word = SpeechTiming.index(at: audio.currentTime + Self.wordLead, in: words), word != shown {
                    shown = word
                    self.onWord?(number, words[word].range)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Звук части уже есть или готовится: переход к ней не ждёт новой озвучки.
    public func hasAudio(for number: Int) -> Bool {
        guard parts.indices.contains(number) else { return false }
        if loads[number] != nil || audioIndex == number { return true }
        guard let voiceId, let server = lumenServer?() else { return false }
        return NeuralVoiceCache.has(text: parts[number].spoken, voice: voiceId, language: language, server: server)
    }

    /// Загрузка части. Временный сбой (сеть моргнула, компьютер занят, модель перезапускается):
    /// ждём и пробуем снова, пока эта часть всё ещё нужна.
    private func loadWaiting(_ number: Int, generation current: Int) async throws -> NeuralAudio {
        var attempt = 0
        while true {
            do {
                return try await load(number)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled, generation == current,
                      NeuralVoiceError.wrap(error).isTemporary, attempt < retryDelays.count else { throw error }
                if attempt == 0 { onWaiting?(NeuralVoiceError.wrap(error)) }
                try await Task.sleep(for: .seconds(retryDelays[isPaused ? retryDelays.count - 1 : attempt]))
                guard generation == current, isPlaying else { throw CancellationError() }
                if !isPaused { attempt += 1 }
            }
        }
    }

    private func load(_ number: Int) async throws -> NeuralAudio {
        if let task = loads[number] {
            let text = parts[number].spoken
            do {
                return try await task.value
            } catch {
                // Заготовленная загрузка не удалась (сеть моргнула, компьютер был занят):
                // ещё одна попытка, если эта часть всё ещё нужна.
                if loads[number] == task { loads[number] = nil }
                guard !(error is CancellationError), !Task.isCancelled,
                      parts.indices.contains(number), parts[number].spoken == text else { throw error }
            }
        }
        let task = try makeLoad(number)
        loads[number] = task
        do {
            return try await task.value
        } catch {
            if loads[number] == task { loads[number] = nil }
            throw error
        }
    }

    private func makeLoad(_ number: Int) throws -> Task<NeuralAudio, any Error> {
        guard let voiceId else { throw NeuralVoiceError.noVoice }
        let text = parts[number].spoken
        if let fetch { return Task { try await fetch(text) } }
        if let lumenServer {
            guard let server = lumenServer() else { throw NeuralVoiceError.noKey }
            let language = language
            return Task { try await NeuralVoiceCache.audio(text: text, voice: voiceId, language: language, server: server) }
        }
        guard let key = apiKey(), !key.isEmpty else { throw NeuralVoiceError.noKey }
        let speech = NeuralSpeechRequest(
            text: text,
            voiceId: voiceId,
            model: model,
            tuning: tuning,
            language: language,
            previous: number > 0 ? parts[number - 1].spoken : nil,
            next: number + 1 < parts.count ? parts[number + 1].spoken : nil
        )
        return Task { try await NeuralVoiceCache.audio(for: speech, key: key) }
    }

    /// Следующие фразы скачиваются по одной (или все сразу, `parallelLoads`), пока звучит эта;
    /// дальние загрузки отменяются.
    private func prefetch(after number: Int, generation current: Int) {
        let ahead = max(lookahead, 1)
        for key in Array(loads.keys) where key < number || key > number + ahead {
            loads[key]?.cancel()
            loads[key] = nil
        }
        if parallelLoads {
            for next in (number + 1)...(number + ahead) where next < parts.count && loads[next] == nil {
                if let task = try? makeLoad(next) { loads[next] = task }
            }
            return
        }
        Task { [weak self] in
            for next in (number + 1)...(number + ahead) {
                guard let self, self.generation == current, next < self.parts.count else { return }
                _ = try? await self.load(next)
            }
        }
    }

    private func fail(_ error: NeuralVoiceError) {
        halt(keepLoads: false)
        isPlaying = false
        isPaused = false
        onFailure?(error)
    }

    fileprivate func finished(_ id: ObjectIdentifier) {
        guard let audio, ObjectIdentifier(audio) == id, let number = audioIndex else { return }
        wordTask?.cancel()
        wordTask = nil
        self.audio = nil
        audioIndex = nil
        if number + 1 >= parts.count {
            isPlaying = false
            isPaused = false
            onFinish?()
            NeuralVoiceCache.trim()
            return
        }
        // После заголовка пауза побольше, между фразами чуть-чуть, как у чтеца.
        start(number + 1, delay: parts[number].isHeading ? 0.45 : 0.06)
    }

    /// Делегат отдельно: его методы приходят не на главном потоке.
    private final class Delegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        @MainActor weak var player: NeuralVoicePlayer?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            let id = ObjectIdentifier(player)
            Task { @MainActor in self.player?.finished(id) }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            let id = ObjectIdentifier(player)
            Task { @MainActor in self.player?.finished(id) }
        }
    }
}

/// Тишина, пока следующая часть ещё озвучивается. В фоне iOS держит приложение, только пока
/// оно что-то играет: без звука на заблокированном экране Lumen усыпили бы посреди запроса
/// к компьютеру, голос замолк бы, а потом перешёл на Apple.
@MainActor
final class SilentAudio {
    private var player: AVAudioPlayer?

    func start() {
        #if os(iOS)
        if player == nil {
            player = try? AVAudioPlayer(data: Self.wav)
            player?.numberOfLoops = -1
        }
        if player?.isPlaying == false { player?.play() }
        #endif
    }

    func stop() {
        player?.pause()
    }

    /// Секунда тишины в WAV: 8 кГц, 16 бит, моно.
    nonisolated static let wav: Data = {
        let rate: UInt32 = 8000
        let bytes = rate * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + bytes); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        text("data"); u32(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }()
}

/// «Послушать» в настройках: одна фраза выбранным голосом.
@MainActor
public final class NeuralVoiceSample {
    public static let text = "Это голос для ваших книг в Lumen. Послушайте ударения: звонит, договор, красивее, торты, километр."

    private var player: AVAudioPlayer?

    public init() {}

    public func play(voiceId: String, model: NeuralVoiceModel, tuning: NeuralVoiceTuning, key: String) async throws {
        let speech = NeuralSpeechRequest(text: Self.text, voiceId: voiceId, model: model, tuning: tuning, language: "ru")
        let sound = try await NeuralVoiceCache.audio(for: speech, key: key)
        try play(sound)
    }

    /// Та же фраза голосом своего сервера.
    public func play(voice: String, server: LumenVoiceServer) async throws {
        let sound = try await NeuralVoiceCache.audio(text: Self.text, voice: voice, language: "ru", server: server)
        try play(sound)
    }

    private func play(_ sound: NeuralAudio) throws {
        player?.stop()
        SpeechAudio.activate()
        player = try AVAudioPlayer(data: sound.data)
        player?.play()
    }

    public func stop() {
        player?.stop()
        player = nil
    }
}
