import AVFoundation
import Combine

/// The book feed, an optional add-on to the calm dive, in two modes you pick on the start screen.
///
/// Deep Listen reads the book at an easy listening speed in a clear voice, picks up where you left
/// off last time, and shows the words it is reading, upright and in step, coming through the tunnel
/// and in the band under the centre. A short recall check follows the session.
///
/// Lab test is the fast feed: a low, even voice sped up well past easy listening without raising the
/// pitch, softened under the music, with the same words streaming out of the tunnel small, turning and
/// faint, too fast to read. It starts somewhere new in the book each time, and a 20 phrase quiz after
/// the session (half from what played, half from parts never played) measures whether anything stuck.
///
/// Either runs for three minutes of feed time once you have settled, and pauses whenever you look away.
/// The voice is made on the phone by the system's speech engine and played through the same audio
/// engine as the music. Nothing is recorded or sent.
final class BookFeed: ObservableObject {
    static let shared = BookFeed()
    static let testSeconds = 180.0
    static let listenSpeeds: [Double] = [1.25, 1.5, 2]
    static let labSpeeds: [Double] = [2, 3, 4]
    private static let modeKey = "nmind.bookfeed.mode.v1", oldOnKey = "nmind.bookfeed.v1"
    private static let listenSpeedKey = "nmind.bookfeed.listenspeed.v1", labSpeedKey = "nmind.bookfeed.speed.v1"
    private static let listenPosKey = "nmind.bookfeed.listenpos.v1", labHeardKey = "nmind.bookfeed.labheard.v1"

    enum Mode: String, CaseIterable {
        case off, listen, lab
        var label: String {
            switch self {
            case .off: return "Off"
            case .listen: return "Deep Listen"
            case .lab: return "Lab test"
            }
        }
    }

