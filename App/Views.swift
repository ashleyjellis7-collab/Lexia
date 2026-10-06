import SwiftUI
import LexiaCore

// MARK: - Set up

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Lexia is a keyboard made for dyslexic readers and writers: an easier-to-read font, calm colours, and corrections that understand how dyslexic spelling works.")
                        .font(model.settings.keyFont(size: 16))
                        .padding(.vertical, 4)
                }
                Section("Turn on the keyboard") {
                    step(1, "Open the **Settings** app.")
                    step(2, "Go to **General → Keyboard → Keyboards**.")
                    step(3, "Tap **Add New Keyboard…** and choose **Lexia**.")
                    step(4, "Tap **Lexia** and turn on **Allow Full Access**. This lets Jev make smart corrections and lets the keyboard read your settings.")
                    step(5, "In any app, hold the 🌐 key and pick **Lexia**.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Section("About Full Access") {
                    Text("Without Full Access, Lexia still works: the dyslexia-friendly font, colours and on-device corrections all run on your phone. With Full Access and a TypeSafe key, the sentence you're typing is sent to TypeSafe's Jev model to pick the right word. Lexia never sends text from password, email, web address, phone or payment fields.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Lexia")
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    KeyPreview(settings: model.settings)
                        .listRowInsets(EdgeInsets())
                }

                Section("Look") {
                    Picker("Font", selection: $model.settings.font) {
                        ForEach(LexiaSettings.KeyFont.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Background", selection: $model.settings.tint) {
                        ForEach(LexiaSettings.Tint.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Lowercase letters on keys", isOn: $model.settings.lowercaseKeys)
                    Toggle("Colour b, d, p and q", isOn: $model.settings.letterColourCues)
                    VStack(alignment: .leading) {
                        Text("Text size")
                        Slider(value: $model.settings.textScale, in: 0.85...1.3, step: 0.05)
                    }
                }

                Section {
                    Picker("Autocorrect", selection: $model.settings.autocorrectMode) {
                        Text("When confident").tag(AutocorrectMode.whenConfident)
                        Text("Suggest only").tag(AutocorrectMode.suggestOnly)
                        Text("Off").tag(AutocorrectMode.off)
                    }
                    Toggle("Spot mixed-up words (their/there)", isOn: $model.settings.reviewPreviousWords)
                    Toggle("Hold a suggestion to hear it", isOn: $model.settings.speakSuggestions)
                } header: {
                    Text("Corrections")
                } footer: {
                    Text("Lexia only changes a word by itself when it's confident. Press delete straight after a correction to undo it — Lexia will remember that word.")
                }

                Section {
                    Toggle("Use Jev smart corrections", isOn: $model.settings.useJev)
                    HStack {
                        Group {
                            if showKey {
                                TextField("TypeSafe API key", text: $model.apiKey)
                            } else {
                                SecureField("TypeSafe API key", text: $model.apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { model.saveAPIKey() }
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Save key") { model.saveAPIKey() }
                    Button {
                        model.saveAPIKey()
                        Task { await model.testJev() }
                    } label: {
                        HStack {
                            Text("Test Jev")
                            if model.isTestingJev { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!model.hasAPIKey || model.isTestingJev)
                    if let result = model.jevTestResult {
                        Text(result).font(.footnote)
                    }
                    DisclosureGroup("Advanced") {
                        TextField("Server", text: $model.settings.jevBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Model", text: $model.settings.jevModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Jev by TypeSafe")
                } footer: {
                    Text("Jev reads the sentence around a word and picks which of Lexia's suggestions you meant — like “form” vs “from”, or “their” vs “they're”. Get a key at console.typesafe.ai. The key is stored in your iPhone's Keychain.")
                }

                Section {
                    if model.personalWords.isEmpty {
                        Text("Words you keep (or undo corrections for) appear here, and won't be corrected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.personalWords, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { offsets in
                        offsets.map { model.personalWords[$0] }.forEach(model.removeWord)
                    }
                } header: {
                    Text("My words")
                }
            }
            .navigationTitle("Settings")
            .onAppear { model.reloadWords() }
        }
    }
}

/// A live preview of the keyboard's look.
struct KeyPreview: View {
    let settings: LexiaSettings

    var body: some View {
        let theme = Theme.make(settings.tint)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(["b", "d", "p", "q", "a", "e"], id: \.self) { letter in
                    let shown = settings.lowercaseKeys ? letter : letter.uppercased()
                    Text(shown)
                        .font(settings.keyFont(size: 23))
                        .foregroundColor(settings.letterColourCues ? (theme.cueColour(for: shown) ?? theme.text) : theme.text)
                        .frame(width: 40, height: 48)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.key)
                            .shadow(color: theme.shadow, radius: 0, x: 0, y: 1))
                }
            }
            Text("because the dog was happy")
                .font(settings.keyFont(size: 18))
                .foregroundColor(theme.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(theme.background)
    }
}

// MARK: - Try it

struct TryItView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Switch to Lexia with the 🌐 key and try typing things like “i dont no wen its hapening becuz” or “their going to the skool”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(model.settings.keyFont(size: 20))
                    .focused($focused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.make(model.settings.tint).background))
            }
            .padding()
            .navigationTitle("Try it")
            .toolbar {
                Button("Clear") { text = "" }
            }
            .onAppear { focused = true }
        }
    }
}
