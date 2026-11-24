import Foundation
import Testing
import LumenCore
import LumenStorage
@testable import LumenUI

@MainActor
struct ReadingPlaceSyncTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @Test func placeFromAnotherDeviceReachesTheOpeningBook() async throws {
        let source = try await db.addSource(
            title: "Книга", format: .epub, file: "missing.epub", originalName: "Книга.epub", folderId: nil
        )
        try await db.saveReadingPosition(source.id, locator: SourceLocator(section: 70, progression: 1, textOffset: 2137), progress: 0.84)
        let model = ReaderModel(database: db, sourceId: source.id, highlightId: nil)
        await model.load()
        #expect(model.section == 70)

        // Синхронизация принесла место с iPhone, пока книга ещё не открылась.
        try await db.saveReadingPosition(source.id, locator: SourceLocator(section: 71, progression: 0, textOffset: 0), progress: 0.85)
        for _ in 0..<50 where model.section != 71 {
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(model.section == 71)

        // Книга так и не открылась (файла нет): своё старое место она не записывает.
        await model.flush()
        let stored = try #require(try await db.source(source.id))
        #expect(stored.locator?.section == 71)
    }
}
