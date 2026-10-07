import XCTest
@testable import LexiaCore

/// "Sound it out": words typed the way they sound, often because the writer
/// doesn't know how to start spelling them. Add real examples from testers here.
final class SoundOutTests: XCTestCase {

    static let cases: [String: String] = [
        "accomodate": "accommodate",
        "acheive": "achieve",
        "anser": "answer",
        "arguement": "argument",
        "becos": "because",
        "becuz": "because",
        "beginer": "beginner",
        "beleev": "believe",
        "beutiful": "beautiful",
        "bewtiful": "beautiful",
        "calender": "calendar",
        "choclate": "chocolate",
        "comittee": "committee",
        "computor": "computer",
        "concious": "conscious",
        "conshuns": "conscience",
        "coz": "because",
        "definatly": "definitely",
        "defnitly": "definitely",
        "diffrence": "difference",
        "dinosor": "dinosaur",
        "dissapoint": "disappoint",
        "edukashun": "education",
        "elefant": "elephant",
        "embarass": "embarrass",
        "enjin": "engine",
        "enuff": "enough",
        "envirment": "environment",
        "enviroment": "environment",
        "enybody": "anybody",
        "existance": "existence",
        "experiance": "experience",
        "explane": "explain",
        "exsplain": "explain",
        "famly": "family",
        "favrit": "favourite",
        "febuary": "February",
        "finaly": "finally",
        "fiziks": "physics",
        "fizzical": "physical",
        "foriegn": "foreign",
        "frend": "friend",
        "garantee": "guarantee",
        "goverment": "government",
        "grammer": "grammar",
        "imediatly": "immediately",
        "independant": "independent",
        "intresting": "interesting",
        "knowlege": "knowledge",
        "kwestion": "question",
        "kwite": "quite",
        "libary": "library",
        "liesure": "leisure",
        "lissen": "listen",
        "millenium": "millennium",
        "mischievious": "mischievous",
        "nashunal": "national",
        "neice": "niece",
        "nesesery": "necessary",
        "nessisary": "necessary",
        "newanced": "nuanced",
        "nite": "night",
        "nolij": "knowledge",
        "nollej": "knowledge",
        "noticable": "noticeable",
        "nuanst": "nuanced",
        "ocassion": "occasion",
        "occured": "occurred",
        "ofen": "often",
        "oppertunity": "opportunity",
        "peepul": "people",
        "pepul": "people",
        "persue": "pursue",
        "posession": "possession",
        "probly": "probably",
        "publically": "publicly",
        "reccomend": "recommend",
        "recieve": "receive",
        "rember": "remember",
        "resturant": "restaurant",
        "rite": "right",
        "rithum": "rhythm",
        "rythm": "rhythm",
        "sentance": "sentence",
        "seperate": "separate",
        "seprate": "separate",
        "sertain": "certain",
        "sircle": "circle",
        "sistem": "system",
        "skwer": "square",
        "speshal": "special",
        "sucess": "success",
        "sumwun": "someone",
        "suprise": "surprise",
        "sykology": "psychology",
        "togethor": "together",
        "tommorow": "tomorrow",
        "tomoro": "tomorrow",
        "truely": "truly",
        "vejtable": "vegetable",
        "wen": "when",
        "wensday": "Wednesday",
        "wich": "which",
        "wot": "what",
    ]

    let engine = SpellingEngine(lexicon: SpellingEngineTests.lexicon)

    func testSoundedOutWordsAreFound() {
        var failures: [String] = []
        for (typed, intended) in Self.cases.sorted(by: { $0.key < $1.key }) {
            let result = engine.analyze(typed)
            let top = (result.autocorrect ?? result.candidates.first?.word)?.lowercased()
            let accepted: Set<String> = intended == "favourite" ? ["favourite", "favorite"] : [intended.lowercased()]
            if !accepted.contains(top ?? "") {
                failures.append("\(typed) → \(top ?? "nil") (wanted \(intended)); options: \(result.candidates.prefix(3).map(\.word))")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testMostSoundedOutWordsAreFixedAutomatically() {
        let fixed = Self.cases.filter { typed, intended in
            engine.analyze(typed).autocorrect?.lowercased() == intended.lowercased()
                || (intended == "favourite" && engine.analyze(typed).autocorrect == "favorite")
        }.count
        XCTAssertGreaterThanOrEqual(fixed, 85, "only \(fixed) of \(Self.cases.count) fixed automatically")
    }

    func testSilentLettersAndShSounds() {
        XCTAssertFalse(Set(Phonetic.codes(for: "listen")).isDisjoint(with: Phonetic.codes(for: "lissen")))
        XCTAssertFalse(Set(Phonetic.codes(for: "conscience")).isDisjoint(with: Phonetic.codes(for: "conshuns")))
        XCTAssertFalse(Set(Phonetic.codes(for: "nuanced")).isDisjoint(with: Phonetic.codes(for: "nuanst")))
    }
}
