import Foundation

// Nmind worlds. Depth has no end: past the first worlds, new ones keep opening.
// Each world sets the look of the void (fold count, base hue, pattern seed); the GPU
// shader in VoidShader.metal draws it and VoidField eases between worlds.
// Fold counts skip 6, so no six-pointed figure can appear.

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
