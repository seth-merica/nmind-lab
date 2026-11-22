import Foundation

// Nmind calm reader, native version. A port of the web prototype's calm.mjs, fed by ARKit face
// tracking on the Face ID (TrueDepth) camera instead of a face model on the colour camera.
// Everything runs on the phone, frame by frame. Nothing is saved or sent anywhere.
//
// Prototype heuristics, not a medical device. iOS does not give apps the raw infrared image,
// so pupil size is still not read.

private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }
private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
/// per-frame rate tuned for 30 frames a second, adjusted for the real frame time
private func rate(_ k: Double, _ dt: Double) -> Double { 1 - pow(1 - k, max(0.2, min(4, dt * 30))) }

/// Resting level: falls quickly to the relaxed level, rises only slowly.
final class RestFloor {
    var v: Double?
    func add(_ x: Double, _ learning: Bool, _ dt: Double) -> Double {
        guard let cur = v else { v = x; return x }
        let k = x < cur ? (learning ? 0.08 : 0.02) : (learning ? 0.01 : 0.0008)
        let nv = cur + (x - cur) * rate(k, dt)
        v = nv
        return nv
    }
}

/// Personal typical level: learns fast during the first stretch, then barely moves.
final class Typical {
    var v: Double?
    var n = 0
    func add(_ x: Double, _ learning: Bool) -> Double {
        n += 1
        guard let cur = v else { v = x; return x }
        let nv = cur + (x - cur) * (learning ? max(0.02, 1 / Double(n)) : 0.0015)
        v = nv
        return nv
    }
}

final class Ema {
    let tau: Double
    var v: Double?
    init(_ tau: Double) { self.tau = tau }
    func f(_ x: Double, _ dt: Double) -> Double {
        guard let cur = v else { v = x; return x }
        let nv = cur + (x - cur) * (1 - exp(-dt / tau))
        v = nv
        return nv
    }
}

enum Verdict: String {
    case learning = "Learning you"
    case restless = "Restless"
    case tense = "Tense calm"
    case settling = "Settling"
    case mellow = "Mellow calm"
    case paused = "Paused"
}

struct Signal {
    var text = "—"
    var conf = 0.0
    /// 1 leans tense, -2 leans mellow, -1 a mild note, 0 neutral
    var lean = 0
    var v = 0.0
}

struct CalmOut {
    var signals: [String: Signal] = [:]
    var tension = 0.0
    var mellow = 0.0
    var still = 0.0
    var verdict: Verdict = .learning
    var learning = true
    var learnLeft = 20
    var hr = 0.0
    var hrConf = 0.0
}

struct CalmInput {
    var t: Double
    var dt: Double
    var looking: Bool
    var blink: Double          // 0 open, 1 closed (mean of both eyes)
    var ex: Double             // eye rotation inside the head, radians
    var ey: Double
    var s1: Double             // eye steadiness 0..1
    var s2: Double             // head stillness 0..1
    var s3: Double             // share of recent time looking at the screen
    var squint: Double
    var wide: Double
    var brow: Double
    var jaw: Double
    var headY: Double          // metres, camera space
    var headZ: Double
    var rgb: SIMD3<Double>?    // mean skin colour on forehead and cheeks
    var ambient: Double?       // ARKit light estimate, lumens (about 1000 is normal indoor light)
}

final class CalmReader {
    static let signalOrder: [(String, String)] = [
        ("gaze", "Steady gaze"), ("sacc", "Eye jumps"), ("head", "Head stillness"),
        ("brate", "Blink rate"), ("blen", "Blink length"), ("lids", "Eyelids"),
        ("brow", "Brow"), ("jaw", "Jaw and mouth"),
        ("hr", "Heart rate"), ("hrv", "Heart variability"), ("breath", "Breathing"),
        ("light", "Light"), ("pupil", "Pupil size")
    ]

    private(set) var out = CalmOut()
    private(set) var fps = 60.0

    private var t0 = 0.0, faceT = 0.0
    private var blinkOn = false, blinkStart = 0.0
    private var blinks: [Double] = [], blinkLens: [Double] = []
    private var prevEye: (Double, Double)?
    private var velFloor = 0.3, saccades: [Double] = [], lastSacc = -10.0
    private var lidT = Typical(), browF = RestFloor(), jawF = RestFloor(), squintF = RestFloor(), wideF = RestFloor()
    private var rgb: [TimedSample] = [], motion: [TimedSample] = []
    private var hrHist: [Double] = [], hr = 0.0, hrConf = 0.0, hrBase = Typical(), hrTrend: [(t: Double, v: Double)] = []
    private var hrv = 0.0, hrvConf = 0.0, hrvBase = Typical()
    private var br = 0.0, brConf = 0.0, lastSpec = 0.0
    private var luma = 0.0, lumaE = Ema(1)
    private var tE = Ema(4), mE = Ema(4), sE = Ema(2)
    private var verdict: Verdict = .learning, cand: Verdict = .learning, candT = 0.0

