import SwiftUI

// Nmind geometric void, native version. Layers of geometry sit one behind another down an
// endless tunnel; mellow calm moves you inward, so far layers grow toward you and pass by.
// Focus makes every layer brighter, more saturated and more intricate, and the deeper you go
// the more layers you see at once, the more they fold into each other, and the stronger the
// glow at the centre. Depth has no end: past the first worlds, new ones keep opening.
//
// Safety: every change is eased over a second or more and nothing pulses; repeating shapes
// pass any point well under three times a second. Fold counts skip 6, and star figures are
// only drawn with 7 or more points, so no six-pointed star can appear.

private let TAU = Double.pi * 2
private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }
private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

enum VoidWorld {
    static let folds = [5, 7, 8, 9, 10, 11, 12]
    static let families = ["rosette", "seed", "polygon", "spiral", "lattice", "lotus", "fractal"]
    static let levelAt: [Double] = [0, 3, 6, 10, 14, 19, 25]
    /// past the last fixed world, a new world opens every `endlessStep` layers, forever
    static let endlessStep = 8.0
    static let hues: [Double] = [262, 174, 288, 208, 326, 150, 48]
    static let names = ["Deep ocean", "Teal reef", "Violet drift", "Azure", "Rose nebula", "Sea glass", "Gold",
                        "Prism", "Aurora", "Inner sun", "Crystal", "Starfield", "Origin"]
    static func level(_ z: Double) -> Int {
        let last = levelAt[levelAt.count - 1]
        if z >= last { return levelAt.count - 1 + Int((z - last) / endlessStep) }
        var l = 0
        for (i, a) in levelAt.enumerated() where z >= a { l = i }
        return l
    }
    static func name(_ l: Int) -> String {
        if l < names.count { return names[l] }
        return "Beyond \(l - names.count + 2)"
    }
    /// 0 at the surface, rising toward 1 the deeper you travel
    static func deep(_ z: Double) -> Double { 1 - exp(-max(0, z) / 18) }
}

/// Small deterministic random generator (xorshift), so each layer keeps its look.
struct XorShift {
    var s: UInt32
    init(_ seed: Int) {
        let m = UInt64(truncatingIfNeeded: seed) &* 2654435761
        s = UInt32(truncatingIfNeeded: m)
        if s == 0 { s = 0x9E3779B9 }
    }
    mutating func next() -> Double {
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        return Double(s) / 4294967296.0
    }
}

