import CryptoKit
import Foundation
import Security

/// Голос со своего сервера «Голос Lumen»: домашний компьютер с видеокартой озвучивает фразы
/// (Qwen3-TTS, клон выбранного голоса), а приложение просит их по сети (Tailscale, https).
/// Сервер отдаёт фразу mp3 (или wav), время слов считается по самому звуку (`SpeechAlignment`).
public struct LumenVoiceInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Адрес и ключ сервера голоса.
public struct LumenVoiceServer: Hashable, Sendable {
    public var url: URL
    public var key: String

    /// Языки, которые голос читает (Qwen3-TTS). Остальные книги читает голос Apple.
    public static let languages: Set<String> = ["ru", "en", "de", "fr", "es", "it", "pt", "zh", "ja", "ko"]

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

    /// Язык книги по силам голосу; неизвестный язык считается русским.
    public static func supports(_ language: String?) -> Bool {
        guard let code = language?.prefix(2).lowercased(), code.count == 2 else { return true }
        return languages.contains(code)
    }

    /// Адрес из того, что вставили: «lumen-pc.xxx.ts.net», «https://…/» или ссылка с ключом
    /// «https://…/#key=…» (её показывает окно сервера). `nil`, если адреса не видно.
    public static func parse(_ text: String) -> (url: URL, key: String?)? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        let key = parts.fragment.flatMap { fragment in
            URLComponents(string: "?" + fragment)?.queryItems?.first { $0.name == "key" }?.value
        }
        parts.fragment = nil
        parts.query = nil
        parts.path = ""
        guard let url = parts.url else { return nil }
        return (url, key?.isEmpty == false ? key : nil)
    }

    public func voices() async throws -> [LumenVoiceInfo] {
        let data = try await send(request(path: "/v1/voices"))
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let list = object["voices"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return LumenVoiceInfo(id: id, name: name)
        }
    }

    /// Звук одной фразы. Долгая первая фраза: сервер может ещё прогреваться.
    public func speech(text: String, voice: String, language: String?) async throws -> Data {
        var request = request(path: "/v1/speak")
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text, "voice": voice]
        if let language = language?.prefix(2), language.count == 2 { body["language"] = language.lowercased() }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data = try await send(request)
        guard !data.isEmpty else { throw NeuralVoiceError.server(0, "нет звука в ответе") }
        return data
    }

    /// Имя файла в кеше: от сервера, голоса, языка и текста.
    public func cacheKey(text: String, voice: String, language: String?) -> String {
        let code = language?.prefix(2).lowercased() ?? ""
        let digest = SHA256.hash(data: Data("lumen|\(url.host() ?? "")|\(voice)|\(code)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func request(path: String) -> URLRequest {
        var request = URLRequest(url: url.appending(path: path))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet ? NeuralVoiceError.offline : NeuralVoiceError.serverUnreachable
        } catch {
            throw NeuralVoiceError.wrap(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.parseError(status: status, data: data) }
        return data
    }

    static func parseError(status: Int, data: Data) -> NeuralVoiceError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = object?["error"] as? String ?? ""
        switch status {
        case 401, 403: return .badKey
        case 502, 503, 504: return .voiceStarting
        default: return .server(status, message)
        }
    }
}

/// Сервер голоса в настройках: адрес в UserDefaults, ключ в Связке ключей.
public enum LumenVoiceStore {
    public static let urlKey = "readAloud.lumenServer"
    static let service = "io.github.bradd06.lumen.voice"
    static let account = "lumen-server"

    public static func load() -> LumenVoiceServer? {
        guard let text = UserDefaults.standard.string(forKey: urlKey), let url = URL(string: text),
              let key = loadKey() else { return nil }
        return LumenVoiceServer(url: url, key: key)
    }

    public static func save(_ server: LumenVoiceServer) throws {
        try saveKey(server.key)
        UserDefaults.standard.set(server.url.absoluteString, forKey: urlKey)
    }

    public static func delete() {
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: urlKey)
    }

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func loadKey() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    private static func saveKey(_ key: String) throws {
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        item[kSecAttrLabel as String] = "Lumen: ключ сервера голоса"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NeuralVoiceError.keychain(status) }
    }
}
