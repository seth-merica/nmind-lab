import SwiftUI

// Nmind geometric void, native version (a port of void.mjs). Layers of geometry sit one behind
// another; mellow calm moves you inward, so far layers grow toward you and pass by. New shape
// families and colour worlds open the deeper you go. Every change is eased: nothing flashes.
// Fold counts skip 6, and star figures are only drawn with 7 or more points, so no six-pointed
// star can appear.

private let TAU = Double.pi * 2
private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }
private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

enum VoidWorld {
    static let folds = [5, 7, 8, 9, 10, 11, 12]
    static let families = ["rosette", "seed", "polygon", "spiral", "lattice", "lotus", "fractal"]
    static let levelAt: [Double] = [0, 3, 6, 10, 14, 19, 25]
    static let hues: [Double] = [262, 174, 288, 208, 326, 150, 48]
    static let names = ["Deep ocean", "Teal reef", "Violet drift", "Azure", "Rose nebula", "Sea glass", "Gold", "Prism"]
    static func level(_ z: Double) -> Int {
        var l = 0
        for (i, a) in levelAt.enumerated() where z >= a { l = i }
        return l
    }
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
    var I: Double          // intricacy 0..1
    var vib: Double        // vibrancy 0..1
    var wash: Double       // 0 full colour, 1 washed out
    var alpha: Double
    var scatter: Double
    var speed: Double      // travel, layers per second
    var dt: Double
    var reduce: Bool
}

final class VoidRenderer {
    struct Spec { var fam: String; var folds: Int; var hue: Double; var hue2: Double; var spin: Double; var rot: Double; var seed: Double }
    struct Mote { var a: Double; var d: Double; var s: Double }

    var Z = 0.0
    private var t = 0.0
    private var specs: [Int: Spec] = [:]
    private var motes: [Mote] = []

    init() {
        var r = XorShift(99)
        for _ in 0..<70 { motes.append(Mote(a: r.next() * TAU, d: r.next() * 8, s: 0.5 + r.next())) }
    }

    private func spec(_ k: Int) -> Spec {
        if let s = specs[k] { return s }
        let L = VoidWorld.level(Double(max(0, k - 6)))
        var r = XorShift(k * 7919 + 13)
        let open = min(VoidWorld.families.count, L + 2)
        let fam = VoidWorld.families[min(open - 1, Int(r.next() * Double(open)))]
        let folds = VoidWorld.folds[min(VoidWorld.folds.count - 1, Int(r.next() * Double(VoidWorld.folds.count)))]
        let prism = L >= 7 || Double(k) > VoidWorld.levelAt[6] + 8
        let hue = prism ? r.next() * 360 : VoidWorld.hues[min(L, VoidWorld.hues.count - 1)] + (r.next() - 0.5) * 60
        let hue2 = (hue + 40 + r.next() * 110).truncatingRemainder(dividingBy: 360)
        let spin = (r.next() < 0.5 ? -1.0 : 1.0) * (0.03 + r.next() * 0.06)
        let s = Spec(fam: fam, folds: folds, hue: hue, hue2: hue2, spin: spin, rot: r.next() * TAU, seed: r.next() * 100)
        specs[k] = s
        for kk in specs.keys where kk < k - 14 { specs[kk] = nil }
        return s
    }

    private func col(_ h: Double, _ st: VoidState, _ a: Double, _ lift: Double = 0) -> Color {
        let sat = lerp(14, 96, st.vib) * (1 - st.wash * 0.85)
        let li = clamp(lerp(36, 64, st.vib) + lift, 10, 92)
        return hsl(h, sat, li, a)
    }

