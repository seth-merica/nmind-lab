import ARKit
import Combine
import CoreMotion
import UIKit

// Reads the face with ARKit on the Face ID (TrueDepth) camera: head pose, eye rotation,
// the 52 expression scores, and (as a hint) skin colour from the front colour camera for the
// pulse. Everything stays on the phone. No frames, images or numbers are saved or sent.

private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }

enum Mode: String {
    case idle, noFace, away, second, reading
}

/// What the drawing loop reads every frame.
struct Live {
    var F = 0.3
    var Z = 0.0
    var travel = 0.0
    var mellow = 0.0
    var mode: Mode = .idle
    var verdict: Verdict = .learning
    var learnLeft = 20
    /// heart rate from the camera, and how sure the reading is (0 to 1)
    var hr = 0.0
    var hrConf = 0.0
    /// where the centre target sits now, as a fraction of the screen's width and height
    var tx = 0.5
    var ty = Engine.homeY
    /// true while your eyes steer the centre
    var steering = false
}

/// What the readout and captions show, refreshed four times a second.
struct Panel {
    var signals: [String: Signal] = [:]
    var verdict: Verdict = .learning
    var learnLeft = 20
    var tension = 0.0
    var mellow = 0.0
    var still = 0.0
    var fps = 0.0
    var F = 0.0
    var depth = 0
    var heart: Int?
    /// beats per minute below your rate at the start of the session (positive means slower)
    var heartDrop = 0
    var mode: Mode = .idle
    var lock = 0.0
    /// eye steering state and gaze map, for the camera view readout
    var steer = ""
}

final class Engine: NSObject, ObservableObject, ARSessionDelegate {
    @Published var running = false
    @Published var message = ""
    @Published var panel = Panel()

    /// read by the canvas on the main thread
    var live = Live()

