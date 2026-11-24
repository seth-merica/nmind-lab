import SwiftUI

enum Palette {
    static let bg = Color(red: 9 / 255, green: 10 / 255, blue: 34 / 255)
    static let teal = Color(red: 47 / 255, green: 227 / 255, blue: 200 / 255)
    static let mist = Color(red: 169 / 255, green: 165 / 255, blue: 210 / 255)
    static let foam = Color(red: 234 / 255, green: 255 / 255, blue: 250 / 255)
    static let current = Color(red: 46 / 255, green: 39 / 255, blue: 116 / 255)
    static let glass = Color(red: 18 / 255, green: 17 / 255, blue: 52 / 255).opacity(0.78)
    static let amber = Color(red: 242 / 255, green: 193 / 255, blue: 78 / 255)
    /// orange is kept for alerts only
    static let alert = Color(red: 226 / 255, green: 96 / 255, blue: 31 / 255)
}

/// Holds the drawing state between frames: the void itself and the eased look for each mode.
final class DrawState {
    let renderer = VoidRenderer()
    private var last: Date?
    private var alpha = 0.85, sat = 0.8, scale = 1.0

    func draw(_ ctx: inout GraphicsContext, size: CGSize, date: Date, engine: Engine, reduce: Bool) {
        let dt = last.map { min(0.1, max(0.001, date.timeIntervalSince($0))) } ?? 1.0 / 60
        last = date
        let live = engine.live
        let running = engine.running

        // each state has its own look; every change is eased over about a second
        let target: (Double, Double, Double)
        if !running { target = (0.85, 0.8, 1.0) }
        else {
            switch live.mode {
            case .reading: target = (1.0, 1.0, 1.0)
            case .noFace: target = (0.55, 0.5, 0.92)
            case .away: target = (0.6, 0.45, 0.95)
            case .second: target = (0.4, 0.2, 0.9)
            case .idle: target = (0.85, 0.8, 1.0)
            }
        }
        let e = min(1, dt * 1.4)
        alpha += (target.0 - alpha) * e
        sat += (target.1 - sat) * e
        scale += (target.2 - scale) * e

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.bg))
        let F = running ? live.F : 0.3
        if running { renderer.Z = live.Z }
        // focus drives intensity; depth keeps raising the ceiling, so the deeper you are,
        // the more intricate and vivid the same focus becomes
        let deep = VoidWorld.deep(renderer.Z)
        let R = min(size.width, size.height) * 0.48 * scale * (0.86 + 0.22 * F + 0.08 * deep * F)
        let st = VoidState(
            R: R, F: F,
            I: min(1.7, max(0, 0.1 + 0.65 * F + 0.95 * deep * pow(F, 1.5))),
            vib: min(1.3, max(0, 0.15 + 0.6 * F + 0.25 * live.mellow + 0.3 * deep * F)),
            wash: 1 - sat, alpha: alpha,
            scatter: max(0, 1 - F) * (1 - 0.5 * live.mellow),
            speed: max(0, live.travel), dt: dt, reduce: reduce)
        let c = CGPoint(x: size.width / 2, y: size.height * 0.42)
        renderer.draw(&ctx, center: c, st: st)

        // centre target with a focus meter around it
        if running && live.mode == .reading {
            let zr = min(size.width, size.height) * 0.1
            let ring = Path(ellipseIn: CGRect(x: c.x - zr, y: c.y - zr, width: zr * 2, height: zr * 2))
            ctx.stroke(ring, with: .color(Palette.mist.opacity(0.2)), lineWidth: 2)
            var arc = Path()
            arc.addArc(center: c, radius: zr, startAngle: .degrees(-90), endAngle: .degrees(-90 + max(0.1, F * 360)), clockwise: false)
            ctx.stroke(arc, with: .color(Palette.teal.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            let dr = 2.5 + 1.5 * F
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2)),
                     with: .color(Palette.foam.opacity(0.5 + 0.4 * F)))
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = Engine()
    @State private var drawState = DrawState()
    @State private var showPanel = false
    @State private var toast = ""
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    drawState.draw(&ctx, size: size, date: tl.date, engine: engine, reduce: reduce)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                guard engine.running else { return }
                engine.recenter()
                flash("Center set where your eyes are now")
            }

            if engine.running {
                RunningOverlay(engine: engine, panel: engine.panel, showPanel: $showPanel)
            } else {
                IntroCard(engine: engine)
            }

            if !toast.isEmpty {
                Text(toast)
                    .font(.footnote)
                    .foregroundStyle(Palette.foam)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Palette.glass))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .background(Palette.bg)
    }

    private func flash(_ text: String) {
        withAnimation(.easeInOut(duration: 0.3)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.4)) { toast = "" }
        }
    }
}

// MARK: intro

