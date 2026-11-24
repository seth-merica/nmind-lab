import SwiftUI

// Rewards, challenges and progression.
//
// Rewards: crossing into a new world blooms the void and names the world; passing your deepest
// point ever is called out. Challenges: every few minutes a short one appears; clearing it gives
// a speed surge and a rare color world, missing it costs nothing. Progression: rank, daily
// streak, deepest world and challenges cleared are kept on this phone only (UserDefaults).
// Nothing is sent anywhere.

/// What you have done over time, kept on this phone.
struct Record: Codable {
    var deepest = 0            // deepest world reached, 0 based
    var sessions = 0
    var totalSeconds = 0.0
    var streak = 0             // days in a row with a dive of 3 minutes or more
    var lastDiveDay = ""       // yyyy-MM-dd
    var challengesWon = 0

    static let ranks: [(from: Int, name: String)] = [
        (0, "Diver"), (2, "Drifter"), (4, "Deep"), (7, "Abyss"), (10, "Void walker"), (15, "Origin")
    ]
    static func rank(_ deepest: Int) -> String {
        ranks.last { deepest >= $0.from }?.name ?? "Diver"
    }
    var rank: String { Record.rank(deepest) }
}

/// The last dive, shown on the start screen.
struct DiveSummary {
    var minutes = 0
    var world = 0
    var cleared = 0
    var newBest = false
}

/// One message in the band under the centre target.
struct Banner: Equatable {
    enum Tone { case reward, challenge, info }
    var id = UUID()
    var title: String
    var detail: String
    var tone: Tone
    var progress: Double? = nil
    var secondsLeft: Int? = nil
}

final class Journey: ObservableObject {
    @Published private(set) var banner: Banner?
    @Published private(set) var record: Record
    @Published private(set) var lastDive: DiveSummary?

    private enum Kind: CaseIterable { case heart, center, soft, mellow }
    private struct Active {
        var kind: Kind
        var title: String
        var detail: String
        var limit: Double
        var need: Double
        var elapsed = 0.0
        var held = 0.0
        var startDrop = 0
    }

    private static let key = "nmind.record.v1"
    private var wasRunning = false
    private var sessionSeconds = 0.0
    private var level = 0
    private var sessionBest = 0
    private var startDeepest = 0
    private var cleared = 0
    private var nextChallenge = 90.0
    private var active: Active?
    private var bannerUntil = 0.0
    private var clock = 0.0
    private var lastKind: Kind?

