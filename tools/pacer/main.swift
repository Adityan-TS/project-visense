// tools/pacer/main.swift — feeds recognizer-style partials into WordPacer and
// checks the glasses get every update immediately and every word exactly once.
import Foundation
setbuf(stdout, nil)

var sent: [TextMessage] = []
let pacer = WordPacer(send: { sent.append($0) })

func text(_ m: TextMessage) -> String { String(decoding: m.payload, as: UTF8.self) }

let partials = [
    "Hello",
    "Hello how are you",                                   // burst of 3 words
    "Hello how are you doing today",
    "Hello how are you doing today my friend",
    "Hello, how are you doing today, my friend",           // punctuation revision
]
for p in partials {
    let before = sent.count
    pacer.partial(p)
    precondition(sent.count > before, "every changed partial must be sent right away")
    print(sent[before...].map { ($0.type == .partial ? "partial  " : "FINAL    ") + text($0) }.joined(separator: "\n"))
}
pacer.final("Hello, how are you doing today, my friend?")
print("FINAL    " + text(sent.last!))

let committed = sent.filter { $0.type == .final }.map(text).joined(separator: " ")
print("committed: \(committed)")
// Lines already scrolled up are not revised later ("Hello" keeps no comma).
precondition(WordPacer.words(committed).count == 8 && committed.hasSuffix("my friend?"),
             "all words committed once, in order")
// No live line may exceed (rows-1) lines worth of characters.
precondition(sent.filter { $0.type == .partial }.allSatisfy { text($0).count <= 24 }, "live line fits the display")
print("WordPacer OK")
