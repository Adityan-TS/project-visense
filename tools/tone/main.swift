import Foundation

let group = DispatchGroup()
group.enter()
Task {
    await TonePunctuationDemo.run()
    group.leave()
}
group.wait()