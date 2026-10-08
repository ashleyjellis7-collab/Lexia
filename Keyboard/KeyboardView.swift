import SwiftUI
import LexiaCore

struct KeyboardView: View {
    @ObservedObject var state: KeyboardState

    static let keyHeight: CGFloat = 48
    static let rowSpacing: CGFloat = 10
    static let keySpacing: CGFloat = 6
    static let suggestionBarHeight: CGFloat = 52
    static var totalHeight: CGFloat { suggestionBarHeight + 4 * keyHeight + 3 * rowSpacing + 16 }

    var body: some View {
        let theme = state.theme
        VStack(spacing: 0) {
            SuggestionBar(state: state, theme: theme)
                .frame(height: Self.suggestionBarHeight)
            GeometryReader { geo in
                let unit = (geo.size.width - 6 - 9 * Self.keySpacing) / 10
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(KeyboardLayout.rows(for: state.page, showsGlobe: state.showsGlobe).enumerated()),
                            id: \.offset) { _, row in
                        HStack(spacing: Self.keySpacing) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                                KeyView(spec: key, state: state, theme: theme)
                                    .frame(width: key.units.map { $0 * unit + ($0 - 1) * Self.keySpacing },
                                           height: Self.keyHeight)
                                    .frame(maxWidth: key.units == nil ? .infinity : nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 8)
            }
        }
        .background(theme.background.ignoresSafeArea())
    }
}

// MARK: - Keys

struct KeyView: View {
    let spec: KeySpec
    @ObservedObject var state: KeyboardState
    let theme: Theme

    @State private var pressed = false
    @State private var repeatTimer: Timer?
    @State private var keySize: CGSize = .zero

    private var isFunctionKey: Bool {
        if case .character = spec.kind { return false }
        return spec.kind != .space
    }

    var body: some View {
        if spec.kind == .globe {
            GlobeKey(controller: state.inputController, theme: theme)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
                    .shadow(color: theme.shadow, radius: 0, x: 0, y: 1)
                label
            }
            .contentShape(Rectangle())
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { keySize = geo.size }
                    .onChange(of: geo.size) { keySize = $0 }
            })
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        if spec.kind == .backspace { startRepeating() }
                    }
                    .onEnded { value in
                        pressed = false
                        if spec.kind == .backspace {
                            stopRepeating()
                        } else {
                            if case .character = spec.kind, keySize.width > 0 {
                                // Offset from the key's centre, in key pitches (key plus the gap around it).
                                state.lastTouch = CGPoint(
                                    x: (value.location.x - keySize.width / 2) / (keySize.width + KeyboardView.keySpacing),
                                    y: (value.location.y - keySize.height / 2) / (keySize.height + KeyboardView.rowSpacing)
                                )
                            } else {
                                state.lastTouch = nil
                            }
                            state.onKey(spec.kind)
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isKeyboardKey)
        }
    }

    private var background: Color {
        if pressed { return theme.keyPressed }
        if spec.kind == .shift, state.shift != .off { return theme.key }
        return isFunctionKey ? theme.functionKey : theme.key
    }

    @ViewBuilder private var label: some View {
        let settings = state.settings
        switch spec.kind {
        case .character(let c):
            let shown = state.label(for: c)
            Text(shown)
                .font(settings.keyFont(size: pressed ? 28 : 23))
                .foregroundColor(settings.letterColourCues ? (theme.cueColour(for: shown) ?? theme.text) : theme.text)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        case .shift:
            Image(systemName: state.shift == .capsLock ? "capslock.fill" : (state.shift == .on ? "shift.fill" : "shift"))
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(theme.text)
        case .backspace:
            Image(systemName: pressed ? "delete.left.fill" : "delete.left")
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(theme.text)
        case .space:
            Text("space").font(settings.keyFont(size: 16)).foregroundColor(theme.secondaryText)
        case .returnKey:
            Text(state.returnLabel).font(settings.keyFont(size: 16)).foregroundColor(theme.text)
                .minimumScaleFactor(0.6).lineLimit(1)
        case .page(_, let label):
            Text(label).font(settings.keyFont(size: 16)).foregroundColor(theme.text)
        case .globe:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        switch spec.kind {
        case .character(let c): return c
        case .shift: return "shift"
        case .backspace: return "delete"
        case .space: return "space"
        case .returnKey: return state.returnLabel
        case .page(_, let label): return label
        case .globe: return "next keyboard"
        }
    }

    /// Delete once immediately, then keep deleting while held.
    private func startRepeating() {
        state.onKey(.backspace)
        repeatTimer?.invalidate()
        let start = Date()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [state] _ in
            guard Date().timeIntervalSince(start) > 0.45 else { return }
            Task { @MainActor in state.onKey(.backspace) }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

/// The "next keyboard" key. It has to be a UIKit control so iOS can show its
/// keyboard-switching menu on long press.
struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?
    let theme: Theme

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.layer.cornerRadius = 8
        button.accessibilityLabel = "Next keyboard"
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.backgroundColor = UIColor(theme.functionKey)
        button.tintColor = UIColor(theme.text)
    }
}

// MARK: - Suggestion bar

struct SuggestionBar: View {
    @ObservedObject var state: KeyboardState
    let theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            if state.suggestions.isEmpty {
                Text(state.notice ?? "")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(state.suggestions) { suggestion in
                    chip(suggestion)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .overlay(alignment: .topTrailing) {
            if state.jevWorking {
                Circle().fill(theme.accent.opacity(0.6)).frame(width: 5, height: 5).padding(4)
                    .accessibilityHidden(true)
            }
        }
    }

    private func chip(_ suggestion: Suggestion) -> some View {
        let highlighted = suggestion.isAutocorrect || suggestion.kind == .fixPrevious
        let text: String = {
            switch suggestion.kind {
            case .keepTyped:
                return state.currentSet?.autocorrect != nil ? "“\(suggestion.text)”" : suggestion.text
            case .fixPrevious:
                return "↺ \(suggestion.text)"
            case .undoCorrection:
                return "↩ \(suggestion.text)"
            default:
                return suggestion.text
            }
        }()
        return Text(text)
            .font(state.settings.keyFont(size: 20, bold: highlighted))
            .foregroundColor(highlighted ? theme.accentText : theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(highlighted ? theme.accent : theme.key.opacity(0.55))
            )
            .contentShape(Rectangle())
            .onTapGesture { state.onSuggestion(suggestion) }
            .onLongPressGesture(minimumDuration: 0.45) { state.onSpeak(suggestion.text) }
            .accessibilityElement()
            .accessibilityLabel(accessibility(for: suggestion))
            .accessibilityAddTraits(.isButton)
    }

    private func accessibility(for suggestion: Suggestion) -> String {
        switch suggestion.kind {
        case .keepTyped: return "Keep \(suggestion.text)"
        case .fixPrevious: return "Change \(suggestion.fix?.word ?? "") to \(suggestion.text)"
        case .undoCorrection: return "Undo correction, keep \(suggestion.text)"
        default: return suggestion.isAutocorrect ? "\(suggestion.text), will be used" : suggestion.text
        }
    }
}
