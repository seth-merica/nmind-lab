import AVFoundation

/// The chant: how the book goes faster than one voice can speak while every word stays whole,
/// low and in the book's exact order.
///
/// Each word is spoken on its own by the low voice at its top rate, so every sound of the word is
/// made by the voice itself and nothing is sped up afterwards (no cut sounds, no raised pitch). Its
/// silent edges are trimmed. The words then start one after another in strict book order, each a
/// little after the one before, sooner the faster the speed, so they overlap like a hall of monks
/// chanting in a staggered round. Each word plays on whichever of up to twelve voices is free, each
/// voice at its own place in the stereo field, in a large soft room under the music.
final class Chant {
    static let voiceCount = 12
    struct Word { let buf: AVAudioPCMBuffer?; let dur: Double }
    struct Onset { let pos: Int; let word: Int; let t: Double; let dur: Double; let voice: Int; var marks = 0 }
    private final class Conv { var c: AVAudioConverter? }

    /// word indices into the book, in order, to be chanted
    let list: [Int]
    private let texts: [String]
    /// words a second to start
    let target: Double
    /// one word at a time with no overlap, for the proof
    let solo: Bool
    private let voice: AVSpeechSynthesisVoice?
    private let pitch: Float
    private let players: [AVAudioPlayerNode]
    private let sound = Soundscape.shared
    private let synths = (0..<4).map { _ in AVSpeechSynthesizer() }
    private let converters = (0..<4).map { _ in Conv() }
    /// word marks the voice gave for each word, as it spoke it (under the lock)
    private var marks: [Int: Int] = [:]
    private let lock = NSLock()
    private let sr = Soundscape.bookFormat.sampleRate

    // made ahead (main thread starts them, the voices finish them)
    private var nextToMake = 0
    private var inFlight = 0
    private var ready: [Int: Word] = [:]          // under the lock
    // scheduled (audio queue)
    private(set) var nextToSchedule = 0
    private var free: [Double]
    private var lastOnset = -1.0, lastDur = 0.0
    private var avgDur = 0.0
    private(set) var started = false
    private var log: [Onset] = []                  // under the lock
    private(set) var slips = 0
    private var maxBusy = 0
    var stopped = false

    init(list: [Int], words: [String], target: Double, solo: Bool = false, voice: AVSpeechSynthesisVoice?, pitch: Float) {
        self.list = list
        texts = list.map { Chant.clean(words[$0]) }
        self.target = max(0.5, target)
        self.solo = solo
        self.voice = voice
        self.pitch = pitch
        players = Array(Soundscape.shared.bookPlayers.prefix(Chant.voiceCount))
        free = Array(repeating: 0, count: Chant.voiceCount)
    }

    static func clean(_ w: String) -> String {
        w.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'")))
    }

    // MARK: making the words

    /// Main thread: keep about five seconds of words made ahead of where the chant is.
    func make() {
        guard !stopped else { return }
        let ahead = Int(target * 5) + 8
        while inFlight < 8, nextToMake < list.count, nextToMake - nextToSchedule < ahead {
            makeWord(nextToMake)
            nextToMake += 1
        }
    }

