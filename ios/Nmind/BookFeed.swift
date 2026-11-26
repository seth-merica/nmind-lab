import AVFoundation
import Combine

/// The book feed, an optional add-on to the calm dive.
///
/// Pick a speed on the start screen: A 1.5x, B 2x, C 4x, D 14x, or E, any speed up to 20x, or
/// Chapter, one whole chapter in three minutes. Once you settle, the book plays for three minutes of
/// feed time under the music, with its words coming through the tunnel, and a quiz follows.
///
/// Every word is spoken whole by the phone's own voice: nothing is sped up after the voice has made
/// it, so no sound is cut out and the pitch never rises. Up to the voice's own top rate (measured on
/// this phone) one voice reads straight through. Faster than that, the book becomes a chant: each
/// word is spoken whole by a low voice and the words start one after another in exact book order,
/// overlapping like monks chanting in a staggered round (see Chant).
///
/// The voices are made on the phone and played through the same audio engine as the music. Nothing
/// is recorded or sent.
final class BookFeed: ObservableObject {
    static let shared = BookFeed()
    static let testSeconds = 180.0
    static let maxSpeed = 20.0
    private static let choiceKey = "nmind.bookfeed.choice.v1", customKey = "nmind.bookfeed.custom.v1"
    private static let bookKey = "nmind.bookfeed.book.v1"

    enum Choice: String, CaseIterable {
        case off, a, b, c, d, e, chapter
        var label: String {
            switch self {
            case .off: return "Off"
            case .a: return "A 1.5x"
            case .b: return "B 2x"
            case .c: return "C 4x"
            case .d: return "D 14x"
            case .e: return "E custom"
            case .chapter: return "Chapter"
            }
        }
        var preset: Double? {
            switch self {
            case .a: return 1.5
            case .b: return 2
            case .c: return 4
            case .d: return 14
            default: return nil
            }
        }
    }
    /// How the words look in the tunnel: readable, faint and turning, or a fast unreadable stream.
    enum Look { case clear, lab, flash }
    enum State { case off, waiting, feeding, paused, done }
    enum Event { case none, started, finished }

    @Published var choice: Choice { didSet { UserDefaults.standard.set(choice.rawValue, forKey: BookFeed.choiceKey) } }
    /// E's saved speed
    @Published private(set) var customSpeed: Double
    @Published private(set) var book: Book
    @Published private(set) var shelf: [BookShelf.Entry] = []
    @Published private(set) var loading = false
    @Published var loadMessage: String?
    @Published private(set) var loadFailed = false

    // MARK: the voice

    /// The deepest English voice on the phone, chosen once.
    let voice: AVSpeechSynthesisVoice?
    /// words a second this voice reads at its normal rate
    private(set) var normalWPS: Double
    /// how many times its normal speed the voice reads at its own top rate, every sound still spoken
    private(set) var topFactor: Double
    /// how the voice's middle rates land against the simple model, learned as it reads
    private var rateBias: Double
    private(set) var measured: Bool
    private var vkey: String { voice?.identifier ?? "default" }

    // MARK: session

    private(set) var state: State = .off
    private(set) var sessionChoice: Choice = .off
    private(set) var sessionSpeed = 1.0
    private(set) var sessionLook: Look = .clear
    private(set) var sessionStamp = 0
    private(set) var fedSeconds = 0.0
    /// 0 to 1, eased: how present the feed is, for the music's ducking and the words' brightness
    private(set) var level = 0.0
    private(set) var streams: [Stream] = []
    /// chunks kept out of a run that would otherwise use up the book, so the quiz has text you never heard
    private(set) var heldOut: Set<Int> = []
    private var calmHeld = 0.0
    private var gen = 0
    private let lock = NSLock()
    /// what the screen showed: how many frames each word was drawn in
    private var frames: [Int: Int] = [:]
    private(set) var stats: Stats?

    var isFeeding: Bool { state == .feeding || state == .paused }
    var words: [String] { book.words }
    /// the speed of the choice on screen, or of the session that is running
    var speed: Double {
        if sessionChoice != .off { return sessionSpeed }
        return speed(for: choice)
    }
    func speed(for c: Choice) -> Double {
        switch c {
        case .e: return customSpeed
        case .chapter:
            guard let ch = book.chapter else { return 1 }
            return Double(ch.range.count) / BookFeed.testSeconds / normalWPS
        default: return c.preset ?? 1.5
        }
    }
    /// one voice reads straight through up to its top rate; faster than that is the chant
    func isChant(_ s: Double) -> Bool { s > topFactor + 0.01 }
    static func look(for s: Double) -> Look { s <= 2.001 ? .clear : s < 5 ? .lab : .flash }
    private(set) var startWord = 0
    /// how far the chant has reached, kept as it plays so it stays put once the voices stop
    private var chantAt = 0
    /// the chant, when the session runs faster than one voice
    private(set) var chant: Chant?
    /// the word the feed has reached, whichever way it is reading
    var cursor: Int {
        if let c = chant {
            if state == .feeding, let r = c.reached(at: c.now()) { return max(chantAt, r) }
            return chantAt
        }
        return streams.first?.wordIndex ?? startWord
    }
    var wordIndex: Int { cursor }

