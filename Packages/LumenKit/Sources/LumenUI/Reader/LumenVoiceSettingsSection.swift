import LumenReader
import LumenThemes
import SwiftUI

/// Настройки → «Голос Lumen с вашего компьютера»: адрес и ключ своего сервера голоса
/// (окно `6-server.bat` на компьютере), проверка, голос, «Послушать» и «Читать голосом Lumen».
struct LumenVoiceSettingsSection: View {
    @Environment(\.lumenTheme) private var theme
    @State private var linkText = ""
    @State private var keyText = ""
    @State private var status: String?
    @State private var isWorking = false
    @State private var isConfirmingDelete = false
    private var readAloud: ReadAloud { .shared }

    var body: some View {
        Section {
            if let server = readAloud.lumenServer {
                LabeledContent("Компьютер") {
                    Text(server.url.host() ?? server.url.absoluteString)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Toggle("Читать голосом Lumen", isOn: engineBinding)
                Picker("Голос", selection: voiceBinding) {
                    if readAloud.lumenVoices.isEmpty {
                        Text(readAloud.lumenVoiceName ?? "Голос \(readAloud.lumenVoiceId.uppercased())").tag(readAloud.lumenVoiceId)
                    }
                    ForEach(readAloud.lumenVoices) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
                HStack(spacing: 10) {
                    Button("Послушать") { run { try await readAloud.playLumenSample() } }
                    Button("Проверить связь") {
                        run {
                            try await readAloud.loadLumenVoices()
                            status = "Компьютер на связи, голосов: \(readAloud.lumenVoices.count)."
                        }
                    }
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Отключить", role: .destructive) { isConfirmingDelete = true }
                }
                .buttonStyle(.borderless)
            } else {
                TextField("Ссылка из окна сервера", text: $linkText, prompt: Text("https://lumen-pc….ts.net/#key=…"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(connect)
                SecureField("Ключ, если его нет в ссылке", text: $keyText)
                    .onSubmit(connect)
                HStack(spacing: 10) {
                    Button("Подключить", action: connect)
                        .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    if isWorking { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.borderless)
            }
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Голос Lumen с вашего компьютера")
        } footer: {
            Text(footer)
        }
        .task(id: readAloud.lumenServer) {
            guard readAloud.lumenServer != nil, readAloud.lumenVoices.isEmpty else { return }
            try? await readAloud.loadLumenVoices()
        }
        .confirmationDialog("Отключить голос Lumen на этом устройстве?", isPresented: $isConfirmingDelete) {
            Button("Отключить", role: .destructive) {
                readAloud.deleteLumenServer()
                status = nil
            }
        } message: {
            Text("Книги снова будет читать голос Apple. Сервер на компьютере не изменится.")
        }
    }

    private var footer: String {
        if readAloud.lumenServer != nil {
            return "Голос озвучивает ваш компьютер, поэтому он должен быть включён, окно «Голос Lumen» открыто, а на этом устройстве включён Tailscale. Уже прочитанное хранится на устройстве. Книги на языках, которых голос не знает, читает голос Apple."
        }
        return "Запустите на компьютере 6-server.bat из набора «Голос Lumen» и вставьте сюда ссылку из его окна, она уже с ключом. На этом устройстве должен быть включён Tailscale с тем же аккаунтом. Ключ хранится только на этом устройстве, в Связке ключей."
    }

    private var engineBinding: Binding<Bool> {
        Binding(
            get: { readAloud.engine == .lumen },
            set: { readAloud.engine = $0 ? .lumen : .apple }
        )
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: { readAloud.lumenVoiceId },
            set: { id in
                if let voice = readAloud.lumenVoices.first(where: { $0.id == id }) { readAloud.chooseLumenVoice(voice) }
            }
        )
    }

    private func connect() {
        let link = linkText
        let key = keyText
        run {
            let voices = try await readAloud.saveLumenServer(link: link, key: key)
            linkText = ""
            keyText = ""
            readAloud.engine = .lumen
            if let voices {
                status = "Подключено. Голосов на компьютере: \(voices.count)."
            } else {
                status = "Сохранено, но компьютер сейчас не ответил. Голос заработает, когда сервер будет запущен."
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                status = "Не получилось: \(error.localizedDescription)"
            }
        }
    }
}