    static var supported: Bool { ARFaceTrackingConfiguration.isSupported }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "nmind.face", qos: .userInteractive)
    private let calm = CalmReader()

    // all below touched only on `queue`
    private var lastT = 0.0, startT = 0.0, seenT = 0.0, secondT = 0.0, awayT = 0.0
    private var mode: Mode = .idle
    private var eyeH: [(t: Double, x: Double, y: Double)] = []
    private var headH: [(t: Double, p: SIMD3<Double>, yaw: Double, pitch: Double)] = []
    private var lookH: [(t: Double, v: Bool)] = []
    private var center: (x: Double, y: Double)?
    private var recenterAsked = false
    private var lock = 0.0
    private var F = 0.3, Z = 0.0, travel = 0.0, mellowV = 0.0
    /// seconds of held mellow calm; the longer it holds, the faster you sink (up to 2.8x)
    private var streak = 0.0
    private var lastPanel = 0.0
    private var skinIdx: [Int]?
    private let motionMgr = CMMotionManager()
    private var phoneMove = 0.0, s2Held = 0.6, headYHeld = 0.0, headZHeld = -0.3
    private var lastHit: SIMD2<Double>?
    private var hrStart = 0.0
    private var boostUntil = 0.0

    // The wandering target. It drifts slowly around the screen once the resting face is learned,
    // and the tunnel bends to follow it. The gaze is compared with where the target is now, and
    // `gazeMap` learns how far the eyes move on the screen for each metre the target moves, so it
    // works whatever the gaze sensor's gain or the phone's axes turn out to be.
    static let homeY = 0.42
    private static let metresPerPoint = 0.000166                  // iPhone 17 Pro Max, about 460 ppi at 3x
    private let screenM = (w: 440 * Engine.metresPerPoint, h: 956 * Engine.metresPerPoint)
    private var wanderPhase = 0.0, wanderAmp = 0.0
    private var tx = 0.5, ty = Engine.homeY
    /// screen offset (right, down) in metres to gaze-hit offset in camera space: [a b; c d]
    private var gazeMap = (a: 0.0, b: 1.0, c: 1.0, d: 0.0)

    // Eye steering. Once the gaze map has learned how your eyes follow the target and you have
    // held focus for a few seconds, the centre goes where you look. A one-euro filter keeps it
    // still when your eyes rest and lets it jump with a quick look. Losing focus hands the centre
    // back to its slow wander.
    private var steering = false, steerMix = 0.0, learnT = 0.0, steerHold = 0.0, lowT = 0.0, offT = 0.0
    private var steerX = 0.5, steerY = Engine.homeY, steerSeeded = false
    /// the last fifth of a second of raw gaze points on the screen (metres from home), for fixations
    private var steerBuf: [(t: Double, x: Double, y: Double)] = []
    private var steerJump = false
    /// taps while steering: you look where you tap, so each one is a calibration point
    private var taps: [(t: Double, hit: SIMD2<Double>, o: SIMD2<Double>)] = []
    private var tapAsked: (x: Double, y: Double)?
    private var tuned = 0

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start() {
        guard Engine.supported else {
            message = "This iPhone has no Face ID camera, so Nmind can't track your face."
            return
        }
        let cfg = ARFaceTrackingConfiguration()
        cfg.isLightEstimationEnabled = true
        cfg.maximumNumberOfTrackedFaces = min(2, ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces)
        queue.async {
            self.lastT = 0; self.startT = 0; self.seenT = 0; self.secondT = 0; self.awayT = 0
            self.mode = .noFace; self.eyeH = []; self.headH = []; self.lookH = []
            self.center = nil; self.lastHit = nil; self.wanderPhase = 0; self.wanderAmp = 0; self.tx = 0.5; self.ty = Engine.homeY; self.gazeMap = (0, 1, 1, 0); self.steering = false; self.steerMix = 0; self.learnT = 0; self.steerHold = 0; self.lowT = 0; self.offT = 0; self.steerSeeded = false; self.steerBuf = []; self.steerJump = false; self.taps = []; self.tapAsked = nil; self.tuned = 0; self.hrStart = 0; self.boostUntil = 0; self.phoneMove = 0; self.s2Held = 0.6; self.lock = 0; self.F = 0.3; self.Z = 0; self.travel = 0; self.mellowV = 0; self.streak = 0
            self.calm.reset(0)
        }
        if motionMgr.isDeviceMotionAvailable {
            motionMgr.deviceMotionUpdateInterval = 1.0 / 60
            motionMgr.startDeviceMotionUpdates()
        }
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        message = ""
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        session.pause()
        motionMgr.stopDeviceMotionUpdates()
        running = false
        live = Live()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// A reward: travel faster for a while, as long as you stay with it.
    func boost(_ seconds: Double) { queue.async { self.boostUntil = self.lastT + seconds } }

    /// Treat wherever the eyes rest right now as the centre target.
    func recenter() { queue.async { self.recenterAsked = true } }

    /// A tap at a spot on the screen (fractions of width and height). While you steer it tunes the
    /// gaze map to that spot; otherwise it sets the centre where your eyes are. Returns true if it tuned.
    @discardableResult
    func tap(x: Double, y: Double) -> Bool {
        let steeringNow = live.steering
        queue.async {
            if self.steering { self.tapAsked = (x, y) } else { self.recenterAsked = true }
        }
        return steeringNow
    }

    /// Fits the gaze map to your taps. One tap moves the centre so it lands right; taps spread
    /// along an axis also fit how far the eyes move per centimetre that way.
    private func calibrate() {
        guard let last = taps.last else { return }
        let gm = gazeMap
        func applyOffset() {
            let e = SIMD2(gm.a * last.o.x + gm.b * last.o.y, gm.c * last.o.x + gm.d * last.o.y)
            center = (last.hit.x - e.x, last.hit.y - e.y)
        }
        guard taps.count >= 2 else { applyOffset(); return }
        // each axis on its own: hit.x against the screen's down offset, hit.y against its right offset
        func fit(_ xs: [Double], _ ys: [Double], _ g0: Double, _ y0: Double) -> (g: Double, c: Double) {
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var sxx = 0.0, sxy = 0.0
            for i in 0..<xs.count { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
            // taps must spread about 1.5 cm along this axis before its gain is refit
            guard (sxx / n).squareRoot() > 0.015 else { return (g0, y0) }
            let lam = 0.0003                                     // pull toward the current gain
            let g = Engine.gain((sxy + lam * g0) / (sxx + lam), like: nil)
            return (g, my - g * mx)
        }
        let down = fit(taps.map { $0.o.y }, taps.map { $0.hit.x }, gm.b, last.hit.x - gm.b * last.o.y)
        let right = fit(taps.map { $0.o.x }, taps.map { $0.hit.y }, gm.c, last.hit.y - gm.c * last.o.x)
        gazeMap = (0, down.g, right.g, 0)
        center = (down.c, right.c)
    }

    /// Eye-to-screen gain for one axis, never so small that noise is blown up. The slow learning
    /// keeps the sign it has (it starts positive, as the camera's axes say); taps may flip it.
    private static func gain(_ v: Double, like: Double?) -> Double {
        let sign = like.map { $0 < 0 ? -1.0 : 1.0 } ?? (v < 0 ? -1.0 : 1.0)
        return sign * max(0.3, min(1.6, v * sign))
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didFailWithError error: Error) {
        let text: String
        if let e = error as? ARError, e.code == .cameraUnauthorized {
            text = "Camera access is off. Turn it on in Settings, Nmind, Camera, then tap Start again."
        } else {
            text = "The camera stopped: \(error.localizedDescription)"
        }
        DispatchQueue.main.async {
            self.message = text
            self.stop()
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.timestamp
        let dt = lastT > 0 ? clamp(t - lastT, 0.001, 0.25) : 1.0 / 60
        lastT = t
        if startT == 0 { startT = t; calm.reset(t) }

        let faces = frame.anchors.compactMap { $0 as? ARFaceAnchor }.filter { $0.isTracked }
        if let a = faces.first {
            seenT = t
            secondT = faces.count >= 2 ? secondT + dt : 0
            track(a, frame: frame, t: t, dt: dt)
        } else {
            secondT = 0
            lookH.append((t, false)); trimLook(t)
            // a brief loss (a tilt, a bump) holds your place; only a longer one lets focus fall
            let gone = t - seenT
            if gone > 1.5 { mode = .noFace }
            step(t: t, dt: dt, Ftgt: gone < 2.0 ? F : 0.08)
        }
        publish(t)
    }

    // MARK: per-frame reading

    private func track(_ a: ARFaceAnchor, frame: ARFrame, t: Double, dt: Double) {
        // head pose relative to the camera
        let R = simd_mul(simd_inverse(frame.camera.transform), a.transform)
        let pos = SIMD3<Double>(Double(R.columns.3.x), Double(R.columns.3.y), Double(R.columns.3.z))
        let fz = R.columns.2
        let yaw = Double(atan2(fz.x, fz.z)), pitch = Double(atan2(fz.y, fz.z))

        // expression scores
        let bs = a.blendShapes
        func b(_ k: ARFaceAnchor.BlendShapeLocation) -> Double { bs[k]?.doubleValue ?? 0 }
        let blink = (b(.eyeBlinkLeft) + b(.eyeBlinkRight)) / 2
        // Looking down lowers the lids, which reads as a half blink. Take that out, so a look
        // down still counts as open eyes and the gaze keeps tracking.
        let lidL = max(0, b(.eyeBlinkLeft) - 0.75 * b(.eyeLookDownLeft))
        let lidR = max(0, b(.eyeBlinkRight) - 0.75 * b(.eyeLookDownRight))
        let wL = clamp(1 - (lidL - 0.35) / 0.3, 0, 1), wR = clamp(1 - (lidR - 0.35) / 0.3, 0, 1)
        let shut = wL + wR < 0.3
        let squint = (b(.eyeSquintLeft) + b(.eyeSquintRight)) / 2
        let wide = (b(.eyeWideLeft) + b(.eyeWideRight)) / 2
        let brow = (b(.browDownLeft) + b(.browDownRight)) / 2 + 0.5 * b(.browInnerUp)
        let jaw = (b(.mouthPressLeft) + b(.mouthPressRight)) / 2 + 0.6 * b(.jawForward)
            + 0.4 * (b(.mouthRollLower) + b(.mouthRollUpper)) / 2 + 0.4 * b(.mouthShrugLower)

        // eye rotation inside the head, from the point the eyes converge on
        let lp = a.lookAtPoint
        let len = simd_length(lp)
        let ln = len > 1e-5 ? lp / len : SIMD3<Float>(0, 0, 1)
        let ex = Double(atan2(ln.x, ln.z)), ey = Double(atan2(ln.y, ln.z))

        // Where the gaze lands on the phone. The eyes' midpoint and gaze direction are put in
        // camera space, and the ray is met with the plane of the screen. A point on the screen
        // stays the same point however the phone is held, tilted or moved, so the centre target
        // is kept as a spot on the glass and focus no longer depends on holding the phone just so.
        // The direction is the average of both eyes' own rotation, each weighted by how open it is,
        // so the reading never flips between one eye and the other.
        let lm = a.leftEyeTransform.columns.3, rm = a.rightEyeTransform.columns.3
        let mid = SIMD3<Float>((lm.x + rm.x) / 2, (lm.y + rm.y) / 2, (lm.z + rm.z) / 2)
        let lz = a.leftEyeTransform.columns.2, rz = a.rightEyeTransform.columns.2
        let fL = SIMD3<Float>(lz.x, lz.y, lz.z), fR = SIMD3<Float>(rz.x, rz.y, rz.z)
        var gdir = fL * Float(wL + 0.01) + fR * Float(wR + 0.01)
        if simd_dot(gdir, lp - mid) < 0 { gdir = -gdir }      // point out of the face, toward the phone
        let gl = simd_length(gdir)
        gdir = gl > 1e-5 ? gdir / gl : SIMD3<Float>(0, 0, 1)
        let o4 = simd_mul(R, SIMD4<Float>(mid.x, mid.y, mid.z, 1))
        let g4 = simd_mul(R, SIMD4<Float>(gdir.x, gdir.y, gdir.z, 0))
        var hit: SIMD2<Double>? = nil
        var eyeDist = max(0.12, Double(simd_length(SIMD3<Float>(o4.x, o4.y, o4.z))))
        if abs(g4.z) > 0.05 {
            let k = -o4.z / g4.z
            if k > 0 {
                let hx = Double(o4.x + k * g4.x), hy = Double(o4.y + k * g4.y)
                hit = SIMD2(hx, hy)
                eyeDist = max(0.12, Double(k) * Double(simd_length(SIMD3<Float>(g4.x, g4.y, g4.z))))
            }
        }
        if !shut, let h = hit { lastHit = h }

        // move the target, then take the gaze relative to it
        let learning = calm.out.learning
        if mode == .reading && !learning && !steering { wanderPhase += dt }
        wanderAmp += ((mode == .reading && !learning ? 1.0 : 0.0) - wanderAmp) * min(1, dt / 6)
        let w = wanderPhase * 2 * Double.pi
        let wx = 0.5 + wanderAmp * (0.22 * sin(w / 27) + 0.06 * sin(w / 71 + 2.1))
        let wy = Engine.homeY + wanderAmp * (0.09 * sin(w / 37 + 1.3) + 0.02 * sin(w / 53))
        let gm = gazeMap

        // steering: unlock after the map has learned and focus has held; hand back when focus drops
        let det = gm.a * gm.d - gm.b * gm.c
        let mapReady = learnT > 15 && abs(det) > 0.08
        steerHold = (mode == .reading && !learning && F > 0.55) ? steerHold + dt : 0
        lowT = F < 0.4 ? lowT + dt : 0
        offT = mode != .reading ? offT + dt : 0
        if !steering && mapReady && steerHold > 3 { steering = true; steerSeeded = false; steerBuf = [] }
        if steering && (lowT > 4 || offT > 2.5 || learning) { steering = false }

        // a tap while steering: the eyes are on the tapped spot, so fit the map to it
        if let tp = tapAsked {
            tapAsked = nil
            if let raw = hit, !shut {
                let o = SIMD2((tp.x - 0.5) * screenM.w, (tp.y - Engine.homeY) * screenM.h)
                taps.append((t, raw, o))
                taps.removeAll { t - $0.t > 240 }
                if taps.count > 8 { taps.removeFirst(taps.count - 8) }
                calibrate()
                tuned += 1
            }
        }

        if steering, !shut, let raw = hit, let cc = center {
            let gmNow = gazeMap
            let dNow = gmNow.a * gmNow.d - gmNow.b * gmNow.c
            if abs(dNow) > 0.05 {
                // where on the screen the eyes point, in metres from home, from the inverse of the map
                let gx = raw.x - cc.x, gy = raw.y - cc.y
                let sx = (gmNow.d * gx - gmNow.b * gy) / dNow, sy = (-gmNow.c * gx + gmNow.a * gy) / dNow
                steerBuf.append((t, sx, sy))
            }
        }
        steerBuf.removeAll { t - $0.t > 0.2 }
        if steering, steerBuf.count >= 4 {
            if !steerSeeded { steerX = tx; steerY = ty; steerSeeded = true }
            // A fixation is the mean of the last fifth of a second. Small differences from where the
            // centre sits are the sensor's noise and only nudge it slowly; a real look elsewhere
            // (more than about 8 mm) sends it there in a quick glide, the way the eyes jump.
            let n = Double(steerBuf.count)
            let mx = steerBuf.reduce(0) { $0 + $1.x } / n, my = steerBuf.reduce(0) { $0 + $1.y } / n
            let fx = clamp(0.5 + mx / screenM.w, 0.1, 0.9)
            let fy = clamp(Engine.homeY + my / screenM.h, 0.12, 0.6)
            let dm = hypot((fx - steerX) * screenM.w, (fy - steerY) * screenM.h)
            if dm > 0.008 { steerJump = true }
            if steerJump && dm < 0.0025 { steerJump = false }
            let tau = steerJump ? 0.09 : 0.9
            let k = 1 - exp(-dt / tau)
            steerX += (fx - steerX) * k
            steerY += (fy - steerY) * k
        }
        steerMix += ((steering ? 1.0 : 0.0) - steerMix) * min(1, dt / (steering ? 0.35 : 1.5))
        if !steering && steerMix < 0.001 { steerX = wx; steerY = wy }
        tx = wx + (steerX - wx) * steerMix
        ty = wy + (steerY - wy) * steerMix
        let ox = (tx - 0.5) * screenM.w, oy = (ty - Engine.homeY) * screenM.h
        let expect = SIMD2(gm.a * ox + gm.b * oy, gm.c * ox + gm.d * oy)
        let res: SIMD2<Double>? = hit.map { $0 - expect }

        // phone movement from the motion sensors: quick moves of the hand are not the body
        // getting restless, so head stillness is held, not marked down, while the phone moves
        var moveNow = 0.0
        if let dm = motionMgr.deviceMotion {
            let r = dm.rotationRate, ua = dm.userAcceleration
            moveNow = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() + 3 * (ua.x * ua.x + ua.y * ua.y + ua.z * ua.z).squareRoot()
        }
        phoneMove += (moveNow - phoneMove) * min(1, dt / (moveNow > phoneMove ? 0.05 : 0.4))
        let phoneMoving = phoneMove > 0.35

        // attention: face toward the phone (loosely) and the gaze landing on or near the phone
        let onPhone = lastHit.map { simd_length($0) < 0.26 } ?? true
        let facing = abs(yaw) < 0.8 && abs(pitch) < 0.8 && onPhone
        awayT = facing ? 0 : awayT + dt
        if secondT > 0.4 { mode = .second }
        else if awayT > 1.2 { mode = .away }
        else { mode = .reading }
        let looking = mode == .reading
        lookH.append((t, looking)); trimLook(t)

        // steadiness of the gaze on the screen and of the head over the last couple of seconds
        if !shut, let h = res { eyeH.append((t, h.x, h.y)) }
        eyeH.removeAll { t - $0.t > 1.5 }
        let gazeSpread = eyeSpread() / eyeDist                      // radians, as seen from the eyes
        let s1 = exp(-max(0, gazeSpread - 0.012) / 0.03)
        if !phoneMoving {
            headH.append((t, pos, yaw, pitch))
            headH.removeAll { t - $0.t > 2 }
            let (pSp, rSp) = headSpread()                            // slow drift of the arm is removed
            s2Held = exp(-max(0, pSp - 0.0025) / 0.006) * exp(-max(0, rSp - 0.015) / 0.035)
            headYHeld = pos.y; headZHeld = pos.z
        }
        let s2 = s2Held
        let s3 = lookH.isEmpty ? 0 : Double(lookH.filter { $0.v }.count) / Double(lookH.count)

        // centre lock: the gaze stays on the same spot of the screen. A steady gaze held on
        // another spot for a couple of seconds pulls the centre there, so a bad start or a
        // shifted grip recovers on its own; tapping the screen sets it at once.
        if !shut && looking, let h = res {
            if recenterAsked || center == nil { center = (h.x, h.y); recenterAsked = false }
            else if !steering, let cc = center {
                let off = hypot(h.x - cc.x, h.y - cc.y) / eyeDist
                let steady = eyeH.count >= 20 && gazeSpread < 0.03 && (eyeH.last!.t - eyeH.first!.t) > 1.2
                let tau = calm.out.learning ? 3.0 : (steady && off > 0.06 ? 2.5 : 25.0)
                let k = 1 - exp(-dt / tau)
                center = (cc.x + (h.x - cc.x) * k, cc.y + (h.y - cc.y) * k)
                // learn the gaze map while the target is away from home and the eyes follow it
                // The camera's axes are fixed to the phone: on an iPhone held upright its x runs down
                // the screen and its y runs to the right. So each screen direction has its own gain,
                // learned alone. A full 2x2 map learned from the drifting target (whose left-right and
                // up-down moves go together for long stretches) collapsed to one diagonal line.
                if !phoneMoving && gazeSpread < 0.05, let raw = hit {
                    let eX = raw.x - cc.x - expect.x, eY = raw.y - cc.y - expect.y
                    var b = gm.b, c = gm.c
                    if abs(oy) > 0.003 { b += 0.004 / (oy * oy + 0.0001) * eX * oy }
                    if abs(ox) > 0.003 { c += 0.004 / (ox * ox + 0.0001) * eY * ox }
                    if abs(oy) > 0.003 || abs(ox) > 0.003 {
                        gazeMap = (0, Engine.gain(b, like: gm.b), Engine.gain(c, like: gm.c), 0)
                        learnT += dt
                    }
                }
            }
        }
        if let cc = center, let raw = lastHit {
            let h = raw - expect
            let dev = hypot(h.x - cc.x, h.y - cc.y) / eyeDist
            // while you steer, the centre follows your eyes, so only a wide miss (a quick look
            // the centre has not caught up with yet) loosens the lock
            let target = !looking ? 0 : (steering ? 0.25 + 0.7 * exp(-max(0, dev - 0.1) / 0.2) : exp(-max(0, dev - 0.05) / 0.12))
            lock += (target - lock) * (1 - exp(-dt / 0.4))
        }
        // eye jumps are read from the gaze on the screen, so following the screen as the hand
        // moves does not count as restless eyes
        let gx = lastHit.map { ($0.x - expect.x) / eyeDist } ?? ex, gy = lastHit.map { ($0.y - expect.y) / eyeDist } ?? ey

        // skin colour on forehead and cheeks, for the camera pulse (a hint)
        let rgb = sampleSkin(a, frame: frame)
        let ambient = frame.lightEstimate.map { Double($0.ambientIntensity) }

        let out = calm.frame(CalmInput(t: t, dt: dt, looking: looking, blink: blink, ex: gx, ey: gy,
                                       s1: s1, s2: s2, s3: s3, squint: squint, wide: wide, brow: brow, jaw: jaw,
                                       headY: headYHeld, headZ: headZHeld, rgb: rgb, ambient: ambient))
        let calmV = clamp((out.still - 0.3) / 0.6, 0, 1)
        let Ftgt = looking ? 0.55 * lock + 0.45 * calmV : 0.08
        let mTarget = out.verdict == .mellow ? out.mellow : out.mellow * 0.4
        mellowV += (mTarget - mellowV) * min(1, dt / 3)
        step(t: t, dt: dt, Ftgt: Ftgt)
    }

    /// Eases focus and moves you through the void. Only mellow calm travels deeper.
    private func step(t: Double, dt: Double, Ftgt: Double) {
        F += (Ftgt - F) * (1 - exp(-dt / (Ftgt > F ? 1.5 : 1.0)))
        let o = calm.out
        let ready = clamp((F - 0.3) / 0.4, 0, 1)
        var target: Double
        if mode != .reading { target = -0.02; streak = max(0, streak - dt * 2) }
        else {
            switch o.verdict {
            case .mellow: streak += dt * ready
            case .settling: break
            case .tense: streak = max(0, streak - dt * 1.5)
            case .restless: streak = max(0, streak - dt * 4)
            default: streak = max(0, streak - dt)
            }
            streak = min(streak, 120)
            let momentum = 1 + min(1.8, streak / 40)
            switch o.verdict {
            case .mellow: target = 0.16 * momentum * ready * (0.6 + 0.4 * o.mellow) * clamp(1 - 2 * (o.tension - 0.15), 0, 1)
            case .settling: target = 0.04 * ready * (1 + 0.5 * (momentum - 1))
            case .tense: target = 0
            case .restless: target = -0.05
            default: target = 0.02 * ready
            }
        }
        if mode == .reading && t < boostUntil { target += 0.22 }
        travel += (target - travel) * min(1, dt / 2.5)
        Z = max(0, Z + travel * dt)
    }

    private func publish(_ t: Double) {
        let o = calm.out
        let snap = Live(F: F, Z: Z, travel: travel, mellow: mellowV, mode: mode, verdict: o.verdict, learnLeft: o.learnLeft,
                        hr: o.hr, hrConf: o.hrConf, tx: tx, ty: ty, steering: steering)
        var p: Panel?
        if o.hrConf > 0.15 && o.hr > 35 && o.hr < 180 {
            if hrStart == 0 { hrStart = o.hr }
            else if t - startT < 60 { hrStart += (o.hr - hrStart) * 0.01 }
        }
        if t - lastPanel > 0.25 {
            lastPanel = t
            p = Panel(signals: o.signals, verdict: o.verdict, learnLeft: o.learnLeft, tension: o.tension, mellow: o.mellow,
                      still: o.still, fps: calm.fps, F: F, depth: VoidWorld.level(Z),
                      heart: o.hrConf > 0.15 ? Int(o.hr.rounded()) : nil,
                      heartDrop: o.hrConf > 0.15 && hrStart > 0 ? Int((hrStart - o.hr).rounded()) : 0,
                      mode: mode, lock: lock,
                      steer: String(format: "steer %@ · taps %d · gain down %.2f right %.2f · learn %.0fs",
                                    steering ? "on" : "off", tuned, gazeMap.b, gazeMap.c, learnT))
        }
        DispatchQueue.main.async {
            guard self.running else { return }
            self.live = snap
            if let p = p { self.panel = p }
        }
    }

    // MARK: helpers

    private func trimLook(_ t: Double) { lookH.removeAll { t - $0.t > 5 } }

    private func eyeSpread() -> Double {
        guard eyeH.count >= 4 else { return 0 }
        let n = Double(eyeH.count)
        let mx = eyeH.reduce(0) { $0 + $1.x } / n, my = eyeH.reduce(0) { $0 + $1.y } / n
        let v = eyeH.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) + ($1.y - my) * ($1.y - my) } / n
        return v.squareRoot()
    }

    /// Head movement over the last two seconds after a straight-line trend is taken out, so a slow
    /// sag or drift of the arm holding the phone is not read as fidgeting.
    private func headSpread() -> (Double, Double) {
        guard headH.count >= 8 else { return (0, 0) }
        let n = Double(headH.count)
        let t0 = headH[0].t
        let ts = headH.map { $0.t - t0 }
        let mt = ts.reduce(0, +) / n
        let vt = max(1e-6, ts.reduce(0) { $0 + ($1 - mt) * ($1 - mt) })
        func residual(_ xs: [Double]) -> Double {
            let mx = xs.reduce(0, +) / n
            var cov = 0.0
            for i in 0..<xs.count { cov += (ts[i] - mt) * (xs[i] - mx) }
            let slope = cov / vt
            var r = 0.0
            for i in 0..<xs.count { let e = xs[i] - mx - slope * (ts[i] - mt); r += e * e }
            return r / n
        }
        let vp = residual(headH.map { $0.p.x }) + residual(headH.map { $0.p.y }) + residual(headH.map { $0.p.z })
        let vr = residual(headH.map { $0.yaw }) + residual(headH.map { $0.pitch })
        return (vp.squareRoot(), vr.squareRoot())
    }

    /// Mean skin colour (0 to 255) on the forehead and both cheeks, read from the colour frame.
    private func sampleSkin(_ a: ARFaceAnchor, frame: ARFrame) -> SIMD3<Double>? {
        let verts = a.geometry.vertices
        if skinIdx == nil {
            // pick the mesh points nearest the forehead and the cheeks once; the mesh layout never changes
            let targets: [SIMD2<Float>] = [SIMD2(0, 0.062), SIMD2(-0.042, -0.008), SIMD2(0.042, -0.008)]
            skinIdx = targets.map { tg in
                var best = 0, bd = Float.greatestFiniteMagnitude
                for (i, v) in verts.enumerated() where v.z > 0 {
                    let d = simd_length(SIMD2(v.x, v.y) - tg)
                    if d < bd { bd = d; best = i }
                }
                return best
            }
        }
        guard let idx = skinIdx else { return nil }
        let cam = frame.camera
        let res = cam.imageResolution
        func project(_ local: SIMD3<Float>) -> CGPoint {
            let w = simd_mul(a.transform, SIMD4<Float>(local.x, local.y, local.z, 1))
            return cam.projectPoint(SIMD3<Float>(w.x, w.y, w.z), orientation: .landscapeRight, viewportSize: res)
        }
        let pb = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let W = CVPixelBufferGetWidthOfPlane(pb, 0), H = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let yp = yBase.assumingMemoryBound(to: UInt8.self), cp = cBase.assumingMemoryBound(to: UInt8.self)

        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        for (k, i) in idx.enumerated() where i < verts.count {
            let v = verts[i]
            let p = project(v)
            let edge = project(v + SIMD3<Float>(k == 0 ? 0.016 : 0.011, 0, 0))
            let half = Int(max(3, min(60, hypot(edge.x - p.x, edge.y - p.y))))
            let cx = Int(p.x), cy = Int(p.y)
            let x0 = max(0, cx - half), x1 = min(W - 2, cx + half), y0 = max(0, cy - half), y1 = min(H - 2, cy + half)
            if x1 <= x0 + 2 || y1 <= y0 + 2 { continue }
            let stepPx = max(1, (x1 - x0) / 10)
            var y = y0
            while y <= y1 {
                var x = x0
                while x <= x1 {
                    let Y = Double(yp[y * yStride + x])
                    let ci = (y / 2) * cStride + (x / 2) * 2
                    let Cb = Double(cp[ci]) - 128, Cr = Double(cp[ci + 1]) - 128
                    sr += Y + 1.402 * Cr
                    sg += Y - 0.344136 * Cb - 0.714136 * Cr
                    sb += Y + 1.772 * Cb
                    n += 1
                    x += stepPx
                }
                y += stepPx
            }
        }
        return n > 0 ? SIMD3(sr / n, sg / n, sb / n) : nil
    }
}
