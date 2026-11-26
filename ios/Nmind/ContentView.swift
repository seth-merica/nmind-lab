import Combine
import SwiftUI

/// Shown on screen so you can tell which build is on the phone. Kept here, not in the Xcode
/// project file, so updates never touch the file that holds your signing settings.
enum AppInfo {
    static let version = "0.22"
}

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

/// Holds the drawing state between frames: the void's shader inputs and the eased look for each mode.
final class DrawState {
    let field = VoidField()
    private var last: Date?
    private var alpha = 0.85, sat = 0.8

    /// Advances one frame and returns the shader inputs for it.
    func frame(date: Date, engine: Engine, fade: Double, reduce: Bool) -> VoidUniforms {
        let dt = last.map { min(0.1, max(0.001, date.timeIntervalSince($0))) } ?? 1.0 / 60
        last = date
        let live = engine.live
        let running = engine.running

        // each state has its own look; every change is eased over about a second
        let target: (Double, Double)
        if !running { target = (0.85, 0.8) }
        else {
            switch live.mode {
            case .reading: target = (1.0, 1.0)
            case .noFace: target = (0.55, 0.5)
            case .away: target = (0.6, 0.45)
            case .second: target = (0.4, 0.2)
            case .idle: target = (0.85, 0.8)
            }
        }
        let e = min(1, dt * 1.4)
        // the end of a timed session dims the void with the sound
        let dim = running ? 0.25 + 0.75 * fade : 1
        alpha += (target.0 * dim - alpha) * e
        sat += (target.1 - sat) * e
        return field.update(date: date, live: live, running: running, alpha: alpha, sat: sat, reduce: reduce)
    }

    // the book feed's words in flight
    private struct Flying { let word: String; let angle: Double; let born: Double; let life: Double; let mirror: Bool; let spin: Double; var readable = false }
    private var spiral = 0.0
    private var flying: [Flying] = []
    private var wordAt = 0

    /// The book feed's words: each streams out of the far end of the tunnel along a ray, growing as it
    /// comes at you, turned and sometimes mirrored, faint and gone in under a second, so it can't be read.
    /// Every word fades in and out smoothly (no flashes), and at most about a fifth of full brightness.
    func drawBook(_ ctx: inout GraphicsContext, size: CGSize, engine: Engine) {
        let book = BookFeed.shared
        let live = engine.live
        let now = Date().timeIntervalSinceReferenceDate
        if engine.running && !engine.calibrating && book.state == .feeding {
            let target = book.wordIndex
            if target < wordAt || target - wordAt > 160 { wordAt = target }
            while wordAt < target && wordAt < book.words.count {
                let w = book.words[wordAt].trimmingCharacters(in: .punctuationCharacters)
                wordAt += 1
                if w.isEmpty || (book.sessionMode == .whole && book.inHeldOut(wordAt - 1)) { continue }
                if book.sessionMode == .whole {
                    // 14x: dozens a second, turned, mirrored and gone in half a second, never readable
                    if flying.count < 140 {
                        flying.append(Flying(word: w, angle: Double.random(in: 0..<(2 * .pi)), born: now,
                                             life: Double.random(in: 0.35...0.55), mirror: Bool.random(), spin: Double.random(in: -1.2...1.2)))
                    }
                } else if book.sessionMode == .listen {
                    // Deep Listen: upright and readable, each word on the next turn of a slow spiral
                    spiral += 2.39996
                    flying.append(Flying(word: w, angle: spiral, born: now, life: 1.5, mirror: false, spin: 0, readable: true))
                } else {
                    flying.append(Flying(word: w, angle: Double.random(in: 0..<(2 * .pi)), born: now,
                                         life: Double.random(in: 0.7...1.0), mirror: Bool.random(), spin: Double.random(in: -0.6...0.6)))
                }
            }
        }
        flying.removeAll { now - $0.born > $0.life }
        guard !flying.isEmpty else { return }
        let c = CGPoint(x: size.width * live.tx, y: size.height * live.ty)
        let reach = Double(max(size.width, size.height)) * 0.75
        let level = book.level
        for f in flying where f.readable {
            // drifts gently out from the centre and grows, fading in and out (no flashes)
            let a = (now - f.born) / f.life
            let r = 14 + reach * 0.32 * a * a
            let alpha = 0.55 * level * sin(Double.pi * a)
            let pt = CGPoint(x: c.x + CGFloat(cos(f.angle) * r), y: c.y + CGFloat(sin(f.angle) * r))
            var g = ctx
            g.opacity = alpha
            g.draw(Text(f.word).font(.system(size: CGFloat(11 + 20 * a), weight: .regular)).foregroundColor(Palette.foam), at: pt)
        }
        for f in flying where !f.readable {
            let a = (now - f.born) / f.life                   // 0 to 1 over its flight
            let r = 18 + reach * a * a                          // speeds up as it nears, like the tunnel
            let alpha = 0.2 * level * sin(Double.pi * a)        // smooth rise and fall
            let pt = CGPoint(x: c.x + CGFloat(cos(f.angle) * r), y: c.y + CGFloat(sin(f.angle) * r))
            var g = ctx
            g.translateBy(x: pt.x, y: pt.y)
            g.rotate(by: .radians(f.angle + .pi / 2 + f.spin))
            if f.mirror { g.scaleBy(x: -1, y: 1) }
            g.opacity = alpha
            let pts = CGFloat(7 + 22 * a)
            g.draw(Text(f.word).font(.system(size: pts, weight: .light)).foregroundColor(Palette.foam), at: .zero)
        }
    }

