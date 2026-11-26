import SwiftUI

/// The check after a book feed session: short phrases, half from what played this session and half
/// from parts of the book that never played, and you say which you heard. Guessing gets half right,
/// so a score well above half means something stuck.
struct BookQuiz {
    struct Item { let phrase: String; let heard: Bool }
    let mode: BookFeed.Mode
    let speed: Double
    let seconds: Double
    let items: [Item]

    static let phraseLength = 6

    /// Builds the quiz for the session that just ended, or nil if too little played to test.
    static func make(feed: BookFeed) -> BookQuiz? {
        let mode = feed.sessionMode
        guard mode != .off else { return nil }
        let words = feed.words
        let played = feed.playedRange
        let half = mode == .lab ? 10 : 5
        let n = phraseLength

        var taken: [Int] = []
        func spaced(_ i: Int) -> Bool { !taken.contains { abs($0 - i) < n + 2 } }
        func phrase(at i: Int) -> String? {
            let raw = words[i..<(i + n)].joined(separator: " ")
            let clean = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\u{201C}", with: "")
                .replacingOccurrences(of: "\u{201D}", with: "")
            return clean.split(separator: " ").count >= n - 1 ? clean : nil
        }

        // from what played: skip the first few seconds, when the voice was still fading in
        let lo = played.lowerBound + 8, hi = played.upperBound - n
        guard hi - lo > n * 4 else { return nil }
        var heard: [Item] = []
        for i in Array(lo..<hi).shuffled() where heard.count < half && spaced(i) {
            if let p = phrase(at: i) { heard.append(Item(phrase: p, heard: true)); taken.append(i) }
        }
        guard heard.count >= 2 else { return nil }

        // decoys: never near this session, never from an earlier lab test, and for Deep Listen from
        // the part of the book still ahead of you, since what's behind you was read before
        let near = (played.lowerBound - 300)..<(played.upperBound + 300)
        let before = mode == .lab ? feed.labHeard : []
        func clear(_ i: Int) -> Bool {
            let r = i..<(i + n)
            return !near.overlaps(r) && !before.contains { $0.overlaps(r) }
        }
        var pools: [[Int]] = []
        let all = Array(0..<(words.count - n))
        if mode == .listen { pools.append(all.filter { $0 >= near.upperBound }) }
        pools.append(all.filter(clear))
        pools.append(all.filter { !near.overlaps($0..<($0 + n)) })
        var decoys: [Item] = []
        for pool in pools where decoys.count < heard.count {
            for i in pool.shuffled() where decoys.count < heard.count && spaced(i) {
                if let p = phrase(at: i) { decoys.append(Item(phrase: p, heard: false)); taken.append(i) }
            }
        }
        let k = min(heard.count, decoys.count)
        guard k >= 2 else { return nil }
        return BookQuiz(mode: mode, speed: feed.speed, seconds: feed.fedSeconds,
                        items: (Array(heard.prefix(k)) + Array(decoys.prefix(k))).shuffled())
    }

    /// How often pure guessing scores at least this many out of `total`.
    static func chance(atLeast correct: Int, of total: Int) -> Double {
        guard total > 0 else { return 1 }
        var sum = 0.0
        for k in correct...max(correct, total) where k <= total {
            sum += binomial(total, k)
        }
        return sum / pow(2, Double(total))
    }

    private static func binomial(_ n: Int, _ k: Int) -> Double {
        var r = 1.0
        for i in 0..<min(k, n - k) { r = r * Double(n - i) / Double(i + 1) }
        return r
    }
}

/// Every quiz result, kept on the phone so the two modes and their speeds can be compared.
struct QuizRecord: Codable {
    var date: Date
    var mode: String
    var speed: Double
    var seconds: Double
    var correct: Int
    var total: Int
}

enum QuizLog {
    private static let key = "nmind.bookquiz.log.v1"

