import Foundation

/// A one-time eye calibration, saved on the phone so it is done once, not every session.
///
/// The Face ID camera's gaze reading has two faults that differ from person to person. It moves too
/// little or too much for a given look (the gains), and the shape of the eyelids bends it: opening the
/// eyes wide, squinting, or lids that relax as you calm down all shift where it thinks you look,
/// mostly up and down. The calibration measures both: a dot visits the middle and four corners, then
/// asks for wide eyes and a squint while you keep looking at the middle. Nothing leaves the phone.
struct GazeCal: Codable, Equatable {
    /// metres the gaze hit moves on the camera's x (screen down) for each metre the target moves down
    var gDown: Double
    /// metres the gaze hit moves on the camera's y (screen right) for each metre the target moves right
    var gRight: Double
    /// how far the lids bend the reading, in radians per unit of lid shape (times eye distance = metres)
    var kDown: Double
    var kRight: Double
    /// the lid shape when looking at the middle with relaxed eyes
    var lidRef: Double
    /// fit error, metres
    var rms: Double
    var date: Date

    private static let key = "nmind.gazecal.v1"

    static func load() -> GazeCal? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GazeCal.self, from: d)
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: GazeCal.key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// One step of the calibration as the screen shows it.
struct CalibDot: Equatable {
    var x = 0.5, y = Engine.homeY
    var text = "Look at the dot"
    var note = ""
    var step = 0, total = CalibPlan.steps.count
    /// 0...1, how much of this step is done
    var fill = 0.0
}

enum CalibPlan {
    struct Step {
        let x: Double, y: Double
        let text: String
        /// true when the eyes stay on the middle and only the lids change
        let lid: Bool
        let settle: Double
    }

    static let collect = 1.1
    static let steps: [Step] = [
        Step(x: 0.5, y: Engine.homeY, text: "Look at the dot. Keep your head still and move only your eyes.", lid: false, settle: 1.6),
        Step(x: 0.15, y: 0.13, text: "Follow the dot with your eyes", lid: false, settle: 0.9),
        Step(x: 0.85, y: 0.13, text: "Follow the dot with your eyes", lid: false, settle: 0.9),
        Step(x: 0.85, y: 0.87, text: "Follow the dot with your eyes", lid: false, settle: 0.9),
        Step(x: 0.15, y: 0.87, text: "Follow the dot with your eyes", lid: false, settle: 0.9),
        Step(x: 0.5, y: Engine.homeY, text: "Back to the middle, eyes relaxed", lid: false, settle: 1.0),
        Step(x: 0.5, y: Engine.homeY, text: "Stay on the dot and open your eyes wide", lid: true, settle: 1.3),
        Step(x: 0.5, y: Engine.homeY, text: "Stay on the dot and squint a little", lid: true, settle: 1.3),
    ]

    /// Median of a list (the middle value), robust to a stray frame or a half blink.
    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    struct Row { let ox: Double, oy: Double, hx: Double, hy: Double, lid: Double, dist: Double, center: Bool, relaxed: Bool }

    /// Fits the calibration from one row per step. Returns nil if it doesn't hold together.
    static func fit(_ rows: [Row]) -> GazeCal? {
        let mid = rows.filter { $0.center }
        let relaxed = rows.filter { $0.relaxed }
        guard rows.filter({ !$0.center }).count == 4, !relaxed.isEmpty else { return nil }
        let lidRef = relaxed.map { $0.lid }.reduce(0, +) / Double(relaxed.count)

        // Lid bend, from the steps where only the lids change: the hit against eye distance times
        // the change in lid shape. Ridge pulls a weak fit toward no bend at all.
        func lidSlope(_ h: (Row) -> Double) -> Double {
            let xs = mid.map { $0.dist * ($0.lid - lidRef) }, ys = mid.map(h)
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var sxx = 0.0, sxy = 0.0
            for i in 0..<xs.count { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
            guard mid.count >= 3, (sxx / n).squareRoot() > 0.012 else { return 0 }   // lids barely changed
            return max(-0.6, min(0.6, sxy / (sxx + 0.0004)))
        }
        let kDown = lidSlope { $0.hx }, kRight = lidSlope { $0.hy }

        // Gains, from the dot's five places, with the lid bend taken out first.
        let pts = rows.filter { !$0.center || $0.relaxed }
        func line(_ u: [Double], _ v: [Double]) -> (g: Double, c: Double, res: [Double]) {
            let n = Double(u.count)
            let mu = u.reduce(0, +) / n, mv = v.reduce(0, +) / n
            var suu = 0.0, suv = 0.0
            for i in 0..<u.count { suu += (u[i] - mu) * (u[i] - mu); suv += (u[i] - mu) * (v[i] - mv) }
            let g = suu > 1e-9 ? suv / suu : 0
            let c = mv - g * mu
            return (g, c, (0..<u.count).map { v[$0] - (g * u[$0] + c) })
        }
        let down = line(pts.map { $0.oy }, pts.map { $0.hx - kDown * $0.dist * ($0.lid - lidRef) })
        let right = line(pts.map { $0.ox }, pts.map { $0.hy - kRight * $0.dist * ($0.lid - lidRef) })
        let all = down.res + right.res
        let rms = (all.map { $0 * $0 }.reduce(0, +) / Double(max(1, all.count))).squareRoot()
        let ok = (0.3...4.0).contains(abs(down.g)) && (0.3...4.0).contains(abs(right.g)) && rms < 0.022
        guard ok else { return nil }
        return GazeCal(gDown: down.g, gRight: right.g, kDown: kDown, kRight: kRight, lidRef: lidRef, rms: rms, date: Date())
    }
}