    /// Centre target with a focus meter around it, drawn over the void.
    func drawMeter(_ ctx: inout GraphicsContext, size: CGSize, engine: Engine) {
        let live = engine.live
        guard engine.running && !engine.calibrating && live.mode == .reading else { return }
        let F = live.F
        // the target sits on the far end of the tunnel and wanders with it
        let c = CGPoint(x: size.width * live.tx, y: size.height * live.ty)
        let zr = min(size.width, size.height) * 0.1
        let ring = Path(ellipseIn: CGRect(x: c.x - zr, y: c.y - zr, width: zr * 2, height: zr * 2))
        ctx.stroke(ring, with: .color(Palette.foam.opacity(0.18)), lineWidth: 2)
        var arc = Path()
        arc.addArc(center: c, radius: zr, startAngle: .degrees(-90), endAngle: .degrees(-90 + max(0.1, F * 360)), clockwise: false)
        ctx.stroke(arc, with: .color(Palette.teal.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        if live.steering {
            // a small dot in the ring shows your eyes have the wheel
            let d: CGFloat = 7
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(Palette.teal.opacity(0.9)))
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = Engine()
    @StateObject private var journey = Journey()
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State private var drawState = DrawState()
    @State private var showPanel = false
    @State private var toast = ""
    @State private var soundOn = Soundscape.shared.enabled
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            TimelineView(.animation) { tl in
                GeometryReader { geo in
                    let u = drawState.frame(date: tl.date, engine: engine, fade: journey.fade, reduce: reduce)
                    ZStack {
                        Rectangle()
                            .fill(Palette.bg)
                            .colorEffect(u.shader(size: geo.size))
                        Canvas { ctx, size in
                            drawState.drawBook(&ctx, size: size, engine: engine)
                            drawState.drawMeter(&ctx, size: size, engine: engine)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .global) { pt in
                guard engine.running && !engine.calibrating else { return }
                let b = UIScreen.main.bounds
                if engine.tap(x: Double(pt.x / max(1, b.width)), y: Double(pt.y / max(1, b.height))) {
                    flash("Tuned to where you tapped")
                } else {
                    flash("Center set where your eyes are now")
                }
            }

            if engine.running && engine.calibrating {
                CalibrationOverlay(engine: engine)
                    .transition(.opacity)
            } else if engine.running {
                RunningOverlay(engine: engine, panel: engine.panel, best: journey.record.deepest, clock: journey.clockText,
                               showPanel: $showPanel, soundOn: $soundOn)
                // every message sits in this band: below the centre target, above the stats
                GeometryReader { g in
                    MessageBand(banner: journey.banner, panel: engine.panel, toast: toast)
                        .frame(width: g.size.width - 32)
                        .position(x: g.size.width / 2, y: g.size.height * 0.665)
                }
                .allowsHitTesting(false)
            } else if let q = journey.quiz {
                QuizCard(quiz: q, done: { c, t in
                    withAnimation(.easeInOut(duration: 0.3)) { journey.finishQuiz(correct: c, total: t) }
                }, skip: {
                    withAnimation(.easeInOut(duration: 0.3)) { journey.skipQuiz() }
                })
                .transition(.opacity)
            } else if let sum = journey.summary {
                SummaryCard(summary: sum, record: journey.record) {
                    withAnimation(.easeInOut(duration: 0.3)) { journey.summary = nil }
                }
                .transition(.opacity)
            } else {
                // the start card scrolls only if it doesn't fit the screen
                ViewThatFits(in: .vertical) {
                    IntroCard(engine: engine, journey: journey, soundOn: $soundOn)
                    ScrollView(showsIndicators: false) {
                        IntroCard(engine: engine, journey: journey, soundOn: $soundOn).padding(.vertical, 24)
                    }
                }
                .transition(.opacity)
            }
        }
        .background(Palette.bg)
        .onReceive(ticker) { _ in
            journey.tick(dt: 0.25, engine: engine, field: drawState.field)
        }
        .onChange(of: engine.running) { _, _ in
            // start and stop are handled at once, so the end card shows without a flicker of the start screen
            journey.tick(dt: 0, engine: engine, field: drawState.field)
        }
        .onChange(of: engine.calibrating) { _, now in
            journey.tick(dt: 0, engine: engine, field: drawState.field)
            if !now && engine.running && !engine.calibResult.isEmpty { flash(engine.calibResult, for: 3.5) }
        }
    }

    private func flash(_ text: String, for seconds: Double = 1.6) {
        withAnimation(.easeInOut(duration: 0.3)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            withAnimation(.easeInOut(duration: 0.4)) { if toast == text { toast = "" } }
        }
    }
}

// MARK: book feed

/// Deep Listen's line in the message band: the words being read, in step with the voice.
struct BookLine: View {
    let panel: Panel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let line = BookFeed.shared.lineWords {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEEP LISTEN").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(Palette.teal)
                    (Text(line.spoken).foregroundColor(Palette.foam)
                     + Text(line.coming.isEmpty ? "" : " " + line.coming).foregroundColor(Palette.mist.opacity(0.55)))
                        .font(.title3)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                }
            } else {
                let c = panel.caption
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.0).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                    Text(c.1).font(.footnote).foregroundStyle(Palette.mist)
                }
            }
        }
    }
}