    func draw(_ ctx: inout GraphicsContext, center: CGPoint, st: VoidState) {
        t += st.dt * (st.reduce ? 0.25 : 1)
        var c = ctx
        c.translateBy(x: center.x, y: center.y)
        c.blendMode = .plusLighter
        let R = st.R

        // the void's heart: a soft glow that warms with depth
        let hueC = VoidWorld.hues[min(VoidWorld.level(Z), VoidWorld.hues.count - 1)]
        let gR = R * 0.55
        let glow = Gradient(colors: [hsl(hueC, lerp(20, 80, st.vib) * (1 - st.wash), lerp(30, 62, st.vib), 0.10 + 0.16 * st.F), .clear])
        c.fill(Path(ellipseIn: CGRect(x: -gR, y: -gR, width: gR * 2, height: gR * 2)),
               with: .radialGradient(glow, center: .zero, startRadius: 0, endRadius: gR))

        // motes stream outward while you travel
        for i in motes.indices {
            motes[i].d -= st.speed * st.dt * 1.2 + st.dt * 0.02
            if motes[i].d < -1 { motes[i].d += 8; motes[i].a = Double.random(in: 0..<TAU) }
            let m = motes[i]
            let sc = exp(-m.d * 0.55), rr = R * 1.4 * sc
            if rr > R * 1.6 { continue }
            let al = clamp((8 - m.d) / 2, 0, 1) * clamp(m.d + 1, 0, 1) * 0.5 * st.alpha
            let pr = max(0.6, 1.6 * sc * m.s)
            let x = cos(m.a) * rr, y = sin(m.a) * rr
            c.fill(Path(ellipseIn: CGRect(x: x - pr, y: y - pr, width: pr * 2, height: pr * 2)),
                   with: .color(hsl(hueC + 40, 70, 80, al * (0.3 + 0.7 * st.F))))
        }

        // layers, far to near
        let N = 7, base = Int(floor(Z))
        var j = N - 1
        while j >= -1 {
            let k = base + j, d = Double(k) - Z
            j -= 1
            if d < -0.9 { continue }
            let sc = exp(-d * 0.52), r = R * 1.18 * sc
            let a = clamp((Double(N - 1) - d) / 1.4, 0, 1) * clamp((d + 0.9) / 0.9, 0, 1) * st.alpha
            if a < 0.01 || r < 2 { continue }
            let s = spec(k)
            var lc = c
            lc.rotate(by: .radians(s.rot + t * s.spin * (0.5 + 0.8 * st.F)))
            layer(&lc, s, r, a, st)
        }
    }

