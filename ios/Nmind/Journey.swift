import Combine
import SwiftUI

// Rewards, challenges and progression.
//
// Rewards: crossing into a new world blooms the void and names the world; passing your deepest
// point ever is called out. Challenges: every few minutes a short one appears; clearing it gives
// a speed surge and a rare color world, missing it costs nothing. They come about once a minute
// and climb a calm ladder: steady eyes and head first, then a soft face, then a slower heart. Progression: rank, daily
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

/// The card shown when a session ends.
struct SessionSummary {
    var seconds = 0.0          // the whole session, start to finish
    var planned = 0            // minutes chosen, 0 for open
    var completed = false      // ran to the end of the chosen time
    var focus = 0.0            // average focus while your face was in view, 0 to 1
    var mellowSeconds = 0.0
    var longestMellow = 0.0
    var world = 0
    var newBest = false
    var cleared = 0
    var pulseStart: Int?
    var pulseEnd: Int?
    var dives = 0
    var bookSeconds = 0.0
    var bookWords = 0
    var bookMode = ""          // "Deep Listen" or "Lab test at 3x"
    var quizLine: String?
    var bookDetail: String?    // the 14x run's own account: words, speed, how it was reached
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
    @Published var summary: SessionSummary?
    /// the book feed check, shown before the summary
    @Published var quiz: BookQuiz?
    /// session length in minutes; 0 runs until you stop
    @Published var plannedMinutes: Int {
        didSet { UserDefaults.standard.set(plannedMinutes, forKey: Journey.minutesKey) }
    }
    /// seconds left in a timed session, or seconds so far in an open one
    @Published private(set) var clockText = ""
    /// 1 during a session, easing to 0 over its last 20 seconds
    private(set) var fade = 1.0
    static let lengths = [3, 5, 10, 20, 0]
    private static let minutesKey = "nmind.minutes.v1"
    private static let fadeLen = 20.0
    static func mmss(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private enum Kind: CaseIterable { case center, still, soft, mellow, heart }
    private struct Active {
        var kind: Kind
        var title: String
        var detail: String
        var limit: Double
        var need: Double
        var elapsed = 0.0
        var held = 0.0
        var startDrop = 0
        var limitValue = 0.0
    }

    private static let key = "nmind.record.v1"
    private var wasRunning = false
    private var sessionSeconds = 0.0
    private var level = 0
    private var sessionBest = 0
    private var startDeepest = 0
    private var cleared = 0
    private var nextChallenge = 30.0
    private var divesSeen = 0
    /// calm ladder: each challenge cleared this dive asks for a little more calm
    private var tier = 0
    private var active: Active?
    private var bannerUntil = 0.0
    private var clock = 0.0
    private var lastKind: Kind?
    private var wasSteering = false, steerCount = 0
    private var elapsed = 0.0, focusSum = 0.0, mellowSeconds = 0.0, mellowRun = 0.0, longestMellow = 0.0
    private var pulseStart: Int?, pulseEnd: Int?
    private var finishedOnTime = false, fadeShown = false

    init() {
        if let d = UserDefaults.standard.data(forKey: Journey.key),
           let r = try? JSONDecoder().decode(Record.self, from: d) {
            record = r
        } else {
            record = Record()
        }
        let m = UserDefaults.standard.object(forKey: Journey.minutesKey) as? Int ?? 10
        plannedMinutes = Journey.lengths.contains(m) ? m : 10
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
        // the eye calibration is not part of the dive
        let running = engine.running && !engine.calibrating
        if running && !wasRunning { begin() }
        if !running && wasRunning { end() }
        wasRunning = running
        guard running else { return }

        let p = engine.panel
        let reading = p.mode == .reading
        if reading { sessionSeconds += dt }

        // the session clock runs on real time; a timed session fades over its last 20 seconds and ends itself
        elapsed += dt
        let total = Double(plannedMinutes) * 60
        if plannedMinutes > 0 {
            let left = max(0, total - elapsed)
            fade = min(1, left / Journey.fadeLen)
            let secs = Int(left.rounded(.up))
            clockText = String(format: "%d:%02d left", secs / 60, secs % 60)
            if left <= Journey.fadeLen && !fadeShown {
                fadeShown = true
                active = nil
                show(Banner(title: "Coming back", detail: "Let the light fade. Stay soft for these last breaths.", tone: .info), for: Journey.fadeLen + 2)
            }
            if left <= 0 {
                finishedOnTime = true
                engine.stop()
                return
            }
        } else {
            fade = 1
            let secs = Int(elapsed)
            clockText = String(format: "%d:%02d", secs / 60, secs % 60)
        }
        if reading {
            focusSum += p.F * dt
            if p.verdict == .mellow {
                mellowSeconds += dt
                mellowRun += dt
                longestMellow = max(longestMellow, mellowRun)
            } else {
                mellowRun = 0
            }
            if let h = p.heart, sessionSeconds > 20 {
                if pulseStart == nil { pulseStart = h }
                pulseEnd = h
            }
        }
        // the book feed test, when it's switched on
        let book = BookFeed.shared
        let calmNow = reading && engine.live.F > 0.55 && (p.verdict == .mellow || p.verdict == .settling)
        switch book.tick(dt: dt, reading: reading, calm: calmNow) {
        case .started:
            if book.sessionMode == .listen {
                show(Banner(title: "Deep Listen", detail: "\(BookText.title), from where you left off. Let the words come to you.", tone: .info), for: 4)
            } else if book.sessionMode == .whole {
                show(Banner(title: "Book 14x", detail: "The whole book, faster than words. Let it pour past.", tone: .info), for: 3)
            } else {
                show(Banner(title: "Lab test", detail: "\(BookText.title) at \(speedLabel(book.speed)). Let it wash past, there's nothing to follow.", tone: .info), for: 4)
            }
        case .finished:
            show(Banner(title: book.sessionMode == .listen ? "Deep Listen complete" : book.sessionMode == .whole ? "Book 14x complete" : "Lab feed complete",
                        detail: "A short quiz comes when you end the session. Stay as long as you like.", tone: .info), for: 4)
        case .none:
            break
        }

        // dives: each one that starts gets its own rush of sound
        let live = engine.live
        if live.dives > divesSeen { divesSeen = live.dives; Soundscape.shared.dive() }
        Soundscape.shared.update(focus: live.F, mellow: p.mellow, deep: VoidWorld.deep(field.Z),
                                 reading: reading, fade: fade,
                                 drive: min(1, max(0, live.travel) / 0.5), surge: live.surge,
                                 duck: book.level * (book.sessionMode == .listen ? 2 : 1))

        // a new world
        if p.depth > level {
            level = p.depth
            field.bloom()
            Soundscape.shared.world(level)
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

        // eye steering: say so the first time it unlocks, and briefly when it comes back
        let steering = engine.live.steering
        if steering && !wasSteering {
            steerCount += 1
            Soundscape.shared.steer()
            if steerCount == 1 {
                show(Banner(title: "You're steering", detail: "Look where you want to go. Tap a spot you're looking at to tune it.", tone: .info), for: 5)
            } else {
                show(Banner(title: "Steering again", detail: "Your focus is back, so the center follows your eyes.", tone: .info), for: 3)
            }
        }
        wasSteering = steering

        // the running challenge
        if var a = active {
            if reading {
                a.elapsed += dt
                switch a.kind {
                case .heart:
                    a.held = Double(max(0, p.heartDrop - a.startDrop))
                case .center:
                    a.held = p.lock > 0.55 ? a.held + dt : max(0, a.held - 2 * dt)
                case .still:
                    a.held = p.still > 0.75 ? a.held + dt : max(0, a.held - 2 * dt)
                case .soft:
                    a.held = p.tension < a.limitValue ? a.held + dt : max(0, a.held - 2 * dt)
                case .mellow:
                    a.held = p.verdict == .mellow ? a.held + dt : max(0, a.held - 2 * dt)
                }
            }
            if a.held >= a.need {
                active = nil
                cleared += 1
                tier += 1
                record.challengesWon += 1
                save()
                engine.boost(min(25, 10 + 2 * Double(tier)))
                Soundscape.shared.cleared()
                field.reward(seconds: min(40, 15 + 3 * Double(tier)))
                show(Banner(title: "Calm \(tier) cleared", detail: "Speed surge and a rare color world. The next one asks for a little more.", tone: .reward), for: 5)
                nextChallenge = sessionSeconds + Double.random(in: 25...40)
            } else if a.elapsed >= a.limit {
                active = nil
                show(Banner(title: "Close", detail: "No loss. Another one comes in a moment.", tone: .info), for: 3)
                nextChallenge = sessionSeconds + 30
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
        // no new challenge in the last minute and a quarter of a timed session
        let roomLeft = plannedMinutes == 0 || total - elapsed > 75
        if reading && roomLeft && !BookFeed.shared.isFeeding && p.verdict != .learning && sessionSeconds >= nextChallenge && clock >= bannerUntil {
            start(heartOK: p.heart != nil, drop: p.heartDrop)
        }
    }

    private func start(heartOK: Bool, drop: Int) {
        // a calming arc: first steady the eyes and head, then soften, then slow the heart
        var kinds: [Kind]
        switch tier {
        case 0...1: kinds = [.center, .still]
        case 2...3: kinds = [.soft, .mellow, .still]
        default: kinds = [.mellow, .soft, .heart]
        }
        if tier >= 2 { kinds.append(.heart) }
        if !heartOK { kinds.removeAll { $0 == .heart } }
        if kinds.count > 1 { kinds.removeAll { $0 == lastKind } }
        guard let k = kinds.randomElement() else { return }
        lastKind = k
        let t = Double(tier)
        let hold = min(60, 15 + 5 * t)                  // 15 s, 20 s, 25 s ... up to a minute
        let level = "Calm \(tier + 1) · "
        var a: Active
        switch k {
        case .center:
            a = Active(kind: k, title: level + "Hold the center \(Int(hold))s", detail: "Rest your eyes on it. Let everything else blur.",
                       limit: hold * 2 + 15, need: hold)
        case .still:
            a = Active(kind: k, title: level + "Be completely still \(Int(hold))s", detail: "Let your head rest. Only your breath moves.",
                       limit: hold * 2 + 15, need: hold)
        case .soft:
            a = Active(kind: k, title: level + "Soften your face \(Int(hold))s", detail: "Jaw loose, brow smooth, eyes soft.",
                       limit: hold * 2 + 15, need: hold)
            a.limitValue = max(0.12, 0.25 - 0.02 * t)   // softer each time
        case .mellow:
            let m = min(90, 20 + 8 * t)
            a = Active(kind: k, title: level + "Stay mellow \(Int(m))s", detail: "Easy and soft. No effort at all.",
                       limit: m * 2 + 15, need: m)
        case .heart:
            let beats = min(8, 3 + tier / 2)
            a = Active(kind: k, title: level + "Slow your heart by \(beats)", detail: "Breathe out longer than you breathe in.",
                       limit: 60 + 5 * t, need: Double(beats), startDrop: drop)
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
        tier = 0
        active = nil
        nextChallenge = 30
        divesSeen = 0
        BookFeed.shared.sessionBegan()
        banner = nil
        lastDive = nil
        wasSteering = false
        steerCount = 0
        elapsed = 0; focusSum = 0; mellowSeconds = 0; mellowRun = 0; longestMellow = 0
        pulseStart = nil; pulseEnd = nil
        finishedOnTime = false; fadeShown = false
        fade = 1
        summary = nil
        quiz = nil
        clockText = ""
        Soundscape.shared.begin()
    }

    /// The quiz is done: its score goes on the summary.
    func finishQuiz(correct: Int, total: Int) {
        summary?.quizLine = "Quiz: \(correct) of \(total) right (guessing gets about \(total / 2))"
        quiz = nil
    }

    func skipQuiz() { quiz = nil }

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
            summary = SessionSummary(seconds: elapsed, planned: plannedMinutes, completed: finishedOnTime,
                                     focus: sessionSeconds > 0 ? focusSum / sessionSeconds : 0,
                                     mellowSeconds: mellowSeconds, longestMellow: longestMellow,
                                     world: sessionBest, newBest: sessionBest > startDeepest, cleared: cleared,
                                     pulseStart: sessionSeconds >= 60 ? pulseStart : nil,
                                     pulseEnd: sessionSeconds >= 60 ? pulseEnd : nil,
                                     dives: divesSeen,
                                     bookSeconds: BookFeed.shared.fedSeconds, bookWords: BookFeed.shared.wordsFed,
                                     bookMode: BookFeed.shared.sessionMode == .listen ? "Deep Listen at \(speedLabel(BookFeed.shared.speed))"
                                         : BookFeed.shared.sessionMode == .whole ? "Book 14x"
                                         : "Lab test at \(speedLabel(BookFeed.shared.speed))",
                                     bookDetail: BookFeed.shared.wholeReport)
            if BookFeed.shared.fedSeconds >= 20 { quiz = BookQuiz.make(feed: BookFeed.shared) }
        }
        BookFeed.shared.sessionEnded()
        fade = 1
        Soundscape.shared.end()
    }
}