func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double) -> Color {
    let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
    let ss = clamp(s / 100, 0, 1), ll = clamp(l / 100, 0, 1)
    let q = ll < 0.5 ? ll * (1 + ss) : ll + ss - ll * ss
    let p = 2 * ll - q
    func hue(_ tIn: Double) -> Double {
        var t = tIn
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 0.5 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    return Color(red: hue(hh + 1.0 / 3), green: hue(hh), blue: hue(hh - 1.0 / 3), opacity: clamp(a, 0, 1))
}

struct VoidState {
    var R: Double
    var F: Double          // focus 0..1
    var I: Double          // intricacy, 0..1.7 (above 1 adds extra rings, arms and detail)
    var vib: Double        // vibrancy, 0..1.3 (above 1 brightens past full colour)
    var wash: Double       // 0 full colour, 1 washed out
    var alpha: Double
    var scatter: Double
    var speed: Double      // travel, layers per second
    var dt: Double
    var reduce: Bool
}

final class VoidRenderer {
    struct Spec {
        var fam: String
        var fam2: String?
        var folds: Int
        var hue: Double
        var hue2: Double
        var spin: Double
        var rot: Double
        var seed: Double
    }
    struct Mote { var a: Double; var d: Double; var s: Double }

    var Z = 0.0
    private var t = 0.0
    private var specs: [Int: Spec] = [:]
    private var motes: [Mote] = []
    private var dtAvg = 1.0 / 60
    /// drawing detail, eased down if the phone can't keep a smooth frame rate
    private(set) var quality = 1.0

    init() {
        var r = XorShift(99)
        for _ in 0..<180 { motes.append(Mote(a: r.next() * TAU, d: r.next() * 10, s: 0.5 + r.next())) }
    }

    private func spec(_ k: Int) -> Spec {
        if let s = specs[k] { return s }
        let L = VoidWorld.level(Double(max(0, k - 6)))
        var r = XorShift(k * 7919 + 13)
        let open = min(VoidWorld.families.count, L + 2)
        let fam = VoidWorld.families[min(open - 1, Int(r.next() * Double(open)))]
        let folds = VoidWorld.folds[min(VoidWorld.folds.count - 1, Int(r.next() * Double(VoidWorld.folds.count)))]
        let prism = L >= 7
        let hue = prism ? r.next() * 360 : VoidWorld.hues[min(L, VoidWorld.hues.count - 1)] + (r.next() - 0.5) * 60
        let hue2 = (hue + 40 + r.next() * 110).truncatingRemainder(dividingBy: 360)
        let spin = (r.next() < 0.5 ? -1.0 : 1.0) * (0.03 + r.next() * 0.06)
        // deeper worlds fuse two families into one layer, more often the deeper you are
        let fuse = r.next() < clamp(Double(L - 4) * 0.18, 0, 0.85)
        let pick = VoidWorld.families[min(VoidWorld.families.count - 1, Int(r.next() * Double(VoidWorld.families.count)))]
        let fam2: String? = fuse && pick != fam ? pick : nil
        let s = Spec(fam: fam, fam2: fam2, folds: folds, hue: hue, hue2: hue2,
                     spin: spin, rot: r.next() * TAU, seed: r.next() * 100)
        specs[k] = s
        for kk in specs.keys where kk < k - 24 { specs[kk] = nil }
        return s
    }

    private func col(_ h: Double, _ st: VoidState, _ a: Double, _ lift: Double = 0) -> Color {
        let sat = lerp(14, 96, st.vib) * (1 - st.wash * 0.85)
        let li = clamp(lerp(36, 64, st.vib) + lift, 10, 94)
        return hsl(h, sat, li, a)
    }

    private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    func draw(_ ctx: inout GraphicsContext, center: CGPoint, st: VoidState) {
        t += st.dt * (st.reduce ? 0.25 : 1)
        dtAvg += (st.dt - dtAvg) * 0.05
        if dtAvg > 1.0 / 48 { quality = max(0.45, quality - st.dt * 0.25) }
        else if dtAvg < 1.0 / 57 { quality = min(1, quality + st.dt * 0.05) }

        let R = st.R, F = st.F
        let deep = VoidWorld.deep(Z)
        let dive = deep * F                          // how strongly the deep look shows right now
        let lvl = VoidWorld.level(Z)
        let drift = t * 3 * deep                     // slow hue drift, a few degrees a second
        let hueC = (lvl < VoidWorld.hues.count ? VoidWorld.hues[lvl] : spec(Int(floor(Z))).hue) + drift

        var c = ctx
        c.translateBy(x: center.x, y: center.y)
        c.blendMode = .plusLighter

        // the void's heart: a soft glow that widens and brightens with focus and depth
        let gR = R * (0.55 + 0.45 * dive)
        let glow = Gradient(colors: [hsl(hueC, lerp(20, 85, min(1, st.vib)) * (1 - st.wash), lerp(30, 66, min(1, st.vib)),
                                         0.10 + 0.16 * F + 0.22 * dive), .clear])
        c.fill(circle(0, 0, gR), with: .radialGradient(glow, center: .zero, startRadius: 0, endRadius: gR))
        // the light at the end of the tunnel
        let cR = R * (0.06 + 0.16 * dive)
        let core = Gradient(colors: [hsl(hueC + 30, 40 * (1 - st.wash), 88, (0.08 + 0.55 * dive) * st.alpha), .clear])
        c.fill(circle(0, 0, cR), with: .radialGradient(core, center: .zero, startRadius: 0, endRadius: cR))

        tunnel(&c, R: R, st: st, dive: dive, hue: hueC)

        // motes stream outward while you travel; more of them, the deeper you are
        let moteN = min(motes.count, Int(Double(motes.count) * (0.35 + 0.65 * deep) * quality))
        var moteP = Path()
        var moteA = 0.0
        for i in 0..<moteN {
            motes[i].d -= st.speed * st.dt * 1.4 + st.dt * 0.03
            if motes[i].d < -1 { motes[i].d += 10; motes[i].a = Double.random(in: 0..<TAU) }
            let m = motes[i]
            let sc = exp(-m.d * 0.5), rr = R * 1.5 * sc
            if rr > R * 1.8 { continue }
            let pr = max(0.6, 1.8 * sc * m.s)
            moteP.addPath(circle(cos(m.a) * rr, sin(m.a) * rr, pr))
            moteA += clamp((10 - m.d) / 2, 0, 1) * clamp(m.d + 1, 0, 1)
        }
        if moteN > 0 {
            let al = 0.42 * st.alpha * (0.3 + 0.7 * F) * (moteA / Double(moteN))
            c.fill(moteP, with: .color(hsl(hueC + 40, 70, 82, al)))
        }

        // layers, far to near; more of them stay visible as you go deeper
        let N = 7 + Int((7 * deep * quality).rounded())
        let fall = lerp(0.52, 0.34, deep)
        let base = Int(floor(Z))
        let echo = clamp((deep - 0.15) / 0.5, 0, 1) * clamp((F - 0.35) / 0.4, 0, 1)
        var j = N - 1
        while j >= -1 {
            let k = base + j, d = Double(k) - Z
            j -= 1
            if d < -0.9 { continue }
            let sc = exp(-d * fall), r = R * 1.18 * sc
            let a = clamp((Double(N - 1) - d) / 1.8, 0, 1) * clamp((d + 0.9) / 0.9, 0, 1) * st.alpha
            if a < 0.01 || r < 2 { continue }
            var s = spec(k)
            s.hue += drift
            s.hue2 += drift
            var lc = c
            lc.rotate(by: .radians(s.rot + t * s.spin * (0.5 + 0.8 * F)))
            // near layers carry a glow; the glow strengthens with focus and depth
            let glowAmt = quality > 0.6 && d < 3.5 ? clamp(F * 1.2 - 0.3, 0, 1) * (0.5 + 0.5 * deep) : 0
            family(lc, s.fam, s, r, a, st, glowAmt, swap: false)
            if let f2 = s.fam2 {
                var l2 = lc
                l2.rotate(by: .radians(Double.pi / Double(s.folds)))
                family(l2, f2, s, r * 0.72, a * 0.8, st, glowAmt * 0.6, swap: true)
            }
            // a counter-turning echo nested inside: the layer repeats within itself as you go deeper
            if echo > 0.02 && quality > 0.55 && d < 5 {
                var ec = c
                ec.rotate(by: .radians(s.rot - t * s.spin * 1.3 + Double.pi / Double(s.folds)))
                family(ec, s.fam, s, r * 0.5, a * 0.6 * echo, st, 0, swap: true)
                if echo > 0.6 && d < 2.5 {
                    var e2 = c
                    e2.rotate(by: .radians(s.rot + t * s.spin * 1.7))
                    family(e2, s.fam, s, r * 0.25, a * (echo - 0.5), st, 0, swap: false)
                }
            }
        }

        // a soft dark edge pulls the eye inward
        let vR = R * 2.2
        let vig = Gradient(stops: [Gradient.Stop(color: .clear, location: 0.45),
                                   Gradient.Stop(color: Color.black.opacity(0.25 + 0.35 * dive), location: 1)])
        var vc = ctx
        vc.translateBy(x: center.x, y: center.y)
        vc.fill(circle(0, 0, vR), with: .radialGradient(vig, center: .zero, startRadius: 0, endRadius: vR))
    }

    /// Faint tunnel walls: spokes running into the vanishing point and rings sliding outward as you travel.
    private func tunnel(_ c: inout GraphicsContext, R: Double, st: VoidState, dive: Double, hue: Double) {
        let wall = (0.03 + 0.14 * dive) * st.alpha
        if wall < 0.035 { return }
        let n = spec(Int(floor(Z))).folds * 2
        var tc = c
        tc.rotate(by: .radians(t * 0.015))
        var sp = Path()
        for i in 0..<n {
            let th = Double(i) * TAU / Double(n)
            sp.move(to: CGPoint(x: cos(th) * R * 0.05, y: sin(th) * R * 0.05))
            sp.addLine(to: CGPoint(x: cos(th) * R * 1.9, y: sin(th) * R * 1.9))
        }
        tc.stroke(sp, with: .color(hsl(hue, 60 * (1 - st.wash), 60, wall * 0.7)), lineWidth: 0.8)
        // two rings per layer of depth; at full travel speed each point sees well under one ring a second
        let ringsPer = 2.0
        let first = floor(Z * ringsPer)
        for q in 0..<Int(14 * ringsPer) {
            let d = (first + Double(q)) / ringsPer - Z
            if d < -0.6 { continue }
            let rr = R * 1.5 * exp(-d * 0.42)
            if rr < 3 { break }
            let a = wall * clamp((d + 0.6) / 0.6, 0, 1) * clamp((14 - d) / 4, 0, 1)
            tc.stroke(circle(0, 0, rr), with: .color(hsl(hue + d * 6, 55 * (1 - st.wash), 62, a)), lineWidth: 0.9)
        }
    }

    private func family(_ c: GraphicsContext, _ fam: String, _ s: Spec, _ r: Double, _ a: Double,
                        _ st: VoidState, _ glow: Double, swap: Bool) {
        let n = s.folds, I = st.I, sc = st.scatter, tt = t
        let h1 = swap ? s.hue2 : s.hue, h2 = swap ? s.hue : s.hue2
        let lw = max(0.7, r / lerp(150, 230, min(I, 1.3)))
        func jit(_ i: Int, _ q: Int) -> Double { sc * r * 0.07 * sin(tt * 0.6 + Double(i) * 1.7 + Double(q) * 2.3 + s.seed) }
        let A = a * lerp(0.45, 1, st.F)
        let gc = c
        func stroke(_ p: Path, _ h: Double, _ al: Double, _ lift: Double = 0) {
            if glow > 0.02 {
                gc.stroke(p, with: .color(col(h, st, al * 0.22 * glow, lift + 6)), lineWidth: lw * 4)
            }
            gc.stroke(p, with: .color(col(h, st, al, lift)), lineWidth: lw)
        }
        func fill(_ p: Path, _ h: Double, _ al: Double, _ lift: Double = 0) {
            gc.fill(p, with: .color(col(h, st, al, lift)))
        }

        switch fam {
        case "rosette":
            let rings = 1 + Int((I * 3).rounded())
            for m in 0..<rings {
                let rr = r * (0.3 + 0.2 * Double(m)), pl = r * (0.2 + 0.045 * Double(m)), pw = pl * lerp(0.22, 0.34, min(I, 1))
                let cnt = n * (m % 2 == 1 ? 2 : 1)
                var p = Path()
                for i in 0..<cnt {
                    let th = Double(i) * TAU / Double(cnt) + Double(m) * 0.2
                    let tr = CGAffineTransform(translationX: cos(th) * rr + jit(i, m), y: sin(th) * rr + jit(i, m + 1)).rotated(by: th)
                    p.addPath(Path(ellipseIn: CGRect(x: -pl, y: -pw, width: pl * 2, height: pw * 2)), transform: tr)
                }
                stroke(p, m % 2 == 1 ? h2 : h1, A * max(0.25, 0.8 - Double(m) * 0.1), Double(m) * 4)
            }
            if I > 0.5 {
                var p = Path()
                let dots = n * (I > 1.2 ? 4 : 2)
                for i in 0..<dots { let th = Double(i) * TAU / Double(dots); p.addPath(circle(cos(th) * r * 0.95, sin(th) * r * 0.95, r * 0.018)) }
                fill(p, h2, A * min(1, I - 0.5), 18)
            }

        case "seed":
            let cr = r * 0.46
            var p = Path()
            for i in 0..<n { let th = Double(i) * TAU / Double(n); p.addPath(circle(cos(th) * cr + jit(i, 0), sin(th) * cr + jit(i, 1), cr)) }
            stroke(p, h1, A * 0.7)
            if I > 0.35 {
                var p2 = Path()
                for i in 0..<n { let th = (Double(i) + 0.5) * TAU / Double(n); p2.addPath(circle(cos(th) * cr * 1.55, sin(th) * cr * 1.55, cr * 0.55)) }
                stroke(p2, h2, A * min(0.9, (I - 0.2) * 0.8), 8)
            }
            if I > 0.7 {
                var p3 = Path()
                for i in 0..<n { let th = (Double(i) + 0.5) * TAU / Double(n); p3.addPath(circle(cos(th) * cr * 0.98, sin(th) * cr * 0.98, r * 0.016)) }
                fill(p3, h2, A * min(1, (I - 0.6) * 1.5), 22)
            }
            if I > 1.05 {   // an inner bloom of small circles
                var p4 = Path()
                for i in 0..<(n * 2) { let th = Double(i) * TAU / Double(n * 2); p4.addPath(circle(cos(th) * cr * 0.5, sin(th) * cr * 0.5, cr * 0.26)) }
                stroke(p4, h1, A * min(0.8, (I - 1) * 1.4), 14)
            }

        case "polygon":
            let count = 3 + Int((I * 6).rounded()), tw = 0.14 + 0.1 * sin(tt * 0.2 + s.seed)
            for m in 0..<count {
                let rr = r * (1 - Double(m) * 0.075)
                if rr < r * 0.08 { break }
                var p = Path()
                for v in 0...n {
                    let th = Double(v) * TAU / Double(n) + Double(m) * tw
                    let pt = CGPoint(x: cos(th) * rr + jit(v, m), y: sin(th) * rr + jit(v, m + 3))
                    if v == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                stroke(p, m % 2 == 1 ? h2 : h1, A * max(0.2, 0.85 - Double(m) * 0.05), Double(m) * 3)
            }
            if I > 0.45 && n >= 7 {   // star polygon {n/2} or {n/3}, never fewer than 7 points
                let k = n >= 10 ? 3 : 2
                var p = Path()
                for v in 0...n {
                    let th = Double((v * k) % n) * TAU / Double(n)
                    let pt = CGPoint(x: cos(th) * r, y: sin(th) * r)
                    if v == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                stroke(p, h2, A * min(1, I - 0.3), 12)
            }

        case "spiral":
            let steps = 24 + Int((min(I, 1.4) * 24).rounded()), turns = lerp(0.6, 1.3, I), dir: Double = s.spin > 0 ? 1 : -1
            let arms = I > 1.1 ? n * 2 : n
            for i in 0..<arms {
                var p = Path()
                for q in 0...steps {
                    let u = Double(q) / Double(steps), rr = r * (0.06 + 0.94 * pow(u, 1.3))
                    let th = Double(i) * TAU / Double(arms) + u * turns * TAU * dir
                    let pt = CGPoint(x: cos(th) * rr + jit(q, i) * u, y: sin(th) * rr + jit(q, i + 2) * u)
                    if q == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                stroke(p, i % 2 == 1 ? h2 : h1, A * (i >= n ? 0.5 : 0.8), i % 2 == 1 ? 10 : 0)
                if I > 0.4 && i < n {
                    let beads = 2 + Int((min(I, 1.5) * 4).rounded())
                    var bp = Path()
                    for b in 1...beads {
                        let u = Double(b) / Double(beads + 1), rr = r * (0.06 + 0.94 * pow(u, 1.3))
                        let th = Double(i) * TAU / Double(arms) + u * turns * TAU * dir
                        bp.addPath(circle(cos(th) * rr, sin(th) * rr, r * 0.012 * (1 + u)))
                    }
                    fill(bp, h2, A * min(1, I - 0.3), 20)
                }
            }

        case "lattice":
            let rings = 2 + Int((I * 4).rounded()), cells = n * 2
            var prev: [CGPoint] = []
            for m in 0...rings {
                let rr = r * (0.2 + 0.8 * Double(m) / Double(rings)), off = Double(m % 2) * Double.pi / Double(cells)
                stroke(circle(0, 0, rr), h1, A * 0.45)
                var pts: [CGPoint] = []
                for i in 0..<cells {
                    let th = Double(i) * TAU / Double(cells) + off
                    pts.append(CGPoint(x: cos(th) * rr + jit(i, m), y: sin(th) * rr + jit(i, m + 5)))
                }
                if !prev.isEmpty {
                    var p = Path()
                    for i in 0..<cells {
                        let q2 = pts[(i + cells - (m % 2 == 1 ? 0 : 1)) % cells]
                        p.move(to: prev[i]); p.addLine(to: pts[i])
                        p.move(to: prev[i]); p.addLine(to: q2)
                    }
                    stroke(p, m % 2 == 1 ? h2 : h1, A * 0.75, 6)
                }
                prev = pts
            }

        case "lotus":
            let layers = 1 + Int((I * 3).rounded())
            var m = layers - 1
            while m >= 0 {
                let len = r * (0.5 + 0.12 * Double(m)), wd = len * lerp(0.22, 0.3, min(I, 1)), off = Double(m) * Double.pi / Double(n)
                var p = Path()
                for i in 0..<n {
                    let th = Double(i) * TAU / Double(n) + off, ca = cos(th), sa = sin(th), px = -sa, py = ca, jj = jit(i, m)
                    let b0 = r * 0.08
                    p.move(to: CGPoint(x: ca * b0, y: sa * b0))
                    p.addQuadCurve(to: CGPoint(x: ca * len + jj, y: sa * len + jj * 0.5),
                                   control: CGPoint(x: ca * len * 0.55 + px * wd, y: sa * len * 0.55 + py * wd))
                    p.addQuadCurve(to: CGPoint(x: ca * b0, y: sa * b0),
                                   control: CGPoint(x: ca * len * 0.55 - px * wd, y: sa * len * 0.55 - py * wd))
                }
                stroke(p, m % 2 == 1 ? h2 : h1, A * max(0.25, 0.9 - Double(m) * 0.12), Double(m) * 6)
                if I > 0.55 {
                    var v = Path()
                    for i in 0..<n {
                        let th = Double(i) * TAU / Double(n) + off
                        v.move(to: CGPoint(x: cos(th) * r * 0.1, y: sin(th) * r * 0.1))
                        v.addLine(to: CGPoint(x: cos(th) * len * 0.85, y: sin(th) * len * 0.85))
                    }
                    stroke(v, h2, A * min(1, I - 0.45), 16)
                }
                m -= 1
            }

        default: // fractal
            let kids = min(n, 8), maxD = 1 + Int((I * 2).rounded())
            var budget = Int(240 + 420 * quality * clamp(I - 0.8, 0, 1))
            var paths: [Int: Path] = [:]
            func rec(_ x: Double, _ y: Double, _ rr: Double, _ dep: Int) {
                if budget <= 0 { return }
                budget -= 1
                paths[dep, default: Path()].addPath(circle(x, y, rr))
                if dep >= maxD || rr < 3 { return }
                for i in 0..<kids {
                    let th = Double(i) * TAU / Double(kids) + Double(dep) * 0.4 + tt * 0.02 * (dep % 2 == 1 ? 1 : -1)
                    rec(x + cos(th) * rr * 0.62, y + sin(th) * rr * 0.62, rr * 0.34, dep + 1)
                }
            }
            rec(0, 0, r * 0.9, 0)
            for (dep, p) in paths {
                stroke(p, dep % 2 == 1 ? h2 : h1, A * max(0.2, 0.85 - Double(dep) * 0.16), Double(dep) * 8)
            }
        }
    }
}
