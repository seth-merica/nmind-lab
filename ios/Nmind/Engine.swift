import ARKit
import Combine
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
    var mode: Mode = .idle
    var lock = 0.0
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
    private var lastPanel = 0.0
    private var skinIdx: [Int]?

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
            self.center = nil; self.lock = 0; self.F = 0.3; self.Z = 0; self.travel = 0; self.mellowV = 0
            self.calm.reset(0)
        }
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        message = ""
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        session.pause()
        running = false
        live = Live()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Treat wherever the eyes rest right now as the centre target.
    func recenter() { queue.async { self.recenterAsked = true } }

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
            if t - seenT > 0.7 { mode = .noFace }
            step(t: t, dt: dt, Ftgt: 0.08)
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
        // gaze direction in camera space, for the centre lock
        let g = simd_mul(R, SIMD4<Float>(ln.x, ln.y, ln.z, 0))
        let gx = Double(atan2(g.x, g.z)), gy = Double(atan2(g.y, g.z))

        // attention: facing the phone, eyes on the screen, nobody else in view
        let facing = abs(yaw) < 0.45 && abs(pitch) < 0.45 && abs(gx) < 0.6 && abs(gy) < 0.6
        awayT = facing ? 0 : awayT + dt
        if secondT > 0.4 { mode = .second }
        else if awayT > 0.8 { mode = .away }
        else { mode = .reading }
        let looking = mode == .reading
        lookH.append((t, looking)); trimLook(t)

        // steadiness of the eyes and the head over the last couple of seconds
        if blink < 0.4 { eyeH.append((t, ex, ey)) }
        eyeH.removeAll { t - $0.t > 1.5 }
        headH.append((t, pos, yaw, pitch))
        headH.removeAll { t - $0.t > 2 }
        let s1 = exp(-max(0, eyeSpread() - 0.008) / 0.02)
        let (pSp, rSp) = headSpread()
        let s2 = exp(-max(0, pSp - 0.0015) / 0.004) * exp(-max(0, rSp - 0.01) / 0.025)
        let s3 = lookH.isEmpty ? 0 : Double(lookH.filter { $0.v }.count) / Double(lookH.count)

        // centre lock: the eyes stay where they rested on the centre target
        if blink < 0.4 && looking {
            if recenterAsked || center == nil { center = (gx, gy); recenterAsked = false }
            else if let cc = center {
                let k = calm.out.learning ? 1 - exp(-dt / 3) : 1 - exp(-dt / 25)
                center = (cc.x + (gx - cc.x) * k, cc.y + (gy - cc.y) * k)
            }
        }
        if let cc = center {
            let dev = hypot(gx - cc.x, gy - cc.y)
            let target = looking ? exp(-max(0, dev - 0.04) / 0.10) : 0
            lock += (target - lock) * (1 - exp(-dt / 0.4))
        }

        // skin colour on forehead and cheeks, for the camera pulse (a hint)
        let rgb = sampleSkin(a, frame: frame)
        let ambient = frame.lightEstimate.map { Double($0.ambientIntensity) }

        let out = calm.frame(CalmInput(t: t, dt: dt, looking: looking, blink: blink, ex: ex, ey: ey,
                                       s1: s1, s2: s2, s3: s3, squint: squint, wide: wide, brow: brow, jaw: jaw,
                                       headY: pos.y, headZ: pos.z, rgb: rgb, ambient: ambient))
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
        if mode != .reading { target = -0.02 }
        else {
            switch o.verdict {
            case .mellow: target = 0.16 * ready * (0.6 + 0.4 * o.mellow) * clamp(1 - 2 * (o.tension - 0.15), 0, 1)
            case .settling: target = 0.04 * ready
            case .tense: target = 0
            case .restless: target = -0.05
            default: target = 0.02 * ready
            }
        }
        travel += (target - travel) * min(1, dt / 2.5)
        Z = max(0, Z + travel * dt)
    }

    private func publish(_ t: Double) {
        let o = calm.out
        let snap = Live(F: F, Z: Z, travel: travel, mellow: mellowV, mode: mode, verdict: o.verdict, learnLeft: o.learnLeft)
        var p: Panel?
        if t - lastPanel > 0.25 {
            lastPanel = t
            p = Panel(signals: o.signals, verdict: o.verdict, learnLeft: o.learnLeft, tension: o.tension, mellow: o.mellow,
                      still: o.still, fps: calm.fps, F: F, depth: VoidWorld.level(Z),
                      heart: o.hrConf > 0.15 ? Int(o.hr.rounded()) : nil, mode: mode, lock: lock)
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

    private func headSpread() -> (Double, Double) {
        guard headH.count >= 4 else { return (0, 0) }
        let n = Double(headH.count)
        var mp = SIMD3<Double>(0, 0, 0), my = 0.0, mpi = 0.0
        for h in headH { mp += h.p; my += h.yaw; mpi += h.pitch }
        mp /= n; my /= n; mpi /= n
        var vp = 0.0, vr = 0.0
        for h in headH {
            let d = h.p - mp
            vp += d.x * d.x + d.y * d.y + d.z * d.z
            vr += (h.yaw - my) * (h.yaw - my) + (h.pitch - mpi) * (h.pitch - mpi)
        }
        return ((vp / n).squareRoot(), (vr / n).squareRoot())
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
