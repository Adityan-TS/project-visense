// Log.swift — tiny on-screen + console log. Thread-safe: call from anywhere.
import Foundation

final class Log: ObservableObject {
    static let shared = Log()
    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func add(_ msg: String) { shared.add(msg) }

    func add(_ msg: String) {
        let line = "\(formatter.string(from: Date())) \(msg)"
        print("[ViSense] " + line)
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 200 { self.lines.removeFirst(self.lines.count - 200) }
        }
    }
}