    private func makeWord(_ pos: Int) {
        inFlight += 1
        let k = pos % synths.count
        let u = AVSpeechUtterance(string: texts[pos])
        u.voice = voice
        u.rate = AVSpeechUtteranceMaximumSpeechRate
        u.pitchMultiplier = pitch
        u.volume = 1
        u.preUtteranceDelay = 0; u.postUtteranceDelay = 0
        var bufs: [AVAudioPCMBuffer] = []
        let conv = converters[k]
        let fmt = Soundscape.bookFormat
        synths[k].write(u, toBufferCallback: { [weak self] buffer in
            guard let self else { return }
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                if let b = BookFeed.convert(pcm, with: &conv.c, to: fmt) { bufs.append(b) }
                return
            }
            let word = Chant.join(bufs, format: fmt)
            self.lock.lock()
            self.ready[pos] = Word(buf: word, dur: word.map { Double($0.frameLength) / fmt.sampleRate } ?? 0)
            self.lock.unlock()
            DispatchQueue.main.async { self.inFlight -= 1; self.make() }
        }, toMarkerCallback: { [weak self] markers in
            guard let self else { return }
            let n = markers.filter { $0.mark == .word }.count
            self.lock.lock(); self.marks[pos, default: 0] += n; self.lock.unlock()
        })
    }

    /// One buffer for the word, its silent edges trimmed and its ends eased so nothing clicks.
    static func join(_ bufs: [AVAudioPCMBuffer], format fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let total = bufs.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0 else { return nil }
        var x = [Float](repeating: 0, count: total)
        var o = 0
        for b in bufs {
            guard let d = b.floatChannelData?[0] else { continue }
            for i in 0..<Int(b.frameLength) { x[o + i] = d[i] }
            o += Int(b.frameLength)
        }
        let th: Float = 0.006
        guard var a = x.firstIndex(where: { abs($0) > th }), var e = x.lastIndex(where: { abs($0) > th }) else { return nil }
        let margin = Int(fmt.sampleRate * 0.006)
        a = max(0, a - margin); e = min(total - 1, e + margin)
        let n = e - a + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let d = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        let fade = min(n / 2, Int(fmt.sampleRate * 0.004))
        for i in 0..<n {
            var g: Float = 1
            if i < fade { g = Float(i) / Float(fade) } else if i >= n - fade { g = Float(n - 1 - i) / Float(fade) }
            d[i] = x[a + i] * g
        }
        return out
    }

    // MARK: playing in order

    /// Audio queue: start every voice together so they share one clock.
    func start(volume: Float) {
        guard !started else { return }
        started = true
        let pans: [Float] = [-0.15, 0.2, -0.45, 0.5, -0.7, 0.7, -0.3, 0.35, -0.6, 0.6, 0.05, -0.05]
        for (i, p) in players.enumerated() {
            p.stop()
            p.pan = solo ? 0 : pans[i]
            p.volume = volume
        }
        guard sound.engine.isRunning else { return }
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        let when = AVAudioTime(hostTime: host)
        for p in players { p.play(at: when) }
    }

    func now() -> Double {
        guard let p = players.first, let nt = p.lastRenderTime, nt.isSampleTimeValid,
              let pt = p.playerTime(forNodeTime: nt), pt.isSampleTimeValid, pt.sampleRate > 0 else { return 0 }
        return Double(pt.sampleTime) / pt.sampleRate
    }

    /// Audio queue: start the next words that are ready, each strictly after the one before.
    func schedule() {
        guard started, !stopped else { return }
        let t0 = now()
        while nextToSchedule < list.count {
            lock.lock(); let w = ready[nextToSchedule]; lock.unlock()
            guard let w else { break }
            // how many words are sounding at once on average, so the starts land on the target rate
            if w.dur > 0 { avgDur = avgDur == 0 ? w.dur : avgDur * 0.9 + w.dur * 0.1 }
            let overlap = solo ? 1 : max(1, target * avgDur)
            var onset: Double
            if lastOnset < 0 {
                onset = t0 + 0.3
            } else {
                let gap = solo ? lastDur + 0.04 : min(4 / target, max(0.25 / target, lastDur / overlap))
                onset = lastOnset + gap
            }
            if onset < t0 + 0.04 { onset = t0 + 0.04; slips += 1 }
            if onset > t0 + 3 { break }
            // the voice that has been free the longest
            var v = 0
            for i in 1..<free.count where free[i] < free[v] { v = i }
            if free[v] > onset { onset = free[v]; slips += 1 }
            onset = max(onset, lastOnset + 0.001)
            if let b = w.buf {
                players[v].scheduleBuffer(b, at: AVAudioTime(sampleTime: AVAudioFramePosition(onset * sr), atRate: sr), options: [], completionHandler: nil)
                free[v] = onset + w.dur + 0.005
            }
            let busy = free.filter { $0 > onset }.count
            maxBusy = max(maxBusy, busy)
            lock.lock()
            log.append(Onset(pos: nextToSchedule, word: list[nextToSchedule], t: onset, dur: w.dur, voice: v))
            ready[nextToSchedule] = nil
            lock.unlock()
            lastOnset = onset; lastDur = w.dur
            nextToSchedule += 1
        }
    }

    func pause() { for p in players { p.pause() } }
    func resume() { if sound.engine.isRunning { for p in players { p.play() } } }
    func halt() {
        stopped = true
        for s in synths where s.isSpeaking { s.stopSpeaking(at: .immediate) }
    }

    /// The word the chant has reached: one past the last word that has started.
    func reached(at t: Double) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let i = log.lastIndex(where: { $0.t <= t }) else { return nil }
        return log[i].word + 1
    }

    var finished: Bool {
        guard nextToSchedule >= list.count else { return false }
        return now() >= lastOnset + lastDur
    }

    /// Words that have started and finished sounding, with what the voice marked as spoken.
    func done(at t: Double) -> [Onset] {
        lock.lock(); defer { lock.unlock() }
        return log.filter { $0.t + $0.dur <= t + 0.02 }.map { var o = $0; o.marks = marks[o.pos] ?? 0; return o }
    }

    /// True when every start so far came after the one before, in book order.
    var inOrder: Bool {
        lock.lock(); defer { lock.unlock() }
        guard log.count > 1 else { return true }
        for i in 1..<log.count where !(log[i].t > log[i - 1].t && log[i].word > log[i - 1].word) { return false }
        return true
    }
    var voicesUsed: Int { maxBusy }
    var averageWord: Double { avgDur }
}