struct BookFeedPicker: View {
    @ObservedObject var book: BookFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BOOK FEED · TEST").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(Palette.mist)
            HStack(spacing: 6) {
                ForEach(BookFeed.Mode.allCases, id: \.self) { m in
                    chip(m.label, on: book.mode == m) { book.mode = m }
                }
            }
            if book.mode == .listen {
                HStack(spacing: 6) {
                    ForEach(BookFeed.listenSpeeds, id: \.self) { v in
                        chip(speedLabel(v), on: book.listenSpeed == v) { book.listenSpeed = v }
                    }
                }
                Text("Once you settle, \(BookText.title) plays for 3 minutes at an easy listening speed in a clear voice, with its words in step coming through the tunnel and in the band below. It carries on where you left off, and a 10 phrase recall check follows the session.")
                    .font(.caption).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            } else if book.mode == .lab {
                HStack(spacing: 6) {
                    ForEach(BookFeed.labSpeeds, id: \.self) { v in
                        chip(speedLabel(v), on: book.labSpeed == v) { book.labSpeed = v }
                    }
                }
                Text("The fast, low feed with unreadable words, for 3 minutes once you settle, from a new place in the book each time. After the session, a 20 phrase quiz (half played, half never played) checks whether anything stuck. Guessing scores about 10.")
                    .font(.caption).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            } else if book.mode == .whole {
                Text("The whole book at 14 times normal speaking speed, every word spoken by the voice, with the music, and its words streaming through the tunnel too fast to read. Four short passages are held back so the 20 phrase quiz after the session has text you never heard. The end card shows the words played and the real speed.")
                    .font(.caption).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
                ProofPanel(book: book)
            }
        }
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.bg : Palette.foam)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Capsule().fill(on ? Palette.teal : Palette.current.opacity(0.45)))
        }
    }
}