    init() {
        if let d = UserDefaults.standard.data(forKey: Journey.key),
           let r = try? JSONDecoder().decode(Record.self, from: d) {
            record = r
        } else {
            record = Record()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(record) { UserDefaults.standard.set(d, forKey: Journey.key) }
    }

    private func show(_ b: Banner, for seconds: Double) {
        withAnimation(.easeInOut(duration: 0.4)) { banner = b }
        bannerUntil = clock + seconds
    }

    /// Called four times a second.
    func tick(dt: Double, engine: Engine, field: VoidField) {
        clock += dt
        let running = engine.running
        if running && !wasRunning { begin() }
        if !running && wasRunning { end() }
        wasRunning = running
        guard running else { return }

        let p = engine.panel
        let reading = p.mode == .reading
        if reading { sessionSeconds += dt }

        // a new world
        if p.depth > level {
            level = p.depth
            field.bloom()
            let name = "World \(level + 1) · \(VoidWorld.name(level))"
            if level > record.deepest {
                let oldRank = record.rank
                record.deepest = level
                save()
                if record.rank != oldRank {
                    show(Banner(title: "New rank · \(record.rank)", detail: "\(name). Deeper than you've ever been.", tone: .reward), for: 6)
                } else {
                    show(Banner(title: "New deepest · \(name)", detail: "Past your best. Every world from here is new.", tone: .reward), for: 5)
                }
            } else if active == nil {
                show(Banner(title: name, detail: "You've crossed into a new world.", tone: .reward), for: 4)
            }
            sessionBest = max(sessionBest, level)
        }

        // the running challenge
        if var a = active {
            if reading {
                a.elapsed += dt
                switch a.kind {
                case .heart:
                    a.held = Double(max(0, p.heartDrop - a.startDrop))
                case .center:
                    a.held = p.lock > 0.55 ? a.held + dt : max(0, a.held - 2 * dt)
                case .soft:
                    a.held = p.tension < 0.25 ? a.held + dt : max(0, a.held - 2 * dt)
                case .mellow:
                    a.held = p.verdict == .mellow ? a.held + dt : max(0, a.held - 2 * dt)
                }
            }
            if a.held >= a.need {
                active = nil
                cleared += 1
                record.challengesWon += 1
                save()
                engine.boost(15)
                field.reward(seconds: 25)
                show(Banner(title: "Challenge cleared", detail: "Speed surge and a rare color world.", tone: .reward), for: 5)
                nextChallenge = sessionSeconds + Double.random(in: 180...240)
            } else if a.elapsed >= a.limit {
                active = nil
                show(Banner(title: "Close", detail: "No loss. Another one comes soon.", tone: .info), for: 3)
                nextChallenge = sessionSeconds + Double.random(in: 180...240)
            } else {
                active = a
                let b = Banner(id: banner?.id ?? UUID(), title: a.title, detail: a.detail, tone: .challenge,
                               progress: min(1, a.held / a.need), secondsLeft: Int((a.limit - a.elapsed).rounded(.up)))
                if clock >= bannerUntil { banner = b }
            }
            return
        }

        if banner != nil && clock >= bannerUntil {
            withAnimation(.easeInOut(duration: 0.5)) { banner = nil }
        }

        // start a challenge when the time comes and you're settled in
        if reading && p.verdict != .learning && sessionSeconds >= nextChallenge && clock >= bannerUntil {
            start(heartOK: p.heart != nil, drop: p.heartDrop)
        }
    }

    private func start(heartOK: Bool, drop: Int) {
        var kinds = Kind.allCases.filter { $0 != lastKind }
        if !heartOK { kinds.removeAll { $0 == .heart } }
        guard let k = kinds.randomElement() else { return }
        lastKind = k
        let a: Active
        switch k {
        case .heart:
            a = Active(kind: k, title: "Slow your heart by 5 beats", detail: "Breathe out longer than you breathe in.",
                       limit: 75, need: 5, startDrop: drop)
        case .center:
            a = Active(kind: k, title: "Hold the center for 30 seconds", detail: "Rest your eyes on it. Let everything else blur.",
                       limit: 75, need: 30)
        case .soft:
            a = Active(kind: k, title: "Soften your face for 20 seconds", detail: "Let your jaw hang loose and your brow go smooth.",
                       limit: 60, need: 20)
        case .mellow:
            a = Active(kind: k, title: "Stay mellow for 45 seconds", detail: "Easy and soft. No effort.",
                       limit: 90, need: 45)
        }
        active = a
        withAnimation(.easeInOut(duration: 0.4)) {
            banner = Banner(title: a.title, detail: a.detail, tone: .challenge, progress: 0, secondsLeft: Int(a.limit))
        }
        bannerUntil = clock
    }

    private func begin() {
        sessionSeconds = 0
        level = 0
        sessionBest = 0
        startDeepest = record.deepest
        cleared = 0
        active = nil
        nextChallenge = 90
        banner = nil
        lastDive = nil
    }

    private func end() {
        active = nil
        banner = nil
        record.sessions += 1
        record.totalSeconds += sessionSeconds
        if sessionSeconds >= 180 {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.dateFormat = "yyyy-MM-dd"
            let today = f.string(from: Date())
            let yesterday = f.string(from: Date().addingTimeInterval(-86_400))
            if record.lastDiveDay == today {
            } else if record.lastDiveDay == yesterday {
                record.streak += 1
            } else {
                record.streak = 1
            }
            record.lastDiveDay = today
        }
        save()
        if sessionSeconds >= 20 {
            lastDive = DiveSummary(minutes: Int((sessionSeconds / 60).rounded()), world: sessionBest,
                                   cleared: cleared, newBest: sessionBest > startDeepest)
        }
    }
}
