import LumenCore
import LumenReader
import LumenThemes
import SwiftUI

// Плеер чтения вслух в «Острове»: на Mac и iPad остров в читалке становится плеером,
// на других экранах у острова кружок с обложкой; на iPhone плеер внизу, в читалке вместо её нижней панели.

/// Обложка звучащей книги: своё фото или нарисованная обложка её цветами.
struct ReadAloudCover: View {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 4

    @Environment(\.lumenTheme) private var theme
    private var readAloud: ReadAloud { .shared }

    var body: some View {
        Group {
            if let source = readAloud.source, let cover = source.shownCover, let attachments = readAloud.attachments {
                AttachmentImage(name: cover, attachments: attachments, contentMode: .fill)
            } else {
                let card = theme.vividCard(Int(readAloud.sourceId?.uuid.1 ?? 0))
                LinearGradient(colors: card.colors, startPoint: .top, endPoint: .bottom)
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: width * 0.4))
                            .foregroundStyle(card.foreground.opacity(0.7))
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

enum ReadAloudFormat {
    /// «12:40»
    static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// «18 мин», «1 ч 5 мин», «меньше минуты»
    static func minutes(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "меньше минуты" }
        if minutes < 60 { return "\(minutes) мин" }
        return minutes % 60 == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(minutes % 60) мин"
    }

    static func rate(_ rate: Double) -> String {
        let value = (rate * 100).rounded() / 100
        return (value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)) + "×"
    }
}

/// Тонкая полоска: сколько главы прозвучало.
struct ReadAloudProgress: View {
    var fraction: Double
    var tint: Color?

    @Environment(\.lumenTheme) private var theme

    var body: some View {
        Capsule()
            .fill(theme.line)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint ?? theme.textPrimary)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .animation(LumenMotion.standard, value: fraction)
    }
}

/// Остров в читалке, пока книга звучит: «Разделы» | обложка, глава, полоска |
/// фраза назад · пауза · фраза вперёд | скорость, голос | «В заметки», таймер, стоп.
struct ReadAloudBar: View {
    var onRooms: () -> Void

    @Environment(\.lumenTheme) private var theme
    @State private var isPanelPresented = false
    private var readAloud: ReadAloud { .shared }

    #if os(macOS)
    static let height: CGFloat = 62
    #else
    static let height: CGFloat = 64
    #endif

    var body: some View {
        HStack(spacing: 6) {
            labelButton("Разделы", "square.grid.2x2", help: "Вернуть разделы, книга звучит дальше", action: onRooms)
            divider
            ReadAloudCover(width: 30, height: 42, radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(readAloud.chapterTitle.isEmpty ? readAloud.bookTitle : readAloud.chapterTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .monospacedDigit()
                ReadAloudProgress(fraction: readAloud.chapterFraction)
                    .padding(.top, 3)
            }
            .frame(width: 190, alignment: .leading)
            .padding(.trailing, 4)
            iconButton("backward.end.fill", "Фраза назад") { readAloud.previous() }
            playButton
            iconButton("forward.end.fill", "Фраза вперёд") { readAloud.next() }
            chip(ReadAloudFormat.rate(readAloud.rate), isOn: isPanelPresented)
            chip(readAloud.voiceName, systemImage: "chevron.down", isOn: isPanelPresented)
                .popover(isPresented: $isPanelPresented, arrowEdge: .top) {
                    ReadAloudPanel()
                        .keyHintHost()
                }
            divider
            labelButton("В заметки", "quote.opening", help: "Звучащую фразу в заметки выпиской") {
                Task { await readAloud.excerptCurrent() }
            }
            labelButton(readAloud.sleepTimer == .off ? "Таймер" : timerTitle, "moon", isOn: readAloud.sleepTimer != .off, help: "Таймер сна") {
                isPanelPresented = true
            }
            labelButton("Стоп", "xmark", help: "Остановить чтение вслух") { readAloud.stop() }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .lumenGlass(Capsule())
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.top, BubbleMetrics.lift)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Чтение вслух")
        .accessibilityIdentifier("readAloud.bar")
    }

    private var status: String {
        if readAloud.isPreparing { return "Готовлю главу…" }
        return "\(ReadAloudFormat.clock(readAloud.elapsed)) · до конца главы \(ReadAloudFormat.minutes(readAloud.remaining))"
    }

    private var timerTitle: String {
        if readAloud.sleepTimer == .chapterEnd { return "Глава" }
        guard let deadline = readAloud.sleepDeadline else { return "Таймер" }
        return ReadAloudFormat.minutes(deadline.timeIntervalSinceNow)
    }

    private var divider: some View {
        Capsule().fill(theme.line).frame(width: 1, height: 26).padding(.horizontal, 4)
    }

    private var playButton: some View {
        Button {
            readAloud.togglePause()
        } label: {
            Image(systemName: readAloud.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.onInk)
                .frame(width: 42, height: 42)
                .background(theme.ink, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .help(readAloud.isPaused ? "Продолжить" : "Пауза")
        .accessibilityLabel(readAloud.isPaused ? "Продолжить" : "Пауза")
        .keyHint(readAloud.isPaused ? "Продолжить" : "Пауза") { readAloud.togglePause() }
    }

    private func iconButton(_ systemImage: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .help(title)
        .accessibilityLabel(title)
        .keyHint(title, perform: action)
    }

    private func chip(_ title: String, systemImage: String? = nil, isOn: Bool) -> some View {
        Button {
            isPanelPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isOn ? theme.accent : theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(isOn ? theme.accentSoft : theme.surface2, in: Capsule())
        }
        .help("Голос, скорость и таймер сна")
        .keyHint(title) { isPanelPresented.toggle() }
    }

    private func labelButton(_ title: String, _ systemImage: String, isOn: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 16))
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(isOn ? theme.accent : theme.textSecondary)
            .frame(minWidth: 54)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(title)
        .keyHint(title, perform: action)
    }
}

/// Кружок звучащей книги справа у острова: кольцо — сколько главы прозвучало, значок — пауза.
/// Нажатие возвращает в книгу (и остров снова становится плеером).
struct ReadAloudRing: View {
    var onOpen: () -> Void

