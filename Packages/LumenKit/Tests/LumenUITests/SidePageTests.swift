import Foundation
import Testing
import LumenCore
import LumenStorage
@testable import LumenUI

@MainActor
struct SidePageTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @Test func anyPageOpensBesideTheBookAndTakesExcerpts() async throws {
        let folder = try await db.createFolder(name: "Курс")
        let source = try await db.addSource(
            title: "Книга", format: .epub, file: "missing.epub", originalName: "Книга.epub", folderId: folder.id
        )
        let other = try await db.createPage(title: "Конспект", folderId: folder.id)
        let model = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await model.load()
        #expect(model.showsBookNotes)

        await model.openSidePage(other.id)
        #expect(model.notes?.pageId == other.id)
        #expect(!model.showsBookNotes)

        let highlight = Highlight(
            sourceId: source.id, locator: SourceLocator(section: 0, progression: 0), text: "Цитата", label: "гл. 1"
        )
        await model.addExcerpt(highlight)
        await model.flush()
        let excerpts = try await db.blocks(of: other.id).filter { $0.type == .excerpt }
        #expect(excerpts.map(\.text) == ["Цитата"])

        // Книга запоминает, какая заметка была открыта рядом.
        let reopened = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await reopened.load()
        #expect(reopened.notes?.pageId == other.id)

        await reopened.openBookNotes()
        #expect(reopened.showsBookNotes)
    }

    @Test func excerptsGoToTheNoteOpenInTheOtherHalfOfTheScreen() async throws {
        let source = try await db.addSource(
            title: "Книга", format: .epub, file: "missing.epub", originalName: "Книга.epub"
        )
        let beside = try await db.createPage(title: "Рядом")
        let editor = PageEditorModel(database: db, pageId: beside.id)
        await editor.load()
        OpenPageEditors.shared.register(editor, id: editor.pageId)
        defer { OpenPageEditors.shared.unregister(editor, id: editor.pageId) }

        let model = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await model.load()
        model.besidePageId = beside.id
        let highlight = Highlight(
            sourceId: source.id, locator: SourceLocator(section: 0, progression: 0), text: "Цитата", label: "гл. 1"
        )
        await model.addExcerpt(highlight)
        await editor.flush()

        // Выписка сразу в открытом редакторе и в базе, а заметки к книге не заводятся.
        #expect(editor.blocks.filter { $0.type == .excerpt }.map(\.text) == ["Цитата"])
        let saved = try await db.blocks(of: beside.id).filter { $0.type == .excerpt }
        #expect(saved.map(\.text) == ["Цитата"])
        #expect(model.notes == nil)
        #expect(try await db.bookNotesPage(for: source.id) == nil)

        // Рядом закрыли заметку: выписки снова идут в заметки к книге.
        model.besidePageId = nil
        await model.addExcerpt(highlight)
        await model.flush()
        let notes = try #require(try await db.bookNotesPage(for: source.id))
        #expect(try await db.blocks(of: notes.id).filter { $0.type == .excerpt }.count == 1)
    }

    @Test func bookNotesAreCreatedOnlyWhenTheEditorOpens() async throws {
        let folder = try await db.createFolder(name: "Курс")
        let source = try await db.addSource(
            title: "Книга", format: .epub, file: "missing.epub", originalName: "Книга.epub",
            folderId: folder.id, position: LibraryPoint(x: 200, y: 100)
        )
        let model = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await model.load()
        #expect(model.notes == nil)
        #expect(try await db.bookNotesPage(for: source.id) == nil, "Книгу открыли, но заметку ещё не начинали")

        let notes = try #require(await model.ensureNotes())
        let page = try #require(try await db.page(notes.pageId))
        #expect(page.sourceId == source.id)
        #expect(page.folderId == folder.id)
        #expect(page.position == LibraryPoint(x: 200 + LibraryLayout.cellWidth, y: 100))
        #expect(model.showsBookNotes)
        #expect(await model.ensureNotes()?.pageId == notes.pageId, "Вторая заметка не заводится")

        // В следующий раз книга сразу открывает уже заведённую заметку.
        let reopened = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await reopened.load()
        #expect(reopened.notes?.pageId == notes.pageId)
    }

    @Test func firstExcerptStartsTheBookNotes() async throws {
        let source = try await db.addSource(
            title: "Книга", format: .epub, file: "missing.epub", originalName: "Книга.epub"
        )
        let model = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await model.load()
        let highlight = Highlight(
            sourceId: source.id, locator: SourceLocator(section: 0, progression: 0), text: "Цитата", label: "гл. 1"
        )
        await model.addExcerpt(highlight)
        await model.flush()

        let page = try #require(try await db.bookNotesPage(for: source.id))
        #expect(page.folderId == nil, "Книга лежит в корне, и заметка тоже")
        let excerpts = try await db.blocks(of: page.id).filter { $0.type == .excerpt }
        #expect(excerpts.map(\.text) == ["Цитата"])
    }

    @Test func newSidePageGoesIntoTheBooksFolder() async throws {
        let folder = try await db.createFolder(name: "Курс")
        let source = try await db.addSource(
            title: "Книга", format: .epub, file: "missing.epub", originalName: "Книга.epub", folderId: folder.id
        )
        let model = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await model.load()

        await model.createSidePage()

        let pageId = try #require(model.notes?.pageId)
        let page = try #require(try await db.page(pageId))
        #expect(page.folderId == folder.id)
        #expect(page.sourceId == nil)
    }

    @Test func readingTimeSplitsAtLongPauses() async throws {
        let source = try await db.addSource(
            title: "Книга", format: .epub, file: "missing.epub", originalName: "Книга.epub"
        )
        let model = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await model.load()
        let start = Date().addingTimeInterval(60)
        model.noteActivity(at: start)
        model.noteActivity(at: start.addingTimeInterval(120))
        let first = try #require(model.readingSession)
        #expect(first.seconds >= 180 && first.seconds < 200)

        // Долгий перерыв не засчитывается: с нового действия идёт новый отрезок.
        let back = start.addingTimeInterval(120 + ReaderModel.idleLimit + 60)
        model.noteActivity(at: back)
        model.noteActivity(at: back.addingTimeInterval(30))
        let second = try #require(model.readingSession)
        #expect(second.id != first.id)
        #expect(second.startedAt == back)
        #expect(abs(second.seconds - 30) < 0.01)
        // Время между началом и концом отрезка и есть время чтения.
        #expect(abs(second.endedAt.timeIntervalSince(second.startedAt) - second.seconds) < 0.01)

        try await db.saveReadingSession(first)
        try await db.saveReadingSession(second)
        let total = try await db.readingStats(of: source.id).totalSeconds
        #expect(abs(total - (first.seconds + second.seconds)) < 0.01)
    }

    @Test func sessionLineShowsTwoDigitMinutesAndPauses() {
        let start = Calendar.current.date(bySettingHour: 11, minute: 0, second: 10, of: Date())!
        let short = ReadingSession(sourceId: UUID(), startedAt: start, endedAt: start.addingTimeInterval(110), seconds: 110)
        #expect(ReadingText.session(short) == "11:00–11:02 · 2 мин")
        // Старый отрезок: 44 минуты между началом и концом, читали из них 8.
        let old = ReadingSession(sourceId: UUID(), startedAt: start, endedAt: start.addingTimeInterval(44 * 60), seconds: 8 * 60)
        #expect(ReadingText.session(old) == "11:00–11:44 · 8 мин, с перерывами")
    }
}