/// Hear for yourself that the 14x feed is the real voice: one sentence at full speed, then the same
/// recording uncompressed, then the same sentence at normal speed, with the measured numbers.
struct ProofPanel: View {
    @ObservedObject var book: BookFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stage = book.proofStage {
                Text(stage).font(.footnote.weight(.semibold)).foregroundStyle(Palette.teal)
                    .fixedSize(horizontal: false, vertical: true)
                Text(book.proofText).font(.footnote).foregroundStyle(Palette.foam)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(action: { book.runProof() }) {
                    Text("Hear the proof")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Palette.foam)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .overlay(Capsule().stroke(Palette.teal, lineWidth: 1))
                }
            }
            if !book.proofNumbers.isEmpty {
                Text(book.proofNumbers).font(.caption).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: calibration

/// The one-time eye calibration: a dot walks the eyes to the middle and the corners, then asks for
/// wide eyes and a squint. Steady, no flashing.
struct CalibrationOverlay: View {
    @ObservedObject var engine: Engine

    var body: some View {
        let d = engine.calibDot
        GeometryReader { g in
            ZStack {
                Palette.bg.opacity(0.92)
                ZStack {
                    Circle().stroke(Palette.foam.opacity(0.18), lineWidth: 2)
                    Circle().trim(from: 0, to: d.fill)
                        .stroke(Palette.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: d.fill)
                    Circle().fill(Palette.foam).frame(width: 10, height: 10)
                }
                .frame(width: 36, height: 36)
                .position(x: g.size.width * d.x, y: g.size.height * d.y)
                .animation(.easeInOut(duration: 0.45), value: d.step)

                VStack(spacing: 8) {
                    Text("EYE CALIBRATION · \(min(d.step + 1, d.total)) OF \(d.total)")
                        .font(.caption2.weight(.semibold)).tracking(1.2)
                        .foregroundStyle(Palette.teal)
                    Text(d.text)
                        .font(.headline).foregroundStyle(Palette.foam)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if !d.note.isEmpty {
                        Text(d.note)
                            .font(.footnote.weight(.medium)).foregroundStyle(Palette.foam)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Once only. It's saved on this phone.")
                        .font(.caption).foregroundStyle(Palette.mist)
                }
                .frame(width: g.size.width - 64)
                .position(x: g.size.width / 2, y: g.size.height * 0.6)

                Button(action: { engine.skipCalibration() }) {
                    Text("Skip")
                        .font(.footnote).foregroundStyle(Palette.mist)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(Palette.glass))
                        .overlay(Capsule().stroke(Palette.current, lineWidth: 1))
                }
                .position(x: g.size.width / 2, y: g.size.height - 56)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: intro

struct IntroCard: View {
    @ObservedObject var engine: Engine
    @ObservedObject var journey: Journey
    @Binding var soundOn: Bool
    private var record: Record { journey.record }
    private var lastDive: DiveSummary? { journey.lastDive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROTOTYPE v\(AppInfo.version) · FACE ID CAMERA")
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
                bullet("Hold the phone any comfortable way with your face in view. It follows where your eyes land on the screen, so moving your hand is fine.")
                bullet("Rest your eyes on the center, soften your gaze, let your brow and jaw go.")
                bullet("The first time, a dot walks your eyes around the screen for about 15 seconds. It's saved, so you do it once. Redo it below if tracking feels off or you switch to glasses.")
                bullet("The first 20 seconds of a dive learn your resting face. Tap the screen to set the center right away.")
                bullet("Follow the light as it drifts. Once you hold focus, it goes where you look and the tunnel follows. While you steer, tap a spot you are looking at to line it up.")
                bullet("Hold a mellow calm and the void pulls you into a dive every 10 to 20 seconds: the tunnel speeds up, the pulse deepens and the air rushes past. The deeper your streak, the sooner and longer they come.")
                bullet("Sound follows you: it fills out as you focus and shimmers when you're mellow. A timed session fades out and ends on a soft bell. Turn your volume up.")
                bullet("The pulse reading is a hint and needs light on your face.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("SESSION").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(Palette.mist)
                HStack(spacing: 6) {
                    ForEach(Journey.lengths, id: \.self) { m in
                        let on = journey.plannedMinutes == m
                        Button(action: { journey.plannedMinutes = m }) {
                            Text(m == 0 ? "Open" : "\(m) min")
                                .font(.footnote.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Palette.bg : Palette.foam)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(Capsule().fill(on ? Palette.teal : Palette.current.opacity(0.45)))
                        }
                    }
                    Button(action: {
                        soundOn.toggle()
                        Soundscape.shared.setEnabled(soundOn)
                    }) {
                        Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.footnote)
                            .foregroundStyle(soundOn ? Palette.teal : Palette.mist)
                            .frame(width: 38).padding(.vertical, 8)
                            .background(Capsule().fill(Palette.current.opacity(0.45)))
                    }
                    .accessibilityLabel(soundOn ? "Sound on" : "Sound off")
                }
            }
            .padding(.top, 2)
            BookFeedPicker(book: BookFeed.shared)
            Button(action: { engine.start() }) {
                Text("Start")
                    .font(.headline)
                    .foregroundStyle(Palette.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.teal))
            }
            .padding(.top, 4)
            Button(action: { engine.start(calibrate: true) }) {
                Text(Engine.isCalibrated ? "Recalibrate eyes" : "Starts with a 15 second eye calibration, once")
                    .font(.footnote)
                    .foregroundStyle(Engine.isCalibrated ? Palette.teal : Palette.mist)
                    .frame(maxWidth: .infinity)
            }
            .disabled(!Engine.isCalibrated)
            if !engine.message.isEmpty {
                Text(engine.message)
                    .font(.footnote)
                    .foregroundStyle(Palette.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if record.sessions > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    if let d = lastDive {
                        Text("Last dive: \(d.minutes) min · World \(d.world + 1) · \(d.cleared) challenge\(d.cleared == 1 ? "" : "s") cleared\(d.newBest ? " · new deepest" : "")")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Palette.teal)
                    }
                    HStack(spacing: 8) {
                        progressStat(record.rank, "rank")
                        progressStat("\(record.streak) day\(record.streak == 1 ? "" : "s")", "streak")
                        progressStat("World \(record.deepest + 1)", "deepest")
                        progressStat("\(record.challengesWon)", "cleared")
                    }
                }
            }
            Text("Everything runs on this iPhone. Your progress stays on it, and nothing is sent.")
                .font(.caption)
                .foregroundStyle(Palette.mist.opacity(0.8))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 22).fill(Palette.glass))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.current, lineWidth: 1))
        .padding(.horizontal, 18)
    }

    private func progressStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(Palette.foam)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(Palette.mist)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.current.opacity(0.35)))
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Palette.teal).frame(width: 5, height: 5).padding(.top, 6)
            Text(s).font(.footnote).foregroundStyle(Palette.mist).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: end of a session