    init() { reset(0) }

    func reset(_ now: Double) {
        t0 = now; faceT = 0
        blinkOn = false; blinkStart = 0; blinks = []; blinkLens = []
        prevEye = nil; velFloor = 0.3; saccades = []; lastSacc = -10
        lidT = Typical(); browF = RestFloor(); jawF = RestFloor(); squintF = RestFloor(); wideF = RestFloor()
        rgb = []; motion = []; hrHist = []; hr = 0; hrConf = 0; hrBase = Typical(); hrTrend = []
        hrv = 0; hrvConf = 0; hrvBase = Typical()
        br = 0; brConf = 0; lastSpec = now; luma = 0; lumaE = Ema(1)
        tE = Ema(4); mE = Ema(4); sE = Ema(2)
        verdict = .learning; cand = .learning; candT = 0
        out = CalmOut()
        fps = 60
    }

    @discardableResult
    func frame(_ f: CalmInput) -> CalmOut {
        let now = f.t, dt = f.dt
        var S = out.signals
        fps += ((dt > 0 ? 1 / dt : 60) - fps) * 0.05
        faceT += dt
        let learning = faceT < 20
        out.learning = learning
        out.learnLeft = max(0, Int(ceil(20 - faceT)))
        let fpsC = clamp((fps - 12) / 14, 0, 1)

        // ---- light, and skin colour for the pulse ----
        if let c = f.rgb {
            luma = lumaE.f(0.299 * c.x + 0.587 * c.y + 0.114 * c.z, dt)
            rgb.append(TimedSample(t: now, v: [c.x, c.y, c.z]))
        }
        trim(&rgb, now, 32)
        var lightC = f.rgb != nil ? clamp((luma - 35) / 50, 0, 1) : 0
        if let amb = f.ambient { lightC = min(lightC == 0 ? 1 : lightC, clamp((amb - 120) / 400, 0, 1)) }
        let lightTxt: String
        if let amb = f.ambient {
            lightTxt = amb < 120 ? "too dark" : amb < 400 ? "dim" : "good"
        } else {
            lightTxt = f.rgb == nil ? "unknown" : luma < 35 ? "too dark" : luma < 70 ? "dim" : "good"
        }
        S["light"] = Signal(text: lightTxt + (f.ambient != nil ? " · \(Int(f.ambient!)) lm" : ""), conf: 1, lean: 0, v: f.ambient ?? luma)

        // ---- blinks ----
        let bl = f.blink
        if !blinkOn && bl > 0.5 {
            blinkOn = true; blinkStart = now
        } else if blinkOn && bl < 0.3 {
            blinkOn = false
            let d = (now - blinkStart) * 1000
            if d > 40 && d < 700 {
                blinks.append(now); blinkLens.append(d)
                if blinkLens.count > 10 { blinkLens.removeFirst() }
            }
        }
        blinks.removeAll { now - $0 > 60 }
        let span = min(60, max(15, now - t0))
        let bpm = Double(blinks.count) * 60 / span
        let brC = clamp((now - t0) / 40, 0, 1) * 0.9
        let blen = blinkLens.isEmpty ? 0 : blinkLens.reduce(0, +) / Double(blinkLens.count)
        let blC = fpsC * clamp(Double(blinkLens.count) / 4, 0, 1) * 0.9   // the TrueDepth camera times blinks well

        // ---- eye jumps (saccades), radians per second ----
        let eyeOpen = bl < 0.35
        if eyeOpen, let p = prevEye, dt > 0, dt < 0.12 {
            let v = hypot(f.ex - p.0, f.ey - p.1) / dt
            if v < velFloor * 3 { velFloor += (v - velFloor) * rate(0.02, dt) }
            if v > max(4 * velFloor, 1.2) && now - lastSacc > 0.15 { saccades.append(now); lastSacc = now }
        }
        prevEye = eyeOpen ? (f.ex, f.ey) : nil
        saccades.removeAll { now - $0 > 30 }
        let sRate = Double(saccades.count) * 60 / min(30, max(10, now - t0))
        let sC = fpsC * clamp((now - t0) / 15, 0, 1) * 0.85

        // ---- lids, brow, squint, jaw ----
        let openness = 1 - bl
        var lidRel = 1.0
        if eyeOpen { let base = lidT.add(openness, learning); lidRel = base > 0 ? openness / base : 1 }
        let faceC = clamp(0.6 + lightC, 0, 1)   // depth tracking works in the dark, so expression scores stay usable
        let tBrow = clamp((f.brow - browF.add(f.brow, learning, dt) - 0.04) / 0.22, 0, 1)
        let tJaw = clamp((f.jaw - jawF.add(f.jaw, learning, dt) - 0.04) / 0.25, 0, 1)
        let tSquint = clamp((f.squint - squintF.add(f.squint, learning, dt) - 0.05) / 0.25, 0, 1)
        let tWide = clamp((f.wide - wideF.add(f.wide, learning, dt) - 0.06) / 0.25, 0, 1)

        // ---- slow head motion for breathing ----
        motion.append(TimedSample(t: now, v: [f.headY, f.headZ]))
        trim(&motion, now, 34)

        // ---- spectra, once a second ----
        if now - lastSpec > 1 { lastSpec = now; spectra(now, lightC: lightC, headStill: f.s2, fpsC: fpsC) }

        // ---- per-signal readout ----
        S["gaze"] = Signal(text: "\(Int((f.s1 * 100).rounded()))%", conf: 0.95, lean: 0, v: f.s1)
        S["sacc"] = Signal(text: "\(Int(sRate.rounded()))/min", conf: sC, lean: sRate > 45 ? -1 : 0, v: sRate)
        S["head"] = Signal(text: "\(Int((f.s2 * 100).rounded()))%", conf: 0.95, lean: 0, v: f.s2)
        S["brate"] = Signal(text: "\(Int(bpm.rounded()))/min", conf: brC, lean: bpm < 5 ? 1 : bpm <= 22 ? -2 : 0, v: bpm)
        S["blen"] = Signal(text: blen > 0 ? "\(Int(blen.rounded())) ms" : "—", conf: blC,
                           lean: blen > 0 && blen < 120 ? 1 : blen >= 180 ? -2 : 0, v: blen)
        let lidTxt = tSquint > 0.4 ? "squint" : tWide > 0.4 ? "wide" : lidRel < 0.62 ? "heavy" : lidRel < 0.95 ? "soft" : "open"
        S["lids"] = Signal(text: lidTxt, conf: faceC * 0.9, lean: lidTxt == "squint" || lidTxt == "wide" ? 1 : lidTxt == "soft" ? -2 : 0, v: lidRel)
        S["brow"] = Signal(text: tBrow > 0.5 ? "tense" : tBrow > 0.2 ? "slight" : "relaxed", conf: faceC * 0.9, lean: tBrow > 0.35 ? 1 : -2, v: tBrow)
        S["jaw"] = Signal(text: tJaw > 0.5 ? "tense" : tJaw > 0.2 ? "slight" : "relaxed", conf: faceC * 0.85, lean: tJaw > 0.35 ? 1 : -2, v: tJaw)
        let hb = hrBase.v ?? 0
        let trend = hrTrendSlope()
        let hrC = hrConf, hrvC = hrvConf, brthC = brConf
        var hrLean = 0
        if hrC > 0.15 && hb > 0 { hrLean = hr > hb + 4 ? 1 : hr <= hb ? -2 : 0 }
        S["hr"] = Signal(text: hrC > 0.15 ? "\(Int(hr.rounded())) bpm" + (trend < -0.04 ? " ↓" : trend > 0.04 ? " ↑" : "") : "—",
                         conf: hrC, lean: hrLean, v: hr)
        let hvb = hrvBase.v ?? 0
        var hrvLean = 0
        if hrvC > 0.1 && hvb > 0 { hrvLean = hrv < hvb * 0.8 ? 1 : hrv > hvb * 1.05 ? -2 : 0 }
        S["hrv"] = Signal(text: hrvC > 0.1 ? "\(Int(hrv.rounded())) ms" : "—", conf: hrvC, lean: hrvLean, v: hrv)
        S["breath"] = Signal(text: brthC > 0.15 ? String(format: "%.1f/min", br) : "—", conf: brthC,
                             lean: brthC > 0.15 ? (br <= 10 ? -2 : br > 18 ? 1 : 0) : 0, v: br)
        S["pupil"] = Signal(text: "not available to apps", conf: 0, lean: 0, v: 0)

        // ---- tense and mellow ----
        let hrUp = hb > 0 ? clamp((hr - hb - 3) / 8, 0, 1) : 0
        let hrDown = hb > 0 ? clamp(0.5 + (hb - hr) / 8, 0, 1) : 0.5
        let T: [(Double, Double, Double)] = [
            (tBrow, 1.0, faceC), (tSquint, 0.8, faceC), (tJaw, 0.8, faceC), (tWide, 0.5, faceC),
            (bpm < 5 ? 1 : bpm < 8 ? 0.5 : 0, 1.0, brC),
            (blen > 0 && blen < 120 ? 1 : blen > 0 && blen < 150 ? 0.4 : 0, 0.5, blC),
            (hrUp, 0.8, hrC),
            (hvb > 0 ? clamp((hvb * 0.85 - hrv) / (hvb * 0.4), 0, 1) : 0, 0.4, hrvC),
            (br > 18 ? clamp((br - 18) / 6, 0, 1) : 0, 0.4, brthC)
        ]
        let soft: Double = (lidRel >= 0.62 && lidRel < 0.97 && tSquint < 0.3) ? 1 : (lidRel < 0.62 ? 0.5 : 0.2)
        let M: [(Double, Double, Double)] = [
            (soft, 1.0, faceC * 0.9), (1 - max(tBrow, tJaw, tSquint), 1.0, faceC),
            (bpm >= 5 && bpm <= 22 ? 1 : 0.2, 0.8, brC),
            (blen >= 180 ? 1 : blen >= 140 ? 0.5 : 0, 0.6, blC),
            (hrDown * (trend < 0 ? 1 : 0.7), 0.7, hrC),
            (hvb > 0 ? clamp(0.5 + (hrv - hvb) / (hvb * 0.5), 0, 1) : 0.5, 0.4, hrvC),
            (br > 0 ? clamp((16 - br) / 6, 0, 1) : 0, 0.9, brthC)
        ]
        func wavg(_ a: [(Double, Double, Double)]) -> Double {
            var s = 0.0, w = 0.0
            for (v, wt, c) in a where c >= 0.25 { s += v * wt * c; w += wt * c }
            return w > 0 ? s / w : 0
        }
        let still = clamp((0.42 * f.s1 + 0.25 * f.s2 + 0.15 * f.s3 + 0.18 * clamp(1 - (sRate - 15) / 40, 0, 1)) * (0.5 + 0.5 * f.s2), 0, 1)
        out.tension = tE.f(wavg(T), dt)
        out.mellow = mE.f(wavg(M), dt)
        out.still = sE.f(still, dt)

        let c: Verdict
        if !f.looking { c = .paused }
        else if learning { c = .learning }
        else if out.still < 0.5 { c = .restless }
        else if out.tension >= 0.42 && out.tension > out.mellow - 0.12 { c = .tense }
        else if out.mellow >= 0.55 && out.tension < 0.38 && out.still >= 0.7 { c = .mellow }
        else { c = .settling }
        if c != cand { cand = c; candT = 0 } else { candT += dt }
        if c != verdict && (candT > 1.5 || c == .paused || verdict == .learning) { verdict = c }
        out.verdict = verdict
        out.hr = hr
        out.hrConf = hrC
        out.signals = S
        return out
    }

