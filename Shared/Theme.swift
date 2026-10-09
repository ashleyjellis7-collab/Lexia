import UIKit
import SwiftUI
import CoreText

/// Registers the bundled OpenDyslexic fonts (works in the app and the keyboard extension).
enum FontRegistry {
    static let regular = "OpenDyslexic-Regular"
    static let bold = "OpenDyslexic-Bold"
    private static var registered = false

    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        for name in [regular, bold] where UIFont(name: name, size: 12) == nil {
            if let url = Bundle.main.url(forResource: name, withExtension: "otf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

extension LexiaSettings {
    func keyFont(size: CGFloat, bold: Bool = false) -> Font {
        let scaled = size * CGFloat(textScale)
        switch font {
        case .openDyslexic:
            return .custom(bold ? FontRegistry.bold : FontRegistry.regular, fixedSize: scaled * 0.9)
        case .rounded:
            return .system(size: scaled, weight: bold ? .semibold : .regular, design: .rounded)
        case .system:
            return .system(size: scaled, weight: bold ? .semibold : .regular)
        }
    }
}

/// Keyboard colours. "Standard" matches Apple's keyboard (and follows dark
/// mode) so Lexia is discreet; the tints are soft, low-glare colours with
/// dark-grey text, which reduce visual stress for many dyslexic readers.
struct Theme {
    let background: Color
    let key: Color
    let functionKey: Color
    let keyPressed: Color
    let text: Color
    let secondaryText: Color
    let accent: Color
    let accentText: Color
    let shadow: Color

    static func make(_ tint: LexiaSettings.Tint, dark: Bool = false) -> Theme {
        func hex(_ value: UInt32) -> Color {
            Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
        }
        let ink = hex(0x2B2A33)
        switch tint {
        case .standard where dark:
            return Theme(background: hex(0x1F1F21), key: hex(0x5C5C60), functionKey: hex(0x3A3A3D),
                         keyPressed: hex(0x7A7A7F), text: .white, secondaryText: hex(0xAEAEB2),
                         accent: hex(0x5C5C60), accentText: .white, shadow: .black.opacity(0.6))
        case .standard:
            return Theme(background: hex(0xD1D3D9), key: .white, functionKey: hex(0xABB0BA),
                         keyPressed: hex(0xBFC3CB), text: .black, secondaryText: hex(0x6E6E73),
                         accent: .white, accentText: .black, shadow: .black.opacity(0.3))
        case .dark:
            return Theme(background: hex(0x1C1C21), key: hex(0x3A3A42), functionKey: hex(0x2A2A31),
                         keyPressed: hex(0x56565F), text: hex(0xEFE8D8), secondaryText: hex(0xB5AFA3),
                         accent: hex(0xF2C14E), accentText: hex(0x1C1C21), shadow: .black.opacity(0.5))
        default:
            let (bg, fn): (UInt32, UInt32) = {
                switch tint {
                case .cream: return (0xF6EED9, 0xE3D8BC)
                case .blue: return (0xDCE9F5, 0xC3D5E8)
                case .green: return (0xDDEFDF, 0xC4DEC8)
                case .peach: return (0xFBE3D3, 0xEDCBB5)
                case .lilac: return (0xE9E1F3, 0xD3C7E5)
                default: return (0xE4E4E2, 0xCDCDCB)
                }
            }()
            return Theme(background: hex(bg), key: hex(0xFFFDF7), functionKey: hex(fn),
                         keyPressed: hex(fn).opacity(0.7), text: ink, secondaryText: ink.opacity(0.6),
                         accent: hex(0x2F5DA8), accentText: .white, shadow: .black.opacity(0.18))
        }
    }

    /// Distinct colours for letters that are easy to mirror.
    func cueColour(for letter: String) -> Color? {
        switch letter.lowercased() {
        case "b": return Color(red: 0.12, green: 0.40, blue: 0.80)
        case "d": return Color(red: 0.78, green: 0.22, blue: 0.16)
        case "p": return Color(red: 0.13, green: 0.55, blue: 0.27)
        case "q": return Color(red: 0.62, green: 0.30, blue: 0.70)
        default: return nil
        }
    }
}
