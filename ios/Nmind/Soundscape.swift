import AVFoundation

// The Nmind score: generative ambient sound made on the phone, live, from your focus and calm.
//
// A soft open chord (sub, root, fifth, octave, ninth, twelfth) breathes under the void. The upper
// voices only come in as focus grows, so the sound thickens the deeper you settle. Mellow calm adds
// a sparse shimmer of high bell notes. Each new world moves the chord to a new root over a few
// seconds. Crossing into a world, clearing a challenge and taking the wheel with your eyes each get a
// soft chime, and a session ends on a low singing bowl. Nothing is recorded and nothing is sent.

final class Soundscape {
    static let shared = Soundscape()
    private static let key = "nmind.sound.v1"

    let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    // the book feed's chain: up to twelve voices, each on its own player and place in the stereo
    // field, mixed together, softened and given a little room for the chant
    static let maxVoices = 12
    let bookPlayers: [AVAudioPlayerNode] = (0..<12).map { _ in AVAudioPlayerNode() }
    var bookPlayer: AVAudioPlayerNode { bookPlayers[0] }
    let bookBus = AVAudioMixerNode()
    let bookEQ = AVAudioUnitEQ(numberOfBands: 1)
    let bookReverb = AVAudioUnitReverb()
    static let bookFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    private let synth = Synth()
    private var stopWork: DispatchWorkItem?
    /// The audio session and engine are started and stopped here, off the main thread, so a slow
    /// audio route can never freeze the screen.
    let audioQ = DispatchQueue(label: "nmind.audio", qos: .userInitiated)
    private(set) var enabled: Bool

    private init() {
        enabled = UserDefaults.standard.object(forKey: Soundscape.key) as? Bool ?? true
        synth.enabled = enabled ? 1 : 0
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        synth.enabled = on ? 1 : 0
        UserDefaults.standard.set(on, forKey: Soundscape.key)
    }

    /// A dive starts: wake the audio and fade the score in.
    func begin() {
        stopWork?.cancel()
        stopWork = nil
        synth.rootHz = Synth.root(for: 0)
        synth.fade = 1
        synth.running = 1
        audioQ.async { self.startEngine() }
    }

    /// Called about four times a second with the live readings.
    func update(focus: Double, mellow: Double, deep: Double, reading: Bool, fade: Double,
                drive: Double = 0, surge: Double = 0, duck: Double = 0) {
        synth.drive = max(0, min(1, drive))
        synth.surge = max(0, min(1, surge))
        synth.duck = max(0, min(2, duck))      // up to 2 under Deep Listen, so the voice is clear
        synth.focus = max(0, min(1, focus))
        synth.mellow = max(0, min(1, mellow))
        synth.deep = max(0, min(1, deep))
        synth.reading = reading ? 1 : 0
        synth.fade = max(0, min(1, fade))
    }

    /// A new world: the chord glides to its root and a three-note chime rings.
    func world(_ level: Int) {
        synth.rootHz = Synth.root(for: level)
        synth.bloomCount &+= 1
    }

    /// A challenge cleared: a rising chime.
    func cleared() { synth.clearCount &+= 1 }

    /// A dive: the bass rises and a swell of air rushes past.
    func dive() { synth.diveCount &+= 1 }

    /// Your eyes took the wheel: one soft note.
    func steer() { synth.steerCount &+= 1 }

    /// Runs on `audioQ`: the book's voices either plain and clear, or as a chant: a light low-pass
    /// and a touch of a large room, so many voices blend into one low murmur.
    func styleBook(chant: Bool) {
        bookEQ.bands[0].bypass = !chant
        bookReverb.wetDryMix = chant ? 30 : 0
    }

    /// Wake the audio without starting a dive (for the book feed proof on the start screen).
    func wake() {
        stopWork?.cancel()
        stopWork = nil
        audioQ.async { self.startEngine() }
    }

    /// Let the audio sleep again a little after the proof, unless a dive has started.
    func sleepSoon() {
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.synth.running == 0 else { return }
            self.engine.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        stopWork = w
        audioQ.asyncAfter(deadline: .now() + 4, execute: w)
    }

    /// The dive is over: the score fades, a singing bowl rings out, then the audio sleeps.
    func end() {
        synth.running = 0
        synth.endCount &+= 1
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.synth.running == 0 else { return }
            self.engine.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        stopWork = w
        audioQ.asyncAfter(deadline: .now() + 12, execute: w)
    }

