import AVFoundation
import Foundation
import Testing
@testable import LumenReader

/// Сбои связи у нейроголоса: короткий обрыв не переводит книгу на голос Apple.
@MainActor
struct NeuralVoicePlayerTests {
    /// Сервер, который первые `failures` раз отвечает ошибкой.
    actor FlakyServer {
        let failures: Int
        let error: NeuralVoiceError
        private(set) var calls = 0

        init(failures: Int, error: NeuralVoiceError = .serverUnreachable) {
            self.failures = failures
            self.error = error
        }

        func speak(_ text: String) throws -> NeuralAudio {
            calls += 1
            if calls <= failures { throw error }
            return NeuralAudio(data: SilentAudio.wav, words: nil)
        }
    }

    /// Что сообщил плеер.
    final class Events {
        var started: [Int] = []
        var waited: [NeuralVoiceError] = []
        var failed: NeuralVoiceError?
        var loading: [Bool] = []
    }

    private func makePlayer(for server: FlakyServer, delays: [Double] = [0.01, 0.01, 0.01]) -> (NeuralVoicePlayer, Events) {
        let player = NeuralVoicePlayer()
        let events = Events()
        player.voiceId = "a"
        player.retryDelays = delays
        player.fetch = { text in try await server.speak(text) }
        player.onPart = { events.started.append($0) }
        player.onWaiting = { events.waited.append($0) }
        player.onFailure = { events.failed = $0 }
        player.onLoading = { events.loading.append($0) }
        return (player, events)
    }

    private let part = [SpeechPart(spoken: "Арагорн поднял меч.", start: 0, length: 19)]

    private func waitFor(_ events: Events) async {
        for _ in 0..<300 where events.started.isEmpty && events.failed == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func shortOutageWaitsAndKeepsTheVoice() async {
        let server = FlakyServer(failures: 2)
        let (player, events) = makePlayer(for: server)
        player.play(part, from: 0)
        await waitFor(events)
        #expect(events.started == [0])
        #expect(events.failed == nil)
        #expect(events.waited == [.serverUnreachable])
        #expect(await server.calls == 3)
        player.stop()
    }

    @Test func loadingIsReportedUntilTheSoundStarts() async {
        let server = FlakyServer(failures: 1)
        let (player, events) = makePlayer(for: server)
        player.play(part, from: 0)
        await waitFor(events)
        // Пока ждали звук (и повторяли после сбоя) — «готовится», звук пошёл — нет.
        #expect(events.loading == [true, false])
        player.stop()
        #expect(events.loading == [true, false])
    }

    @Test func stoppingWhileLoadingEndsTheLoading() async {
        let server = FlakyServer(failures: 100)
        let (player, events) = makePlayer(for: server, delays: [5])
        player.play(part, from: 0)
        for _ in 0..<100 where events.loading.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        player.stop()
        #expect(events.loading == [true, false])
    }

    @Test func wrongKeyFailsAtOnce() async {
        let server = FlakyServer(failures: 5, error: .badKey)
        let (player, events) = makePlayer(for: server)
        player.play(part, from: 0)
        await waitFor(events)
        #expect(events.failed == .badKey)
        #expect(events.waited.isEmpty)
        #expect(await server.calls == 1)
    }

    @Test func longOutageGivesUpAfterTheRetries() async {
        let server = FlakyServer(failures: 100, error: .voiceStarting)
        let (player, events) = makePlayer(for: server, delays: [0.01, 0.01])
        player.play(part, from: 0)
        await waitFor(events)
        #expect(events.failed == .voiceStarting)
        #expect(events.waited == [.voiceStarting])
        #expect(await server.calls == 3)
        #expect(!player.isPlaying)
    }

    @Test func onlyPassingProblemsAreWaitedOut() {
        for error in [NeuralVoiceError.offline, .serverUnreachable, .voiceStarting, .busy] {
            #expect(error.isTemporary)
        }
        for error in [NeuralVoiceError.badKey, .noKey, .quotaExceeded, .paidPlanRequired, .server(500, "")] {
            #expect(!error.isTemporary)
        }
    }

    @Test func silenceIsOneSecondOfValidSound() throws {
        let sound = try AVAudioPlayer(data: SilentAudio.wav)
        #expect(abs(sound.duration - 1) < 0.01)
    }
}
