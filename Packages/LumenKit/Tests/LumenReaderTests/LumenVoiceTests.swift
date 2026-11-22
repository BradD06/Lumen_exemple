import Foundation
import Testing
@testable import LumenReader

struct LumenVoiceTests {
    @Test func linkFromServerWindowGivesAddressAndKey() throws {
        let parsed = try #require(LumenVoiceServer.parse("  https://lumen-pc.tail1234.ts.net/#key=odj4tG_mZaUjMMO6\n"))
        #expect(parsed.url.absoluteString == "https://lumen-pc.tail1234.ts.net")
        #expect(parsed.key == "odj4tG_mZaUjMMO6")
    }

    @Test func bareAddressGetsHttpsAndNoKey() throws {
        let parsed = try #require(LumenVoiceServer.parse("lumen-pc.tail1234.ts.net/v1/voices?x=1"))
        #expect(parsed.url.absoluteString == "https://lumen-pc.tail1234.ts.net")
        #expect(parsed.key == nil)
        let local = try #require(LumenVoiceServer.parse("http://127.0.0.1:8092"))
        #expect(local.url.absoluteString == "http://127.0.0.1:8092")
    }

    @Test func notAnAddressIsRejected() {
        #expect(LumenVoiceServer.parse("") == nil)
        #expect(LumenVoiceServer.parse("какой-то текст с пробелами") == nil)
        #expect(LumenVoiceServer.parse("ftp://lumen-pc") == nil)
    }

    @Test func languagesTheVoiceReads() {
        #expect(LumenVoiceServer.supports("ru"))
        #expect(LumenVoiceServer.supports("en-US"))
        #expect(LumenVoiceServer.supports(nil))
        #expect(!LumenVoiceServer.supports("uk"))
        #expect(!LumenVoiceServer.supports("pl"))
    }

    @Test func requestCarriesKeyAndCacheDependsOnVoiceAndLanguage() throws {
        let server = LumenVoiceServer(url: URL(string: "https://lumen-pc.ts.net")!, key: "k1")
        let request = server.request(path: "/v1/voices")
        #expect(request.url?.absoluteString == "https://lumen-pc.ts.net/v1/voices")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k1")

        let base = server.cacheKey(text: "Привет.", voice: "a", language: "ru")
        #expect(base == server.cacheKey(text: "Привет.", voice: "a", language: "ru-RU"))
        #expect(base != server.cacheKey(text: "Привет.", voice: "b", language: "ru"))
        #expect(base != server.cacheKey(text: "Привет.", voice: "a", language: "en"))
        #expect(base != server.cacheKey(text: "Привет!", voice: "a", language: "ru"))
    }

    @Test func serverErrorsBecomeClearMessages() {
        #expect(LumenVoiceServer.parseError(status: 401, data: Data()) == .badKey)
        #expect(LumenVoiceServer.parseError(status: 503, data: Data()) == .voiceStarting)
        let body = Data(#"{"error": "Нужен текст до 1000 знаков"}"#.utf8)
        #expect(LumenVoiceServer.parseError(status: 400, data: body) == .server(400, "Нужен текст до 1000 знаков"))
    }

    @Test func waveIsToldFromMp3() {
        #expect(NeuralVoiceCache.isWave(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8)))
        #expect(!NeuralVoiceCache.isWave(Data([0x49, 0x44, 0x33, 0x04])))
    }
}
