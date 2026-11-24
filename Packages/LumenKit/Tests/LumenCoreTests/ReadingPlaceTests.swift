import Foundation
import Testing
@testable import LumenCore

struct ReadingPlaceTests {
    @Test func nearbyLineOnAnotherScreenIsSamePlace() {
        // Mac открыл место iPhone: вверху начало строки чуть раньше.
        let phone = SourceLocator(section: 70, progression: 1, textOffset: 2137)
        let mac = SourceLocator(section: 70, progression: 0.99, textOffset: 1877)
        #expect(ReadingPlace.isSame(phone, mac))
    }

    @Test func readOnIsNewPlace() {
        let opened = SourceLocator(section: 70, progression: 0.2, textOffset: 400)
        let later = SourceLocator(section: 70, progression: 0.5, textOffset: 1200)
        #expect(!ReadingPlace.isSame(opened, later))
    }

    @Test func otherChapterIsNewPlace() {
        let end = SourceLocator(section: 70, progression: 1, textOffset: 2137)
        let next = SourceLocator(section: 71, progression: 0, textOffset: 0)
        #expect(!ReadingPlace.isSame(end, next))
    }

    @Test func pdfPointComparesOnlyHeight() {
        let a = SourceLocator(section: 4, point: LocatorPoint(x: 0, y: 600))
        let zoomed = SourceLocator(section: 4, point: LocatorPoint(x: 120, y: 560))
        let lower = SourceLocator(section: 4, point: LocatorPoint(x: 0, y: 300))
        #expect(ReadingPlace.isSame(a, zoomed))
        #expect(!ReadingPlace.isSame(a, lower))
        #expect(!ReadingPlace.isSame(a, SourceLocator(section: 5, point: LocatorPoint(x: 0, y: 600))))
    }

    @Test func progressionWithoutOffset() {
        #expect(ReadingPlace.isSame(SourceLocator(section: 2, progression: 0.30), SourceLocator(section: 2, progression: 0.31)))
        #expect(!ReadingPlace.isSame(SourceLocator(section: 2, progression: 0.30), SourceLocator(section: 2, progression: 0.40)))
    }
}
