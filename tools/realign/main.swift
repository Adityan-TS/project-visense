// Tests SpeechEngine.alignedCommitCount (compiled together with SpeechEngine's
// pure helper extracted by tools/run_tests.sh). Each case: what was shown before,
// the recognizer's new transcript, and the words that must appear next.
func w(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
var failed = 0
func check(_ name: String, shown: String, now: String, expect: String) {
    let snap = w(shown)
    let n = alignedCommitCount(snapshot: snap, committed: snap.count, words: w(now))
    let got = w(now).dropFirst(n).joined(separator: " ")
    let ok = got == expect
    if !ok { failed += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): \"\(got)\"\(ok ? "" : "  expected \"\(expect)\"")")
}
check("continues", shown: "Thanks for coming in today.", now: "Thanks for coming in today. Your next", expect: "Your next")
check("first words rewritten", shown: "I there thanks for coming in today.", now: "Hi there, thanks for coming in today. Your next", expect: "Your next")
check("recognizer restarted", shown: "Thanks for coming in today.", now: "Your next", expect: "Your next")
check("restart, short line before", shown: "Okay.", now: "Your next appointment", expect: "Your next appointment")
check("tail rewritten", shown: "Please take two tablets", now: "Please take 2 tablets after", expect: "after")
check("words merged shorter", shown: "Call us if any thing changes.", now: "Call us if anything changes. Bye", expect: "Bye")
check("no new words yet", shown: "Thanks for coming in today.", now: "Thanks for coming in today.", expect: "")
print(failed == 0 ? "Realign OK" : "Realign FAILED (\(failed))")
if failed > 0 { exit(1) }
