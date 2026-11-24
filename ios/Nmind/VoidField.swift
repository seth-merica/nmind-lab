import SwiftUI

/// Everything the GPU shader needs for one frame.
struct VoidUniforms {
    var time = 0.0, flow = 0.0, focus = 0.3, deep = 0.0, beat = 0.0
    var folds = 7.0, hue = 0.0, iters = 1.0, wash = 0.2, bright = 0.85, kseed = 1.0
    var beatPhase = 0.0, ripple = 0.0, heartCalm = 0.0
    /// the far end of the tunnel, as a fraction of the screen
    var tx = 0.5, ty = Engine.homeY
    /// where the body of the tunnel is swinging toward; it trails the far end, so a quick look
    /// snaps the light there and the tunnel sweeps round after it
    var lx = 0.5, ly = Engine.homeY
}

/// Turns the engine's live readings into smooth shader inputs, frame by frame.
///
/// Travel: `flow` moves you down the tunnel. Its speed rises with focus and with mellow calm
/// travel, and is capped so a ring passes any point under twice a second.
/// Heart: when the camera has a confident heart rate, a soft pulse follows it, one swell per
/// beat, changing brightness by about 7 percent at most.
/// Worlds: each depth level has its own folds, color and pattern seed. Color and pattern morph
/// smoothly; the fold count changes behind a short, gentle dim so the tunnel never jumps.
final class VoidField {
    private(set) var Z = 0.0
    private var last: Date?
    private var u = VoidUniforms()
    private var rate = 0.2
    private var hr = 70.0, phase = 0.0, beatAmp = 0.0
    /// your resting rate for this session, learned slowly; beating below it counts as slowing
    private var hrBase = 0.0, heartCalm = 0.0
    private var foldsNow = 7.0, foldsWant = 7.0, swap = 1.0
    private var hueNow = 0.0, seedNow = 1.0
    private var started = false
    private var bloomAt = -100.0, rewardUntil = -100.0, rewardMix = 0.0

    /// A slow swell of light when you cross into a new world: rises over half a second, fades over two.
    func bloom() { bloomAt = u.time }
    /// A rare color world for a while: the colors drift through the whole spectrum and the pattern gets richer.
    func reward(seconds: Double) { rewardUntil = u.time + seconds }

    /// shader phase (0 to 1) for a hue in degrees, matching `pal()` in VoidShader.metal
    private static func phase(_ deg: Double) -> Double {
        let t = 1 - deg / 360
        return t - floor(t)
    }

    private static func world(_ l: Int) -> (folds: Double, hue: Double, seed: Double) {
        let fixed: [Double] = [5, 7, 8, 9, 10, 11, 7]           // never 6, never 12
        let cycle: [Double] = [8, 9, 10, 11, 7]
        let folds = l < fixed.count ? fixed[l] : cycle[(l - fixed.count) % cycle.count]
        let deg = l < VoidWorld.hues.count ? VoidWorld.hues[l]
            : VoidWorld.hues[VoidWorld.hues.count - 1] + Double(l - VoidWorld.hues.count + 1) * 137.5
        return (folds, phase(deg), 1.0 + Double(l) * 1.37)
    }