    private init() {
        let d = UserDefaults.standard
        let v = BookFeed.deepVoice()
        voice = v
        let key = v?.identifier ?? "default"
        let n = d.double(forKey: "nmind.bookfeed.normal.\(key)")
        normalWPS = n > 0.5 ? n : 2.9
        let t = d.double(forKey: "nmind.bookfeed.top.\(key)")
        topFactor = t >= 1.2 ? t : 2.6
        let b = d.double(forKey: "nmind.bookfeed.bias.\(key)")
        rateBias = b > 0.3 ? b : 1
        measured = n > 0.5 && t >= 1.2
        if let c = d.string(forKey: BookFeed.choiceKey), let cc = Choice(rawValue: c) {
            choice = cc
        } else {
            switch d.string(forKey: "nmind.bookfeed.mode.v1") {
            case "listen": choice = d.double(forKey: "nmind.bookfeed.listenspeed.v1") >= 2 ? .b : .a
            case "lab": choice = .c
            case "whole": choice = .d
            case "chapter": choice = .chapter
            default: choice = .off
            }
        }
        let cs = d.double(forKey: BookFeed.customKey)
        customSpeed = cs >= 1 ? min(BookFeed.maxSpeed, cs) : 8
        let id = d.string(forKey: BookFeed.bookKey) ?? BookShelf.builtInID
        book = Book(BookShelf.load(id) ?? Book.builtIn)
        shelf = BookShelf.list()
    }