    @Published var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: BookFeed.modeKey) } }
    /// how many times normal speaking speed, for each mode
    @Published var listenSpeed: Double { didSet { UserDefaults.standard.set(listenSpeed, forKey: BookFeed.listenSpeedKey) } }
    @Published var labSpeed: Double { didSet { UserDefaults.standard.set(labSpeed, forKey: BookFeed.labSpeedKey) } }

    enum State { case off, waiting, feeding, paused, done }
    enum Event { case none, started, finished }
    private(set) var state: State = .off
    /// the mode this session runs in, fixed when it starts
    private(set) var sessionMode: Mode = .off
    private(set) var fedSeconds = 0.0
    /// 0 to 1, eased: how present the feed is, for the music's ducking and the words' brightness
    private(set) var level = 0.0
    /// where the voice is in `words`, kept in step with what has actually played
    private(set) var cursor = 0.0
    /// the first word this session read
    private(set) var startWord = 0
    var isFeeding: Bool { state == .feeding || state == .paused }
    var speed: Double { (sessionMode == .off ? mode : sessionMode) == .listen ? listenSpeed : labSpeed }
    var wordIndex: Int { min(words.count, Int(cursor)) }

    let words: [String]
    private let chunks: [(text: String, first: Int, count: Int)]
    private var calmHeld = 0.0

    // speech, on the main thread
    private let synth = AVSpeechSynthesizer()
    private var nextChunk = 0
    // the audio side, on Soundscape's queue
    private var queued = 0.0, writing = false, gen = 0
    private var converter: AVAudioConverter?
    // what has been scheduled on the player, in the player's own seconds, so the words track the voice
    private struct Seg { var start: Double; var dur: Double; let first: Int; let count: Int; let chunk: Int; var done: Bool }
    private var timeline: [Seg] = []
    private var schedEnd = 0.0
    private let lock = NSLock()

    private init() {
        let d = UserDefaults.standard
        if let m = d.string(forKey: BookFeed.modeKey), let mm = Mode(rawValue: m) {
            mode = mm
        } else {
            mode = (d.object(forKey: BookFeed.oldOnKey) as? Bool ?? false) ? .lab : .off
        }
        let ls = d.double(forKey: BookFeed.listenSpeedKey)
        listenSpeed = BookFeed.listenSpeeds.contains(ls) ? ls : 1.5
        let s = d.double(forKey: BookFeed.labSpeedKey)
        labSpeed = BookFeed.labSpeeds.contains(s) ? s : 3
        let paras = BookText.body.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var w: [String] = [], c: [(String, Int, Int)] = []
        // a chunk is a paragraph, or a few short ones, so speech is made a little ahead of playback
        var buf = "", first = 0
        for p in paras {
            if buf.isEmpty { first = w.count }
            buf += (buf.isEmpty ? "" : " ") + p
            w += p.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if buf.count > 280 { c.append((buf, first, w.count - first)); buf = "" }
        }
        if !buf.isEmpty { c.append((buf, first, w.count - first)) }
        words = w
        chunks = c
    }

    // MARK: session

    func sessionBegan() {
        stopAudio()
        sessionMode = mode
        state = mode == .off ? .off : .waiting
        fedSeconds = 0; level = 0; calmHeld = 0
        // Deep Listen carries on where you left off; the lab feed starts somewhere new each time
        var k = 0
        if mode == .listen {
            let pos = UserDefaults.standard.integer(forKey: BookFeed.listenPosKey)
            k = chunks.lastIndex { $0.first <= pos } ?? 0
            if chunks[k].first > words.count - 60 { k = 0 }
        } else if mode == .lab {
            let need = Int(BookFeed.testSeconds * wordsPerSecond) + 400
            let fits = chunks.indices.filter { chunks[$0].first + need <= words.count }
            k = fits.randomElement() ?? 0
        }
        nextChunk = k
        startWord = chunks.isEmpty ? 0 : chunks[k].first
        cursor = Double(startWord)
    }

    func sessionEnded() {
        if isFeeding { stopAudio() }
        if sessionMode == .listen && wordsFed > 0 {
            let at = wordIndex >= words.count - 60 ? 0 : wordIndex
            UserDefaults.standard.set(at, forKey: BookFeed.listenPosKey)
        }
        if sessionMode == .lab && wordsFed > 0 {
            var heard = UserDefaults.standard.array(forKey: BookFeed.labHeardKey) as? [[Int]] ?? []
            heard.append([startWord, wordIndex])
            UserDefaults.standard.set(heard, forKey: BookFeed.labHeardKey)
        }
        if state != .done { state = .off }
    }

    /// Words fed so far this session.
    var wordsFed: Int { max(0, wordIndex - startWord) }
    /// The words that actually played this session.
    var playedRange: Range<Int> { startWord..<max(startWord, wordIndex) }
    /// Parts of the book earlier lab tests played, so quiz decoys come from text you have never heard.
    var labHeard: [Range<Int>] {
        (UserDefaults.standard.array(forKey: BookFeed.labHeardKey) as? [[Int]] ?? [])
            .compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]..<$0[1] : nil }
    }

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
            if let at = playedPosition() { cursor = max(cursor, at) } else { cursor += dt * wordsPerSecond }
            pump()
            if fedSeconds >= BookFeed.testSeconds || cursor >= Double(words.count) - 1 {
                finishAudio(); state = .done; ev = .finished
            }
        case .paused:
            if reading { resumeAudio(); state = .feeding }
        }
        let want = state == .feeding ? 1.0 : 0.0
        level += (want - level) * min(1, dt / 1.5)
        return ev
    }

    /// The system voice reads about 180 words a minute at its normal rate; only a fallback now.
    private var wordsPerSecond: Double { 3.0 * speed }

    /// Where the voice has reached, in words, from what the player has played.
    private func playedPosition() -> Double? {
        guard let at = playerSeconds() else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let seg = timeline.last(where: { $0.start <= at }) else { return nil }
        let dur = max(0.05, seg.dur)
        let f = min(1, max(0, (at - seg.start) / dur))
        // while a chunk is still arriving its length isn't known yet, so hold short of its end
        let frac = seg.done ? f : min(f, 0.9)
        return Double(seg.first) + Double(seg.count) * frac
    }

    private func playerSeconds() -> Double? {
        let p = sound.bookPlayer
        guard let nt = p.lastRenderTime, nt.isSampleTimeValid,
              let pt = p.playerTime(forNodeTime: nt), pt.isSampleTimeValid, pt.sampleRate > 0 else { return nil }
        return Double(pt.sampleTime) / pt.sampleRate
    }

    // MARK: audio

    private var sound: Soundscape { Soundscape.shared }

    private func startAudio() {
        let listen = sessionMode == .listen
        let rate = Float(speed)
        sound.audioQ.async {
            self.gen += 1; self.queued = 0; self.writing = false
            self.lock.lock(); self.timeline = []; self.schedEnd = 0; self.lock.unlock()
            let p = self.sound.bookPlayer
            p.stop()
            self.sound.bookPitch.rate = rate
            self.sound.bookPitch.pitch = listen ? 0 : -150     // the lab feed sits a touch lower and darker
            self.sound.bookEQ.bands[0].bypass = listen          // and softened; Deep Listen stays clear
            p.volume = 0
            if self.sound.engine.isRunning { p.play() }
            self.rampVolume(to: listen ? 1.0 : 0.9, over: 2.5)
        }
        pump()
    }

    private func pauseAudio() { sound.audioQ.async { self.sound.bookPlayer.pause() } }
    private func resumeAudio() { sound.audioQ.async { if self.sound.engine.isRunning { self.sound.bookPlayer.play() } } }

    private func finishAudio() {
        sound.audioQ.async {
            self.rampVolume(to: 0, over: 3)
            let g = self.gen
            self.sound.audioQ.asyncAfter(deadline: .now() + 3.2) {
                guard self.gen == g else { return }
                self.gen += 1
                self.sound.bookPlayer.stop()
                self.queued = 0; self.writing = false
            }
        }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private func stopAudio() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        sound.audioQ.async {
            self.gen += 1
            self.sound.bookPlayer.stop()
            self.sound.bookPlayer.volume = 0
            self.queued = 0; self.writing = false
        }
    }

    /// Runs on the audio queue: steps the player's volume toward a target.
    private func rampVolume(to v: Float, over seconds: Double) {
        let p = sound.bookPlayer, start = p.volume, steps = 20
        let g = gen
        for i in 1...steps {
            sound.audioQ.asyncAfter(deadline: .now() + seconds * Double(i) / Double(steps)) {
                guard self.gen == g else { return }
                p.volume = start + (v - start) * Float(i) / Float(steps)
            }
        }
    }

    /// Keeps about eight seconds of speech queued ahead of the player.
    private func pump() {
        sound.audioQ.async {
            guard !self.writing, self.queued < 8 else { return }
            self.writing = true
            let g = self.gen
            DispatchQueue.main.async { self.writeNext(gen: g) }
        }
    }

    private func writeNext(gen g: Int) {
        guard isFeeding, nextChunk < chunks.count else {
            sound.audioQ.async { self.writing = false }
            return
        }
        let k = nextChunk
        let chunk = chunks[k]
        let u = AVSpeechUtterance(string: chunk.text)
        nextChunk += 1
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.pitchMultiplier = sessionMode == .listen ? 1.0 : 0.8   // the lab voice is low and even
        u.volume = 1
        u.preUtteranceDelay = 0; u.postUtteranceDelay = 0
        let speed = self.speed
        synth.write(u) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                self.sound.audioQ.async {
                    guard self.gen == g else { return }
                    self.writing = false
                    self.lock.lock()
                    if let i = self.timeline.lastIndex(where: { $0.chunk == k }) { self.timeline[i].done = true }
                    self.lock.unlock()
                }
                return
            }
            guard let out = self.convert(pcm) else { return }
            let source = Double(out.frameLength) / Soundscape.bookFormat.sampleRate
            let seconds = source / speed
            self.sound.audioQ.async {
                guard self.gen == g else { return }
                self.queued += seconds
                // note where this piece lands on the player's clock (after any gap if it ran dry)
                let now = self.playerSeconds() ?? 0
                self.lock.lock()
                if self.schedEnd < now { self.schedEnd = now }
                if let i = self.timeline.indices.last, self.timeline[i].chunk == k {
                    self.timeline[i].dur += source
                } else {
                    self.timeline.append(Seg(start: self.schedEnd, dur: source, first: chunk.first, count: chunk.count, chunk: k, done: false))
                }
                self.schedEnd += source
                self.lock.unlock()
                self.sound.bookPlayer.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { _ in
                    self.sound.audioQ.async { if self.gen == g { self.queued = max(0, self.queued - seconds) } }
                }
            }
        }
    }

    // MARK: what's on screen

    /// Deep Listen shows the book in short lines of seven words, in step with the voice.
    var lineWords: (spoken: String, coming: String)? {
        guard sessionMode == .listen, isFeeding, !words.isEmpty else { return nil }
        let i = min(words.count - 1, wordIndex)
        let a = startWord + ((i - startWord) / 7) * 7
        let b = min(words.count, a + 7)
        let spoken = words[a...i].joined(separator: " ")
        let coming = i + 1 < b ? words[(i + 1)..<b].joined(separator: " ") : ""
        return (spoken, coming)
    }

    /// Speech arrives in the voice's own format; the player takes one fixed format.
    private func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outFmt = Soundscape.bookFormat
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