struct SummaryCard: View {
    let summary: SessionSummary
    let record: Record
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.completed ? "SESSION COMPLETE" : "SESSION ENDED")
                .font(.caption2.weight(.semibold)).tracking(1.2)
                .foregroundStyle(summary.newBest ? Palette.amber : Palette.teal)
            Text(headline)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.foam)
                .fixedSize(horizontal: false, vertical: true)
            Text(line)
                .font(.subheadline).foregroundStyle(Palette.mist)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile(Journey.mmss(summary.seconds), "time")
                tile("\(Int((summary.focus * 100).rounded()))%", "average focus")
                tile(Journey.mmss(summary.mellowSeconds), "in mellow calm")
                tile(Journey.mmss(summary.longestMellow), "calmest stretch")
                tile("World \(summary.world + 1)", VoidWorld.name(summary.world).lowercased())
                tile("\(summary.cleared)", summary.cleared == 1 ? "challenge cleared" : "challenges cleared")
            }
            if summary.dives > 0 {
                Text("\(summary.dives) dive\(summary.dives == 1 ? "" : "s") into the void")
                    .font(.footnote).foregroundStyle(Palette.mist)
            }
            if summary.bookSeconds > 5 {
                Text("\(summary.bookMode): \(Journey.mmss(summary.bookSeconds)) of \(BookText.title), about \(summary.bookWords) words")
                    .font(.footnote).foregroundStyle(Palette.mist)
            }
            if let d = summary.bookDetail {
                Text(d).font(.footnote).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let q = summary.quizLine {
                Text(q).font(.footnote).foregroundStyle(Palette.mist)
            }
            if let a = summary.pulseStart, let b = summary.pulseEnd {
                Text("Pulse hint \(a) → \(b)\(b < a ? ", settling as you went" : "")")
                    .font(.footnote).foregroundStyle(Palette.mist)
            }
            HStack(spacing: 8) {
                small(record.rank, "rank")
                small("\(record.streak) day\(record.streak == 1 ? "" : "s")", "streak")
                small("World \(record.deepest + 1)", "deepest")
            }
            Button(action: done) {
                Text("Done")
                    .font(.headline).foregroundStyle(Palette.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.teal))
            }
            Text("Kept on this iPhone only. Pulse is a visual hint, not a health reading.")
                .font(.caption).foregroundStyle(Palette.mist.opacity(0.8))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 22).fill(Palette.glass))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .stroke(summary.newBest ? Palette.amber.opacity(0.6) : Palette.current, lineWidth: 1))
        .padding(.horizontal, 18)
    }

    private var headline: String {
        if summary.newBest { return "Deeper than ever" }
        let share = summary.seconds > 0 ? summary.mellowSeconds / summary.seconds : 0
        if share > 0.4 { return "A soft, deep dive" }
        if summary.focus > 0.6 { return "Steady and focused" }
        return "Time well spent"
    }

    private var line: String {
        let world = "World \(summary.world + 1) · \(VoidWorld.name(summary.world))"
        if summary.newBest { return "You reached \(world), your deepest yet." }
        return "You reached \(world)."
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(Palette.foam).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(Palette.mist).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.current.opacity(0.35)))
    }

    private func small(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(Palette.foam)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(Palette.mist)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.current.opacity(0.35)))
    }
}