    /// Prefers a male English voice of the best quality the phone has, US or UK. Novelty voices are left out.
    private static func deepVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language.hasPrefix("en") && !v.identifier.contains("speech.synthesis.voice") &&
                !v.identifier.lowercased().contains("eloquence") && !v.voiceTraits.contains(.isPersonalVoice) &&
                !v.voiceTraits.contains(.isNoveltyVoice)
        }
        let male = all.filter { $0.gender == .male }
        let pool = male.isEmpty ? all : male
        func place(_ l: String) -> Int { l == "en-US" ? 2 : l == "en-GB" ? 1 : 0 }
        return pool.max { a, b in
            (a.quality.rawValue, place(a.language)) < (b.quality.rawValue, place(b.language))
        } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    var voiceName: String { voice?.name ?? "the system voice" }

    // MARK: books

    func select(_ id: String) {
        guard !isFeeding, let s = BookShelf.load(id) else { return }
        book = Book(s)
        UserDefaults.standard.set(id, forKey: BookFeed.bookKey)
        loadMessage = nil
    }

    /// Reads a DRM-free EPUB, PDF or text file the user picked in Files. The text is kept on the
    /// phone only.
    func importBook(from url: URL) {
        guard !loading else { return }
        loading = true; loadMessage = nil; loadFailed = false
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let s = try BookLoader.load(url)
                try BookShelf.save(s)
                let b = Book(s)
                DispatchQueue.main.async {
                    self.shelf = BookShelf.list()
                    self.book = b
                    UserDefaults.standard.set(s.id, forKey: BookFeed.bookKey)
                    self.loading = false
                    let ch = b.sections.filter { $0.range.count >= 300 }.count
                    self.loadMessage = "Loaded \(b.title): \(b.words.count.formatted()) words, \(ch >= 2 ? "\(ch) chapters" : "no chapters marked")."
                }
            } catch {
                DispatchQueue.main.async {
                    self.loading = false
                    self.loadFailed = true
                    self.loadMessage = (error as? LocalizedError)?.errorDescription ?? "That file couldn't be read."
                }
            }
        }
    }

    func removeCurrent() {
        guard !isFeeding, book.id != BookShelf.builtInID else { return }
        let id = book.id
        BookShelf.remove(id)
        UserDefaults.standard.removeObject(forKey: posKey(id))
        UserDefaults.standard.removeObject(forKey: heardKey(id))
        shelf = BookShelf.list()
        select(BookShelf.builtInID)
    }

    func setCustom(_ v: Double) {
        customSpeed = min(BookFeed.maxSpeed, max(1, (v * 2).rounded() / 2))
        UserDefaults.standard.set(customSpeed, forKey: BookFeed.customKey)
    }

    private func posKey(_ id: String) -> String { "nmind.bookfeed.pos.\(id)" }
    private func heardKey(_ id: String) -> String { "nmind.bookfeed.heard.\(id)" }
    /// where the next session starts in this book
    var position: Int {
        let d = UserDefaults.standard
        if d.object(forKey: posKey(book.id)) == nil && book.id == BookShelf.builtInID {
            return d.integer(forKey: "nmind.bookfeed.listenpos.v1")
        }
        return d.integer(forKey: posKey(book.id))
    }
    /// parts of this book earlier sessions played, so quiz decoys come from text you have never heard
    var heard: [Range<Int>] {
        (UserDefaults.standard.array(forKey: heardKey(book.id)) as? [[Int]] ?? [])
            .compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]..<$0[1] : nil }
    }
    /// minutes for the whole book at a speed
    func bookMinutes(at s: Double) -> Double { Double(book.words.count) / (normalWPS * 60 * s) }

    // MARK: session

    final class Stream {
        let index: Int
        let player: AVAudioPlayerNode
        let synth = AVSpeechSynthesizer()
        /// the chunks this voice reads, in order
        let plan: [Int]
        let first: Int
        let pitch: Float
        let pan: Float
        // main thread
        var next = 0
        var cursor: Double
        // audio queue
        var queued = 0.0, writing = false
        // the voice's callback thread
        var converter: AVAudioConverter?
        // under the lock
        var timeline: [Seg] = []
        var schedEnd = 0.0
        var logs: [Int: ChunkLog] = [:]

        init(index: Int, player: AVAudioPlayerNode, plan: [Int], first: Int, pitch: Float, pan: Float) {
            self.index = index; self.player = player; self.plan = plan; self.first = first
            self.pitch = pitch; self.pan = pan; cursor = Double(first)
        }
        var wordIndex: Int { Int(cursor) }
    }
    struct Seg { var start: Double; var dur: Double; let first: Int; let count: Int; let chunk: Int; var done: Bool }
    final class ChunkLog {
        let words: Int, u: Float
        var covered = Set<Int>()
        var marks = 0
        var frames = 0, rate = 0.0
        var done = false
        init(words: Int, u: Float) { self.words = words; self.u = u }
    }
    /// What the end card reports: the passage, what the voices spoke and what the screen drew.
    struct Stats {
        var passage = 0, spoken = 0, drawn = 0, minFrames = 0
        var marks = 0
        var voices = 1
        var perVoice = 0.0      // times normal speed, as measured
        var inOrder = true
        var overlap = 1.0       // words sounding at once, on average
        var total = 0.0
        var wpm = 0.0
    }

    func sessionBegan() {
        stopAudio()
        sessionStamp += 1
        chant?.halt(); chant = nil
        streams = []; heldOut = []; frames = [:]; stats = nil
        fedSeconds = 0; level = 0; calmHeld = 0
        sessionChoice = choice
        let chunks = book.chunks
        guard choice != .off, !chunks.isEmpty, !(choice == .chapter && book.chapter == nil) else {
            sessionChoice = .off; state = .off; return
        }
        sessionSpeed = speed(for: choice)
        sessionLook = BookFeed.look(for: sessionSpeed)
        var list: [Int]
        var target: Int
        if choice == .chapter, let ch = book.chapter {
            list = chunks.indices.filter { chunks[$0].first >= ch.range.lowerBound && chunks[$0].first < ch.range.upperBound }
            target = Int.max
        } else {
            var k = chunks.lastIndex { $0.first <= position } ?? 0
            if chunks[k].first > book.words.count - 60 { k = 0 }
            list = Array(k..<chunks.count)
            target = Int(sessionSpeed * normalWPS * BookFeed.testSeconds * 1.05) + 30
            // if this run would use up the rest of the book, hold four short passages back for the quiz
            let ahead = book.words.count - chunks[k].first
            if ahead < target + 400 && list.count >= 10 {
                heldOut = Set([0.2, 0.4, 0.6, 0.8].map { list[min(list.count - 2, max(1, Int(Double(list.count) * $0)))] })
                list.removeAll { heldOut.contains($0) }
            }
        }
        var take: [Int] = [], sum = 0
        for c in list {
            take.append(c); sum += chunks[c].count
            if sum >= target { break }
        }
        startWord = chunks[take[0]].first
        chantAt = startWord
        let low = sessionSpeed > 2.001
        if isChant(sessionSpeed) {
            let ws = take.flatMap { k in Array(chunks[k].first..<(chunks[k].first + chunks[k].count)) }
                .filter { BookFeed.isWord(book.words[$0]) && !Chant.clean(book.words[$0]).isEmpty }
            chant = Chant(list: ws, words: book.words, target: sessionSpeed * normalWPS, voice: voice, pitch: 0.75)
        } else {
            streams = [Stream(index: 0, player: Soundscape.shared.bookPlayer, plan: take, first: startWord,
                              pitch: low ? 0.8 : 1.0, pan: 0)]
        }
        state = .waiting
    }

    func sessionEnded() {
        if isFeeding {
            if let c = chant, let r = c.reached(at: c.now()) { chantAt = max(chantAt, r) }
            stats = makeStats()
        }
        if isFeeding { stopAudio() }
        let d = UserDefaults.standard
        if sessionChoice != .off && wordsFed > 0 {
            let at = cursor
            if sessionChoice != .chapter {
                d.set(at >= book.words.count - 60 ? 0 : at, forKey: posKey(book.id))
            }
            var h = d.array(forKey: heardKey(book.id)) as? [[Int]] ?? []
            if at > startWord { h.append([startWord, at]) }
            d.set(h, forKey: heardKey(book.id))
        }
        if state != .done { state = .off }
    }

    func inHeldOut(_ w: Int) -> Bool {
        heldOut.contains { book.chunks[$0].first <= w && w < book.chunks[$0].first + book.chunks[$0].count }
    }
    var heldOutWords: Int { heldOut.reduce(0) { $0 + book.chunks[$1].count } }
    /// word positions in the held back chunks, for quiz decoys
    var heldOutIndices: [Int] { heldOut.sorted().flatMap { k in Array(book.chunks[k].first..<(book.chunks[k].first + book.chunks[k].count)) } }
    private func heldBetween(_ a: Int, _ b: Int) -> Int {
        heldOut.reduce(0) { sum, k in
            let c = book.chunks[k]
            return sum + max(0, min(b, c.first + c.count) - max(a, c.first))
        }
    }

    /// Words fed so far this session, across all the voices.
    var wordsFed: Int {
        let c = cursor
        return max(0, c - startWord - heldBetween(startWord, c))
    }
    /// The words that actually played.
    var playedRange: Range<Int> { startWord..<max(startWord, cursor) }

    /// Called four times a second while a dive runs.
    func tick(dt: Double, reading: Bool, calm: Bool) -> Event {
        var ev = Event.none
        switch state {
        case .off, .done:
            break
        case .waiting:
            calmHeld = calm ? calmHeld + dt : max(0, calmHeld - dt)
            if calmHeld > 6 { startAudio(); state = .feeding; ev = .started }
        case .feeding:
            if !reading { pauseAudio(); state = .paused; break }
            fedSeconds += dt
            for s in streams {
                if let at = playedPosition(s) { s.cursor = max(s.cursor, at) }
                pump(s)
            }
            if let c = chant {
                c.make()
                sound.audioQ.async { c.schedule() }
                if let r = c.reached(at: c.now()) { chantAt = max(chantAt, r) }
            }
            let limit = sessionChoice == .chapter ? BookFeed.testSeconds * 1.25 : BookFeed.testSeconds
            let over = chant.map { $0.finished } ?? streams.allSatisfy(finished)
            if fedSeconds >= limit || (fedSeconds > 3 && over) {
                stats = makeStats()
                finishAudio(); state = .done; ev = .finished
            }
        case .paused:
            if reading { resumeAudio(); state = .feeding }
        }
        let want = state == .feeding ? 1.0 : 0.0
        level += (want - level) * min(1, dt / 1.5)
        return ev
    }

    /// Where a voice has reached, in words, from what its player has played.
    private func playedPosition(_ s: Stream) -> Double? {
        guard let at = playerSeconds(s.player) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let seg = s.timeline.last(where: { $0.start <= at }) else { return nil }
        let f = min(1, max(0, (at - seg.start) / max(0.05, seg.dur)))
        // while a chunk is still arriving its length isn't known yet, so hold short of its end
        let frac = seg.done ? f : min(f, 0.9)
        return Double(seg.first) + Double(seg.count) * frac
    }

    private func finished(_ s: Stream) -> Bool {
        guard s.next >= s.plan.count, let at = playerSeconds(s.player) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let last = s.timeline.last, last.done else { return false }
        return at >= last.start + last.dur - 0.05
    }

    private func playerSeconds(_ p: AVAudioPlayerNode) -> Double? {
        guard let nt = p.lastRenderTime, nt.isSampleTimeValid,
              let pt = p.playerTime(forNodeTime: nt), pt.isSampleTimeValid, pt.sampleRate > 0 else { return nil }
        return Double(pt.sampleTime) / pt.sampleRate
    }

    /// The screen calls this for every word it draws, each frame.
    func markDrawn(_ i: Int) { frames[i, default: 0] += 1 }

    static func isWord(_ w: String) -> Bool { w.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }

    /// Counts over the chunks that played all the way through: the words in them, the words the voice
    /// marked as spoken, and the words the screen drew.
    private func makeStats() -> Stats {
        var st = Stats()
        var minF = Int.max
        func count(_ i: Int, spoken: Bool) {
            st.passage += 1
            if spoken { st.spoken += 1 }
            let f = frames[i] ?? 0
            if f > 0 { st.drawn += 1 }
            minF = min(minF, f)
        }
        if let c = chant {
            let done = c.done(at: c.now())
            for o in done {
                st.marks += o.marks
                count(o.word, spoken: o.marks > 0)
            }
            st.voices = c.voicesUsed
            st.perVoice = topFactor
            st.inOrder = c.inOrder
            st.overlap = c.target * c.averageWord
        } else {
            var secs = 0.0, spokenWords = 0
            for s in streams {
                let at = playerSeconds(s.player) ?? 0
                lock.lock()
                let segs = s.timeline.filter { $0.done && $0.start + $0.dur <= at + 0.05 }
                let logs = s.logs
                lock.unlock()
                for seg in segs {
                    let log = logs[seg.chunk]
                    st.marks += log?.marks ?? 0
                    if let l = log, l.rate > 0 { secs += Double(l.frames) / l.rate; spokenWords += l.words }
                    for i in seg.first..<(seg.first + seg.count) where BookFeed.isWord(book.words[i]) {
                        count(i, spoken: log?.covered.contains(i) ?? false)
                    }
                }
            }
            if secs > 0 { st.perVoice = Double(spokenWords) / secs / normalWPS }
        }
        st.minFrames = minF == Int.max ? 0 : minF
        if fedSeconds > 5 {
            st.wpm = Double(wordsFed) / fedSeconds * 60
            st.total = st.wpm / (normalWPS * 60)
        }
        return st
    }

    /// A plain account of the run for the end card.
    var report: String? {
        guard sessionChoice != .off, fedSeconds > 5, let st = stats else { return nil }
        var parts: [String] = []
        if sessionChoice == .chapter, let ch = book.chapter {
            parts.append("\(ch.title): \(wordsFed.formatted()) of \(ch.range.count.formatted()) words in \(Journey.mmss(fedSeconds)).")
        }
        let x = String(format: "%.1f", st.total), each = String(format: "%.1f", st.perVoice)
        if chant != nil {
            parts.append("Chant at \(x)x (\(Int(st.wpm.rounded()).formatted()) words a minute): each word spoken whole at the voice's top rate, \(each)x, about \(String(format: "%.1f", st.overlap)) words sounding at once, up to \(st.voices) voices. \(st.inOrder ? "Every word started in book order." : "Some words started out of order.")")
        } else {
            parts.append("One voice at \(x)x (\(Int(st.wpm.rounded()).formatted()) words a minute).")
        }
        if st.marks > 0 {
            parts.append("Of \(st.passage.formatted()) words that played through, the voice\(st.voices > 1 ? "s" : "") spoke \(st.spoken.formatted()) and the screen drew \(st.drawn.formatted()), each word for at least \(st.minFrames) frame\(st.minFrames == 1 ? "" : "s").")
        } else {
            parts.append("Of \(st.passage.formatted()) words that played through, the screen drew \(st.drawn.formatted()), each for at least \(st.minFrames) frames. This voice gave no word marks, so spoken words couldn't be counted.")
        }
        if sessionChoice != .chapter {
            parts.append("\(book.title) is \(Int((Double(cursor) / Double(max(1, book.words.count)) * 100).rounded()))% read.")
        }
        if !heldOut.isEmpty { parts.append("\(heldOutWords) words were held back for the quiz.") }
        return parts.joined(separator: " ")
    }

    // MARK: speech rate

    /// How many times normal speed the voice reads at a given rate setting, from the measured top rate.
    private func model(_ u: Float) -> Double {
        u >= 0.5 ? pow(topFactor, Double(u - 0.5) / 0.5) : pow(0.5, Double(0.5 - u) / 0.5)
    }

    /// The voice's own rate setting for a speed. No speed-up is ever added after the voice.
    func utteranceRate(for v: Double) -> Float {
        if v >= topFactor - 0.02 { return AVSpeechUtteranceMaximumSpeechRate }
        if abs(v - 1) < 0.02 { return AVSpeechUtteranceDefaultSpeechRate }
        let w = v / rateBias
        let u = w >= 1 ? 0.5 + 0.5 * log(w) / log(topFactor) : 0.5 - 0.5 * log(w) / log(0.5)
        return Float(min(1, max(0, u)))
    }

    /// Learns the voice's real speed from a piece it has finished reading.
    private func learn(words: Int, seconds: Double, u: Float) {
        guard words >= 20, seconds > 0.8 else { return }
        let wps = Double(words) / seconds
        let d = UserDefaults.standard
        if u == AVSpeechUtteranceDefaultSpeechRate {
            normalWPS = measured ? normalWPS * 0.6 + wps * 0.4 : wps
            d.set(normalWPS, forKey: "nmind.bookfeed.normal.\(vkey)")
        } else if u >= AVSpeechUtteranceMaximumSpeechRate {
            let f = min(6, max(1.2, wps / normalWPS))
            topFactor = topFactor * 0.6 + f * 0.4
            d.set(topFactor, forKey: "nmind.bookfeed.top.\(vkey)")
        } else {
            let f = wps / normalWPS
            rateBias = min(2, max(0.5, rateBias * 0.6 + f / model(u) * 0.4))
            d.set(rateBias, forKey: "nmind.bookfeed.bias.\(vkey)")
        }
    }

    // MARK: audio

    private var sound: Soundscape { Soundscape.shared }

    private func startAudio() {
        let low = sessionSpeed > 2.001
        let vol: Float = low ? 0.9 : 1.0
        let all = streams
        if let c = chant {
            c.make()
            sound.audioQ.async {
                self.gen += 1
                self.sound.styleBook(chant: true)
                c.start(volume: 0.55)
                c.schedule()
            }
            return
        }
        sound.audioQ.async {
            self.gen += 1
            self.sound.styleBook(chant: low)
            for s in all {
                s.queued = 0; s.writing = false
                self.lock.lock(); s.timeline = []; s.schedEnd = 0; self.lock.unlock()
                s.player.stop()
                s.player.pan = s.pan
                s.player.volume = 0
                if self.sound.engine.isRunning { s.player.play() }
                self.rampVolume(s.player, to: vol, over: 2.5)
            }
        }
        for s in streams { pump(s) }
    }

    private func pauseAudio() {
        let all = streams, c = chant
        sound.audioQ.async { for s in all { s.player.pause() }; c?.pause() }
    }
    private func resumeAudio() {
        let all = streams, c = chant
        sound.audioQ.async { if self.sound.engine.isRunning { for s in all { s.player.play() } }; c?.resume() }
    }

    private func finishAudio() {
        let all = streams
        let players = chant != nil ? Array(sound.bookPlayers) : all.map { $0.player }
        chant?.halt()
        sound.audioQ.async {
            for p in players { self.rampVolume(p, to: 0, over: 3) }
            let g = self.gen
            self.sound.audioQ.asyncAfter(deadline: .now() + 3.2) {
                guard self.gen == g else { return }
                self.gen += 1
                for p in players { p.stop() }
                for s in all { s.queued = 0; s.writing = false }
            }
        }
        for s in streams where s.synth.isSpeaking { s.synth.stopSpeaking(at: .immediate) }
    }

    private func stopAudio() {
        for s in streams where s.synth.isSpeaking { s.synth.stopSpeaking(at: .immediate) }
        chant?.halt()
        let all = streams
        let players = Array(sound.bookPlayers)
        sound.audioQ.async {
            self.gen += 1
            for p in players { p.stop(); p.volume = 0 }
            for s in all { s.queued = 0; s.writing = false }
        }
    }

    /// Runs on the audio queue: steps a player's volume toward a target.
    private func rampVolume(_ p: AVAudioPlayerNode, to v: Float, over seconds: Double) {
        let start = p.volume, steps = 20
        let g = gen
        for i in 1...steps {
            sound.audioQ.asyncAfter(deadline: .now() + seconds * Double(i) / Double(steps)) {
                guard self.gen == g else { return }
                p.volume = start + (v - start) * Float(i) / Float(steps)
            }
        }
    }

    /// Keeps about eight seconds of speech queued ahead of each voice.
    private func pump(_ s: Stream) {
        sound.audioQ.async {
            guard !s.writing, s.queued < 8 else { return }
            s.writing = true
            let g = self.gen
            DispatchQueue.main.async { self.writeNext(s, gen: g) }
        }
    }

    private func writeNext(_ s: Stream, gen g: Int) {
        guard isFeeding, s.next < s.plan.count else {
            sound.audioQ.async { s.writing = false }
            return
        }
        let k = s.plan[s.next]
        s.next += 1
        let chunk = book.chunks[k]
        let u = utteranceRate(for: sessionSpeed)
        let utt = AVSpeechUtterance(string: chunk.text)
        utt.voice = voice
        utt.rate = u
        utt.pitchMultiplier = s.pitch
        utt.volume = 1
        utt.preUtteranceDelay = 0; utt.postUtteranceDelay = 0
        let log = ChunkLog(words: chunk.count, u: u)
        lock.lock(); s.logs[k] = log; lock.unlock()
        // where each word sits in the text, to match the voice's word marks to the book's words
        var starts: [Int] = [], ends: [Int] = [], cum = 0
        for w in book.words[chunk.first..<(chunk.first + chunk.count)] {
            starts.append(cum); cum += w.utf16.count; ends.append(cum); cum += 1
        }
        let first = chunk.first
        s.synth.write(utt, toBufferCallback: { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                self.sound.audioQ.async {
                    guard self.gen == g else { return }
                    s.writing = false
                    self.lock.lock()
                    if let i = s.timeline.lastIndex(where: { $0.chunk == k }) { s.timeline[i].done = true }
                    log.done = true
                    let secs = log.rate > 0 ? Double(log.frames) / log.rate : 0
                    self.lock.unlock()
                    DispatchQueue.main.async { self.learn(words: log.words, seconds: secs, u: log.u) }
                }
                return
            }
            self.lock.lock(); log.frames += Int(pcm.frameLength); log.rate = pcm.format.sampleRate; self.lock.unlock()
            guard let out = BookFeed.convert(pcm, with: &s.converter, to: Soundscape.bookFormat) else { return }
            let secs = Double(out.frameLength) / Soundscape.bookFormat.sampleRate
            self.sound.audioQ.async {
                guard self.gen == g else { return }
                s.queued += secs
                // note where this piece lands on the player's clock (after any gap if it ran dry)
                let now = self.playerSeconds(s.player) ?? 0
                self.lock.lock()
                if s.schedEnd < now { s.schedEnd = now }
                if let i = s.timeline.indices.last, s.timeline[i].chunk == k {
                    s.timeline[i].dur += secs
                } else {
                    s.timeline.append(Seg(start: s.schedEnd, dur: secs, first: first, count: chunk.count, chunk: k, done: false))
                }
                s.schedEnd += secs
                self.lock.unlock()
                s.player.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { _ in
                    self.sound.audioQ.async { if self.gen == g { s.queued = max(0, s.queued - secs) } }
                }
            }
        }, toMarkerCallback: { [weak self] markers in
            guard let self else { return }
            self.lock.lock()
            for m in markers where m.mark == .word {
                log.marks += 1
                let r = m.textRange
                for j in starts.indices where starts[j] < r.location + max(1, r.length) && r.location < ends[j] {
                    log.covered.insert(first + j)
                }
            }
            self.lock.unlock()
        })
    }

    // MARK: the sample and the proof

    @Published private(set) var proofStage: String?
    @Published private(set) var proofText = ""
    @Published private(set) var proofNumbers = ""
    private let sampleSynth = AVSpeechSynthesizer()
    private var sampleConverter: AVAudioConverter?

    /// Measures this voice once, quietly, so speeds and voice counts are right from the first session.
    func measureIfNeeded() {
        guard !measured, proofStage == nil, !isFeeding else { return }
        measured = true
        let text = sampleText(words: 60, from: book.words.count / 4)
        record(text, u: AVSpeechUtteranceDefaultSpeechRate, pitch: 1) { normal in
            self.learnFrom(normal, words: text.split(separator: " ").count, u: AVSpeechUtteranceDefaultSpeechRate)
            self.record(text, u: AVSpeechUtteranceMaximumSpeechRate, pitch: 1) { fast in
                self.learnFrom(fast, words: text.split(separator: " ").count, u: AVSpeechUtteranceMaximumSpeechRate)
            }
        }
    }

    private func learnFrom(_ b: [AVAudioPCMBuffer], words: Int, u: Float) {
        let secs = b.reduce(0.0) { $0 + Double($1.frameLength) } / Soundscape.bookFormat.sampleRate
        learn(words: words, seconds: secs, u: u)
        if u == AVSpeechUtteranceDefaultSpeechRate { measured = true }
    }

    private func sampleText(words n: Int, from start: Int) -> String {
        let w = book.words
        guard !w.isEmpty else { return "" }
        // start at the beginning of a sentence
        var a = min(max(0, start), max(0, w.count - n - 1))
        while a > 0 && a < w.count - 1 && !Book.endsSentence(w[a - 1]) && a > start - 80 { a -= 1 }
        return w[a..<min(w.count, a + n)].joined(separator: " ")
    }

    /// A sample chant or reading kept while it plays, so it can be stopped.
    private var sampleChant: Chant?

    /// A sample of a speed, as the session will sound, for about eight seconds.
    func runSample(speed s: Double) {
        guard proofStage == nil, !isFeeding, !book.words.isEmpty else { return }
        Soundscape.shared.wake()
        let w = book.words
        if isChant(s) {
            let n = Int(s * normalWPS * 8) + 4
            let start = sentenceStart(Int.random(in: 0..<max(1, w.count - n - 1)))
            let list = (start..<min(w.count, start + n)).filter { BookFeed.isWord(w[$0]) && !Chant.clean(w[$0]).isEmpty }
            proofText = w[start..<min(w.count, start + 40)].joined(separator: " ") + " ..."
            proofNumbers = "\(list.count) words in about 8 seconds, each spoken whole by the low voice at its top rate, starting one after another in book order."
            playChant(Chant(list: list, words: w, target: s * normalWPS, voice: voice, pitch: 0.75),
                      stage: "Sample: the chant at \(speedLabel(s))", seconds: 9)
        } else {
            let u = utteranceRate(for: s)
            let text = sampleText(words: max(12, Int(s * normalWPS * 8)), from: Int.random(in: 0..<max(1, w.count - 60)))
            proofText = text
            proofNumbers = ""
            proofStage = "Preparing the voice"
            let low = s > 2.001
            record(text, u: u, pitch: low ? 0.8 : 1) { b in
                self.learnFrom(b, words: text.split(separator: " ").count, u: u)
                let secs = b.reduce(0.0) { $0 + Double($1.frameLength) } / Soundscape.bookFormat.sampleRate
                if secs > 0.5 {
                    self.proofNumbers = "One voice speaking every word at \(String(format: "%.1f", Double(text.split(separator: " ").count) / secs / self.normalWPS))x its normal speed. Pitch kept, nothing cut."
                }
                self.playTogether([b], chant: low, stage: "Sample at \(speedLabel(s))", maxSeconds: 9)
            }
        }
    }

    /// The proof for a chant speed: the words of one sentence, each spoken whole at the voice's top
    /// rate, one after another with nothing overlapping; then the same sentence read at normal speed.
    func runProof(speed s: Double) {
        guard proofStage == nil, !isFeeding, !book.words.isEmpty else { return }
        Soundscape.shared.wake()
        let w = book.words
        let start = sentenceStart(Int.random(in: 0..<max(1, w.count - 30)))
        var end = start + 12
        while end < min(w.count, start + 30) && !Book.endsSentence(w[end - 1]) { end += 1 }
        let list = (start..<end).filter { BookFeed.isWord(w[$0]) && !Chant.clean(w[$0]).isEmpty }
        let text = w[start..<end].joined(separator: " ")
        proofText = text
        proofNumbers = "In the chant at \(speedLabel(s)) these words overlap, about \(String(format: "%.0f", max(1, s / topFactor))) at a time, but each one is this same whole word and each starts after the one before."
        let solo = Chant(list: list, words: w, target: 1, solo: true, voice: voice, pitch: 0.75)
        playChant(solo, stage: "1 of 2: each word alone, whole, at the voice's top rate", seconds: 20) {
            self.proofStage = "Preparing normal speed"
            self.record(text, u: AVSpeechUtteranceDefaultSpeechRate, pitch: 0.75) { b in
                self.learnFrom(b, words: text.split(separator: " ").count, u: AVSpeechUtteranceDefaultSpeechRate)
                self.playTogether([b], chant: true, stage: "2 of 2: the same sentence at normal speed", maxSeconds: 20)
            }
        }
    }

    private func sentenceStart(_ i: Int) -> Int {
        let w = book.words
        var a = min(max(0, i), max(0, w.count - 1))
        let floor = a - 120
        while a > 0 && a > floor && !Book.endsSentence(w[a - 1]) { a -= 1 }
        return a
    }

    /// Plays a sample chant until its words are done or the time runs out, then runs `after`.
    private func playChant(_ c: Chant, stage: String, seconds: Double, after: (() -> Void)? = nil) {
        sampleChant = c
        proofStage = "Preparing the voice"
        let snd = Soundscape.shared
        c.make()
        // give the voice a moment to make the first words before the chant starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.proofStage = stage
            snd.audioQ.async {
                snd.styleBook(chant: true)
                c.start(volume: c.solo ? 0.9 : 0.55)
                c.schedule()
            }
            var t = 0.0
            func step() {
                t += 0.2
                c.make()
                snd.audioQ.async { c.schedule() }
                if (c.finished && t > 1) || t >= seconds {
                    c.halt()
                    snd.audioQ.async { for p in snd.bookPlayers { p.stop(); p.volume = 0 } }
                    self.sampleChant = nil
                    if let after { after() } else {
                        self.proofStage = nil
                        snd.sleepSoon()
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: step)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: step)
        }
    }

    private func record(_ text: String, u: Float, pitch: Float, done: @escaping ([AVAudioPCMBuffer]) -> Void) {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = voice
        utt.rate = u
        utt.pitchMultiplier = pitch
        utt.preUtteranceDelay = 0; utt.postUtteranceDelay = 0
        var out: [AVAudioPCMBuffer] = []
        sampleSynth.write(utt) { [weak self] buffer in
            guard let self else { return }
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                if let b = BookFeed.convert(pcm, with: &self.sampleConverter, to: Soundscape.bookFormat) { out.append(b) }
            } else {
                DispatchQueue.main.async { done(out) }
            }
        }
    }

    /// Plays recordings on the book's players at once, styled as the session would be.
    private func playTogether(_ recs: [[AVAudioPCMBuffer]], chant: Bool, stage: String, maxSeconds: Double) {
        let snd = Soundscape.shared
        let sr = Soundscape.bookFormat.sampleRate
        let longest = recs.map { $0.reduce(0.0) { $0 + Double($1.frameLength) } / sr }.max() ?? 0
        let secs = min(longest, maxSeconds)
        let n = recs.count
        let g = gen
        proofStage = stage
        snd.audioQ.asyncAfter(deadline: .now() + 0.6) {
            snd.styleBook(chant: chant)
            let vol: Float = 1
            for (i, r) in recs.enumerated() {
                let p = snd.bookPlayers[i]
                p.stop()
                p.pan = n == 1 ? 0 : -0.7 + 1.4 * Float(i) / Float(n - 1)
                for b in r { p.scheduleBuffer(b, completionHandler: nil) }
                p.volume = vol
            }
            if snd.engine.isRunning { for i in 0..<n { snd.bookPlayers[i].play() } }
            snd.audioQ.asyncAfter(deadline: .now() + secs + 0.3) {
                for i in 0..<n {
                    let p = snd.bookPlayers[i]
                    if g == self.gen { p.stop() }
                    p.volume = 0
                }
                DispatchQueue.main.async {
                    if self.proofStage == stage { self.proofStage = nil }
                }
                snd.sleepSoon()
            }
        }
    }

    // MARK: what's on screen

    /// At easy speeds the band under the centre shows the book in short lines of seven words, in step with the voice.
    var lineWords: (spoken: String, coming: String)? {
        guard sessionLook == .clear, isFeeding, chant == nil, let s = streams.first, !book.words.isEmpty else { return nil }
        let w = book.words
        let i = min(w.count - 1, max(s.first, s.wordIndex))
        let a = s.first + ((i - s.first) / 7) * 7
        let b = min(w.count, a + 7)
        let spoken = w[a...i].joined(separator: " ")
        let coming = i + 1 < b ? w[(i + 1)..<b].joined(separator: " ") : ""
        return (spoken, coming)
    }

    /// Speech arrives in the voice's own format; the players take one fixed format. Each voice keeps
    /// its own converter, since the voices run at the same time.
    static func convert(_ pcm: AVAudioPCMBuffer, with converter: inout AVAudioConverter?, to outFmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converter!.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: outFmt)
        }
        guard let conv = converter else { return nil }
        let ratio = outFmt.sampleRate / pcm.format.sampleRate
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 1024)
        guard let ob = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        conv.convert(to: ob, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return pcm
        }
        return err == nil && ob.frameLength > 0 ? ob : nil
    }
}
