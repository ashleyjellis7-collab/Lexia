# Lexia: a dyslexia-friendly iPhone keyboard

Lexia is a custom iOS keyboard designed for people with dyslexia:

- **Easier-to-read keys.** Labels use the [OpenDyslexic](https://opendyslexic.org) font (Rounded and System fonts are also available). Keys show lowercase letters to match what you read. Optional colours for **b d p q** help you tell mirror letters apart.
- **Calm colours.** Cream, blue, green, peach, lilac, grey or dark backgrounds with dark-grey (not pure black) text, plus larger keys and adjustable text size.
- **Corrections that understand dyslexic spelling.** Lexia matches words by *sound* (`becuz` → because, `fone` → phone, `enuf` → enough). It treats mirrored letters (b/d, p/q), swapped letters (`wiht`), and dropped or doubled letters (`litle`) as small slips rather than big errors.
- **Context from Jev.** [TypeSafe's Jev](https://docs.typesafe.ai/) reads the sentence and picks which suggestion you meant. It catches real-word mix-ups a spell checker can't, such as *their/there/they're*, *form/from* and *was/saw*.
- **Gentle by design.** Lexia changes a word on its own only when it's confident. Press delete straight after a correction to undo it, and Lexia remembers that word. Mixed-up words are offered as a ↺ chip in the suggestion bar and never changed silently. Hold a suggestion to hear it read aloud.

## How the autocorrect works

```
 keystroke ─► on-device engine (LexiaCore) ─► suggestion bar     (instant, offline)
                   │  top candidates
                   ▼
              Jev /v1/systemone  ─► re-ranked bar + autocorrect  (~70–500 ms, after a short pause)
```

1. **On-device engine** (`LexiaCore/SpellingEngine.swift`). This scores all ~38k words in the lexicon with a *dyslexia-weighted* edit distance (`EditCost.swift`) plus a loose sound-alike code (`Phonetic.swift`). The result is weighted by how common each word is. It works without the network and without Full Access.
2. **Jev re-ranking** (`LexiaCore/Jev/`). Lexia sends Jev the text around the cursor and two typed questions:
   - `intended_word`, a **choice** between the typed word, the engine's candidates and any homophones;
   - `typed_is_intended`, a **noul** (yes/no probability) asking whether the word as typed is already right.

   Jev's probabilities are blended 70/30 with the on-device scores. Lexia only autocorrects a misspelling when Jev thinks the typed word is probably wrong (`typed_is_intended < 0.4`). Real-word swaps (their → there) need Jev to be at least 85% sure. Any error or timeout falls back to the on-device answer.
3. **Look-back review.** After each word, Lexia asks Jev about the previous two words, so `their going` can be flagged once `going` is typed.

The client mirrors the wire format of TypeSafe's official SDK: `POST https://api.typesafe.ai/v1/systemone` with a Bearer key, body `{model, state, questions}`, and answers keyed by question name.

## Project layout

| Path | What's in it |
| --- | --- |
| `LexiaCore/` | Swift package with the spelling engine, phonetic codes, the Jev client and reranker, the suggestion pipeline and unit tests. Platform-independent. |
| `Keyboard/` | The keyboard extension (`UIInputViewController` + SwiftUI keys and suggestion bar). |
| `App/` | Companion app: setup steps, appearance, corrections, API key + "Test Jev", personal words, a "Try it" pad. |
| `Shared/` | Settings and API key (shared via the Keychain), font registration, colour themes. |
| `Fonts/` | OpenDyslexic Regular/Bold (SIL Open Font License). |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for the Xcode project. |

## Build and run

Requirements: a Mac with Xcode 16 or later, an iPhone on iOS 16 or later, and a free Apple ID.

1. Download this branch (green **Code** button → **Download ZIP**) and unzip it.
2. Double-click `Lexia.xcodeproj` to open it in Xcode.
3. Click the blue **Lexia** project icon at the top of the left sidebar. Then, for **both** targets (`Lexia` and `LexiaKeyboard`), open **Signing & Capabilities** and choose your Apple ID under **Team**.
4. Plug in your iPhone, choose it at the top of the Xcode window, and press ▶ (Run).
5. On the phone, go to **Settings → General → Keyboard → Keyboards → Add New Keyboard… → Lexia**, then tap **Lexia** and turn on **Allow Full Access**.
6. In the Lexia app, open **Settings**, paste your TypeSafe API key and tap **Test Jev**.

If Xcode says the bundle identifier isn't available, change `LEXIA_BUNDLE_PREFIX` (project ▸ Build Settings) to something unique, such as `com.yourname.lexia`.

`Lexia.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you edit `project.yml`, run `brew install xcodegen && xcodegen`.

Run the engine tests with `cd LexiaCore && swift test`.

## Privacy

- With Full Access off, Lexia sends nothing anywhere: all corrections happen on the phone.
- With Full Access on and a key saved, Lexia sends up to ~300 characters before the cursor and ~120 after it, plus the candidate words, to TypeSafe for each word it checks. It never sends text from password, one-time-code, email, URL, username, phone or credit-card fields (iOS already blocks custom keyboards in secure fields).
- The API key lives in the iOS Keychain, shared only between the Lexia app and its keyboard.
- Before shipping to other people, put your own server in front of TypeSafe (set **Settings → Jev → Advanced → Server**) so users don't need their own key, and add a privacy policy.

## Credits and licences

- **OpenDyslexic** by Abbie Gonzalez, SIL Open Font License 1.1 (`Fonts/OpenDyslexic-OFL.txt`).
- Word frequencies come from [FrequencyWords](https://github.com/hermitdave/FrequencyWords) (MIT, Hermit Dave), filtered against the [SCOWL](http://wordlist.aspell.net/) English word lists.
- Word-pair (bigram) counts come from the [Google Books Ngram](https://books.google.com/ngrams) fiction corpus (v3, 2020), licensed [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/), trimmed to common pairs.
- **Jev** and the System One API are from [TypeSafe AI](https://typesafe.ai).