    private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private func layer(_ c: inout GraphicsContext, _ s: Spec, _ r: Double, _ a: Double, _ st: VoidState) {
        let n = s.folds, I = st.I, sc = st.scatter, tt = t
        let lw = max(0.7, r / lerp(150, 230, I))
        func jit(_ i: Int, _ q: Int) -> Double { sc * r * 0.07 * sin(tt * 0.6 + Double(i) * 1.7 + Double(q) * 2.3 + s.seed) }
        let A = a * lerp(0.45, 1, st.F)
        func stroke(_ p: Path, _ color: Color) { c.stroke(p, with: .color(color), lineWidth: lw) }

        switch s.fam {
        case "rosette":
            let rings = 1 + Int((I * 3).rounded())
            for m in 0..<rings {
                let rr = r * (0.3 + 0.22 * Double(m)), pl = r * (0.2 + 0.05 * Double(m)), pw = pl * lerp(0.22, 0.34, I)
                let cnt = n * (m % 2 == 1 ? 2 : 1)
                var p = Path()
                for i in 0..<cnt {
                    let th = Double(i) * TAU / Double(cnt) + Double(m) * 0.2
                    let tr = CGAffineTransform(translationX: cos(th) * rr + jit(i, m), y: sin(th) * rr + jit(i, m + 1)).rotated(by: th)
                    p.addPath(Path(ellipseIn: CGRect(x: -pl, y: -pw, width: pl * 2, height: pw * 2)), transform: tr)
                }
                stroke(p, col(m % 2 == 1 ? s.hue2 : s.hue, st, A * (0.8 - Double(m) * 0.1), Double(m) * 4))
            }
            if I > 0.5 {
                var p = Path()
                for i in 0..<(n * 2) { let th = Double(i) * TAU / Double(n * 2); p.addPath(circle(cos(th) * r * 0.95, sin(th) * r * 0.95, r * 0.018)) }
                c.fill(p, with: .color(col(s.hue2, st, A * (I - 0.5), 18)))
            }

        case "seed":
            let cr = r * 0.46
            var p = Path()
            for i in 0..<n { let th = Double(i) * TAU / Double(n); p.addPath(circle(cos(th) * cr + jit(i, 0), sin(th) * cr + jit(i, 1), cr)) }
            stroke(p, col(s.hue, st, A * 0.7))
            if I > 0.35 {
                var p2 = Path()
                for i in 0..<n { let th = (Double(i) + 0.5) * TAU / Double(n); p2.addPath(circle(cos(th) * cr * 1.55, sin(th) * cr * 1.55, cr * 0.55)) }
                stroke(p2, col(s.hue2, st, A * (I - 0.2) * 0.8, 8))
            }
            if I > 0.7 {
                var p3 = Path()
                for i in 0..<n { let th = (Double(i) + 0.5) * TAU / Double(n); p3.addPath(circle(cos(th) * cr * 0.98, sin(th) * cr * 0.98, r * 0.016)) }
                c.fill(p3, with: .color(col(s.hue2, st, A * (I - 0.6) * 1.5, 22)))
            }

        case "polygon":
            let count = 3 + Int((I * 6).rounded()), tw = 0.14 + 0.1 * sin(tt * 0.2 + s.seed)
            for m in 0..<count {
                let rr = r * (1 - Double(m) * 0.1)
                if rr < r * 0.1 { break }
                var p = Path()
                for v in 0...n {
                    let th = Double(v) * TAU / Double(n) + Double(m) * tw
                    let pt = CGPoint(x: cos(th) * rr + jit(v, m), y: sin(th) * rr + jit(v, m + 3))
                    if v == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                stroke(p, col(m % 2 == 1 ? s.hue2 : s.hue, st, A * (0.85 - Double(m) * 0.06), Double(m) * 3))
            }
            if I > 0.45 && n >= 7 {   // star polygon {n/2} or {n/3}, never fewer than 7 points
                let k = n >= 10 ? 3 : 2
                var p = Path()
                for v in 0...n {
                    let th = Double((v * k) % n) * TAU / Double(n)
                    let pt = CGPoint(x: cos(th) * r, y: sin(th) * r)
                    if v == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                stroke(p, col(s.hue2, st, A * (I - 0.3), 12))
            }

        case "spiral":
            let steps = 24 + Int((I * 24).rounded()), turns = lerp(0.6, 1.3, I), dir: Double = s.spin > 0 ? 1 : -1
            for i in 0..<n {
                var p = Path()
                for q in 0...steps {
                    let u = Double(q) / Double(steps), rr = r * (0.06 + 0.94 * pow(u, 1.3))
                    let th = Double(i) * TAU / Double(n) + u * turns * TAU * dir
                    let pt = CGPoint(x: cos(th) * rr + jit(q, i) * u, y: sin(th) * rr + jit(q, i + 2) * u)
                    if q == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                stroke(p, col(i % 2 == 1 ? s.hue2 : s.hue, st, A * 0.8, i % 2 == 1 ? 10 : 0))
                if I > 0.4 {
                    let beads = 2 + Int((I * 4).rounded())
                    var bp = Path()
                    for b in 1...beads {
                        let u = Double(b) / Double(beads + 1), rr = r * (0.06 + 0.94 * pow(u, 1.3))
                        let th = Double(i) * TAU / Double(n) + u * turns * TAU * dir
                        bp.addPath(circle(cos(th) * rr, sin(th) * rr, r * 0.012 * (1 + u)))
                    }
                    c.fill(bp, with: .color(col(s.hue2, st, A * (I - 0.3), 20)))
                }
            }

        case "lattice":
            let rings = 2 + Int((I * 4).rounded()), cells = n * 2
            var prev: [CGPoint] = []
            for m in 0...rings {
                let rr = r * (0.2 + 0.8 * Double(m) / Double(rings)), off = Double(m % 2) * Double.pi / Double(cells)
                stroke(circle(0, 0, rr), col(s.hue, st, A * 0.45))
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
                    stroke(p, col(m % 2 == 1 ? s.hue2 : s.hue, st, A * 0.75, 6))
                }
                prev = pts
            }

        case "lotus":
            let layers = 1 + Int((I * 3).rounded())
            var m = layers - 1
            while m >= 0 {
                let len = r * (0.55 + 0.15 * Double(m)), wd = len * lerp(0.22, 0.3, I), off = Double(m) * Double.pi / Double(n)
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
                stroke(p, col(m % 2 == 1 ? s.hue2 : s.hue, st, A * (0.9 - Double(m) * 0.12), Double(m) * 6))
                if I > 0.55 {
                    var v = Path()
                    for i in 0..<n {
                        let th = Double(i) * TAU / Double(n) + off
                        v.move(to: CGPoint(x: cos(th) * r * 0.1, y: sin(th) * r * 0.1))
                        v.addLine(to: CGPoint(x: cos(th) * len * 0.85, y: sin(th) * len * 0.85))
                    }
                    stroke(v, col(s.hue2, st, A * (I - 0.45), 16))
                }
                m -= 1
            }

        default: // fractal
            let kids = min(n, 8), maxD = 1 + Int((I * 2).rounded())
            var budget = 260
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
                stroke(p, col(dep % 2 == 1 ? s.hue2 : s.hue, st, A * (0.85 - Double(dep) * 0.18), Double(dep) * 8))
            }
        }
    }
}