    func update(date: Date, live: Live, running: Bool, alpha: Double, sat: Double, reduce: Bool) -> VoidUniforms {
        let dt = last.map { min(0.1, max(0.001, date.timeIntervalSince($0))) } ?? 1.0 / 60
        last = date
        if running { Z = live.Z }
        let F = running ? live.F : 0.3
        let deep = VoidWorld.deep(Z)
        let w = VoidField.world(VoidWorld.level(Z))
        if !started {
            started = true
            foldsNow = w.folds; foldsWant = w.folds; hueNow = w.hue; seedNow = w.seed
        }

        // travel down the tunnel
        let travel = running ? max(0, live.travel) : 0
        var want = (0.12 + 0.45 * F + 2.6 * travel) * (1 + 0.4 * heartCalm)   // a slowing heart carries you faster
        want = min(want, 1.8)
        if reduce { want *= 0.35 }
        rate += (want - rate) * min(1, dt * 0.8)
        u.flow += dt * rate
        if u.flow > 1000 { u.flow -= 1000 }

        // world look: hue takes the short way round, pattern seed morphs
        rewardMix += ((u.time < rewardUntil ? 1.0 : 0.0) - rewardMix) * min(1, dt * 0.7)
        let hueWant = rewardMix > 0.05 ? (u.time * 0.05).truncatingRemainder(dividingBy: 1) : w.hue
        var dh = hueWant - hueNow
        dh -= (dh / 1).rounded()
        hueNow += dh * min(1, dt * 0.35)
        hueNow -= floor(hueNow)
        seedNow += (w.seed - seedNow) * min(1, dt * 0.3)
        foldsWant = w.folds
        if foldsWant != foldsNow {
            swap = max(0, swap - dt * 1.4)
            if swap == 0 { foldsNow = foldsWant }
        } else {
            swap = min(1, swap + dt * 1.0)
        }

        // heartbeat: a strong swell and a ripple on every beat, only with a confident reading.
        // Slowing your heart below where it started this session grows the core and speeds travel.
        let hasHeart = running && live.hrConf > 0.15 && live.hr > 35 && live.hr < 180
        if hasHeart {
            hr += (live.hr - hr) * min(1, dt * 0.8)
            if hrBase == 0 { hrBase = hr }
            hrBase += (hr - hrBase) * min(1, dt / 120)
        }
        let calmTarget = hasHeart && hrBase > 0 ? max(0, min(1, (hrBase - hr) / 8)) : 0
        heartCalm += (calmTarget - heartCalm) * min(1, dt * 0.5)
        beatAmp += ((hasHeart ? 1.0 : 0.0) - beatAmp) * min(1, dt * 0.5)
        phase += dt * hr / 60
        phase -= floor(phase)
        // quick rise, slow fall, like a pulse
        let swell = phase < 0.08 ? phase / 0.08 : exp(-(phase - 0.08) * 5)
        let beat = beatAmp * swell * (reduce ? 0.35 : 1.0)
        u.beatPhase = phase
        u.ripple = beatAmp * (reduce ? 0.4 : 1.0)
        u.heartCalm = heartCalm

        u.time += dt
        u.focus = F
        u.deep = deep
        u.beat = beat
        u.folds = foldsNow
        u.hue = hueNow
        u.kseed = seedNow
        let bt = u.time - bloomAt
        let bloomEnv = bt < 0 || bt > 8 ? 0 : (bt < 0.5 ? (bt / 0.5) * (bt / 0.5) * (3 - 2 * bt / 0.5) : exp(-(bt - 0.5) / 1.2))
        u.iters = min(4.2, 1 + 3 * F * (0.4 + 0.6 * deep) + 0.9 * rewardMix)
        u.wash = 1 - sat
        u.bright = alpha * (0.3 + 0.7 * swap) * (1 + 0.35 * bloomEnv)
        u.heartCalm = max(heartCalm, 0.8 * bloomEnv)
        // the far end eases to the target at the frame rate (the face reads arrive at 60 a second);
        // the tunnel's body trails it by about a quarter of a second
        let wantX = running ? live.tx : 0.5, wantY = running ? live.ty : Engine.homeY
        let kT = 1 - exp(-dt / (running && live.steering ? 0.02 : 0.08))
        u.tx += (wantX - u.tx) * kT
        u.ty += (wantY - u.ty) * kT
        let kL = 1 - exp(-dt / 0.25)
        u.lx += (u.tx - u.lx) * kL
        u.ly += (u.ty - u.ly) * kL
        return u
    }
}

extension VoidUniforms {
    func shader(size: CGSize) -> Shader {
        ShaderLibrary.nmindVoid(
            .float2(size.width, size.height), .float2(0.5, Engine.homeY), .float2(tx, ty), .float2(lx, ly),
            .float(time), .float(flow),
            .float(focus), .float(deep), .float(beat), .float(folds), .float(hue), .float(iters),
            .float(wash), .float(bright), .float(kseed),
            .float(beatPhase), .float(ripple), .float(heartCalm))
    }
}
