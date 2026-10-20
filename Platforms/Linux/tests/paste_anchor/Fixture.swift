import Foundation

func expect(_ text: String, _ selection: NSRange, _ current: String,
            _ expected: NSRange?, _ reason: String) {
    let actual = ComposerPasteAnchor(text: text, selection: selection).selection(in: current)
    precondition(actual == expected, "\(reason): \(String(describing: actual))")
}

@main
enum Fixture {
    static func main() {
        expect("before after", NSRange(location: 7, length: 0), "before after",
               NSRange(location: 7, length: 0), "caret motion without an edit")
        expect("before after", NSRange(location: 7, length: 0), "😊before after",
               NSRange(location: 9, length: 0), "UTF-16 insertion before paste")
        expect("before after", NSRange(location: 3, length: 0), "before after!",
               NSRange(location: 3, length: 0), "edit after paste")
        expect("before after", NSRange(location: 7, length: 0), "before typedafter",
               NSRange(location: 7, length: 0), "typing at paste caret follows it")
        expect("before after", NSRange(location: 7, length: 5), "before edited",
               nil, "replacement through selected text")
        expect("before after", NSRange(location: 7, length: 0), "befter",
               nil, "deletion across paste caret")
        expect("before after", NSRange(location: 7, length: 0), "Xbefore afterY",
               nil, "edits on both sides have no unambiguous anchor")
        expect("aaaa", NSRange(location: 2, length: 0), "aaaaa",
               nil, "repeated insertion has no unique side of the caret")
        expect("aaaa", NSRange(location: 2, length: 0), "aaa",
               nil, "repeated deletion has no unique side of the caret")
        expect("before after", NSRange(location: 50, length: 0), "before after",
               nil, "invalid original selection")
        let paste = NSRange(location: 5, length: 0)
        precondition(ComposerPasteAnchor.laterSelection(NSRange(location: 11, length: 0),
            afterReplacing: paste, insertedUTF16Length: 6) == NSRange(location: 17, length: 0),
            "later caret after paste")
        precondition(ComposerPasteAnchor.laterSelection(NSRange(location: 1, length: 0),
            afterReplacing: paste, insertedUTF16Length: 6) == NSRange(location: 1, length: 0),
            "later caret before paste")
        precondition(ComposerPasteAnchor.laterSelection(NSRange(location: 3, length: 4),
            afterReplacing: paste, insertedUTF16Length: 6) == NSRange(location: 11, length: 0),
            "later selection crossed paste")
        let alphabet: [Character] = ["a", "b"]
        for length in 0...5 {
            for pattern in 0..<(1 << length) {
                let original = String((0..<length).map { alphabet[(pattern >> $0) & 1] })
                for caret in 0...length {
                    let selection = NSRange(location: caret, length: 0)
                    for edit in 0...length {
                        for character in alphabet {
                            var inserted = original
                            inserted.insert(character, at: inserted.index(inserted.startIndex,
                                                                          offsetBy: edit))
                            let actual = ComposerPasteAnchor(text: original,
                                selection: selection).selection(in: inserted)
                            let expected = edit < caret ? caret + 1 : caret
                            precondition(actual == nil || actual?.location == expected,
                                         "insertion remapped across caret: \(original) \(edit) \(caret)")
                        }
                        guard edit < length else { continue }
                        var deleted = original
                        deleted.remove(at: deleted.index(deleted.startIndex, offsetBy: edit))
                        let actual = ComposerPasteAnchor(text: original,
                            selection: selection).selection(in: deleted)
                        let expected = edit < caret ? caret - 1 : caret
                        precondition(actual == nil || actual?.location == expected,
                                     "deletion remapped across caret: \(original) \(edit) \(caret)")
                    }
                }
            }
        }
        print("PASS anchored clipboard text fallback")
    }
}