    /// Runs on `audioQ` only.
    private func startEngine() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        if node == nil {
            let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
            synth.prepare(sampleRate: sr > 8000 ? sr : 48_000)
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: synth.sr, channels: 2) else { return }
            let synth = self.synth
            let n = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
                synth.render(Int(frames), UnsafeMutableAudioBufferListPointer(abl))
                return noErr
            }
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: fmt)
            engine.mainMixerNode.outputVolume = 1
            node = n
            let bf = Soundscape.bookFormat
            let band = bookEQ.bands[0]
            band.filterType = .lowPass
            band.frequency = 3_200
            band.bypass = true
            bookReverb.loadFactoryPreset(.cathedral)
            bookReverb.wetDryMix = 0
            engine.attach(bookBus); engine.attach(bookEQ); engine.attach(bookReverb)
            for (i, p) in bookPlayers.enumerated() {
                engine.attach(p)
                engine.connect(p, to: bookBus, fromBus: 0, toBus: i, format: bf)
                p.volume = 0
            }
            if let stereo = AVAudioFormat(standardFormatWithSampleRate: bf.sampleRate, channels: 2) {
                engine.connect(bookBus, to: bookEQ, format: stereo)
                engine.connect(bookEQ, to: bookReverb, format: stereo)
                engine.connect(bookReverb, to: engine.mainMixerNode, format: stereo)
            }
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }
}

/// The synth itself. The main thread writes the targets and bumps the event counters; the audio
/// thread reads them, smooths every change and makes the sound. Nothing here allocates while playing.
final class Synth {
    // written by the main thread
    var enabled = 1.0, running = 0.0, reading = 0.0, fade = 1.0
    var focus = 0.3, mellow = 0.0, deep = 0.0
    /// how fast you travel (0 to 1), whether a dive is on (0 to 1), and how much to make room for the book's voice
    var drive = 0.0, surge = 0.0, duck = 0.0
    var rootHz = 73.42
    var bloomCount = 0, clearCount = 0, steerCount = 0, endCount = 0, diveCount = 0

    // audio thread state
    private(set) var sr = 48_000.0
    private var seenBloom = 0, seenClear = 0, seenSteer = 0, seenEnd = 0, seenDive = 0
    private var gain = 0.0, f = 0.3, m = 0.0, d = 0.0, root = 73.42
    private var dr = 0.0, sg = 0.0, dk = 0.0, bright = 0.3
    // the pulse: a soft double beat, like a heart, that quickens and deepens as you dive
    private var pulsePh = 0.0, kickT = 10.0, kickA = 0.0, kickPh = 0.0, clickN = 0.0
    // the rush of air as you travel
    private var windLP = 0.0, windBP = 0.0, windSwell = 0.0
    private var t = 0.0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// sub, root, fifth, octave, ninth, twelfth
    private static let ratios: [Double] = [0.5, 1, 1.5, 2, 2.25, 3]
    private static let lfoPeriods: [Double] = [29, 11, 13, 17, 19, 23]
    private static let pent: [Double] = [1, 9.0 / 8, 5.0 / 4, 3.0 / 2, 5.0 / 3, 2]
    private let voices = 6
    private var phA: UnsafeMutablePointer<Double>
    private var phB: UnsafeMutablePointer<Double>
    private var amp: UnsafeMutablePointer<Double>
    private var lpL = 0.0, lpR = 0.0

    private struct Bell {
        var freq = 0.0, a = 0.0, tau = 1.0, p1 = 0.0, p2 = 0.0, pan = 0.5, ratio2 = 2.76, mix2 = 0.35
        var delay = 0.0
    }
    private var bells: UnsafeMutablePointer<Bell>
    private let bellCount = 16

    init() {
        phA = .allocate(capacity: 6); phA.initialize(repeating: 0, count: 6)
        phB = .allocate(capacity: 6); phB.initialize(repeating: 0.25, count: 6)
        amp = .allocate(capacity: 6); amp.initialize(repeating: 0, count: 6)
        bells = .allocate(capacity: 16); bells.initialize(repeating: Bell(), count: 16)
    }

    func prepare(sampleRate: Double) { sr = sampleRate }

    /// A calm walk of roots around D, one per world, never far from home.
    static func root(for level: Int) -> Double {
        let steps = [0, -5, 3, -2, 5, 0, 7, -3, 2, -4]
        let s = steps[((level % steps.count) + steps.count) % steps.count]
        return 73.42 * pow(2, Double(s) / 12)
    }

    private func rand() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    private func ring(_ freq: Double, _ a: Double, tau: Double, delay: Double = 0, pan: Double? = nil,
                      ratio2: Double = 2.76, mix2: Double = 0.35) {
        var k = 0, low = Double.greatestFiniteMagnitude
        for i in 0..<bellCount where bells[i].a < low && bells[i].delay <= 0 { low = bells[i].a; k = i }
        bells[k] = Bell(freq: freq, a: a, tau: tau, p1: 0, p2: 0, pan: pan ?? (0.25 + 0.5 * rand()),
                        ratio2: ratio2, mix2: mix2, delay: delay)
    }