// MARK: while running

struct RunningOverlay: View {
    @ObservedObject var engine: Engine
    let panel: Panel
    let best: Int
    let clock: String
    @Binding var showPanel: Bool
    @Binding var soundOn: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nmind").font(.headline).foregroundStyle(Palette.foam)
                    Text("v\(AppInfo.version)\(clock.isEmpty ? "" : " · " + clock)")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(Palette.mist)
                }
                Spacer()
                Button(action: {
                    soundOn.toggle()
                    Soundscape.shared.setEnabled(soundOn)
                }) {
                    Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.footnote).foregroundStyle(soundOn ? Palette.teal : Palette.mist)
                        .frame(width: 34, height: 30)
                        .background(Capsule().fill(Palette.glass))
                        .overlay(Capsule().stroke(Palette.current, lineWidth: 1))
                }
                .accessibilityLabel(soundOn ? "Sound on" : "Sound off")
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
                    stat("\(panel.depth + 1) · \(VoidWorld.name(panel.depth).components(separatedBy: " ").first ?? "")", "depth · best \(max(best, panel.depth) + 1)")
                    stat(panel.heart.map { panel.heartDrop >= 2 ? "\($0) ↓\(panel.heartDrop)" : "\($0)" } ?? "—", "heart")
                }
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
            // lifted off the very bottom edge so the numbers stay in view
            .padding(.bottom, 84)
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
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.glass))
    }
}

// MARK: the message band

extension Panel {
    var caption: (String, String) {
        switch mode {
        case .noFace, .idle: return ("Looking for you", "Bring your face back into view. Your place is held for a moment.")
        case .away: return ("Paused", "Look back at the center to continue.")
        case .second: return ("Paused", "Someone else is in view. Nmind pauses until it's just you.")
        case .reading: break
        }
        switch verdict {
        case .learning: return ("Learning your resting face · \(learnLeft)s", "Breathe normally and rest your eyes on the center.")
        case .restless: return ("Settle", "Let your eyes rest on the center. Keep your head still.")
        case .settling: return ("Settling", "Good. Breathe out slowly and let your eyes go soft.")
        case .tense: return ("Steady, but held", "You are holding it with effort. Soften your eyes, unclench your jaw, let your brow go.")
        case .mellow: return ("Mellow calm", "Easy and soft. Let it carry you deeper.")
        case .paused: return ("Paused", "Look back at the center to continue.")
        }
    }

}

/// One message at a time, in the band below the centre target: a reward or challenge first,
/// then a quick notice, otherwise the coaching line.
struct MessageBand: View {
    let banner: Banner?
    let panel: Panel
    let toast: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let b = banner {
                HStack(alignment: .firstTextBaseline) {
                    Text(b.title).font(.headline)
                        .foregroundStyle(b.tone == .reward ? Palette.amber : b.tone == .challenge ? Palette.teal : Palette.foam)
                    Spacer()
                    if let s = b.secondsLeft {
                        Text("\(s)s").font(.system(.footnote, design: .monospaced)).foregroundStyle(Palette.mist)
                    }
                }
                Text(b.detail).font(.footnote).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
                if let p = b.progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.current.opacity(0.6))
                            Capsule().fill(Palette.teal).frame(width: max(4, g.size.width * p))
                                .animation(.easeInOut(duration: 0.3), value: p)
                        }
                    }
                    .frame(height: 4)
                }
            } else if !toast.isEmpty {
                Text(toast).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.foam)
            } else if BookFeed.shared.sessionMode == .listen && BookFeed.shared.isFeeding {
                BookLine(panel: panel)
            } else {
                let c = panel.caption
                Text(c.0).font(.subheadline.weight(.semibold))
                    .foregroundStyle(panel.verdict == .tense && panel.mode == .reading ? Palette.amber : Palette.teal)
                Text(c.1).font(.footnote).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.glass))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(banner?.tone == .reward ? Palette.amber.opacity(0.6) : Palette.current, lineWidth: 1))
        .animation(.easeInOut(duration: 0.35), value: banner)
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
                Text(panel.steer)
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