    static func all() -> [QuizRecord] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let r = try? JSONDecoder().decode([QuizRecord].self, from: d) else { return [] }
        return r
    }

    static func add(_ r: QuizRecord) {
        var list = all()
        list.append(r)
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
}

func speedLabel(_ v: Double) -> String {
    v == v.rounded() ? "\(Int(v))x" : String(format: "%gx", v)
}

/// The quiz itself, shown between the end of a session and its summary.
struct QuizCard: View {
    let quiz: BookQuiz
    let done: (_ correct: Int, _ total: Int) -> Void
    let skip: () -> Void

    @State private var index = 0
    @State private var correct = 0
    @State private var finished = false

    private var total: Int { quiz.items.count }
    private var isLab: Bool { quiz.mode == .lab }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isLab ? "LAB QUIZ" : "RECALL CHECK")
                .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(Palette.teal)
            if finished { result } else { question }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 22).fill(Palette.glass))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.current, lineWidth: 1))
        .padding(.horizontal, 20)
    }

    private var question: some View {
        let item = quiz.items[index]
        return VStack(alignment: .leading, spacing: 16) {
            Text("Did this play in your session?")
                .font(.subheadline).foregroundStyle(Palette.mist)
            Text("\u{201C}\(item.phrase)\u{201D}")
                .font(.title3.weight(.medium)).foregroundStyle(Palette.foam)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            HStack(spacing: 10) {
                answer("Heard it", yes: true)
                answer("New to me", yes: false)
            }
            HStack {
                Text("\(index + 1) of \(total)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Palette.mist)
                Spacer()
                Button("Skip quiz", action: skip)
                    .font(.footnote).foregroundStyle(Palette.mist)
            }
        }
    }

    private func answer(_ label: String, yes: Bool) -> some View {
        Button {
            if quiz.items[index].heard == yes { correct += 1 }
            if index + 1 < total {
                index += 1
            } else {
                QuizLog.add(QuizRecord(date: Date(), mode: quiz.mode.rawValue, speed: quiz.speed,
                                       seconds: quiz.seconds, correct: correct, total: total))
                withAnimation(.easeInOut(duration: 0.3)) { finished = true }
            }
        } label: {
            Text(label)
                .font(.headline)
                .foregroundStyle(yes ? Palette.bg : Palette.foam)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Capsule().fill(yes ? Palette.teal : Palette.current.opacity(0.6)))
        }
    }

    private var result: some View {
        let p = BookQuiz.chance(atLeast: correct, of: total)
        let same = QuizLog.all().filter { $0.mode == quiz.mode.rawValue && $0.speed == quiz.speed }
        let avg = same.isEmpty ? 0 : same.map { Double($0.correct) / Double(max(1, $0.total)) }.reduce(0, +) / Double(same.count)
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(correct) of \(total) right")
                .font(.system(size: 34, weight: .semibold)).foregroundStyle(Palette.foam)
            Text("Guessing gets about \(total / 2).")
                .font(.subheadline).foregroundStyle(Palette.mist)
            Text(verdict(p))
                .font(.subheadline).foregroundStyle(p < 0.05 ? Palette.amber : Palette.foam)
                .fixedSize(horizontal: false, vertical: true)
            if same.count > 1 {
                Text("\(quiz.mode.label) at \(speedLabel(quiz.speed)): \(same.count) tests so far, averaging \(Int((avg * 100).rounded()))% right.")
                    .font(.footnote).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { done(correct, total) } label: {
                Text("See session")
                    .font(.headline).foregroundStyle(Palette.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Capsule().fill(Palette.teal))
            }
            .padding(.top, 4)
        }
    }

    private func verdict(_ p: Double) -> String {
        if p < 0.05 {
            let odds = max(20, Int((1 / p).rounded()))
            return "Guessing scores this high about 1 time in \(odds). One result can still be luck, so repeat it."
        }
        if p < 0.25 { return "A little above guessing, within what luck often gives. More tests will tell." }
        return "Within what guessing gives."
    }
}