    /// Control-rate work, every 32 samples: smoothing, the slow swells, events and the shimmer.
    private func control(_ dt: Double) {
        let on = enabled > 0.5
        let want = on ? running * (0.4 + 0.6 * reading) * fade : 0
        gain += (want - gain) * (1 - exp(-dt / 1.4))
        let k = 1 - exp(-dt / 1.5)
        f += (focus - f) * k
        m += (mellow - m) * k
        d += (deep - d) * k
        dr += (drive - dr) * (1 - exp(-dt / 0.8))
        sg += (surge - sg) * (1 - exp(-dt / 0.6))
        dk += (duck - dk) * (1 - exp(-dt / 1.0))
        bright = 0.25 + 0.4 * f + 0.45 * dr + 0.25 * sg
        windSwell *= exp(-dt / 2.5)
        root += (rootHz - root) * (1 - exp(-dt / 4))

        // the upper voices only open up as focus grows (no arrays made here: this runs on the audio thread)
        for i in 0..<voices {
            let base: Double
            switch i {
            case 0: base = 0.20 + 0.10 * dr
            case 1: base = 0.32 + 0.08 * dr
            case 2: base = 0.24
            case 3: base = 0.18 * (0.35 + 0.65 * f) + 0.06 * sg
            case 4: base = 0.13 * f + 0.06 * dr
            default: base = 0.09 * f * (0.3 + 0.7 * m) * (0.5 + 0.5 * d) + 0.05 * sg
            }
            let lfo = 0.72 + 0.28 * sin(2 * .pi * t / Synth.lfoPeriods[i] + Double(i) * 1.7)
            amp[i] = base * lfo
        }

        let r4 = root * 4
        if bloomCount != seenBloom {
            seenBloom = bloomCount
            if on {
                let target = rootHz * 4
                ring(target, 0.07, tau: 3.5)
                ring(target * 5.0 / 4, 0.06, tau: 3.5, delay: 0.35)
                ring(target * 3.0 / 2, 0.055, tau: 4.0, delay: 0.7)
            }
        }
        if clearCount != seenClear {
            seenClear = clearCount
            if on {
                ring(r4, 0.06, tau: 2.5, pan: 0.35)
                ring(r4 * 5.0 / 4, 0.06, tau: 2.5, delay: 0.16, pan: 0.5)
                ring(r4 * 3.0 / 2, 0.06, tau: 3.0, delay: 0.32, pan: 0.65)
                ring(r4 * 2, 0.05, tau: 4.0, delay: 0.5, pan: 0.5)
            }
        }
        if steerCount != seenSteer {
            seenSteer = steerCount
            if on { ring(r4 * 3.0 / 2, 0.045, tau: 2.0, pan: 0.5) }
        }
        if diveCount != seenDive {
            seenDive = diveCount
            if on {
                windSwell = 1
                ring(r4 * 2, 0.05, tau: 3.0, pan: 0.4)
                ring(r4 * 3, 0.04, tau: 3.5, delay: 0.25, pan: 0.6)
            }
        }
        if endCount != seenEnd {
            seenEnd = endCount
            if on {
                // a low singing bowl: a slightly inharmonic partial gives the slow beating shimmer
                ring(root * 2, 0.16, tau: 7.0, pan: 0.45, ratio2: 2.71, mix2: 0.3)
                ring(root * 2 * 1.004, 0.10, tau: 6.0, pan: 0.55, ratio2: 5.1, mix2: 0.15)
            }
        }

        // shimmer: sparse high notes while you're mellow
        if on && running > 0.5 && reading > 0.5 && m > 0.25 {
            let rate = 0.08 + 0.45 * (m - 0.25)
            if rand() < rate * dt {
                let note = Synth.pent[Int(rand() * Double(Synth.pent.count)) % Synth.pent.count]
                ring(r4 * note * (rand() < 0.3 ? 2 : 1), 0.028 + 0.02 * m, tau: 2.2 + 1.5 * m)
            }
        }
    }

