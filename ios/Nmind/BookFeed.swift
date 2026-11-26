import AVFoundation
import Combine

/// The book feed test, an optional add-on to the calm dive.
///
/// Once you have settled (steady focus with mellow or settling calm for a few seconds), it reads a
/// book in a low, even voice, sped up past easy listening without raising the pitch, and softened,
/// under the music. The same words stream out of the far end of the tunnel, small, turning and faint,
/// too fast to read. It runs for three minutes of feed time, pauses whenever you look away, then fades.
///
/// The voice is made on the phone by the system's speech engine and played through the same audio
/// engine as the music. Nothing is recorded or sent.
final class BookFeed: ObservableObject {
    static let shared = BookFeed()
    static let testSeconds = 180.0
    static let speeds: [Double] = [2, 3, 4]
    private static let onKey = "nmind.bookfeed.v1", speedKey = "nmind.bookfeed.speed.v1"

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: BookFeed.onKey) } }
    /// how many times normal speaking speed
    @Published var speed: Double { didSet { UserDefaults.standard.set(speed, forKey: BookFeed.speedKey) } }

    enum State { case off, waiting, feeding, paused, done }
    enum Event { case none, started, finished }
    private(set) var state: State = .off
    private(set) var fedSeconds = 0.0
    /// 0 to 1, eased: how present the feed is, for the music's ducking and the words' brightness
    private(set) var level = 0.0
    /// the visual cursor through `words`, advancing with the voice
    private(set) var cursor = 0.0
    var isFeeding: Bool { state == .feeding || state == .paused }

    let words: [String]
    private let chunks: [(text: String, first: Int)]
    private var calmHeld = 0.0

    // speech, on the main thread
    private let synth = AVSpeechSynthesizer()
    private var nextChunk = 0
    // the audio side, on Soundscape's queue
    private var queued = 0.0, writing = false, gen = 0
    private var converter: AVAudioConverter?

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: BookFeed.onKey) as? Bool ?? false
        let s = d.double(forKey: BookFeed.speedKey)
        speed = BookFeed.speeds.contains(s) ? s : 3
        let paras = BookText.body.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var w: [String] = [], c: [(String, Int)] = []
        // a chunk is a paragraph, or a few short ones, so speech is made a little ahead of playback
        var buf = "", first = 0
        for p in paras {
            if buf.isEmpty { first = w.count }
            buf += (buf.isEmpty ? "" : " ") + p
            w += p.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if buf.count > 280 { c.append((buf, first)); buf = "" }
        }
        if !buf.isEmpty { c.append((buf, first)) }
        words = w
        chunks = c
    }

    // MARK: session

    func sessionBegan() {
        stopAudio()
        state = enabled ? .waiting : .off
        fedSeconds = 0; level = 0; cursor = 0; calmHeld = 0; nextChunk = 0
    }

    func sessionEnded() {
        if isFeeding { stopAudio() }
        if state != .done { state = .off }
    }

    /// Words fed so far this session, about.
    var wordsFed: Int { min(words.count, Int(cursor)) }

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
            cursor += dt * wordsPerSecond
            pump()
            if fedSeconds >= BookFeed.testSeconds { finishAudio(); state = .done; ev = .finished }
        case .paused:
            if reading { resumeAudio(); state = .feeding }
        }
        let want = state == .feeding ? 1.0 : 0.0
        level += (want - level) * min(1, dt / 1.5)
        return ev
    }

    /// The system voice reads about 180 words a minute at its normal rate.
    private var wordsPerSecond: Double { 3.0 * speed }

    // MARK: audio

    private var sound: Soundscape { Soundscape.shared }

    private func startAudio() {
        let rate = Float(speed)
        sound.audioQ.async {
            self.gen += 1; self.queued = 0; self.writing = false
            let p = self.sound.bookPlayer
            self.sound.bookPitch.rate = rate
            self.sound.bookPitch.pitch = -150      // a touch lower and darker
            p.volume = 0
            if self.sound.engine.isRunning { p.play() }
            self.rampVolume(to: 0.9, over: 2.5)
        }
        nextChunk = max(0, chunks.firstIndex { $0.first >= Int(cursor) } ?? 0)
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
        let u = AVSpeechUtterance(string: chunks[nextChunk].text)
        nextChunk += 1
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.pitchMultiplier = 0.8                 // low and even
        u.volume = 1
        u.preUtteranceDelay = 0; u.postUtteranceDelay = 0
        synth.write(u) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                self.sound.audioQ.async { if self.gen == g { self.writing = false } }
                return
            }
            guard let out = self.convert(pcm) else { return }
            let seconds = Double(out.frameLength) / Soundscape.bookFormat.sampleRate / Double(self.speed)
            self.sound.audioQ.async {
                guard self.gen == g else { return }
                self.queued += seconds
                self.sound.bookPlayer.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { _ in
                    self.sound.audioQ.async { if self.gen == g { self.queued = max(0, self.queued - seconds) } }
                }
            }
        }
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