struct IntroCard: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROTOTYPE · NATIVE · FACE ID CAMERA")
                .font(.caption2.weight(.semibold)).tracking(1.2)
                .foregroundStyle(Palette.teal)
            Text("Travel into the void")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Palette.foam)
            Text("Nmind reads your eyes and face with the Face ID camera, which sees in depth and works in dim light. Steady focus makes the geometry sharper and more vibrant. Only a soft, mellow calm carries you deeper. Calm held with effort keeps you where you are.")
                .font(.subheadline)
                .foregroundStyle(Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Hold the phone at arm's length with your face in view.")
                bullet("Rest your eyes on the center, soften your gaze, let your brow and jaw go.")
                bullet("The first 20 seconds learn your resting face. Tap the screen to re-center.")
                bullet("The pulse reading is a hint and needs light on your face.")
            }
            Button(action: { engine.start() }) {
                Text("Start")
                    .font(.headline)
                    .foregroundStyle(Palette.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.teal))
            }
            .padding(.top, 4)
            if !engine.message.isEmpty {
                Text(engine.message)
                    .font(.footnote)
                    .foregroundStyle(Palette.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Everything runs on this iPhone. Nothing is saved or sent.")
                .font(.caption)
                .foregroundStyle(Palette.mist.opacity(0.8))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 22).fill(Palette.glass))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.current, lineWidth: 1))
        .padding(.horizontal, 18)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Palette.teal).frame(width: 5, height: 5).padding(.top, 6)
            Text(s).font(.footnote).foregroundStyle(Palette.mist).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: while running

struct RunningOverlay: View {
    @ObservedObject var engine: Engine
    let panel: Panel
    @Binding var showPanel: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nmind").font(.headline).foregroundStyle(Palette.foam)
                    Text("Prototype").font(.caption2).foregroundStyle(Palette.mist)
                }
                Spacer()
                pill(showPanel ? "Hide view" : "Camera view") { showPanel.toggle() }
                pill("Stop") { engine.stop() }
            }
            .padding(.horizontal, 16)

            if showPanel {
                SignalPanel(panel: panel)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    stat("\(Int((panel.F * 100).rounded()))%", "focus")
                    stat(calmShort, "calm")
                    stat("\(panel.depth + 1) · \(VoidWorld.name(panel.depth).components(separatedBy: " ").first ?? "")", "depth")
                    stat(panel.heart.map { "\($0)" } ?? "—", "heart")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(caption.0).font(.subheadline.weight(.semibold))
                        .foregroundStyle(panel.verdict == .tense && panel.mode == .reading ? Palette.amber : Palette.teal)
                    Text(caption.1).font(.footnote).foregroundStyle(Palette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.glass))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.current.opacity(0.6))
                        Capsule().fill(Palette.teal).frame(width: g.size.width * max(0.01, panel.F))
                            .animation(.easeInOut(duration: 0.4), value: panel.F)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    private var calmShort: String {
        if panel.mode != .reading { return "Paused" }
        switch panel.verdict {
        case .mellow: return "Mellow"
        case .tense: return "Tense"
        case .learning: return "Learning"
        default: return panel.verdict.rawValue
        }
    }

    private var caption: (String, String) {
        switch panel.mode {
        case .noFace, .idle: return ("Looking for you", "Hold the phone at arm's length with your face in view.")
        case .away: return ("Paused", "Look back at the center to continue.")
        case .second: return ("Paused", "Someone else is in view. Nmind pauses until it's just you.")
        case .reading: break
        }
        switch panel.verdict {
        case .learning: return ("Learning your resting face · \(panel.learnLeft)s", "Breathe normally and rest your eyes on the center.")
        case .restless: return ("Settle", "Let your eyes rest on the center. Keep your head still.")
        case .settling: return ("Settling", "Good. Breathe out slowly and let your eyes go soft.")
        case .tense: return ("Steady, but held", "You are holding it with effort. Soften your eyes, unclench your jaw, let your brow go.")
        case .mellow: return ("Mellow calm", "Easy and soft. Let it carry you deeper.")
        case .paused: return ("Paused", "Look back at the center to continue.")
        }
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(Palette.foam)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Palette.glass))
                .overlay(Capsule().stroke(Palette.current, lineWidth: 1))
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Palette.foam).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(Palette.mist)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.glass))
    }
}

// MARK: Camera view readout

struct SignalPanel: View {
    let panel: Panel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.verdict.rawValue + (panel.verdict == .learning ? " · \(panel.learnLeft)s" : ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(panel.verdict == .tense ? Palette.amber : Palette.teal)
                Text(String(format: "tense %.2f · mellow %.2f · still %.2f · center %.0f%% · %.0f fps",
                            panel.tension, panel.mellow, panel.still, panel.lock * 100, panel.fps))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.mist)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.current, lineWidth: 1))

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(CalmReader.signalOrder, id: \.0) { item in
                        let s = panel.signals[item.0] ?? Signal()
                        HStack {
                            Text(item.1).foregroundStyle(Palette.mist)
                            Spacer()
                            Text(s.text)
                                .foregroundStyle(s.conf >= 0.25 ? (s.lean > 0 ? Palette.amber : s.lean < -1 ? Palette.teal : Palette.foam) : Palette.foam.opacity(0.6))
                            HStack(spacing: 2) {
                                ForEach(0..<4, id: \.self) { i in
                                    Circle()
                                        .fill(s.conf > (Double(i) + 0.5) / 4 ? Palette.mist : Palette.mist.opacity(0.22))
                                        .frame(width: 5, height: 5)
                                }
                            }
                            .frame(width: 30, alignment: .trailing)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 4)
                        Divider().overlay(Palette.current.opacity(0.6))
                    }
                }
            }
            .frame(maxHeight: 300)

            Text("Pupil size: iOS does not give apps the raw infrared image, so it can't be read here either.")
                .font(.system(size: 10)).foregroundStyle(Palette.mist.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.glass))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.current, lineWidth: 1))
    }
}