    func render(_ frames: Int, _ out: UnsafeMutableAudioBufferListPointer) {
        guard out.count >= 1 else { return }
        let left = out[0].mData?.assumingMemoryBound(to: Float.self)
        let right = out.count > 1 ? out[1].mData?.assumingMemoryBound(to: Float.self) : nil
        let inv = 1.0 / sr
        let twoPi = 2.0 * Double.pi
        let block = 32
        var i = 0
        while i < frames {
            control(Double(block) * inv)
            let n = min(block, frames - i)
            for j in 0..<n {
                t += inv
                var l = 0.0, r = 0.0
                // the chord: each voice is a pair of slightly detuned sines, one leaning left, one right
                for v in 0..<voices {
                    let fr = root * Synth.ratios[v]
                    phA[v] += twoPi * fr * 1.0012 * inv
                    phB[v] += twoPi * fr * 0.9988 * inv
                    if phA[v] > twoPi { phA[v] -= twoPi }
                    if phB[v] > twoPi { phB[v] -= twoPi }
                    // add the 2nd and 3rd harmonics (from the sine and cosine, no extra oscillators) so the
                    // low notes are heard on a phone speaker, which can't play the fundamentals
                    let sa = sin(phA[v]), ca = cos(phA[v]), sb = sin(phB[v]), cb = cos(phB[v])
                    let h2 = bright * (v < 3 ? 0.6 : 0.35), h3 = bright * (v < 3 ? 0.4 : 0.2)
                    let a = sa + h2 * 2 * sa * ca + h3 * (3 * sa - 4 * sa * sa * sa)
                    let b = sb + h2 * 2 * sb * cb + h3 * (3 * sb - 4 * sb * sb * sb)
                    l += amp[v] * (0.65 * a + 0.35 * b)
                    r += amp[v] * (0.35 * a + 0.65 * b)
                }
                l *= 1 - 0.3 * dk; r *= 1 - 0.3 * dk

                // the pulse: from 52 beats a minute at rest to about 92 deep in a dive
                let bpm = 52 + 28 * dr + 12 * sg
                pulsePh += bpm / 60 * inv
                if pulsePh >= 1 { pulsePh -= 1; kickT = 0; kickA = 1 }
                if kickT < 0.29 && kickT + inv >= 0.29 { kickT = 0.29; kickA = 0.62 }  // the second, softer beat
                kickT += inv
                let kt = kickT >= 0.29 ? kickT - 0.29 : kickT
                let kf = 46 + 80 * exp(-kt / 0.045)
                kickPh += twoPi * kf * inv
                if kickPh > twoPi { kickPh -= twoPi }
                let kenv = kickA * exp(-kt / 0.2)
                let ks = sin(kickPh), kc = cos(kickPh)
                clickN += (rand() * 2 - 1 - clickN) * 0.3
                let kick = kenv * (ks + 0.7 * 2 * ks * kc + 0.45 * (3 * ks - 4 * ks * ks * ks)) + kickA * 0.25 * exp(-kt / 0.006) * clickN
                let kickGain = (0.05 + 0.28 * f) * (0.35 + 0.65 * dr) + 0.22 * sg
                l += kick * kickGain; r += kick * kickGain

                // the rush of air: noise that brightens and swells the faster you travel
                let nz = rand() * 2 - 1
                windLP += (nz - windLP) * (0.02 + 0.10 * dr + 0.08 * sg)
                windBP += (windLP - windBP) * 0.01
                let wind = (windLP - windBP) * (0.03 + 0.20 * dr * dr + 0.25 * sg + 0.3 * windSwell)
                l += wind * 2.2; r += wind * 2.2 * (0.85 + 0.15 * sin(twoPi * t / 3.1))
                // a soft breath of filtered noise, swelling every nine seconds or so
                let breath = 0.035 * (0.55 + 0.45 * sin(twoPi * t / 9.3)) * (1 - 0.4 * f)
                lpL += (rand() * 2 - 1 - lpL) * 0.035
                lpR += (rand() * 2 - 1 - lpR) * 0.035
                l += breath * lpL * 3
                r += breath * lpR * 3
                l *= gain; r *= gain

                // bells ring past the end of a dive, so they follow only the sound switch
                var bl = 0.0, br = 0.0
                for k in 0..<bellCount {
                    if bells[k].delay > 0 { bells[k].delay -= inv; continue }
                    let a = bells[k].a
                    if a < 0.0002 { continue }
                    bells[k].p1 += twoPi * bells[k].freq * inv
                    bells[k].p2 += twoPi * bells[k].freq * bells[k].ratio2 * inv
                    if bells[k].p1 > twoPi { bells[k].p1 -= twoPi }
                    if bells[k].p2 > twoPi { bells[k].p2 -= twoPi }
                    let s = a * (sin(bells[k].p1) + bells[k].mix2 * sin(bells[k].p2) * min(1, a * 20))
                    bl += s * (1 - bells[k].pan)
                    br += s * bells[k].pan
                    bells[k].a = a * exp(-inv / bells[k].tau)
                }
                if enabled < 0.5 { bl = 0; br = 0 }
                l += bl * 2; r += br * 2

                left?[i + j] = Float(tanh(l * 1.5) * 0.95)
                right?[i + j] = Float(tanh(r * 1.5) * 0.95)
            }
            i += n
        }
        if t > 100_000 { t -= 100_000 }
    }
}
