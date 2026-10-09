import SwiftUI
import LexiaCore

enum KeyboardPage: Hashable {
    case letters, numbers, symbols
}

enum ShiftState {
    case off, on, capsLock
}

enum KeyKind: Hashable {
    case character(String)
    case shift
    case backspace
    case space
    case returnKey
    case page(KeyboardPage, label: String)
    case globe
}

struct KeySpec: Hashable {
    let kind: KeyKind
    /// Width in letter-key units; nil fills the remaining space.
    let units: CGFloat?

    static func char(_ s: String) -> KeySpec { KeySpec(kind: .character(s), units: 1) }
}

enum KeyboardLayout {
    static func rows(for page: KeyboardPage, showsGlobe: Bool) -> [[KeySpec]] {
        let chars: (String) -> [KeySpec] = { $0.map { KeySpec.char(String($0)) } }
        var bottom: [KeySpec] = [
            KeySpec(kind: page == .letters ? .page(.numbers, label: "123") : .page(.letters, label: "ABC"), units: 1.3),
        ]
        if showsGlobe { bottom.append(KeySpec(kind: .globe, units: 1.3)) }
        bottom.append(KeySpec(kind: .space, units: nil))
        bottom.append(KeySpec(kind: .returnKey, units: 2.2))

        let punctuation = chars(".,?!'").map { KeySpec(kind: $0.kind, units: 1.4) }
        switch page {
        case .letters:
            return [
                chars("qwertyuiop"),
                chars("asdfghjkl"),
                [KeySpec(kind: .shift, units: 1.4)] + chars("zxcvbnm") + [KeySpec(kind: .backspace, units: 1.4)],
                bottom,
            ]
        case .numbers:
            return [
                chars("1234567890"),
                chars("-/:;()$&@\""),
                [KeySpec(kind: .page(.symbols, label: "#+="), units: 1.4)] + punctuation
                    + [KeySpec(kind: .backspace, units: 1.4)],
                bottom,
            ]
        case .symbols:
            return [
                chars("[]{}#%^*+="),
                chars("_\\|~<>€£¥•"),
                [KeySpec(kind: .page(.numbers, label: "123"), units: 1.4)] + punctuation
                    + [KeySpec(kind: .backspace, units: 1.4)],
                bottom,
            ]
        }
    }
}

/// Everything the SwiftUI keyboard renders, owned by `KeyboardViewController`.
@MainActor
final class KeyboardState: ObservableObject {
    @Published var settings = LexiaSettings()
    @Published var page: KeyboardPage = .letters
    @Published var shift: ShiftState = .on
    @Published var suggestions: [Suggestion] = []
    @Published var reviewFix: Suggestion?
    @Published var notice: String?
    @Published var showsGlobe = true
    @Published var returnLabel = "return"
    @Published var jevWorking = false
    /// A tone-check result (or status) shown in place of the suggestions.
    @Published var toneVerdict: String? {
        didSet { if toneVerdict == nil { toneAdditions = [] } }
    }
    /// Friendly endings Jev suggested with the tone verdict ("Thanks!").
    @Published var toneAdditions: [String] = []

    var currentSet: SuggestionSet?
    weak var inputController: UIInputViewController?

    /// Where the last letter key was touched, relative to its centre (in key sizes).
    var lastTouch: CGPoint?

    var onKey: (KeyKind) -> Void = { _ in }
    var onSuggestion: (Suggestion) -> Void = { _ in }
    var onSpeak: (Suggestion) -> Void = { _ in }
    var onReadBack: () -> Void = {}
    var onToneCheck: () -> Void = {}
    var onToneAddition: (String) -> Void = { _ in }

    var theme: Theme { Theme.make(settings.tint) }

    /// What a letter key shows: lowercase by default (matching what you read),
    /// uppercase while shift is on so its state is obvious.
    func label(for character: String) -> String {
        switch shift {
        case .on, .capsLock: return character.uppercased()
        case .off: return settings.lowercaseKeys ? character.lowercased() : character.uppercased()
        }
    }
}