    private func trim(_ a: inout [TimedSample], _ now: Double, _ secs: Double) {
        var k = 0
        while k < a.count && now - a[k].t > secs { k += 1 }
        if k > 0 { a.removeFirst(k) }
    }

    private func hrTrendSlope() -> Double {
        let a = hrTrend
        guard a.count >= 6 else { return 0 }
        let tt0 = a[0].t
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for p in a { let x = p.t - tt0; n += 1; sx += x; sy += p.v; sxx += x * x; sxy += x * p.v }
        let d = n * sxx - sx * sx
        return d != 0 ? (n * sxy - sx * sy) / d : 0
    }

    private func spectra(_ now: Double, lightC: Double, headStill: Double, fpsC: Double) {
        // heart rate from the last 12 s of skin colour (a hint: it needs light on the face)
        let buf = rgb
        if buf.count > 120, let first = buf.first, let last = buf.last, now - first.t > 9 {
            let fs = 30.0, t1 = last.t, tStart = max(first.t, t1 - 12)
            let ch = DSP.resample(buf, dims: 3, t0: tStart, t1: t1, fs: fs)
            let h = DSP.detrend(DSP.posPulse(ch[0], ch[1], ch[2], fs: fs), Int((fs * 1.2).rounded()))
            let pk = DSP.peak(DSP.spectrum(h, fs: fs, f0: 0.7, f1: 3.0, step: 1.0 / 60), halfBand: 0.1, harmonic: true)
            let bpm = pk.f * 60
            let conf = clamp((pk.q - 0.25) / 0.45, 0, 1) * lightC * clamp((headStill - 0.2) / 0.5, 0, 1) * fpsC
            if conf > 0.1 {
                hrHist.append(bpm)
                if hrHist.count > 5 { hrHist.removeFirst() }
                let s = hrHist.sorted()
                hr = s[s.count / 2]
            }
            hrConf = hrConf * 0.5 + conf * 0.5
            if hrConf > 0.35 { _ = hrBase.add(hr, now - t0 < 60); hrTrend.append((now, hr)) }
            hrTrend.removeAll { now - $0.t > 45 }

            // variability: beat to beat timing over the last 30 s
            hrvConf = 0
            if hrConf > 0.4 && now - first.t > 25 {
                let u0 = max(first.t, t1 - 30)
                let c2 = DSP.resample(buf, dims: 3, t0: u0, t1: t1, fs: fs)
                let x = DSP.movAvg(DSP.detrend(DSP.posPulse(c2[0], c2[1], c2[2], fs: fs), Int((fs * 0.9).rounded())), 3)
                let per = fs * 60 / max(40, hr), minGap = (per * 0.6).rounded(.down)
                var pks: [Double] = []
                if x.count > 2 {
                    for i in 1..<(x.count - 1) where x[i] > 0 && x[i] >= x[i - 1] && x[i] > x[i + 1] {
                        let a = x[i - 1], b = x[i], c = x[i + 1], den = a - 2 * b + c
                        let ti = Double(i) + (den != 0 ? clamp(0.5 * (a - c) / den, -0.5, 0.5) : 0)
                        if let lastPk = pks.last, ti - lastPk < minGap {
                            if b > x[Int(lastPk.rounded())] { pks[pks.count - 1] = ti }
                        } else {
                            pks.append(ti)
                        }
                    }
                }
                var ibi: [Double] = []
                if pks.count > 1 { for i in 1..<pks.count { ibi.append((pks[i] - pks[i - 1]) / fs * 1000) } }
                let sortedIbi = ibi.sorted()
                let med = sortedIbi.isEmpty ? 0 : sortedIbi[sortedIbi.count / 2]
                let good = ibi.filter { abs($0 - med) < med * 0.22 }
                if good.count >= 12 {
                    var s = 0.0, n = 0.0
                    for i in 1..<good.count { s += (good[i] - good[i - 1]) * (good[i] - good[i - 1]); n += 1 }
                    let r = (s / max(1, n)).squareRoot()
                    hrv = hrv > 0 ? lerp(hrv, r, 0.3) : r
                    hrvConf = clamp(hrConf * 0.6 * (Double(good.count) / Double(max(1, ibi.count))) * fpsC, 0, 0.6)
                    if hrvConf > 0.25 { _ = hrvBase.add(hrv, now - t0 < 90) }
                }
            }
        } else {
            hrConf *= 0.8
        }

        // breathing from slow head rise and fall (the depth camera measures this well)
        let m = motion
        if m.count > 200, let first = m.first, let last = m.last, now - first.t > 20 {
            let fs = 10.0, t1 = last.t, tStart = max(first.t, t1 - 32)
            let ch = DSP.resample(m, dims: 2, t0: tStart, t1: t1, fs: fs)
            let y = DSP.detrend(ch[0], Int(fs * 12)), z = DSP.detrend(ch[1], Int(fs * 12))
            let a = DSP.peak(DSP.spectrum(y, fs: fs, f0: 0.1, f1: 0.6, step: 0.005), halfBand: 0.03, harmonic: false)
            let b = DSP.peak(DSP.spectrum(z, fs: fs, f0: 0.1, f1: 0.6, step: 0.005), halfBand: 0.03, harmonic: false)
            let best = a.q >= b.q ? a : b
            let conf = clamp((best.q - 0.3) / 0.4, 0, 1) * clamp((headStill - 0.3) / 0.5, 0, 1) * clamp((t1 - tStart - 20) / 10 + 0.5, 0, 1)
            if conf > 0.1 { br = br > 0 ? lerp(br, best.f * 60, 0.35) : best.f * 60 }
            brConf = brConf * 0.5 + conf * 0.5
        }
    }
}
