import Foundation

/// Место чтения на разных устройствах. Одна книга открывается на iPhone и на Mac с одного
/// места, но экраны разной ширины: вверху оказывается начало другой строки, у PDF другая точка
/// страницы. Такое «почти то же место» не считается новым местом и не записывается, иначе
/// запись со свежим временем перебила бы место, до которого дочитали на другом устройстве.
public enum ReadingPlace {
    /// Сколько символов главы вверх и вниз от места ещё считается тем же местом:
    /// пара строк узкого экрана iPhone с крупным шрифтом.
    public static let textSlack = 400
    /// Сколько точек страницы PDF вверх и вниз считается тем же местом.
    public static let pointSlack = 80.0

    /// То же место, только на другом экране. Разные главы (страницы PDF) это всегда разные места.
    public static func isSame(_ a: SourceLocator, _ b: SourceLocator) -> Bool {
        guard a.section == b.section else { return false }
        if let x = a.textOffset, let y = b.textOffset {
            return abs(x - y) <= textSlack
        }
        if let x = a.point, let y = b.point {
            // Сбоку точка зависит от масштаба, важно только, какая строка страницы вверху.
            return abs(x.y - y.y) <= pointSlack
        }
        if a.point != nil || b.point != nil {
            return true
        }
        return abs(a.progression - b.progression) < 0.02
    }
}