    @Environment(\.lumenTheme) private var theme
    private var readAloud: ReadAloud { .shared }

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Circle().stroke(theme.line, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: readAloud.chapterFraction)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ReadAloudCover(width: 38, height: 38, radius: 19)
            }
            .frame(width: 46, height: 46)
            .padding(8)
            .lumenGlass(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            // Пауза прямо на кружке, не открывая книгу.
            Button {
                readAloud.togglePause()
            } label: {
                Image(systemName: readAloud.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.onInk)
                    .frame(width: 20, height: 20)
                    .background(theme.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: -2, y: -2)
            .accessibilityLabel(readAloud.isPaused ? "Продолжить" : "Пауза")
        }
        .help("\(readAloud.bookTitle): вернуться в книгу")
        .accessibilityLabel("Звучит «\(readAloud.bookTitle)». Открыть книгу")
        .accessibilityIdentifier("readAloud.ring")
        .keyHint("Книга звучит", perform: onOpen)
    }
}

/// Голос, скорость и таймер сна: панель над чипами плеера.
struct ReadAloudPanel: View {
    @Environment(\.lumenTheme) private var theme
    @State private var neuralError: String?
    @State private var isLoadingVoices = false
    private var readAloud: ReadAloud { .shared }

    var body: some View {
        @Bindable var model = ReadAloud.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if readAloud.availableEngines.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(readAloud.availableEngines, id: \.self) { engine in
                            choice(engine.title, isOn: readAloud.engine == engine) {
                                readAloud.engine = engine
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                switch readAloud.engine {
                case .elevenLabs where readAloud.hasNeuralKey: neuralVoices
                case .lumen where readAloud.lumenServer != nil: lumenVoices
                default: appleVoices
                }

                HStack {
                    label("Скорость")
                    Spacer()
                    Text(ReadAloudFormat.rate(readAloud.rate))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                .padding(.top, 12)
                Slider(value: $model.rate, in: readAloud.rates, step: 0.05)
                    .tint(theme.accent)
                HStack(spacing: 6) {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                        choice(ReadAloudFormat.rate(value), isOn: abs(readAloud.rate - value) < 0.01) {
                            readAloud.rate = value
                        }
                    }
                }

                label("Таймер сна").padding(.top, 12)
                FlowChips(spacing: 6) {
                    ForEach(ReadAloud.SleepTimer.choices, id: \.self) { timer in
                        choice(timer.title, isOn: readAloud.sleepTimer == timer) {
                            readAloud.setSleepTimer(timer)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 340)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var appleVoices: some View {
        label("Голос Apple · бесплатно, без интернета")
        ForEach(voices) { voice in
            voiceRow(voice.name, "\(voice.quality.title) · \(voice.languageTitle)", isOn: voice.id == selectedVoiceId) {
                readAloud.voiceId = voice.id
            }
        }
        hint(downloadHint)
    }

    @ViewBuilder
    private var neuralVoices: some View {
        label("ElevenLabs · по вашему ключу, нужен интернет")
        if readAloud.fallbackToApple {
            hint("ElevenLabs не ответил, глава звучит голосом Apple. Выберите голос, чтобы попробовать снова.")
        }
        if readAloud.neuralVoices.isEmpty {
            if isLoadingVoices {
                ProgressView().controlSize(.small).padding(8)
            } else if let neuralError {
                hint(neuralError)
            }
        }
        ForEach(readAloud.neuralVoices) { voice in
            voiceRow(voice.name, voice.shownDetails, isOn: voice.id == readAloud.elevenVoiceId) {
                readAloud.chooseNeuralVoice(voice)
            }
        }
        hint("Скорость нейроголоса до 2×. Уже прочитанное хранится на устройстве и второй раз знаков не тратит.")
            .task { await loadVoices() }
    }

    @ViewBuilder
    private var lumenVoices: some View {
        label("Голос Lumen · с вашего компьютера")
        if readAloud.fallbackToApple {
            hint("Компьютер с голосом не ответил, глава звучит голосом Apple. Выберите голос, чтобы попробовать снова.")
        } else if !LumenVoiceServer.supports(readAloud.language) {
            hint("Этот язык голос Lumen пока не читает, книгу читает голос Apple.")
        }
        if readAloud.lumenVoices.isEmpty {
            if isLoadingVoices {
                ProgressView().controlSize(.small).padding(8)
            } else if let neuralError {
                hint(neuralError)
            }
            if let name = readAloud.lumenVoiceName {
                voiceRow(name, "", isOn: true) {}
            }
        }
        ForEach(readAloud.lumenVoices) { voice in
            voiceRow(voice.name, "", isOn: voice.id == readAloud.lumenVoiceId) {
                readAloud.chooseLumenVoice(voice)
            }
        }
        hint("Скорость до 2×. Компьютер должен быть включён, а на этом устройстве включён Tailscale.")
            .task { await loadLumenVoices() }
    }

    private func loadLumenVoices() async {
        guard readAloud.lumenVoices.isEmpty, !isLoadingVoices else { return }
        isLoadingVoices = true
        defer { isLoadingVoices = false }
        do {
            try await readAloud.loadLumenVoices()
            neuralError = nil
        } catch {
            neuralError = "Не удалось загрузить голоса: \(error.localizedDescription)"
        }
    }

    private func loadVoices() async {
        guard readAloud.neuralVoices.isEmpty, !isLoadingVoices else { return }
        isLoadingVoices = true
        defer { isLoadingVoices = false }
        do {
            try await readAloud.loadNeuralVoices()
            neuralError = nil
        } catch {
            neuralError = "Не удалось загрузить голоса: \(error.localizedDescription)"
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Голоса языка книги, лучшие сверху. Если язык не узнали, русские и английские.
    private var voices: [SpeechVoiceInfo] {
        let language = readAloud.language ?? "ru"
        let list = SpeechVoices.voices(for: language)
        return list.isEmpty ? SpeechVoices.voices(for: "ru") + SpeechVoices.voices(for: "en") : list
    }

    private var selectedVoiceId: String? {
        readAloud.voiceId ?? readAloud.language.flatMap { SpeechVoices.best(for: $0)?.id }
    }

    private var downloadHint: String {
        #if os(macOS)
        "Голоса лучше скачиваются в Системных настройках → Универсальный доступ → Устный контент → Системный голос → Управлять голосами."
        #else
        "Голоса лучше скачиваются в Настройках → Универсальный доступ → Устный контент → Голоса."
        #endif
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textTertiary)
    }

    private func voiceRow(_ name: String, _ details: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .opacity(isOn ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    if !details.isEmpty {
                        Text(details)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isOn ? theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func choice(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isOn ? theme.accent : theme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(isOn ? theme.accentSoft : theme.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Настройки → «Озвучка книг».
struct ReadAloudSettingsSection: View {
    @Setting(ReadAloud.highlightKey) private var highlights = true
    @Setting(ReadAloud.followKey) private var follows = true
    @Environment(\.lumenTheme) private var theme

    var body: some View {
        Section {
            Picker("Голос по умолчанию", selection: voiceBinding) {
                Text("Лучший для языка книги").tag(String?.none)
                ForEach(SpeechVoices.voices(for: "ru") + SpeechVoices.voices(for: "en")) { voice in
                    Text("\(voice.name) · \(voice.quality.title.lowercased())").tag(Optional(voice.id))
                }
            }
            Picker("Скорость", selection: rateBinding) {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3], id: \.self) { value in
                    Text(ReadAloudFormat.rate(value)).tag(value)
                }
            }
            Toggle("Подсвечивать читаемое", isOn: $highlights)
            Toggle("Листать книгу за голосом", isOn: $follows)
        } header: {
            Text("Озвучка книг")
        } footer: {
            Text("В читалке кнопка с наушниками читает книгу вслух с места на экране. Голоса Apple работают без интернета и бесплатно.")
        }
    }

    private var voiceBinding: Binding<String?> {
        Binding(get: { ReadAloud.shared.voiceId }, set: { ReadAloud.shared.voiceId = $0 })
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { (ReadAloud.shared.rate * 4).rounded() / 4 },
            set: { ReadAloud.shared.rate = $0 }
        )
    }
}

/// iPhone: плеер внизу, пока книга звучит. В читалке это и есть режим аудио: та же книга
/// с подсвеченной фразой, а вместо нижней панели плеер; нажатие на название открывает голос,
/// скорость и таймер прямо над ним. Второго экрана с текстом нет: в читалке текст уже перед глазами.
/// На других экранах плеер с обложкой, и нажатие открывает звучащую книгу (`onOpen`).
struct PhoneMiniPlayer: View {
    /// Открыть звучащую книгу. `nil` в самой читалке.
    var onOpen: (() -> Void)?

    @Environment(\.lumenTheme) private var theme
    @State private var isPanelPresented = false
    private var readAloud: ReadAloud { .shared }

    static let height: CGFloat = 62

    private var isInReader: Bool { onOpen == nil }

    var body: some View {
        HStack(spacing: 10) {
            // В читалке книга и так на экране, обложка только заняла бы место.
            if !isInReader {
                ReadAloudCover(width: 30, height: 42, radius: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(readAloud.chapterTitle.isEmpty ? readAloud.bookTitle : readAloud.chapterTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if isInReader {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                HStack(spacing: 4) {
                    if readAloud.sleepTimer != .off {
                        Image(systemName: "moon.fill").font(.system(size: 9))
                    }
                    Text(status).lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                ReadAloudProgress(fraction: readAloud.chapterFraction)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            iconButton("backward.end.fill", "Фраза назад") { readAloud.previous() }
            Button {
                readAloud.togglePause()
            } label: {
                Image(systemName: readAloud.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.onInk)
                    .frame(width: 42, height: 42)
                    .background(theme.ink, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(readAloud.isPaused ? "Продолжить" : "Пауза")
            if isInReader {
                iconButton("forward.end.fill", "Фраза вперёд") { readAloud.next() }
            }
            iconButton("quote.opening", "Фразу в заметки") {
                Task { await readAloud.excerptCurrent() }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, isInReader ? 16 : 10)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .lumenGlass(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            if let onOpen {
                onOpen()
            } else {
                isPanelPresented = true
            }
        }
        .popover(isPresented: $isPanelPresented, arrowEdge: .bottom) {
            ReadAloudPanel()
                .presentationCompactAdaptation(.popover)
                .keyHintHost()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isInReader ? "Голос, скорость и таймер" : "Открыть книгу") {
            if let onOpen { onOpen() } else { isPanelPresented = true }
        }
        .accessibilityIdentifier("readAloud.mini")
    }

    private var status: String {
        if readAloud.isPreparing { return "Готовлю главу…" }
        var parts = [readAloud.voiceName]
        if abs(readAloud.rate - 1) > 0.01 { parts.append(ReadAloudFormat.rate(readAloud.rate)) }
        parts.append("ещё \(ReadAloudFormat.minutes(readAloud.remaining))")
        return parts.joined(separator: " · ")
    }

    private func iconButton(_ systemImage: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}
