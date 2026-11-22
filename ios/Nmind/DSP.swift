import Foundation

// Signal processing helpers, ported from the web prototype (calm.mjs).
// Times are in seconds.

struct TimedSample {
    var t: Double
    var v: [Double]
}

enum DSP {
    static func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Linear resampling of an irregular buffer onto an even grid.
    static func resample(_ buf: [TimedSample], dims: Int, t0: Double, t1: Double, fs: Double) -> [[Double]] {
        let n = max(0, Int((t1 - t0) * fs))
        var out = Array(repeating: Array(repeating: 0.0, count: n), count: dims)
        guard !buf.isEmpty, n > 0 else { return out }
        var j = 0
        for i in 0..<n {
            let t = t0 + Double(i) / fs
            while j < buf.count - 2 && buf[j + 1].t < t { j += 1 }
            let a = buf[j]
            let b = j + 1 < buf.count ? buf[j + 1] : buf[j]
            let u = b.t > a.t ? clamp((t - a.t) / (b.t - a.t), 0, 1) : 0
            for q in 0..<dims { out[q][i] = a.v[q] + (b.v[q] - a.v[q]) * u }
        }
        return out
    }

    static func movAvg(_ x: [Double], _ w: Int) -> [Double] {
        let n = x.count
        guard n > 0 else { return [] }
        var pre = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { pre[i + 1] = pre[i] + x[i] }
        let h = max(1, w / 2)
        var o = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - h), b = min(n, i + h + 1)
            o[i] = (pre[b] - pre[a]) / Double(b - a)
        }
        return o
    }

    static func detrend(_ x: [Double], _ w: Int) -> [Double] {
        let m = movAvg(x, w)
        return zip(x, m).map { $0 - $1 }
    }

    /// Power at each frequency from f0 to f1, Hann window.
    static func spectrum(_ x: [Double], fs: Double, f0: Double, f1: Double, step: Double) -> (fr: [Double], pw: [Double]) {
        let n = x.count
        guard n >= 8 else { return ([], []) }
        let mean = x.reduce(0, +) / Double(n)
        var w = [Double](repeating: 0, count: n)
        for i in 0..<n { w[i] = (x[i] - mean) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))) }
        var fr: [Double] = [], pw: [Double] = []
        var f = f0
        while f <= f1 + 1e-9 {
            var re = 0.0, im = 0.0
            let k = 2 * Double.pi * f / fs
            for i in 0..<n {
                re += w[i] * cos(k * Double(i))
                im -= w[i] * sin(k * Double(i))
            }
            fr.append(f)
            pw.append(re * re + im * im)
            f += step
        }
        return (fr, pw)
    }

    /// Peak frequency and how far it stands above the rest of the band (0 to 1).
    static func peak(_ sp: (fr: [Double], pw: [Double]), halfBand: Double, harmonic: Bool) -> (f: Double, q: Double) {
        let fr = sp.fr, pw = sp.pw
        guard !fr.isEmpty else { return (0, 0) }
        var bi = 0
        for i in 1..<pw.count where pw[i] > pw[bi] { bi = i }
        let f = fr[bi]
        var inP = 0.0, tot = 0.0
        for i in 0..<pw.count {
            tot += pw[i]
            let d = abs(fr[i] - f)
            let d2 = harmonic ? abs(fr[i] - 2 * f) : 9
            if d <= halfBand || d2 <= halfBand { inP += pw[i] }
        }
        var fp = f
        if bi > 0 && bi < pw.count - 1 && fr.count > 1 {
            let a = pw[bi - 1], b = pw[bi], c = pw[bi + 1], den = a - 2 * b + c
            if den != 0 { fp = f + clamp(0.5 * (a - c) / den, -1, 1) * (fr[1] - fr[0]) }
        }
        return (fp, tot > 0 ? inP / tot : 0)
    }

    /// Plane-orthogonal-to-skin pulse signal (Wang et al. 2017).
    static func posPulse(_ R: [Double], _ G: [Double], _ B: [Double], fs: Double) -> [Double] {
        let n = R.count
        let L = max(8, Int((1.6 * fs).rounded()))
        var H = [Double](repeating: 0, count: n)
        guard n >= L else { return H }
        var s1 = [Double](repeating: 0, count: L), s2 = [Double](repeating: 0, count: L)
        for s in 0...(n - L) {
            var mr = 0.0, mg = 0.0, mb = 0.0
            for i in s..<(s + L) { mr += R[i]; mg += G[i]; mb += B[i] }
            mr /= Double(L); mg /= Double(L); mb /= Double(L)
            if mr <= 0 || mg <= 0 || mb <= 0 { continue }
            var a1 = 0.0, a2 = 0.0
            for i in 0..<L {
                let r = R[s + i] / mr, g = G[s + i] / mg, b = B[s + i] / mb
                s1[i] = g - b
                s2[i] = g + b - 2 * r
                a1 += s1[i]; a2 += s2[i]
            }
            a1 /= Double(L); a2 /= Double(L)
            var v1 = 0.0, v2 = 0.0
            for i in 0..<L { v1 += (s1[i] - a1) * (s1[i] - a1); v2 += (s2[i] - a2) * (s2[i] - a2) }
            let al = v2 > 0 ? (v1 / v2).squareRoot() : 0
            var hm = 0.0
            for i in 0..<L { hm += s1[i] + al * s2[i] }
            hm /= Double(L)
            for i in 0..<L { H[s + i] += s1[i] + al * s2[i] - hm }
        }
        return H
    }
}
