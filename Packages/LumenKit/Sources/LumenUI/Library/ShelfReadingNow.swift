import GRDB
import LumenCore
import LumenStorage
import LumenThemes
import SwiftUI

/// «Читаю сейчас» над полками: обложка книги, которую читаешь, сколько прочитано и осталось,
/// «Продолжить» и «С заметками рядом», последняя выдержка и заметки к книге. Ниже другие начатые книги.
/// Пока ни одну книгу не начали, блока нет.
struct ShelfReadingNow: View {
    let database: AppDatabase
    var onOpenSource: (UUID) -> Void

    @State private var snapshot = ShelfReadingSnapshot.empty
    /// Широкое окно: выдержка и заметки справа от книги, а не под ней.
    @State private var isWide = true
    /// Узкое окно (iPhone): рядом с обложкой только название, цифры и кнопки идут под ней во всю ширину.
    @State private var isCompact = false
    @Environment(\.appActions) private var appActions
    @Environment(\.lumenTheme) private var theme

    var body: some View {
        Group {
            if let book = snapshot.current {
                VStack(alignment: .leading, spacing: 12) {
                    card(book)
                    if !snapshot.others.isEmpty {
                        others
                    }
                }
                .transition(.opacity)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 820 } action: { isWide = $0 }
        .onGeometryChange(for: Bool.self) { $0.size.width < 560 } action: { isCompact = $0 }
        .task { await observe() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Читаю сейчас")
        .accessibilityIdentifier("shelf-reading-now")
    }

    // MARK: - Книга

    private func card(_ book: Source) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 26))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
        return layout {
            if isCompact {
                compactDetails(book)
            } else {
                HStack(alignment: .top, spacing: isWide ? 26 : 16) {
                    cover(book)
                    details(book)
                }
            }
            if isWide {
                Rectangle()
                    .fill(theme.contrast.opacity(0.1))
                    .frame(width: 1)
                    .padding(.vertical, 6)
            }
            side(book)
                .frame(width: isWide ? 300 : nil)
                .frame(maxWidth: isWide ? nil : .infinity, alignment: .leading)
        }
        .padding(isWide ? 24 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Свет от книги: тёплая полоса цвета темы слева, как обложка за листом.
            LinearGradient(
                colors: [theme.glow.opacity(0.28), theme.glow2.opacity(0.1), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .clipShape(shape)
        .lumenGlass(shape)
    }

    private func cover(_ book: Source) -> some View {
        Button {
            onOpenSource(book.id)
        } label: {
            SourceCoverArt(
                source: book,
                attachments: database.attachments,
                width: isWide ? 130 : isCompact ? 84 : 96,
                height: isWide ? 190 : isCompact ? 122 : 140
            )
                .shadow(color: .black.opacity(theme.shadowOpacity * 1.2), radius: 16, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Открыть «\(book.displayTitle)»")
    }

    private func details(_ book: Source) -> some View {
        let forecast = ReadingForecast(progress: book.progress, sessions: snapshot.sessions)
        return VStack(alignment: .leading, spacing: 8) {
            Text(place)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(theme.accent)
            Text(book.displayTitle)
                .font(.system(size: isWide ? 28 : 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: isWide ? 26 : 16) {
                stat(ReadingText.percent(book.progress), "прочитано")
                if let remaining = forecast.remainingSeconds, remaining > 0 {
                    stat(SourceDashboardView.remainingValue(forecast), "осталось")
                }
                if let date = forecast.finishDate, forecast.remainingSeconds != 0 {
                    stat(ReadingText.day(date), "дочитаю")
                }
            }
            .padding(.top, 4)
            ReadingProgressBar(progress: book.progress)
                .frame(maxWidth: 360)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons(book) }
                VStack(alignment: .leading, spacing: 8) { buttons(book) }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// iPhone: обложка и название рядом, а цифры, полоса и кнопки под ними во всю ширину карточки,
    /// иначе в узкой колонке справа от обложки всё обрезается, а кнопки сжимаются в высокие пилюли.
    private func compactDetails(_ book: Source) -> some View {
        let forecast = ReadingForecast(progress: book.progress, sessions: snapshot.sessions)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                cover(book)
                VStack(alignment: .leading, spacing: 6) {
                    Text(place)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(theme.accent)
                        .lineLimit(2)
                    Text(book.displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let author = book.author, !author.isEmpty {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 12) {
                stat(ReadingText.percent(book.progress), "прочитано", fill: true)
                if let remaining = forecast.remainingSeconds, remaining > 0 {
                    stat(SourceDashboardView.remainingValue(forecast), "осталось", fill: true)
                }
                if let date = forecast.finishDate, forecast.remainingSeconds != 0 {
                    stat(ReadingText.day(date), "дочитаю", fill: true)
                }
            }
            ReadingProgressBar(progress: book.progress)
            HStack(spacing: 10) { buttons(book, fill: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «Читаю · полка «Классика»».
    private var place: String {
        guard let shelf = snapshot.shelfName else { return "Читаю сейчас" }
        return "Читаю · полка «\(shelf)»"
    }

    /// `fill`: цифры делят ширину поровну и, если не влезают, чуть уменьшаются, а не обрезаются.
    private func stat(_ value: String, _ caption: String, fill: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(fill ? 0.7 : 1)
            Text(caption)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
    }

    /// `fill`: две кнопки поровну на всю ширину (iPhone), иначе по размеру надписи.
    @ViewBuilder
    private func buttons(_ book: Source, fill: Bool = false) -> some View {
        Button {
            onOpenSource(book.id)
        } label: {
            Label("Продолжить", systemImage: "book")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, fill ? 10 : 16)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: fill ? 44 : 36)
                .background(theme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fill, vertical: true)
        .keyHint("Продолжить чтение") { onOpenSource(book.id) }
        .accessibilityIdentifier("shelf-continue")

        Button {
            openWithNotes(book)
        } label: {
            Label(fill ? "С заметками" : "С заметками рядом", systemImage: "rectangle.split.2x1")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, fill ? 10 : 16)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: fill ? 44 : 36)
                .lumenGlass(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fill, vertical: true)
        .help("Открыть книгу, а рядом заметки к ней")
        .keyHint("С заметками рядом") { openWithNotes(book) }
    }

    /// Книга открывается с панелью заметок: читалка помнит этот выбор сама.
    private func openWithNotes(_ book: Source) {
        UserDefaults.standard.set(true, forKey: ReaderView.notesOpenKey)
        onOpenSource(book.id)
    }

    // MARK: - Выдержка и заметки

    private func side(_ book: Source) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let highlight = snapshot.lastHighlight {
                label("Последняя выдержка")
                Button {
                    appActions.open(.source(book.id, highlight: highlight.id))
                } label: {
                    Text("«\(highlight.text.trimmingCharacters(in: .whitespacesAndNewlines))»")
                        .font(.system(size: 15, design: .serif).italic())
                        .lineSpacing(3)
                        .foregroundStyle(theme.textPrimary.opacity(0.88))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Открыть книгу на этом месте")
                .keyHint("Последняя выдержка") { appActions.open(.source(book.id, highlight: highlight.id)) }
            }
            if snapshot.noteCount > 0 {
                label("Заметки к книге · \(snapshot.noteCount)")
                    .padding(.top, snapshot.lastHighlight == nil ? 0 : 6)
                ForEach(snapshot.notes) { page in
                    Button {
                        appActions.open(.page(page.id))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundStyle(theme.accent)
                            Text(page.displayTitle)
                                .font(.subheadline)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ReadingText.day(page.updatedAt))
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyHint(page.displayTitle) { appActions.open(.page(page.id)) }
                }
            }
            if snapshot.lastHighlight == nil, snapshot.noteCount == 0 {
                label("Выдержки и заметки")
                Text("Выделите строку в книге и нажмите «В заметки»: выдержка ляжет в заметку со ссылкой на место в книге.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(theme.textSecondary)
    }

    // MARK: - Тоже читаю

    private var others: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                label("Тоже читаю")
                    .padding(.trailing, 4)
                ForEach(snapshot.others) { book in
                    Button {
                        onOpenSource(book.id)
                    } label: {
                        HStack(spacing: 10) {
                            SourceCoverArt(source: book, attachments: database.attachments, width: 22, height: 32)
                            Text(book.displayTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text(ReadingText.percent(book.progress))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(.leading, 6)
                        .padding(.trailing, 14)
                        .padding(.vertical, 5)
                        .lumenGlass(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyHint(book.displayTitle) { onOpenSource(book.id) }
                }
            }
            .padding(.vertical, 2)
        }
        .keyHintClip()
    }

    private func observe() async {
        let observation = ValueObservation.tracking { db in try ShelfReadingSnapshot.fetch(db) }
            .removeDuplicates()
        do {
            for try await value in observation.values(in: database.reader) where value != snapshot {
                withAnimation(LumenMotion.standard) { snapshot = value }
            }
        } catch {
            lumenLog.error("Reading now observation failed: \(String(describing: error), privacy: .public)")
        }
    }
}
