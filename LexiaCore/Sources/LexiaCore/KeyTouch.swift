import Foundation

/// Where a letter key was touched, as offsets from the key's centre
/// (x in key widths, y in key heights; about −0.5…0.5 inside the key).
public struct KeyTouch: Sendable, Hashable {
    public let letter: Character
    public let dx: Double
    public let dy: Double

    public init(letter: Character, dx: Double, dy: Double) {
        self.letter = Character(letter.lowercased())
        self.dx = dx
        self.dy = dy
    }
}
